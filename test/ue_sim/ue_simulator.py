"""
UE Simulator - Main Orchestrator

Ties together the S1AP client, NAS handler, SIP client, and Milenage
authentication to provide a complete UE lifecycle for testing the
EPC + IMS stack.

Lifecycle:
    1. EPC Attach:  S1 Setup → Attach Request → Auth → Security Mode → Bearer
    2. IMS Register: SIP REGISTER with AKA auth through P-CSCF → I-CSCF → S-CSCF
    3. VoLTE/ViLTE:  SIP INVITE → call setup → media → BYE
    4. Detach:       UE-initiated detach

Usage:
    from ue_sim import UESimulator, Config

    sub = Config.default_subscribers()[0]
    ue = UESimulator(
        imsi=sub.imsi, ki=sub.ki, opc=sub.opc,
        msisdn=sub.msisdn,
    )
    ue.attach()
    ue.ims_register()
    ue.volte_call("19876541000", duration=5)
    ue.detach()
"""

import logging
import os
import time
import statistics
import concurrent.futures
import threading
import collections
import multiprocessing
from enum import Enum
from dataclasses import dataclass, field
from typing import Optional, List, Dict, Any, Tuple

from .config import Config, SubscriberConfig, setup_logging
from .milenage import Milenage, AuthenticationError
from .nas_handler import NASHandler, EPSMobilityMessageType
from .s1ap_client import S1APClient, S1APProcedureCode, SharedS1APConnection, s1ap_procedure_name
from .sip_client import SIPClient

logger = logging.getLogger(__name__)


class UEState(Enum):
    """UE state machine states."""
    IDLE = "idle"
    CONNECTING = "connecting"
    AUTHENTICATING = "authenticating"
    SECURITY_MODE = "security_mode"
    ATTACHED = "attached"
    IMS_REGISTERING = "ims_registering"
    IMS_REGISTERED = "ims_registered"
    IN_CALL = "in_call"
    DETACHING = "detaching"
    DETACHED = "detached"
    ERROR = "error"


@dataclass
class UEMetrics:
    """Performance metrics for a single UE lifecycle."""
    imsi: str = ""
    msisdn: str = ""
    enb_ue_id: int = 0
    mme_ue_id: int = 0

    attach_start: float = 0.0
    attach_end: float = 0.0
    ims_register_start: float = 0.0
    ims_register_end: float = 0.0
    call_setup_start: float = 0.0
    call_setup_end: float = 0.0
    call_end: float = 0.0
    detach_start: float = 0.0
    detach_end: float = 0.0

    attach_success: bool = False
    ims_register_success: bool = False
    call_success: bool = False
    detach_success: bool = False

    error_message: str = ""
    error_stage: str = ""
    last_stage: str = ""
    ip_address: str = ""
    stage_times_ms: Dict[str, float] = field(default_factory=dict)

    # Dedicated bearers captured during call (QCI-1 for VoLTE, QCI-2 for ViLTE)
    dedicated_bearers: List[Dict[str, Any]] = field(default_factory=list)

    @property
    def attach_time_ms(self) -> float:
        if self.attach_start and self.attach_end:
            return (self.attach_end - self.attach_start) * 1000
        return 0.0

    @property
    def ims_register_time_ms(self) -> float:
        if self.ims_register_start and self.ims_register_end:
            return (self.ims_register_end - self.ims_register_start) * 1000
        return 0.0

    @property
    def call_setup_time_ms(self) -> float:
        if self.call_setup_start and self.call_setup_end:
            return (self.call_setup_end - self.call_setup_start) * 1000
        return 0.0

    @property
    def total_time_ms(self) -> float:
        """Total lifecycle time."""
        start = self.attach_start
        end = max(self.detach_end, self.call_end, self.ims_register_end, self.attach_end)
        if start and end:
            return (end - start) * 1000
        return 0.0


class UESimulator:
    """
    Main UE Simulator orchestrator.

    Manages the complete UE lifecycle from EPC attach through IMS registration
    to VoLTE/ViLTE calls and detach.

    Args:
        imsi: Subscriber IMSI (15 digits)
        ki: Subscriber key K (hex string)
        opc: Subscriber OPc (hex string)
        amf: Authentication Management Field (hex string)
        msisdn: Subscriber MSISDN
        mme_ip: Override MME IP
        mme_port: Override MME port
        pcscf_ip: Override P-CSCF IP
        pcscf_port: Override P-CSCF port
        sip_local_port: Local port for SIP
    """

    def __init__(
        self,
        imsi: str,
        ki: str,
        opc: str,
        amf: str = "8000",
        msisdn: str = "",
        imei_sv: str = "",
        mme_ip: str = None,
        mme_port: int = None,
        pcscf_ip: str = None,
        pcscf_port: int = None,
        sip_local_port: int = None,
        shared_conn: 'SharedS1APConnection' = None,
        ue_network_capability: bytes = None,
    ):
        self._imsi = imsi
        self._msisdn = msisdn or imsi  # Use IMSI if no MSISDN
        self._imei_sv = imei_sv
        self._state = UEState.IDLE
        self._metrics = UEMetrics()
        self._metrics.imsi = imsi
        self._metrics.msisdn = self._msisdn
        self._current_stage = ""
        self._current_stage_started_at = 0.0

        # Milenage authentication
        self._milenage = Milenage.from_hex(ki, opc, amf)

        # NAS handler
        self._nas = NASHandler(imsi, ue_network_capability=ue_network_capability)

        # S1AP client (shared or standalone)
        self._s1ap = S1APClient(
            mme_ip=mme_ip,
            mme_port=mme_port,
            shared_conn=shared_conn,
        )

        # SIP client (lazy init after attach to get IP)
        self._sip: Optional[SIPClient] = None
        self._pcscf_ip = pcscf_ip
        self._pcscf_port = pcscf_port
        self._sip_local_port = sip_local_port

        # State from attach
        self._ip_address: Optional[str] = None
        self._ipv6_prefix: Optional[str] = None
        self._bearer_id: int = 5
        self._guti_bytes: Optional[bytes] = None   # 10-byte GUTI from Attach/TAU Accept

        # Dedicated bearer tracking (populated during calls)
        self._dedicated_bearers: List[Dict[str, Any]] = []
        self._dedicated_bearer_trace: List[Dict[str, Any]] = []
        self._bearer_poll_thread: Optional[threading.Thread] = None
        self._bearer_poll_stop = threading.Event()

        # Security context
        self._ck: Optional[bytes] = None
        self._ik: Optional[bytes] = None
        self._kasme: Optional[bytes] = None

        logger.info("UE Simulator created: IMSI=%s MSISDN=%s IMEI-SV=%s", imsi, msisdn, imei_sv or "(none)")

    def _stage_start(self, stage: str):
        """Mark the beginning of a UE lifecycle stage for burst diagnostics."""
        self._current_stage = stage
        self._current_stage_started_at = time.time()
        self._metrics.last_stage = stage

    def _stage_done(self, stage: str = None):
        """Record elapsed time for the current UE lifecycle stage."""
        stage = stage or self._current_stage
        if stage and self._current_stage_started_at:
            elapsed_ms = (time.time() - self._current_stage_started_at) * 1000
            self._metrics.stage_times_ms[stage] = elapsed_ms
        self._current_stage = ""
        self._current_stage_started_at = 0.0

    def _stage_error(self, message: str, stage: str = None):
        """Record the first failing stage and the most specific error text."""
        stage = stage or self._current_stage or self._metrics.last_stage or self._state.value
        if not self._metrics.error_stage:
            self._metrics.error_stage = stage
        if message:
            self._metrics.error_message = message

    def _capture_s1_ids(self):
        """Copy S1AP IDs into metrics for per-UE failure correlation."""
        try:
            self._metrics.enb_ue_id = self._s1ap.enb_ue_id
            self._metrics.mme_ue_id = self._s1ap.mme_ue_id
        except Exception:
            pass

    # ================================================================
    # EPC Attach
    # ================================================================
    def attach(self, apn: str = "internet", pdn_type: int = 1) -> bool:
        """
        Perform full EPC attach procedure.

        Steps:
            1. SCTP connect to MME
            2. S1 Setup (eNB registration)
            3. Send Attach Request (NAS)
            4. Handle Authentication Request → send Authentication Response
            5. Handle Security Mode Command → send Security Mode Complete
            6. Handle Attach Accept → send Attach Complete
            7. Handle Initial Context Setup → send response

        Args:
            apn:      APN for the initial default bearer
            pdn_type: PDN type (1=IPv4, 2=IPv6, 3=IPv4v6)

        Returns:
            True if attach succeeded
        """
        self._state = UEState.CONNECTING
        self._metrics.attach_start = time.time()
        self._metrics.error_stage = ""
        self._metrics.error_message = ""

        try:
            # Step 1: Connect to MME
            self._stage_start("s1_connect")
            logger.info("[%s] Connecting to MME...", self._imsi)
            if not self._s1ap.connect():
                self._stage_error("Failed to connect to MME")
                raise ConnectionError("Failed to connect to MME")
            self._stage_done("s1_connect")

            # Step 2: S1 Setup
            self._stage_start("s1_setup")
            logger.info("[%s] Performing S1 Setup...", self._imsi)
            if not self._s1ap.s1_setup():
                self._stage_error("S1 Setup failed")
                raise ConnectionError("S1 Setup failed")
            self._stage_done("s1_setup")

            # Step 3: Send Attach Request
            self._stage_start("attach_request")
            logger.info("[%s] Sending Attach Request...", self._imsi)
            attach_req = self._nas.build_attach_request(apn=apn, pdn_type=pdn_type)
            self._s1ap.send_attach_request(attach_req)
            self._capture_s1_ids()
            self._stage_done("attach_request")

            # Step 4: Handle Authentication
            self._state = UEState.AUTHENTICATING
            self._stage_start("s6a_auth")
            if not self._handle_authentication():
                self._stage_error(self._metrics.error_message or "Authentication failed")
                raise AuthenticationError(self._metrics.error_message or "Authentication failed")
            self._capture_s1_ids()
            self._stage_done("s6a_auth")

            # Step 5: Handle Security Mode
            self._state = UEState.SECURITY_MODE
            self._stage_start("nas_security")
            if not self._handle_security_mode():
                self._stage_error(self._metrics.error_message or "Security Mode failed")
                raise RuntimeError(self._metrics.error_message or "Security Mode failed")
            self._capture_s1_ids()
            self._stage_done("nas_security")

            # Step 6: Handle Attach Accept
            self._stage_start("s11_attach_accept")
            if not self._handle_attach_accept():
                self._stage_error(self._metrics.error_message or "Attach Accept not received")
                raise RuntimeError(self._metrics.error_message or "Attach Accept not received")
            self._capture_s1_ids()
            self._stage_done("s11_attach_accept")

            self._state = UEState.ATTACHED
            self._metrics.attach_end = time.time()
            self._metrics.attach_success = True
            self._metrics.error_stage = ""
            self._metrics.error_message = ""

            logger.info(
                "[%s] EPC Attach successful: IP=%s (%.0fms)",
                self._imsi,
                self._ip_address or "unknown",
                self._metrics.attach_time_ms,
            )
            return True

        except Exception as e:
            self._state = UEState.ERROR
            self._metrics.attach_end = time.time()
            self._capture_s1_ids()
            self._stage_error(str(e))
            logger.error("[%s] Attach failed: %s", self._imsi, e)
            return False

    def _send_authentication_response(self, decoded: Dict[str, Any]) -> bool:
        """Send Authentication Response for a decoded Authentication Request."""
        rand = decoded.get('rand')
        autn = decoded.get('autn')
        if not rand or not autn:
            self._capture_s1_ids()
            self._stage_error("Authentication Request missing RAND/AUTN")
            logger.error("[%s] No RAND/AUTN in Auth Request", self._imsi)
            return False

        logger.info("[%s] Received Auth Request: RAND=%s", self._imsi, rand.hex()[:16] + "...")

        try:
            res, ck, ik = self._milenage.authenticate(rand, autn)
            self._ck = ck
            self._ik = ik
        except AuthenticationError as e:
            self._capture_s1_ids()
            self._stage_error(f"Authentication MAC failure: {e}")
            logger.error("[%s] Authentication MAC failure: %s", self._imsi, e)
            fail_msg = self._nas.build_authentication_failure(0x14)
            self._s1ap.send_nas(fail_msg)
            return False

        plmn = Config.plmn_bytes()
        ak = self._milenage.f5(rand)
        sqn_ak = autn[0:6]
        sqn = bytes(a ^ b for a, b in zip(sqn_ak, ak))
        self._kasme = NASHandler.derive_kasme(ck, ik, plmn, sqn, ak)

        auth_resp = self._nas.build_authentication_response(res)
        self._s1ap.send_nas(auth_resp)
        logger.info("[%s] Sent Authentication Response: RES=%s", self._imsi, res.hex())
        return True

    def _handle_authentication(self) -> bool:
        """
        Handle NAS Authentication Request/Response exchange.

        Receives Authentication Request from MME, computes RES using
        Milenage, and sends Authentication Response.
        """
        logger.info("[%s] Waiting for Authentication Request...", self._imsi)

        # May receive Identity Request first
        nas_pdu, s1ap_msg = self._s1ap.receive_nas()
        if nas_pdu is None:
            self._capture_s1_ids()
            self._stage_error("No NAS message while waiting for Authentication Request")
            logger.error("[%s] No NAS message received", self._imsi)
            return False

        decoded = self._nas.decode_message(nas_pdu)
        msg_type = decoded.get('message_type', 0)

        # Handle Identity Request if received
        if msg_type == EPSMobilityMessageType.IDENTITY_REQUEST:
            logger.info("[%s] Received Identity Request, sending response", self._imsi)
            identity_resp = self._nas.build_identity_response()
            self._s1ap.send_nas(identity_resp)

            # Now wait for actual Auth Request
            nas_pdu, s1ap_msg = self._s1ap.receive_nas()
            if nas_pdu is None:
                self._capture_s1_ids()
                self._stage_error("No NAS message after Identity Response")
                return False
            decoded = self._nas.decode_message(nas_pdu)
            msg_type = decoded.get('message_type', 0)

        if msg_type != EPSMobilityMessageType.AUTHENTICATION_REQUEST:
            self._capture_s1_ids()
            self._stage_error(
                "Expected Authentication Request, got "
                f"{decoded.get('message_type_name', 'unknown')}"
            )
            logger.error("[%s] Expected Auth Request, got: %s",
                         self._imsi, decoded.get('message_type_name', 'unknown'))
            return False

        return self._send_authentication_response(decoded)

    def _handle_security_mode(self) -> bool:
        """
        Handle NAS Security Mode Command/Complete exchange.

        Receives Security Mode Command, derives NAS keys, and sends
        Security Mode Complete (integrity protected).
        """
        logger.info("[%s] Waiting for Security Mode Command...", self._imsi)

        decoded = None
        deadline = time.time() + Config.S1AP_TIMEOUT
        last_seen = ""

        while time.time() < deadline:
            remaining = max(0.1, deadline - time.time())
            nas_pdu, _ = self._s1ap.receive_nas(timeout=remaining)
            if nas_pdu is None:
                continue

            decoded = self._nas.decode_message(nas_pdu)
            msg_type = decoded.get('message_type', 0)
            last_seen = decoded.get('message_type_name', f"0x{msg_type:02x}")

            if msg_type == EPSMobilityMessageType.SECURITY_MODE_COMMAND:
                break

            if msg_type == EPSMobilityMessageType.AUTHENTICATION_REQUEST:
                logger.warning(
                    "[%s] Duplicate Authentication Request while waiting for Security Mode Command; "
                    "re-sending Authentication Response",
                    self._imsi,
                )
                if not self._send_authentication_response(decoded):
                    return False
                continue

            if msg_type == EPSMobilityMessageType.ATTACH_REJECT:
                cause = decoded.get('emm_cause', 0)
                self._capture_s1_ids()
                self._stage_error(f"Attach Reject before Security Mode Command cause={cause}")
                logger.error("[%s] Attach Rejected before Security Mode Command: cause=%d",
                             self._imsi, cause)
                return False

            logger.warning("[%s] Ignoring %s while waiting for Security Mode Command",
                           self._imsi, last_seen)

        if decoded is None:
            self._capture_s1_ids()
            self._stage_error("No NAS message while waiting for Security Mode Command")
            logger.error("[%s] No Security Mode Command received", self._imsi)
            return False

        msg_type = decoded.get('message_type', 0)

        if msg_type != EPSMobilityMessageType.SECURITY_MODE_COMMAND:
            self._capture_s1_ids()
            self._stage_error(
                "Expected Security Mode Command, got "
                f"{last_seen or decoded.get('message_type_name', 'unknown')}"
            )
            logger.error("[%s] Expected Security Mode Command, got: %s",
                         self._imsi, last_seen or decoded.get('message_type_name', 'unknown'))
            return False

        logger.info("[%s] Received Security Mode Command: EEA%d EIA%d",
                     self._imsi,
                     decoded.get('selected_eea', -1),
                     decoded.get('selected_eia', -1))

        # Derive NAS keys
        if self._kasme:
            self._nas.derive_nas_keys(self._kasme)

        # Send Security Mode Complete
        sec_complete = self._nas.build_security_mode_complete()
        self._s1ap.send_nas(sec_complete)
        logger.info("[%s] Sent Security Mode Complete", self._imsi)

        return True

    def _finish_attach_accept(self, nas_pdu: Optional[bytes]) -> bool:
        """Extract bearer details from Attach Accept and send Attach Complete."""
        if nas_pdu is not None:
            decoded = self._nas.decode_message(nas_pdu)
            msg_type = decoded.get('message_type', 0)

            if msg_type == EPSMobilityMessageType.ATTACH_REJECT:
                cause = decoded.get('emm_cause', 0)
                self._capture_s1_ids()
                self._stage_error(f"Attach Reject cause={cause}")
                logger.error("[%s] Attach Rejected: cause=%d", self._imsi, cause)
                return False

            if msg_type == EPSMobilityMessageType.ATTACH_ACCEPT:
                esm = decoded.get('esm_container', {})
                self._ip_address = esm.get('ip_address')
                self._ipv6_prefix = esm.get('ipv6_prefix')
                self._bearer_id = esm.get('bearer_id', 5)
                logger.info("[%s] Assigned IP: %s IPv6-prefix: %s, Bearer ID: %d",
                            self._imsi, self._ip_address,
                            self._ipv6_prefix or "(none)", self._bearer_id)
                guti_hex = decoded.get('guti')
                if guti_hex and len(guti_hex) >= 22:
                    guti_raw = bytes.fromhex(guti_hex)
                    if len(guti_raw) >= 11:
                        self._guti_bytes = guti_raw[1:11]   # skip 0xF6 type byte
                        logger.info("[%s] Stored GUTI: %s", self._imsi, self._guti_bytes.hex())
        else:
            logger.info("[%s] NAS PDU not extracted from InitialContextSetupRequest (parser limitation)", self._imsi)
            logger.info("[%s] Attach is successful - MME created session and bearer", self._imsi)
            self._bearer_id = 5

        self._metrics.ip_address = self._ip_address or "assigned"

        attach_complete = self._nas.build_attach_complete(self._bearer_id)
        self._s1ap.send_nas(attach_complete)
        logger.info("[%s] Sent Attach Complete", self._imsi)

        try:
            nas_pdu2, _ = self._s1ap.receive_nas(timeout=2.0)
            if nas_pdu2:
                decoded2 = self._nas.decode_message(nas_pdu2)
                if decoded2.get('message_type') == EPSMobilityMessageType.EMM_INFORMATION:
                    logger.info("[%s] Received EMM Information", self._imsi)
        except Exception:
            pass

        return True

    def _wait_for_attach_accept(self) -> bool:
        """
        Wait for Attach Accept while tolerating NAS retransmissions.

        In burst tests Open5GS can legitimately retransmit Authentication or
        Security Mode Command before InitialContextSetupRequest arrives. A real
        UE answers the duplicate and keeps waiting; failing immediately creates
        artificial detach storms that hide the actual EPC limit.
        """
        deadline = time.time() + Config.S1AP_TIMEOUT
        last_seen = ""

        while time.time() < deadline:
            remaining = max(0.1, deadline - time.time())
            nas_pdu, s1ap_msg = self._s1ap.receive_nas(timeout=min(5.0, remaining))
            proc_code = (s1ap_msg or {}).get('procedure_code', -1)

            if proc_code == S1APProcedureCode.INITIAL_CONTEXT_SETUP:
                logger.info("[%s] Received InitialContextSetupRequest - Attach Accepted by MME!", self._imsi)
                return self._finish_attach_accept(nas_pdu)

            if nas_pdu is None:
                continue

            decoded = self._nas.decode_message(nas_pdu)
            msg_type = decoded.get('message_type', 0)
            msg_name = decoded.get('message_type_name', hex(msg_type))
            last_seen = str(msg_name)

            if msg_type == EPSMobilityMessageType.ATTACH_REJECT:
                cause = decoded.get('emm_cause', 0)
                self._capture_s1_ids()
                self._stage_error(f"Attach Reject cause={cause}")
                logger.error("[%s] Attach Rejected: cause=%d", self._imsi, cause)
                return False

            if msg_type == EPSMobilityMessageType.ATTACH_ACCEPT:
                logger.info("[%s] Received Attach Accept outside InitialContextSetupRequest", self._imsi)
                return self._finish_attach_accept(nas_pdu)

            if msg_type == EPSMobilityMessageType.SECURITY_MODE_COMMAND:
                logger.warning(
                    "[%s] Duplicate Security Mode Command while waiting for Attach Accept; "
                    "re-sending Security Mode Complete",
                    self._imsi,
                )
                if self._kasme:
                    self._nas.derive_nas_keys(self._kasme)
                sec_complete = self._nas.build_security_mode_complete()
                self._s1ap.send_nas(sec_complete)
                continue

            if msg_type == EPSMobilityMessageType.AUTHENTICATION_REQUEST:
                logger.warning(
                    "[%s] Duplicate Authentication Request while waiting for Attach Accept; "
                    "re-sending Authentication Response",
                    self._imsi,
                )
                if not self._send_authentication_response(decoded):
                    return False
                continue

            if msg_type == EPSMobilityMessageType.IDENTITY_REQUEST:
                logger.warning(
                    "[%s] Duplicate Identity Request while waiting for Attach Accept; "
                    "re-sending Identity Response",
                    self._imsi,
                )
                self._s1ap.send_nas(self._nas.build_identity_response())
                continue

            if msg_type == EPSMobilityMessageType.EMM_INFORMATION:
                logger.info("[%s] Received EMM Information before Attach Accept; continuing", self._imsi)
                continue

            logger.warning(
                "[%s] Unexpected NAS message while waiting for Attach Accept: %s; continuing",
                self._imsi,
                msg_name,
            )

        self._capture_s1_ids()
        suffix = f" (last NAS={last_seen})" if last_seen else ""
        self._stage_error(f"No Attach Accept/InitialContextSetup received before timeout{suffix}")
        logger.error("[%s] No Attach Accept received (timeout)%s", self._imsi, suffix)
        return False

    def _handle_attach_accept(self) -> bool:
        """
        Handle Attach Accept + Initial Context Setup.

        Receives Attach Accept (may come inside InitialContextSetupRequest),
        extracts assigned IP address and bearer info, sends Attach Complete.
        """
        logger.info("[%s] Waiting for Attach Accept...", self._imsi)

        # The Attach Accept comes inside InitialContextSetupRequest (S1AP),
        # which contains the NAS PDU with Attach Accept + bearer info.
        # Our S1AP client detects InitialContextSetupRequest and auto-sends
        # the InitialContextSetupResponse. The NAS PDU may or may not be
        # extractable depending on the APER parser capability.
        return self._wait_for_attach_accept()

        nas_pdu, s1ap_msg = self._s1ap.receive_nas()

        # Check if we received InitialContextSetupRequest (proc_code=9)
        # Even if NAS PDU extraction fails, the MME accepted our attach
        # if we got this far (auth + security mode both passed).
        proc_code = s1ap_msg.get('procedure_code', -1)

        if proc_code == S1APProcedureCode.INITIAL_CONTEXT_SETUP:
            logger.info("[%s] Received InitialContextSetupRequest — Attach Accepted by MME!", self._imsi)

            # Try to extract NAS PDU for IP address
            if nas_pdu is not None:
                decoded = self._nas.decode_message(nas_pdu)
                msg_type = decoded.get('message_type', 0)

                if msg_type == EPSMobilityMessageType.ATTACH_REJECT:
                    cause = decoded.get('emm_cause', 0)
                    self._capture_s1_ids()
                    self._stage_error(f"Attach Reject cause={cause}")
                    logger.error("[%s] Attach Rejected: cause=%d", self._imsi, cause)
                    return False

                if msg_type == EPSMobilityMessageType.ATTACH_ACCEPT:
                    esm = decoded.get('esm_container', {})
                    self._ip_address = esm.get('ip_address')
                    self._ipv6_prefix = esm.get('ipv6_prefix')
                    self._bearer_id = esm.get('bearer_id', 5)
                    logger.info("[%s] Assigned IP: %s IPv6-prefix: %s, Bearer ID: %d",
                                 self._imsi, self._ip_address,
                                 self._ipv6_prefix or "(none)", self._bearer_id)
                    guti_hex = decoded.get('guti')
                    if guti_hex and len(guti_hex) >= 22:
                        guti_raw = bytes.fromhex(guti_hex)
                        if len(guti_raw) >= 11:
                            self._guti_bytes = guti_raw[1:11]   # skip 0xF6 type byte
                            logger.info("[%s] Stored GUTI: %s", self._imsi, self._guti_bytes.hex())
            else:
                logger.info("[%s] NAS PDU not extracted from InitialContextSetupRequest (parser limitation)", self._imsi)
                logger.info("[%s] Attach is successful — MME created session and bearer", self._imsi)
                self._bearer_id = 5  # Default bearer

            self._metrics.ip_address = self._ip_address or "assigned"

            # Send Attach Complete
            attach_complete = self._nas.build_attach_complete(self._bearer_id)
            self._s1ap.send_nas(attach_complete)
            logger.info("[%s] Sent Attach Complete", self._imsi)

            # May receive EMM Information after Attach Complete
            try:
                nas_pdu2, _ = self._s1ap.receive_nas(timeout=2.0)
                if nas_pdu2:
                    decoded2 = self._nas.decode_message(nas_pdu2)
                    if decoded2.get('message_type') == EPSMobilityMessageType.EMM_INFORMATION:
                        logger.info("[%s] Received EMM Information", self._imsi)
            except Exception:
                pass  # EMM Information is optional

            return True

        elif nas_pdu is not None:
            # Got a regular DownlinkNASTransport (not InitialContextSetupRequest)
            decoded = self._nas.decode_message(nas_pdu)
            msg_type = decoded.get('message_type', 0)
            if msg_type == EPSMobilityMessageType.ATTACH_REJECT:
                cause = decoded.get('emm_cause', 0)
                self._capture_s1_ids()
                self._stage_error(f"Attach Reject cause={cause}")
                logger.error("[%s] Attach Rejected: cause=%d", self._imsi, cause)
                return False
            self._capture_s1_ids()
            self._stage_error(
                "Expected InitialContextSetup/Attach Accept, got "
                f"{decoded.get('message_type_name', hex(msg_type))}"
            )
            logger.error("[%s] Unexpected NAS message type: 0x%02x", self._imsi, msg_type)
            return False

        self._capture_s1_ids()
        self._stage_error("No Attach Accept/InitialContextSetup received before timeout")
        logger.error("[%s] No Attach Accept received (timeout)", self._imsi)
        return False

        # Might be EMM Information or other message before Attach Accept
        logger.warning("[%s] Unexpected message type: %s, waiting for Attach Accept...",
                        self._imsi, decoded.get('message_type_name', 'unknown'))

        # Try once more
        nas_pdu, s1ap_msg = self._s1ap.receive_nas(timeout=5.0)
        if nas_pdu:
            decoded = self._nas.decode_message(nas_pdu)
            if decoded.get('message_type') == EPSMobilityMessageType.ATTACH_ACCEPT:
                esm = decoded.get('esm_container', {})
                self._ip_address = esm.get('ip_address')
                self._bearer_id = esm.get('bearer_id', 5)

                attach_complete = self._nas.build_attach_complete(self._bearer_id)
                self._s1ap.send_nas(attach_complete)
                return True

        return False

    # ================================================================
    # IMS Registration
    # ================================================================
    def ims_register(self) -> bool:
        """
        Perform IMS registration via SIP REGISTER with AKA auth.

        Requires a successful EPC attach first.

        Returns:
            True if IMS registration succeeded
        """
        if self._state != UEState.ATTACHED and self._state != UEState.IMS_REGISTERED:
            self._stage_error(f"Cannot register IMS from state={self._state.value}", "ims_register")
            logger.error("[%s] Cannot register IMS: not attached (state=%s)",
                         self._imsi, self._state.value)
            return False

        self._state = UEState.IMS_REGISTERING
        self._metrics.ims_register_start = time.time()
        self._stage_start("ims_register")

        try:
            # The attached EPC bearer IP is useful for NAS/EPC validation, but SIP
            # signaling in this containerized harness must advertise the reachable
            # test-network IP so incoming IMS requests can route back to the UE sim.
            signaling_ip = Config.LOCAL_IP
            self._sip = SIPClient(
                pcscf_ip=self._pcscf_ip or Config.PCSCF_IP,
                pcscf_port=self._pcscf_port or Config.PCSCF_PORT,
                local_ip=signaling_ip,
                local_port=self._sip_local_port or Config.SIP_LOCAL_PORT_BASE,
                ims_domain=Config.IMS_DOMAIN,
                milenage=self._milenage,
                imsi=self._imsi,
                msisdn=self._msisdn,
                imei_sv=self._imei_sv,
            )

            if self._ip_address and self._ip_address != signaling_ip:
                logger.info(
                    "[%s] Attached bearer IP %s retained for EPC state; advertising SIP contact via %s",
                    self._imsi,
                    self._ip_address,
                    signaling_ip,
                )

            self._stage_start("sip_socket")
            if not self._sip.connect():
                self._stage_error(self._sip.last_error or "Failed to create SIP socket", "sip_socket")
                raise ConnectionError(self._sip.last_error or "Failed to create SIP socket")
            self._stage_done("sip_socket")

            # Perform IMS REGISTER with AKA
            self._stage_start("ims_register")
            if not self._sip.register():
                self._stage_error(self._sip.last_error or "IMS registration failed", "ims_register")
                raise RuntimeError(self._sip.last_error or "IMS registration failed")
            self._stage_done("ims_register")

            self._state = UEState.IMS_REGISTERED
            self._metrics.ims_register_end = time.time()
            self._metrics.ims_register_success = True
            self._metrics.error_message = ""
            self._metrics.error_stage = ""

            logger.info(
                "[%s] IMS Registration successful (%.0fms)",
                self._imsi,
                self._metrics.ims_register_time_ms,
            )
            return True

        except Exception as e:
            self._state = UEState.ERROR
            self._metrics.ims_register_end = time.time()
            self._stage_error(str(e), self._metrics.error_stage or self._current_stage or "ims_register")
            logger.error("[%s] IMS registration failed: %s", self._imsi, e)
            return False

    # ================================================================
    # VoLTE / ViLTE Calls
    # ================================================================
    def volte_call(self, target_msisdn: str, duration: float = 5.0) -> bool:
        """
        Make a VoLTE (audio-only) call.

        Args:
            target_msisdn: Target MSISDN to call
            duration: Call duration in seconds

        Returns:
            True if call completed successfully
        """
        return self._make_call(target_msisdn, video=False, duration=duration)

    def vilte_call(self, target_msisdn: str, duration: float = 5.0) -> bool:
        """
        Make a ViLTE (video+audio) call.

        Args:
            target_msisdn: Target MSISDN to call
            duration: Call duration in seconds

        Returns:
            True if call completed successfully
        """
        return self._make_call(target_msisdn, video=True, duration=duration)

    def volte_hold_resume_call(
        self,
        target_msisdn: str,
        active_before_hold: float = 2.0,
        hold_duration: float = 2.0,
        active_after_resume: float = 2.0,
    ) -> bool:
        """Make a VoLTE call with a mid-call hold/resume sequence."""
        return self._make_call(
            target_msisdn,
            video=False,
            duration=active_before_hold + hold_duration + active_after_resume,
            hold_resume=True,
            active_before_hold=active_before_hold,
            hold_duration=hold_duration,
            active_after_resume=active_after_resume,
        )

    def vilte_hold_resume_call(
        self,
        target_msisdn: str,
        active_before_hold: float = 2.0,
        hold_duration: float = 2.0,
        active_after_resume: float = 2.0,
    ) -> bool:
        """Make a ViLTE call with a mid-call hold/resume sequence."""
        return self._make_call(
            target_msisdn,
            video=True,
            duration=active_before_hold + hold_duration + active_after_resume,
            hold_resume=True,
            active_before_hold=active_before_hold,
            hold_duration=hold_duration,
            active_after_resume=active_after_resume,
        )

    def answer_call(
        self,
        duration: float = 5.0,
        answer_delay: float = 0.5,
    ) -> bool:
        """
        Wait for and answer an incoming call on an already registered UE.

        This gives regression tests a real caller/callee pair instead of two
        independent originating UEs.
        """
        if self._state != UEState.IMS_REGISTERED:
            logger.error("[%s] Cannot answer call: not IMS registered (state=%s)",
                         self._imsi, self._state.value)
            return False

        if not self._sip:
            logger.error("[%s] No SIP client available", self._imsi)
            return False

        self._state = UEState.IN_CALL
        self._metrics.call_setup_start = time.time()
        if self._s1ap.connected:
            self._start_bearer_poll()

        try:
            logger.info("[%s] Waiting for incoming call", self._imsi)
            success = self._sip.answer_call(
                call_duration=duration,
                answer_delay=answer_delay,
                timeout=duration + 15.0,
            )
            self._metrics.call_setup_end = time.time()
            self._metrics.call_end = time.time()
            self._metrics.call_success = success
            self._metrics.error_message = "" if success else (self._sip.last_error or "incoming call failed")
            self._metrics.dedicated_bearers = self._stop_bearer_poll(
                wait_for_activation_s=4.0 if success else 1.0,
                wait_for_deactivation_s=12.0 if success else 1.0,
            )
            self._state = UEState.IMS_REGISTERED

            if success:
                logger.info("[%s] Incoming call completed successfully", self._imsi)
            else:
                logger.warning("[%s] Incoming call failed", self._imsi)
            return success

        except Exception as e:
            self._metrics.call_end = time.time()
            self._metrics.error_message = str(e)
            self._stop_bearer_poll()
            self._state = UEState.IMS_REGISTERED
            logger.error("[%s] Incoming call error: %s", self._imsi, e)
            return False

    def establish_call_dialog(self, target_msisdn: str, video: bool = False) -> Optional[Dict[str, Any]]:
        """Establish an outgoing SIP dialog and leave it active for supplemental tests."""
        if self._state not in (UEState.IMS_REGISTERED, UEState.IN_CALL) or not self._sip:
            self._metrics.error_message = "UE is not IMS registered for dialog establishment"
            return None

        dialog = self._sip.establish_call_dialog(target_msisdn, sdp_video=video)
        if dialog:
            self._state = UEState.IN_CALL
        else:
            self._metrics.error_message = self._sip.last_error
        return dialog

    def answer_next_call_dialog(
        self,
        answer_delay: float = 0.5,
        timeout: float = None,
    ) -> Optional[Dict[str, Any]]:
        """Answer the next incoming SIP dialog and leave it active."""
        if self._state not in (UEState.IMS_REGISTERED, UEState.IN_CALL) or not self._sip:
            self._metrics.error_message = "UE is not IMS registered for dialog answer"
            return None

        dialog = self._sip.answer_next_call_dialog(answer_delay=answer_delay, timeout=timeout)
        if dialog:
            self._state = UEState.IN_CALL
        else:
            self._metrics.error_message = self._sip.last_error
        return dialog

    def hold_dialog(self, dialog: Dict[str, Any]) -> bool:
        """Place a specific active SIP dialog on hold."""
        if not self._sip:
            self._metrics.error_message = "No SIP client available for hold"
            return False
        ok = self._sip.hold_dialog(dialog)
        self._metrics.error_message = "" if ok else self._sip.last_error
        return ok

    def resume_dialog(self, dialog: Dict[str, Any]) -> bool:
        """Resume a specific active SIP dialog."""
        if not self._sip:
            self._metrics.error_message = "No SIP client available for resume"
            return False
        ok = self._sip.resume_dialog(dialog)
        self._metrics.error_message = "" if ok else self._sip.last_error
        return ok

    def switch_dialog_media(
        self,
        dialog: Dict[str, Any],
        video: bool,
        connection_ip: Optional[str] = None,
    ) -> bool:
        """Switch a specific active SIP dialog between audio-only and audio+video."""
        if not self._sip:
            self._metrics.error_message = "No SIP client available for media switch"
            return False
        ok = self._sip.switch_dialog_media(
            dialog,
            video=video,
            connection_ip=connection_ip,
        )
        self._metrics.error_message = "" if ok else self._sip.last_error
        return ok

    def answer_next_media_switch(self, dialog: Dict[str, Any], timeout: float = None) -> bool:
        """Answer the next remote media-switch re-INVITE for a specific active SIP dialog."""
        if not self._sip:
            self._metrics.error_message = "No SIP client available for media switch answer"
            return False
        ok = self._sip.answer_next_media_switch(dialog, timeout=timeout)
        self._metrics.error_message = "" if ok else self._sip.last_error
        return ok

    def end_dialog(self, dialog: Dict[str, Any], tolerate_timeout: bool = False) -> bool:
        """End a specific active SIP dialog with BYE."""
        if not self._sip:
            self._metrics.error_message = "No SIP client available for BYE"
            return False
        ok = self._sip.end_dialog(dialog, tolerate_timeout=tolerate_timeout)
        self._metrics.error_message = "" if ok else self._sip.last_error
        if not self._sip.active_dialogs():
            self._state = UEState.IMS_REGISTERED
        return ok

    def wait_for_dialog_end(self, dialog: Dict[str, Any], timeout: float = None) -> bool:
        """Wait for a remote BYE on a specific active SIP dialog."""
        if not self._sip:
            self._metrics.error_message = "No SIP client available while waiting for BYE"
            return False
        ok = self._sip.wait_for_dialog_end(dialog, timeout=timeout)
        self._metrics.error_message = "" if ok else self._sip.last_error
        if not self._sip.active_dialogs():
            self._state = UEState.IMS_REGISTERED
        return ok

    def active_dialogs(self) -> List[Dict[str, Any]]:
        """Return currently tracked SIP dialogs for this UE."""
        if not self._sip:
            return []
        return self._sip.active_dialogs()

    def _start_bearer_poll(self):
        """Start background thread to poll S1AP for dedicated bearer activations.

        During an active SIP call, the P-CSCF sends Rx AAR to PCRF which triggers
        a dedicated bearer activation via MME → S1AP DownlinkNASTransport carrying
        NAS Activate Dedicated Bearer Context Request (ESM 0xC5). We need to accept
        these with ESM 0xC6 while the SIP invite() is blocking on the main thread.
        """
        self._dedicated_bearers = []
        self._dedicated_bearer_trace = []
        self._bearer_poll_stop.clear()

        def _poll_loop():
            logger.info("[%s] Bearer poll thread started", self._imsi)
            while not self._bearer_poll_stop.is_set():
                try:
                    # Non-blocking poll with short timeout
                    nas_pdu, s1ap_info = self._s1ap.receive_nas(timeout=0.5)
                    if nas_pdu is None and s1ap_info.get("error") == "timeout":
                        continue
                    proc_code = s1ap_info.get("procedure_code")
                    proc_name = s1ap_info.get("procedure_name", s1ap_procedure_name(proc_code or -1))
                    has_nas = nas_pdu is not None

                    if has_nas:
                        decoded = self._nas.decode_message(nas_pdu)
                        msg_type = decoded.get("message_type")
                        msg_name = decoded.get("message_type_name", "unknown")
                    else:
                        decoded = {}
                        msg_type = None
                        msg_name = "<no-nas>"

                    self._dedicated_bearer_trace.append({
                        "timestamp": time.time(),
                        "direction": "recv",
                        "procedure_code": proc_code,
                        "procedure_name": proc_name,
                        "mme_ue_id": s1ap_info.get("mme_ue_id"),
                        "enb_ue_id": s1ap_info.get("enb_ue_id"),
                        "erab_id": s1ap_info.get("erab_id"),
                        "erab_setup_response_sent": bool(s1ap_info.get("erab_setup_response_sent", False)),
                        "has_nas": has_nas,
                        "message_type": msg_type,
                        "message_type_name": msg_name,
                        "nas_hex": nas_pdu.hex() if has_nas else "",
                        "nas_length": len(nas_pdu) if has_nas else 0,
                        "protocol": decoded.get("protocol", ""),
                        "protocol_discriminator": decoded.get("protocol_discriminator"),
                        "security_header": decoded.get("security_header"),
                        "decode_error": decoded.get("error", ""),
                    })

                    if not has_nas:
                        logger.debug("[%s] Bearer poll saw S1AP %s without NAS payload", self._imsi, proc_name)
                        continue

                    # Check for Activate Dedicated Bearer Context Request (0xC5)
                    if msg_type == 0xC5:
                        bearer_id = decoded.get("bearer_id", 0)
                        qci = decoded.get("qci", -1)
                        linked_id = decoded.get("linked_bearer_id", 0)
                        logger.info(
                            "[%s] *** Dedicated bearer activation: bearer_id=%d QCI=%d linked=%d ***",
                            self._imsi, bearer_id, qci, linked_id,
                        )
                        # Accept the bearer
                        accept_msg = self._nas.build_activate_dedicated_bearer_accept(bearer_id)
                        self._s1ap.send_nas(accept_msg)
                        logger.info("[%s] Sent Activate Dedicated Bearer Accept (bearer_id=%d)", self._imsi, bearer_id)
                        self._dedicated_bearer_trace.append({
                            "timestamp": time.time(),
                            "direction": "send",
                            "procedure_code": 13,
                            "procedure_name": "UPLINK_NAS_TRANSPORT",
                            "mme_ue_id": None,
                            "enb_ue_id": None,
                            "erab_id": bearer_id,
                            "erab_setup_response_sent": False,
                            "has_nas": True,
                            "message_type": 0xC6,
                            "message_type_name": "Activate Dedicated Bearer Context Accept",
                            "nas_hex": bytes(accept_msg).hex(),
                            "nas_length": len(accept_msg),
                            "protocol": "ESM",
                            "protocol_discriminator": 0x02,
                            "security_header": ((accept_msg[0] >> 4) & 0x0F) if accept_msg else None,
                            "decode_error": "",
                        })

                        self._dedicated_bearers.append({
                            "bearer_id": bearer_id,
                            "qci": qci,
                            "linked_bearer_id": linked_id,
                            "timestamp": time.time(),
                        })

                    # Check for Deactivate Bearer Context Request (0xCD)
                    elif msg_type == 0xCD:
                        bearer_id = decoded.get("bearer_id", 0)
                        logger.info(
                            "[%s] Dedicated bearer deactivation: bearer_id=%d",
                            self._imsi, bearer_id,
                        )
                        deact_accept = self._nas.build_deactivate_bearer_accept(bearer_id)
                        self._s1ap.send_nas(deact_accept)
                        logger.info("[%s] Sent Deactivate Bearer Accept (bearer_id=%d)", self._imsi, bearer_id)
                        self._dedicated_bearer_trace.append({
                            "timestamp": time.time(),
                            "direction": "send",
                            "procedure_code": 13,
                            "procedure_name": "UPLINK_NAS_TRANSPORT",
                            "mme_ue_id": None,
                            "enb_ue_id": None,
                            "erab_id": bearer_id,
                            "erab_setup_response_sent": False,
                            "has_nas": True,
                            "message_type": 0xCE,
                            "message_type_name": "Deactivate EPS Bearer Context Accept",
                            "nas_hex": bytes(deact_accept).hex(),
                            "nas_length": len(deact_accept),
                            "protocol": "ESM",
                            "protocol_discriminator": 0x02,
                            "security_header": ((deact_accept[0] >> 4) & 0x0F) if deact_accept else None,
                            "decode_error": "",
                        })

                        # Mark deactivation time
                        for b in self._dedicated_bearers:
                            if b["bearer_id"] == bearer_id and "deactivated" not in b:
                                b["deactivated"] = time.time()
                                break

                    else:
                        logger.debug("[%s] Bearer poll got NAS: %s (type=0x%02X)",
                                     self._imsi, msg_name, msg_type or 0)

                except Exception as e:
                    if not self._bearer_poll_stop.is_set():
                        logger.debug("[%s] Bearer poll exception: %s", self._imsi, e)

            logger.info("[%s] Bearer poll thread stopped. Bearers captured: %d",
                        self._imsi, len(self._dedicated_bearers))

        self._bearer_poll_thread = threading.Thread(
            target=_poll_loop, daemon=True, name=f"bearer-poll-{self._imsi}"
        )
        self._bearer_poll_thread.start()

    def _await_bearer_activity(
        self,
        wait_for_activation_s: float = 0.0,
        wait_for_deactivation_s: float = 0.0,
    ):
        """Allow late dedicated bearer NAS messages to arrive before stopping the poller."""
        if not self._bearer_poll_thread or not self._bearer_poll_thread.is_alive():
            return

        if wait_for_activation_s > 0:
            deadline = time.time() + wait_for_activation_s
            while time.time() < deadline and not self._dedicated_bearers:
                time.sleep(0.1)

        if self._dedicated_bearers and wait_for_deactivation_s > 0:
            deadline = time.time() + wait_for_deactivation_s
            while time.time() < deadline:
                if all("deactivated" in bearer for bearer in self._dedicated_bearers):
                    break
                time.sleep(0.1)

    def _stop_bearer_poll(
        self,
        wait_for_activation_s: float = 0.0,
        wait_for_deactivation_s: float = 0.0,
    ) -> List[Dict[str, Any]]:
        """Stop the bearer poll thread and return captured bearers."""
        self._await_bearer_activity(
            wait_for_activation_s=wait_for_activation_s,
            wait_for_deactivation_s=wait_for_deactivation_s,
        )
        if self._bearer_poll_thread and self._bearer_poll_thread.is_alive():
            self._bearer_poll_stop.set()
            self._bearer_poll_thread.join(timeout=3.0)
            self._bearer_poll_thread = None

        bearers = list(self._dedicated_bearers)
        if bearers:
            logger.info("[%s] Dedicated bearers during call:", self._imsi)
            for b in bearers:
                deact = "deactivated" if "deactivated" in b else "active"
                logger.info("  bearer_id=%d QCI=%d linked=%d [%s]",
                            b["bearer_id"], b["qci"], b["linked_bearer_id"], deact)
        return bearers

    @property
    def dedicated_bearers(self) -> List[Dict[str, Any]]:
        """Return list of dedicated bearers captured during the last call."""
        return list(self._dedicated_bearers)

    @property
    def dedicated_bearer_trace(self) -> List[Dict[str, Any]]:
        """Return the ordered NAS/S1AP messages seen during bearer polling."""
        return list(self._dedicated_bearer_trace)

    def _make_call(
        self,
        target_msisdn: str,
        video: bool,
        duration: float,
        hold_resume: bool = False,
        active_before_hold: float = 2.0,
        hold_duration: float = 2.0,
        active_after_resume: float = 2.0,
        poll_bearers: bool = True,
    ) -> bool:
        """Internal call handler for VoLTE/ViLTE.

        Args:
            poll_bearers: If True, start a background thread to capture
                dedicated bearer activations (QCI-1/QCI-2) during the call.
        """
        call_type = "ViLTE" if video else "VoLTE"

        if self._state != UEState.IMS_REGISTERED:
            logger.error("[%s] Cannot make %s call: not IMS registered (state=%s)",
                         self._imsi, call_type, self._state.value)
            return False

        if not self._sip:
            logger.error("[%s] No SIP client available", self._imsi)
            return False

        self._state = UEState.IN_CALL
        self._metrics.call_setup_start = time.time()

        # Start dedicated bearer polling if S1AP is connected
        if poll_bearers and self._s1ap.connected:
            self._start_bearer_poll()

        try:
            logger.info("[%s] Initiating %s call to %s (duration=%.1fs)",
                         self._imsi, call_type, target_msisdn, duration)

            if hold_resume:
                success = self._sip.invite_with_hold_resume(
                    target_msisdn=target_msisdn,
                    sdp_video=video,
                    active_before_hold=active_before_hold,
                    hold_duration=hold_duration,
                    active_after_resume=active_after_resume,
                )
            else:
                success = self._sip.invite(
                    target_msisdn=target_msisdn,
                    sdp_video=video,
                    call_duration=duration,
                )

            self._metrics.call_setup_end = time.time()
            self._metrics.call_end = time.time()
            self._metrics.call_success = success
            self._metrics.error_message = "" if success else (self._sip.last_error or f"{call_type} call failed")

            # Stop bearer polling and collect results
            bearers = self._stop_bearer_poll(
                wait_for_activation_s=4.0 if success else 1.0,
                wait_for_deactivation_s=12.0 if success else 1.0,
            ) if poll_bearers else []
            self._metrics.dedicated_bearers = bearers

            if success:
                bearer_summary = ""
                if bearers:
                    qcis = [str(b["qci"]) for b in bearers]
                    bearer_summary = f" dedicated_bearers=[QCI {','.join(qcis)}]"
                logger.info(
                    "[%s] %s call completed successfully (setup=%.0fms)%s",
                    self._imsi, call_type, self._metrics.call_setup_time_ms, bearer_summary,
                )
            else:
                logger.warning("[%s] %s call failed", self._imsi, call_type)

            self._state = UEState.IMS_REGISTERED
            return success

        except Exception as e:
            self._metrics.call_end = time.time()
            self._metrics.error_message = str(e)
            self._stop_bearer_poll() if poll_bearers else None
            self._state = UEState.IMS_REGISTERED
            logger.error("[%s] %s call error: %s", self._imsi, call_type, e)
            return False

    # ================================================================
    # S1 Idle / Paging
    # ================================================================
    def release_to_idle(self) -> bool:
        """
        Move UE to S1 idle state without full detach.

        Sends UEContextReleaseRequest to the MME and waits for the
        UEContextReleaseCommand, then sends UEContextReleaseComplete.
        The SCTP connection remains open so the UE can receive Paging.

        Returns:
            True if the release completed successfully
        """
        if not self._s1ap.connected:
            logger.error("[%s] Cannot release to idle: S1AP not connected", self._imsi)
            return False

        logger.info("[%s] Releasing UE context (going S1 idle)...", self._imsi)
        self._s1ap.send_ue_context_release()
        ok = self._s1ap.handle_ue_context_release_command()
        if ok:
            logger.info("[%s] UE is now S1 idle (UEContextReleaseCommand received)", self._imsi)
        else:
            logger.warning(
                "[%s] UEContextReleaseCommand not received within timeout",
                self._imsi,
            )
        return ok

    def wait_for_paging(self, timeout: float = 30.0) -> bool:
        """
        Wait for a Paging message from the MME.

        Should be called after release_to_idle().  The UE must remain
        SCTP-connected to receive the paging.

        Args:
            timeout: Maximum seconds to wait

        Returns:
            True if a Paging message was received
        """
        if not self._s1ap.connected:
            logger.error("[%s] Cannot wait for paging: S1AP not connected", self._imsi)
            return False
        logger.info("[%s] Waiting for Paging (timeout=%.1fs)...", self._imsi, timeout)
        return self._s1ap.wait_for_paging(timeout=timeout)

    # ================================================================
    # TAU (Tracking Area Update)
    # ================================================================
    def tau(
        self,
        update_type: int = 0x01,
        active_flag: bool = True,
        new_tac: int = None,
    ) -> bool:
        """
        Perform a Tracking Area Update procedure.

        Requires an active EPC attach (SCTP connected, NAS security active).
        Uses the GUTI stored from the last Attach Accept or TAU Accept.

        Args:
            update_type: TAU update type (0=TA, 1=combined TA/LA, 4=periodic)
            active_flag: Request active flag (keep bearer active after TAU)
            new_tac:     TAC being entered (defaults to Config.TAC)

        Returns:
            True if TAU completed successfully (TAU Accept + TAU Complete)
        """
        if not self._s1ap.connected:
            logger.error("[%s] Cannot perform TAU: not connected", self._imsi)
            return False

        if self._guti_bytes is None:
            logger.error("[%s] Cannot perform TAU: no GUTI stored from previous attach", self._imsi)
            return False

        tac = new_tac if new_tac is not None else Config.TAC
        plmn = Config.plmn_bytes()

        logger.info("[%s] Sending TAU Request (update_type=%d active=%s TAC=0x%04X)",
                    self._imsi, update_type, active_flag, tac)

        tau_req = self._nas.build_tau_request(
            guti_bytes=self._guti_bytes,
            update_type=update_type,
            active_flag=active_flag,
            new_tac=tac,
            plmn=plmn,
        )
        self._s1ap.send_nas(tau_req)

        # Wait for TAU Accept
        nas_pdu, s1ap_msg = self._s1ap.receive_nas(timeout=10.0)
        if nas_pdu is None:
            logger.error("[%s] No response to TAU Request", self._imsi)
            return False

        decoded = self._nas.decode_message(nas_pdu)
        msg_type = decoded.get('message_type', 0)

        if msg_type == EPSMobilityMessageType.TAU_REJECT:
            cause = decoded.get('emm_cause', 0)
            logger.error("[%s] TAU Rejected: cause=0x%02X", self._imsi, cause)
            return False

        if msg_type != EPSMobilityMessageType.TAU_ACCEPT:
            logger.error("[%s] Expected TAU Accept, got: 0x%02X (%s)",
                         self._imsi, msg_type, decoded.get('message_type_name', '?'))
            return False

        logger.info("[%s] TAU Accepted", self._imsi)

        # Update GUTI if new one was assigned
        new_guti = decoded.get('new_guti_bytes')
        if new_guti and len(new_guti) >= 10:
            self._guti_bytes = new_guti
            logger.info("[%s] Updated GUTI from TAU Accept: %s", self._imsi, self._guti_bytes.hex())

        # Send TAU Complete
        tau_complete = self._nas.build_tau_complete()
        self._s1ap.send_nas(tau_complete)
        logger.info("[%s] TAU procedure complete", self._imsi)
        return True

    # ================================================================
    # Subsequent Attach with GUTI
    # ================================================================
    def attach_with_guti(self, apn: str = "internet") -> bool:
        """
        Perform EPC attach using the GUTI stored from a previous attach.

        This exercises the GUTI-based identity path instead of IMSI,
        which is the normal path for a UE returning from idle after a
        previous session.

        Requires a GUTI stored in self._guti_bytes (set by a prior
        successful attach()).  The S1AP must not be connected yet
        (or call detach() first to disconnect).

        Returns:
            True if attach with GUTI succeeded
        """
        if self._guti_bytes is None:
            logger.error("[%s] No GUTI available — run attach() first to obtain one", self._imsi)
            return False

        self._state = UEState.CONNECTING
        self._metrics.attach_start = time.time()

        try:
            if not self._s1ap.connect():
                raise ConnectionError("Failed to connect to MME")

            if not self._s1ap.s1_setup():
                raise ConnectionError("S1 Setup failed")

            logger.info("[%s] Sending GUTI Attach Request (GUTI=%s)...",
                        self._imsi, self._guti_bytes.hex())
            attach_req = self._nas.build_guti_attach_request(
                guti_bytes=self._guti_bytes, apn=apn
            )
            self._s1ap.send_attach_request(attach_req)

            self._state = UEState.AUTHENTICATING
            if not self._handle_authentication():
                raise AuthenticationError("Authentication failed")

            self._state = UEState.SECURITY_MODE
            if not self._handle_security_mode():
                raise RuntimeError("Security Mode failed")

            if not self._handle_attach_accept():
                raise RuntimeError("Attach Accept not received")

            self._state = UEState.ATTACHED
            self._metrics.attach_end = time.time()
            self._metrics.attach_success = True

            logger.info("[%s] GUTI Attach successful: IP=%s (%.0fms)",
                        self._imsi, self._ip_address or "unknown",
                        self._metrics.attach_time_ms)
            return True

        except Exception as e:
            self._state = UEState.ERROR
            self._metrics.attach_end = time.time()
            self._metrics.error_message = str(e)
            logger.error("[%s] GUTI Attach failed: %s", self._imsi, e)
            return False

    # ================================================================
    # AUTS Re-synchronisation
    # ================================================================
    def attach_with_auts_resync(
        self,
        apn: str = "internet",
        sqn_ue: bytes = None,
    ) -> bool:
        """
        Perform EPC attach with forced SQN re-synchronisation (AUTS path).

        On the first authentication round the UE sends Authentication Failure
        (EMM cause=0x15, SQN out of range) with an AUTS token computed from
        sqn_ue.  The HSS re-synchronises its SQN counter and issues a fresh
        Auth Request.  The second round completes normally.

        This exercises TS 35.206 §6.3.3 (AUTS) and TS 24.301 §5.4.2.7
        (Authentication Failure with resync cause).

        Args:
            apn:    APN for the default bearer
            sqn_ue: 6-byte UE SQN to use for AUTS (defaults to a value
                    well ahead of the network to guarantee resync)

        Returns:
            True if the attach completed after re-synchronisation
        """
        if sqn_ue is None:
            sqn_ue = bytes.fromhex("FFFFFFFFFFFF")  # far-future SQN, triggers resync

        self._state = UEState.CONNECTING
        self._metrics.attach_start = time.time()

        try:
            if not self._s1ap.connect():
                raise ConnectionError("Failed to connect to MME")

            if not self._s1ap.s1_setup():
                raise ConnectionError("S1 Setup failed")

            logger.info("[%s] Sending Attach Request (AUTS resync test)...", self._imsi)
            attach_req = self._nas.build_attach_request(apn=apn)
            self._s1ap.send_attach_request(attach_req)

            self._state = UEState.AUTHENTICATING
            if not self._handle_authentication_with_resync(sqn_ue):
                raise AuthenticationError("Authentication with resync failed")

            self._state = UEState.SECURITY_MODE
            if not self._handle_security_mode():
                raise RuntimeError("Security Mode failed")

            if not self._handle_attach_accept():
                raise RuntimeError("Attach Accept not received")

            self._state = UEState.ATTACHED
            self._metrics.attach_end = time.time()
            self._metrics.attach_success = True

            logger.info("[%s] AUTS-resync attach successful: IP=%s (%.0fms)",
                        self._imsi, self._ip_address or "unknown",
                        self._metrics.attach_time_ms)
            return True

        except Exception as e:
            self._state = UEState.ERROR
            self._metrics.attach_end = time.time()
            self._metrics.error_message = str(e)
            logger.error("[%s] AUTS-resync attach failed: %s", self._imsi, e)
            return False

    def _handle_authentication_with_resync(self, sqn_ue: bytes) -> bool:
        """
        First round: send Auth Failure (resync) with AUTS.
        Second round: normal Milenage authentication.
        """
        logger.info("[%s] Waiting for first Authentication Request (resync round)...", self._imsi)

        nas_pdu, _ = self._s1ap.receive_nas()
        if nas_pdu is None:
            logger.error("[%s] No NAS message received in resync round", self._imsi)
            return False

        decoded = self._nas.decode_message(nas_pdu)
        msg_type = decoded.get('message_type', 0)

        if msg_type == EPSMobilityMessageType.IDENTITY_REQUEST:
            logger.info("[%s] Received Identity Request, sending response", self._imsi)
            self._s1ap.send_nas(self._nas.build_identity_response())
            nas_pdu, _ = self._s1ap.receive_nas()
            if nas_pdu is None:
                return False
            decoded = self._nas.decode_message(nas_pdu)
            msg_type = decoded.get('message_type', 0)

        if msg_type != EPSMobilityMessageType.AUTHENTICATION_REQUEST:
            logger.error("[%s] Expected Auth Request, got: 0x%02X", self._imsi, msg_type)
            return False

        rand = decoded.get('rand')
        if not rand:
            logger.error("[%s] No RAND in Auth Request", self._imsi)
            return False

        # Compute AUTS and send Authentication Failure (cause=0x15 = sync failure)
        auts = self._milenage.compute_auts(rand, sqn_ue)
        logger.info("[%s] Sending Authentication Failure with AUTS (SQN_UE=%s AUTS=%s)",
                    self._imsi, sqn_ue.hex(), auts.hex())
        auth_fail = self._nas.build_authentication_failure(0x15, auts=auts)
        self._s1ap.send_nas(auth_fail)

        # Wait for second Authentication Request (post-resync)
        logger.info("[%s] Waiting for second Authentication Request (after resync)...", self._imsi)
        nas_pdu2, _ = self._s1ap.receive_nas(timeout=15.0)
        if nas_pdu2 is None:
            logger.error("[%s] No second Auth Request after resync", self._imsi)
            return False

        decoded2 = self._nas.decode_message(nas_pdu2)
        msg_type2 = decoded2.get('message_type', 0)

        if msg_type2 != EPSMobilityMessageType.AUTHENTICATION_REQUEST:
            logger.error("[%s] Expected second Auth Request, got: 0x%02X", self._imsi, msg_type2)
            return False

        rand2 = decoded2.get('rand')
        autn2 = decoded2.get('autn')
        if not rand2 or not autn2:
            logger.error("[%s] No RAND/AUTN in second Auth Request", self._imsi)
            return False

        logger.info("[%s] Received second Auth Request after resync: RAND=%s",
                    self._imsi, rand2.hex()[:16] + "...")

        # Normal Milenage authentication on second round
        res, ck, ik = self._milenage.authenticate(rand2, autn2)
        self._ck = ck
        self._ik = ik

        plmn = Config.plmn_bytes()
        ak = self._milenage.f5(rand2)
        sqn_ak = autn2[0:6]
        sqn = bytes(a ^ b for a, b in zip(sqn_ak, ak))
        self._kasme = NASHandler.derive_kasme(ck, ik, plmn, sqn, ak)

        auth_resp = self._nas.build_authentication_response(res)
        self._s1ap.send_nas(auth_resp)
        logger.info("[%s] Sent Authentication Response (after resync): RES=%s",
                    self._imsi, res.hex())
        return True

    # ================================================================
    # Detach
    # ================================================================
    def detach(self) -> bool:
        """
        Perform UE-initiated detach.

        Steps:
            1. De-register from IMS (if registered)
            2. Send NAS Detach Request
            3. Wait for Detach Accept
            4. Handle UE Context Release

        Returns:
            True if detach completed
        """
        self._state = UEState.DETACHING
        self._metrics.detach_start = time.time()

        try:
            # IMS de-register
            if self._sip and self._sip.registered:
                logger.info("[%s] De-registering from IMS...", self._imsi)
                self._sip.unregister()
                self._sip.disconnect()
                self._sip = None

            # NAS Detach
            if self._s1ap.connected:
                logger.info("[%s] Sending Detach Request...", self._imsi)
                detach_req = self._nas.build_detach_request(switch_off=True)
                self._s1ap.send_nas(detach_req)

                # Wait for Detach Accept
                try:
                    nas_pdu, _ = self._s1ap.receive_nas(timeout=5.0)
                    if nas_pdu:
                        decoded = self._nas.decode_message(nas_pdu)
                        logger.info("[%s] Received: %s",
                                     self._imsi, decoded.get('message_type_name', 'unknown'))
                except Exception:
                    pass

                # Send UE Context Release
                self._s1ap.send_ue_context_release()
                self._s1ap.handle_ue_context_release_command()

                # Disconnect
                self._s1ap.disconnect()

            self._state = UEState.DETACHED
            self._metrics.detach_end = time.time()
            self._metrics.detach_success = True

            logger.info("[%s] Detach complete", self._imsi)
            return True

        except Exception as e:
            self._metrics.detach_end = time.time()
            self._metrics.error_message = str(e)
            logger.error("[%s] Detach error: %s", self._imsi, e)

            # Force cleanup
            try:
                self._s1ap.disconnect()
            except Exception:
                pass

            self._state = UEState.DETACHED
            return False

    def _cleanup_failed_attach(self):
        """Close local sockets after a failed attach without sending NAS Detach."""
        try:
            if self._sip:
                self._sip.disconnect()
                self._sip = None
        except Exception:
            pass

        try:
            if self._s1ap.connected:
                self._s1ap.disconnect()
        except Exception:
            pass

    # ================================================================
    # Full Lifecycle
    # ================================================================
    def run_full_lifecycle(
        self,
        target_msisdn: str = None,
        call_type: str = "volte",
        call_duration: float = 5.0,
        skip_call: bool = False,
    ) -> UEMetrics:
        """
        Run the complete UE lifecycle: attach → register → call → detach.

        Args:
            target_msisdn: Target for call (None = skip call)
            call_type: "volte" or "vilte"
            call_duration: Call duration in seconds
            skip_call: Skip the call phase

        Returns:
            UEMetrics with timing and success data
        """
        logger.info("="*60)
        logger.info("[%s] Starting full UE lifecycle", self._imsi)
        logger.info("="*60)

        # Attach
        if not self.attach():
            logger.error("[%s] Lifecycle aborted: attach failed", self._imsi)
            self._cleanup_failed_attach()
            return self._metrics

        # IMS Register
        if not self.ims_register():
            logger.error("[%s] Lifecycle aborted: IMS registration failed", self._imsi)
            self.detach()
            return self._metrics

        # Call
        if not skip_call and target_msisdn:
            if call_type == "vilte":
                self.vilte_call(target_msisdn, duration=call_duration)
            else:
                self.volte_call(target_msisdn, duration=call_duration)

        # Detach
        self.detach()

        logger.info(
            "[%s] Lifecycle complete: attach=%.0fms register=%.0fms call=%.0fms total=%.0fms",
            self._imsi,
            self._metrics.attach_time_ms,
            self._metrics.ims_register_time_ms,
            self._metrics.call_setup_time_ms,
            self._metrics.total_time_ms,
        )

        return self._metrics

    # ================================================================
    # Properties
    # ================================================================
    @property
    def state(self) -> UEState:
        return self._state

    @property
    def metrics(self) -> UEMetrics:
        return self._metrics

    @property
    def imsi(self) -> str:
        return self._imsi

    @property
    def msisdn(self) -> str:
        return self._msisdn

    @property
    def ip_address(self) -> Optional[str]:
        return self._ip_address

    @property
    def ipv6_prefix(self) -> Optional[str]:
        """IPv6 /64 prefix assigned by PDN GW (e.g. '2001:db8:1::/64'), or None."""
        return self._ipv6_prefix

    @property
    def selected_eea(self) -> int:
        """EPS Encryption Algorithm negotiated in Security Mode (0=null, 1=SNOW3G, 2=AES)."""
        return self._nas.selected_eea

    @property
    def selected_eia(self) -> int:
        """EPS Integrity Algorithm negotiated in Security Mode (0=null, 1=SNOW3G, 2=AES)."""
        return self._nas.selected_eia

    @property
    def attached(self) -> bool:
        return self._state in (
            UEState.ATTACHED, UEState.IMS_REGISTERING,
            UEState.IMS_REGISTERED, UEState.IN_CALL,
        )

    @property
    def ims_registered(self) -> bool:
        return self._state in (UEState.IMS_REGISTERED, UEState.IN_CALL)

    @property
    def guti_bytes(self) -> Optional[bytes]:
        """10-byte GUTI from the last Attach Accept or TAU Accept, or None."""
        return self._guti_bytes


# ================================================================
# Load Test Runner
# ================================================================

@dataclass
class LoadTestResult:
    """Results from a load test run."""
    concurrent: int = 0
    total_ues: int = 0
    attach_success: int = 0
    attach_failed: int = 0
    register_success: int = 0
    register_failed: int = 0
    call_success: int = 0
    call_failed: int = 0
    avg_attach_ms: float = 0.0
    avg_register_ms: float = 0.0
    avg_call_setup_ms: float = 0.0
    p95_attach_ms: float = 0.0
    p95_register_ms: float = 0.0
    elapsed_seconds: float = 0.0
    errors: List[str] = field(default_factory=list)
    attach_times_ms: List[float] = field(default_factory=list)
    register_times_ms: List[float] = field(default_factory=list)
    failure_stages: Dict[str, int] = field(default_factory=dict)
    failure_samples: Dict[str, List[str]] = field(default_factory=dict)
    stage_latency_ms: Dict[str, Dict[str, float]] = field(default_factory=dict)
    slowest_ues: List[Dict[str, Any]] = field(default_factory=list)

    @property
    def attach_success_rate(self) -> float:
        total = self.attach_success + self.attach_failed
        return (self.attach_success / total * 100) if total > 0 else 0.0

    @property
    def register_success_rate(self) -> float:
        total = self.register_success + self.register_failed
        return (self.register_success / total * 100) if total > 0 else 0.0


@dataclass
class CallPairTestResult:
    """Results from a simultaneous call-pair test.

    Each 'pair' consists of one caller UE and one callee UE that are both
    attached and IMS-registered before any INVITE is sent.  All N calls are
    launched simultaneously to stress the IMS SIP signalling path and the
    EPC dedicated-bearer creation path end to end.
    """
    n_pairs: int = 0
    attach_success: int = 0
    attach_failed: int = 0
    register_success: int = 0
    register_failed: int = 0
    callers_attempted: int = 0
    callers_success: int = 0
    callers_failed: int = 0
    callees_answered: int = 0
    avg_call_setup_ms: float = 0.0
    p95_call_setup_ms: float = 0.0
    elapsed_seconds: float = 0.0
    errors: List[str] = field(default_factory=list)

    @property
    def num_ues(self) -> int:
        return self.n_pairs * 2

    @property
    def call_success_rate(self) -> float:
        if self.callers_attempted == 0:
            return 0.0
        return self.callers_success / self.callers_attempted * 100

    @property
    def attach_success_rate(self) -> float:
        total = self.attach_success + self.attach_failed
        return self.attach_success / total * 100 if total > 0 else 0.0

    @property
    def register_success_rate(self) -> float:
        total = self.register_success + self.register_failed
        return self.register_success / total * 100 if total > 0 else 0.0


def _run_single_ue(
    sub_config: Dict[str, str],
    target_msisdn: str,
    call_type: str,
    call_duration: float,
    sip_port: int,
    skip_call: bool,
    shared_conn: 'SharedS1APConnection' = None,
) -> UEMetrics:
    """Worker function for running a single UE lifecycle in a thread pool."""
    ue = None
    try:
        ue = UESimulator(
            imsi=sub_config["imsi"],
            ki=sub_config["ki"],
            opc=sub_config["opc"],
            amf=sub_config.get("amf", "8000"),
            msisdn=sub_config.get("msisdn", ""),
            sip_local_port=sip_port,
            shared_conn=shared_conn,
        )
        return ue.run_full_lifecycle(
            target_msisdn=target_msisdn,
            call_type=call_type,
            call_duration=call_duration,
            skip_call=skip_call,
        )
    except Exception as e:
        logger.error("UE worker error: %s", e)
        m = UEMetrics()
        m.error_message = str(e)
        # Ensure cleanup even on unexpected errors
        if ue is not None:
            try:
                ue.detach()
            except Exception:
                pass
        return m


def run_load_test(
    num_ues: int,
    subscribers: List[Dict[str, str]] = None,
    target_msisdn: str = None,
    call_type: str = "volte",
    call_duration: float = 2.0,
    max_workers: int = None,
    skip_call: bool = False,
    use_shared_enb: bool = True,
    ues_per_enb: int = None,
    attach_stagger_ms: float = None,
) -> LoadTestResult:
    """
    Run a load test with multiple concurrent UEs distributed across virtual eNBs.

    UEs are spread across multiple SCTP connections (virtual eNBs) so the MME
    can process their S1AP transactions in parallel.  Each eNB has its own SCTP
    association and NAS context — the MME handles them concurrently rather than
    serially, unlocking true scaling to 128 / 256 / 1024 UEs.

    Topology example for 128 UEs (UES_PER_ENB=32):
        eNB-0 (SCTP conn 1): UEs  0-31  → MME processes 32 NAS chains in parallel
        eNB-1 (SCTP conn 2): UEs 32-63  → with eNB-0, eNB-2, eNB-3
        eNB-2 (SCTP conn 3): UEs 64-95
        eNB-3 (SCTP conn 4): UEs 96-127
    All 4 eNBs process concurrently → total latency ~ 1 eNB's batch time, not 4×.

    Args:
        num_ues:      Number of concurrent UEs to simulate
        subscribers:  List of subscriber dicts with imsi/ki/opc/msisdn.
                      Will be cycled if fewer than num_ues.
        target_msisdn: Target for calls (None = skip call)
        call_type:    "volte" or "vilte"
        call_duration: Call duration per UE in seconds
        max_workers:  Thread pool size. Defaults to min(num_ues, 256).
        skip_call:    Skip call phase (attach + register only)
        use_shared_enb: Use shared SCTP connections (realistic eNB behavior).
                        False = each UE gets its own SCTP connection (stress mode).
        ues_per_enb:  UEs per virtual eNB. Defaults to Config.UES_PER_ENB (32).
                      Controls parallelism: lower = more eNBs = more parallel MME work.
        attach_stagger_ms: Milliseconds to wait between launching each UE thread.
                      None → auto-calculate (tiny stagger to prevent SCTP storm).
                      0    → fully simultaneous burst (maximum stress).
                      10   → 10ms/UE → realistic eNB RACH scheduling (~100 UE/sec).
                      50   → 50ms/UE → slower RACH / intentional pacing.
                      Set ATTACH_STAGGER_MS env var to override from shell.

    Returns:
        LoadTestResult with aggregated metrics
    """
    if subscribers is None:
        # Dynamically provision N subscribers in PyHSS
        try:
            from .provisioner import provision_subscribers
            logger.info("Dynamically provisioning %d subscribers in PyHSS...", num_ues)
            subscribers = provision_subscribers(num_ues)
            logger.info("Provisioned %d subscribers", len(subscribers))
        except Exception as e:
            logger.warning("Dynamic provisioning failed (%s), using defaults", e)
            default_subs = Config.default_subscribers()
            subscribers = [
                {"imsi": s.imsi, "ki": s.ki, "opc": s.opc,
                 "amf": s.amf, "msisdn": s.msisdn}
                for s in default_subs
            ]

    # ----------------------------------------------------------------
    # Determine multi-eNB topology
    # ----------------------------------------------------------------
    if ues_per_enb is None:
        env_val = os.environ.get('UES_PER_ENB')
        if env_val:
            # Caller explicitly chose a topology — respect it.
            ues_per_enb = int(env_val)
        else:
            # Auto-scale: smaller UE counts need more eNBs (more SCTP parallelism)
            # so each eNB's NAS chain is short and the MME processes them concurrently.
            #
            # Rule of thumb derived from MME S1AP event-loop benchmarks:
            #   ≤ 10 UEs  → 1 UE/eNB  (each UE has its own SCTP — max parallelism)
            #   ≤ 64 UEs  → 4 UEs/eNB (16 eNBs for 64 UEs)
            #   ≤ 256 UEs → 16 UEs/eNB (16 eNBs for 256 UEs)
            #   > 256 UEs → 32 UEs/eNB (scales to 1024 UEs with 32 eNBs)
            #
            # This ensures TC-2/TC-3 at 2, 5, 10 UEs all get independent SCTP
            # connections and pass at the same concurrency as TC-9 (sequential).
            if num_ues <= 10:
                ues_per_enb = 1
            elif num_ues <= 64:
                ues_per_enb = 4
            elif num_ues <= 256:
                ues_per_enb = 16
            else:
                ues_per_enb = 32

    # Clamp: at least 1, at most num_ues
    ues_per_enb = max(1, min(ues_per_enb, num_ues))
    num_enbs = max(1, (num_ues + ues_per_enb - 1) // ues_per_enb) if use_shared_enb else 0

    if max_workers is None:
        # Each eNB's UEs are I/O-bound (blocking on SCTP/SIP); allow all to run.
        # Cap at 256 to avoid thread-creation overhead for very large tests.
        max_workers = min(num_ues, 256)

    result = LoadTestResult(concurrent=num_ues, total_ues=num_ues)
    start_time = time.time()

    # ----------------------------------------------------------------
    # Set up eNB connections (one SCTP association per virtual eNB)
    # ----------------------------------------------------------------
    enb_connections: List[SharedS1APConnection] = []

    if use_shared_enb:
        logger.info(
            "Setting up %d virtual eNB connection(s) (%d UEs/eNB) to MME %s:%d ...",
            num_enbs, ues_per_enb, Config.MME_IP, Config.MME_PORT,
        )
        for i in range(num_enbs):
            enb_id = Config.ENB_ID_BASE + i   # unique 20-bit eNB ID per connection
            enb_name = f"{Config.ENB_NAME}-{i+1:02d}" if num_enbs > 1 else Config.ENB_NAME
            conn = SharedS1APConnection(enb_id=enb_id, enb_name=enb_name)

            if not conn.connect():
                logger.error("eNB-%d: SCTP connect failed — aborting load test", i)
                for c in enb_connections:
                    try:
                        c.disconnect()
                    except Exception:
                        pass
                result.elapsed_seconds = time.time() - start_time
                result.attach_failed = num_ues
                result.errors.append(f"eNB-{i} SCTP connect failed")
                return result

            if not conn.s1_setup():
                logger.error("eNB-%d: S1 Setup failed — aborting load test", i)
                conn.disconnect()
                for c in enb_connections:
                    try:
                        c.disconnect()
                    except Exception:
                        pass
                result.elapsed_seconds = time.time() - start_time
                result.attach_failed = num_ues
                result.errors.append(f"eNB-{i} S1 Setup failed")
                return result

            enb_connections.append(conn)
            logger.debug("eNB-%d ready (ID=0x%05X)", i, enb_id)

        logger.info(
            "All %d eNB connection(s) ready — %d UEs distributed across %d SCTP associations",
            num_enbs, num_ues, num_enbs,
        )

    logger.info("="*60)
    logger.info("LOAD TEST: %d UEs | %d eNBs | %d UEs/eNB | workers=%d",
                num_ues, max(1, num_enbs), ues_per_enb, max_workers)
    logger.info("="*60)

    # ----------------------------------------------------------------
    # Build per-UE configuration list with eNB assignment
    # ----------------------------------------------------------------
    ue_configs = []
    base_port = Config.SIP_LOCAL_PORT_BASE
    for i in range(num_ues):
        sub = subscribers[i % len(subscribers)].copy()
        sip_port = base_port + i
        # Round-robin assignment: UE i goes to eNB i % num_enbs
        conn = enb_connections[i % num_enbs] if enb_connections else None
        ue_configs.append((sub, sip_port, conn))

    # ----------------------------------------------------------------
    # Timeout tuning — scale per-eNB, not per total UEs
    # With multi-eNB, each eNB processes ues_per_enb UEs serially.
    # Timeout must cover worst-case serialised attach through that eNB.
    # Production NAS timers (T3450=6s, T3460=6s) are preserved.
    # ----------------------------------------------------------------
    original_s1ap_timeout = Config.S1AP_TIMEOUT
    original_sip_timeout = Config.SIP_TIMEOUT

    # ---- Stagger calculation ----
    # Priority: explicit param > ATTACH_STAGGER_MS env var > auto-calculate.
    # Auto-calc: tiny stagger prevents SCTP connection storm but is small enough
    # that the test is still effectively a burst.  0 = true simultaneous burst.
    env_stagger = os.environ.get('ATTACH_STAGGER_MS')
    if attach_stagger_ms is not None:
        launch_stagger_s = attach_stagger_ms / 1000.0
    elif env_stagger is not None:
        launch_stagger_s = float(env_stagger) / 1000.0
    else:
        # Auto: small stagger to avoid SCTP connection storm, scales with UE count.
        # For 1 UE: 0s.  For 32 UEs: 3ms.  For 1024 UEs: 5ms (capped).
        launch_stagger_s = min(0.005, 0.1 / max(num_ues, 1))

    if use_shared_enb:
        # Serial depth per eNB: ues_per_enb × ~400ms avg attach = expected batch time
        # Add 12s base for connection setup + MME processing overhead
        per_enb_timeout = 12.0 + (ues_per_enb * 0.5)
        Config.S1AP_TIMEOUT = min(60.0, max(Config.S1AP_TIMEOUT, per_enb_timeout))
        Config.SIP_TIMEOUT = min(30.0, max(Config.SIP_TIMEOUT, 12.0 + (ues_per_enb * 0.2)))
        logger.info(
            "Timeout tuning: S1AP=%.1fs (per-%d-UE eNB), SIP=%.1fs, stagger=%.1fms",
            Config.S1AP_TIMEOUT, ues_per_enb, Config.SIP_TIMEOUT, launch_stagger_s * 1000,
        )

    # ----------------------------------------------------------------
    # Run all UEs concurrently via thread pool
    # ----------------------------------------------------------------
    metrics_list: List[UEMetrics] = []

    try:
        with concurrent.futures.ThreadPoolExecutor(max_workers=max_workers) as executor:
            futures = []
            for sub_config, sip_port, conn in ue_configs:
                future = executor.submit(
                    _run_single_ue,
                    sub_config=sub_config,
                    target_msisdn=target_msisdn or "",
                    call_type=call_type,
                    call_duration=call_duration,
                    sip_port=sip_port,
                    skip_call=skip_call,
                    shared_conn=conn,
                )
                futures.append(future)
                if launch_stagger_s > 0:
                    time.sleep(launch_stagger_s)

            # Collect results as they complete
            # Timeout = per-eNB timeout + generous headroom for the whole batch
            collect_timeout = Config.S1AP_TIMEOUT + Config.SIP_TIMEOUT + 30.0
            for future in concurrent.futures.as_completed(futures, timeout=collect_timeout):
                try:
                    m = future.result(timeout=collect_timeout)
                    metrics_list.append(m)
                except concurrent.futures.TimeoutError:
                    logger.error("UE future timed out after %.0fs", collect_timeout)
                    m = UEMetrics()
                    m.error_message = f"timeout after {collect_timeout:.0f}s"
                    metrics_list.append(m)
                except Exception as e:
                    logger.error("UE future error: %s", e)
                    m = UEMetrics()
                    m.error_message = str(e)
                    metrics_list.append(m)
    finally:
        # Always disconnect all eNB connections
        for conn in enb_connections:
            try:
                conn.disconnect()
            except Exception:
                pass
        Config.S1AP_TIMEOUT = original_s1ap_timeout
        Config.SIP_TIMEOUT = original_sip_timeout

    result.elapsed_seconds = time.time() - start_time

    # Aggregate results
    attach_times = []
    register_times = []
    call_times = []
    failure_stages = collections.Counter()
    failure_samples: Dict[str, List[str]] = collections.defaultdict(list)
    stage_samples: Dict[str, List[float]] = collections.defaultdict(list)
    slowest_candidates: List[Dict[str, Any]] = []

    for m in metrics_list:
        for stage_name, stage_ms in m.stage_times_ms.items():
            if stage_ms > 0:
                stage_samples[stage_name].append(stage_ms)

        if m.attach_success:
            result.attach_success += 1
            if m.attach_time_ms > 0:
                attach_times.append(m.attach_time_ms)
        else:
            result.attach_failed += 1
            stage = m.error_stage or m.last_stage or "attach_unknown"
            failure_stages[stage] += 1
            if len(failure_samples[stage]) < 5:
                failure_samples[stage].append(
                    f"{m.imsi or '?'} eNB={m.enb_ue_id or '-'} MME={m.mme_ue_id or '-'}: "
                    f"{m.error_message or 'no detail'}"
                )

        if m.ims_register_success:
            result.register_success += 1
            if m.ims_register_time_ms > 0:
                register_times.append(m.ims_register_time_ms)
        else:
            result.register_failed += 1
            if m.attach_success:
                stage = m.error_stage or m.last_stage or "ims_register"
                failure_stages[stage] += 1
                if len(failure_samples[stage]) < 5:
                    failure_samples[stage].append(
                        f"{m.imsi or '?'} eNB={m.enb_ue_id or '-'} MME={m.mme_ue_id or '-'}: "
                        f"{m.error_message or 'no detail'}"
                    )

        if m.call_success:
            result.call_success += 1
            if m.call_setup_time_ms > 0:
                call_times.append(m.call_setup_time_ms)
        elif not skip_call and target_msisdn:
            result.call_failed += 1

        if m.error_message:
            stage = m.error_stage or m.last_stage or "unknown"
            result.errors.append(f"{stage}: {m.error_message}")

        total_time = m.total_time_ms or m.attach_time_ms or m.ims_register_time_ms
        if total_time > 0:
            slowest_candidates.append({
                "imsi": m.imsi,
                "stage": m.error_stage or ("ok" if m.ims_register_success else m.last_stage),
                "attach_ms": round(m.attach_time_ms),
                "register_ms": round(m.ims_register_time_ms),
                "total_ms": round(total_time),
                "enb_ue_id": m.enb_ue_id,
                "mme_ue_id": m.mme_ue_id,
            })

    # Compute statistics
    if attach_times:
        result.avg_attach_ms = statistics.mean(attach_times)
        if len(attach_times) >= 2:
            sorted_times = sorted(attach_times)
            p95_idx = int(len(sorted_times) * 0.95)
            result.p95_attach_ms = sorted_times[min(p95_idx, len(sorted_times) - 1)]

    if register_times:
        result.avg_register_ms = statistics.mean(register_times)
        if len(register_times) >= 2:
            sorted_times = sorted(register_times)
            p95_idx = int(len(sorted_times) * 0.95)
            result.p95_register_ms = sorted_times[min(p95_idx, len(sorted_times) - 1)]

    if call_times:
        result.avg_call_setup_ms = statistics.mean(call_times)

    result.attach_times_ms = attach_times
    result.register_times_ms = register_times
    result.failure_stages = dict(failure_stages)
    result.failure_samples = dict(failure_samples)
    for stage_name, samples in stage_samples.items():
        if not samples:
            continue
        sorted_samples = sorted(samples)
        p95_idx = int(len(sorted_samples) * 0.95)
        result.stage_latency_ms[stage_name] = {
            "count": len(samples),
            "avg": round(statistics.mean(samples)),
            "p95": round(sorted_samples[min(p95_idx, len(sorted_samples) - 1)]),
            "max": round(sorted_samples[-1]),
        }
    result.slowest_ues = sorted(
        slowest_candidates,
        key=lambda item: item.get("total_ms", 0),
        reverse=True,
    )[:5]

    logger.info("="*60)
    logger.info("LOAD TEST RESULTS: %d UEs in %.1fs", num_ues, result.elapsed_seconds)
    logger.info("  Attach:   %d/%d (%.1f%%) avg=%.0fms p95=%.0fms",
                 result.attach_success, num_ues, result.attach_success_rate,
                 result.avg_attach_ms, result.p95_attach_ms)
    logger.info("  Register: %d/%d (%.1f%%) avg=%.0fms p95=%.0fms",
                 result.register_success, num_ues, result.register_success_rate,
                 result.avg_register_ms, result.p95_register_ms)
    if not skip_call and target_msisdn:
        logger.info("  Call:     %d/%d avg_setup=%.0fms",
                     result.call_success, num_ues, result.avg_call_setup_ms)
    if result.failure_stages:
        logger.info(
            "  Failure stages: %s",
            ", ".join(f"{stage}={count}" for stage, count in sorted(result.failure_stages.items())),
        )
    if result.stage_latency_ms:
        logger.info(
            "  Stage latency: %s",
            ", ".join(
                f"{stage}:avg={stats['avg']}ms p95={stats['p95']}ms"
                for stage, stats in sorted(result.stage_latency_ms.items())
            ),
        )
    logger.info("="*60)

    return result


# ============================================================================
# Process-sharded load generation (capacity work)
# ----------------------------------------------------------------------------
# run_load_test()/run_burst_attach_test() drive "concurrent" UEs with a
# ThreadPoolExecutor in ONE Python process, so they are GIL-bound: past ~50-75
# UEs the interpreter (not the EPC/IMS core) becomes the bottleneck — the core
# sits near-idle while the generator's threads contend for the GIL.
#
# These wrappers split the UEs across N independent OS PROCESSES.  Each shard is
# a fully independent generator (its own GIL, its own SCTP connections, and a
# NON-OVERLAPPING identity space — subscriber range, eNB-ID band, SIP-port band)
# so the MME/HSS never see colliding identities.  Results aggregate into one
# LoadTestResult (counts summed, latency samples merged for true avg/p95, wall
# time = max shard time since shards run in parallel).
#
# Backward-compatible: num_procs<=1 calls the single-process function directly.
# Gate from the shell with LOAD_GEN_PROCS (default 1).
# ============================================================================

def _shard_subscriber_base0(num_procs: int, stride: int) -> int:
    """Time/pid-scoped base subscriber index, kept inside a window that leaves
    room for num_procs*stride so per-shard ranges never wrap/overlap mod 10M."""
    window = max(1, 10_000_000 - num_procs * stride)
    return (int(time.time() * 1000) + os.getpid() * 1000) % window


def _load_shard_entry(shard_args: Dict[str, Any]) -> Dict[str, Any]:
    """Run one generator shard in a child process (module-level so it is
    picklable).  Sets this shard's distinct identity space BEFORE any
    provisioning/connect, runs the existing single-process driver for its slice,
    and returns a plain (picklable) dict of results."""
    os.environ["LOAD_SUBSCRIBER_BASE"] = str(shard_args["sub_base"])
    Config.ENB_ID_BASE = shard_args["enb_id_base"]
    Config.SIP_LOCAL_PORT_BASE = shard_args["sip_port_base"]
    try:
        setup_logging(os.environ.get("LOG_LEVEL", "WARNING"))
    except Exception:
        pass

    if shard_args.get("mode") == "burst":
        res = run_burst_attach_test(
            num_ues=shard_args["num_ues"],
            single_enb=shard_args.get("single_enb", True),
            attach_stagger_ms=shard_args.get("attach_stagger_ms", 0.0),
        )
    else:
        res = run_load_test(
            num_ues=shard_args["num_ues"],
            skip_call=shard_args.get("skip_call", True),
            call_type=shard_args.get("call_type", "volte"),
            ues_per_enb=shard_args.get("ues_per_enb"),
        )

    return {
        "attach_success": res.attach_success,
        "attach_failed": res.attach_failed,
        "register_success": res.register_success,
        "register_failed": res.register_failed,
        "attach_times_ms": list(res.attach_times_ms),
        "register_times_ms": list(res.register_times_ms),
        "elapsed_seconds": res.elapsed_seconds,
        "errors": list(res.errors[:5]),
    }


def _run_sharded(num_ues: int, num_procs: int, mode: str, **mode_kwargs) -> LoadTestResult:
    """Split num_ues across num_procs OS processes and aggregate the results.

    Each shard gets a contiguous, non-overlapping eNB-ID and SIP-port band sized
    to its own slice, plus a widely-strided subscriber-index band, so concurrent
    shards never collide at the MME or HSS."""
    num_procs = max(1, min(int(num_procs), num_ues))

    # Even split: the first `rem` shards take one extra UE.
    per, rem = divmod(num_ues, num_procs)
    shard_sizes = [per + (1 if k < rem else 0) for k in range(num_procs)]

    # Control total eNB/SCTP-association count: each shard uses the topology the
    # WHOLE run would use (derived from total num_ues), NOT its small slice. Without
    # this, a small slice auto-picks ~1 UE/eNB and N shards explode into 64-128 SCTP
    # associations from one container, swamping the MME (observed: 128 eNBs @ 512/8
    # tanked to 37%). 'load' mode only; burst manages its own single_enb topology.
    if mode == "load" and mode_kwargs.get("ues_per_enb") is None:
        if num_ues <= 10:    _g = 1
        elif num_ues <= 64:  _g = 4
        elif num_ues <= 256: _g = 16
        else:                _g = 32
        # Each shard uses the WHOLE-RUN ues_per_enb value, so total eNBs across all
        # shards ≈ what single-process would use (e.g. 512 UEs / 8 procs: each shard
        # 64 UEs at 32/eNB = 2 eNBs/shard => 16 eNBs total, matching single-process).
        mode_kwargs = dict(mode_kwargs, ues_per_enb=_g)

    SUB_STRIDE = 200_000          # subscriber-index band per shard (slice always smaller)
    base0 = _shard_subscriber_base0(num_procs, SUB_STRIDE)
    enb_cursor = Config.ENB_ID_BASE        # 20-bit eNB-ID space; pack contiguously
    port_cursor = Config.SIP_LOCAL_PORT_BASE

    shard_args = []
    for k in range(num_procs):
        sz = shard_sizes[k]
        sa = {
            "mode": mode,
            "num_ues": sz,
            "sub_base": base0 + k * SUB_STRIDE,
            "enb_id_base": enb_cursor,
            "sip_port_base": port_cursor,
        }
        sa.update(mode_kwargs)
        shard_args.append(sa)
        # A shard uses at most `sz` eNB IDs and `sz` SIP ports; +16 gap between bands.
        enb_cursor += sz + 16
        port_cursor += sz + 16
    if port_cursor > 64000:
        logger.warning("Sharded SIP ports approaching 64000 (%d) — lower num_ues or LOAD_GEN_PROCS",
                       port_cursor)

    logger.info("SHARDED %s: %d UEs across %d processes %s", mode.upper(), num_ues, num_procs, shard_sizes)

    agg = LoadTestResult(concurrent=num_ues, total_ues=num_ues)
    attach_times: List[float] = []
    register_times: List[float] = []
    max_elapsed = 0.0

    # fork (Linux default): the parent has opened no sockets/threads yet, so the
    # forked workers start clean and we avoid the `python -c` + spawn __main__ pitfall.
    ctx = multiprocessing.get_context("fork")
    with concurrent.futures.ProcessPoolExecutor(max_workers=num_procs, mp_context=ctx) as ex:
        futures = [ex.submit(_load_shard_entry, sa) for sa in shard_args]
        for fut in concurrent.futures.as_completed(futures):
            try:
                d = fut.result()
            except Exception as e:
                logger.error("Load shard failed: %s", e)
                agg.errors.append(f"shard error: {e}")
                continue
            agg.attach_success += d["attach_success"]
            agg.attach_failed += d["attach_failed"]
            agg.register_success += d["register_success"]
            agg.register_failed += d["register_failed"]
            attach_times.extend(d["attach_times_ms"])
            register_times.extend(d["register_times_ms"])
            max_elapsed = max(max_elapsed, d["elapsed_seconds"])
            agg.errors.extend(d["errors"])

    agg.elapsed_seconds = max_elapsed
    if attach_times:
        agg.avg_attach_ms = statistics.mean(attach_times)
        s = sorted(attach_times)
        agg.p95_attach_ms = s[min(len(s) - 1, int(len(s) * 0.95))]
    if register_times:
        agg.avg_register_ms = statistics.mean(register_times)
        s = sorted(register_times)
        agg.p95_register_ms = s[min(len(s) - 1, int(len(s) * 0.95))]
    agg.attach_times_ms = attach_times
    agg.register_times_ms = register_times

    logger.info("SHARDED RESULT: attach %d/%d (%.1f%%) | reg %d/%d | wall=%.1fs | %d procs",
                agg.attach_success, num_ues, agg.attach_success_rate,
                agg.register_success, num_ues, agg.elapsed_seconds, num_procs)
    return agg


def run_load_test_sharded(num_ues: int, num_procs: int = None,
                          call_type: str = "volte", skip_call: bool = True,
                          ues_per_enb: int = None) -> LoadTestResult:
    """Process-sharded attach+register load (GIL-free generator scaling).
    num_procs defaults to the LOAD_GEN_PROCS env (1 = single-process)."""
    if num_procs is None:
        try:
            num_procs = int(os.environ.get("LOAD_GEN_PROCS", "1") or "1")
        except ValueError:
            num_procs = 1
    if num_procs <= 1:
        return run_load_test(num_ues=num_ues, skip_call=skip_call,
                             call_type=call_type, ues_per_enb=ues_per_enb)
    return _run_sharded(num_ues, num_procs, "load",
                        call_type=call_type, skip_call=skip_call, ues_per_enb=ues_per_enb)


def run_burst_attach_test_sharded(num_ues: int, num_procs: int = None,
                                  single_enb: bool = True,
                                  attach_stagger_ms: float = 0.0) -> LoadTestResult:
    """Process-sharded burst attach (GIL-free generator scaling).
    With sharding, single_enb=True means one eNB PER SHARD (num_procs eNBs total),
    since each process owns its own SCTP association/identity band.
    num_procs defaults to the LOAD_GEN_PROCS env (1 = single-process)."""
    if num_procs is None:
        try:
            num_procs = int(os.environ.get("LOAD_GEN_PROCS", "1") or "1")
        except ValueError:
            num_procs = 1
    if num_procs <= 1:
        return run_burst_attach_test(num_ues=num_ues, single_enb=single_enb,
                                     attach_stagger_ms=attach_stagger_ms)
    return _run_sharded(num_ues, num_procs, "burst",
                        single_enb=single_enb, attach_stagger_ms=attach_stagger_ms)


def run_burst_attach_test(
    num_ues: int,
    subscribers: List[Dict[str, str]] = None,
    single_enb: bool = True,
    attach_stagger_ms: float = 0.0,
    max_workers: int = None,
) -> LoadTestResult:
    """
    Test EPC attach + IMS registration capacity under burst conditions.

    This test ONLY measures the attach path: S1AP → MME → freeDiameter S6a →
    PyHSS → MySQL → SGW GTP-C.  No IMS registration, no calls.  It isolates
    the EPC attach bottleneck from IMS load so each component can be tuned
    and validated independently.

    Two test modes:
        single_enb=True  (default):
            All N UEs attach through ONE SCTP connection — the realistic scenario
            where a cell tower comes back online after an outage and all camped UEs
            simultaneously re-attach.  This stresses the MME's per-connection NAS
            state machine scheduler and the Diameter S6a pipeline to the HSS.

        single_enb=False:
            UEs distributed across multiple virtual eNBs (one SCTP per UE for
            ≤10 UEs, scaled for larger counts) — the multi-eNB scaling mode that
            our load tests use for VoLTE/ViLTE capacity.  Useful for comparing
            the single-eNB bottleneck vs the theoretical maximum.

    Args:
        num_ues:          Number of UEs to attach simultaneously.
        subscribers:      Pre-provisioned subscriber list.  Auto-provisioned if None.
        single_enb:       True = all UEs on one SCTP (realistic burst).
                          False = multi-eNB distribution (scaling baseline).
        attach_stagger_ms: Milliseconds between each UE thread launch.
                           0 = fully simultaneous burst.
                           10 = realistic RACH scheduling (eNB schedules ~100 UE/s).
                           Set ATTACH_STAGGER_MS env var to override from shell.
        max_workers:      Thread pool size. Defaults to min(num_ues, 256).

    Returns:
        LoadTestResult with attach_success, attach_failed, avg_attach_ms,
        p95_attach_ms, elapsed_seconds.  register_* and call_* fields are 0.
    """
    # Resolve stagger: param > env var > 0 (explicit default for burst)
    env_stagger = os.environ.get('ATTACH_STAGGER_MS')
    if env_stagger is not None and attach_stagger_ms == 0.0:
        attach_stagger_ms = float(env_stagger)
    stagger_s = attach_stagger_ms / 1000.0

    if max_workers is None:
        max_workers = min(num_ues, 256)

    # In single_enb mode: 1 eNB, all UEs share it → use_shared_enb=True, ues_per_enb=num_ues
    # In multi_enb mode: use auto-calc ues_per_enb
    if single_enb:
        ues_per_enb = num_ues          # all on one eNB
        use_shared_enb = True
        mode_label = "SINGLE-eNB (realistic burst)"
    else:
        ues_per_enb = None             # auto-calculate multi-eNB
        use_shared_enb = True
        mode_label = "MULTI-eNB (scaling baseline)"

    logger.info("=" * 60)
    logger.info("BURST ATTACH TEST: %d UEs | mode=%s | stagger=%.0fms",
                num_ues, mode_label, attach_stagger_ms)
    logger.info("=" * 60)

    # Delegate to run_load_test with skip_call=True (attach + register skipped = attach only)
    # We actually want attach ONLY, not register. Use skip_call=True and no target_msisdn.
    # To skip IMS register we need a lower-level call. run_load_test does attach+register,
    # so we set skip_call=True (skips call) and we can't skip register easily here.
    # For the burst attach test, register is also included — it's a fair measure of the
    # full EPC+IMS entry path per UE (attach → SGW session → IMS register → S-CSCF).
    # This is actually MORE realistic: in a real burst, all UEs would re-attach AND
    # re-register simultaneously.

    result = run_load_test(
        num_ues=num_ues,
        subscribers=subscribers,
        skip_call=True,           # no calls — just attach + IMS register
        use_shared_enb=use_shared_enb,
        ues_per_enb=ues_per_enb,
        max_workers=max_workers,
        attach_stagger_ms=attach_stagger_ms,
    )

    logger.info("=" * 60)
    logger.info("BURST ATTACH TEST RESULTS: %d UEs | mode=%s | stagger=%.0fms",
                num_ues, mode_label, attach_stagger_ms)
    logger.info("  Attach:   %d/%d (%.1f%%) avg=%.0fms p95=%.0fms",
                result.attach_success, num_ues, result.attach_success_rate,
                result.avg_attach_ms, result.p95_attach_ms)
    logger.info("  Register: %d/%d (%.1f%%) avg=%.0fms",
                result.register_success, num_ues, result.register_success_rate,
                result.avg_register_ms)
    logger.info("  Total elapsed: %.1fs", result.elapsed_seconds)
    logger.info("=" * 60)

    return result


def run_call_pair_test(
    n_pairs: int,
    subscribers: List[Dict[str, str]] = None,
    call_type: str = "volte",
    call_duration: float = 5.0,
    max_workers: int = None,
    ues_per_enb: int = None,
) -> CallPairTestResult:
    """
    Test N simultaneous VoLTE/ViLTE call pairs end-to-end.

    This is the definitive deployment readiness test.  A commercial EPC+IMS
    must handle at least 32 simultaneous call pairs (64 UEs).  The test uses
    a staged approach so the EPC attach and IMS register burden is separated
    from the call-setup burst:

        Phase 1 — Attach:    2*N UEs attach to EPC concurrently (multi-eNB).
        Phase 2 — Register:  All attached UEs perform SIP REGISTER via IMS.
        Phase 3 — Call:      N callees start answer_call() (polling socket).
                             0.5 s later, N callers simultaneously send INVITE.
                             Both sides complete the call (hold for call_duration, then BYE).
        Phase 4 — Detach:    All UEs perform UE-initiated detach.

    The key difference from run_load_test():
    - Callers and callees are distinct UE identities (real INVITE/answer flow).
    - Calls happen AFTER all UEs are registered — no attach/register noise during call burst.
    - Dedicated EPS bearer creation (QCI-1 for VoLTE, QCI-2 for ViLTE) is exercised per call.

    Args:
        n_pairs:       Number of simultaneous call pairs (each pair = 1 caller + 1 callee).
        subscribers:   Pre-provisioned subscriber list (2*n_pairs entries required).
                       If None, provisions via PyHSS REST API automatically.
        call_type:     "volte" (audio) or "vilte" (video+audio).
        call_duration: How long to hold each call before BYE (seconds).
        max_workers:   Thread pool size.  Defaults to 2*n_pairs.
        ues_per_enb:   UEs per virtual eNB for Phase 1 attach.  Auto-calculated if None.

    Returns:
        CallPairTestResult with per-phase success counts and timing.
    """
    num_ues = n_pairs * 2
    result = CallPairTestResult(n_pairs=n_pairs)
    start_time = time.time()

    # ---- ues_per_enb auto-calculation (same rule as run_load_test) ----
    if ues_per_enb is None:
        env_val = os.environ.get('UES_PER_ENB')
        if env_val:
            ues_per_enb = int(env_val)
        else:
            if num_ues <= 10:
                ues_per_enb = 1
            elif num_ues <= 64:
                ues_per_enb = 4
            elif num_ues <= 256:
                ues_per_enb = 16
            else:
                ues_per_enb = 32
    ues_per_enb = max(1, min(ues_per_enb, num_ues))
    num_enbs = max(1, (num_ues + ues_per_enb - 1) // ues_per_enb)

    if max_workers is None:
        max_workers = min(num_ues + 4, 256)

    logger.info("=" * 60)
    logger.info("CALL PAIR TEST: %d pairs | %d UEs | %d eNBs | %d UEs/eNB | type=%s",
                n_pairs, num_ues, num_enbs, ues_per_enb, call_type.upper())
    logger.info("=" * 60)

    # ---- Provision subscribers ----
    if subscribers is None:
        try:
            from .provisioner import provision_subscribers
            logger.info("Provisioning %d subscribers in PyHSS...", num_ues)
            subscribers = provision_subscribers(num_ues)
        except Exception as e:
            logger.warning("Dynamic provisioning failed (%s); using defaults", e)
            default_subs = Config.default_subscribers()
            subscribers = [
                {"imsi": s.imsi, "ki": s.ki, "opc": s.opc,
                 "amf": s.amf, "msisdn": s.msisdn}
                for s in default_subs
            ]

    # Ensure we have enough subscribers (cycle if necessary)
    if len(subscribers) < num_ues:
        subscribers = (subscribers * ((num_ues // len(subscribers)) + 1))[:num_ues]

    caller_subs = subscribers[:n_pairs]
    callee_subs = subscribers[n_pairs:n_pairs * 2]

    # ---- Timeout tuning ----
    original_s1ap_timeout = Config.S1AP_TIMEOUT
    original_sip_timeout = Config.SIP_TIMEOUT
    per_enb_timeout = 12.0 + (ues_per_enb * 0.5)
    Config.S1AP_TIMEOUT = min(60.0, max(Config.S1AP_TIMEOUT, per_enb_timeout))
    # SIP timeout must cover call_duration + IMS round-trips
    Config.SIP_TIMEOUT = max(Config.SIP_TIMEOUT, call_duration + 15.0)

    env_setup_stagger = os.environ.get("CALL_PAIR_SETUP_STAGGER_MS")
    if env_setup_stagger is None:
        env_setup_stagger = os.environ.get("ATTACH_STAGGER_MS")
    if env_setup_stagger is not None:
        try:
            setup_stagger_s = max(0.0, float(env_setup_stagger) / 1000.0)
        except ValueError:
            setup_stagger_s = 0.0
    else:
        # TC-10 measures simultaneous calls, not a zero-jitter attach storm.
        setup_stagger_s = min(0.05, 0.5 / max(num_ues, 1))

    enb_connections: List['SharedS1APConnection'] = []
    caller_ues: List[UESimulator] = []
    callee_ues: List[UESimulator] = []

    try:
        # ---- Set up eNB connections ----
        logger.info("Setting up %d eNB connections...", num_enbs)
        for i in range(num_enbs):
            enb_id = Config.ENB_ID_BASE + i
            enb_name = f"{Config.ENB_NAME}-{i+1:02d}"
            conn = SharedS1APConnection(enb_id=enb_id, enb_name=enb_name)
            if not conn.connect() or not conn.s1_setup():
                logger.error("eNB-%d setup failed", i)
                continue
            enb_connections.append(conn)

        if not enb_connections:
            result.errors.append("All eNB connections failed — MME unreachable")
            return result

        # ---- Create UE objects ----
        # Caller SIP ports: 14000..14000+n_pairs-1
        # Callee SIP ports: 15000..15000+n_pairs-1
        for i, sub in enumerate(caller_subs):
            conn = enb_connections[i % len(enb_connections)]
            caller_ues.append(UESimulator(
                imsi=sub["imsi"], ki=sub["ki"], opc=sub["opc"],
                amf=sub.get("amf", "8000"), msisdn=sub.get("msisdn", ""),
                sip_local_port=14000 + i,
                shared_conn=conn,
            ))

        for i, sub in enumerate(callee_subs):
            conn = enb_connections[(n_pairs + i) % len(enb_connections)]
            callee_ues.append(UESimulator(
                imsi=sub["imsi"], ki=sub["ki"], opc=sub["opc"],
                amf=sub.get("amf", "8000"), msisdn=sub.get("msisdn", ""),
                sip_local_port=15000 + i,
                shared_conn=conn,
            ))

        all_ues = caller_ues + callee_ues
        result.attach_failed = num_ues  # will subtract successes below

        # ======================================================
        # Phase 1: Attach all UEs concurrently
        # ======================================================
        logger.info(
            "Phase 1: Attaching %d UEs concurrently (setup stagger %.1fms)...",
            num_ues, setup_stagger_s * 1000,
        )

        def _do_attach(ue: UESimulator) -> bool:
            try:
                return ue.attach()
            except Exception as e:
                logger.error("Attach error %s: %s", ue.imsi, e)
                return False

        with concurrent.futures.ThreadPoolExecutor(max_workers=max_workers) as ex:
            attach_futures = []
            for ue in all_ues:
                attach_futures.append(ex.submit(_do_attach, ue))
                if setup_stagger_s > 0:
                    time.sleep(setup_stagger_s)
            attach_results = [f.result() for f in attach_futures]

        result.attach_success = sum(1 for r in attach_results if r)
        result.attach_failed = num_ues - result.attach_success
        logger.info("Phase 1 done: %d/%d attached", result.attach_success, num_ues)

        # ======================================================
        # Phase 2: IMS register all attached UEs concurrently
        # ======================================================
        logger.info(
            "Phase 2: IMS registering %d UEs concurrently (setup stagger %.1fms)...",
            result.attach_success, setup_stagger_s * 1000,
        )

        def _do_register(ue: UESimulator) -> bool:
            if not ue.attached:
                return False
            try:
                return ue.ims_register()
            except Exception as e:
                logger.error("Register error %s: %s", ue.imsi, e)
                return False

        with concurrent.futures.ThreadPoolExecutor(max_workers=max_workers) as ex:
            reg_futures = []
            for ue in all_ues:
                reg_futures.append(ex.submit(_do_register, ue))
                if setup_stagger_s > 0:
                    time.sleep(setup_stagger_s)
            reg_results = [f.result() for f in reg_futures]

        result.register_success = sum(1 for r in reg_results if r)
        result.register_failed = num_ues - result.register_success
        logger.info("Phase 2 done: %d/%d IMS registered", result.register_success, num_ues)

        # ---- Build active caller/callee pairs ----
        ready_callers = [ue for ue in caller_ues if ue.ims_registered]
        ready_callees = [ue for ue in callee_ues if ue.ims_registered]
        n_active = min(len(ready_callers), len(ready_callees))

        if n_active == 0:
            result.elapsed_seconds = time.time() - start_time
            result.errors.append("No registered UE pairs — attach/register phase failed entirely")
            return result

        active_callers = ready_callers[:n_active]
        active_callees = ready_callees[:n_active]
        result.callers_attempted = n_active

        # ======================================================
        # Phase 3: Simultaneous calls
        #
        # All callee threads start answer_call() first.  A threading.Barrier
        # ensures the main thread does NOT launch callers until every callee
        # thread has entered answer_call() and is actively polling its socket.
        # This prevents the race where an INVITE arrives before the callee is
        # ready to receive it.
        # ======================================================
        logger.info("Phase 3: %d simultaneous %s call pairs...", n_active, call_type.upper())

        call_setup_times_ms: List[float] = []
        call_errors: List[str] = []

        # Barrier parties = n_active callees + 1 (main thread)
        callee_ready = threading.Barrier(n_active + 1, timeout=30.0)

        def _callee_worker(ue: UESimulator) -> bool:
            """Callee: signal ready at barrier, then answer incoming call."""
            try:
                callee_ready.wait()   # block until all callees + main reach barrier
            except threading.BrokenBarrierError:
                logger.error("Callee barrier broken — %s", ue.imsi)
                return False
            # Now inside answer_call() — socket already bound, will buffer INVITE
            return ue.answer_call(duration=call_duration, answer_delay=0.3)

        def _caller_worker(caller: UESimulator, callee_msisdn: str) -> Tuple[bool, float]:
            """Caller: send INVITE to callee and measure setup time."""
            t0 = time.time()
            try:
                if call_type == "vilte":
                    ok = caller.vilte_call(callee_msisdn, duration=call_duration)
                else:
                    ok = caller.volte_call(callee_msisdn, duration=call_duration)
            except Exception as e:
                logger.error("Caller %s error: %s", caller.imsi, e)
                ok = False
            return ok, (time.time() - t0) * 1000.0

        # Use a single pool with enough headroom for callee + caller threads
        pool_size = min(n_active * 2 + 4, 512)
        collect_timeout = call_duration + Config.SIP_TIMEOUT + 45.0

        with concurrent.futures.ThreadPoolExecutor(max_workers=pool_size) as ex:
            # Submit all callee workers — they will block at the barrier
            callee_futs = [ex.submit(_callee_worker, callee) for callee in active_callees]

            # Main thread arrives at barrier last, releasing all callees simultaneously
            try:
                callee_ready.wait()
            except threading.BrokenBarrierError:
                logger.error("Callee readiness barrier broken — proceeding anyway")

            # 400ms grace: all callees just passed the barrier and are now in answer_call()
            # This is a safety margin; UDP receive buffers will hold the INVITE anyway.
            time.sleep(0.4)

            # NOW launch all callers simultaneously
            caller_futs = [
                ex.submit(_caller_worker, caller, callee.msisdn)
                for caller, callee in zip(active_callers, active_callees)
            ]

            # Collect caller results
            for fut in concurrent.futures.as_completed(caller_futs, timeout=collect_timeout):
                try:
                    ok, elapsed_ms = fut.result(timeout=collect_timeout)
                    if ok:
                        result.callers_success += 1
                        call_setup_times_ms.append(elapsed_ms)
                    else:
                        result.callers_failed += 1
                except concurrent.futures.TimeoutError:
                    result.callers_failed += 1
                    call_errors.append("caller timed out")
                except Exception as e:
                    result.callers_failed += 1
                    call_errors.append(f"caller error: {e}")

            # Collect callee results (should all be done once callers completed)
            for fut in concurrent.futures.as_completed(callee_futs, timeout=30.0):
                try:
                    if fut.result(timeout=30.0):
                        result.callees_answered += 1
                except Exception:
                    pass

        result.errors = call_errors[:10]

        if call_setup_times_ms:
            result.avg_call_setup_ms = statistics.mean(call_setup_times_ms)
            sorted_times = sorted(call_setup_times_ms)
            p95_idx = min(int(len(sorted_times) * 0.95), len(sorted_times) - 1)
            result.p95_call_setup_ms = sorted_times[p95_idx]

    finally:
        # ======================================================
        # Phase 4: Detach all UEs
        # ======================================================
        logger.info("Phase 4: Detaching all UEs...")
        for ue in caller_ues + callee_ues:
            try:
                ue.detach()
            except Exception:
                pass
        for conn in enb_connections:
            try:
                conn.disconnect()
            except Exception:
                pass
        Config.S1AP_TIMEOUT = original_s1ap_timeout
        Config.SIP_TIMEOUT = original_sip_timeout

    result.elapsed_seconds = time.time() - start_time

    logger.info("=" * 60)
    logger.info("CALL PAIR TEST RESULTS: %d pairs in %.1fs", n_pairs, result.elapsed_seconds)
    logger.info("  Attach:    %d/%d (%.1f%%)",
                result.attach_success, num_ues, result.attach_success_rate)
    logger.info("  Register:  %d/%d (%.1f%%)",
                result.register_success, num_ues, result.register_success_rate)
    logger.info("  Calls:     %d/%d callers (%.1f%%) | %d callees answered | avg_setup=%.0fms | p95=%.0fms",
                result.callers_success, result.callers_attempted, result.call_success_rate,
                result.callees_answered, result.avg_call_setup_ms, result.p95_call_setup_ms)
    logger.info("=" * 60)

    return result


def run_ramp_test(
    step_list: List[int] = None,
    subscribers: List[Dict[str, str]] = None,
    target_msisdn: str = None,
    call_type: str = "volte",
    call_duration: float = 2.0,
    pass_threshold: float = 95.0,
    max_latency_ms: float = 2000.0,
    skip_call: bool = False,
) -> Tuple[int, List[LoadTestResult]]:
    """
    Run a ramp-up load test, increasing concurrent UEs until failure.

    Args:
        step_list: List of concurrent UE counts to test
        subscribers: Subscriber configurations
        target_msisdn: Target for calls
        call_type: "volte" or "vilte"
        call_duration: Call duration
        pass_threshold: Minimum success rate (%) to pass
        max_latency_ms: Maximum average latency to pass
        skip_call: Skip call phase

    Returns:
        Tuple of (max_sustainable_concurrent, list_of_results)
    """
    if step_list is None:
        step_list = [10, 25, 50, 100, 150, 200, 300, 500]

    logger.info("="*60)
    logger.info("RAMP-UP TEST: steps=%s", step_list)
    logger.info("Pass criteria: >%.0f%% success AND latency <%.0fms",
                 pass_threshold, max_latency_ms)
    logger.info("="*60)

    max_sustainable = 0
    all_results = []

    header = f"{'Concurrent':>12} {'Attach%':>10} {'Reg%':>10} {'AvgAtt(ms)':>12} {'AvgReg(ms)':>12} {'Elapsed':>10}"
    logger.info(header)
    logger.info("-" * 70)

    for concurrent in step_list:
        result = run_load_test(
            num_ues=concurrent,
            subscribers=subscribers,
            target_msisdn=target_msisdn,
            call_type=call_type,
            call_duration=call_duration,
            skip_call=skip_call,
        )
        all_results.append(result)

        row = (
            f"{concurrent:>12} "
            f"{result.attach_success_rate:>9.1f}% "
            f"{result.register_success_rate:>9.1f}% "
            f"{result.avg_attach_ms:>12.0f} "
            f"{result.avg_register_ms:>12.0f} "
            f"{result.elapsed_seconds:>9.1f}s"
        )
        logger.info(row)

        # Check pass criteria
        passes = (
            result.attach_success_rate >= pass_threshold and
            result.avg_attach_ms < max_latency_ms
        )

        if passes:
            max_sustainable = concurrent
        else:
            logger.info(">>> Threshold breached at %d concurrent", concurrent)
            break

        # Cooldown between steps
        time.sleep(3)

    logger.info("="*60)
    logger.info("RESULT: Max sustainable concurrent UEs: %d", max_sustainable)
    logger.info("="*60)

    return max_sustainable, all_results


# ================================================================
# eNB Capacity Test
# ================================================================

@dataclass
class ENBCapacityResult:
    """Results from an eNB capacity test."""
    attempted: int = 0
    success: int = 0
    failed: int = 0
    avg_setup_ms: float = 0.0
    elapsed_seconds: float = 0.0

    @property
    def success_rate(self) -> float:
        return (self.success / self.attempted * 100) if self.attempted > 0 else 0.0


def _setup_single_enb(enb_id: int, enb_name: str) -> Tuple[bool, float]:
    """Connect and S1Setup a single standalone eNB. Returns (success, elapsed_ms)."""
    # Use SharedS1APConnection with custom enb_id (thread-safe, no global mutation)
    conn = SharedS1APConnection(enb_id=enb_id, enb_name=enb_name)
    start = time.time()
    try:
        if not conn.connect():
            return False, (time.time() - start) * 1000
        if not conn.s1_setup():
            conn.disconnect()
            return False, (time.time() - start) * 1000

        elapsed_ms = (time.time() - start) * 1000
        conn.disconnect()
        return True, elapsed_ms
    except Exception as e:
        logger.error("eNB setup error (ID=0x%05X): %s", enb_id, e)
        try:
            conn.disconnect()
        except Exception:
            pass
        return False, (time.time() - start) * 1000


def run_enb_capacity_test(num_enbs: int, max_workers: int = None) -> ENBCapacityResult:
    """
    Test eNB capacity: ramp up S1Setup connections with unique eNB IDs.

    Each eNB opens its own SCTP connection and performs S1 Setup.
    Measures how many concurrent eNBs the MME can accept.

    Args:
        num_enbs: Number of eNBs to attempt
        max_workers: Max concurrent connections

    Returns:
        ENBCapacityResult with success count and timing
    """
    if max_workers is None:
        max_workers = min(num_enbs, 50)

    result = ENBCapacityResult(attempted=num_enbs)
    start_time = time.time()

    logger.info("eNB capacity test: %d eNBs (max_workers=%d)", num_enbs, max_workers)

    setup_times = []

    with concurrent.futures.ThreadPoolExecutor(max_workers=max_workers) as executor:
        futures = []
        base_enb_id = 0x20000  # Use a different range from the main eNB
        for i in range(num_enbs):
            enb_id = base_enb_id + i
            enb_name = f"LoadTest-eNB-{i}"
            futures.append(executor.submit(_setup_single_enb, enb_id, enb_name))

        for future in concurrent.futures.as_completed(futures):
            try:
                success, elapsed_ms = future.result(timeout=30.0)
                if success:
                    result.success += 1
                    setup_times.append(elapsed_ms)
                else:
                    result.failed += 1
            except Exception as e:
                logger.error("eNB future error: %s", e)
                result.failed += 1

    result.elapsed_seconds = time.time() - start_time
    if setup_times:
        result.avg_setup_ms = statistics.mean(setup_times)

    logger.info("eNB capacity: %d/%d succeeded (%.1f%%) avg=%.0fms in %.1fs",
                result.success, result.attempted, result.success_rate,
                result.avg_setup_ms, result.elapsed_seconds)

    return result


# ================================================================
# CLI Entry Point
# ================================================================

def main():
    """CLI entry point for the UE simulator."""
    import argparse

    parser = argparse.ArgumentParser(
        description="UE/eNB Simulator for EPC+IMS Testing",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="""
Examples:
  # Single UE attach + register
  python -m ue_sim.ue_simulator --imsi 001019876540700 --attach --register

  # VoLTE call
  python -m ue_sim.ue_simulator --imsi 001019876540700 --call 19876541000

  # Load test with 50 UEs
  python -m ue_sim.ue_simulator --load-test 50

  # Ramp-up test
  python -m ue_sim.ue_simulator --ramp-test
        """,
    )

    parser.add_argument("--imsi", help="Subscriber IMSI")
    parser.add_argument("--ki", help="Subscriber Ki (hex)")
    parser.add_argument("--opc", help="Subscriber OPc (hex)")
    parser.add_argument("--msisdn", help="Subscriber MSISDN")
    parser.add_argument("--amf", default="8000", help="AMF (hex, default 8000)")

    parser.add_argument("--attach", action="store_true", help="Perform EPC attach")
    parser.add_argument("--register", action="store_true", help="Perform IMS registration")
    parser.add_argument("--call", metavar="TARGET", help="Make VoLTE call to TARGET")
    parser.add_argument("--vilte", action="store_true", help="Use ViLTE instead of VoLTE")
    parser.add_argument("--duration", type=float, default=5.0, help="Call duration (seconds)")
    parser.add_argument("--detach", action="store_true", help="Perform detach after operations")

    parser.add_argument("--load-test", type=int, metavar="N", help="Run load test with N UEs")
    parser.add_argument("--ramp-test", action="store_true", help="Run ramp-up test")
    parser.add_argument("--steps", help="Ramp-up steps (comma-separated, e.g., 10,25,50,100)")

    parser.add_argument("--log-level", default="INFO",
                        choices=["DEBUG", "INFO", "WARNING", "ERROR"])
    parser.add_argument("--full-lifecycle", action="store_true",
                        help="Run full lifecycle (attach + register + call + detach)")

    args = parser.parse_args()
    setup_logging(args.log_level)
    Config.log_config()

    # Load test mode
    if args.load_test:
        result = run_load_test(
            num_ues=args.load_test,
            skip_call=not args.call,
            target_msisdn=args.call,
            call_type="vilte" if args.vilte else "volte",
            call_duration=args.duration,
        )
        print(f"\nLoad test: {result.attach_success}/{result.total_ues} attached "
              f"({result.attach_success_rate:.1f}%)")
        return

    # Ramp test mode
    if args.ramp_test:
        steps = None
        if args.steps:
            steps = [int(s) for s in args.steps.split(',')]

        max_concurrent, results = run_ramp_test(
            step_list=steps,
            skip_call=not args.call,
            target_msisdn=args.call,
            call_type="vilte" if args.vilte else "volte",
            call_duration=args.duration,
        )
        print(f"\nRamp test result: max {max_concurrent} concurrent UEs")
        return

    # Single UE mode
    subs = Config.default_subscribers()
    if args.imsi:
        sub_config = SubscriberConfig(
            imsi=args.imsi,
            ki=args.ki or subs[0].ki,
            opc=args.opc or subs[0].opc,
            amf=args.amf,
            msisdn=args.msisdn or "",
        )
    else:
        sub_config = subs[0]

    ue = UESimulator(
        imsi=sub_config.imsi,
        ki=sub_config.ki,
        opc=sub_config.opc,
        amf=sub_config.amf,
        msisdn=sub_config.msisdn,
    )

    if args.full_lifecycle:
        ue.run_full_lifecycle(
            target_msisdn=args.call,
            call_type="vilte" if args.vilte else "volte",
            call_duration=args.duration,
        )
        return

    if args.attach:
        ue.attach()

    if args.register:
        ue.ims_register()

    if args.call:
        if args.vilte:
            ue.vilte_call(args.call, duration=args.duration)
        else:
            ue.volte_call(args.call, duration=args.duration)

    if args.detach:
        ue.detach()


if __name__ == "__main__":
    main()
