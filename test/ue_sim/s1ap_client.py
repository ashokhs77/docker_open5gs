"""
S1AP Client for UE/eNB Simulator

SCTP-based S1AP client that connects to the MME and handles the S1AP
procedures needed for UE attach, bearer setup, and detach.

Uses pycrate for ASN.1 PER encoding/decoding when available, with a
fallback to hand-crafted byte templates for environments where pycrate
is not installed.

Supported procedures:
    - S1SetupRequest / S1SetupResponse
    - InitialUEMessage (Attach Request)
    - DownlinkNASTransport / UplinkNASTransport
    - InitialContextSetupRequest / InitialContextSetupResponse
    - UEContextReleaseRequest / UEContextReleaseCommand / UEContextReleaseComplete

Reference: 3GPP TS 36.413 (S1AP)
"""

import logging
import socket
import struct
import threading
import time
from enum import IntEnum
from typing import Optional, Tuple, Dict, Any, Callable

from .config import Config

logger = logging.getLogger(__name__)


# ================================================================
# S1AP Constants
# ================================================================

class S1APProcedureCode(IntEnum):
    """S1AP Elementary Procedure codes (TS 36.413)."""
    S1_SETUP = 17
    INITIAL_UE_MESSAGE = 12
    DOWNLINK_NAS_TRANSPORT = 11
    UPLINK_NAS_TRANSPORT = 13
    INITIAL_CONTEXT_SETUP = 9
    UE_CONTEXT_RELEASE_REQUEST = 18
    UE_CONTEXT_RELEASE_COMMAND = 23
    UE_CONTEXT_RELEASE_COMPLETE = 23  # same code, different criticality
    PAGING = 10
    E_RAB_SETUP = 5
    E_RAB_RELEASE = 7
    RESET = 14
    ERROR_INDICATION = 15


def s1ap_procedure_name(proc_code: int) -> str:
    """Return a stable human-readable S1AP procedure name."""
    try:
        return S1APProcedureCode(proc_code).name
    except Exception:
        return f"UNKNOWN_{proc_code}"


class S1APProtocolIEId(IntEnum):
    """S1AP Protocol IE identifiers used in our messages."""
    MME_UE_S1AP_ID = 0
    ENB_UE_S1AP_ID = 8
    NAS_PDU = 26
    TAI = 67
    EUTRAN_CGI = 100
    RRC_ESTABLISHMENT_CAUSE = 134
    GLOBAL_ENB_ID = 59
    ENB_NAME = 60
    SUPPORTED_TAS = 64
    DEFAULT_PAGING_DRX = 137
    CAUSE = 2
    S1_SETUP_RESPONSE = 17
    UE_AGGREGATE_MAX_BITRATE = 66
    E_RAB_TO_BE_SETUP_LIST = 24
    UE_SECURITY_CAPABILITIES = 107
    SECURITY_KEY = 73
    E_RAB_SETUP_LIST = 28


# S1AP message types (APER encoding)
S1AP_INITIATING_MESSAGE = 0x00
S1AP_SUCCESSFUL_OUTCOME = 0x20
S1AP_UNSUCCESSFUL_OUTCOME = 0x40

# SCTP PPID for S1AP
S1AP_PPID = 18


# ================================================================
# S1AP Encoder (using pycrate if available, else templates)
# ================================================================

class S1APEncoder:
    """
    S1AP ASN.1 PER encoder.

    Attempts to use pycrate_asn1rt for proper ASN.1 encoding. Falls back
    to hand-crafted byte templates when pycrate is not available.
    """

    _use_pycrate = False
    _s1ap_pdu = None

    @classmethod
    def _init_pycrate(cls):
        """Try to load pycrate S1AP definitions."""
        if cls._s1ap_pdu is not None:
            return cls._use_pycrate

        try:
            from pycrate_asn1dir import S1AP
            cls._s1ap_pdu = S1AP.S1AP_PDU_Descriptions.S1AP_PDU
            cls._s1ap_module = S1AP
            cls._use_pycrate = True
            logger.info("Using pycrate for S1AP encoding")
        except ImportError:
            cls._use_pycrate = False
            logger.info("pycrate not available, using template-based S1AP encoding")

        return cls._use_pycrate

    @classmethod
    def _get_pdu(cls):
        """Get the S1AP PDU object for encoding.

        In pycrate, ASN.1 types from compiled modules are singleton objects.
        We don't clone them — we just set_val() on them each time before encoding.
        The set_val() call in each encode_* method overwrites any previous state.
        """
        return cls._s1ap_pdu

    @classmethod
    def encode_s1_setup_request(
        cls, plmn: bytes, enb_id: int, enb_name: str, tac: int
    ) -> bytes:
        """
        Encode S1SetupRequest.

        Args:
            plmn: 3-byte PLMN identity
            enb_id: 20-bit macro eNB ID
            enb_name: eNB name string
            tac: Tracking Area Code

        Returns:
            Complete S1AP PDU bytes
        """
        cls._init_pycrate()

        if cls._use_pycrate:
            return cls._encode_s1_setup_pycrate(plmn, enb_id, enb_name, tac)

        return cls._encode_s1_setup_template(plmn, enb_id, enb_name, tac)

    @classmethod
    def _encode_s1_setup_pycrate(
        cls, plmn: bytes, enb_id: int, enb_name: str, tac: int
    ) -> bytes:
        """Encode S1SetupRequest using pycrate's S1AP module directly."""
        S1AP = cls._s1ap_module

        # Use the specific procedure class directly (not the top-level PDU CHOICE)
        # This avoids the singleton/stale state issues with the top-level PDU
        IEs = S1AP.S1AP_PDU_Contents.S1SetupRequestIEs
        pdu = cls._get_pdu()

        # Build the value using pycrate's expected structure
        val = ('initiatingMessage', {
            'procedureCode': 17,  # S1Setup
            'criticality': 'reject',
            'value': ('S1SetupRequest', {
                'protocolIEs': [
                    {
                        'id': 59,  # Global-ENB-ID
                        'criticality': 'reject',
                        'value': ('Global-ENB-ID', {
                            'pLMNidentity': plmn,
                            'eNB-ID': ('macroENB-ID', (enb_id, 20)),
                        }),
                    },
                    {
                        'id': 60,  # ENBname
                        'criticality': 'ignore',
                        'value': ('ENBname', enb_name),
                    },
                    {
                        'id': 64,  # SupportedTAs
                        'criticality': 'reject',
                        'value': ('SupportedTAs', [{
                            'tAC': tac.to_bytes(2, 'big'),
                            'broadcastPLMNs': [plmn],
                        }]),
                    },
                    {
                        'id': 137,  # PagingDRX
                        'criticality': 'ignore',
                        'value': ('PagingDRX', 'v128'),
                    },
                ],
            }),
        })

        try:
            pdu.set_val(val)
            return pdu.to_aper()
        except Exception as e:
            logger.error(f"pycrate S1SetupRequest encoding failed: {e}")
            logger.info("Falling back to template-based encoding")
            return cls._encode_s1_setup_template(plmn, enb_id, enb_name, tac)

    @classmethod
    def _encode_s1_setup_template(
        cls, plmn: bytes, enb_id: int, enb_name: str, tac: int
    ) -> bytes:
        """
        Encode S1SetupRequest using hand-crafted APER byte template.

        The S1AP PDU structure (APER):
            - PDU choice index (initiatingMessage = 0)
            - Procedure code
            - Criticality
            - Value (OPEN TYPE containing S1SetupRequest)
                - S1SetupRequest sequence
                    - protocolIEs list
        """
        # Build the protocol IEs

        # IE 1: Global-ENB-ID (ID=59, criticality=reject)
        global_enb_id_value = cls._encode_global_enb_id(plmn, enb_id)

        # IE 2: eNBname (ID=60, criticality=ignore)
        enb_name_value = cls._encode_printable_string(enb_name)

        # IE 3: SupportedTAs (ID=64, criticality=reject)
        supported_tas_value = cls._encode_supported_tas(plmn, tac)

        # IE 4: DefaultPagingDRX (ID=137, criticality=ignore)
        paging_drx_value = cls._encode_paging_drx()

        # Assemble IEs list
        ies = bytearray()
        ies.extend(cls._wrap_protocol_ie(59, 0, global_enb_id_value))   # reject
        ies.extend(cls._wrap_protocol_ie(60, 1, enb_name_value))        # ignore
        ies.extend(cls._wrap_protocol_ie(64, 0, supported_tas_value))   # reject
        ies.extend(cls._wrap_protocol_ie(137, 1, paging_drx_value))     # ignore

        # S1SetupRequest value = number of IEs (constrained, 0-based for 4 IEs)
        # + the IEs themselves
        s1setup_value = bytearray()
        # Number of protocol IEs - 1 (0-indexed, APER semi-constrained)
        s1setup_value.append(0x00)
        s1setup_value.append(0x04)  # 4 IEs
        s1setup_value.extend(ies)

        # Wrap in InitiatingMessage
        return cls._wrap_initiating_message(
            S1APProcedureCode.S1_SETUP, 0, bytes(s1setup_value)
        )

    @classmethod
    def encode_initial_ue_message(
        cls,
        enb_ue_id: int,
        nas_pdu: bytes,
        plmn: bytes,
        tac: int,
        cell_id: int,
        rrc_cause: int = 3,  # mo-Signalling
    ) -> bytes:
        """
        Encode InitialUEMessage.

        Args:
            enb_ue_id: eNB-UE-S1AP-ID
            nas_pdu: NAS PDU (Attach Request)
            plmn: 3-byte PLMN
            tac: Tracking Area Code
            cell_id: 28-bit cell identity
            rrc_cause: RRC Establishment Cause

        Returns:
            Complete S1AP PDU bytes
        """
        cls._init_pycrate()

        if cls._use_pycrate:
            return cls._encode_initial_ue_pycrate(
                enb_ue_id, nas_pdu, plmn, tac, cell_id, rrc_cause
            )

        return cls._encode_initial_ue_template(
            enb_ue_id, nas_pdu, plmn, tac, cell_id, rrc_cause
        )

    @classmethod
    def _encode_initial_ue_pycrate(
        cls, enb_ue_id, nas_pdu, plmn, tac, cell_id, rrc_cause
    ) -> bytes:
        """Encode InitialUEMessage using pycrate."""
        cause_map = {0: 'emergency', 1: 'highPriorityAccess', 2: 'mt-Access',
                     3: 'mo-Signalling', 4: 'mo-Data'}

        pdu = cls._get_pdu()
        # IMPORTANT: use int() for all enum values — pycrate rejects IntEnum objects
        val = ('initiatingMessage', {
            'procedureCode': 12,  # InitialUEMessage
            'criticality': 'ignore',
            'value': ('InitialUEMessage', {
                'protocolIEs': [
                    {
                        'id': 8,   # ENB-UE-S1AP-ID
                        'criticality': 'reject',
                        'value': ('ENB-UE-S1AP-ID', int(enb_ue_id)),
                    },
                    {
                        'id': 26,  # NAS-PDU
                        'criticality': 'reject',
                        'value': ('NAS-PDU', bytes(nas_pdu)),
                    },
                    {
                        'id': 67,  # TAI
                        'criticality': 'reject',
                        'value': ('TAI', {
                            'pLMNidentity': plmn,
                            'tAC': tac.to_bytes(2, 'big'),
                        }),
                    },
                    {
                        'id': 100,  # EUTRAN-CGI
                        'criticality': 'ignore',
                        'value': ('EUTRAN-CGI', {
                            'pLMNidentity': plmn,
                            'cell-ID': (cell_id << 4, 28),
                        }),
                    },
                    {
                        'id': 134,  # RRC-Establishment-Cause
                        'criticality': 'ignore',
                        'value': ('RRC-Establishment-Cause',
                                  cause_map.get(rrc_cause, 'mo-Signalling')),
                    },
                ],
            }),
        })

        try:
            pdu.set_val(val)
            return pdu.to_aper()
        except Exception as e:
            logger.error(f"pycrate InitialUEMessage encoding failed: {e}")
            logger.info("Falling back to template-based encoding")
            return cls._encode_initial_ue_template(
                enb_ue_id, nas_pdu, plmn, tac, cell_id, rrc_cause)

    @classmethod
    def _encode_initial_ue_template(
        cls, enb_ue_id, nas_pdu, plmn, tac, cell_id, rrc_cause
    ) -> bytes:
        """Encode InitialUEMessage using byte templates."""
        ies = bytearray()

        # IE: eNB-UE-S1AP-ID (ID=8)
        enb_id_val = cls._encode_integer_constrained(enb_ue_id, 0, 16777215)
        ies.extend(cls._wrap_protocol_ie(8, 0, enb_id_val))

        # IE: NAS-PDU (ID=26)
        nas_val = cls._encode_octet_string_unbounded(nas_pdu)
        ies.extend(cls._wrap_protocol_ie(26, 0, nas_val))

        # IE: TAI (ID=67)
        tai_val = plmn + tac.to_bytes(2, 'big')
        ies.extend(cls._wrap_protocol_ie(67, 0, tai_val))

        # IE: EUTRAN-CGI (ID=100)
        # cell-ID is a BIT STRING of 28 bits
        cell_bits = (cell_id << 4).to_bytes(4, 'big')  # 28 bits + 4 padding
        cgi_val = plmn + cell_bits
        ies.extend(cls._wrap_protocol_ie(100, 1, cgi_val))

        # IE: RRC-Establishment-Cause (ID=134)
        cause_val = bytes([rrc_cause << 5])  # APER enumerated, 4 values
        ies.extend(cls._wrap_protocol_ie(134, 1, cause_val))

        # InitialUEMessage
        msg_value = bytearray()
        msg_value.append(0x00)
        msg_value.append(0x05)  # 5 IEs
        msg_value.extend(ies)

        return cls._wrap_initiating_message(
            S1APProcedureCode.INITIAL_UE_MESSAGE, 1, bytes(msg_value)
        )

    @classmethod
    def encode_uplink_nas_transport(
        cls, mme_ue_id: int, enb_ue_id: int, nas_pdu: bytes,
        plmn: bytes, tac: int, cell_id: int
    ) -> bytes:
        """
        Encode UplinkNASTransport.

        Args:
            mme_ue_id: MME-UE-S1AP-ID (assigned by MME)
            enb_ue_id: eNB-UE-S1AP-ID
            nas_pdu: NAS PDU
            plmn: 3-byte PLMN
            tac: TAC
            cell_id: Cell ID

        Returns:
            Complete S1AP PDU bytes
        """
        cls._init_pycrate()

        if cls._use_pycrate:
            return cls._encode_ul_nas_pycrate(
                mme_ue_id, enb_ue_id, nas_pdu, plmn, tac, cell_id
            )

        return cls._encode_ul_nas_template(
            mme_ue_id, enb_ue_id, nas_pdu, plmn, tac, cell_id
        )

    @classmethod
    def _encode_ul_nas_pycrate(cls, mme_ue_id, enb_ue_id, nas_pdu, plmn, tac, cell_id):
        """Encode UplinkNASTransport using pycrate."""
        pdu = cls._get_pdu()
        val = ('initiatingMessage', {
            'procedureCode': 13,  # UplinkNASTransport
            'criticality': 'ignore',
            'value': ('UplinkNASTransport', {
                'protocolIEs': [
                    {
                        'id': 0,  # MME-UE-S1AP-ID
                        'criticality': 'reject',
                        'value': ('MME-UE-S1AP-ID', int(mme_ue_id)),
                    },
                    {
                        'id': 8,  # eNB-UE-S1AP-ID
                        'criticality': 'reject',
                        'value': ('ENB-UE-S1AP-ID', int(enb_ue_id)),
                    },
                    {
                        'id': 26,  # NAS-PDU
                        'criticality': 'reject',
                        'value': ('NAS-PDU', bytes(nas_pdu)),
                    },
                    {
                        'id': 100,  # EUTRAN-CGI
                        'criticality': 'ignore',
                        'value': ('EUTRAN-CGI', {
                            'pLMNidentity': plmn,
                            'cell-ID': (int(cell_id) << 4, 28),
                        }),
                    },
                    {
                        'id': 67,  # TAI
                        'criticality': 'ignore',
                        'value': ('TAI', {
                            'pLMNidentity': plmn,
                            'tAC': int(tac).to_bytes(2, 'big'),
                        }),
                    },
                ],
            }),
        })

        try:
            pdu.set_val(val)
            return pdu.to_aper()
        except Exception as e:
            logger.error(f"pycrate UplinkNASTransport encoding failed: {e}")
            return cls._encode_ul_nas_template(
                mme_ue_id, enb_ue_id, nas_pdu, plmn, tac, cell_id)

    @classmethod
    def _encode_ul_nas_template(cls, mme_ue_id, enb_ue_id, nas_pdu, plmn, tac, cell_id):
        """Encode UplinkNASTransport using byte templates."""
        ies = bytearray()

        # MME-UE-S1AP-ID (ID=0)
        mme_id_val = cls._encode_integer_constrained(mme_ue_id, 0, 0xFFFFFFFF)
        ies.extend(cls._wrap_protocol_ie(0, 0, mme_id_val))

        # eNB-UE-S1AP-ID (ID=8)
        enb_id_val = cls._encode_integer_constrained(enb_ue_id, 0, 16777215)
        ies.extend(cls._wrap_protocol_ie(8, 0, enb_id_val))

        # NAS-PDU (ID=26)
        nas_val = cls._encode_octet_string_unbounded(nas_pdu)
        ies.extend(cls._wrap_protocol_ie(26, 0, nas_val))

        # EUTRAN-CGI (ID=100)
        cell_bits = (cell_id << 4).to_bytes(4, 'big')
        cgi_val = plmn + cell_bits
        ies.extend(cls._wrap_protocol_ie(100, 1, cgi_val))

        # TAI (ID=67)
        tai_val = plmn + tac.to_bytes(2, 'big')
        ies.extend(cls._wrap_protocol_ie(67, 1, tai_val))

        msg_value = bytearray()
        msg_value.append(0x00)
        msg_value.append(0x05)  # 5 IEs
        msg_value.extend(ies)

        return cls._wrap_initiating_message(
            S1APProcedureCode.UPLINK_NAS_TRANSPORT, 1, bytes(msg_value)
        )

    @classmethod
    def encode_initial_context_setup_response(
        cls, mme_ue_id: int, enb_ue_id: int,
        erab_id: int = 5, gtp_teid: int = 1,
        transport_addr: str = "127.0.0.1"
    ) -> bytes:
        """
        Encode InitialContextSetupResponse.

        Args:
            mme_ue_id: MME-UE-S1AP-ID
            enb_ue_id: eNB-UE-S1AP-ID
            erab_id: E-RAB ID from the request
            gtp_teid: GTP TEID for uplink
            transport_addr: eNB GTP-U transport address

        Returns:
            Complete S1AP PDU bytes
        """
        cls._init_pycrate()

        if cls._use_pycrate:
            return cls._encode_ctx_setup_resp_pycrate(
                mme_ue_id, enb_ue_id, erab_id, gtp_teid, transport_addr
            )

        return cls._encode_ctx_setup_resp_template(
            mme_ue_id, enb_ue_id, erab_id, gtp_teid, transport_addr
        )

    @classmethod
    def _encode_ctx_setup_resp_pycrate(
        cls, mme_ue_id, enb_ue_id, erab_id, gtp_teid, transport_addr
    ):
        """Encode InitialContextSetupResponse using pycrate."""
        ip_bytes = socket.inet_aton(transport_addr)

        pdu = cls._get_pdu()
        val = ('successfulOutcome', {
            'procedureCode': 9,  # InitialContextSetup
            'criticality': 'reject',
            'value': ('InitialContextSetupResponse', {
                'protocolIEs': [
                    {
                        'id': 0,  # MME-UE-S1AP-ID
                        'criticality': 'ignore',
                        'value': ('MME-UE-S1AP-ID', int(mme_ue_id)),
                    },
                    {
                        'id': 8,  # eNB-UE-S1AP-ID
                        'criticality': 'ignore',
                        'value': ('ENB-UE-S1AP-ID', int(enb_ue_id)),
                    },
                    {
                        'id': 51,  # E-RABSetupListCtxtSURes
                        'criticality': 'ignore',
                        'value': ('E-RABSetupListCtxtSURes', [{
                            'id': 50,
                            'criticality': 'ignore',
                            'value': ('E-RABSetupItemCtxtSURes', {
                                'e-RAB-ID': int(erab_id),
                                'transportLayerAddress': (
                                    int.from_bytes(ip_bytes, 'big'), 32
                                ),
                                'gTP-TEID': int(gtp_teid).to_bytes(4, 'big'),
                            }),
                        }]),
                    },
                ],
            }),
        })

        try:
            pdu.set_val(val)
            return pdu.to_aper()
        except Exception as e:
            logger.error(f"pycrate InitialContextSetupResponse encoding failed: {e}")
            return cls._encode_ctx_setup_resp_template(
                mme_ue_id, enb_ue_id, erab_id, gtp_teid, transport_addr)

    @classmethod
    def _encode_ctx_setup_resp_template(
        cls, mme_ue_id, enb_ue_id, erab_id, gtp_teid, transport_addr
    ):
        """Encode InitialContextSetupResponse using byte templates."""
        ip_bytes = socket.inet_aton(transport_addr)

        ies = bytearray()

        # MME-UE-S1AP-ID (ID=0)
        mme_id_val = cls._encode_integer_constrained(mme_ue_id, 0, 0xFFFFFFFF)
        ies.extend(cls._wrap_protocol_ie(0, 1, mme_id_val))

        # eNB-UE-S1AP-ID (ID=8)
        enb_id_val = cls._encode_integer_constrained(enb_ue_id, 0, 16777215)
        ies.extend(cls._wrap_protocol_ie(8, 1, enb_id_val))

        # E-RABSetupListCtxtSURes (ID=51) - simplified
        erab_item = bytearray()
        erab_item.append(0x00)  # No optional fields
        erab_item.append(erab_id & 0xFF)  # E-RAB-ID
        # Transport layer address (32 bits)
        erab_item.append(0x00)  # length determinant for BIT STRING
        erab_item.append(0x20)  # 32 bits
        erab_item.extend(ip_bytes)
        # GTP-TEID (4 bytes OCTET STRING)
        erab_item.extend(gtp_teid.to_bytes(4, 'big'))

        erab_list = bytearray()
        erab_list.append(0x00)  # 1 item (0-indexed)
        # Item wrapper (IE id=50, criticality=ignore)
        erab_list.extend(b'\x00\x32')  # id=50
        erab_list.append(0x40)  # criticality=ignore
        erab_list.append(len(erab_item))
        erab_list.extend(erab_item)

        ies.extend(cls._wrap_protocol_ie(51, 1, bytes(erab_list)))

        msg_value = bytearray()
        msg_value.append(0x00)
        msg_value.append(0x03)  # 3 IEs
        msg_value.extend(ies)

        return cls._wrap_successful_outcome(
            S1APProcedureCode.INITIAL_CONTEXT_SETUP, 0, bytes(msg_value)
        )

    @classmethod
    def encode_erab_setup_response(
        cls, mme_ue_id: int, enb_ue_id: int,
        erab_id: int = 5, gtp_teid: int = 1,
        transport_addr: str = "127.0.0.1"
    ) -> bytes:
        """Encode E-RABSetupResponse for dedicated bearer setup."""
        cls._init_pycrate()

        if cls._use_pycrate:
            return cls._encode_erab_setup_resp_pycrate(
                mme_ue_id, enb_ue_id, erab_id, gtp_teid, transport_addr
            )

        return cls._encode_erab_setup_resp_template(
            mme_ue_id, enb_ue_id, erab_id, gtp_teid, transport_addr
        )

    @classmethod
    def _encode_erab_setup_resp_pycrate(
        cls, mme_ue_id, enb_ue_id, erab_id, gtp_teid, transport_addr
    ):
        """Encode E-RABSetupResponse using pycrate."""
        ip_bytes = socket.inet_aton(transport_addr)

        pdu = cls._get_pdu()
        val = ('successfulOutcome', {
            'procedureCode': 5,  # E-RABSetup
            'criticality': 'reject',
            'value': ('E-RABSetupResponse', {
                'protocolIEs': [
                    {
                        'id': 0,
                        'criticality': 'ignore',
                        'value': ('MME-UE-S1AP-ID', int(mme_ue_id)),
                    },
                    {
                        'id': 8,
                        'criticality': 'ignore',
                        'value': ('ENB-UE-S1AP-ID', int(enb_ue_id)),
                    },
                    {
                        'id': 28,  # E-RABSetupListBearerSURes
                        'criticality': 'ignore',
                        'value': ('E-RABSetupListBearerSURes', [{
                            'id': 39,
                            'criticality': 'ignore',
                            'value': ('E-RABSetupItemBearerSURes', {
                                'e-RAB-ID': int(erab_id),
                                'transportLayerAddress': (
                                    int.from_bytes(ip_bytes, 'big'), 32
                                ),
                                'gTP-TEID': int(gtp_teid).to_bytes(4, 'big'),
                            }),
                        }]),
                    },
                ],
            }),
        })

        try:
            pdu.set_val(val)
            return pdu.to_aper()
        except Exception as e:
            logger.error("pycrate E-RABSetupResponse encoding failed: %s", e)
            return cls._encode_erab_setup_resp_template(
                mme_ue_id, enb_ue_id, erab_id, gtp_teid, transport_addr
            )

    @classmethod
    def _encode_erab_setup_resp_template(
        cls, mme_ue_id, enb_ue_id, erab_id, gtp_teid, transport_addr
    ):
        """Encode E-RABSetupResponse using byte templates."""
        ip_bytes = socket.inet_aton(transport_addr)

        ies = bytearray()

        mme_id_val = cls._encode_integer_constrained(mme_ue_id, 0, 0xFFFFFFFF)
        ies.extend(cls._wrap_protocol_ie(0, 1, mme_id_val))

        enb_id_val = cls._encode_integer_constrained(enb_ue_id, 0, 16777215)
        ies.extend(cls._wrap_protocol_ie(8, 1, enb_id_val))

        erab_item = bytearray()
        erab_item.append(0x00)  # No optional fields
        erab_item.append(erab_id & 0xFF)
        erab_item.append(0x00)  # length determinant for BIT STRING
        erab_item.append(0x20)  # 32 bits
        erab_item.extend(ip_bytes)
        erab_item.extend(gtp_teid.to_bytes(4, 'big'))

        erab_list = bytearray()
        erab_list.append(0x00)  # 1 item (0-indexed)
        erab_list.extend(b'\x00\x27')  # id=39
        erab_list.append(0x40)  # criticality=ignore
        erab_list.append(len(erab_item))
        erab_list.extend(erab_item)

        ies.extend(cls._wrap_protocol_ie(28, 1, bytes(erab_list)))

        msg_value = bytearray()
        msg_value.append(0x00)
        msg_value.append(0x03)
        msg_value.extend(ies)

        return cls._wrap_successful_outcome(
            S1APProcedureCode.E_RAB_SETUP, 0, bytes(msg_value)
        )

    @classmethod
    def encode_ue_context_release_request(
        cls, mme_ue_id: int, enb_ue_id: int, cause_type: str = "radioNetwork",
        cause_value: int = 20  # user-inactivity — triggers ECM-IDLE (Release Access Bearers),
        # not Delete Session; NAS/normal-release would cause MME to tear down the PDN session
    ) -> bytes:
        """Encode UEContextReleaseRequest.

        Tries pycrate first — it produces spec-correct APER for all other procedures
        and there is no fundamental reason proc 18 should behave differently.
        Falls back to the hand-rolled template only if pycrate returns empty bytes
        or raises an exception.
        """
        cls._init_pycrate()
        if cls._use_pycrate:
            cause_map = {
                "nas": ("nas", "normal-release"),
                "radio": ("radioNetwork", "unspecified"),
                "radioNetwork": ("radioNetwork", "user-inactivity"),
            }
            cause_key, cause_str = cause_map.get(cause_type, ("radioNetwork", "user-inactivity"))
            try:
                pdu = cls._get_pdu()
                val = ('initiatingMessage', {
                    'procedureCode': 18,  # UEContextReleaseRequest
                    'criticality': 'ignore',
                    'value': ('UEContextReleaseRequest', {
                        'protocolIEs': [
                            {
                                'id': 0,
                                'criticality': 'reject',
                                'value': ('MME-UE-S1AP-ID', int(mme_ue_id)),
                            },
                            {
                                'id': 8,
                                'criticality': 'reject',
                                'value': ('ENB-UE-S1AP-ID', int(enb_ue_id)),
                            },
                            {
                                'id': 2,
                                'criticality': 'ignore',
                                'value': ('Cause', (cause_key, cause_str)),
                            },
                        ],
                    }),
                })
                pdu.set_val(val)
                result = pdu.to_aper()
                if result and len(result) >= 5:
                    logger.debug(
                        "UEContextReleaseRequest (pycrate): %d bytes: %s",
                        len(result), result.hex(),
                    )
                    return result
                logger.warning(
                    "UEContextReleaseRequest: pycrate returned %d bytes — falling back to template",
                    len(result) if result else 0,
                )
            except Exception as exc:
                logger.warning(
                    "UEContextReleaseRequest: pycrate encoding failed (%s) — falling back to template",
                    exc,
                )

        return cls._encode_ctx_release_req_template(
            mme_ue_id, enb_ue_id, cause_type, cause_value
        )

    @classmethod
    def _encode_ctx_release_req_pycrate(cls, mme_ue_id, enb_ue_id, cause_type, cause_value):
        """Encode UEContextReleaseRequest using pycrate.

        NOTE: retained for reference only.  The live encoding path is inlined
        directly in encode_ue_context_release_request() for clarity.
        """
        cause_map = {
            "nas": ("nas", "normal-release"),
            "radio": ("radioNetwork", "unspecified"),
            "radioNetwork": ("radioNetwork", "user-inactivity"),
        }
        cause_key, cause_str = cause_map.get(cause_type, ("radioNetwork", "user-inactivity"))

        pdu = cls._get_pdu()
        val = ('initiatingMessage', {
            'procedureCode': 18,  # UEContextReleaseRequest
            'criticality': 'ignore',
            'value': ('UEContextReleaseRequest', {
                'protocolIEs': [
                    {
                        'id': 0,
                        'criticality': 'reject',
                        'value': ('MME-UE-S1AP-ID', int(mme_ue_id)),
                    },
                    {
                        'id': 8,
                        'criticality': 'reject',
                        'value': ('ENB-UE-S1AP-ID', int(enb_ue_id)),
                    },
                    {
                        'id': 2,
                        'criticality': 'ignore',
                        'value': ('Cause', (cause_key, cause_str)),
                    },
                ],
            }),
        })

        try:
            pdu.set_val(val)
            result = pdu.to_aper()
            return result if result else b''
        except Exception as e:
            logger.error("pycrate UEContextReleaseRequest encoding failed: %s", e)
            return b''

    @classmethod
    def _encode_ctx_release_req_template(cls, mme_ue_id, enb_ue_id, cause_type, cause_value):
        """Encode UEContextReleaseRequest using APER byte templates.

        Integer encoding (range > 65535) uses X.691 §12.2.6 semi-constrained form:
          1-byte length determinant = (n_octets - 1), followed by n_octets of value.
          e.g. MME-UE-S1AP-ID=9  → b'\\x00\\x09'  (det=0 → 1 octet, value=9)
               ENB-UE-S1AP-ID=1  → b'\\x00\\x01'  (det=0 → 1 octet, value=1)
        """
        ies = bytearray()

        # MME-UE-S1AP-ID (0..4294967295): APER unconstrained → len prefix + min bytes
        mme_id_val = cls._encode_integer_constrained(mme_ue_id, 0, 0xFFFFFFFF)
        ies.extend(cls._wrap_protocol_ie(0, 0, mme_id_val))

        # ENB-UE-S1AP-ID (0..16777215): APER unconstrained → len prefix + min bytes
        enb_id_val = cls._encode_integer_constrained(enb_ue_id, 0, 16777215)
        ies.extend(cls._wrap_protocol_ie(8, 0, enb_id_val))

        # APER encoding for Cause CHOICE (5 root alternatives + extension marker):
        #   Byte 0: [ext=0][CHOICE_idx_3bits][pad_4bits]   (APER §22.5: index unaligned, value byte-aligned)
        #     radioNetwork = index 0 → [0][000][0000] = 0x00
        #     transport    = index 1 → [0][001][0000] = 0x10
        #     nas          = index 2 → [0][010][0000] = 0x20
        #     protocol     = index 3 → [0][011][0000] = 0x30
        #     misc         = index 4 → [0][100][0000] = 0x40
        #
        # APER encoding for CauseRadioNetwork ENUMERATED (36 root values, TS 36.413 §9.2.1.3):
        #   Root values 0..35 (unspecified … x2-handover-triggered) + extension marker.
        #   Range = 36  →  ceil(log2(36)) = 6 bits needed.
        #   Byte 1: [ext=0][enum_idx_6bits][pad_1bit]
        #     user-inactivity = root index 20 = 010100b
        #     → [0][010100][0] = 0b00101000 = 0x28
        #
        #   Index mapping (0-based):
        #     0  unspecified
        #     1  tx2relocoverall-expiry
        #     …
        #    19  reduce-load-in-serving-cell
        #    20  user-inactivity            ← used here
        #    21  radio-connection-with-ue-lost
        #    …
        #    35  x2-handover-triggered
        #
        # APER encoding for CauseNAS ENUMERATED (4 root values + extension):
        #   Byte 1: [ext=0][enum_idx_2bits][pad_5bits]
        #     normal-release = root index 0 → [0][00][00000] = 0x00
        if cause_type == "nas":
            cause_val = bytes([0x20, 0x00])  # nas/normal-release
        else:
            cause_val = bytes([0x00, 0x28])  # radioNetwork/user-inactivity (root index 20 → 0x28)
        ies.extend(cls._wrap_protocol_ie(2, 1, cause_val))

        msg_value = bytearray()
        msg_value.append(0x00)
        msg_value.append(0x03)
        msg_value.extend(ies)

        return cls._wrap_initiating_message(
            S1APProcedureCode.UE_CONTEXT_RELEASE_REQUEST, 1, bytes(msg_value)
        )

    @classmethod
    def encode_ue_context_release_complete(
        cls, mme_ue_id: int, enb_ue_id: int
    ) -> bytes:
        """Encode UEContextReleaseComplete.

        Tries pycrate first so the MME receives a spec-correct APER message.
        A valid UEContextReleaseComplete is required for the MME to send
        GTPv2 Release Access Bearers to the SGW and switch the UPF DL FAR to
        buffer mode — without it the DDN/paging chain never fires.
        Falls back to the hand-rolled template if pycrate is unavailable or
        returns too few bytes.
        """
        cls._init_pycrate()

        if cls._use_pycrate:
            try:
                pdu = cls._get_pdu()
                val = ('successfulOutcome', {
                    'procedureCode': 23,  # UEContextRelease
                    'criticality': 'reject',
                    'value': ('UEContextReleaseComplete', {
                        'protocolIEs': [
                            {
                                'id': 0,
                                'criticality': 'ignore',
                                'value': ('MME-UE-S1AP-ID', int(mme_ue_id)),
                            },
                            {
                                'id': 8,
                                'criticality': 'ignore',
                                'value': ('ENB-UE-S1AP-ID', int(enb_ue_id)),
                            },
                        ],
                    }),
                })
                pdu.set_val(val)
                result = pdu.to_aper()
                if result and len(result) >= 5:
                    logger.debug(
                        "UEContextReleaseComplete (pycrate): %d bytes: %s",
                        len(result), result.hex(),
                    )
                    return result
                logger.warning(
                    "UEContextReleaseComplete: pycrate returned %d bytes — falling back to template",
                    len(result) if result else 0,
                )
            except Exception as exc:
                logger.warning(
                    "UEContextReleaseComplete: pycrate encoding failed (%s) — falling back to template",
                    exc,
                )

        # Template fallback
        ies = bytearray()

        mme_id_val = cls._encode_integer_constrained(mme_ue_id, 0, 0xFFFFFFFF)
        ies.extend(cls._wrap_protocol_ie(0, 1, mme_id_val))

        enb_id_val = cls._encode_integer_constrained(enb_ue_id, 0, 16777215)
        ies.extend(cls._wrap_protocol_ie(8, 1, enb_id_val))

        msg_value = bytearray()
        msg_value.append(0x00)
        msg_value.append(0x02)
        msg_value.extend(ies)

        return cls._wrap_successful_outcome(
            S1APProcedureCode.UE_CONTEXT_RELEASE_COMMAND, 0, bytes(msg_value)
        )

    # ================================================================
    # APER Encoding Helpers
    # ================================================================
    @staticmethod
    def _wrap_initiating_message(proc_code: int, criticality: int, value: bytes) -> bytes:
        """Wrap value in an S1AP InitiatingMessage PDU."""
        pdu = bytearray()
        pdu.append(0x00)  # Choice index: initiatingMessage
        pdu.append(proc_code & 0xFF)
        pdu.append(criticality << 6)  # 2-bit criticality (reject=0, ignore=1)
        # Length-determinant for value (open type)
        if len(value) < 128:
            pdu.append(len(value))
        else:
            pdu.append(0x80 | ((len(value) >> 8) & 0x7F))
            pdu.append(len(value) & 0xFF)
        pdu.extend(value)
        return bytes(pdu)

    @staticmethod
    def _wrap_successful_outcome(proc_code: int, criticality: int, value: bytes) -> bytes:
        """Wrap value in an S1AP SuccessfulOutcome PDU."""
        pdu = bytearray()
        pdu.append(0x20)  # Choice index: successfulOutcome
        pdu.append(proc_code & 0xFF)
        pdu.append(criticality << 6)
        if len(value) < 128:
            pdu.append(len(value))
        else:
            pdu.append(0x80 | ((len(value) >> 8) & 0x7F))
            pdu.append(len(value) & 0xFF)
        pdu.extend(value)
        return bytes(pdu)

    @staticmethod
    def _wrap_protocol_ie(ie_id: int, criticality: int, value: bytes) -> bytes:
        """Wrap a value as a ProtocolIE-Field."""
        ie = bytearray()
        ie.extend(ie_id.to_bytes(2, 'big'))  # Protocol IE-ID (2 bytes)
        ie.append(criticality << 6)  # Criticality
        # Length of value
        if len(value) < 128:
            ie.append(len(value))
        else:
            ie.append(0x80 | ((len(value) >> 8) & 0x7F))
            ie.append(len(value) & 0xFF)
        ie.extend(value)
        return bytes(ie)

    @staticmethod
    def _encode_integer_constrained(value: int, lb: int, ub: int) -> bytes:
        """Encode a constrained whole number (APER).

        Per X.691 §12.2 (APER):
          - range ≤ 255  : 1 byte
          - range ≤ 65535: 2 bytes (big-endian)
          - range > 65535: semi-constrained form (X.691 §12.2.6) —
              1-byte length determinant = (n_octets − 1) encoded as
              a constrained whole number INTEGER(1..max_octets).
              Since range is ≤ 256 for that meta-integer, it maps to
              (n_octets − 1) in one byte.
              E.g. MME-UE-S1AP-ID(0..4294967295)=9  → b'\x00\x09'
                   ENB-UE-S1AP-ID(0..16777215)=1    → b'\x00\x01'
        """
        range_val = ub - lb
        offset = value - lb

        if range_val < 256:
            return bytes([offset & 0xFF])
        elif range_val < 65536:
            return struct.pack('!H', offset)
        else:
            # APER §12.2.6: length determinant = (n_octets - 1)
            min_bytes = max(1, (offset.bit_length() + 7) // 8) if offset > 0 else 1
            return bytes([min_bytes - 1]) + offset.to_bytes(min_bytes, 'big')

    @staticmethod
    def _encode_octet_string_unbounded(data: bytes) -> bytes:
        """Encode an unbounded OCTET STRING with length determinant."""
        result = bytearray()
        if len(data) < 128:
            result.append(len(data))
        else:
            result.append(0x80 | ((len(data) >> 8) & 0x7F))
            result.append(len(data) & 0xFF)
        result.extend(data)
        return bytes(result)

    @classmethod
    def _encode_global_enb_id(cls, plmn: bytes, enb_id: int) -> bytes:
        """Encode Global-ENB-ID value."""
        result = bytearray()
        result.append(0x00)  # No optional/extension bits
        result.extend(plmn)  # PLMN identity (3 bytes)
        # eNB-ID CHOICE: macroENB-ID (index 0) = 20 bits
        result.append(0x00)  # CHOICE index 0 (macro)
        # 20-bit BIT STRING
        enb_bytes = (enb_id << 4).to_bytes(3, 'big')  # 20 bits + 4 padding
        result.extend(enb_bytes)
        return bytes(result)

    @staticmethod
    def _encode_printable_string(s: str) -> bytes:
        """Encode a PrintableString with length determinant."""
        encoded = s.encode('ascii')
        result = bytearray()
        if len(encoded) < 128:
            result.append(len(encoded))
        else:
            result.append(0x80 | ((len(encoded) >> 8) & 0x7F))
            result.append(len(encoded) & 0xFF)
        result.extend(encoded)
        return bytes(result)

    @classmethod
    def _encode_supported_tas(cls, plmn: bytes, tac: int) -> bytes:
        """Encode SupportedTAs (list of TAI items)."""
        result = bytearray()
        result.append(0x00)  # 1 item (0-indexed)
        # SupportedTAs-Item:
        result.append(0x00)  # No optional bits
        result.extend(tac.to_bytes(2, 'big'))  # TAC
        # BroadcastPLMNs (1 item)
        result.append(0x00)  # 1 PLMN (0-indexed)
        result.extend(plmn)
        return bytes(result)

    @staticmethod
    def _encode_paging_drx() -> bytes:
        """Encode PagingDRX (enumerated: v32=0, v64=1, v128=2, v256=3)."""
        return bytes([0x40])  # v128 = index 2, shifted left in APER


# ================================================================
# S1AP Decoder
# ================================================================

class S1APDecoder:
    """
    S1AP message decoder.

    Decodes S1AP PDUs to extract NAS messages and procedure information.
    Handles both pycrate-decoded and template-decoded messages.
    """

    _use_pycrate = False
    _s1ap_pdu = None

    @classmethod
    def _init_pycrate(cls):
        """Try to initialize pycrate for decoding."""
        if cls._s1ap_pdu is not None:
            return cls._use_pycrate

        try:
            from pycrate_asn1dir import S1AP
            cls._s1ap_pdu = S1AP.S1AP_PDU_Descriptions.S1AP_PDU
            cls._use_pycrate = True
        except ImportError:
            cls._use_pycrate = False

        return cls._use_pycrate

    @classmethod
    def _get_pdu(cls):
        """Get the S1AP PDU object for decoding."""
        return cls._s1ap_pdu

    @classmethod
    def decode(cls, data: bytes) -> Dict[str, Any]:
        """
        Decode an S1AP PDU.

        Returns a dictionary with decoded fields including:
            - pdu_type: "initiatingMessage", "successfulOutcome", etc.
            - procedure_code: S1AP procedure code
            - mme_ue_id: MME-UE-S1AP-ID (if present)
            - enb_ue_id: eNB-UE-S1AP-ID (if present)
            - nas_pdu: NAS PDU bytes (if present)
            - erab_list: E-RAB list (if present)
        """
        cls._init_pycrate()

        if cls._use_pycrate:
            return cls._decode_pycrate(data)

        return cls._decode_template(data)

    @classmethod
    def _decode_pycrate(cls, data: bytes) -> Dict[str, Any]:
        """Decode using pycrate."""
        result = {}

        try:
            pdu = cls._get_pdu()
            pdu.from_aper(data)
            val = pdu.get_val()

            if isinstance(val, tuple) and len(val) == 2:
                result['pdu_type'], msg = val
            elif isinstance(val, dict) and 'initiatingMessage' in val:
                msg = val['initiatingMessage']
                result['pdu_type'] = 'initiatingMessage'
            elif isinstance(val, dict) and 'successfulOutcome' in val:
                msg = val['successfulOutcome']
                result['pdu_type'] = 'successfulOutcome'
            elif isinstance(val, dict) and 'unsuccessfulOutcome' in val:
                msg = val['unsuccessfulOutcome']
                result['pdu_type'] = 'unsuccessfulOutcome'
            else:
                result['pdu_type'] = 'unknown'
                return result

            result['procedure_code'] = msg['procedureCode']
            result['procedure_name'] = s1ap_procedure_name(result['procedure_code'])
            result['criticality'] = msg.get('criticality', '')

            # Extract IEs from value
            _, ie_val = msg['value']
            if 'protocolIEs' in ie_val:
                for ie in ie_val['protocolIEs']:
                    ie_id = ie['id']
                    _, ie_data = ie['value']

                    if ie_id == 0:  # MME-UE-S1AP-ID
                        result['mme_ue_id'] = ie_data
                    elif ie_id == 8:  # eNB-UE-S1AP-ID
                        result['enb_ue_id'] = ie_data
                    elif ie_id == 26:  # NAS-PDU
                        result['nas_pdu'] = ie_data
                    elif ie_id == 16 or ie_id == 24:  # E-RAB setup lists
                        result['erab_list'] = ie_data
                        erab_id = cls._extract_first_erab_id_from_pycrate(ie_data)
                        if erab_id is not None:
                            result['erab_id'] = erab_id
                        nas_pdu = cls._extract_first_nas_pdu_from_pycrate(ie_data)
                        if nas_pdu is not None:
                            result['nas_pdu'] = nas_pdu
                    elif ie_id == 73:  # SecurityKey
                        result['security_key'] = ie_data
                    elif ie_id == 2:  # Cause
                        result['cause'] = ie_data

        except Exception as e:
            logger.error("pycrate decode error: %s", e)
            result = cls._decode_template(data)

        return result

    @classmethod
    def _decode_template(cls, data: bytes) -> Dict[str, Any]:
        """
        Decode S1AP PDU using manual parsing.

        This handles the common cases needed for the attach flow.
        """
        result = {}

        if len(data) < 4:
            result['error'] = 'PDU too short'
            return result

        # PDU type
        pdu_choice = data[0]
        if pdu_choice == 0x00:
            result['pdu_type'] = 'initiatingMessage'
        elif pdu_choice == 0x20:
            result['pdu_type'] = 'successfulOutcome'
        elif pdu_choice == 0x40:
            result['pdu_type'] = 'unsuccessfulOutcome'
        else:
            result['pdu_type'] = f'unknown(0x{pdu_choice:02X})'
            return result

        result['procedure_code'] = data[1]
        result['procedure_name'] = s1ap_procedure_name(result['procedure_code'])
        result['criticality_byte'] = data[2]

        # Value length
        offset = 3
        if data[offset] & 0x80:
            value_len = ((data[offset] & 0x7F) << 8) | data[offset + 1]
            offset += 2
        else:
            value_len = data[offset]
            offset += 1

        value_data = data[offset:offset + value_len]

        # Parse protocol IEs
        cls._parse_protocol_ies(value_data, result)

        return result

    @classmethod
    def _parse_protocol_ies(cls, data: bytes, result: Dict):
        """Parse the protocolIEs sequence from the message value."""
        if len(data) < 3:
            return

        # Number of IEs (usually 2 bytes)
        offset = 0
        # Skip optional bits / extension bits
        if data[offset] == 0x00:
            offset += 1

        if offset >= len(data):
            return

        num_ies = data[offset]
        if num_ies == 0:
            offset += 1
            if offset < len(data):
                num_ies = data[offset]
        offset += 1

        for _ in range(num_ies):
            if offset + 4 > len(data):
                break

            # IE-ID (2 bytes)
            ie_id = (data[offset] << 8) | data[offset + 1]
            offset += 2

            # Criticality (1 byte, upper 2 bits)
            offset += 1

            # Length
            if offset >= len(data):
                break

            if data[offset] & 0x80:
                ie_len = ((data[offset] & 0x7F) << 8)
                offset += 1
                if offset < len(data):
                    ie_len |= data[offset]
                offset += 1
            else:
                ie_len = data[offset]
                offset += 1

            if offset + ie_len > len(data):
                ie_len = len(data) - offset

            ie_value = data[offset:offset + ie_len]
            offset += ie_len

            # Extract known IEs
            if ie_id == 0:  # MME-UE-S1AP-ID
                if len(ie_value) >= 4:
                    result['mme_ue_id'] = struct.unpack('!I', ie_value[:4])[0]
                elif len(ie_value) >= 2:
                    result['mme_ue_id'] = struct.unpack('!H', ie_value[:2])[0]
                elif len(ie_value) == 1:
                    result['mme_ue_id'] = ie_value[0]
            elif ie_id == 8:  # eNB-UE-S1AP-ID
                if len(ie_value) >= 4:
                    result['enb_ue_id'] = struct.unpack('!I', ie_value[:4])[0]
                elif len(ie_value) >= 3:
                    result['enb_ue_id'] = (ie_value[0] << 16) | (ie_value[1] << 8) | ie_value[2]
                elif len(ie_value) >= 2:
                    result['enb_ue_id'] = struct.unpack('!H', ie_value[:2])[0]
            elif ie_id == 26:  # NAS-PDU
                # OCTET STRING with length determinant
                if len(ie_value) > 0:
                    nas_offset = 0
                    if ie_value[0] & 0x80:
                        nas_len = ((ie_value[0] & 0x7F) << 8) | ie_value[1]
                        nas_offset = 2
                    else:
                        nas_len = ie_value[0]
                        nas_offset = 1
                    result['nas_pdu'] = ie_value[nas_offset:nas_offset + nas_len]
            elif ie_id in (16, 24, 28, 51):  # E-RAB lists
                result['erab_data'] = ie_value
                if ie_id in (16, 24):
                    erab_id = cls._extract_first_erab_id_from_template(ie_value)
                    if erab_id is not None:
                        result['erab_id'] = erab_id
            elif ie_id == 2:  # Cause
                result['cause_raw'] = ie_value.hex()

    @classmethod
    def _extract_first_erab_id_from_pycrate(cls, value: Any) -> Optional[int]:
        """Best-effort extraction of the first e-RAB-ID from pycrate-decoded data."""
        def _walk(node):
            if isinstance(node, dict):
                if 'e-RAB-ID' in node:
                    return node['e-RAB-ID']
                for item in node.values():
                    found = _walk(item)
                    if found is not None:
                        return found
            elif isinstance(node, (list, tuple)):
                for item in node:
                    found = _walk(item)
                    if found is not None:
                        return found
            return None

        erab_id = _walk(value)
        try:
            return int(erab_id) if erab_id is not None else None
        except (TypeError, ValueError):
            return None

    @classmethod
    def _extract_first_nas_pdu_from_pycrate(cls, value: Any) -> Optional[bytes]:
        """Best-effort extraction of embedded NAS-PDU from pycrate-decoded E-RAB structures."""
        def _walk(node):
            if isinstance(node, dict):
                for key, item in node.items():
                    if key in ('nAS-PDU', 'NAS-PDU', 'nAS_PDU', 'NAS_PDU'):
                        if isinstance(item, (bytes, bytearray)):
                            return bytes(item)
                        if isinstance(item, memoryview):
                            return item.tobytes()
                    found = _walk(item)
                    if found is not None:
                        return found
            elif isinstance(node, (list, tuple)):
                for item in node:
                    found = _walk(item)
                    if found is not None:
                        return found
            return None

        return _walk(value)

    @classmethod
    def _extract_first_erab_id_from_template(cls, data: bytes) -> Optional[int]:
        """Best-effort extraction of the first e-RAB-ID from manually decoded IE bytes."""
        if not data:
            return None

        offset = 0
        if data[offset] == 0x00:
            offset += 1
        if offset >= len(data):
            return None

        offset += 1  # list count / list marker
        if offset + 4 > len(data):
            return None

        offset += 2  # inner IE id
        offset += 1  # criticality
        if offset >= len(data):
            return None

        if data[offset] & 0x80:
            inner_len = (data[offset] & 0x7F) << 8
            offset += 1
            if offset >= len(data):
                return None
            inner_len |= data[offset]
            offset += 1
        else:
            inner_len = data[offset]
            offset += 1

        if offset >= len(data):
            return None

        item = data[offset:offset + inner_len]
        if not item:
            return None

        if len(item) >= 2 and item[0] == 0x00:
            return item[1]
        return item[0]


# ================================================================
# S1AP Client
# ================================================================

class S1APClient:
    """
    S1AP SCTP client for connecting to the MME.

    Manages the SCTP connection, S1 Setup, and message exchange for the
    UE attach/detach lifecycle.

    Args:
        mme_ip: MME IP address
        mme_port: MME S1AP port (default 36412)
        local_ip: Local bind address
    """

    def __init__(
        self,
        mme_ip: str = None,
        mme_port: int = None,
        local_ip: str = None,
        shared_conn: 'SharedS1APConnection' = None,
    ):
        self._mme_ip = mme_ip or Config.MME_IP
        self._mme_port = mme_port or Config.MME_PORT
        self._local_ip = local_ip or Config.LOCAL_IP
        self._sock: Optional[socket.socket] = None
        self._connected = False
        self._s1_setup_done = False

        # Shared connection mode
        self._shared_conn = shared_conn
        self._shared_enb_ue_id: int = 0  # assigned by shared conn

        # S1AP IDs
        self._enb_ue_id_counter = 0
        self._enb_ue_id: int = 0
        self._mme_ue_id: int = 0

        # Encoder / Decoder
        self._encoder = S1APEncoder
        self._decoder = S1APDecoder

        # Receive callback
        self._receive_callbacks: Dict[int, Callable] = {}
        self._receive_buffer: Dict[int, Dict] = {}  # proc_code -> decoded msg
        self._receive_lock = threading.Lock()
        self._receive_event = threading.Event()

    def connect(self) -> bool:
        """
        Establish SCTP connection to MME.

        In shared mode, the connection is already established — this is a no-op.
        Tries pysctp first, falls back to raw socket SCTP.

        Returns:
            True if connected successfully
        """
        if self._shared_conn:
            # Shared mode: connection already established, register this UE
            self._shared_enb_ue_id = self._shared_conn.register_ue()
            self._enb_ue_id = self._shared_enb_ue_id
            self._connected = True
            logger.info("Using shared eNB connection (eNB-UE-ID=%d)", self._enb_ue_id)
            return True

        logger.info("Connecting to MME %s:%d via SCTP", self._mme_ip, self._mme_port)

        try:
            self._sock = self._create_sctp_socket()
            self._sock.settimeout(Config.S1AP_TIMEOUT)
            self._sock.connect((self._mme_ip, self._mme_port))
            self._connected = True
            logger.info("SCTP connection established to MME")
            return True
        except Exception as e:
            logger.error("Failed to connect to MME: %s", e)
            self._connected = False
            return False

    def _create_sctp_socket(self) -> socket.socket:
        """Create an SCTP socket using pysctp or raw socket."""
        try:
            import sctp
            sock = sctp.sctpsocket_tcp(socket.AF_INET)
            logger.debug("Using pysctp for SCTP socket")
            return sock
        except ImportError:
            pass

        # Try raw SCTP socket
        try:
            IPPROTO_SCTP = 132
            sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM, IPPROTO_SCTP)
            logger.debug("Using raw SCTP socket (IPPROTO_SCTP=132)")
            return sock
        except OSError as e:
            logger.warning("Raw SCTP not available: %s. Falling back to TCP shim.", e)
            # Last resort: TCP socket for development/testing without SCTP
            sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
            logger.warning("Using TCP socket as SCTP fallback (NOT spec-compliant)")
            return sock

    def disconnect(self):
        """Close the SCTP connection (or unregister from shared connection)."""
        if self._shared_conn:
            # Shared mode: just unregister this UE, don't close the socket
            if self._shared_enb_ue_id:
                self._shared_conn.unregister_ue(self._shared_enb_ue_id)
                self._shared_enb_ue_id = 0
            self._connected = False
            return

        if self._sock:
            try:
                self._sock.close()
            except Exception:
                pass
            self._sock = None
        self._connected = False
        self._s1_setup_done = False
        logger.info("Disconnected from MME")

    def s1_setup(self) -> bool:
        """
        Perform S1 Setup procedure with MME.

        In shared mode, S1 Setup is already done — this is a no-op.
        Sends S1SetupRequest and waits for S1SetupResponse.

        Returns:
            True if S1 Setup succeeded
        """
        if self._shared_conn:
            # Shared mode: S1 Setup already done
            self._s1_setup_done = True
            return True

        if not self._connected:
            raise ConnectionError("Not connected to MME")

        logger.info("Sending S1SetupRequest to MME")

        plmn = Config.plmn_bytes()
        pdu = self._encoder.encode_s1_setup_request(
            plmn=plmn,
            enb_id=Config.ENB_ID,
            enb_name=Config.ENB_NAME,
            tac=Config.TAC,
        )

        self._send(pdu)

        # Wait for S1SetupResponse
        response = self._receive()
        if response is None:
            logger.error("No S1SetupResponse received")
            return False

        decoded = self._decoder.decode(response)
        logger.info("S1 Setup response: %s (proc=%s)",
                     decoded.get('pdu_type'), decoded.get('procedure_code'))

        if decoded.get('pdu_type') == 'successfulOutcome' and \
           decoded.get('procedure_code') == S1APProcedureCode.S1_SETUP:
            self._s1_setup_done = True
            logger.info("S1 Setup successful")
            return True
        elif decoded.get('pdu_type') == 'unsuccessfulOutcome':
            logger.error("S1 Setup failed: %s", decoded)
            return False
        else:
            logger.warning("Unexpected response to S1 Setup: %s", decoded)
            return False

    def send_attach_request(self, nas_pdu: bytes) -> int:
        """
        Send InitialUEMessage carrying Attach Request.

        Args:
            nas_pdu: NAS Attach Request PDU

        Returns:
            eNB-UE-S1AP-ID assigned to this UE
        """
        if self._shared_conn:
            # In shared mode, eNB-UE-ID was assigned at connect() time
            pass
        else:
            self._enb_ue_id_counter += 1
            self._enb_ue_id = self._enb_ue_id_counter

        plmn = Config.plmn_bytes()

        pdu = self._encoder.encode_initial_ue_message(
            enb_ue_id=self._enb_ue_id,
            nas_pdu=nas_pdu,
            plmn=plmn,
            tac=Config.TAC,
            cell_id=Config.CELL_ID,
            rrc_cause=3,  # mo-Signalling
        )

        self._send(pdu)
        logger.info("Sent InitialUEMessage (eNB-UE-ID=%d)", self._enb_ue_id)
        return self._enb_ue_id

    def receive_nas(self, timeout: float = None) -> Tuple[Optional[bytes], Dict]:
        """
        Receive the next downlink S1AP message and extract NAS PDU.

        Handles:
            - DownlinkNASTransport (extracts NAS PDU)
            - InitialContextSetupRequest (extracts NAS PDU, auto-responds)

        Args:
            timeout: Override receive timeout

        Returns:
            Tuple of (NAS PDU bytes or None, decoded S1AP dict)
        """
        if self._shared_conn:
            data = self._shared_conn.receive_for_ue(self._enb_ue_id, timeout)
        else:
            data = self._receive(timeout)
        if data is None:
            return None, {"error": "timeout"}

        decoded = self._decoder.decode(data)
        proc_code = decoded.get('procedure_code', -1)

        # Store MME-UE-S1AP-ID
        if 'mme_ue_id' in decoded:
            self._mme_ue_id = decoded['mme_ue_id']

        nas_pdu = decoded.get('nas_pdu')

        # If it is InitialContextSetupRequest, we need to send a response
        if proc_code == S1APProcedureCode.INITIAL_CONTEXT_SETUP:
            logger.info("Received InitialContextSetupRequest (MME-UE-ID=%d)",
                        self._mme_ue_id)
            self._send_initial_context_setup_response()
        elif proc_code == S1APProcedureCode.E_RAB_SETUP:
            erab_id = decoded.get('erab_id', 5)
            logger.info("Received E-RABSetupRequest (MME-UE-ID=%d e-RAB-ID=%d)",
                        self._mme_ue_id, erab_id)
            self._send_erab_setup_response(erab_id=erab_id)
            decoded['erab_setup_response_sent'] = True
            decoded['erab_id'] = erab_id
        elif proc_code == S1APProcedureCode.PAGING:
            logger.info("Received Paging message (broadcast from MME)")
            decoded['paging'] = True

        if nas_pdu:
            logger.debug("Extracted NAS PDU (%d bytes): %s",
                         len(nas_pdu), nas_pdu.hex()[:40] + "...")

        return nas_pdu, decoded

    def send_nas(self, nas_pdu: bytes):
        """
        Send UplinkNASTransport carrying a NAS message.

        Args:
            nas_pdu: NAS PDU to send
        """
        plmn = Config.plmn_bytes()

        pdu = self._encoder.encode_uplink_nas_transport(
            mme_ue_id=self._mme_ue_id,
            enb_ue_id=self._enb_ue_id,
            nas_pdu=nas_pdu,
            plmn=plmn,
            tac=Config.TAC,
            cell_id=Config.CELL_ID,
        )

        self._send(pdu)
        logger.debug("Sent UplinkNASTransport (%d bytes NAS)", len(nas_pdu))

    def send_ue_context_release(self):
        """Send UEContextReleaseRequest (UE-initiated detach)."""
        pdu = self._encoder.encode_ue_context_release_request(
            mme_ue_id=self._mme_ue_id,
            enb_ue_id=self._enb_ue_id,
        )
        logger.warning(
            "Sending UEContextReleaseRequest (%d bytes, mme_ue_id=%d, enb_ue_id=%d): %s",
            len(pdu), self._mme_ue_id, self._enb_ue_id, pdu.hex(),
        )
        self._send(pdu)
        logger.info("Sent UEContextReleaseRequest")

    def handle_ue_context_release_command(self, timeout: float = 10.0) -> bool:
        """
        Wait for and handle UEContextReleaseCommand from MME.

        Sends UEContextReleaseComplete in response.  Loops through any
        intermediate S1AP messages (e.g. a pending DownlinkNASTransport or
        E-RABSetupRequest that the MME flushes before releasing the context)
        until the UEContextReleaseCommand arrives or the timeout expires.

        Returns:
            True if release command received and completed
        """
        deadline = time.time() + timeout
        while time.time() < deadline:
            remaining = deadline - time.time()
            if remaining <= 0:
                break
            if self._shared_conn:
                data = self._shared_conn.receive_for_ue(
                    self._enb_ue_id, timeout=min(remaining, 2.0)
                )
            else:
                data = self._receive(timeout=min(remaining, 2.0))
            if data is None:
                # No message yet — keep waiting
                continue

            decoded = self._decoder.decode(data)
            proc_code = decoded.get('procedure_code', -1)

            if proc_code == S1APProcedureCode.UE_CONTEXT_RELEASE_COMMAND:
                # Send UEContextReleaseComplete
                pdu = self._encoder.encode_ue_context_release_complete(
                    mme_ue_id=self._mme_ue_id,
                    enb_ue_id=self._enb_ue_id,
                )
                self._send(pdu)
                logger.info("Sent UEContextReleaseComplete")
                return True

            # Any other message (pending NAS downlink, E-RAB, etc.) — log and skip
            logger.debug(
                "handle_ue_context_release_command: skipping procedure_code=%s "
                "while waiting for UEContextReleaseCommand",
                proc_code,
            )

        logger.warning("No UEContextReleaseCommand received within %.1fs", timeout)
        return False

    def wait_for_paging(self, timeout: float = 30.0) -> bool:
        """
        Wait for a Paging message from the MME.

        The UE must be in S1 idle state (UEContextReleaseRequest sent).
        Paging is a broadcast message (no UE-ID), so SharedS1APConnection
        delivers it to all registered UE queues automatically.

        Args:
            timeout: Maximum seconds to wait for the paging message

        Returns:
            True if a Paging message arrived before the timeout
        """
        deadline = time.time() + timeout
        while time.time() < deadline:
            remaining = deadline - time.time()
            _, decoded = self.receive_nas(timeout=min(remaining, 5.0))
            if decoded.get('paging'):
                logger.info("Paging received — UE can respond with Service Request")
                return True
        logger.warning("No Paging received within %.1fs", timeout)
        return False

    def _send_initial_context_setup_response(self):
        """Send InitialContextSetupResponse to acknowledge bearer setup."""
        pdu = self._encoder.encode_initial_context_setup_response(
            mme_ue_id=self._mme_ue_id,
            enb_ue_id=self._enb_ue_id,
            erab_id=5,
            gtp_teid=self._enb_ue_id,  # Use eNB-UE-ID as TEID for simplicity
            transport_addr=self._local_ip if self._local_ip != "0.0.0.0" else "127.0.0.1",
        )
        self._send(pdu)
        logger.info("Sent InitialContextSetupResponse")

    def _send_erab_setup_response(self, erab_id: int = 5):
        """Send E-RABSetupResponse to acknowledge dedicated bearer setup."""
        pdu = self._encoder.encode_erab_setup_response(
            mme_ue_id=self._mme_ue_id,
            enb_ue_id=self._enb_ue_id,
            erab_id=erab_id,
            gtp_teid=self._enb_ue_id,
            transport_addr=self._local_ip if self._local_ip != "0.0.0.0" else "127.0.0.1",
        )
        self._send(pdu)
        logger.info("Sent E-RABSetupResponse (e-RAB-ID=%d)", erab_id)

    # ================================================================
    # Low-level SCTP I/O
    # ================================================================
    def _send(self, data: bytes):
        """Send data over SCTP with S1AP PPID."""
        if self._shared_conn:
            self._shared_conn.send(data)
            return

        if not self._sock:
            raise ConnectionError("Socket not connected")

        try:
            # Try sctp-specific send with PPID
            try:
                import sctp
                self._sock.sctp_send(data, ppid=socket.htonl(S1AP_PPID))
            except (ImportError, AttributeError):
                self._sock.sendall(data)

            logger.debug("Sent %d bytes to MME", len(data))
        except Exception as e:
            logger.error("Send failed: %s", e)
            raise

    def _receive(self, timeout: float = None) -> Optional[bytes]:
        """
        Receive data from SCTP.

        Args:
            timeout: Receive timeout in seconds

        Returns:
            Received bytes or None on timeout
        """
        if not self._sock:
            raise ConnectionError("Socket not connected")

        if timeout is not None:
            self._sock.settimeout(timeout)
        else:
            self._sock.settimeout(Config.S1AP_TIMEOUT)

        try:
            # Wait for data using select() — pysctp doesn't always honor settimeout
            import select
            effective_timeout = timeout if timeout is not None else Config.S1AP_TIMEOUT
            ready, _, _ = select.select([self._sock], [], [], effective_timeout)
            if not ready:
                logger.debug("Receive timeout (select)")
                return None

            # Try sctp-specific receive
            try:
                import sctp
                fromaddr, flags, data, notif = self._sock.sctp_recv(65536)
                if data:
                    logger.debug("Received %d bytes from MME", len(data))
                    return data
                return None
            except (ImportError, AttributeError):
                data = self._sock.recv(65536)
                if data:
                    logger.debug("Received %d bytes from MME", len(data))
                    return data
                return None
        except socket.timeout:
            logger.debug("Receive timeout")
            return None
        except Exception as e:
            logger.error("Receive failed: %s", e)
            return None

    @property
    def connected(self) -> bool:
        if self._shared_conn:
            return self._shared_conn.connected
        return self._connected

    @property
    def s1_setup_done(self) -> bool:
        return self._s1_setup_done

    @property
    def mme_ue_id(self) -> int:
        return self._mme_ue_id

    @property
    def enb_ue_id(self) -> int:
        return self._enb_ue_id

    @property
    def using_shared_conn(self) -> bool:
        """Whether this client is using a shared eNB connection."""
        return self._shared_conn is not None


# ================================================================
# Shared S1AP Connection (single eNB, multiple UEs)
# ================================================================

class SharedS1APConnection:
    """
    Shared SCTP connection to MME representing a single eNB.

    One SCTP association, one S1 Setup, multiple UEs multiplexed by
    eNB-UE-S1AP-ID. A background receive thread demuxes incoming
    messages into per-UE queues.

    Usage:
        shared = SharedS1APConnection()
        shared.connect()
        shared.s1_setup()

        # Each UE registers to get a unique eNB-UE-S1AP-ID + queue
        ue_id = shared.register_ue()
        ...
        shared.send(pdu)
        msg = shared.receive_for_ue(ue_id, timeout=10.0)
        ...
        shared.unregister_ue(ue_id)
        shared.disconnect()
    """

    def __init__(
        self,
        mme_ip: str = None,
        mme_port: int = None,
        local_ip: str = None,
        enb_id: int = None,
        enb_name: str = None,
    ):
        self._mme_ip = mme_ip or Config.MME_IP
        self._mme_port = mme_port or Config.MME_PORT
        self._local_ip = local_ip or Config.LOCAL_IP
        self._enb_id = enb_id if enb_id is not None else Config.ENB_ID
        self._enb_name = enb_name or Config.ENB_NAME
        self._sock: Optional[socket.socket] = None
        self._connected = False
        self._s1_setup_done = False

        # Per-UE demux: eNB-UE-S1AP-ID -> Queue
        import queue
        self._ue_queues: Dict[int, 'queue.Queue'] = {}
        self._ue_queues_lock = threading.Lock()
        self._mme_to_enb: Dict[int, int] = {}
        self._mme_to_enb_lock = threading.Lock()
        self._ue_id_counter = 0
        self._ue_id_lock = threading.Lock()

        # Thread-safe send
        self._send_lock = threading.Lock()

        # Background receive thread
        self._recv_thread: Optional[threading.Thread] = None
        self._stop_event = threading.Event()

        # S1Setup response queue (not UE-specific)
        self._setup_queue: 'queue.Queue' = None

    def connect(self) -> bool:
        """Establish SCTP connection to MME."""
        import queue
        self._setup_queue = queue.Queue()

        logger.info("[SharedENB] Connecting to MME %s:%d", self._mme_ip, self._mme_port)
        try:
            self._sock = self._create_sctp_socket()
            self._sock.settimeout(Config.S1AP_TIMEOUT)
            self._sock.connect((self._mme_ip, self._mme_port))
            self._connected = True

            # Start receive thread
            self._stop_event.clear()
            self._recv_thread = threading.Thread(
                target=self._receive_loop, daemon=True, name="SharedENB-recv"
            )
            self._recv_thread.start()

            logger.info("[SharedENB] SCTP connection established")
            return True
        except Exception as e:
            logger.error("[SharedENB] Connect failed: %s", e)
            self._connected = False
            return False

    def _create_sctp_socket(self) -> socket.socket:
        """Create an SCTP socket."""
        try:
            import sctp
            return sctp.sctpsocket_tcp(socket.AF_INET)
        except ImportError:
            pass

        try:
            return socket.socket(socket.AF_INET, socket.SOCK_STREAM, 132)
        except OSError:
            return socket.socket(socket.AF_INET, socket.SOCK_STREAM)

    def s1_setup(self) -> bool:
        """Perform S1 Setup (once per connection)."""
        if not self._connected:
            raise ConnectionError("Not connected to MME")
        if self._s1_setup_done:
            return True

        logger.info("[SharedENB] S1 Setup (eNB-ID=0x%05X)", self._enb_id)

        plmn = Config.plmn_bytes()
        pdu = S1APEncoder.encode_s1_setup_request(
            plmn=plmn,
            enb_id=self._enb_id,
            enb_name=self._enb_name,
            tac=Config.TAC,
        )

        self._raw_send(pdu)

        # Wait for S1SetupResponse (routed to _setup_queue by recv thread)
        try:
            data = self._setup_queue.get(timeout=Config.S1AP_TIMEOUT)
        except Exception:
            logger.error("[SharedENB] No S1SetupResponse received")
            return False

        decoded = S1APDecoder.decode(data)
        if (decoded.get('pdu_type') == 'successfulOutcome' and
                decoded.get('procedure_code') == S1APProcedureCode.S1_SETUP):
            self._s1_setup_done = True
            logger.info("[SharedENB] S1 Setup successful")
            return True

        logger.error("[SharedENB] S1 Setup failed: %s", decoded.get('pdu_type'))
        return False

    def register_ue(self) -> int:
        """Register a new UE and return its eNB-UE-S1AP-ID."""
        import queue
        with self._ue_id_lock:
            self._ue_id_counter += 1
            ue_id = self._ue_id_counter

        with self._ue_queues_lock:
            self._ue_queues[ue_id] = queue.Queue()

        logger.debug("[SharedENB] Registered UE eNB-UE-ID=%d", ue_id)
        return ue_id

    def unregister_ue(self, enb_ue_id: int):
        """Remove a UE's queue."""
        with self._ue_queues_lock:
            self._ue_queues.pop(enb_ue_id, None)
        with self._mme_to_enb_lock:
            stale_mme_ids = [mme_id for mme_id, mapped_enb_id in self._mme_to_enb.items() if mapped_enb_id == enb_ue_id]
            for mme_id in stale_mme_ids:
                self._mme_to_enb.pop(mme_id, None)
        logger.debug("[SharedENB] Unregistered UE eNB-UE-ID=%d", enb_ue_id)

    def bind_mme_ue(self, mme_ue_id: int, enb_ue_id: int):
        """Remember the MME->eNB UE-ID mapping for shared downlink routing."""
        if mme_ue_id is None or enb_ue_id is None:
            return
        with self._mme_to_enb_lock:
            self._mme_to_enb[int(mme_ue_id)] = int(enb_ue_id)

    def send(self, data: bytes):
        """Thread-safe send over the shared SCTP socket."""
        self._raw_send(data)

    def _raw_send(self, data: bytes):
        """Send data with lock."""
        if not self._sock:
            raise ConnectionError("Socket not connected")
        with self._send_lock:
            try:
                try:
                    import sctp
                    self._sock.sctp_send(data, ppid=socket.htonl(S1AP_PPID))
                except (ImportError, AttributeError):
                    self._sock.sendall(data)
            except Exception as e:
                logger.error("[SharedENB] Send failed: %s", e)
                raise

    def receive_for_ue(self, enb_ue_id: int, timeout: float = None) -> Optional[bytes]:
        """
        Block until a message arrives for this UE.

        Returns the raw S1AP PDU bytes, or None on timeout.
        """
        timeout = timeout if timeout is not None else Config.S1AP_TIMEOUT
        with self._ue_queues_lock:
            q = self._ue_queues.get(enb_ue_id)
        if q is None:
            logger.error("[SharedENB] No queue for eNB-UE-ID=%d", enb_ue_id)
            return None

        try:
            return q.get(timeout=timeout)
        except Exception:
            return None

    def _receive_loop(self):
        """Background thread: read from socket, decode, route to per-UE queue."""
        import select

        while not self._stop_event.is_set():
            try:
                ready, _, _ = select.select([self._sock], [], [], 0.5)
                if not ready:
                    continue

                try:
                    import sctp
                    _, _, data, _ = self._sock.sctp_recv(65536)
                except (ImportError, AttributeError):
                    data = self._sock.recv(65536)

                if not data:
                    logger.warning("[SharedENB] Connection closed by MME")
                    self._connected = False
                    break

                # Decode to find the target UE
                decoded = S1APDecoder.decode(data)
                proc_code = decoded.get('procedure_code', -1)

                # S1SetupResponse goes to setup queue
                if proc_code == S1APProcedureCode.S1_SETUP:
                    self._setup_queue.put(data)
                    continue

                # Route by eNB-UE-S1AP-ID when available. Some Open5GS
                # downlink messages only carry the MME-UE-ID after the
                # initial context is established, so keep a reverse map.
                enb_ue_id = decoded.get('enb_ue_id')
                mme_ue_id = decoded.get('mme_ue_id')

                if enb_ue_id is not None and mme_ue_id is not None:
                    self.bind_mme_ue(mme_ue_id, enb_ue_id)

                if enb_ue_id is None and mme_ue_id is not None:
                    with self._mme_to_enb_lock:
                        enb_ue_id = self._mme_to_enb.get(int(mme_ue_id))

                if enb_ue_id is not None:
                    with self._ue_queues_lock:
                        q = self._ue_queues.get(enb_ue_id)
                    if q is not None:
                        q.put(data)
                    else:
                        logger.warning("[SharedENB] No queue for eNB-UE-ID=%d (proc=%d)",
                                       enb_ue_id, proc_code)
                else:
                    # Broadcast to all UEs (e.g. Reset, Paging)
                    logger.debug("[SharedENB] Broadcast msg proc=%d to all UEs", proc_code)
                    with self._ue_queues_lock:
                        for q in self._ue_queues.values():
                            q.put(data)

            except OSError:
                if not self._stop_event.is_set():
                    logger.warning("[SharedENB] Socket error in receive loop")
                break
            except Exception as e:
                if not self._stop_event.is_set():
                    logger.error("[SharedENB] Receive loop error: %s", e)
                continue

    def disconnect(self):
        """Stop receive thread and close socket."""
        self._stop_event.set()
        if self._recv_thread and self._recv_thread.is_alive():
            self._recv_thread.join(timeout=3.0)
        if self._sock:
            try:
                self._sock.close()
            except Exception:
                pass
            self._sock = None
        with self._ue_queues_lock:
            self._ue_queues.clear()
        with self._mme_to_enb_lock:
            self._mme_to_enb.clear()
        self._connected = False
        self._s1_setup_done = False
        logger.info("[SharedENB] Disconnected")

    @property
    def connected(self) -> bool:
        return self._connected

    @property
    def s1_setup_done(self) -> bool:
        return self._s1_setup_done


if __name__ == "__main__":
    logging.basicConfig(level=logging.DEBUG)

    # Test encoding
    plmn = Config.plmn_bytes()
    print(f"PLMN: {plmn.hex()}")

    s1setup = S1APEncoder.encode_s1_setup_request(
        plmn=plmn, enb_id=0x12345, enb_name="SIPp-Test-eNB", tac=1
    )
    print(f"S1SetupRequest ({len(s1setup)} bytes): {s1setup.hex()}")

    nas_pdu = bytes.fromhex("0741720f0900100019008765040007f0e0e000")
    initial_ue = S1APEncoder.encode_initial_ue_message(
        enb_ue_id=1, nas_pdu=nas_pdu, plmn=plmn, tac=1, cell_id=0x12345
    )
    print(f"InitialUEMessage ({len(initial_ue)} bytes): {initial_ue.hex()}")
