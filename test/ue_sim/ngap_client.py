"""
NGAP client over SCTP - the 5G (N2) counterpart of ``s1ap_client.py``.

Uses pycrate's compiled NGAP ASN.1 (``pycrate_asn1dir.NGAP``) to encode/decode
NGAP PDUs, and the same SCTP transport pattern as the S1AP client (pysctp with
a raw-SCTP / TCP fallback). NGAP runs on AMF N2 (default TCP/SCTP port 38412,
SCTP PPID 60).

The scaling design that makes this worth building: one gNB SCTP association is
set up **once** (NG Setup), and then *many* virtual UEs are multiplexed over it,
each identified by its own RAN-UE-NGAP-ID. There is no per-UE process or per-UE
socket - which is exactly why this can burst hundreds of registrations where a
per-UE full-stack emulator (UERANSIM) tops out at a few dozen.

Only the NGAP layer lives here; the NAS payloads it carries are built by
:mod:`ue_sim.nas5g`.
"""

import logging
import socket
import struct
import threading
from typing import Optional, Dict, Any, List, Tuple

logger = logging.getLogger(__name__)

# SCTP payload protocol identifier + default N2 port for NGAP
NGAP_PPID = 60
AMF_N2_PORT_DEFAULT = 38412

# NGAP procedure codes (TS 38.413 clause 9.3.5)
PC_DOWNLINK_NAS_TRANSPORT = 4
PC_INITIAL_CONTEXT_SETUP = 14
PC_INITIAL_UE_MESSAGE = 15
PC_NG_SETUP = 21
PC_PDU_SESSION_RESOURCE_SETUP = 29
PC_UE_CONTEXT_RELEASE = 41
PC_UPLINK_NAS_TRANSPORT = 46

# NGAP ProtocolIE-IDs (TS 38.413 clause 9.3.1.x)
IE_AMF_UE_NGAP_ID = 10
IE_DEFAULT_PAGING_DRX = 21
IE_GLOBAL_RAN_NODE_ID = 27
IE_NAS_PDU = 38
IE_RAN_UE_NGAP_ID = 85
IE_RAN_NODE_NAME = 82
IE_RRC_ESTABLISHMENT_CAUSE = 90
IE_SUPPORTED_TA_LIST = 102
IE_UE_CONTEXT_REQUEST = 112
IE_USER_LOCATION_INFORMATION = 121

_ngap_pdu = None
_ngap_import_error = None


def _get_pdu_cls():
    """Lazily import and return the NGAP top-level PDU class (singleton)."""
    global _ngap_pdu, _ngap_import_error
    if _ngap_pdu is None and _ngap_import_error is None:
        try:
            from pycrate_asn1dir import NGAP
            _ngap_pdu = NGAP.NGAP_PDU_Descriptions.NGAP_PDU
        except Exception as e:      # pragma: no cover - image always has pycrate
            _ngap_import_error = e
            logger.error("pycrate NGAP not available: %s", e)
    if _ngap_import_error is not None:
        raise _ngap_import_error
    return _ngap_pdu


# ---------------------------------------------------------------------------
# IE value builders (nested NGAP structures)
# ---------------------------------------------------------------------------
def _global_gnb_id(plmn: bytes, gnb_id: int, gnb_id_bits: int = 32) -> tuple:
    """GlobalRANNodeID ::= CHOICE { globalGNB-ID GlobalGNB-ID }."""
    return ("globalGNB-ID", {
        "pLMNIdentity": plmn,
        "gNB-ID": ("gNB-ID", (gnb_id, gnb_id_bits)),
    })


def _supported_ta_list(plmn: bytes, tac: bytes, sst: bytes = b"\x01",
                       sd: Optional[bytes] = None) -> list:
    """SupportedTAList with one TA item / one broadcast PLMN / one S-NSSAI.

    Include ``sd`` (3 octets) so the advertised slice matches the subscribed
    S-NSSAI exactly; otherwise open5gs treats the SD as 0xffffff and the
    Allowed-NSSAI intersection can come up empty.
    """
    snssai: Dict[str, Any] = {"sST": sst}
    if sd is not None:
        snssai["sD"] = sd
    return [{
        "tAC": tac,
        "broadcastPLMNList": [{
            "pLMNIdentity": plmn,
            "tAISliceSupportList": [{"s-NSSAI": snssai}],
        }],
    }]


def _user_location_nr(plmn: bytes, nr_cell_id: int, tac: bytes) -> tuple:
    """UserLocationInformation ::= CHOICE { userLocationInformationNR ... }."""
    return ("userLocationInformationNR", {
        "nR-CGI": {"pLMNIdentity": plmn, "nRCellIdentity": (nr_cell_id, 36)},
        "tAI": {"pLMNIdentity": plmn, "tAC": tac},
    })


def _ie(ie_id: int, criticality: str, value_name: str, value: Any) -> dict:
    return {"id": ie_id, "criticality": criticality, "value": (value_name, value)}


# ---------------------------------------------------------------------------
# Message encoders
# ---------------------------------------------------------------------------
def encode_ng_setup_request(plmn: bytes, gnb_id: int, tac: bytes,
                            ran_node_name: str = "ue5gsim",
                            sst: bytes = b"\x01",
                            sd: Optional[bytes] = None) -> bytes:
    pdu = _get_pdu_cls()
    ies: List[dict] = [
        _ie(IE_GLOBAL_RAN_NODE_ID, "reject", "GlobalRANNodeID",
            _global_gnb_id(plmn, gnb_id)),
        _ie(IE_RAN_NODE_NAME, "ignore", "RANNodeName", ran_node_name),
        _ie(IE_SUPPORTED_TA_LIST, "reject", "SupportedTAList",
            _supported_ta_list(plmn, tac, sst, sd)),
        _ie(IE_DEFAULT_PAGING_DRX, "ignore", "PagingDRX", "v128"),
    ]
    pdu.set_val(("initiatingMessage", {
        "procedureCode": PC_NG_SETUP,
        "criticality": "reject",
        "value": ("NGSetupRequest", {"protocolIEs": ies}),
    }))
    return pdu.to_aper()


def encode_initial_ue_message(ran_ue_id: int, nas_pdu: bytes, plmn: bytes,
                              nr_cell_id: int, tac: bytes,
                              rrc_cause: str = "mo-Signalling",
                              ue_context_request: bool = True) -> bytes:
    pdu = _get_pdu_cls()
    ies: List[dict] = [
        _ie(IE_RAN_UE_NGAP_ID, "reject", "RAN-UE-NGAP-ID", ran_ue_id),
        _ie(IE_NAS_PDU, "reject", "NAS-PDU", nas_pdu),
        _ie(IE_USER_LOCATION_INFORMATION, "reject", "UserLocationInformation",
            _user_location_nr(plmn, nr_cell_id, tac)),
        _ie(IE_RRC_ESTABLISHMENT_CAUSE, "ignore", "RRCEstablishmentCause",
            rrc_cause),
    ]
    if ue_context_request:
        ies.append(_ie(IE_UE_CONTEXT_REQUEST, "ignore", "UEContextRequest",
                       "requested"))
    pdu.set_val(("initiatingMessage", {
        "procedureCode": PC_INITIAL_UE_MESSAGE,
        "criticality": "ignore",
        "value": ("InitialUEMessage", {"protocolIEs": ies}),
    }))
    return pdu.to_aper()


def encode_initial_context_setup_response(amf_ue_id: int, ran_ue_id: int) -> bytes:
    """InitialContextSetupResponse (successfulOutcome) - ack the AMF's context
    setup so the registration procedure can complete. No PDU-session IEs (this
    simulator does registration only in phase 1)."""
    pdu = _get_pdu_cls()
    ies: List[dict] = [
        _ie(IE_AMF_UE_NGAP_ID, "ignore", "AMF-UE-NGAP-ID", amf_ue_id),
        _ie(IE_RAN_UE_NGAP_ID, "ignore", "RAN-UE-NGAP-ID", ran_ue_id),
    ]
    pdu.set_val(("successfulOutcome", {
        "procedureCode": PC_INITIAL_CONTEXT_SETUP,
        "criticality": "reject",
        "value": ("InitialContextSetupResponse", {"protocolIEs": ies}),
    }))
    return pdu.to_aper()


def encode_uplink_nas_transport(amf_ue_id: int, ran_ue_id: int, nas_pdu: bytes,
                                plmn: bytes, nr_cell_id: int,
                                tac: bytes) -> bytes:
    pdu = _get_pdu_cls()
    ies: List[dict] = [
        _ie(IE_AMF_UE_NGAP_ID, "reject", "AMF-UE-NGAP-ID", amf_ue_id),
        _ie(IE_RAN_UE_NGAP_ID, "reject", "RAN-UE-NGAP-ID", ran_ue_id),
        _ie(IE_NAS_PDU, "reject", "NAS-PDU", nas_pdu),
        _ie(IE_USER_LOCATION_INFORMATION, "ignore", "UserLocationInformation",
            _user_location_nr(plmn, nr_cell_id, tac)),
    ]
    pdu.set_val(("initiatingMessage", {
        "procedureCode": PC_UPLINK_NAS_TRANSPORT,
        "criticality": "ignore",
        "value": ("UplinkNASTransport", {"protocolIEs": ies}),
    }))
    return pdu.to_aper()


# ---------------------------------------------------------------------------
# Decoder
# ---------------------------------------------------------------------------
def decode_pdu(data: bytes) -> Dict[str, Any]:
    """Decode an NGAP PDU into {pdu_type, procedure_code, message, ies{...}}.

    ``ies`` is a flat dict keyed by IE id with convenience keys for the ones
    the registration flow needs: amf_ue_id, ran_ue_id, nas_pdu.
    """
    pdu = _get_pdu_cls()
    pdu.from_aper(data)
    val = pdu.get_val()
    pdu_type = val[0]                       # initiatingMessage/successfulOutcome/...
    body = val[1]
    proc = body.get("procedureCode")
    msg_name, msg_val = body["value"]
    out: Dict[str, Any] = {
        "pdu_type": pdu_type,
        "procedure_code": proc,
        "message": msg_name,
        "ies": {},
    }
    for ie in msg_val.get("protocolIEs", []):
        ie_id = ie.get("id")
        ie_val = ie.get("value")
        out["ies"][ie_id] = ie_val
        if ie_id == IE_AMF_UE_NGAP_ID:
            out["amf_ue_id"] = ie_val[1]
        elif ie_id == IE_RAN_UE_NGAP_ID:
            out["ran_ue_id"] = ie_val[1]
        elif ie_id == IE_NAS_PDU:
            out["nas_pdu"] = bytes(ie_val[1])
    return out


# ---------------------------------------------------------------------------
# Shared gNB SCTP association carrying many virtual UEs
# ---------------------------------------------------------------------------
class NGAPConnection:
    """A single gNB<->AMF SCTP association. NG Setup once; multiplex many UEs.

    RAN-UE-NGAP-IDs are handed out per virtual UE. Receiving is demultiplexed
    by RAN-UE-NGAP-ID so concurrent UEs can each block on their own inbox.
    """

    def __init__(self, amf_ip: str, amf_port: int = AMF_N2_PORT_DEFAULT,
                 plmn: bytes = b"\x00\xf1\x10", gnb_id: int = 1,
                 tac: bytes = b"\x00\x00\x01", nr_cell_id: int = 1,
                 sst: bytes = b"\x01", sd: Optional[bytes] = None,
                 timeout: float = 10.0):
        self.amf_ip = amf_ip
        self.amf_port = amf_port
        self.plmn = plmn
        self.gnb_id = gnb_id
        self.tac = tac
        self.nr_cell_id = nr_cell_id
        self.sst = sst
        self.sd = sd
        self.timeout = timeout

        self._sock: Optional[socket.socket] = None
        self._connected = False
        self._ng_setup_done = False
        self._next_ran_ue_id = 1
        self._id_lock = threading.Lock()
        self._sock_lock = threading.Lock()
        # Per-RAN-UE inbox: ran_ue_id -> list[decoded_pdu]
        self._inbox: Dict[int, List[dict]] = {}
        self._inbox_cv = threading.Condition()
        self._rx_thread: Optional[threading.Thread] = None
        self._running = False

    # --- transport -------------------------------------------------------
    def _create_socket(self) -> socket.socket:
        try:
            import sctp
            return sctp.sctpsocket_tcp(socket.AF_INET)
        except ImportError:
            pass
        try:
            return socket.socket(socket.AF_INET, socket.SOCK_STREAM, 132)
        except OSError:
            logger.warning("Raw SCTP unavailable; using TCP shim (dev only)")
            return socket.socket(socket.AF_INET, socket.SOCK_STREAM)

    def _send(self, data: bytes):
        with self._sock_lock:
            try:
                import sctp  # noqa: F401
                self._sock.sctp_send(data, ppid=socket.htonl(NGAP_PPID))
            except (ImportError, AttributeError):
                self._sock.sendall(data)

    def _recv_once(self, timeout: float) -> Optional[bytes]:
        import select
        ready, _, _ = select.select([self._sock], [], [], timeout)
        if not ready:
            return None
        try:
            import sctp  # noqa: F401
            _, _, data, _ = self._sock.sctp_recv(65536)
            return data or None
        except (ImportError, AttributeError):
            return self._sock.recv(65536) or None

    def connect(self) -> bool:
        try:
            self._sock = self._create_socket()
            self._sock.settimeout(self.timeout)
            self._sock.connect((self.amf_ip, self.amf_port))
            self._connected = True
            logger.info("SCTP connected to AMF %s:%d", self.amf_ip, self.amf_port)
            return True
        except Exception as e:
            logger.error("SCTP connect to AMF failed: %s", e)
            self._connected = False
            return False

    def ng_setup(self) -> bool:
        if not self._connected:
            raise ConnectionError("Not connected to AMF")
        self._send(encode_ng_setup_request(self.plmn, self.gnb_id, self.tac,
                                           sst=self.sst, sd=self.sd))
        resp = self._recv_once(self.timeout)
        if resp is None:
            logger.error("No NGSetupResponse")
            return False
        dec = decode_pdu(resp)
        if dec["pdu_type"] == "successfulOutcome" and \
                dec["procedure_code"] == PC_NG_SETUP:
            self._ng_setup_done = True
            self._start_rx()
            logger.info("NG Setup successful")
            return True
        logger.error("NG Setup failed: %s", dec.get("message"))
        return False

    # --- UE multiplexing -------------------------------------------------
    def new_ran_ue_id(self) -> int:
        with self._id_lock:
            rid = self._next_ran_ue_id
            self._next_ran_ue_id += 1
            with self._inbox_cv:
                self._inbox[rid] = []
            return rid

    def _start_rx(self):
        self._running = True
        self._rx_thread = threading.Thread(target=self._rx_loop, daemon=True)
        self._rx_thread.start()

    def _rx_loop(self):
        while self._running:
            try:
                data = self._recv_once(0.5)
            except Exception as e:
                logger.debug("rx loop recv error: %s", e)
                break
            if not data:
                continue
            try:
                dec = decode_pdu(data)
            except Exception as e:
                logger.debug("rx loop decode error: %s", e)
                continue
            rid = dec.get("ran_ue_id")
            with self._inbox_cv:
                if rid in self._inbox:
                    self._inbox[rid].append(dec)
                else:
                    # Unkeyed (e.g. gNB-wide) - drop into a broadcast bucket
                    self._inbox.setdefault(-1, []).append(dec)
                self._inbox_cv.notify_all()

    def send_initial_ue(self, ran_ue_id: int, nas_pdu: bytes):
        self._send(encode_initial_ue_message(
            ran_ue_id, nas_pdu, self.plmn, self.nr_cell_id, self.tac))

    def send_uplink_nas(self, amf_ue_id: int, ran_ue_id: int, nas_pdu: bytes):
        self._send(encode_uplink_nas_transport(
            amf_ue_id, ran_ue_id, nas_pdu, self.plmn, self.nr_cell_id, self.tac))

    def send_initial_context_setup_response(self, amf_ue_id: int, ran_ue_id: int):
        self._send(encode_initial_context_setup_response(amf_ue_id, ran_ue_id))

    def wait_for(self, ran_ue_id: int, timeout: float = None) -> Optional[dict]:
        """Block until a PDU addressed to ``ran_ue_id`` arrives; pop and return."""
        deadline_to = timeout if timeout is not None else self.timeout
        import time as _t
        end = _t.time() + deadline_to
        with self._inbox_cv:
            while True:
                q = self._inbox.get(ran_ue_id) or []
                if q:
                    return q.pop(0)
                remaining = end - _t.time()
                if remaining <= 0:
                    return None
                self._inbox_cv.wait(remaining)

    def close(self):
        self._running = False
        if self._sock:
            try:
                self._sock.close()
            except Exception:
                pass
        self._sock = None
        self._connected = False


# ---------------------------------------------------------------------------
# Offline self-test (encode only; no live AMF)
# ---------------------------------------------------------------------------
if __name__ == "__main__":
    plmn = bytes.fromhex("00f110")
    tac = bytes.fromhex("000001")

    ng = encode_ng_setup_request(plmn, gnb_id=1, tac=tac)
    print("NGSetupRequest      :", ng.hex())
    dec = decode_pdu(ng)
    assert dec["procedure_code"] == PC_NG_SETUP and dec["message"] == "NGSetupRequest"

    reg = bytes.fromhex("7e004179000d0100f110f0ff000000000000102e02f0f0")
    ium = encode_initial_ue_message(1, reg, plmn, nr_cell_id=1, tac=tac)
    print("InitialUEMessage    :", ium.hex())
    dec = decode_pdu(ium)
    assert dec["procedure_code"] == PC_INITIAL_UE_MESSAGE
    assert dec.get("ran_ue_id") == 1 and dec.get("nas_pdu") == reg, dec

    ul = encode_uplink_nas_transport(500, 1, reg, plmn, nr_cell_id=1, tac=tac)
    print("UplinkNASTransport  :", ul.hex())
    dec = decode_pdu(ul)
    assert dec.get("amf_ue_id") == 500 and dec.get("ran_ue_id") == 1
    assert dec.get("nas_pdu") == reg

    print("\nngap_client self-test PASSED (encode/decode round-trip)")
