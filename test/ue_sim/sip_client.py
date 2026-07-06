"""
SIP Client for IMS Registration and VoLTE/ViLTE Calls

Implements a SIP User Agent capable of:
    - SIP REGISTER with IMS AKAv1-MD5 authentication
    - SIP INVITE for VoLTE (audio-only, QCI 1) calls
    - SIP INVITE for ViLTE (video+audio, QCI 1+2) calls
    - Full call lifecycle: INVITE → 100/183/PRACK/200/ACK → BYE

The SIP client uses raw UDP sockets and constructs SIP messages directly
(no external SIP library needed).

Reference: RFC 3261 (SIP), RFC 3310 (IMS AKA), TS 24.229 (IMS procedures)
"""

import base64
import hashlib
import logging
import random
import re
import select
import socket
import string
import struct
import time
import uuid
from typing import Optional, Tuple, Dict, List, Any
from urllib.parse import quote, unquote

from .config import Config
from .milenage import Milenage

logger = logging.getLogger(__name__)


class SIPClient:
    """
    SIP User Agent for IMS registration and VoLTE/ViLTE calls.

    Handles the complete SIP signaling for IMS attachment including
    AKA-based authentication through the P-CSCF → I-CSCF → S-CSCF chain.

    Args:
        pcscf_ip: P-CSCF IP address
        pcscf_port: P-CSCF SIP port
        local_ip: Local bind address
        local_port: Local SIP port
        ims_domain: IMS domain name
        milenage: Milenage instance for AKA authentication
        imsi: IMSI string
        msisdn: MSISDN string
    """

    def __init__(
        self,
        pcscf_ip: str = None,
        pcscf_port: int = None,
        local_ip: str = None,
        local_port: int = None,
        ims_domain: str = None,
        milenage: Milenage = None,
        imsi: str = "",
        msisdn: str = "",
        imei_sv: str = "",
    ):
        self._pcscf_ip = pcscf_ip or Config.PCSCF_IP
        self._pcscf_port = pcscf_port or Config.PCSCF_PORT
        self._local_ip = local_ip or Config.LOCAL_IP
        self._local_port = local_port or Config.SIP_LOCAL_PORT_BASE
        self._ims_domain = ims_domain or Config.IMS_DOMAIN
        self._imei_sv = imei_sv  # IMEI-SV for +sip.instance in Contact
        self._milenage = milenage
        self._imsi = imsi
        self._msisdn = msisdn

        # Transport sockets
        self._sock: Optional[socket.socket] = None
        self._tcp_server: Optional[socket.socket] = None
        self._tcp_conn: Optional[socket.socket] = None
        self._tcp_peer: Optional[Tuple[str, int]] = None
        self._tcp_buffer: bytes = b""
        self._last_rx_transport: str = "udp"

        # SIP state
        self._call_id: str = ""
        self._local_tag: str = ""
        self._remote_tag: str = ""
        self._cseq: int = 0
        self._branch_counter: int = 0
        self._registered: bool = False

        # Authentication state
        self._auth_realm: str = ""
        self._auth_nonce: str = ""
        self._auth_opaque: str = ""
        self._ck: Optional[bytes] = None
        self._ik: Optional[bytes] = None

        # Call state
        self._in_call: bool = False
        self._call_dialog_id: str = ""
        self._call_local_tag: str = ""
        self._route_set: List[str] = []
        self._service_route_set: List[str] = []
        self._contact: str = ""
        self._remote_target: str = ""
        self._call_remote_tag: str = ""
        self._call_target_uri: str = ""
        self._call_is_video: bool = False
        self._dialogs: Dict[str, Dict[str, Any]] = {}
        self._last_error: str = ""

        # RTP port (simulated)
        self._rtp_port = random.randint(10000, 30000) & 0xFFFE  # even port

    # ================================================================
    # Connection Management
    # ================================================================
    def connect(self) -> bool:
        """
        Create UDP socket plus a passive TCP listener on the same port.

        Returns:
            True if sockets created and bound successfully
        """
        try:
            self._clear_last_error()
            self._sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
            self._sock.settimeout(Config.SIP_TIMEOUT)

            # Bind to local address
            bind_ip = "0.0.0.0"
            self._sock.bind((bind_ip, self._local_port))

            # Determine actual local IP if 0.0.0.0
            if self._local_ip == "0.0.0.0":
                # Try to determine our IP by connecting to P-CSCF
                test_sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
                try:
                    test_sock.connect((self._pcscf_ip, self._pcscf_port))
                    self._local_ip = test_sock.getsockname()[0]
                except Exception:
                    self._local_ip = "127.0.0.1"
                finally:
                    test_sock.close()

            self._local_port = self._sock.getsockname()[1]

            # Some P-CSCF terminating paths still select TCP when targeting the
            # test harness. Listen on the same SIP port so inbound requests can
            # still be answered even when Kamailio chooses TCP for delivery.
            self._tcp_server = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
            self._tcp_server.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
            self._tcp_server.bind((bind_ip, self._local_port))
            self._tcp_server.listen(4)
            self._tcp_server.setblocking(False)

            logger.info(
                "SIP sockets bound to %s:%d (UDP client + TCP listener)",
                self._local_ip,
                self._local_port,
            )
            return True

        except Exception as e:
            self._set_last_error(f"Failed to create SIP socket: {e}")
            logger.error("Failed to create SIP socket: %s", e)
            if self._sock:
                try:
                    self._sock.close()
                except Exception:
                    pass
                self._sock = None
            if self._tcp_server:
                try:
                    self._tcp_server.close()
                except Exception:
                    pass
                self._tcp_server = None
            return False

    def disconnect(self):
        """Close SIP sockets."""
        if self._sock:
            try:
                self._sock.close()
            except Exception:
                pass
            self._sock = None
        if self._tcp_conn:
            try:
                self._tcp_conn.close()
            except Exception:
                pass
            self._tcp_conn = None
        if self._tcp_server:
            try:
                self._tcp_server.close()
            except Exception:
                pass
            self._tcp_server = None
        self._tcp_peer = None
        self._tcp_buffer = b""
        self._last_rx_transport = "udp"
        self._registered = False
        self._clear_active_dialog()
        self._service_route_set = []
        self._route_set = []
        logger.info("SIP sockets closed")

    # ================================================================
    # SIP REGISTER with IMS AKA
    # ================================================================
    def register(self) -> bool:
        """
        Perform IMS registration with AKA authentication.

        Flow:
            1. Send REGISTER (no auth) → receive 401 Unauthorized
            2. Parse WWW-Authenticate (extract nonce with RAND||AUTN)
            3. Compute RES, CK, IK using Milenage
            4. Send REGISTER with Authorization header
            5. Receive 200 OK

        Returns:
            True if registration succeeded
        """
        self._clear_last_error()
        if not self._sock:
            if not self.connect():
                return False

        transient_retry_statuses = {500, 503, 504}

        for attempt in range(2):
            if attempt > 0:
                logger.info("Retrying IMS REGISTER after transient failure")
                time.sleep(0.5)

            self._call_id = self._generate_call_id()
            self._local_tag = self._generate_tag()
            self._cseq = 1

            # Step 1: Initial REGISTER (no auth)
            logger.info("Sending initial REGISTER (no auth) to P-CSCF %s:%d",
                         self._pcscf_ip, self._pcscf_port)

            register_msg = self._build_register()
            self._send_sip(register_msg)

            # Step 2: Receive 401 Unauthorized (skip provisional 1xx responses)
            status_code = 0
            response = None
            for _ in range(10):  # max 10 provisional responses
                response = self._receive_sip(timeout=Config.SIP_TIMEOUT)
                if response is None:
                    if attempt == 0:
                        logger.warning("No response to REGISTER, retrying once")
                        break
                    self._set_last_error("No response to REGISTER")
                    logger.error("No response to REGISTER")
                    return False

                status_code = self._parse_status_code(response)
                logger.info("Received %d response to REGISTER", status_code)

                if status_code >= 200:
                    break  # Got a final response
                # 1xx is provisional — keep waiting for final response

            if response is None:
                continue

            if status_code == 401:
                # Parse WWW-Authenticate header
                if not self._parse_www_authenticate(response):
                    self._set_last_error("Failed to parse WWW-Authenticate header")
                    logger.error("Failed to parse WWW-Authenticate header")
                    return False

                # Step 3: Compute AKA response
                if not self._compute_aka_response():
                    self._set_last_error("AKA computation failed")
                    logger.error("AKA computation failed")
                    return False

                # Step 4: Send REGISTER with Authorization
                self._cseq += 1
                register_auth_msg = self._build_register(with_auth=True)
                self._send_sip(register_auth_msg)

                # Step 5: Receive 200 OK (skip provisional 1xx responses)
                response = None
                status_code = 0
                for _ in range(10):
                    response = self._receive_sip(timeout=Config.SIP_TIMEOUT)
                    if response is None:
                        if attempt == 0:
                            logger.warning("No response to authenticated REGISTER, retrying once")
                            break
                        self._set_last_error("No response to authenticated REGISTER")
                        logger.error("No response to authenticated REGISTER")
                        return False

                    status_code = self._parse_status_code(response)
                    logger.info("Received %d response to authenticated REGISTER", status_code)
                    if status_code >= 200:
                        break

                if response is None:
                    continue

                if status_code == 200:
                    self._registered = True
                    # Parse Service-Route for future requests
                    self._parse_service_route(response)
                    self._clear_last_error()
                    logger.info("IMS registration successful for %s", self._sip_uri)
                    return True
                elif status_code == 401:
                    # S-CSCF re-challenge: the first response matched (verified in S-CSCF logs)
                    # but it needs a second round-trip. Parse new challenge and retry.
                    logger.info("Received second 401 — re-challenging (S-CSCF double round-trip)")
                    if not self._parse_www_authenticate(response):
                        self._set_last_error("Failed to parse second WWW-Authenticate")
                        logger.error("Failed to parse second WWW-Authenticate")
                        return False
                    if not self._compute_aka_response():
                        self._set_last_error("Second AKA computation failed")
                        logger.error("Second AKA computation failed")
                        return False
                    self._cseq += 1
                    register_auth_msg2 = self._build_register(with_auth=True)
                    self._send_sip(register_auth_msg2)
                    # Wait for final response
                    response = None
                    status_code = 0
                    for _ in range(10):
                        response = self._receive_sip(timeout=Config.SIP_TIMEOUT)
                        if response is None:
                            if attempt == 0:
                                logger.warning("No response to third REGISTER, retrying once")
                                break
                            self._set_last_error("No response to third REGISTER")
                            logger.error("No response to third REGISTER")
                            return False
                        status_code = self._parse_status_code(response)
                        logger.info("Received %d response to third REGISTER", status_code)
                        if status_code >= 200:
                            break

                    if response is None:
                        continue

                    if status_code == 200:
                        self._registered = True
                        self._parse_service_route(response)
                        self._clear_last_error()
                        logger.info("IMS registration successful (after re-challenge)")
                        return True
                    elif status_code in transient_retry_statuses and attempt == 0:
                        logger.warning("Transient REGISTER failure after re-challenge: %d", status_code)
                        continue
                    else:
                        self._set_last_error(f"Registration failed on third attempt: {status_code}")
                        logger.error("Registration failed on third attempt: %d", status_code)
                        return False
                elif status_code in transient_retry_statuses and attempt == 0:
                    logger.warning("Transient authenticated REGISTER failure: %d", status_code)
                    continue
                else:
                    self._set_last_error(f"Registration failed with status {status_code}")
                    logger.error("Registration failed with status %d", status_code)
                    return False

            elif status_code == 200:
                # Already registered (no auth challenge)
                self._registered = True
                self._parse_service_route(response)
                self._clear_last_error()
                logger.info("IMS registration successful (no challenge)")
                return True
            elif status_code in transient_retry_statuses and attempt == 0:
                logger.warning("Transient REGISTER failure: %d", status_code)
                continue
            else:
                self._set_last_error(f"Unexpected REGISTER status {status_code}")
                logger.error("Unexpected status %d for REGISTER", status_code)
                return False

        self._set_last_error("IMS registration failed after transient retry")
        logger.error("IMS registration failed after transient retry")
        return False

    def unregister(self) -> bool:
        """
        De-register from IMS.

        Sends REGISTER with Expires: 0.

        Returns:
            True if de-registration succeeded
        """
        if not self._registered:
            return True

        self._cseq += 1
        dereg_msg = self._build_register(expires=0, with_auth=True)
        self._send_sip(dereg_msg)

        response = self._receive_sip(timeout=5.0)
        if response:
            status_code = self._parse_status_code(response)
            if status_code == 200:
                self._registered = False
                logger.info("IMS de-registration successful")
                return True

        self._registered = False
        return False

    # ================================================================
    # SIP INVITE (VoLTE / ViLTE)
    # ================================================================
    def invite(
        self,
        target_msisdn: str,
        sdp_video: bool = False,
        call_duration: float = 5.0,
    ) -> bool:
        """
        Initiate a VoLTE or ViLTE call.

        Full call flow:
            INVITE → 100 Trying → 183 Session Progress → PRACK → 200 (PRACK)
            → 200 (INVITE) → ACK → [media] → BYE → 200 (BYE)

        Args:
            target_msisdn: Target MSISDN to call
            sdp_video: True for ViLTE (video+audio), False for VoLTE (audio-only)
            call_duration: How long to keep the call active (seconds)

        Returns:
            True if call completed successfully
        """
        self._clear_last_error()
        if not self._registered:
            self._set_last_error("Not registered, cannot make call")
            logger.error("Not registered, cannot make call")
            return False

        target_uri = self._build_target_uri(target_msisdn)
        logger.info("Sending INVITE to %s (%s)",
                     target_msisdn, "ViLTE" if sdp_video else "VoLTE")

        if not self._establish_outgoing_call(target_uri=target_uri, sdp_video=sdp_video):
            return False

        # Call is established - hold for duration
        self._in_call = True
        logger.info("Call active for %.1f seconds", call_duration)
        time.sleep(call_duration)

        bye_ok = self.bye()
        if bye_ok:
            self._clear_last_error()
        return bye_ok

    def invite_with_hold_resume(
        self,
        target_msisdn: str,
        sdp_video: bool = False,
        active_before_hold: float = 2.0,
        hold_duration: float = 2.0,
        active_after_resume: float = 2.0,
    ) -> bool:
        """
        Initiate a call, place it on hold via re-INVITE, then resume it.

        This exercises in-dialog re-INVITE handling, which is the same
        dialog machinery used by several supplementary services.
        """
        self._clear_last_error()
        if not self._registered:
            self._set_last_error("Not registered, cannot make hold/resume call")
            logger.error("Not registered, cannot make hold/resume call")
            return False

        target_uri = self._build_target_uri(target_msisdn)
        logger.info("Sending hold/resume INVITE to %s (%s)",
                    target_msisdn, "ViLTE" if sdp_video else "VoLTE")

        if not self._establish_outgoing_call(target_uri=target_uri, sdp_video=sdp_video):
            return False

        logger.info("Call active for %.1fs before hold", active_before_hold)
        time.sleep(active_before_hold)

        if not self._send_reinvite(hold=True):
            if not self._last_error:
                self._set_last_error("Hold re-INVITE failed")
            logger.error("Hold re-INVITE failed")
            self.bye()
            return False

        logger.info("Call on hold for %.1fs", hold_duration)
        time.sleep(hold_duration)

        if not self._send_reinvite(hold=False):
            if not self._last_error:
                self._set_last_error("Resume re-INVITE failed")
            logger.error("Resume re-INVITE failed")
            self.bye()
            return False

        logger.info("Call resumed for %.1fs", active_after_resume)
        time.sleep(active_after_resume)

        bye_ok = self.bye()
        if bye_ok:
            self._clear_last_error()
        return bye_ok

    def answer_call(
        self,
        call_duration: float = 5.0,
        answer_delay: float = 0.5,
        timeout: float = None,
    ) -> bool:
        """
        Wait for an incoming INVITE, answer it, and stay in the dialog until BYE.

        Supports subsequent in-dialog re-INVITEs so caller-side hold/resume
        tests can be validated end to end.
        """
        self._clear_last_error()
        if not self._registered:
            self._set_last_error("Not registered, cannot answer incoming call")
            logger.error("Not registered, cannot answer incoming call")
            return False

        deadline = time.time() + (timeout if timeout is not None else Config.SIP_TIMEOUT * 3)
        incoming_invite = None
        while time.time() < deadline:
            message = self._receive_sip(timeout=1.0)
            if not message:
                continue
            if self._parse_request_method(message) == "INVITE":
                incoming_invite = message
                break

        if not incoming_invite:
            self._set_last_error("No incoming INVITE received before timeout")
            logger.error("No incoming INVITE received before timeout")
            return False

        from_header = self._extract_header(incoming_invite, "From") or ""
        to_header = self._extract_header(incoming_invite, "To") or ""
        call_id = self._extract_header(incoming_invite, "Call-ID") or self._generate_call_id()
        remote_target = self._extract_uri(self._extract_header(incoming_invite, "Contact") or "")
        target_uri = self._extract_uri(to_header) or self._sip_uri
        remote_tag = self._extract_tag(from_header)
        local_tag = self._extract_tag(to_header) or self._generate_tag()
        has_video = "m=video" in self._extract_body(incoming_invite)

        self._call_is_video = has_video
        self._store_active_dialog(
            call_id=call_id,
            local_tag=local_tag,
            remote_tag=remote_tag,
            target_uri=target_uri,
            remote_target=remote_target,
            route_set=self._extract_record_routes(incoming_invite),
            video=has_video,
        )

        self._send_sip(self._build_response(incoming_invite, 100, "Trying", local_tag=local_tag))
        time.sleep(answer_delay)
        self._send_sip(
            self._build_response(
                incoming_invite,
                180,
                "Ringing",
                local_tag=local_tag,
                contact_header=self._contact_header_invite,
            )
        )
        self._send_sip(
            self._build_response(
                incoming_invite,
                200,
                "OK",
                local_tag=local_tag,
                contact_header=self._contact_header_invite,
                body=self._build_sdp(video=has_video),
                content_type="application/sdp",
            )
        )
        logger.info("Answered incoming %s call", "ViLTE" if has_video else "VoLTE")

        # Wait for ACK to the initial INVITE.
        ack_deadline = time.time() + Config.SIP_TIMEOUT
        while time.time() < ack_deadline:
            message = self._receive_sip(timeout=1.0)
            if not message:
                continue
            method = self._parse_request_method(message)
            if method == "ACK":
                logger.info("Received ACK for incoming call")
                self._in_call = True
                self._clear_last_error()
                break
            if method == "BYE":
                self._send_sip(self._build_response(message, 200, "OK", local_tag=local_tag))
                self._clear_active_dialog()
                self._clear_last_error()
                return True
        else:
            self._set_last_error("Incoming call was not ACKed")
            logger.error("Incoming call was not ACKed")
            self._clear_active_dialog()
            return False

        active_deadline = time.time() + max(call_duration + Config.SIP_TIMEOUT, Config.SIP_TIMEOUT * 2)
        while time.time() < active_deadline:
            message = self._receive_sip(timeout=1.0)
            if not message:
                continue

            method = self._parse_request_method(message)
            if method == "BYE":
                self._send_sip(self._build_response(message, 200, "OK", local_tag=local_tag))
                logger.info("Received BYE for incoming call")
                self._clear_active_dialog()
                self._clear_last_error()
                return True

            if method == "INVITE":
                body = self._extract_body(message)
                self._call_is_video = "m=video" in body
                self._send_sip(
                    self._build_response(
                        message,
                        200,
                        "OK",
                        local_tag=local_tag,
                        contact_uri=self._contact_uri,
                        body=self._build_sdp(video=self._call_is_video, direction=self._sdp_direction_for_offer(body)),
                        content_type="application/sdp",
                    )
                )
                logger.info("Answered in-dialog re-INVITE")

                reinvite_ack_deadline = time.time() + Config.SIP_TIMEOUT
                while time.time() < reinvite_ack_deadline:
                    ack = self._receive_sip(timeout=1.0)
                    if not ack:
                        continue
                    if self._parse_request_method(ack) == "ACK":
                        logger.info("Received ACK for re-INVITE")
                        break
                    if self._parse_request_method(ack) == "BYE":
                        self._send_sip(self._build_response(ack, 200, "OK", local_tag=local_tag))
                        self._clear_active_dialog()
                        self._clear_last_error()
                        return True
                continue

        self._set_last_error("Incoming call timed out without BYE")
        logger.warning("Incoming call timed out without BYE")
        self._clear_active_dialog()
        return False

    def establish_call_dialog(self, target_msisdn: str, sdp_video: bool = False) -> Optional[Dict[str, Any]]:
        """Establish an outgoing call and return its dialog without sending BYE."""
        self._clear_last_error()
        if not self._registered:
            self._set_last_error("Not registered, cannot establish call dialog")
            logger.error("Not registered, cannot establish call dialog")
            return None

        target_uri = self._build_target_uri(target_msisdn)
        dialog = self._establish_dialog(target_uri=target_uri, sdp_video=sdp_video)
        if dialog:
            self._remember_dialog(dialog)
            self._in_call = True
        return dialog

    def answer_next_call_dialog(
        self,
        answer_delay: float = 0.5,
        timeout: float = None,
    ) -> Optional[Dict[str, Any]]:
        """Answer the next incoming call and return its dialog without waiting for BYE."""
        self._clear_last_error()
        if not self._registered:
            self._set_last_error("Not registered, cannot answer call dialog")
            logger.error("Not registered, cannot answer call dialog")
            return None

        invite = self._wait_for_incoming_invite(timeout or Config.SIP_TIMEOUT * 3)
        if not invite:
            self._set_last_error("No incoming INVITE received before timeout")
            logger.error("No incoming INVITE received before timeout")
            return None

        dialog = self._answer_incoming_dialog(invite, answer_delay=answer_delay)
        if not dialog:
            self._set_last_error("Incoming INVITE could not be answered")
            return None

        ack_deadline = time.time() + Config.SIP_TIMEOUT
        while time.time() < ack_deadline:
            message = self._receive_sip(timeout=1.0)
            if not message:
                continue
            if (self._extract_header(message, "Call-ID") or "") != dialog["call_id"]:
                continue
            method = self._parse_request_method(message)
            if method == "ACK":
                logger.info("Received ACK for answered call dialog")
                self._clear_last_error()
                self._remember_dialog(dialog)
                self._in_call = True
                return dialog
            if method == "BYE":
                self._send_sip(self._build_response(message, 200, "OK", local_tag=dialog["local_tag"]))
                self._clear_last_error()
                return dialog

        self._set_last_error("Answered call dialog was not ACKed")
        logger.error("Answered call dialog was not ACKed")
        return None

    def hold_dialog(self, dialog: Dict[str, Any]) -> bool:
        """Place a specific established dialog on hold."""
        return self._send_reinvite_for_dialog(dialog, hold=True)

    def resume_dialog(self, dialog: Dict[str, Any]) -> bool:
        """Resume a specific established dialog."""
        return self._send_reinvite_for_dialog(dialog, hold=False)

    def switch_dialog_media(
        self,
        dialog: Dict[str, Any],
        video: bool,
        connection_ip: Optional[str] = None,
    ) -> bool:
        """Switch a specific established dialog between audio-only and audio+video."""
        return self._send_reinvite_for_dialog(
            dialog,
            hold=False,
            video=video,
            connection_ip=connection_ip,
        )

    def end_dialog(self, dialog: Dict[str, Any], tolerate_timeout: bool = False) -> bool:
        """Send BYE for a specific established dialog."""
        ok = self._send_bye_for_dialog(dialog, tolerate_timeout=tolerate_timeout)
        if ok:
            self._forget_dialog(dialog)
        return ok

    def wait_for_dialog_end(self, dialog: Dict[str, Any], timeout: float = None) -> bool:
        """Wait for BYE on a dialog, answering in-dialog re-INVITEs while waiting."""
        if not dialog:
            return False

        def answer_reinvite(message: str) -> None:
            body = self._extract_body(message)
            offer_has_video = "m=video" in body
            dialog["video"] = offer_has_video
            self._send_sip(
                self._build_response(
                    message,
                    200,
                    "OK",
                    local_tag=dialog["local_tag"],
                    contact_uri=self._contact_uri,
                    body=self._build_sdp(
                        video=offer_has_video,
                        direction=self._sdp_direction_for_offer(body),
                    ),
                    content_type="application/sdp",
                )
            )
            logger.info("Answered in-dialog re-INVITE while waiting for dialog end")

        deadline = time.time() + (timeout if timeout is not None else Config.SIP_TIMEOUT * 3)
        while time.time() < deadline:
            message = self._receive_sip(timeout=1.0)
            if not message:
                continue
            if (self._extract_header(message, "Call-ID") or "") != dialog["call_id"]:
                continue

            method = self._parse_request_method(message)
            if method == "BYE":
                self._send_sip(self._build_response(message, 200, "OK", local_tag=dialog["local_tag"]))
                self._clear_last_error()
                self._forget_dialog(dialog)
                return True

            if method == "INVITE":
                answer_reinvite(message)

                ack_deadline = time.time() + Config.SIP_TIMEOUT
                while time.time() < ack_deadline:
                    ack = self._receive_sip(timeout=1.0)
                    if not ack:
                        continue
                    if (self._extract_header(ack, "Call-ID") or "") != dialog["call_id"]:
                        continue
                    if self._parse_request_method(ack) == "ACK":
                        logger.info("Received ACK for in-dialog re-INVITE")
                        break
                    if self._parse_request_method(ack) == "BYE":
                        self._send_sip(self._build_response(ack, 200, "OK", local_tag=dialog["local_tag"]))
                        self._clear_last_error()
                        self._forget_dialog(dialog)
                        return True
                    if self._parse_request_method(ack) == "INVITE":
                        answer_reinvite(ack)
                        ack_deadline = time.time() + Config.SIP_TIMEOUT
                continue

        self._set_last_error("Dialog did not end before timeout")
        logger.warning("Dialog did not end before timeout")
        return False

    def answer_next_media_switch(self, dialog: Dict[str, Any], timeout: float = None) -> bool:
        """Answer one in-dialog media-switch re-INVITE on an established dialog."""
        if not dialog:
            return False

        deadline = time.time() + (timeout if timeout is not None else Config.SIP_TIMEOUT * 2)
        while time.time() < deadline:
            message = self._receive_sip(timeout=1.0)
            if not message:
                continue

            call_id = self._extract_header(message, "Call-ID") or ""
            method = self._parse_request_method(message)

            if method == "BYE":
                self._answer_in_dialog_bye(message, call_id)
                if call_id == dialog["call_id"]:
                    self._set_last_error("Dialog ended before media switch completed")
                    return False
                continue

            if method != "INVITE":
                continue

            if call_id != dialog["call_id"]:
                if call_id in self._dialogs:
                    self._answer_waiting_in_dialog_invite(message, call_id)
                continue

            self._answer_waiting_in_dialog_invite(message, call_id)

            ack_deadline = time.time() + Config.SIP_TIMEOUT
            while time.time() < ack_deadline:
                ack = self._receive_sip(timeout=1.0)
                if not ack:
                    continue

                ack_call_id = self._extract_header(ack, "Call-ID") or ""
                ack_method = self._parse_request_method(ack)

                if ack_call_id != dialog["call_id"]:
                    if ack_method == "INVITE" and ack_call_id in self._dialogs:
                        self._answer_waiting_in_dialog_invite(ack, ack_call_id)
                    elif ack_method == "BYE":
                        self._answer_in_dialog_bye(ack, ack_call_id)
                    continue

                if ack_method == "ACK":
                    logger.info("Received ACK for answered media-switch re-INVITE")
                    self._clear_last_error()
                    return True

                if ack_method == "BYE":
                    self._answer_in_dialog_bye(ack, ack_call_id)
                    self._set_last_error("Dialog ended while waiting for media-switch ACK")
                    return False

                if ack_method == "INVITE":
                    self._answer_waiting_in_dialog_invite(ack, ack_call_id)
                    ack_deadline = time.time() + Config.SIP_TIMEOUT

            self._set_last_error("Media-switch re-INVITE was not ACKed")
            logger.warning("Media-switch re-INVITE was not ACKed")
            return False

        self._set_last_error("No media-switch re-INVITE received before timeout")
        logger.warning("No media-switch re-INVITE received before timeout")
        return False

    def active_dialogs(self) -> List[Dict[str, Any]]:
        """Return the currently tracked SIP dialogs."""
        return list(self._dialogs.values())

    def bye(self) -> bool:
        """
        Send BYE to end current call.

        Returns:
            True if BYE was acknowledged
        """
        if not self._in_call:
            return True

        dialog = {
            "call_id": self._call_dialog_id or self._call_id,
            "local_tag": self._call_local_tag or self._local_tag,
            "remote_tag": self._call_remote_tag,
            "target_uri": self._call_target_uri or self._sip_uri,
            "remote_target": self._remote_target or self._call_target_uri or self._sip_uri,
            "route_set": list(self._route_set),
        }
        if self._send_bye_for_dialog(dialog):
            self._clear_active_dialog()
            self._clear_last_error()
            return True

        self._set_last_error("BYE was not acknowledged")
        self._clear_active_dialog()
        return False

    def _establish_outgoing_call(self, target_uri: str, sdp_video: bool) -> bool:
        """Send an initial INVITE and drive the dialog to the confirmed state."""
        dialog = self._establish_dialog(target_uri=target_uri, sdp_video=sdp_video)
        if not dialog:
            return False

        self._store_active_dialog(
            call_id=dialog["call_id"],
            local_tag=dialog["local_tag"],
            remote_tag=dialog["remote_tag"],
            target_uri=dialog["target_uri"],
            remote_target=dialog["remote_target"],
            route_set=dialog["route_set"],
            video=dialog["video"],
        )
        self._in_call = True
        logger.info("Received 200 OK to INVITE - call established")
        return True

    def _send_reinvite(self, hold: bool) -> bool:
        """Send an in-dialog re-INVITE to place the call on hold or resume it."""
        if not self._in_call or not self._call_dialog_id:
            self._set_last_error("No active call available for re-INVITE")
            logger.error("No active call available for re-INVITE")
            return False

        dialog = {
            "call_id": self._call_dialog_id,
            "local_tag": self._call_local_tag,
            "remote_tag": self._call_remote_tag,
            "target_uri": self._call_target_uri,
            "remote_target": self._remote_target or self._call_target_uri,
            "route_set": list(self._route_set),
            "video": self._call_is_video,
        }
        if not self._send_reinvite_for_dialog(dialog, hold=hold):
            return False

        self._call_remote_tag = dialog["remote_tag"]
        self._remote_target = dialog["remote_target"]
        self._route_set = list(dialog["route_set"])
        return True

    def _establish_dialog(self, target_uri: str, sdp_video: bool) -> Optional[Dict[str, Any]]:
        """Establish an outgoing SIP dialog and return its state."""
        self._clear_last_error()
        call_id = self._generate_call_id()
        local_tag = self._generate_tag()
        self._cseq += 1
        invite_cseq = self._cseq
        route_set = list(self._service_route_set)

        invite_msg = self._build_invite(
            target_uri=target_uri,
            call_id=call_id,
            local_tag=local_tag,
            sdp=self._build_sdp(video=sdp_video),
            route_set=route_set,
        )
        self._send_sip(invite_msg)

        remote_tag = ""
        deadline = time.time() + Config.SIP_TIMEOUT * 3

        while time.time() < deadline:
            response = self._receive_sip(timeout=5.0)
            if response is None:
                continue

            request_method = self._parse_request_method(response)
            if request_method == "INVITE":
                request_call_id = self._extract_header(response, "Call-ID") or ""
                to_header = self._extract_header(response, "To") or ""
                if self._extract_tag(to_header) or request_call_id in self._dialogs:
                    self._answer_waiting_in_dialog_invite(response, request_call_id)
                continue
            if request_method == "BYE":
                request_call_id = self._extract_header(response, "Call-ID") or ""
                self._answer_in_dialog_bye(response, request_call_id)
                continue

            status_code = self._parse_status_code(response)
            if status_code == 0:
                continue
            if (self._extract_header(response, "Call-ID") or "") != call_id:
                logger.debug("Dialog flow: skipped response for unrelated Call-ID")
                continue

            logger.debug("Dialog flow: received %d", status_code)

            if status_code == 100:
                logger.info("Received 100 Trying")
                continue

            if status_code == 180:
                logger.info("Received 180 Ringing")
                remote_tag = self._extract_tag(self._extract_header(response, "To") or "")
                continue

            if status_code == 183:
                logger.info("Received 183 Session Progress")
                remote_tag = self._extract_tag(self._extract_header(response, "To") or "")
                rseq = 1
                rseq_header = self._extract_header(response, "RSeq")
                if rseq_header:
                    try:
                        rseq = int(rseq_header.strip())
                    except ValueError:
                        rseq = 1

                self._cseq += 1
                prack_msg = self._build_prack(
                    target_uri=target_uri,
                    call_id=call_id,
                    local_tag=local_tag,
                    remote_tag=remote_tag,
                    rseq=rseq,
                    invite_cseq=invite_cseq,
                    route_set=route_set,
                )
                self._send_sip(prack_msg)
                logger.info("Sent PRACK (RSeq=%d)", rseq)
                continue

            if status_code == 200:
                cseq_header = self._extract_header(response, "CSeq") or ""
                if "PRACK" in cseq_header:
                    logger.info("Received 200 OK to PRACK")
                    continue
                if "INVITE" in cseq_header:
                    if self._extract_cseq_number(cseq_header) != invite_cseq:
                        logger.debug("Skipped 200 OK for old INVITE CSeq: %s", cseq_header)
                        continue
                    remote_tag = self._extract_tag(self._extract_header(response, "To") or "")
                    contact = self._extract_header(response, "Contact") or ""
                    remote_target = self._extract_uri(contact) or target_uri
                    route_set = self._extract_record_routes(response) or route_set
                    dialog = {
                        "call_id": call_id,
                        "local_tag": local_tag,
                        "remote_tag": remote_tag,
                        "target_uri": target_uri,
                        "remote_target": remote_target,
                        "route_set": route_set,
                        "video": sdp_video,
                    }
                    ack_msg = self._build_ack(
                        target_uri=remote_target,
                        call_id=call_id,
                        local_tag=local_tag,
                        remote_tag=remote_tag,
                        ack_cseq=invite_cseq,
                        route_set=route_set,
                    )
                    self._send_sip(ack_msg)
                    self._clear_last_error()
                    return dialog

                logger.debug("Received 200 OK (unknown method)")
                continue

            if status_code == 486:
                cseq_header = self._extract_header(response, "CSeq") or ""
                if "INVITE" not in cseq_header or self._extract_cseq_number(cseq_header) != invite_cseq:
                    continue
                self._set_last_error("Call rejected: 486 Busy Here")
                logger.warning("Call rejected: 486 Busy Here")
                self._send_ack_for_error(target_uri, call_id, local_tag, remote_tag, response)
                return None

            if status_code == 487:
                cseq_header = self._extract_header(response, "CSeq") or ""
                if "INVITE" not in cseq_header or self._extract_cseq_number(cseq_header) != invite_cseq:
                    continue
                self._set_last_error("Call cancelled: 487 Request Terminated")
                logger.warning("Call cancelled: 487 Request Terminated")
                return None

            if 400 <= status_code < 700:
                cseq_header = self._extract_header(response, "CSeq") or ""
                if "INVITE" not in cseq_header or self._extract_cseq_number(cseq_header) != invite_cseq:
                    continue
                self._set_last_error(f"Call failed with {status_code}")
                logger.warning("Call failed with %d", status_code)
                self._send_ack_for_error(target_uri, call_id, local_tag, remote_tag, response)
                return None

        self._set_last_error(f"Call setup failed (timeout) for {target_uri}")
        logger.error("Call setup failed (timeout)")
        return None

    def _send_reinvite_for_dialog(
        self,
        dialog: Dict[str, Any],
        hold: bool,
        video: Optional[bool] = None,
        connection_ip: Optional[str] = None,
    ) -> bool:
        """Send a hold/resume/media-switch re-INVITE for a specific dialog."""
        self._clear_last_error()
        previous_video = bool(dialog.get("video", False))
        target_video = previous_video if video is None else bool(video)
        self._cseq += 1
        reinvite_cseq = self._cseq
        reinvite = self._build_invite(
            target_uri=dialog["remote_target"] or dialog["target_uri"],
            call_id=dialog["call_id"],
            local_tag=dialog["local_tag"],
            sdp=self._build_sdp(
                video=target_video,
                direction="sendonly" if hold else "sendrecv",
                connection_ip=connection_ip,
            ),
            route_set=dialog["route_set"],
            remote_tag=dialog["remote_tag"],
        )
        self._send_sip(reinvite)
        if hold:
            action = "hold"
        elif video is None:
            action = "resume"
        elif target_video:
            action = "audio-to-video switch"
        else:
            action = "video-to-audio switch"
        logger.info("Sent %s re-INVITE", action)

        deadline = time.time() + Config.SIP_TIMEOUT * 2
        while time.time() < deadline:
            response = self._receive_sip(timeout=2.0)
            if not response:
                continue

            request_method = self._parse_request_method(response)
            if request_method == "INVITE":
                request_call_id = self._extract_header(response, "Call-ID") or ""
                to_header = self._extract_header(response, "To") or ""
                if self._extract_tag(to_header) or request_call_id in self._dialogs:
                    self._answer_waiting_in_dialog_invite(response, request_call_id)
                continue
            if request_method == "BYE":
                request_call_id = self._extract_header(response, "Call-ID") or ""
                self._answer_in_dialog_bye(response, request_call_id)
                if request_call_id == dialog["call_id"]:
                    self._clear_last_error()
                    return True
                continue

            status_code = self._parse_status_code(response)
            if status_code == 0:
                continue
            if not self._response_matches(response, dialog["call_id"], "INVITE", reinvite_cseq):
                logger.debug("Skipped re-INVITE response for unrelated dialog/CSeq")
                continue

            if status_code in (100, 180, 183):
                logger.info("Re-INVITE provisional response: %d", status_code)
                continue

            if status_code == 200:
                dialog["remote_tag"] = (
                    self._extract_tag(self._extract_header(response, "To") or "")
                    or dialog["remote_tag"]
                )
                contact = self._extract_header(response, "Contact") or ""
                if contact:
                    dialog["remote_target"] = self._extract_uri(contact)
                route_set = self._extract_record_routes(response)
                if route_set:
                    dialog["route_set"] = route_set
                ack = self._build_ack(
                    target_uri=dialog["remote_target"] or dialog["target_uri"],
                    call_id=dialog["call_id"],
                    local_tag=dialog["local_tag"],
                    remote_tag=dialog["remote_tag"],
                    ack_cseq=reinvite_cseq,
                    route_set=dialog["route_set"],
                )
                self._send_sip(ack)
                dialog["video"] = target_video
                logger.info("Re-INVITE completed successfully")
                self._clear_last_error()
                return True

            if 400 <= status_code < 700:
                self._set_last_error(f"Re-INVITE failed with {status_code}")
                logger.warning("Re-INVITE failed with %d", status_code)
                self._send_ack_for_error(
                    dialog["remote_target"] or dialog["target_uri"],
                    dialog["call_id"],
                    dialog["local_tag"],
                    dialog["remote_tag"],
                    response,
                )
                return False

        self._set_last_error("Re-INVITE timed out")
        logger.error("Re-INVITE timed out")
        return False

    def _send_bye_for_dialog(self, dialog: Dict[str, Any], tolerate_timeout: bool = False) -> bool:
        """Send BYE for a specific dialog."""
        if not dialog:
            return True

        self._cseq += 1
        bye_cseq = self._cseq
        bye_msg = self._build_bye(
            target_uri=dialog["remote_target"] or dialog["target_uri"],
            call_id=dialog["call_id"],
            local_tag=dialog["local_tag"],
            remote_tag=dialog["remote_tag"],
            route_set=dialog.get("route_set"),
        )
        attempts = 1 if tolerate_timeout else 2

        for attempt in range(attempts):
            self._send_sip(bye_msg)

            deadline = time.time() + (5.0 if tolerate_timeout else 8.0)
            while time.time() < deadline:
                response = self._receive_sip(timeout=1.0)
                if not response:
                    continue

                request_method = self._parse_request_method(response)
                if request_method == "BYE":
                    request_call_id = self._extract_header(response, "Call-ID") or ""
                    self._answer_in_dialog_bye(response, request_call_id)
                    if request_call_id == dialog["call_id"]:
                        logger.info("Received crossed BYE while waiting for BYE response")
                        self._clear_last_error()
                        return True
                    continue

                if (self._extract_header(response, "Call-ID") or "") != dialog["call_id"]:
                    continue

                cseq_header = (self._extract_header(response, "CSeq") or "").upper()
                if "BYE" not in cseq_header:
                    continue
                if self._extract_cseq_number(cseq_header) != bye_cseq:
                    continue

                if self._parse_status_code(response) == 200:
                    logger.info("Received 200 OK to BYE - dialog ended")
                    self._clear_last_error()
                    return True

            if attempt + 1 < attempts:
                logger.warning("No 200 OK received for BYE, retransmitting once")

        if not tolerate_timeout:
            self._set_last_error("No 200 OK received for BYE")
            logger.warning("No 200 OK received for BYE")
        return False

    def _wait_for_incoming_invite(self, timeout: float) -> Optional[str]:
        """Wait for the next incoming INVITE request."""
        deadline = time.time() + timeout
        while time.time() < deadline:
            message = self._receive_sip(timeout=1.0)
            if message and self._parse_request_method(message) == "INVITE":
                call_id = self._extract_header(message, "Call-ID") or ""
                to_header = self._extract_header(message, "To") or ""
                if self._extract_tag(to_header) or call_id in self._dialogs:
                    self._answer_waiting_in_dialog_invite(message, call_id)
                    continue
                return message
        return None

    def _answer_waiting_in_dialog_invite(self, invite: str, call_id: str) -> None:
        """Handle a re-INVITE seen while waiting for a new incoming dialog."""
        dialog = self._dialogs.get(call_id)
        if not dialog:
            self._send_sip(self._build_response(invite, 481, "Call/Transaction Does Not Exist"))
            logger.info("Rejected stray in-dialog INVITE while waiting for a new call")
            return

        body = self._extract_body(invite)
        offer_has_video = "m=video" in body
        dialog["video"] = offer_has_video
        self._send_sip(
            self._build_response(
                invite,
                200,
                "OK",
                local_tag=dialog["local_tag"],
                contact_uri=self._contact_uri,
                body=self._build_sdp(
                    video=offer_has_video,
                    direction=self._sdp_direction_for_offer(body),
                ),
                content_type="application/sdp",
            )
        )
        logger.info("Answered in-dialog re-INVITE while waiting for a new call")

    def _answer_in_dialog_bye(self, bye: str, call_id: str) -> None:
        """Acknowledge a BYE that arrives while this client is busy elsewhere."""
        dialog = self._dialogs.get(call_id)
        local_tag = dialog.get("local_tag", "") if dialog else ""
        if not local_tag and call_id == self._call_dialog_id:
            local_tag = self._call_local_tag

        self._send_sip(self._build_response(bye, 200, "OK", local_tag=local_tag))
        if dialog:
            self._forget_dialog(dialog)
        elif call_id == self._call_dialog_id:
            self._clear_active_dialog()
        logger.info("Answered in-dialog BYE while waiting on another transaction")

    def _answer_incoming_dialog(self, invite: str, answer_delay: float = 0.5) -> Optional[Dict[str, Any]]:
        """Answer one incoming INVITE and return dialog state."""
        from_header = self._extract_header(invite, "From") or ""
        to_header = self._extract_header(invite, "To") or ""
        call_id = self._extract_header(invite, "Call-ID") or self._generate_call_id()
        remote_target = self._extract_uri(self._extract_header(invite, "Contact") or "")
        target_uri = self._extract_uri(to_header) or self._sip_uri
        remote_tag = self._extract_tag(from_header)
        local_tag = self._extract_tag(to_header) or self._generate_tag()
        has_video = "m=video" in self._extract_body(invite)

        dialog = {
            "call_id": call_id,
            "local_tag": local_tag,
            "remote_tag": remote_tag,
            "target_uri": target_uri,
            "remote_target": remote_target or target_uri,
            "route_set": self._extract_record_routes(invite),
            "video": has_video,
        }

        self._send_sip(self._build_response(invite, 100, "Trying", local_tag=local_tag))
        time.sleep(answer_delay)
        self._send_sip(
            self._build_response(
                invite,
                180,
                "Ringing",
                local_tag=local_tag,
                contact_header=self._contact_header_invite,
            )
        )
        self._send_sip(
            self._build_response(
                invite,
                200,
                "OK",
                local_tag=local_tag,
                contact_header=self._contact_header_invite,
                body=self._build_sdp(video=has_video),
                content_type="application/sdp",
            )
        )
        return dialog

    def _build_refer_to(self, target_msisdn: str, replaced_dialog: Dict[str, Any]) -> str:
        """Build a Samsung-style Refer-To target with an encoded Replaces value."""
        replaces = self._format_replaces(replaced_dialog)
        target_user = self._resolve_target_user(target_msisdn)

        if target_user != target_msisdn:
            # The harness registers known simulator UEs under their IMSI IMPU.
            # Route REFER/Replaces to the same registered identity so merge tests
            # exercise dialog handling rather than fail on terminating lookup.
            return (
                f"<sip:{target_user}@{self._ims_domain}"
                f";method=INVITE?Replaces={quote(replaces, safe='')}>"
            )

        return (
            f"<sip:{target_msisdn};phone-context={self._ims_domain}"
            f"@{self._ims_domain};user=phone;method=INVITE?Replaces={quote(replaces, safe='')}>"
        )

    def _build_target_uri(self, target_msisdn: str) -> str:
        """Build a routable target URI for the current test harness."""
        normalized = target_msisdn.strip()
        if normalized.startswith("sip:"):
            return normalized
        if "@" in normalized:
            return f"sip:{normalized}"
        target_user = self._resolve_target_user(target_msisdn)
        return f"sip:{target_user}@{self._ims_domain}"

    def _resolve_target_user(self, target_msisdn: str) -> str:
        """Resolve known simulator MSISDNs to the IMPU user-part they register with."""
        normalized = target_msisdn.strip()
        if normalized.startswith("sip:"):
            normalized = normalized[4:]
        normalized = normalized.split("@", 1)[0]
        normalized = normalized.split(";", 1)[0]

        for subscriber in Config.default_subscribers():
            if subscriber.msisdn == normalized:
                return subscriber.imsi

        return normalized

    def _send_refer(self, dialog: Dict[str, Any], refer_to: str) -> int:
        """Send an in-dialog REFER and return the final status code."""
        self._cseq += 1
        refer_msg = self._build_refer(dialog=dialog, refer_to=refer_to)
        self._send_sip(refer_msg)

        deadline = time.time() + Config.SIP_TIMEOUT * 2
        while time.time() < deadline:
            response = self._receive_sip(timeout=2.0)
            if not response:
                continue

            if (self._extract_header(response, "Call-ID") or "") != dialog["call_id"]:
                continue

            status_code = self._parse_status_code(response)
            if status_code and status_code < 200:
                continue
            if status_code:
                return status_code

        return 0

    @staticmethod
    def _format_replaces(dialog: Dict[str, Any]) -> str:
        """Format dialog identifiers into a Replaces header value."""
        return (
            f"{dialog['call_id']};to-tag={dialog['remote_tag']};from-tag={dialog['local_tag']}"
        )

    def _replaces_matches_dialog(self, replaces_value: str, dialog: Dict[str, Any]) -> bool:
        """Check whether a Replaces header targets the supplied dialog."""
        if not replaces_value or not dialog:
            return False

        decoded = unquote(replaces_value.strip().strip("<>"))
        parts = [part.strip() for part in decoded.split(";") if part.strip()]
        if not parts:
            return False

        call_id = parts[0]
        params: Dict[str, str] = {}
        for part in parts[1:]:
            if "=" in part:
                name, value = part.split("=", 1)
                params[name.strip().lower()] = value.strip()

        return (
            call_id == dialog["call_id"]
            and params.get("to-tag", "") == dialog["local_tag"]
            and params.get("from-tag", "") == dialog["remote_tag"]
        )

    def _build_refer(self, dialog: Dict[str, Any], refer_to: str) -> str:
        """Build an in-dialog REFER for a conference dialog."""
        branch = self._generate_branch()
        msg = f"REFER {dialog['remote_target'] or dialog['target_uri']} SIP/2.0\r\n"
        msg += f"Via: SIP/2.0/UDP {self._local_ip}:{self._local_port};branch={branch};rport\r\n"
        for route in dialog.get("route_set") or []:
            msg += f"Route: {route}\r\n"
        msg += "Max-Forwards: 70\r\n"
        msg += f"From: <{self._sip_uri}>;tag={dialog['local_tag']}\r\n"
        msg += f"To: <{dialog['target_uri']}>;tag={dialog['remote_tag']}\r\n"
        msg += f"Call-ID: {dialog['call_id']}\r\n"
        msg += f"CSeq: {self._cseq} REFER\r\n"
        msg += f"Contact: <{self._contact_uri}>\r\n"
        msg += f"Refer-To: {refer_to}\r\n"
        msg += f"Referred-By: <{self._sip_uri}>\r\n"
        msg += "Supported: replaces\r\n"
        msg += "Allow: INVITE, ACK, CANCEL, BYE, UPDATE, REFER, NOTIFY, PRACK, INFO\r\n"
        msg += "Content-Length: 0\r\n"
        msg += "\r\n"
        return msg

    def _store_active_dialog(
        self,
        call_id: str,
        local_tag: str,
        remote_tag: str,
        target_uri: str,
        remote_target: str,
        route_set: List[str],
        video: bool,
    ):
        """Persist dialog state for subsequent in-dialog requests."""
        self._call_dialog_id = call_id
        self._call_local_tag = local_tag
        self._call_remote_tag = remote_tag
        self._call_target_uri = target_uri
        self._remote_target = remote_target or target_uri
        self._route_set = route_set or []
        self._call_is_video = video

    def _clear_active_dialog(self):
        """Clear the current dialog state after the call ends."""
        self._in_call = False
        self._call_dialog_id = ""
        self._call_local_tag = ""
        self._call_remote_tag = ""
        self._call_target_uri = ""
        self._remote_target = ""
        self._route_set = list(self._service_route_set)
        self._call_is_video = False

    def _dialog_key(self, dialog: Dict[str, Any]) -> str:
        """Return the stable key used by the multi-dialog registry."""
        return dialog.get("call_id", "")

    def _remember_dialog(self, dialog: Dict[str, Any]):
        """Track an established dialog so supplemental tests can manage more than one call."""
        key = self._dialog_key(dialog)
        if key:
            self._dialogs[key] = dialog

    def _forget_dialog(self, dialog: Dict[str, Any]):
        """Remove a dialog from the registry after BYE completes."""
        key = self._dialog_key(dialog)
        if key:
            self._dialogs.pop(key, None)
        self._in_call = bool(self._dialogs)

    # ================================================================
    # SIP Message Builders
    # ================================================================
    def _build_register(self, expires: int = 3600, with_auth: bool = False) -> str:
        """
        Build a SIP REGISTER message.

        Args:
            expires: Registration expiry in seconds
            with_auth: Include Authorization header

        Returns:
            Complete SIP REGISTER message string
        """
        branch = self._generate_branch()

        msg = f"REGISTER sip:{self._ims_domain} SIP/2.0\r\n"
        msg += f"Via: SIP/2.0/UDP {self._local_ip}:{self._local_port};branch={branch};rport\r\n"
        msg += f"Max-Forwards: 70\r\n"
        msg += f"From: <{self._sip_uri}>;tag={self._local_tag}\r\n"
        msg += f"To: <{self._sip_uri}>\r\n"
        msg += f"Call-ID: {self._call_id}\r\n"
        msg += f"CSeq: {self._cseq} REGISTER\r\n"
        msg += f"Contact: <sip:{self._imsi}@{self._local_ip}:{self._local_port}>;expires={expires}\r\n"
        msg += f"Supported: path\r\n"
        # No sec-agree/IPSec — test container has no kernel IPSec support.
        # P-CSCF WITH_SIPP_TEST bypass handles test IPs without IPSec.
        msg += f"Allow: INVITE, ACK, CANCEL, BYE, UPDATE, REFER, NOTIFY, MESSAGE, PRACK, INFO\r\n"
        msg += f"Expires: {expires}\r\n"

        if with_auth and self._auth_nonce:
            auth_header = self._build_authorization_header("REGISTER")
            msg += f"{auth_header}\r\n"
        elif not with_auth:
            # Initial REGISTER: include empty Authorization with algorithm preference
            # This tells S-CSCF to use AKAv1-MD5 for the 401 challenge, which
            # includes base64(RAND||AUTN||CK||IK) in the nonce.
            # Without this, S-CSCF defaults to MD5 with a short nonce (no AKA).
            private_id = f"{self._imsi}@{self._ims_domain}"
            msg += f'Authorization: Digest username="{private_id}", realm="{self._ims_domain}", nonce="", uri="sip:{self._ims_domain}", response="", algorithm=AKAv1-MD5\r\n'

        msg += f"Content-Length: 0\r\n"
        msg += f"\r\n"

        return msg

    def _build_invite(
        self,
        target_uri: str,
        call_id: str,
        local_tag: str,
        sdp: str,
        route_set: Optional[List[str]] = None,
        remote_tag: str = "",
    ) -> str:
        """Build a SIP INVITE message."""
        branch = self._generate_branch()
        route_set = self._service_route_set if route_set is None else route_set

        msg = f"INVITE {target_uri} SIP/2.0\r\n"
        msg += f"Via: SIP/2.0/UDP {self._local_ip}:{self._local_port};branch={branch};rport\r\n"

        # Add route set from Service-Route
        for route in route_set:
            msg += f"Route: {route}\r\n"

        msg += f"Max-Forwards: 70\r\n"
        msg += f"From: <{self._sip_uri}>;tag={local_tag}\r\n"
        msg += f"To: <{target_uri}>"
        if remote_tag:
            msg += f";tag={remote_tag}"
        msg += f"\r\n"
        msg += f"Call-ID: {call_id}\r\n"
        msg += f"CSeq: {self._cseq} INVITE\r\n"
        msg += f"Contact: {self._contact_header_invite}\r\n"
        msg += f"P-Preferred-Identity: <{self._sip_uri}>\r\n"
        msg += f"P-Access-Network-Info: 3GPP-E-UTRAN-FDD;utran-cell-id-3gpp=00101000012345\r\n"
        msg += f"Supported: 100rel, precondition, timer\r\n"
        msg += f"Allow: INVITE, ACK, CANCEL, BYE, UPDATE, REFER, NOTIFY, PRACK, INFO\r\n"
        msg += f"Content-Type: application/sdp\r\n"
        msg += f"Content-Length: {len(sdp)}\r\n"
        msg += f"\r\n"
        msg += sdp

        return msg

    def _build_prack(
        self,
        target_uri: str,
        call_id: str,
        local_tag: str,
        remote_tag: str,
        rseq: int,
        invite_cseq: int,
        route_set: Optional[List[str]] = None,
    ) -> str:
        """Build a SIP PRACK message."""
        branch = self._generate_branch()
        route_set = self._route_set if route_set is None else route_set

        msg = f"PRACK {target_uri} SIP/2.0\r\n"
        msg += f"Via: SIP/2.0/UDP {self._local_ip}:{self._local_port};branch={branch};rport\r\n"

        for route in route_set:
            msg += f"Route: {route}\r\n"

        msg += f"Max-Forwards: 70\r\n"
        msg += f"From: <{self._sip_uri}>;tag={local_tag}\r\n"
        msg += f"To: <{target_uri}>;tag={remote_tag}\r\n"
        msg += f"Call-ID: {call_id}\r\n"
        msg += f"CSeq: {self._cseq} PRACK\r\n"
        msg += f"RAck: {rseq} {invite_cseq} INVITE\r\n"
        msg += f"Content-Length: 0\r\n"
        msg += f"\r\n"

        return msg

    def _build_ack(
        self,
        target_uri: str,
        call_id: str,
        local_tag: str,
        remote_tag: str,
        ack_cseq: Optional[int] = None,
        route_set: Optional[List[str]] = None,
    ) -> str:
        """Build a SIP ACK message."""
        branch = self._generate_branch()
        ack_cseq = self._cseq if ack_cseq is None else ack_cseq
        route_set = self._route_set if route_set is None else route_set

        msg = f"ACK {target_uri} SIP/2.0\r\n"
        msg += f"Via: SIP/2.0/UDP {self._local_ip}:{self._local_port};branch={branch};rport\r\n"

        for route in route_set:
            msg += f"Route: {route}\r\n"

        msg += f"Max-Forwards: 70\r\n"
        msg += f"From: <{self._sip_uri}>;tag={local_tag}\r\n"
        msg += f"To: <{target_uri}>;tag={remote_tag}\r\n"
        msg += f"Call-ID: {call_id}\r\n"
        msg += f"CSeq: {ack_cseq} ACK\r\n"
        msg += f"Content-Length: 0\r\n"
        msg += f"\r\n"

        return msg

    def _build_bye(
        self,
        target_uri: str,
        call_id: str,
        local_tag: str,
        remote_tag: str,
        route_set: Optional[List[str]] = None,
    ) -> str:
        """Build a SIP BYE message."""
        branch = self._generate_branch()
        route_set = self._route_set if route_set is None else route_set

        msg = f"BYE {target_uri} SIP/2.0\r\n"
        msg += f"Via: SIP/2.0/UDP {self._local_ip}:{self._local_port};branch={branch};rport\r\n"

        # Reverse route set for BYE
        for route in reversed(route_set):
            msg += f"Route: {route}\r\n"

        msg += f"Max-Forwards: 70\r\n"
        msg += f"From: <{self._sip_uri}>;tag={local_tag}\r\n"
        msg += f"To: <{target_uri}>;tag={remote_tag}\r\n"
        msg += f"Call-ID: {call_id}\r\n"
        msg += f"CSeq: {self._cseq} BYE\r\n"
        msg += f"Content-Length: 0\r\n"
        msg += f"\r\n"

        return msg

    def _build_response(
        self,
        request: str,
        status_code: int,
        reason: str,
        local_tag: str = "",
        contact_uri: str = "",
        contact_header: str = "",
        body: str = "",
        content_type: str = "",
    ) -> str:
        """Build a SIP response by mirroring transaction headers from a request."""
        via_headers = self._extract_headers(request, "Via")
        from_header = self._extract_header(request, "From") or ""
        to_header = self._extract_header(request, "To") or ""
        call_id = self._extract_header(request, "Call-ID") or ""
        cseq = self._extract_header(request, "CSeq") or ""
        record_routes = self._extract_record_routes(request)

        if local_tag and "tag=" not in to_header:
            to_header = f"{to_header};tag={local_tag}"

        msg = f"SIP/2.0 {status_code} {reason}\r\n"
        for via in via_headers:
            msg += f"Via: {via}\r\n"
        for rr in record_routes:
            msg += f"Record-Route: {rr}\r\n"
        msg += f"From: {from_header}\r\n"
        msg += f"To: {to_header}\r\n"
        msg += f"Call-ID: {call_id}\r\n"
        msg += f"CSeq: {cseq}\r\n"
        msg += f"Allow: INVITE, ACK, CANCEL, BYE, UPDATE, REFER, NOTIFY, PRACK, INFO\r\n"
        if contact_header:
            msg += f"Contact: {contact_header}\r\n"
        elif contact_uri:
            msg += f"Contact: <{contact_uri}>\r\n"
        if content_type and body:
            msg += f"Content-Type: {content_type}\r\n"
        msg += f"Content-Length: {len(body)}\r\n"
        msg += "\r\n"
        msg += body
        return msg

    def _send_ack_for_error(
        self, target_uri, call_id, local_tag, remote_tag, response
    ):
        """Send ACK for a non-2xx final response."""
        if not remote_tag:
            to_header = self._extract_header(response, "To")
            remote_tag = self._extract_tag(to_header) if to_header else ""

        ack = self._build_ack(
            target_uri,
            call_id,
            local_tag,
            remote_tag,
            ack_cseq=self._extract_cseq_number(self._extract_header(response, "CSeq") or ""),
        )
        self._send_sip(ack)

    # ================================================================
    # AKA Authentication
    # ================================================================
    def _parse_www_authenticate(self, response: str) -> bool:
        """
        Parse WWW-Authenticate header from 401 response.

        Extracts: realm, nonce, algorithm, opaque, qop

        The nonce in IMS AKA contains: base64(RAND || AUTN || server data)

        Returns:
            True if header parsed successfully
        """
        www_auth = self._extract_header(response, "WWW-Authenticate")
        if not www_auth:
            logger.error("No WWW-Authenticate header found")
            return False

        logger.debug("WWW-Authenticate: %s", www_auth[:100])

        # Parse realm
        realm_match = re.search(r'realm="([^"]*)"', www_auth)
        if realm_match:
            self._auth_realm = realm_match.group(1)

        # Parse nonce (base64-encoded RAND||AUTN)
        nonce_match = re.search(r'nonce="([^"]*)"', www_auth)
        if nonce_match:
            self._auth_nonce = nonce_match.group(1)
        else:
            logger.error("No nonce found in WWW-Authenticate")
            return False

        # Parse opaque
        opaque_match = re.search(r'opaque="([^"]*)"', www_auth)
        if opaque_match:
            self._auth_opaque = opaque_match.group(1)

        # Parse algorithm
        algo_match = re.search(r'algorithm=(\S+)', www_auth)
        self._auth_algorithm = algo_match.group(1).rstrip(',') if algo_match else "AKAv1-MD5"

        # Parse qop
        qop_match = re.search(r'qop="([^"]*)"', www_auth)
        self._auth_qop = qop_match.group(1) if qop_match else "auth"

        logger.info("Parsed AKA challenge: realm=%s, algo=%s",
                     self._auth_realm, self._auth_algorithm)
        return True

    def _compute_aka_response(self) -> bool:
        """
        Compute authentication response from the 401 challenge.

        IMS authentication: The nonce from the 401 contains base64(RAND||AUTN).
        Even when algorithm=MD5, PyHSS/S-CSCF uses AKA-based auth where
        the "password" for MD5 Digest is the hex-encoded RES from Milenage.

        Returns:
            True if computation succeeded
        """
        if not self._milenage:
            logger.error("No Milenage instance configured")
            return False

        try:
            # Try to decode nonce as base64(RAND || AUTN)
            import base64
            nonce_bytes = base64.b64decode(self._auth_nonce)
            logger.debug("Decoded nonce: %d bytes: %s", len(nonce_bytes), nonce_bytes.hex()[:40])

            if len(nonce_bytes) >= 32:
                rand = nonce_bytes[0:16]
                autn = nonce_bytes[16:32]
                logger.info("Extracted RAND=%s AUTN=%s from nonce", rand.hex(), autn.hex())

                res, ck, ik = self._milenage.authenticate(rand, autn)
                self._auth_res = res
                self._ck = ck
                self._ik = ik
                logger.info("AKA auth OK: RES=%s", res.hex())
                return True
            else:
                logger.warning("Nonce too short for AKA (%d bytes), using empty password", len(nonce_bytes))
                self._auth_res = b""
                self._ck = None
                self._ik = None
                return True

        except Exception as e:
            logger.error("AKA computation failed: %s", e)
            # Fall back to empty password
            logger.warning("Falling back to empty password for Digest auth")
            self._auth_res = b""
            self._ck = None
            self._ik = None
            return True

    def _build_authorization_header(self, method: str) -> str:
        """
        Build the Authorization header for IMS AKA.

        For AKAv1-MD5:
            response = MD5(HA1:nonce:nc:cnonce:qop:HA2)
            HA1 = MD5(private_id:realm:RES_hex)
            HA2 = MD5(method:uri)

        For Digest-AKAv1-MD5, the "password" is the hex-encoded RES.
        """
        uri = f"sip:{self._ims_domain}"
        nc = "00000001"
        cnonce = self._generate_cnonce()

        # Private identity for IMS
        private_id = f"{self._imsi}@{self._ims_domain}"

        # For AKAv1-MD5, the "password" is the RAW BYTES of RES.
        # S-CSCF log confirmed: raw bytes give matching response.
        # (hex string gives mismatch — verified via scscf "UE said / we expect" logs)
        res_bytes = self._auth_res if (hasattr(self, '_auth_res') and self._auth_res) else b""

        # HA1 = MD5(username:realm:RES_raw_bytes)
        import hashlib as _hl
        md5_ha1 = _hl.md5()
        md5_ha1.update(private_id.encode())
        md5_ha1.update(b":")
        md5_ha1.update(self._auth_realm.encode())
        md5_ha1.update(b":")
        md5_ha1.update(res_bytes)
        ha1 = md5_ha1.hexdigest()

        logger.debug("Digest auth: username=%s realm=%s password(raw)=%s",
                     private_id, self._auth_realm, res_bytes.hex() if res_bytes else "empty")
        logger.debug("HA1: %s", ha1)

        # HA2 = MD5(method:uri)
        ha2_input = f"{method}:{uri}"
        ha2 = hashlib.md5(ha2_input.encode()).hexdigest()

        logger.debug("HA2 input: %s -> %s", ha2_input, ha2)

        # Response = MD5(HA1:nonce:nc:cnonce:qop:HA2)
        response_input = f"{ha1}:{self._auth_nonce}:{nc}:{cnonce}:{self._auth_qop}:{ha2}"
        response = hashlib.md5(response_input.encode()).hexdigest()
        logger.debug("Response input: %s -> %s", response_input, response)

        # Build Authorization header
        auth = f'Authorization: Digest username="{private_id}"'
        auth += f', realm="{self._auth_realm}"'
        auth += f', nonce="{self._auth_nonce}"'
        auth += f', uri="{uri}"'
        auth += f', response="{response}"'
        auth += f', algorithm={self._auth_algorithm}'
        auth += f', qop={self._auth_qop}'
        auth += f', nc={nc}'
        auth += f', cnonce="{cnonce}"'

        if self._auth_opaque:
            auth += f', opaque="{self._auth_opaque}"'

        # Include IK and CK for security association (IPSec)
        if self._ik:
            auth += f', ik="{self._ik.hex()}"'
        if self._ck:
            auth += f', ck="{self._ck.hex()}"'

        return auth

    # ================================================================
    # SDP Construction
    # ================================================================
    def _build_sdp(
        self,
        video: bool = False,
        direction: str = "sendrecv",
        connection_ip: Optional[str] = None,
    ) -> str:
        """
        Build SDP offer for VoLTE or ViLTE.

        VoLTE (audio-only): AMR-WB codec, QCI 1
        ViLTE (video+audio): H.264 + AMR-WB, QCI 1 + QCI 2

        Args:
            video: True to include video media line
            direction: SDP media direction attribute (sendrecv/sendonly/inactive)

        Returns:
            Complete SDP string
        """
        session_id = str(random.randint(1000000, 9999999))
        session_version = "1"
        rtp_port = self._rtp_port
        media_ip = connection_ip or self._local_ip

        sdp = "v=0\r\n"
        sdp += f"o=- {session_id} {session_version} IN IP4 {self._local_ip}\r\n"
        sdp += "s=-\r\n"
        sdp += f"c=IN IP4 {media_ip}\r\n"
        sdp += "t=0 0\r\n"

        # Audio media line (AMR-WB, payload type 96)
        sdp += f"m=audio {rtp_port} RTP/AVP 96 97\r\n"
        sdp += f"b=AS:40\r\n"
        sdp += f"b=RS:600\r\n"
        sdp += f"b=RR:2000\r\n"
        sdp += f"a=rtpmap:96 AMR-WB/16000/1\r\n"
        sdp += f"a=fmtp:96 mode-change-capability=2;max-red=220\r\n"
        sdp += f"a=rtpmap:97 telephone-event/16000\r\n"
        sdp += f"a=fmtp:97 0-15\r\n"
        sdp += f"a=curr:qos local none\r\n"
        sdp += f"a=curr:qos remote none\r\n"
        sdp += f"a=des:qos mandatory local sendrecv\r\n"
        sdp += f"a=des:qos mandatory remote sendrecv\r\n"
        sdp += f"a={direction}\r\n"
        sdp += f"a=ptime:20\r\n"
        sdp += f"a=maxptime:240\r\n"

        if video:
            video_port = rtp_port + 2
            sdp += f"m=video {video_port} RTP/AVP 99\r\n"
            sdp += f"b=AS:384\r\n"
            sdp += f"b=RS:600\r\n"
            sdp += f"b=RR:2000\r\n"
            sdp += f"a=rtpmap:99 H264/90000\r\n"
            sdp += f"a=fmtp:99 profile-level-id=42e00c;packetization-mode=1\r\n"
            sdp += f"a=curr:qos local none\r\n"
            sdp += f"a=curr:qos remote none\r\n"
            sdp += f"a=des:qos mandatory local sendrecv\r\n"
            sdp += f"a=des:qos mandatory remote sendrecv\r\n"
            sdp += f"a={direction}\r\n"

        return sdp

    # ================================================================
    # SIP Message Parsing Helpers
    # ================================================================
    @staticmethod
    def _parse_status_code(response: str) -> int:
        """Extract status code from SIP response first line."""
        try:
            first_line = response.split('\r\n')[0]
            parts = first_line.split(' ', 2)
            if len(parts) >= 2:
                return int(parts[1])
        except (ValueError, IndexError):
            pass
        return 0

    def _response_matches(
        self,
        response: str,
        call_id: str,
        method: str,
        cseq: Optional[int] = None,
    ) -> bool:
        """Return True when a SIP response belongs to the expected transaction."""
        if self._parse_status_code(response) == 0:
            return False
        if (self._extract_header(response, "Call-ID") or "") != call_id:
            return False
        cseq_header = self._extract_header(response, "CSeq") or ""
        if method.upper() not in cseq_header.upper():
            return False
        if cseq is not None and self._extract_cseq_number(cseq_header) != cseq:
            return False
        return True

    @staticmethod
    def _extract_header(message: str, header_name: str) -> Optional[str]:
        """Extract a header value from a SIP message."""
        # Handle multi-line headers and case-insensitive matching
        pattern = re.compile(
            rf'^{re.escape(header_name)}\s*:\s*(.+?)(?=\r?\n\S|\r?\n\r?\n)',
            re.IGNORECASE | re.MULTILINE | re.DOTALL
        )
        match = pattern.search(message)
        if match:
            return match.group(1).strip()

        # Simpler single-line search
        for line in message.split('\r\n'):
            if ':' in line:
                name, _, value = line.partition(':')
                if name.strip().lower() == header_name.lower():
                    return value.strip()
        return None

    @staticmethod
    def _extract_headers(message: str, header_name: str) -> List[str]:
        """Extract all occurrences of a SIP header."""
        values: List[str] = []
        for line in message.split('\r\n'):
            if ':' not in line:
                continue
            name, _, value = line.partition(':')
            if name.strip().lower() == header_name.lower():
                values.append(value.strip())
        return values

    @staticmethod
    def _extract_tag(header_value: str) -> str:
        """Extract tag parameter from a To/From header."""
        if not header_value:
            return ""
        match = re.search(r'tag=([^\s;,>]+)', header_value)
        return match.group(1) if match else ""

    @staticmethod
    def _extract_uri(header_value: str) -> str:
        """Extract SIP URI from a header value (e.g., Contact)."""
        match = re.search(r'<(sip:[^>]+)>', header_value)
        return match.group(1) if match else ""

    @staticmethod
    def _parse_request_method(message: str) -> str:
        """Return the SIP method from a request first line, or empty string for responses."""
        first_line = message.split('\r\n')[0]
        if first_line.startswith("SIP/2.0"):
            return ""
        return first_line.split(' ', 1)[0].strip().upper()

    @staticmethod
    def _extract_cseq_number(cseq_header: str) -> int:
        """Extract the numeric portion of a CSeq header."""
        try:
            return int((cseq_header or "0").split()[0])
        except (ValueError, IndexError):
            return 0

    @staticmethod
    def _extract_body(message: str) -> str:
        """Extract the body from a SIP message."""
        if "\r\n\r\n" in message:
            return message.split("\r\n\r\n", 1)[1]
        return ""

    @staticmethod
    def _sdp_direction_for_offer(sdp: str) -> str:
        """Pick a symmetric answer direction for a basic hold/resume exchange."""
        if "a=inactive" in sdp:
            return "inactive"
        if "a=sendonly" in sdp:
            return "recvonly"
        if "a=recvonly" in sdp:
            return "sendonly"
        return "sendrecv"

    @staticmethod
    def _extract_record_routes(message: str) -> List[str]:
        """Extract Record-Route headers (in order) from a SIP message."""
        routes = []
        for line in message.split('\r\n'):
            if line.lower().startswith('record-route:'):
                _, _, value = line.partition(':')
                # May contain multiple routes separated by commas
                for route in value.split(','):
                    route = route.strip()
                    if route:
                        routes.append(route)
        return routes

    def _parse_service_route(self, response: str):
        """Parse Service-Route headers for future request routing."""
        self._service_route_set = []
        for line in response.split('\r\n'):
            if line.lower().startswith('service-route:'):
                _, _, value = line.partition(':')
                for route in value.split(','):
                    route = route.strip()
                    if route:
                        self._service_route_set.append(route)

        self._route_set = list(self._service_route_set)
        if self._service_route_set:
            logger.info("Service-Route set: %s", self._service_route_set)

    # ================================================================
    # SIP Transport
    # ================================================================
    def _send_sip(self, message: str):
        """Send a SIP message via the appropriate transport."""
        if not self._sock:
            raise ConnectionError("SIP socket not connected")

        data = message.encode('utf-8')
        if message.startswith("SIP/2.0") and self._last_rx_transport == "tcp" and self._tcp_conn:
            self._tcp_conn.sendall(data)
            if self._tcp_peer:
                logger.debug(
                    "Sent SIP response (%d bytes) over TCP to %s:%d",
                    len(data),
                    self._tcp_peer[0],
                    self._tcp_peer[1],
                )
            else:
                logger.debug("Sent SIP response (%d bytes) over TCP", len(data))
        else:
            self._sock.sendto(data, (self._pcscf_ip, self._pcscf_port))
            logger.debug(
                "Sent SIP message (%d bytes) to %s:%d via UDP",
                len(data),
                self._pcscf_ip,
                self._pcscf_port,
            )

        # Log first line of message
        first_line = message.split('\r\n')[0]
        logger.info(">> %s", first_line)

    def _receive_sip(self, timeout: float = None) -> Optional[str]:
        """
        Receive a SIP message via UDP or TCP.

        Args:
            timeout: Receive timeout in seconds

        Returns:
            Received SIP message string or None on timeout
        """
        if not self._sock:
            raise ConnectionError("SIP socket not connected")

        deadline = time.time() + (
            timeout if timeout is not None else (self._sock.gettimeout() or Config.SIP_TIMEOUT)
        )

        try:
            while True:
                remaining = deadline - time.time()
                if remaining <= 0:
                    return None

                read_sockets = [self._sock]
                if self._tcp_server:
                    read_sockets.append(self._tcp_server)
                if self._tcp_conn:
                    read_sockets.append(self._tcp_conn)

                ready, _, _ = select.select(read_sockets, [], [], remaining)
                if not ready:
                    return None

                if self._tcp_server and self._tcp_server in ready:
                    conn, addr = self._tcp_server.accept()
                    conn.setblocking(False)
                    if self._tcp_conn:
                        try:
                            self._tcp_conn.close()
                        except Exception:
                            pass
                    self._tcp_conn = conn
                    self._tcp_peer = addr
                    self._tcp_buffer = b""
                    logger.info("Accepted SIP TCP connection from %s:%d", addr[0], addr[1])

                if self._tcp_conn and self._tcp_conn in ready:
                    chunk = self._tcp_conn.recv(65536)
                    if not chunk:
                        try:
                            self._tcp_conn.close()
                        except Exception:
                            pass
                        self._tcp_conn = None
                        self._tcp_peer = None
                        self._tcp_buffer = b""
                    else:
                        self._tcp_buffer += chunk
                        message, self._tcp_buffer = self._extract_complete_sip_message(self._tcp_buffer)
                        if message is not None:
                            decoded = message.decode('utf-8', errors='replace')
                            first_line = decoded.split('\r\n')[0]
                            self._last_rx_transport = "tcp"
                            if self._tcp_peer:
                                logger.info(
                                    "<< %s (from %s:%d via TCP)",
                                    first_line,
                                    self._tcp_peer[0],
                                    self._tcp_peer[1],
                                )
                            else:
                                logger.info("<< %s (via TCP)", first_line)
                            return decoded

                if self._sock in ready:
                    data, addr = self._sock.recvfrom(65536)
                    message = data.decode('utf-8', errors='replace')
                    first_line = message.split('\r\n')[0]
                    self._last_rx_transport = "udp"
                    logger.info("<< %s (from %s:%d via UDP)", first_line, addr[0], addr[1])
                    return message

        except socket.timeout:
            return None
        except Exception as e:
            self._set_last_error(f"SIP receive error: {e}")
            logger.error("SIP receive error: %s", e)
            return None

    @staticmethod
    def _extract_complete_sip_message(buffer: bytes) -> Tuple[Optional[bytes], bytes]:
        """Split one complete SIP-over-TCP message from a byte buffer."""
        header_end = buffer.find(b"\r\n\r\n")
        if header_end < 0:
            return None, buffer

        header_block = buffer[: header_end + 4]
        content_length = 0
        match = re.search(br"(?im)^Content-Length\s*:\s*(\d+)\s*$", header_block)
        if match:
            content_length = int(match.group(1))

        message_len = header_end + 4 + content_length
        if len(buffer) < message_len:
            return None, buffer

        return buffer[:message_len], buffer[message_len:]

    # ================================================================
    # Identifier Generation
    # ================================================================
    @property
    def _sip_uri(self) -> str:
        """SIP URI for this UE.

        Uses IMSI as the identity because PyHSS's Diameter UAR handler
        (Answer_16777216_300) extracts the User-Name AVP and does
        Get_IMS_Subscriber(imsi=...) lookup. If we use MSISDN, PyHSS
        tries to match 'sip:MSISDN' as an IMSI and fails.
        """
        return f"sip:{self._imsi}@{self._ims_domain}"

    @property
    def _contact_uri(self) -> str:
        """Contact URI advertised for dialog-forming requests and responses."""
        return f"sip:{self._imsi}@{self._local_ip}:{self._local_port};transport=udp"

    @property
    def _contact_header_invite(self) -> str:
        """Contact header for INVITE with IMS feature tags.

        Includes +sip.instance (IMEI) and +g.3gpp.icsi-ref (MMTEL service)
        which are required for P-CSCF to trigger Rx AAR for dedicated bearer
        establishment (QCI-1 for VoLTE, QCI-2 for ViLTE).

        Without these, P-CSCF skips Rx media authorization ("Non-IMS SIP client").
        """
        contact = f"<{self._contact_uri}>"
        # Add +sip.instance with IMEI URN (TS 24.229 5.1.1.1.1)
        if self._imei_sv and len(self._imei_sv) >= 14:
            tac = self._imei_sv[:8]
            snr = self._imei_sv[8:14]
            svn = self._imei_sv[14:16] if len(self._imei_sv) >= 16 else "0"
            imei_urn = f"urn:gsma:imei:{tac}-{snr}-{svn}"
            contact += f';+sip.instance="<{imei_urn}>"'
        # Add +g.3gpp.icsi-ref for MMTEL service (TS 24.229 7.2A.8.2)
        contact += ';+g.3gpp.icsi-ref="urn%3Aurn-7%3A3gpp-service.ims.icsi.mmtel"'
        return contact

    @staticmethod
    def _generate_call_id() -> str:
        """Generate a unique Call-ID."""
        return f"{uuid.uuid4().hex[:16]}@ue-sim"

    @staticmethod
    def _generate_tag() -> str:
        """Generate a random SIP tag."""
        return ''.join(random.choices(string.ascii_lowercase + string.digits, k=10))

    def _generate_branch(self) -> str:
        """Generate a unique Via branch parameter."""
        self._branch_counter += 1
        return f"z9hG4bK-uesim-{self._branch_counter}-{random.randint(1000, 9999)}"

    @staticmethod
    def _generate_cnonce() -> str:
        """Generate a client nonce for digest authentication."""
        return hashlib.md5(str(time.time()).encode()).hexdigest()[:16]

    @property
    def registered(self) -> bool:
        return self._registered

    @property
    def in_call(self) -> bool:
        return self._in_call

    @property
    def last_error(self) -> str:
        return self._last_error

    def _set_last_error(self, message: str):
        self._last_error = message

    def _clear_last_error(self):
        self._last_error = ""


if __name__ == "__main__":
    logging.basicConfig(level=logging.DEBUG)

    # Test SDP generation
    client = SIPClient(
        local_ip="10.0.0.1",
        local_port=15060,
        imsi="001019876540700",
        msisdn="19876540700",
    )

    # Test VoLTE SDP
    sdp = client._build_sdp(video=False)
    print("VoLTE SDP:")
    print(sdp)
    print("---")

    # Test ViLTE SDP
    sdp = client._build_sdp(video=True)
    print("ViLTE SDP:")
    print(sdp)
    print("---")

    # Test REGISTER message
    client._call_id = "test-call-id@ue-sim"
    client._local_tag = "abc123"
    client._cseq = 1
    reg = client._build_register()
    print("REGISTER:")
    print(reg)
