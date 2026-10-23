"""
Scenario driver for the sim_algo feature (features/31_sim_algo.sh).

    cd /opt/test && python3 -m ue_sim.sim_algo_scenarios <action> [options]

Every action prints exactly one JSON object on stdout and exits 0; the feature
script decides pass/fail from the JSON. Subscribers are described on the command
line as  IMSI:KI:OPC:AMF:MSISDN:ALGO[:RES_LEN]  (ALGO = milenage | xor; OPC may be
empty for xor).

Actions
  attach      EPC attach + detach                        --ue SPEC
  tau         attach, TAU (exercises NAS security), detach
  register    attach + IMS AKA registration, then detach
  resync      attach with a forced SQN failure (AUTS) and resync
  call        A calls B, both attached and registered     --ue SPEC --peer SPEC
  check       verify a vector produced by the HSS with the UE-side algorithm
              --ue SPEC --rand HEX --autn HEX [--xres HEX --ck HEX --ik HEX]
"""

import argparse
import json
import logging
import sys
import threading
import time


def _spec(text: str) -> dict:
    parts = text.split(":")
    if len(parts) < 6:
        raise argparse.ArgumentTypeError(
            "subscriber must be IMSI:KI:OPC:AMF:MSISDN:ALGO[:RES_LEN]")
    return {
        "imsi": parts[0], "ki": parts[1], "opc": parts[2], "amf": parts[3] or "8000",
        "msisdn": parts[4], "algo": parts[5] or "milenage",
        "res_len": int(parts[6]) if len(parts) > 6 and parts[6] else None,
    }


def _make_ue(spec: dict, port_offset: int):
    from .config import Config
    from .ue_simulator import UESimulator
    return UESimulator(
        imsi=spec["imsi"], ki=spec["ki"], opc=spec["opc"] or "0" * 32, amf=spec["amf"],
        msisdn=spec["msisdn"], sip_local_port=Config.SIP_LOCAL_PORT_BASE + port_offset,
        auth_algo=spec["algo"], auth_res_len=spec["res_len"],
    )


def _state(ue) -> dict:
    return {
        "algo": ue.auth_algo,
        "ip": ue.ip_address,
        "eea": ue.selected_eea,
        "eia": ue.selected_eia,
        # None for Milenage (the simulator's Milenage does not expose it)
        "ue_mac_ok": getattr(ue._milenage, "last_mac_ok", None),
        "error_stage": ue.metrics.error_stage,
        "error": ue.metrics.error_message,
    }


def _quiet_detach(ue) -> None:
    try:
        ue.detach()
    except Exception:
        pass


def act_attach(args) -> dict:
    ue = _make_ue(args.ue, args.port)
    ok = ue.attach()
    out = {"attach": bool(ok)}
    out.update(_state(ue))
    _quiet_detach(ue)
    return out


def act_tau(args) -> dict:
    ue = _make_ue(args.ue, args.port)
    out = {"attach": bool(ue.attach()), "tau": False}
    if out["attach"]:
        try:
            out["tau"] = bool(ue.tau())
        except Exception as exc:  # report, do not crash the scenario
            out["tau_exception"] = str(exc)
    out.update(_state(ue))
    _quiet_detach(ue)
    return out


def act_register(args) -> dict:
    ue = _make_ue(args.ue, args.port)
    out = {"attach": bool(ue.attach()), "register": False}
    if out["attach"]:
        out["register"] = bool(ue.ims_register())
    out.update(_state(ue))
    _quiet_detach(ue)
    return out


def act_resync(args) -> dict:
    ue = _make_ue(args.ue, args.port)
    ok = ue.attach_with_auts_resync(sqn_ue=bytes.fromhex(args.sqn_ue))
    out = {"attach_resync": bool(ok)}
    out.update(_state(ue))
    _quiet_detach(ue)
    return out


def act_call(args) -> dict:
    caller = _make_ue(args.ue, args.port)
    callee = _make_ue(args.peer, args.port + 1)
    out = {"caller": {}, "callee": {}, "call": False, "callee_answered": False}

    for label, ue in (("caller", caller), ("callee", callee)):
        attached = bool(ue.attach())
        registered = bool(ue.ims_register()) if attached else False
        out[label] = {"attach": attached, "register": registered}
        out[label].update(_state(ue))

    if out["caller"]["register"] and out["callee"]["register"]:
        box = {}

        def answer():
            dialog = callee.answer_next_call_dialog(answer_delay=0.3, timeout=25.0)
            box["answered"] = bool(dialog)
            if dialog:
                box["ended"] = callee.wait_for_dialog_end(dialog, timeout=30.0)

        thread = threading.Thread(target=answer, daemon=True)
        thread.start()
        time.sleep(0.5)
        # The harness addresses a UE by its IMSI IMPU (see SIPClient._sip_uri)
        dialog = caller.establish_call_dialog(args.peer["imsi"])
        if dialog:
            time.sleep(args.hold)
            out["call"] = bool(caller.end_dialog(dialog, tolerate_timeout=True))
        else:
            out["caller"]["error"] = caller.metrics.error_message
        thread.join(timeout=40.0)
        out["callee_answered"] = bool(box.get("answered"))
        out["callee_saw_bye"] = bool(box.get("ended"))

    _quiet_detach(caller)
    _quiet_detach(callee)
    return out


def act_check(args) -> dict:
    """Offline check of an HSS vector with the UE-side implementation of the algorithm."""
    from .xor_algo import make_auth_algo
    spec = args.ue
    algo = make_auth_algo(spec["algo"], spec["ki"], spec["opc"] or "0" * 32, spec["amf"],
                          spec["res_len"])
    rand, autn = bytes.fromhex(args.rand), bytes.fromhex(args.autn)
    res, ck, ik = algo.authenticate(rand, autn)
    ak = algo.f5(rand)
    out = {
        "algo": spec["algo"],
        "ue_mac_ok": getattr(algo, "last_mac_ok", None),
        "res": res.hex(), "ck": ck.hex(), "ik": ik.hex(),
        "sqn": int.from_bytes(bytes(a ^ b for a, b in zip(autn[0:6], ak)), "big"),
        "amf": autn[6:8].hex(),
    }
    for name, expected in (("res", args.xres), ("ck", args.ck), ("ik", args.ik)):
        if expected:
            out[name + "_match"] = (out[name] == expected.lower())
    return out


ACTIONS = {
    "attach": act_attach, "tau": act_tau, "register": act_register,
    "resync": act_resync, "call": act_call, "check": act_check,
}


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(prog="sim_algo_scenarios")
    parser.add_argument("action", choices=sorted(ACTIONS))
    parser.add_argument("--ue", type=_spec, required=True)
    parser.add_argument("--peer", type=_spec)
    parser.add_argument("--port", type=int, default=70,
                        help="offset added to SIP_LOCAL_PORT_BASE")
    parser.add_argument("--hold", type=float, default=2.0)
    parser.add_argument("--sqn-ue", default="000000ffffff")
    parser.add_argument("--rand")
    parser.add_argument("--autn")
    parser.add_argument("--xres", default="")
    parser.add_argument("--ck", default="")
    parser.add_argument("--ik", default="")
    parser.add_argument("--log-level", default="CRITICAL")
    args = parser.parse_args(argv)

    logging.basicConfig(level=getattr(logging, args.log_level.upper(), logging.CRITICAL),
                        stream=sys.stderr)
    if args.log_level.upper() == "CRITICAL":
        logging.disable(logging.ERROR)

    if args.action == "call" and not args.peer:
        parser.error("call needs --peer")
    if args.action == "check" and not (args.rand and args.autn):
        parser.error("check needs --rand and --autn")

    try:
        result = ACTIONS[args.action](args)
    except Exception as exc:  # always hand the feature script a JSON object
        result = {"exception": f"{type(exc).__name__}: {exc}"}
    result["action"] = args.action
    print(json.dumps(result))
    return 0


if __name__ == "__main__":
    sys.exit(main())
