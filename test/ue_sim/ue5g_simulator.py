"""
Native NGAP 5G UE simulator + registration load driver.

This is the 5G analogue of the 4G ``run_load_test`` path. It ties together:

    keys5g   - 5G-AKA key hierarchy + SUCI
    nas5g    - 5GMM message codec + NAS security (NIA2 MAC)
    ngap_client - NGAP over SCTP (one shared gNB association)

and runs the 5GMM registration state machine for N *virtual* UEs multiplexed
over a single gNB SCTP association:

    InitialUEMessage(Registration Request/SUCI)
      -> Authentication Request     (RAND, AUTN)
    Authentication Response(RES*)
      -> Security Mode Command      (selected NEA/NIA)
    Security Mode Complete(+ full Reg Request in NAS container, integrity MAC)
      -> InitialContextSetupRequest (carries Registration Accept)
    InitialContextSetupResponse + Registration Complete
      => REGISTERED

Because there is no per-UE process (unlike UERANSIM), a burst of hundreds of
registrations is bounded by the AMF, not by the load generator.

The load subscribers use the same K/OPc/IMSI-range as the existing UERANSIM
load path (test/ueransim/provision_5g_range.js) so provisioning is unchanged:
    IMSI  = "00101" + 10-digit MSIN, base 101
    K     = 465B5CE8B199B49FAA5F0A2EE238A6BC
    OPc   = E8ED289DEBA952E4283B54E88E6183CA   (opType OPC)
    AMF   = 8000

CLI (called by features/5g/10_load_5g.sh):
    python3 -m ue_sim.ue5g_simulator --amf-ip 172.22.1.10 --num-ues 512 \
            --burst --json
"""

import argparse
import concurrent.futures
import json
import logging
import os
import sys
import time
from dataclasses import dataclass, field
from typing import Optional, List, Dict, Any

from .milenage import Milenage
from . import keys5g
from . import nas5g
from . import ngap_client as ngap

logger = logging.getLogger(__name__)

# Load-subscriber defaults - MUST match ueransim/provision_5g_range.js
LOAD_K = "465B5CE8B199B49FAA5F0A2EE238A6BC"
LOAD_OPC = "E8ED289DEBA952E4283B54E88E6183CA"
LOAD_AMF = "8000"
LOAD_IMSI_PREFIX = "00101"      # MCC 001 + MNC 01
LOAD_BASE = 101


@dataclass
class RegResult:
    imsi: str
    success: bool = False
    stage: str = "init"
    cause: Optional[int] = None
    error: Optional[str] = None
    time_ms: float = 0.0


class UE5G:
    """A single virtual 5G UE running the registration state machine over a
    shared :class:`ngap_client.NGAPConnection`."""

    def __init__(self, imsi: str, conn: "ngap.NGAPConnection", *,
                 ki: str = LOAD_K, opc: str = LOAD_OPC, amf: str = LOAD_AMF,
                 mcc: str = "001", mnc: str = "01",
                 sst: int = 1, sd: Optional[int] = 0x000001):
        self.imsi = imsi
        self.mcc = mcc
        self.mnc = mnc
        self.conn = conn
        self._mil = Milenage(bytes.fromhex(ki), bytes.fromhex(opc),
                             amf=bytes.fromhex(amf))
        self.msin = keys5g.split_imsi(imsi, mcc, mnc)
        self.suci = keys5g.encode_suci_nai(mcc, mnc, self.msin)
        self._req_nssai = ((sst, sd),)

        self.ran_ue_id: Optional[int] = None
        self.amf_ue_id: Optional[int] = None
        self.knas_int: Optional[bytes] = None
        self.knas_enc: Optional[bytes] = None
        self.sel_nea = 0
        self.sel_nia = 2
        self.ul_count = 0
        self._reg_req: Optional[bytes] = None

    # -- helpers ----------------------------------------------------------
    def _await_nas(self, timeout: float):
        """Wait for the next NGAP PDU for this UE; return (decoded_pdu, nas_msg,
        nas_type) where nas_msg/type may be None for non-NAS PDUs (e.g. ICS)."""
        pdu = self.conn.wait_for(self.ran_ue_id, timeout)
        if pdu is None:
            return None, None, None
        if pdu.get("amf_ue_id") is not None:
            self.amf_ue_id = pdu["amf_ue_id"]
        nas_msg = nas_type = None
        raw = pdu.get("nas_pdu")
        if raw:
            _, _, inner = nas5g.nas_decapsulate(raw)
            msg, err = nas5g.parse(inner)
            if err == 0 and msg is not None:
                nas_msg = msg
                nas_type = nas5g.message_type(msg)
        return pdu, nas_msg, nas_type

    def _answer_authentication(self, msg) -> bool:
        """Run 5G-AKA for a received Authentication Request and send the
        Authentication Response (RES*). Idempotent - safe to call again if the
        AMF retransmits the request. Returns False if RAND/AUTN are missing."""
        ar = nas5g.extract_auth_request(msg)
        if not ar.get("rand") or not ar.get("autn"):
            return False
        abba = ar.get("abba") or keys5g.ABBA_DEFAULT
        aka = keys5g.run_5g_aka(self._mil, ar["rand"], ar["autn"],
                                supi=self.imsi, mcc=self.mcc, mnc=self.mnc,
                                abba=bytes(abba))
        self._kamf = aka.kamf
        self.conn.send_uplink_nas(
            self.amf_ue_id, self.ran_ue_id,
            nas5g.build_authentication_response(aka.res_star))
        return True

    # -- state machine ----------------------------------------------------
    def register(self, timeout: float = 10.0) -> RegResult:
        t0 = time.time()
        r = RegResult(imsi=self.imsi)
        try:
            self.ran_ue_id = self.conn.new_ran_ue_id()

            # 1) Initial Registration Request in InitialUEMessage.
            # Per TS 24.501 4.4.6 the unprotected initial request may carry only
            # *cleartext* IEs (reg type, SUCI, ngKSI, UE security capability) -
            # NOT Requested-NSSAI. The full request (with NSSAI) is replayed
            # inside the Security Mode Complete NAS container after security.
            self._reg_req = nas5g.build_registration_request(
                self.suci, requested_nssai=None)
            r.stage = "reg_request_sent"
            self.conn.send_initial_ue(self.ran_ue_id, self._reg_req)

            # 2-4) Authentication then Security Mode Command. Under a large
            # simultaneous burst the AMF's response timer can fire and it
            # retransmits the Authentication Request before it processes our
            # reply. SCTP already delivered our first Authentication Response
            # reliably, so the AMF has authenticated and moved on - re-answering
            # would push a second response into an already-authenticated context
            # and get rejected. So: answer the FIRST Auth Request, then simply
            # ignore any duplicate while we wait for the Security Mode Command.
            smc = None
            answered = False
            for _ in range(6):
                pdu, msg, mtype = self._await_nas(timeout)
                if pdu is None:
                    r.error = f"timeout waiting for auth/security (stage {r.stage})"
                    return self._finish(r, t0)
                if mtype == nas5g.MT_REGISTRATION_REJECT:
                    r.cause = nas5g.extract_reject_cause(msg)
                    r.error = "registration rejected at auth/security stage"
                    return self._finish(r, t0)
                if mtype == nas5g.MT_AUTHENTICATION_REJECT:
                    r.error = "authentication rejected (RES* mismatch?)"
                    return self._finish(r, t0)
                if mtype == nas5g.MT_AUTHENTICATION_REQUEST:
                    if not answered:
                        if not self._answer_authentication(msg):
                            r.error = "Auth Request missing RAND/AUTN"
                            return self._finish(r, t0)
                        answered = True
                        r.stage = "auth_response_sent"
                    # else: duplicate retransmit - already answered; ignore it.
                    continue
                if mtype == nas5g.MT_SECURITY_MODE_COMMAND:
                    smc = nas5g.extract_security_mode_command(msg)
                    break
                r.error = f"expected auth/security, got NAS type {mtype}"
                return self._finish(r, t0)
            if smc is None:
                r.error = "no Security Mode Command after authentication"
                return self._finish(r, t0)
            self.sel_nea, self.sel_nia = smc["nea"], smc["nia"]
            self.knas_enc, self.knas_int = keys5g.derive_nas_keys(
                self._kamf, self.sel_nea, self.sel_nia)

            # 5) Security Mode Complete (integrity-protected). The NAS container
            # replays the FULL Registration Request, now including Requested-NSSAI
            # (non-cleartext IEs are allowed here, under integrity protection).
            reg_full = nas5g.build_registration_request(
                self.suci, requested_nssai=self._req_nssai)
            smc_complete = nas5g.build_security_mode_complete(
                nas_container=reg_full)
            protected = nas5g.nas_protect(
                smc_complete, self.knas_int, count=self.ul_count,
                sht=nas5g.SHT_INTEGRITY_CIPHERED_NEW_CTX,
                knas_enc=self.knas_enc, nea_id=self.sel_nea)
            self.ul_count += 1
            r.stage = "security_mode_complete_sent"
            self.conn.send_uplink_nas(self.amf_ue_id, self.ran_ue_id, protected)

            # 6) InitialContextSetupRequest (Registration Accept) or DL Reg Accept
            pdu, msg, mtype = self._await_nas(timeout)
            if pdu is None:
                r.error = "timeout waiting for context setup / Registration Accept"
                return self._finish(r, t0)
            if mtype == nas5g.MT_REGISTRATION_REJECT:
                r.cause = nas5g.extract_reject_cause(msg)
                r.error = "registration rejected after security"
                return self._finish(r, t0)

            proc = pdu.get("procedure_code")
            if proc == ngap.PC_INITIAL_CONTEXT_SETUP:
                # Ack the context, then complete the registration.
                self.conn.send_initial_context_setup_response(
                    self.amf_ue_id, self.ran_ue_id)
                self._send_registration_complete()
                r.success = True
                r.stage = "registered"
                return self._finish(r, t0)
            if mtype == nas5g.MT_REGISTRATION_ACCEPT:
                self._send_registration_complete()
                r.success = True
                r.stage = "registered"
                return self._finish(r, t0)

            r.error = f"unexpected post-security PDU (proc={proc}, nas={mtype})"
            return self._finish(r, t0)
        except Exception as e:                      # pragma: no cover
            r.error = f"{type(e).__name__}: {e}"
            return self._finish(r, t0)

    def _send_registration_complete(self):
        rc = nas5g.build_registration_complete()
        protected = nas5g.nas_protect(
            rc, self.knas_int, count=self.ul_count,
            sht=nas5g.SHT_INTEGRITY_CIPHERED,
            knas_enc=self.knas_enc, nea_id=self.sel_nea)
        self.ul_count += 1
        self.conn.send_uplink_nas(self.amf_ue_id, self.ran_ue_id, protected)

    @staticmethod
    def _finish(r: RegResult, t0: float) -> RegResult:
        r.time_ms = (time.time() - t0) * 1000.0
        return r


# ---------------------------------------------------------------------------
# Load driver
# ---------------------------------------------------------------------------
def run_load_test_5g(num_ues: int, amf_ip: str, *,
                     amf_port: int = ngap.AMF_N2_PORT_DEFAULT,
                     base: int = LOAD_BASE, mcc: str = "001", mnc: str = "01",
                     ki: str = LOAD_K, opc: str = LOAD_OPC, amf_val: str = LOAD_AMF,
                     gnb_id: int = 1, tac: int = 1, sst: int = 1,
                     sd: int = 0x000001, burst: bool = True,
                     max_workers: int = 256,
                     timeout: float = 15.0) -> Dict[str, Any]:
    """Register ``num_ues`` virtual UEs over one gNB association and report.

    ``burst=True`` launches all registrations concurrently (the capacity test);
    ``burst=False`` ramps them through a bounded worker pool.
    """
    plmn = keys5g.encode_plmn(mcc, mnc)
    sd_bytes = int(sd).to_bytes(3, "big") if sd is not None else None
    conn = ngap.NGAPConnection(
        amf_ip, amf_port, plmn=plmn, gnb_id=gnb_id,
        tac=tac.to_bytes(3, "big"), nr_cell_id=1,
        sst=bytes([sst]), sd=sd_bytes, timeout=timeout)

    result: Dict[str, Any] = {
        "ok": False, "amf": f"{amf_ip}:{amf_port}", "requested": num_ues,
        "registered": 0, "failed": 0, "stages": {}, "causes": {},
        "errors": [], "ng_setup": False, "elapsed_ms": 0.0,
    }

    if not conn.connect():
        result["errors"].append(f"SCTP connect to AMF {amf_ip}:{amf_port} failed")
        return result
    if not conn.ng_setup():
        result["errors"].append("NG Setup failed (AMF rejected gNB association)")
        conn.close()
        return result
    result["ng_setup"] = True

    ues = [UE5G(f"{LOAD_IMSI_PREFIX}{str(base + i).zfill(10)}", conn,
                ki=ki, opc=opc, amf=amf_val, mcc=mcc, mnc=mnc,
                sst=sst, sd=sd)
           for i in range(num_ues)]

    t0 = time.time()
    results: List[RegResult] = []
    workers = num_ues if burst else min(max_workers, num_ues)
    workers = max(1, workers)
    with concurrent.futures.ThreadPoolExecutor(max_workers=workers) as ex:
        futs = [ex.submit(ue.register, timeout) for ue in ues]
        for f in concurrent.futures.as_completed(futs):
            results.append(f.result())
    result["elapsed_ms"] = (time.time() - t0) * 1000.0

    for rr in results:
        if rr.success:
            result["registered"] += 1
        else:
            result["failed"] += 1
            result["stages"][rr.stage] = result["stages"].get(rr.stage, 0) + 1
            if rr.cause is not None:
                k = str(rr.cause)
                result["causes"][k] = result["causes"].get(k, 0) + 1
            if rr.error and len(result["errors"]) < 10:
                result["errors"].append(f"{rr.imsi}: {rr.error}")

    result["ok"] = result["registered"] == num_ues
    conn.close()
    return result


# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------
def main(argv=None):
    p = argparse.ArgumentParser(description="Native NGAP 5G registration load test")
    p.add_argument("--amf-ip", default=os.getenv("AMF_IP", "172.22.1.10"))
    p.add_argument("--amf-port", type=int, default=int(os.getenv("AMF_N2_PORT", "38412")))
    p.add_argument("--num-ues", type=int, default=1)
    p.add_argument("--base", type=int, default=LOAD_BASE)
    p.add_argument("--mcc", default=os.getenv("MCC", "001"))
    p.add_argument("--mnc", default=os.getenv("MNC", "01"))
    p.add_argument("--k", default=LOAD_K)
    p.add_argument("--opc", default=LOAD_OPC)
    p.add_argument("--amf-val", default=LOAD_AMF)
    p.add_argument("--gnb-id", type=int, default=1)
    p.add_argument("--tac", type=int, default=int(os.getenv("TAC", "1")))
    p.add_argument("--sst", type=int, default=1)
    p.add_argument("--sd", type=lambda x: int(x, 0), default=0x000001,
                   help="slice differentiator (default 0x000001; -1 for none)")
    p.add_argument("--timeout", type=float, default=15.0)
    p.add_argument("--max-workers", type=int, default=256)
    p.add_argument("--ramp", action="store_true", help="ramp instead of burst")
    p.add_argument("--json", action="store_true", help="emit JSON only")
    p.add_argument("-v", "--verbose", action="store_true")
    args = p.parse_args(argv)

    logging.basicConfig(
        level=logging.DEBUG if args.verbose else logging.WARNING,
        format="%(asctime)s %(levelname)s %(name)s: %(message)s")

    res = run_load_test_5g(
        args.num_ues, args.amf_ip, amf_port=args.amf_port, base=args.base,
        mcc=args.mcc, mnc=args.mnc, ki=args.k, opc=args.opc, amf_val=args.amf_val,
        gnb_id=args.gnb_id, tac=args.tac, sst=args.sst,
        sd=(None if args.sd < 0 else args.sd), burst=not args.ramp,
        max_workers=args.max_workers, timeout=args.timeout)

    if args.json:
        print(json.dumps(res))
    else:
        print(json.dumps(res, indent=2))
    return 0 if res["ok"] else 1


if __name__ == "__main__":
    sys.exit(main())
