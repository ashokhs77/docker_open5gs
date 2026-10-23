"""
Scenario driver for the call-merge feature (features/30_call_merge.sh).

    cd /opt/test && python3 -m ue_sim.merge_scenarios <action> --ue SPEC --ue SPEC ...

Subscribers are given in the order A, B, C, D as  IMSI:KI:OPC:AMF:MSISDN  (Milenage).
A is the initiator (the handset that presses "Merge"). Every action prints exactly one
JSON object on stdout and exits 0; the feature script decides pass/fail from it.

Actions
  anchor       A calls B through the OpenSIPS B2BUA            [--video] [--hold-resume]
               and releases it                                  [--bye-from caller|callee]
  cancel       A calls B, B rings, A cancels
  reject       A calls B, B answers 486
  unreachable  A calls --target (nobody registered there)
  factory      A dials the conference factory alone             [--video] [--subscribe]
  merge        A talks to --parties far parties and merges them into one conference
               [--direction out|in|mixed] [--video] [--subscribe]
               [--bad-refer noreplaces,bogus] [--drop-unknown]   negative probes on the
                                                                 focus before the merge
               [--join]            afterwards B adds D (participant-initiated merge)
               [--drop]            afterwards A drops the last party
               [--leave]           afterwards B hangs up by itself
               The conference always ends with A's BYE on the focus.
  dialin       --count UEs dial the conference room --room one after the other
               (--stagger seconds apart), stay --hold seconds, then all hang up.
               Used by features/06_conference.sh to check the CONTENT of the
               dial-in conference CDR. Without --ue the fixed test subscribers
               (Config.default_subscribers) are used.   [--video]

How it works: each UE is single-threaded on its socket, so every UE that is not being
driven sits in pump() on its own thread (answering re-INVITE / BYE / NOTIFY and
recording them as events). The orchestrator stops a UE's pump while it drives that UE.

In this harness a UE's SIP identity is its IMSI (sip:<IMSI>@domain), so calls, the
REFER targets and the Drop number all use the IMSI.
"""

import argparse
import contextlib
import json
import logging
import subprocess
import sys
import threading
import time
from typing import Any, Dict, List, Optional

FS_CLI = "/usr/local/freeswitch/bin/fs_cli"
LABELS = ("A", "B", "C", "D")


def _spec(text: str) -> dict:
    parts = text.split(":")
    if len(parts) < 5:
        raise argparse.ArgumentTypeError("subscriber must be IMSI:KI:OPC:AMF:MSISDN")
    return {"imsi": parts[0], "ki": parts[1], "opc": parts[2],
            "amf": parts[3] or "8000", "msisdn": parts[4]}


def room_count(room: str) -> int:
    """Members of a FreeSWITCH conference; 0 when it does not exist, -1 when unknown."""
    try:
        done = subprocess.run(
            ["docker", "exec", "freeswitch", FS_CLI, "-x", f"conference {room} list count"],
            capture_output=True, text=True, timeout=10)
    except Exception:
        return -1
    text = (done.stdout or "").strip()
    if text.isdigit():
        return int(text)
    if "not found" in text.lower():
        return 0
    return -1


class Party:
    """One simulated handset plus the thread that serves it while it is idle."""

    def __init__(self, label: str, spec: dict, sip_port: int, shared_conn=None):
        from .ue_simulator import UESimulator
        self.label = label
        self.spec = spec
        self.ue = UESimulator(imsi=spec["imsi"], ki=spec["ki"], opc=spec["opc"],
                              amf=spec["amf"], msisdn=spec["msisdn"],
                              sip_local_port=sip_port, shared_conn=shared_conn)
        self.state: Dict[str, Any] = {}
        self._thread: Optional[threading.Thread] = None
        self._stop = threading.Event()

    @property
    def sip(self):
        return self.ue.sip

    @property
    def number(self) -> str:
        """What other parties dial and what the AS sees in From: the IMSI."""
        return self.spec["imsi"]

    def bring_up(self) -> bool:
        attached = bool(self.ue.attach())
        registered = bool(self.ue.ims_register()) if attached else False
        self.state = {"attach": attached, "register": registered}
        if not registered:
            self.state["error"] = self.ue.metrics.error_message
        return registered

    def start_pump(self) -> None:
        if self._thread is not None or self.sip is None:
            return
        self._stop.clear()
        self._thread = threading.Thread(
            target=lambda: self.sip.pump(86400.0, until=self._stop.is_set), daemon=True)
        self._thread.start()

    def stop_pump(self) -> None:
        if self._thread is None:
            return
        self._stop.set()
        self._thread.join(timeout=5.0)
        self._thread = None

    def has_dialog(self, dialog: Optional[Dict[str, Any]]) -> bool:
        return bool(dialog) and self.sip is not None and \
            dialog["call_id"] in {d["call_id"] for d in self.sip.active_dialogs()}

    def events_since(self, kind: str, since: float) -> List[Dict[str, Any]]:
        if self.sip is None:
            return []
        return [e for e in list(self.sip.events) if e["kind"] == kind and e["t"] >= since]

    def shutdown(self) -> None:
        self.stop_pump()
        if self.sip is not None:
            for dialog in self.sip.active_dialogs():
                try:
                    self.sip.end_dialog(dialog, tolerate_timeout=True)
                except Exception:
                    pass
        try:
            self.ue.detach()
        except Exception:
            pass


@contextlib.contextmanager
def driving(*parties: Party):
    """Stop the pumps of the UEs about to be driven; restart them afterwards."""
    for party in parties:
        party.stop_pump()
    try:
        yield
    finally:
        for party in parties:
            party.start_pump()


class Stage:
    """Builds the parties of one scenario on a shared virtual eNB and cleans up."""

    def __init__(self, args, count: int):
        from .config import Config
        from .s1ap_client import SharedS1APConnection
        if len(args.ue) < count:
            raise ValueError(f"this scenario needs {count} --ue subscribers, got {len(args.ue)}")
        self.conn = SharedS1APConnection(enb_id=Config.ENB_ID_BASE + 0x60 + (args.port % 16),
                                         enb_name=f"{Config.ENB_NAME}-merge")
        self.parties: Dict[str, Party] = {}
        self._args = args
        self._count = count
        self._config = Config

    def up(self, out: dict) -> bool:
        if not self.conn.connect() or not self.conn.s1_setup():
            out["errors"].append("virtual eNB could not connect to the MME (SCTP / S1 Setup)")
            return False
        for index in range(self._count):
            label = LABELS[index]
            party = Party(label, self._args.ue[index],
                          self._config.SIP_LOCAL_PORT_BASE + self._args.port + index,
                          shared_conn=self.conn)
            self.parties[label] = party
            party.bring_up()
        out["setup"] = {label: party.state for label, party in self.parties.items()}
        ready = all(party.state.get("register") for party in self.parties.values())
        if not ready:
            out["errors"].append("not every UE attached and IMS-registered")
        return ready

    def start_pumps(self) -> None:
        for party in self.parties.values():
            party.start_pump()

    def down(self) -> None:
        for party in self.parties.values():
            party.shutdown()
        try:
            self.conn.disconnect()
        except Exception:
            pass

    @property
    def domain(self) -> str:
        return self._config.IMS_DOMAIN


def place_call(caller: Party, callee: Party, video: bool = False) -> Dict[str, Any]:
    """caller dials callee and callee answers. Both pumps are restarted afterwards."""
    box: Dict[str, Any] = {}
    with driving(caller, callee):
        def answer():
            box.update(callee.sip.answer_next_call_capturing(answer_delay=0.3, timeout=25.0))

        thread = threading.Thread(target=answer, daemon=True)
        thread.start()
        time.sleep(0.3)
        dialog = caller.sip.establish_call_dialog(callee.number, sdp_video=video)
        answered_at = time.time()
        thread.join(timeout=45.0)
    result = {
        "ok": bool(dialog) and bool(box.get("dialog")),
        "answered_at": round(answered_at, 1),
        "caller_dialog": dialog,
        "callee_dialog": box.get("dialog"),
        "facts": box.get("facts") or {},
    }
    if not result["ok"]:
        caller_state = "ok" if dialog else \
            (getattr(caller.sip, "_last_error", "") or "INVITE not answered")
        callee_state = "answered" if box.get("dialog") else \
            (getattr(callee.sip, "_last_error", "") or "no call answered")
        result["error"] = f"caller {caller.label}: {caller_state}; callee {callee.label}: {callee_state}"
    return result


def _call_summary(call: Dict[str, Any]) -> Dict[str, Any]:
    caller_id = (call.get("caller_dialog") or {}).get("call_id", "")
    callee_id = (call.get("callee_dialog") or {}).get("call_id", "")
    facts = call.get("facts") or {}
    return {
        "ok": call["ok"],
        "error": call.get("error", ""),
        "answered_at": call.get("answered_at", 0),
        "caller_call_id": caller_id,
        "callee_call_id": callee_id,
        # A B2BUA with topology hiding gives the terminating leg its own Call-ID
        "call_id_changed": bool(caller_id and callee_id and caller_id != callee_id),
        "callee_saw_from": facts.get("from", ""),
        "callee_saw_video": bool(facts.get("has_video")),
        "callee_saw_c_ip": facts.get("c_ip", ""),
        "callee_record_routes": facts.get("record_routes", 0),
    }


def _refer_summary(result: Dict[str, Any]) -> Dict[str, Any]:
    return {
        "status": result.get("status", 0),
        "notify": bool(result.get("notify")),
        "sipfrag": result.get("sipfrag", ""),
        "sipfrag_200": "200" in (result.get("sipfrag", "").split("\n")[0]),
        "subscription_state": result.get("subscription_state", ""),
        "notify_delay": result.get("notify_delay"),
    }


# ---------------------------------------------------------------------------
# Plain calls through the B2BUA
# ---------------------------------------------------------------------------
def act_anchor(args) -> dict:
    out: Dict[str, Any] = {"errors": []}
    stage = Stage(args, 2)
    try:
        if not stage.up(out):
            return out
        a, b = stage.parties["A"], stage.parties["B"]
        stage.start_pumps()

        call = place_call(a, b, video=args.video)
        out["call"] = _call_summary(call)
        if not call["ok"]:
            return out
        a_dialog, b_dialog = call["caller_dialog"], call["callee_dialog"]
        time.sleep(max(1.0, args.talk))

        if args.hold_resume:
            since = time.time()
            with driving(a):
                held = bool(a.sip.hold_dialog(a_dialog))
                time.sleep(0.5)
                resumed = bool(a.sip.resume_dialog(a_dialog))
            time.sleep(0.5)
            out["hold_resume"] = {
                "hold": held, "resume": resumed,
                "callee_reinvites": len(b.events_since("reinvite", since)),
                "both_dialogs_alive": a.has_dialog(a_dialog) and b.has_dialog(b_dialog),
            }

        ender, other, ender_dialog, other_dialog = (
            (b, a, b_dialog, a_dialog) if args.bye_from == "callee" else (a, b, a_dialog, b_dialog))
        since = time.time()
        with driving(ender):
            bye_ok = bool(ender.sip.end_dialog(ender_dialog, tolerate_timeout=True))
        deadline = time.time() + 6.0
        while time.time() < deadline and other.has_dialog(other_dialog):
            time.sleep(0.2)
        out["release"] = {
            "by": args.bye_from, "bye_ok": bye_ok,
            "at": round(since, 1),
            "talk_seconds": round(since - call.get("answered_at", since), 1),
            "peer_got_bye": bool(other.events_since("bye", since)),
            "peer_released": not other.has_dialog(other_dialog),
        }
        return out
    finally:
        stage.down()


def _ring_scenario(args, mode: str, cancel_after: float) -> dict:
    out: Dict[str, Any] = {"errors": []}
    stage = Stage(args, 2)
    try:
        if not stage.up(out):
            return out
        a, b = stage.parties["A"], stage.parties["B"]
        box: Dict[str, Any] = {}

        def ring():
            box.update(b.sip.ring_next_call(mode=mode, timeout=30.0))

        thread = threading.Thread(target=ring, daemon=True)
        thread.start()
        time.sleep(0.3)
        out["caller"] = a.sip.invite_and_cancel(b.number, cancel_after=cancel_after)
        thread.join(timeout=60.0)
        box.pop("invite_headers", None)
        out["callee"] = box
        return out
    finally:
        stage.down()


def act_cancel(args) -> dict:
    return _ring_scenario(args, "cancel", 2.0)


def act_reject(args) -> dict:
    # Long cancel_after: the caller must hear the callee's 486 before it would cancel
    return _ring_scenario(args, "reject", 15.0)


def act_unreachable(args) -> dict:
    out: Dict[str, Any] = {"errors": []}
    stage = Stage(args, 1)
    try:
        if not stage.up(out):
            return out
        started = time.time()
        out["caller"] = stage.parties["A"].sip.invite_and_cancel(args.target, cancel_after=20.0)
        out["seconds"] = round(time.time() - started, 1)
        return out
    finally:
        stage.down()


# ---------------------------------------------------------------------------
# Conference factory and merge
# ---------------------------------------------------------------------------
def act_factory(args) -> dict:
    out: Dict[str, Any] = {"errors": []}
    stage = Stage(args, 1)
    try:
        if not stage.up(out):
            return out
        a = stage.parties["A"]
        focus = a.sip.start_conference_focus(video=args.video)
        out["focus"] = {"ok": bool(focus)}
        if not focus:
            out["focus"]["error"] = a.ue.metrics.error_message or "factory INVITE not answered"
            return out
        room = "merge-" + focus["local_tag"]
        time.sleep(1.0)
        out["focus"].update(room=room, tag=focus["local_tag"], call_id=focus["call_id"],
                            room_count=room_count(room))
        if args.subscribe:
            out["subscribe_status"] = a.sip.subscribe_in_dialog(focus)
        out["bye_ok"] = bool(a.sip.end_dialog(focus, tolerate_timeout=True))
        time.sleep(2.0)
        out["room_count_after"] = room_count(room)
        return out
    finally:
        stage.down()


def act_merge(args) -> dict:
    out: Dict[str, Any] = {"errors": []}
    count = 1 + args.parties
    if args.join:
        count = max(count, 4)
    stage = Stage(args, count)
    try:
        if not stage.up(out):
            return out
        a = stage.parties["A"]
        far = [stage.parties[LABELS[i]] for i in range(1, 1 + args.parties)]
        stage.start_pumps()

        # --- the ordinary calls, one after the other; the previous one goes on hold ---
        calls: List[Dict[str, Any]] = []
        out["calls"] = []
        for index, party in enumerate(far):
            if calls:
                with driving(a):
                    calls[-1]["held"] = bool(a.sip.hold_dialog(calls[-1]["a_dialog"]))
            inbound = args.direction == "in" and index == 0 or \
                args.direction == "mixed" and index % 2 == 0
            call = place_call(party, a, args.video) if inbound else place_call(a, party, args.video)
            summary = _call_summary(call)
            summary.update(party=party.label, direction="in" if inbound else "out")
            out["calls"].append(summary)
            if not call["ok"]:
                out["errors"].append(f"call with {party.label} was not established")
                return out
            calls.append({
                "party": party,
                "a_dialog": call["callee_dialog"] if inbound else call["caller_dialog"],
                "p_dialog": call["caller_dialog"] if inbound else call["callee_dialog"],
            })
            time.sleep(0.5)

        # --- "Merge": hold the active call, dial the factory ---
        with driving(a):
            calls[-1]["held"] = bool(a.sip.hold_dialog(calls[-1]["a_dialog"]))
            focus = a.sip.start_conference_focus(video=args.video)
        out["holds"] = [bool(c.get("held")) for c in calls]
        out["focus"] = {"ok": bool(focus)}
        if not focus:
            out["focus"]["error"] = a.ue.metrics.error_message or "factory INVITE not answered"
            out["errors"].append("conference focus was not established")
            return out
        room = "merge-" + focus["local_tag"]
        time.sleep(1.0)
        out["focus"].update(room=room, tag=focus["local_tag"], call_id=focus["call_id"],
                            room_count=room_count(room))

        def calls_intact() -> bool:
            return all(a.has_dialog(c["a_dialog"]) and c["party"].has_dialog(c["p_dialog"])
                       for c in calls)

        if args.subscribe:
            with driving(a):
                out["subscribe_status"] = a.sip.subscribe_in_dialog(focus)

        # --- negative probes on the focus, before anything is merged ---
        bad = [item for item in (args.bad_refer or "").split(",") if item]
        if "noreplaces" in bad:
            with driving(a):
                result = a.sip.refer(focus, f"<sip:{far[0].number}@{stage.domain}>", notify_wait=3.0)
            out["refer_no_replaces"] = dict(_refer_summary(result), room_count=room_count(room),
                                            calls_intact=calls_intact(),
                                            focus_alive=a.has_dialog(focus))
        if "bogus" in bad:
            ghost = {"call_id": "0000000000000000@ue-sim", "remote_tag": "nosuchtag1",
                     "local_tag": "nosuchtag2"}
            with driving(a):
                result = a.sip.refer(focus, a.sip.merge_refer_to(ghost, far[0].number),
                                     notify_wait=6.0)
            time.sleep(1.0)
            out["refer_bogus_replaces"] = dict(_refer_summary(result), room_count=room_count(room),
                                               calls_intact=calls_intact(),
                                               focus_alive=a.has_dialog(focus))
        if args.drop_unknown:
            with driving(a):
                result = a.sip.drop_participant(focus, "99900011122233")
            out["drop_unknown"] = dict(_refer_summary(result), room_count=room_count(room),
                                       calls_intact=calls_intact(),
                                       focus_alive=a.has_dialog(focus))

        # --- one REFER per call, serialised like the handset does ---
        out["merges"] = []
        for call in calls:
            party = call["party"]
            since = time.time()
            with driving(a):
                result = a.sip.merge_call(focus, call["a_dialog"], party.number)
            time.sleep(1.5)
            reinvites = party.events_since("reinvite", since)
            merged = _refer_summary(result)
            merged.update(
                party=party.label,
                at=round(since, 1),
                absorbed_leg_released=bool(result.get("absorbed_leg_released")),
                party_reinvited=bool(reinvites),
                party_reinvite_video=any(e.get("has_video") for e in reinvites),
                party_reinvite_c_ip=reinvites[-1].get("c_ip", "") if reinvites else "",
                party_dialog_alive=party.has_dialog(call["p_dialog"]),
                room_count=room_count(room),
            )
            out["merges"].append(merged)
        out["focus_alive_after_merge"] = a.has_dialog(focus)
        out["room_after_merge"] = room_count(room)
        if args.conf_hold > 0:
            time.sleep(args.conf_hold)      # everybody stays in the conference a while

        # --- a participant presses Merge: B adds D to the conference it is already in ---
        if args.join:
            joiner, newcomer = far[0], stage.parties["D"]
            own_leg = dict(calls[0]["p_dialog"])
            join: Dict[str, Any] = {}
            out["join"] = join
            with driving(joiner):
                join["own_leg_hold"] = bool(joiner.sip.hold_dialog(calls[0]["p_dialog"]))
            call = place_call(joiner, newcomer)
            join["call"] = _call_summary(call)
            if call["ok"]:
                focus2 = None
                with driving(joiner):
                    joiner.sip.hold_dialog(call["caller_dialog"])
                    time.sleep(0.5)
                    since = time.time()   # after the hold, so only the room re-INVITE counts
                    focus2 = joiner.sip.start_conference_focus()
                    join["focus_ok"] = bool(focus2)
                    if focus2:
                        # Like the initiator's flow: let the focus dialog settle before the
                        # first REFER. Sent right behind the ACK it was answered 500 before
                        # it ever reached the AS (live run 2026-10-06).
                        joiner.sip.pump(1.5)
                        # The handset REFERs both of its calls: the new party, then its
                        # own leg into the room (which the AS retires instead of bridging).
                        first = joiner.sip.merge_call(focus2, call["caller_dialog"], newcomer.number)
                        second = joiner.sip.merge_call(focus2, own_leg, a.number)
                        join["refer_new_party"] = _refer_summary(first)
                        join["refer_own_leg"] = _refer_summary(second)
                time.sleep(2.0)
                if join.get("focus_ok"):
                    join.update(
                        own_room=("merge-" + focus2["local_tag"]),
                        own_room_count=room_count("merge-" + focus2["local_tag"]),
                        old_leg_released=not joiner.has_dialog(own_leg),
                        joiner_focus_alive=joiner.has_dialog(focus2),
                        newcomer_reinvited=bool(newcomer.events_since("reinvite", since)),
                        newcomer_dialog_alive=newcomer.has_dialog(call["callee_dialog"]),
                        room_count=room_count(room),
                    )
                    calls.append({"party": newcomer, "a_dialog": None,
                                  "p_dialog": call["callee_dialog"]})
                    calls[0]["p_dialog"] = focus2

        # --- Drop button: A removes the last party ---
        if args.drop:
            target = calls[-1]["party"]
            before = room_count(room)
            since = time.time()
            used = target.number
            with driving(a):
                result = a.sip.drop_participant(focus, used)
                if result.get("status") == 404 and target.spec["msisdn"] != used:
                    used = target.spec["msisdn"]
                    result = a.sip.drop_participant(focus, used)
            time.sleep(2.0)
            out["drop"] = dict(
                _refer_summary(result), target=target.label, number_used=used,
                room_before=before, room_count=room_count(room),
                target_got_bye=bool(target.events_since("bye", since)),
                target_released=not target.has_dialog(calls[-1]["p_dialog"]),
                focus_alive=a.has_dialog(focus),
                others_alive=all(c["party"].has_dialog(c["p_dialog"]) for c in calls[:-1]),
            )
            calls.pop()

        # --- a participant hangs up by itself ---
        if args.leave and calls:
            leaver = calls[0]
            before = room_count(room)
            with driving(leaver["party"]):
                bye_ok = bool(leaver["party"].sip.end_dialog(leaver["p_dialog"],
                                                            tolerate_timeout=True))
            time.sleep(2.0)
            out["leave"] = {
                "party": leaver["party"].label, "bye_ok": bye_ok,
                "room_before": before, "room_count": room_count(room),
                "focus_alive": a.has_dialog(focus),
                "others_alive": all(c["party"].has_dialog(c["p_dialog"]) for c in calls[1:]),
            }
            calls.pop(0)

        # --- the initiator ends the conference ---
        since = time.time()
        with driving(a):
            bye_ok = bool(a.sip.end_dialog(focus, tolerate_timeout=True))
        deadline = time.time() + 8.0
        while time.time() < deadline and \
                any(c["party"].has_dialog(c["p_dialog"]) for c in calls):
            time.sleep(0.3)
        out["teardown"] = {
            "focus_bye": bye_ok,
            "parties_released": {c["party"].label: not c["party"].has_dialog(c["p_dialog"])
                                 for c in calls},
            "parties_got_bye": {c["party"].label: bool(c["party"].events_since("bye", since))
                                for c in calls},
            "room_count": room_count(room),
        }
        return out
    finally:
        stage.down()


def act_dialin(args) -> dict:
    """UEs join a dial-in room one by one; reports who joined when and for how long."""
    out: Dict[str, Any] = {"errors": [], "room": args.room}
    stage = Stage(args, args.count)
    try:
        if not stage.up(out):
            return out
        members: List[Dict[str, Any]] = []
        out["members"] = members
        joined = []
        for index in range(args.count):
            party = stage.parties[LABELS[index]]
            dialog = party.sip.establish_call_dialog(args.room, sdp_video=args.video)
            entry = {"label": party.label, "number": party.number, "ok": bool(dialog),
                     "joined_at": int(time.time())}
            members.append(entry)
            if not dialog:
                entry["error"] = getattr(party.sip, "_last_error", "") or "INVITE not answered"
                out["errors"].append(f"{party.label} could not join room {args.room}")
                continue
            joined.append((party, dialog, entry))
            party.start_pump()
            if index < args.count - 1:
                time.sleep(args.stagger)
        time.sleep(args.hold)
        out["room_count"] = room_count(args.room)
        for party, dialog, entry in joined:
            with driving(party):
                entry["still_in_call"] = party.has_dialog(dialog)
                entry["bye_ok"] = bool(party.sip.end_dialog(dialog, tolerate_timeout=True))
            entry["left_at"] = int(time.time())
            entry["seconds"] = entry["left_at"] - entry["joined_at"]
        time.sleep(2.0)
        out["room_count_after"] = room_count(args.room)
        return out
    finally:
        stage.down()


ACTIONS = {
    "dialin": act_dialin,
    "anchor": act_anchor, "cancel": act_cancel, "reject": act_reject,
    "unreachable": act_unreachable, "factory": act_factory, "merge": act_merge,
}


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(prog="merge_scenarios")
    parser.add_argument("action", choices=sorted(ACTIONS))
    parser.add_argument("--ue", type=_spec, action="append", default=None,
                        help="repeat: A, B, C, D (dialin: optional, default = fixed subscribers)")
    parser.add_argument("--room", default="1018")
    parser.add_argument("--count", type=int, choices=(1, 2, 3), default=3)
    parser.add_argument("--stagger", type=float, default=4.0)
    parser.add_argument("--hold", type=float, default=6.0)
    parser.add_argument("--port", type=int, default=100,
                        help="offset added to SIP_LOCAL_PORT_BASE for A (B = +1 ...)")
    parser.add_argument("--video", action="store_true")
    parser.add_argument("--hold-resume", action="store_true")
    parser.add_argument("--talk", type=float, default=1.0,
                        help="anchor: seconds the call stays up before it is released")
    parser.add_argument("--conf-hold", type=float, default=0.0,
                        help="merge: seconds everybody stays in the conference after the merges")
    parser.add_argument("--bye-from", choices=("caller", "callee"), default="caller")
    parser.add_argument("--target", default="")
    parser.add_argument("--parties", type=int, choices=(1, 2, 3), default=2)
    parser.add_argument("--direction", choices=("out", "in", "mixed"), default="out")
    parser.add_argument("--subscribe", action="store_true")
    parser.add_argument("--bad-refer", default="")
    parser.add_argument("--drop-unknown", action="store_true")
    parser.add_argument("--join", action="store_true")
    parser.add_argument("--drop", action="store_true")
    parser.add_argument("--leave", action="store_true")
    parser.add_argument("--log-file", default="",
                        help="write the simulator's INFO log here (for diagnosis)")
    args = parser.parse_args(argv)

    if args.log_file:
        logging.basicConfig(filename=args.log_file, filemode="w", level=logging.INFO,
                            format="%(asctime)s %(threadName)s %(name)s %(levelname)s %(message)s")
    else:
        logging.basicConfig(level=logging.CRITICAL, stream=sys.stderr)
        logging.disable(logging.ERROR)

    if not args.ue:
        if args.action != "dialin":
            parser.error("--ue is required for this action")
        from .config import Config
        args.ue = [{"imsi": sub.imsi, "ki": sub.ki, "opc": sub.opc, "amf": sub.amf,
                    "msisdn": sub.msisdn} for sub in Config.default_subscribers()]
    if args.action == "unreachable" and not args.target:
        parser.error("unreachable needs --target")

    try:
        result = ACTIONS[args.action](args)
    except Exception as exc:  # always hand the feature script a JSON object
        result = {"errors": [f"{type(exc).__name__}: {exc}"]}
    result["action"] = args.action
    print(json.dumps(result, default=str))
    return 0


if __name__ == "__main__":
    sys.exit(main())
