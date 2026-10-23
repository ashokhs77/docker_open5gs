"""
Supplementary-service additions for SIPClient (mixed in by sip_client.SIPClient).

Adds what the call-merge tests need on top of the existing multi-dialog support:

  pump()                 serve every tracked dialog for a while (answer re-INVITE,
                         UPDATE, BYE, NOTIFY ...) and record what arrived
  refer()                in-dialog REFER, then wait for the refer NOTIFY
  merge_refer_to() / drop_refer_to()
                         Refer-To values the way a handset builds them
  subscribe_in_dialog()  conference roster SUBSCRIBE
  start_conference_focus() / merge_call() / drop_participant()
                         the handset's "Merge" and "Drop" buttons
  invite_and_cancel()    caller hangs up while the callee is ringing
  ring_next_call()       callee rings and then waits for CANCEL or rejects

The client stays single-threaded per UE: a UE only reads its socket while one of
its methods runs, so a participant that must react to the network (the far party
being re-anchored into a conference) has to sit in pump() on its own thread.

Everything that arrives outside the transaction being waited on goes through
_handle_async_request() and is appended to `events`, which is what the tests
assert on.
"""

import logging
import re
import time
from typing import Any, Callable, Dict, List, Optional

from .config import Config

logger = logging.getLogger(__name__)


class SupplementaryMixin:
    """Requires the SIPClient attributes/methods; adds no state of its own up front."""

    # ------------------------------------------------------------------
    # Event log
    # ------------------------------------------------------------------
    @property
    def events(self) -> List[Dict[str, Any]]:
        """Requests received outside the foreground transaction, oldest first."""
        if not hasattr(self, "_supp_events"):
            self._supp_events = []
        return self._supp_events

    def clear_events(self) -> None:
        self._supp_events = []

    def events_of(self, kind: str, call_id: Optional[str] = None) -> List[Dict[str, Any]]:
        return [e for e in self.events
                if e["kind"] == kind and (call_id is None or e["call_id"] == call_id)]

    def _record_event(self, kind: str, message: str, **extra: Any) -> Dict[str, Any]:
        event = {
            "t": time.time(),
            "kind": kind,
            "call_id": self._extract_header(message, "Call-ID") or "",
            "cseq": self._extract_header(message, "CSeq") or "",
        }
        event.update(extra)
        self.events.append(event)
        return event

    @staticmethod
    def _sdp_facts(body: str) -> Dict[str, Any]:
        """The parts of an SDP the tests look at."""
        conn = re.search(r"^c=IN IP4 (\S+)", body, re.M)
        audio = re.search(r"^m=audio (\d+)", body, re.M)
        video = re.search(r"^m=video (\d+)", body, re.M)
        return {
            "has_sdp": bool(body.strip()),
            "c_ip": conn.group(1) if conn else "",
            "audio_port": int(audio.group(1)) if audio else 0,
            "video_port": int(video.group(1)) if video else 0,
            "has_video": bool(video and int(video.group(1)) > 0),
        }

    # ------------------------------------------------------------------
    # Requests that arrive while we are doing something else
    # ------------------------------------------------------------------
    def _handle_async_request(self, message: str) -> str:
        """
        Answer a request that is not the transaction currently being waited on.
        Returns the method handled, or "" when the message is a response.
        """
        method = self._parse_request_method(message)
        if not method:
            return ""

        call_id = self._extract_header(message, "Call-ID") or ""
        dialog = self._dialogs.get(call_id)
        local_tag = dialog.get("local_tag", "") if dialog else ""

        if method == "INVITE":
            to_header = self._extract_header(message, "To") or ""
            if self._extract_tag(to_header) or dialog:
                facts = self._sdp_facts(self._extract_body(message))
                self._record_event(
                    "reinvite", message,
                    known_dialog=bool(dialog),
                    session_expires=self._extract_header(message, "Session-Expires") or "",
                    supported=self._extract_header(message, "Supported") or "",
                    **facts,
                )
                self._answer_waiting_in_dialog_invite(message, call_id)
            else:
                # A new call while this UE is busy serving others: refuse it cleanly
                # rather than leave the network retransmitting.
                self._record_event("new_invite_refused", message)
                self._send_sip(self._build_response(message, 486, "Busy Here",
                                                    local_tag=self._generate_tag()))
        elif method == "ACK":
            self._record_event("ack", message)
        elif method == "BYE":
            self._record_event("bye", message, known_dialog=bool(dialog))
            self._answer_in_dialog_bye(message, call_id)
        elif method == "NOTIFY":
            self._record_event(
                "notify", message,
                event=self._extract_header(message, "Event") or "",
                subscription_state=self._extract_header(message, "Subscription-State") or "",
                body=self._extract_body(message).strip(),
            )
            self._send_sip(self._build_response(message, 200, "OK", local_tag=local_tag))
        elif method == "UPDATE":
            body = self._extract_body(message)
            self._record_event(
                "update", message,
                session_expires=self._extract_header(message, "Session-Expires") or "",
                **self._sdp_facts(body),
            )
            if body.strip():
                self._send_sip(self._build_response(
                    message, 200, "OK", local_tag=local_tag,
                    contact_uri=self._contact_uri,
                    body=self._build_sdp(video="m=video" in body,
                                         direction=self._sdp_direction_for_offer(body)),
                    content_type="application/sdp"))
            else:
                self._send_sip(self._build_response(message, 200, "OK", local_tag=local_tag,
                                                    contact_uri=self._contact_uri))
        elif method == "CANCEL":
            self._record_event("cancel", message)
            self._send_sip(self._build_response(message, 481,
                                                "Call/Transaction Does Not Exist"))
        elif method == "PRACK":
            self._record_event("prack", message)
            self._send_sip(self._build_response(message, 200, "OK", local_tag=local_tag))
        else:
            # OPTIONS, INFO, MESSAGE, ...
            self._record_event(method.lower(), message)
            self._send_sip(self._build_response(message, 200, "OK", local_tag=local_tag))
        return method

    def pump(self, duration: float, until: Optional[Callable[[], bool]] = None) -> None:
        """Serve all dialogs for `duration` seconds, or until `until()` is true."""
        deadline = time.time() + duration
        while time.time() < deadline:
            if until is not None and until():
                return
            message = self._receive_sip(timeout=0.5)
            if message:
                self._handle_async_request(message)

    def wait_for_event(self, kind: str, call_id: Optional[str] = None,
                       timeout: float = None, since: float = 0.0) -> Optional[Dict[str, Any]]:
        """Pump until an event of `kind` (newer than `since`) exists; return it or None."""
        def found():
            for event in self.events_of(kind, call_id):
                if event["t"] >= since:
                    return event
            return None

        self.pump(timeout if timeout is not None else Config.SIP_TIMEOUT,
                  until=lambda: found() is not None)
        return found()

    # ------------------------------------------------------------------
    # In-dialog requests
    # ------------------------------------------------------------------
    def _build_in_dialog_request(self, dialog: Dict[str, Any], method: str,
                                 extra_headers: str = "", body: str = "",
                                 content_type: str = "") -> str:
        """Same layout as _build_refer(); CSeq must already be incremented."""
        msg = f"{method} {dialog['remote_target'] or dialog['target_uri']} SIP/2.0\r\n"
        msg += (f"Via: SIP/2.0/UDP {self._local_ip}:{self._local_port};"
                f"branch={self._generate_branch()};rport\r\n")
        for route in dialog.get("route_set") or []:
            msg += f"Route: {route}\r\n"
        msg += "Max-Forwards: 70\r\n"
        msg += f"From: <{self._sip_uri}>;tag={dialog['local_tag']}\r\n"
        msg += f"To: <{dialog['target_uri']}>;tag={dialog['remote_tag']}\r\n"
        msg += f"Call-ID: {dialog['call_id']}\r\n"
        msg += f"CSeq: {self._cseq} {method}\r\n"
        msg += f"Contact: <{self._contact_uri}>\r\n"
        msg += extra_headers
        if body and content_type:
            msg += f"Content-Type: {content_type}\r\n"
        msg += f"Content-Length: {len(body)}\r\n\r\n"
        msg += body
        return msg

    def _await_final_response(self, call_id: str, method: str, cseq: int,
                              timeout: float) -> int:
        """Wait for the final response of one transaction, serving everything else."""
        deadline = time.time() + timeout
        while time.time() < deadline:
            message = self._receive_sip(timeout=1.0)
            if not message:
                continue
            if self._handle_async_request(message):
                continue
            if not self._response_matches(message, call_id, method, cseq):
                continue
            status = self._parse_status_code(message)
            if status >= 200:
                return status
        return 0

    def refer(self, dialog: Dict[str, Any], refer_to: str,
              notify_wait: float = 10.0) -> Dict[str, Any]:
        """
        Send an in-dialog REFER and wait for its refer-event NOTIFY.

        Returns {"status": final code or 0, "notify": bool, "sipfrag": str,
                 "subscription_state": str, "notify_delay": seconds or None}.
        Other dialogs keep being served meanwhile: during a merge the absorbed
        call is released while this REFER is still in progress.
        """
        self._cseq += 1
        cseq = self._cseq
        sent_at = time.time()
        self._send_sip(self._build_refer(dialog=dialog, refer_to=refer_to))

        result = {"status": 0, "notify": False, "sipfrag": "",
                  "subscription_state": "", "notify_delay": None}
        deadline = time.time() + Config.SIP_TIMEOUT * 2
        notify_deadline = None
        while time.time() < deadline:
            if notify_deadline is not None and time.time() >= notify_deadline:
                break
            message = self._receive_sip(timeout=1.0)
            if not message:
                continue

            method = self._handle_async_request(message)
            if method:
                if method == "NOTIFY" and \
                        (self._extract_header(message, "Call-ID") or "") == dialog["call_id"]:
                    event = self.events_of("notify", dialog["call_id"])[-1]
                    result.update(notify=True, sipfrag=event["body"],
                                  subscription_state=event["subscription_state"],
                                  notify_delay=round(time.time() - sent_at, 2))
                    if result["status"]:
                        break
                continue

            if not self._response_matches(message, dialog["call_id"], "REFER", cseq):
                continue
            status = self._parse_status_code(message)
            if status < 200:
                continue
            result["status"] = status
            if status >= 300 or result["notify"]:
                break
            notify_deadline = time.time() + notify_wait
        return result

    def merge_refer_to(self, replaced_dialog: Dict[str, Any], target_msisdn: str) -> str:
        """Refer-To for "merge this call": the party's URI with ?Replaces=<dialog>."""
        return self._build_refer_to(target_msisdn, replaced_dialog)

    def drop_refer_to(self, number: str) -> str:
        """Refer-To for the handset's per-participant Drop button (method=BYE, no Replaces)."""
        return f"<sip:{number}@{self._ims_domain};method=BYE>"

    def subscribe_in_dialog(self, dialog: Dict[str, Any], event: str = "conference") -> int:
        """Send the conference roster SUBSCRIBE on a dialog; return the final status."""
        self._cseq += 1
        cseq = self._cseq
        headers = (f"Event: {event}\r\n"
                   "Expires: 3600\r\n"
                   "Accept: application/conference-info+xml\r\n")
        self._send_sip(self._build_in_dialog_request(dialog, "SUBSCRIBE", headers))
        return self._await_final_response(dialog["call_id"], "SUBSCRIBE", cseq,
                                          Config.SIP_TIMEOUT)

    # ------------------------------------------------------------------
    # The handset's Merge / Drop buttons
    # ------------------------------------------------------------------
    def conference_factory_uri(self) -> str:
        return f"sip:mmtel@conf-factory.{self._ims_domain}"

    def start_conference_focus(self, video: bool = False) -> Optional[Dict[str, Any]]:
        """Dial the conference factory; the returned dialog is the focus leg."""
        return self.establish_call_dialog(self.conference_factory_uri(), sdp_video=video)

    def merge_call(self, focus_dialog: Dict[str, Any], call_dialog: Dict[str, Any],
                   party_msisdn: str, notify_wait: float = 10.0) -> Dict[str, Any]:
        """
        Move one existing call into the conference: REFER on the focus dialog with
        Replaces naming the call. The network re-INVITEs the far party into the room
        and releases our leg of that call.
        """
        result = self.refer(focus_dialog, self.merge_refer_to(call_dialog, party_msisdn),
                            notify_wait=notify_wait)
        # The absorbed leg is released by the network (BYE) around the NOTIFY; give a
        # late BYE a moment so the caller sees a settled state.
        if call_dialog["call_id"] in self._dialogs:
            self.pump(3.0, until=lambda: call_dialog["call_id"] not in self._dialogs)
        result["absorbed_leg_released"] = call_dialog["call_id"] not in self._dialogs
        return result

    def drop_participant(self, focus_dialog: Dict[str, Any], number: str) -> Dict[str, Any]:
        """Drop one participant from the conference (REFER ... ;method=BYE)."""
        return self.refer(focus_dialog, self.drop_refer_to(number), notify_wait=6.0)

    # ------------------------------------------------------------------
    # CANCEL while ringing, and a callee that rings without answering
    # ------------------------------------------------------------------
    def invite_and_cancel(self, target_msisdn: str, cancel_after: float = 2.0,
                          sdp_video: bool = False) -> Dict[str, Any]:
        """
        Start a call, wait for ringing, then CANCEL it.

        Returns {"ringing": bool, "cancel_status": code, "final": code,
                 "answered_instead": bool}. A clean cancel is 200 for the CANCEL and
        487 for the INVITE.
        """
        result = {"ringing": False, "cancel_status": 0, "final": 0,
                  "answered_instead": False}
        if not self._registered:
            self._set_last_error("Not registered, cannot place a call")
            return result

        target_uri = self._build_target_uri(target_msisdn)
        call_id = self._generate_call_id()
        local_tag = self._generate_tag()
        self._cseq += 1
        invite_cseq = self._cseq
        route_set = list(self._service_route_set)
        invite = self._build_invite(target_uri=target_uri, call_id=call_id,
                                    local_tag=local_tag,
                                    sdp=self._build_sdp(video=sdp_video),
                                    route_set=route_set)
        via_line = next((line for line in invite.split("\r\n") if line.startswith("Via:")), "")
        self._send_sip(invite)

        def transaction_request(method: str, remote_tag: str = "") -> str:
            # CANCEL and the ACK for a failure reply reuse the INVITE's branch
            msg = f"{method} {target_uri} SIP/2.0\r\n{via_line}\r\n"
            for route in route_set:
                msg += f"Route: {route}\r\n"
            msg += "Max-Forwards: 70\r\n"
            msg += f"From: <{self._sip_uri}>;tag={local_tag}\r\n"
            msg += f"To: <{target_uri}>" + (f";tag={remote_tag}" if remote_tag else "") + "\r\n"
            msg += f"Call-ID: {call_id}\r\n"
            msg += f"CSeq: {invite_cseq} {method}\r\n"
            msg += "Content-Length: 0\r\n\r\n"
            return msg

        started = time.time()
        cancelled = False
        deadline = started + Config.SIP_TIMEOUT * 3
        while time.time() < deadline:
            # Cancel once ringing has lasted cancel_after, or after a grace period
            # even without a 180 (the call is still pending in the network).
            ringing_long_enough = result["ringing"] and time.time() - started >= cancel_after
            waited_without_ringing = time.time() - started >= cancel_after + Config.SIP_TIMEOUT
            if not cancelled and (ringing_long_enough or waited_without_ringing):
                self._send_sip(transaction_request("CANCEL"))
                cancelled = True

            message = self._receive_sip(timeout=0.5)
            if not message:
                continue
            if self._handle_async_request(message):
                continue
            if (self._extract_header(message, "Call-ID") or "") != call_id:
                continue

            status = self._parse_status_code(message)
            cseq_header = (self._extract_header(message, "CSeq") or "").upper()
            if "CANCEL" in cseq_header:
                if status >= 200:
                    result["cancel_status"] = status
                continue
            if "INVITE" not in cseq_header:
                continue
            if status in (180, 183):
                result["ringing"] = True
                continue
            if status == 200:
                # The callee answered before the CANCEL took effect: accept and hang up
                result["answered_instead"] = True
                remote_tag = self._extract_tag(self._extract_header(message, "To") or "")
                contact = self._extract_header(message, "Contact") or ""
                dialog = {
                    "call_id": call_id, "local_tag": local_tag, "remote_tag": remote_tag,
                    "target_uri": target_uri,
                    "remote_target": self._extract_uri(contact) or target_uri,
                    "route_set": list(reversed(self._extract_record_routes(message))) or route_set,
                    "video": sdp_video,
                }
                self._send_sip(self._build_ack(
                    target_uri=dialog["remote_target"], call_id=call_id,
                    local_tag=local_tag, remote_tag=remote_tag,
                    ack_cseq=invite_cseq, route_set=dialog["route_set"]))
                self._send_bye_for_dialog(dialog, tolerate_timeout=True)
                result["final"] = 200
                return result
            if status >= 300:
                result["final"] = status
                remote_tag = self._extract_tag(self._extract_header(message, "To") or "")
                self._send_sip(transaction_request("ACK", remote_tag))
                return result
        self._set_last_error("No final response after CANCEL")
        return result

    def ring_next_call(self, mode: str = "cancel", reject_code: int = 486,
                       reject_reason: str = "Busy Here",
                       timeout: float = None) -> Dict[str, Any]:
        """
        Let the next incoming call ring without answering it.

        mode "cancel": wait for the caller's CANCEL, answer it and send 487.
        mode "reject": ring briefly, then reject with reject_code.

        Returns {"invite": bool, "cancel": bool, "final_sent": code, "ack": bool,
                 "ring_seconds": float, "invite_headers": {...}}.
        """
        timeout = timeout if timeout is not None else Config.SIP_TIMEOUT * 3
        result = {"invite": False, "cancel": False, "final_sent": 0, "ack": False,
                  "ring_seconds": 0.0, "invite_headers": {}}

        invite = self._wait_for_incoming_invite(timeout)
        if not invite:
            self._set_last_error("No incoming INVITE received before timeout")
            return result
        result["invite"] = True
        result["invite_headers"] = self.incoming_invite_facts(invite)
        call_id = self._extract_header(invite, "Call-ID") or ""
        local_tag = self._generate_tag()

        self._send_sip(self._build_response(invite, 100, "Trying", local_tag=local_tag))
        self._send_sip(self._build_response(invite, 180, "Ringing", local_tag=local_tag,
                                            contact_header=self._contact_header_invite))
        rang_at = time.time()

        def send_final(code: int, reason: str) -> None:
            self._send_sip(self._build_response(invite, code, reason, local_tag=local_tag))
            result["final_sent"] = code
            ack_deadline = time.time() + Config.SIP_TIMEOUT
            while time.time() < ack_deadline:
                message = self._receive_sip(timeout=1.0)
                if not message:
                    continue
                if (self._extract_header(message, "Call-ID") or "") == call_id and \
                        self._parse_request_method(message) == "ACK":
                    result["ack"] = True
                    return
                self._handle_async_request(message)

        if mode == "reject":
            time.sleep(0.5)
            result["ring_seconds"] = round(time.time() - rang_at, 2)
            send_final(reject_code, reject_reason)
            return result

        deadline = time.time() + timeout
        while time.time() < deadline:
            message = self._receive_sip(timeout=1.0)
            if not message:
                continue
            if (self._extract_header(message, "Call-ID") or "") == call_id and \
                    self._parse_request_method(message) == "CANCEL":
                result["cancel"] = True
                result["ring_seconds"] = round(time.time() - rang_at, 2)
                self._send_sip(self._build_response(message, 200, "OK", local_tag=local_tag))
                send_final(487, "Request Terminated")
                return result
            if (self._extract_header(message, "Call-ID") or "") == call_id and \
                    self._parse_request_method(message) == "INVITE":
                continue  # INVITE retransmission while ringing
            self._handle_async_request(message)

        # Nobody cancelled: stop ringing so the network does not keep the call pending
        result["ring_seconds"] = round(time.time() - rang_at, 2)
        send_final(480, "Temporarily Unavailable")
        return result

    def incoming_invite_facts(self, invite: str) -> Dict[str, Any]:
        """Headers of an incoming INVITE that the anchoring tests assert on."""
        contact = self._extract_header(invite, "Contact") or ""
        return {
            "call_id": self._extract_header(invite, "Call-ID") or "",
            "from": self._extract_header(invite, "From") or "",
            "contact": contact,
            "contact_has_mmtel": "3gpp-service.ims.icsi.mmtel" in contact,
            "p_asserted_identity": self._extract_header(invite, "P-Asserted-Identity") or "",
            "supported": self._extract_header(invite, "Supported") or "",
            "require": self._extract_header(invite, "Require") or "",
            "user_agent": self._extract_header(invite, "User-Agent") or "",
            "session_expires": self._extract_header(invite, "Session-Expires") or "",
            "record_routes": len(self._extract_record_routes(invite)),
            **self._sdp_facts(self._extract_body(invite)),
        }

    def answer_next_call_capturing(self, answer_delay: float = 0.3,
                                   timeout: float = None) -> Dict[str, Any]:
        """
        Answer the next incoming call and also return what its INVITE looked like.

        Returns {"dialog": dialog or None, "facts": incoming_invite_facts or {}}.
        """
        result = {"dialog": None, "facts": {}}
        invite = self._wait_for_incoming_invite(timeout or Config.SIP_TIMEOUT * 3)
        if not invite:
            self._set_last_error("No incoming INVITE received before timeout")
            return result
        result["facts"] = self.incoming_invite_facts(invite)
        dialog = self._answer_incoming_dialog(invite, answer_delay=answer_delay)
        if not dialog:
            self._set_last_error("Incoming INVITE could not be answered")
            return result

        ack_deadline = time.time() + Config.SIP_TIMEOUT
        while time.time() < ack_deadline:
            message = self._receive_sip(timeout=1.0)
            if not message:
                continue
            if (self._extract_header(message, "Call-ID") or "") != dialog["call_id"]:
                self._handle_async_request(message)
                continue
            method = self._parse_request_method(message)
            if method == "ACK":
                self._remember_dialog(dialog)
                self._in_call = True
                result["dialog"] = dialog
                return result
            if method == "PRACK":
                self._send_sip(self._build_response(message, 200, "OK",
                                                    local_tag=dialog["local_tag"]))
            elif method == "BYE":
                self._send_sip(self._build_response(message, 200, "OK",
                                                    local_tag=dialog["local_tag"]))
                return result
        self._set_last_error("Answered call dialog was not ACKed")
        return result
