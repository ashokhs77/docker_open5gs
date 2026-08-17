"""
NAS (Non-Access Stratum) Message Handler for LTE/EPC

Implements NAS message encoding and decoding per 3GPP TS 24.301 (EPS Mobility
Management) and TS 24.008 (ESM / session management).

Supported messages:
    Encode:
        - Attach Request (0x41)
        - Authentication Response (0x53)
        - Security Mode Complete (0x5e)
        - Attach Complete (0x43)
        - Detach Request (0x45)
        - PDN Connectivity Request (ESM)
        - Activate Default EPS Bearer Context Accept (ESM)

    Decode:
        - Authentication Request (0x52)
        - Security Mode Command (0x5d)
        - Attach Accept (0x42)
        - Attach Reject (0x44)
        - EMM Information (0x61)
        - Downlink NAS Transport
"""

import struct
import hashlib
import hmac
import logging
from enum import IntEnum
from typing import Optional, Tuple, Dict, Any

logger = logging.getLogger(__name__)


# ================================================================
# NAS Protocol Constants (TS 24.301)
# ================================================================

class NASSecurityHeaderType(IntEnum):
    """NAS security header types (4-bit field)."""
    PLAIN = 0x00
    INTEGRITY_PROTECTED = 0x01
    INTEGRITY_CIPHERED = 0x02
    INTEGRITY_PROTECTED_NEW_CONTEXT = 0x03
    INTEGRITY_PROTECTED_CIPHERED = 0x04


class EPSMobilityMessageType(IntEnum):
    """EPS Mobility Management (EMM) message types."""
    ATTACH_REQUEST = 0x41
    ATTACH_ACCEPT = 0x42
    ATTACH_COMPLETE = 0x43
    ATTACH_REJECT = 0x44
    DETACH_REQUEST = 0x45
    DETACH_ACCEPT = 0x46
    TAU_REQUEST = 0x48
    TAU_ACCEPT = 0x49
    TAU_REJECT = 0x4A
    TAU_COMPLETE = 0x4B
    AUTHENTICATION_REQUEST = 0x52
    AUTHENTICATION_RESPONSE = 0x53
    AUTHENTICATION_REJECT = 0x54
    AUTHENTICATION_FAILURE = 0x5C
    SECURITY_MODE_COMMAND = 0x5D
    SECURITY_MODE_COMPLETE = 0x5E
    SECURITY_MODE_REJECT = 0x5F
    EMM_INFORMATION = 0x61
    SERVICE_REQUEST = 0x4D
    IDENTITY_REQUEST = 0x55
    IDENTITY_RESPONSE = 0x56


class ESMMessageType(IntEnum):
    """EPS Session Management (ESM) message types."""
    PDN_CONNECTIVITY_REQUEST = 0xD0
    PDN_CONNECTIVITY_REJECT = 0xD1
    ACTIVATE_DEFAULT_BEARER_CTX_REQUEST = 0xC1
    ACTIVATE_DEFAULT_BEARER_CTX_ACCEPT = 0xC2
    ACTIVATE_DEFAULT_BEARER_CTX_REJECT = 0xC3
    ACTIVATE_DEDICATED_BEARER_CTX_REQUEST = 0xC5
    ACTIVATE_DEDICATED_BEARER_CTX_ACCEPT = 0xC6
    DEACTIVATE_BEARER_CTX_REQUEST = 0xCD
    DEACTIVATE_BEARER_CTX_ACCEPT = 0xCE
    MODIFY_BEARER_CTX_REQUEST = 0xC9
    MODIFY_BEARER_CTX_ACCEPT = 0xCA


class EPSAttachType(IntEnum):
    """EPS attach type values."""
    EPS_ATTACH = 0x01
    COMBINED_ATTACH = 0x02  # EPS + IMSI attach
    EPS_EMERGENCY = 0x06


class NASKeySetIdentifier(IntEnum):
    """NAS key set identifier (3-bit TSC + 3-bit key set ID)."""
    NO_KEY_AVAILABLE = 0x07


# NAS ciphering algorithms
EEA0 = 0  # Null ciphering
EEA1 = 1  # SNOW 3G
EEA2 = 2  # AES-CTR

# NAS integrity algorithms
EIA0 = 0  # Null integrity (forbidden in real networks)
EIA1 = 1  # SNOW 3G
EIA2 = 2  # AES-CMAC


class NASHandler:
    """
    NAS message encoder/decoder for the UE simulator.

    Handles the NAS layer (EMM and ESM) message construction and parsing
    needed for EPC attach, authentication, and bearer setup.

    Args:
        imsi: IMSI string (15 digits)
        ue_network_capability: Override default UE network capability
    """

    def __init__(self, imsi: str, ue_network_capability: bytes = None):
        if len(imsi) < 14 or len(imsi) > 15:
            raise ValueError(f"IMSI must be 14-15 digits, got {len(imsi)}")

        self._imsi = imsi
        self._ue_net_cap = ue_network_capability

        # NAS security context (populated after Security Mode Command)
        self._nas_count_ul = 0
        self._nas_count_dl = 0
        self._knas_int: Optional[bytes] = None
        self._knas_enc: Optional[bytes] = None
        self._selected_eia: int = EIA0
        self._selected_eea: int = EEA0
        self._security_active = False
        self._ksi: int = NASKeySetIdentifier.NO_KEY_AVAILABLE  # Updated from Auth Request

        # Bearer state
        self._bearer_id: int = 5  # default EPS bearer ID

    # ================================================================
    # IMSI Encoding (BCD)
    # ================================================================
    def _encode_imsi_bcd(self) -> bytes:
        """
        Encode IMSI as BCD in EPS Mobile Identity format.

        Format per TS 24.301 Section 9.9.3.12:
            Length (1 byte)
            Digit 1 | Odd/Even | Type (1 byte)
            Digit 3 | Digit 2 (1 byte)
            ...

        For 15-digit IMSI (odd number of digits):
            Type = 0x01 (IMSI), Odd indicator = 1
        """
        imsi = self._imsi
        n = len(imsi)
        is_odd = (n % 2 == 1)

        result = bytearray()

        # First byte: digit1 (high nibble) | odd/even flag | identity type
        # Identity type = 001 (IMSI)
        # For odd-length: bit 4 = 1
        first_digit = int(imsi[0])
        flag_type = (0x09 if is_odd else 0x01)  # 1001 for odd IMSI, 0001 for even
        result.append((first_digit << 4) | flag_type)

        # Remaining digits in pairs
        idx = 1
        while idx < n:
            low = int(imsi[idx])
            if idx + 1 < n:
                high = int(imsi[idx + 1])
            else:
                high = 0x0F  # filler
            result.append((high << 4) | low)
            idx += 2

        # Prepend length byte
        length = len(result)
        return bytes([length]) + bytes(result)

    @staticmethod
    def _decode_imsi_bcd(data: bytes) -> str:
        """Decode BCD-encoded IMSI from EPS Mobile Identity IE."""
        if not data:
            return ""

        length = data[0]
        payload = data[1:1 + length]

        digits = []
        # First byte: high nibble = digit 1, low nibble = type/flags
        digits.append(str((payload[0] >> 4) & 0x0F))

        for i in range(1, len(payload)):
            low = payload[i] & 0x0F
            high = (payload[i] >> 4) & 0x0F
            digits.append(str(low))
            if high != 0x0F:
                digits.append(str(high))

        return ''.join(digits)

    # ================================================================
    # UE Network Capability
    # ================================================================
    def _encode_ue_network_capability(self) -> bytes:
        """
        Encode UE Network Capability IE (TS 24.301 Section 9.9.3.34).

        Default capability:
            EEA0, EEA1 (128-EEA1), EEA2 (128-EEA2)
            EIA1 (128-EIA1), EIA2 (128-EIA2)
            UEA0, UEA1
            UIA1, UIA2
        """
        if self._ue_net_cap is not None:
            cap = self._ue_net_cap
        else:
            # Byte 1: EPS encryption algorithms
            #   bit 8: EEA0 (null)      = 1
            #   bit 7: 128-EEA1 (SNOW)  = 1
            #   bit 6: 128-EEA2 (AES)   = 1
            #   bit 5: EEA3 (ZUC)       = 0
            #   bit 4-1: spare          = 0
            eea_byte = 0b11100000  # EEA0 + EEA1 + EEA2

            # Byte 2: EPS integrity algorithms
            #   bit 8: EIA0 (null)      = 0 (not allowed)
            #   bit 7: 128-EIA1 (SNOW)  = 1
            #   bit 6: 128-EIA2 (AES)   = 1
            #   bit 5: EIA3 (ZUC)       = 0
            #   bit 4-1: spare          = 0
            eia_byte = 0b01100000  # EIA1 + EIA2

            # Byte 3: UMTS encryption algorithms
            uea_byte = 0b11000000  # UEA0 + UEA1

            # Byte 4: UMTS integrity + misc
            uia_byte = 0b01100000  # UIA1 + UIA2

            cap = bytes([eea_byte, eia_byte, uea_byte, uia_byte])

        # IE format: IEI (optional) + Length + Value
        return bytes([len(cap)]) + cap

    # ================================================================
    # ESM Message Construction
    # ================================================================
    def build_pdn_connectivity_request(
        self, apn: str = "internet", pdn_type: int = 0x01
    ) -> bytes:
        """
        Build PDN Connectivity Request (TS 24.301 Section 8.3.20).

        Args:
            apn: Access Point Name string
            pdn_type: 1=IPv4, 2=IPv6, 3=IPv4v6

        Returns:
            Complete ESM message bytes
        """
        msg = bytearray()

        # EPS bearer identity (4 bits) + Protocol discriminator (4 bits)
        # Bearer ID = 0 (unassigned), PD = 0x02 (ESM)
        msg.append(0x02)

        # Procedure transaction identity (1 byte) - use 0x01
        msg.append(0x01)

        # Message type
        msg.append(ESMMessageType.PDN_CONNECTIVITY_REQUEST)

        # Request type (high nibble) + PDN type (low nibble) — TS 24.301 §8.3.20 / §9.9.4.10
        # Upper nibble (bits 8-5): Request type  — 0x1 = initial request
        # Lower nibble (bits 4-1): PDN type      — 1=IPv4, 2=IPv6, 3=IPv4v6
        # e.g. IPv4 initial=0x11, IPv6 initial=0x12, IPv4v6 initial=0x13
        msg.append((0x01 << 4) | (pdn_type & 0x0F))

        # Optional IEs

        # APN (IEI = 0x28)
        if apn:
            encoded_apn = self._encode_apn(apn)
            msg.append(0x28)  # IEI
            msg.append(len(encoded_apn))
            msg.extend(encoded_apn)

        # Protocol configuration options (IEI = 0x27)
        # Request DNS server addresses via PCO
        pco = self._build_pco_request()
        msg.append(0x27)
        msg.append(len(pco))
        msg.extend(pco)

        return bytes(msg)

    def build_activate_default_bearer_accept(self, bearer_id: int = 5) -> bytes:
        """
        Build Activate Default EPS Bearer Context Accept.

        Args:
            bearer_id: EPS bearer ID from Attach Accept

        Returns:
            Complete ESM message bytes
        """
        msg = bytearray()

        # EPS bearer identity (4 bits) | Protocol discriminator (4 bits)
        msg.append((bearer_id << 4) | 0x02)

        # Procedure transaction identity
        msg.append(0x00)

        # Message type
        msg.append(ESMMessageType.ACTIVATE_DEFAULT_BEARER_CTX_ACCEPT)

        return bytes(msg)

    def build_activate_dedicated_bearer_accept(self, bearer_id: int) -> bytes:
        """
        Build Activate Dedicated EPS Bearer Context Accept.

        Args:
            bearer_id: EPS bearer ID from the request

        Returns:
            Complete ESM message bytes
        """
        msg = bytearray()
        msg.append((bearer_id << 4) | 0x02)
        msg.append(0x00)
        msg.append(ESMMessageType.ACTIVATE_DEDICATED_BEARER_CTX_ACCEPT)
        plain_msg = bytes(msg)

        if self._security_active and self._knas_int is not None:
            return self._apply_nas_security(
                plain_msg,
                NASSecurityHeaderType.INTEGRITY_PROTECTED_CIPHERED
            )

        return plain_msg

    def build_deactivate_bearer_accept(self, bearer_id: int) -> bytes:
        """
        Build Deactivate EPS Bearer Context Accept.

        Args:
            bearer_id: EPS bearer ID from the request

        Returns:
            Complete ESM message bytes
        """
        msg = bytearray()
        msg.append((bearer_id << 4) | 0x02)
        msg.append(0x00)
        msg.append(ESMMessageType.DEACTIVATE_BEARER_CTX_ACCEPT)
        plain_msg = bytes(msg)

        if self._security_active and self._knas_int is not None:
            return self._apply_nas_security(
                plain_msg,
                NASSecurityHeaderType.INTEGRITY_PROTECTED_CIPHERED
            )

        return plain_msg

    @staticmethod
    def _encode_apn(apn: str) -> bytes:
        """
        Encode APN as length-value labels.
        "internet" -> b'\\x08internet'
        "ims.mnc001.mcc001.3gppnetwork.org" -> labels...
        """
        parts = apn.split('.')
        result = bytearray()
        for part in parts:
            encoded = part.encode('ascii')
            result.append(len(encoded))
            result.extend(encoded)
        return bytes(result)

    @staticmethod
    def _build_pco_request() -> bytes:
        """
        Build Protocol Configuration Options requesting DNS.

        PCO format (TS 24.008 Section 10.5.6.3):
            Configuration protocol: 0x80 (PPP)
            Container: IPCP with DNS request
        """
        # Simple PCO requesting IPv4 DNS via IPCP
        pco = bytearray()
        pco.append(0x80)  # Configuration protocol = PPP

        # Container 1: IPCP (Protocol ID 0x8021)
        # IPCP Configure-Request for Primary DNS (0x81) and Secondary DNS (0x83)
        ipcp_content = bytes([
            0x01,  # Code: Configure-Request
            0x00,  # Identifier
            0x00, 0x10,  # Length: 16
            0x81, 0x06, 0x00, 0x00, 0x00, 0x00,  # Primary DNS: 0.0.0.0 (request)
            0x83, 0x06, 0x00, 0x00, 0x00, 0x00,  # Secondary DNS: 0.0.0.0 (request)
        ])

        pco.extend(b'\x80\x21')  # Protocol ID: IPCP
        pco.append(len(ipcp_content))
        pco.extend(ipcp_content)

        # Container 2: DNS Server IPv4 Address Request (0x000D)
        pco.extend(b'\x00\x0D')  # Protocol ID: DNS Server IPv4
        pco.append(0x00)  # Length: 0 (request)

        return bytes(pco)

    # ================================================================
    # EMM Message Construction
    # ================================================================
    @property
    def selected_eea(self) -> int:
        """EPS Encryption Algorithm selected by MME (0=null, 1=SNOW3G, 2=AES)."""
        return self._selected_eea

    @property
    def selected_eia(self) -> int:
        """EPS Integrity Algorithm selected by MME (0=null, 1=SNOW3G, 2=AES)."""
        return self._selected_eia

    def build_attach_request(self, apn: str = "internet", pdn_type: int = 1) -> bytes:
        """
        Build Attach Request message (TS 24.301 Section 8.2.4).

        Constructs a combined EPS/IMSI attach request with:
            - EPS attach type: combined (0x02)
            - NAS key set: no key available
            - EPS mobile identity: IMSI
            - UE network capability
            - ESM message container: PDN Connectivity Request

        Args:
            apn:      APN for the initial default bearer
            pdn_type: PDN type (1=IPv4, 2=IPv6, 3=IPv4v6)

        Returns:
            Complete NAS message bytes (plain, no security header)
        """
        msg = bytearray()

        # Protocol discriminator (4 bits) = 0x07 (EMM)
        # Security header type (4 bits) = 0x00 (plain)
        msg.append(0x07)

        # Message type
        msg.append(EPSMobilityMessageType.ATTACH_REQUEST)

        # EPS attach type (4 bits) + NAS key set identifier (4 bits)
        # Combined attach (0x02) | No key available (0x07)
        msg.append((NASKeySetIdentifier.NO_KEY_AVAILABLE << 4) |
                    EPSAttachType.COMBINED_ATTACH)

        # EPS mobile identity (IMSI)
        imsi_ie = self._encode_imsi_bcd()
        msg.extend(imsi_ie)

        # UE network capability
        ue_cap = self._encode_ue_network_capability()
        msg.extend(ue_cap)

        # ESM message container
        esm_msg = self.build_pdn_connectivity_request(apn=apn, pdn_type=pdn_type)
        msg.extend(struct.pack('!H', len(esm_msg)))  # 2-byte length
        msg.extend(esm_msg)

        # Optional IEs

        # DRX parameter (IEI = 0x5C) - no specific DRX
        # Not included for simplicity

        # Last visited registered TAI (IEI = 0x52) - not included

        # Additional GUTI (IEI = 0x50) - not included on first attach

        logger.debug("Built Attach Request: %s", msg.hex())
        return bytes(msg)

    def build_authentication_response(self, res: bytes) -> bytes:
        """
        Build Authentication Response (TS 24.301 Section 8.2.8).

        Args:
            res: Authentication response parameter (RES) from Milenage (8 bytes)

        Returns:
            Complete NAS message bytes
        """
        msg = bytearray()

        # Protocol discriminator + Security header (plain)
        msg.append(0x07)

        # Message type
        msg.append(EPSMobilityMessageType.AUTHENTICATION_RESPONSE)

        # Authentication response parameter (RES)
        # Length + value
        msg.append(len(res))
        msg.extend(res)

        logger.debug("Built Authentication Response: RES=%s", res.hex())
        return bytes(msg)

    def build_authentication_failure(self, cause: int, auts: bytes = None) -> bytes:
        """
        Build Authentication Failure (TS 24.301 Section 8.2.5).

        Args:
            cause: EMM cause (0x15 = synch failure, 0x14 = MAC failure)
            auts: AUTS parameter (14 bytes) for synch failure

        Returns:
            Complete NAS message bytes
        """
        msg = bytearray()
        msg.append(0x07)
        msg.append(EPSMobilityMessageType.AUTHENTICATION_FAILURE)
        msg.append(cause)

        if auts is not None and cause == 0x15:  # synch failure
            msg.append(0x30)  # IEI for AUTS
            msg.append(len(auts))
            msg.extend(auts)

        return bytes(msg)

    def build_security_mode_complete(self) -> bytes:
        """
        Build Security Mode Complete (TS 24.301 Section 8.2.21).

        This message is integrity protected and ciphered with the new
        NAS security context.

        Returns:
            Complete NAS message bytes (with security header if context active)
        """
        # Inner (plain) message
        inner = bytearray()
        inner.append(0x07)  # Protocol discriminator (EMM)
        inner.append(EPSMobilityMessageType.SECURITY_MODE_COMPLETE)

        # Optional: IMEISV (IEI = 0x23)
        # Include a dummy IMEISV for completeness
        imeisv = self._encode_imeisv("3578510472563140")
        inner.append(0x23)  # IEI
        inner.extend(imeisv)

        plain_msg = bytes(inner)

        if self._security_active and self._knas_int is not None:
            # Security Mode Complete uses "integrity protected with new context"
            # header type (0x03 for EEA0, 0x04 if ciphered)
            if self._selected_eea == 0:  # EEA0 = null cipher
                sec_type = NASSecurityHeaderType.INTEGRITY_PROTECTED_NEW_CONTEXT
            else:
                sec_type = NASSecurityHeaderType.INTEGRITY_PROTECTED_CIPHERED
            return self._apply_nas_security(plain_msg, sec_type)

        return plain_msg

    def build_attach_complete(self, bearer_id: int = 5) -> bytes:
        """
        Build Attach Complete (TS 24.301 Section 8.2.2).

        Contains ESM: Activate Default EPS Bearer Context Accept.

        Returns:
            Complete NAS message bytes
        """
        inner = bytearray()
        inner.append(0x07)
        inner.append(EPSMobilityMessageType.ATTACH_COMPLETE)

        # ESM message container
        esm = self.build_activate_default_bearer_accept(bearer_id)
        inner.extend(struct.pack('!H', len(esm)))
        inner.extend(esm)

        plain_msg = bytes(inner)

        if self._security_active and self._knas_int is not None:
            return self._apply_nas_security(
                plain_msg,
                NASSecurityHeaderType.INTEGRITY_PROTECTED_CIPHERED
            )

        return plain_msg

    def build_detach_request(self, switch_off: bool = True) -> bytes:
        """
        Build Detach Request (UE-initiated) (TS 24.301 Section 8.2.11).

        Args:
            switch_off: True for power-off detach, False for re-attach

        Returns:
            Complete NAS message bytes
        """
        inner = bytearray()
        inner.append(0x07)
        inner.append(EPSMobilityMessageType.DETACH_REQUEST)

        # Detach type (4 bits) + NAS key set identifier (4 bits)
        # Detach type: bit 4 = switch_off, bits 1-3 = EPS detach (001)
        detach_type = 0x01  # EPS detach
        if switch_off:
            detach_type |= 0x08  # Set switch-off bit
        # Use the KSI from Authentication Request (not NO_KEY_AVAILABLE)
        # so the MME can validate the detach with existing security context
        ksi = self._ksi if self._security_active else NASKeySetIdentifier.NO_KEY_AVAILABLE
        msg_byte = (ksi << 4) | detach_type
        inner.append(msg_byte)

        # EPS mobile identity (GUTI or IMSI)
        imsi_ie = self._encode_imsi_bcd()
        inner.extend(imsi_ie)

        plain_msg = bytes(inner)

        if self._security_active and self._knas_int is not None:
            return self._apply_nas_security(
                plain_msg,
                NASSecurityHeaderType.INTEGRITY_PROTECTED_CIPHERED
            )

        return plain_msg

    def build_identity_response(self) -> bytes:
        """
        Build Identity Response with IMSI (TS 24.301 Section 8.2.19).

        Returns:
            Complete NAS message bytes
        """
        msg = bytearray()
        msg.append(0x07)
        msg.append(EPSMobilityMessageType.IDENTITY_RESPONSE)

        # Mobile identity (IMSI in BCD)
        imsi_ie = self._encode_imsi_bcd()
        msg.extend(imsi_ie)

        return bytes(msg)

    # ================================================================
    # GUTI Encoding Helpers (TS 24.301 §9.9.3.12)
    # ================================================================
    @staticmethod
    def _encode_guti_identity(guti_bytes: bytes) -> bytes:
        """
        Encode GUTI as EPS Mobile Identity IE (LV format, TS 24.301 §9.9.3.12).

        guti_bytes layout (11 bytes):
            [0-2]  MCC/MNC PLMN (3 bytes)
            [3-4]  MMEGI — MME Group ID (2 bytes big-endian)
            [5]    MMEC  — MME Code (1 byte)
            [6-9]  M-TMSI (4 bytes big-endian)

        The encoded IE includes:
            Byte 0:   0xF6 — spare(4 bits) | odd/even=1 | identity type=110 (GUTI)
            Bytes 1-3: PLMN identity
            Bytes 4-5: MMEGI
            Byte 6:   MMEC
            Bytes 7-10: M-TMSI
        Total value: 11 bytes.  LV = length byte (11) + 11 bytes value = 12 bytes.
        """
        if len(guti_bytes) < 10:
            raise ValueError(f"GUTI must be at least 10 bytes, got {len(guti_bytes)}")

        guti_value = bytearray()
        guti_value.append(0xF6)        # spare | even | identity=GUTI(6)
        guti_value.extend(guti_bytes[0:3])   # PLMN
        guti_value.extend(guti_bytes[3:5])   # MMEGI
        guti_value.append(guti_bytes[5])     # MMEC
        guti_value.extend(guti_bytes[6:10])  # M-TMSI

        return bytes([len(guti_value)]) + bytes(guti_value)

    def build_guti_attach_request(self, guti_bytes: bytes, apn: str = "internet") -> bytes:
        """
        Build Attach Request using GUTI identity (subsequent attach).

        Identical to IMSI attach but uses GUTI as the EPS Mobile Identity
        and sets the NAS KSI from the stored security context (not NO_KEY).

        Args:
            guti_bytes: 10-byte GUTI (PLMN 3B + MMEGI 2B + MMEC 1B + M-TMSI 4B)
            apn: APN for the initial default bearer

        Returns:
            Complete NAS message bytes
        """
        msg = bytearray()
        msg.append(0x07)  # PD=EMM, security=plain
        msg.append(EPSMobilityMessageType.ATTACH_REQUEST)

        # EPS attach type (4 bits) + NAS key set identifier (4 bits)
        # Use stored KSI if security context available, else NO_KEY
        ksi = self._ksi if self._security_active else NASKeySetIdentifier.NO_KEY_AVAILABLE
        msg.append((ksi << 4) | EPSAttachType.COMBINED_ATTACH)

        # EPS mobile identity — GUTI
        guti_ie = self._encode_guti_identity(guti_bytes)
        msg.extend(guti_ie)

        # UE network capability
        ue_cap = self._encode_ue_network_capability()
        msg.extend(ue_cap)

        # ESM message container
        esm_msg = self.build_pdn_connectivity_request(apn=apn)
        msg.extend(struct.pack('!H', len(esm_msg)))
        msg.extend(esm_msg)

        logger.debug("Built GUTI Attach Request: guti=%s", guti_bytes.hex())
        return bytes(msg)

    def build_tau_request(
        self,
        guti_bytes: bytes,
        update_type: int = 0x01,
        active_flag: bool = True,
        new_tac: int = None,
        plmn: bytes = None,
    ) -> bytes:
        """
        Build Tracking Area Update Request (TS 24.301 §8.2.29).

        Args:
            guti_bytes:   10-byte GUTI (current identity)
            update_type:  0x00=TA_updating, 0x01=combined_TA/LA_updating, 0x08=periodic
            active_flag:  Set active flag bit (UE has pending data)
            new_tac:      New TAC (for inter-TA test); if None use configured TAC
            plmn:         PLMN override; if None use Config.plmn_bytes()

        Returns:
            Complete NAS message bytes
        """
        from .config import Config

        inner = bytearray()
        inner.append(0x07)  # PD=EMM, plain
        inner.append(EPSMobilityMessageType.TAU_REQUEST)

        # EPS update type (4 bits) + NAS KSI (4 bits)
        # Bit 3 of EPS update type = Active flag
        eps_update = update_type & 0x07
        if active_flag:
            eps_update |= 0x08
        ksi = self._ksi if self._security_active else NASKeySetIdentifier.NO_KEY_AVAILABLE
        inner.append((ksi << 4) | eps_update)

        # Old GUTI — mandatory
        guti_ie = self._encode_guti_identity(guti_bytes)
        inner.extend(guti_ie)

        # UE network capability (mandatory per TS 24.301 Table 8.2.29.1)
        ue_cap = self._encode_ue_network_capability()
        inner.extend(ue_cap)

        # Last visited registered TAI (optional IEI=0x52)
        tac = new_tac if new_tac is not None else Config.TAC
        tai_plmn = plmn if plmn is not None else Config.plmn_bytes()
        inner.append(0x52)  # IEI
        tai_value = tai_plmn + tac.to_bytes(2, 'big')
        inner.append(len(tai_value))
        inner.extend(tai_value)

        plain_msg = bytes(inner)

        if self._security_active and self._knas_int is not None:
            return self._apply_nas_security(
                plain_msg,
                NASSecurityHeaderType.INTEGRITY_PROTECTED_CIPHERED
            )
        return plain_msg

    def build_tau_complete(self) -> bytes:
        """
        Build Tracking Area Update Complete (TS 24.301 §8.2.26).

        Sent after a TAU Accept that includes a new GUTI assignment.
        """
        inner = bytearray()
        inner.append(0x07)
        inner.append(EPSMobilityMessageType.TAU_COMPLETE)
        plain_msg = bytes(inner)

        if self._security_active and self._knas_int is not None:
            return self._apply_nas_security(
                plain_msg,
                NASSecurityHeaderType.INTEGRITY_PROTECTED_CIPHERED
            )
        return plain_msg

    # ================================================================
    # NAS Message Decoding
    # ================================================================
    def decode_message(self, data: bytes) -> Dict[str, Any]:
        """
        Decode a downlink NAS message.

        Args:
            data: Raw NAS message bytes

        Returns:
            Dictionary with parsed fields
        """
        if len(data) < 2:
            return {"error": "Message too short", "raw": data.hex()}

        result = {
            "raw": data.hex(),
            "length": len(data),
        }

        # Check security header
        pd = data[0] & 0x0F
        security_header = (data[0] >> 4) & 0x0F

        if security_header != NASSecurityHeaderType.PLAIN and pd == 0x07:
            # Security-protected message
            result["security_header"] = security_header
            if len(data) >= 7:
                # MAC (4 bytes) + SQN (1 byte) + plain message
                result["mac"] = data[1:5].hex()
                result["sqn"] = data[5]
                # Strip security header to get plain message
                plain_data = data[6:]
                if len(plain_data) >= 2:
                    pd = plain_data[0] & 0x0F
                    data = plain_data
            else:
                # Treat as plain if too short for security header
                pass

        if pd == 0x07:
            # EMM message
            return self._decode_emm(data, result)
        elif pd == 0x02:
            # ESM message
            return self._decode_esm(data, result)
        else:
            result["protocol_discriminator"] = pd
            result["raw"] = data.hex()
            return result

    def _decode_emm(self, data: bytes, result: Dict) -> Dict[str, Any]:
        """Decode an EMM (EPS Mobility Management) message."""
        result["protocol"] = "EMM"
        if len(data) < 2:
            return result

        msg_type = data[1]
        result["message_type"] = msg_type
        result["message_type_name"] = self._emm_type_name(msg_type)

        if msg_type == EPSMobilityMessageType.AUTHENTICATION_REQUEST:
            return self._decode_auth_request(data, result)
        elif msg_type == EPSMobilityMessageType.SECURITY_MODE_COMMAND:
            return self._decode_security_mode_command(data, result)
        elif msg_type == EPSMobilityMessageType.ATTACH_ACCEPT:
            return self._decode_attach_accept(data, result)
        elif msg_type == EPSMobilityMessageType.ATTACH_REJECT:
            return self._decode_attach_reject(data, result)
        elif msg_type == EPSMobilityMessageType.TAU_ACCEPT:
            return self._decode_tau_accept(data, result)
        elif msg_type == EPSMobilityMessageType.TAU_REJECT:
            result["message_type_name"] = "TAU Reject"
            if len(data) > 2:
                result["emm_cause"] = data[2]
                result["emm_cause_name"] = self._emm_cause_name(data[2])
        elif msg_type == EPSMobilityMessageType.IDENTITY_REQUEST:
            return self._decode_identity_request(data, result)
        elif msg_type == EPSMobilityMessageType.EMM_INFORMATION:
            result["info"] = "EMM Information (network name, time, etc.)"
        elif msg_type == EPSMobilityMessageType.DETACH_ACCEPT:
            result["info"] = "Detach Accept"

        return result

    def _decode_auth_request(self, data: bytes, result: Dict) -> Dict[str, Any]:
        """
        Decode Authentication Request (TS 24.301 Section 8.2.7).

        Layout (TS 24.301 Section 8.2.7):
            Byte 0:    PD + Security header type
            Byte 1:    Message type (0x52)
            Byte 2:    NAS key set identifier (4 bits) + spare (4 bits)
            Byte 3-18: RAND (16 bytes, FIXED — no length prefix)
            Byte 19:   AUTN IEI tag (0x10)
            Byte 20:   AUTN length (16)
            Byte 21-36: AUTN (16 bytes)
        """
        result["message_type_name"] = "Authentication Request"

        offset = 2  # after PD + msg_type

        if len(data) < offset + 1:
            return result

        # NAS key set identifier (4 bits + 4 bits spare)
        nksi = data[offset]
        result["nas_key_set_id"] = nksi & 0x07
        self._ksi = nksi & 0x07  # Store KSI for use in detach/TAU
        offset += 1

        # RAND — FIXED 16 bytes, NO length prefix (TS 24.301 Table 8.2.7.1)
        if len(data) < offset + 16:
            logger.error("Auth Request too short for RAND: %d bytes at offset %d (total %d)", len(data), offset, len(data))
            return result
        result["rand"] = data[offset:offset + 16]
        offset += 16

        logger.debug("RAND extracted at offset 3-18: %s, next bytes at offset %d: %s",
                     result["rand"].hex(), offset, data[offset:offset+4].hex() if len(data) > offset else "N/A")

        # AUTN — Mandatory LV IE (Length + Value, NO IEI tag)
        # Per TS 24.301 Table 8.2.7.1: AUTN is type 4 LV (mandatory = no IEI)
        # Byte at offset 19: length (should be 0x10 = 16)
        # Bytes 20-35: AUTN value (16 bytes)
        if len(data) < offset + 1:
            logger.error("Auth Request too short for AUTN length: offset %d, total %d", offset, len(data))
            return result
        autn_len = data[offset]
        offset += 1
        logger.debug("AUTN length byte: 0x%02x (%d) at offset %d", autn_len, autn_len, offset - 1)

        if len(data) < offset + autn_len:
            logger.error("Auth Request too short for AUTN value: need %d at offset %d, total=%d", autn_len, offset, len(data))
            return result
        result["autn"] = data[offset:offset + autn_len]
        offset += autn_len

        logger.info(
            "Decoded Auth Request: RAND=%s AUTN=%s",
            result["rand"].hex(), result["autn"].hex()
        )
        return result

    def _decode_security_mode_command(self, data: bytes, result: Dict) -> Dict[str, Any]:
        """
        Decode Security Mode Command (TS 24.301 Section 8.2.20).

        Layout:
            Byte 0:   PD + Security header
            Byte 1:   Message type (0x5D)
            Byte 2:   Selected NAS security algorithms
            Byte 3:   NAS key set identifier
            Byte 4:   Replayed UE security capabilities length
            Byte 5+:  Replayed UE security capabilities
        """
        result["message_type_name"] = "Security Mode Command"

        offset = 2

        if len(data) < offset + 1:
            return result

        # Selected NAS security algorithms
        alg_byte = data[offset]
        result["selected_eea"] = (alg_byte >> 4) & 0x07
        result["selected_eia"] = alg_byte & 0x07
        self._selected_eea = result["selected_eea"]
        self._selected_eia = result["selected_eia"]
        offset += 1

        # NAS key set identifier
        if len(data) > offset:
            result["nas_key_set_id"] = data[offset] & 0x07
            offset += 1

        # Replayed UE security capabilities
        if len(data) > offset:
            cap_len = data[offset]
            offset += 1
            if len(data) >= offset + cap_len:
                result["replayed_ue_cap"] = data[offset:offset + cap_len].hex()

        logger.info(
            "Decoded Security Mode Command: EEA%d, EIA%d",
            result.get("selected_eea", -1), result.get("selected_eia", -1)
        )
        return result

    def _decode_attach_accept(self, data: bytes, result: Dict) -> Dict[str, Any]:
        """
        Decode Attach Accept (TS 24.301 Section 8.2.1).

        Extracts the assigned IP address from the ESM message container.
        """
        result["message_type_name"] = "Attach Accept"

        offset = 2

        if len(data) < offset + 1:
            return result

        # EPS attach result + spare
        result["eps_attach_result"] = data[offset] & 0x07
        offset += 1

        # T3412 value (GPRS timer)
        if len(data) > offset:
            result["t3412"] = data[offset]
            offset += 1

        # TAI list
        if len(data) > offset:
            tai_len = data[offset]
            offset += 1
            if len(data) >= offset + tai_len:
                result["tai_list"] = data[offset:offset + tai_len].hex()
                offset += tai_len

        # ESM message container
        if len(data) > offset + 1:
            esm_len = struct.unpack('!H', data[offset:offset + 2])[0]
            offset += 2
            if len(data) >= offset + esm_len:
                esm_data = data[offset:offset + esm_len]
                result["esm_container"] = self._decode_esm_container(esm_data)
                offset += esm_len

        # Parse optional IEs for GUTI, etc.
        while offset < len(data):
            if offset >= len(data):
                break
            iei = data[offset]

            if iei == 0x50:  # GUTI
                offset += 1
                if offset < len(data):
                    guti_len = data[offset]
                    offset += 1
                    if offset + guti_len <= len(data):
                        result["guti"] = data[offset:offset + guti_len].hex()
                        offset += guti_len
            elif iei == 0x13:  # EPS network feature support
                offset += 1
                if offset < len(data):
                    feat_len = data[offset]
                    offset += 1 + feat_len
            else:
                # Unknown IE - try to skip by reading length
                offset += 1
                if offset < len(data):
                    ie_len = data[offset]
                    offset += 1 + ie_len
                else:
                    break

        logger.info("Decoded Attach Accept: result=%s", result.get("eps_attach_result"))
        return result

    def _decode_esm_container(self, data: bytes) -> Dict[str, Any]:
        """Decode the ESM message inside an Attach Accept."""
        esm_result = {}
        if len(data) < 3:
            return esm_result

        bearer_id = (data[0] >> 4) & 0x0F
        pti = data[1]
        msg_type = data[2]

        esm_result["bearer_id"] = bearer_id
        esm_result["pti"] = pti
        esm_result["message_type"] = msg_type
        self._bearer_id = bearer_id

        if msg_type == ESMMessageType.ACTIVATE_DEFAULT_BEARER_CTX_REQUEST:
            esm_result["type_name"] = "Activate Default Bearer Context Request"
            offset = 3

            if len(data) > offset:
                # EPS QoS
                qos_len = data[offset]
                offset += 1 + qos_len

            if len(data) > offset:
                # APN
                apn_len = data[offset]
                offset += 1
                if offset + apn_len <= len(data):
                    esm_result["apn"] = self._decode_apn(data[offset:offset + apn_len])
                    offset += apn_len

            if len(data) > offset:
                # PDN address
                pdn_len = data[offset]
                offset += 1
                if offset + pdn_len <= len(data):
                    pdn_data = data[offset:offset + pdn_len]
                    pdn_type = pdn_data[0] & 0x07
                    if pdn_type == 1 and pdn_len >= 5:  # IPv4
                        ip_bytes = pdn_data[1:5]
                        esm_result["ip_address"] = '.'.join(str(b) for b in ip_bytes)
                    elif pdn_type == 2 and pdn_len >= 9:  # IPv6
                        esm_result["ipv6_prefix"] = pdn_data[1:9].hex()
                    elif pdn_type == 3 and pdn_len >= 13:  # IPv4v6
                        esm_result["ip_address"] = '.'.join(str(b) for b in pdn_data[9:13])
                        esm_result["ipv6_prefix"] = pdn_data[1:9].hex()

        return esm_result

    def _decode_tau_accept(self, data: bytes, result: Dict) -> Dict[str, Any]:
        """
        Decode Tracking Area Update Accept (TS 24.301 §8.2.26).

        Extracts the new T3412 timer, assigned GUTI (if present), and TAI list.
        """
        result["message_type_name"] = "TAU Accept"
        offset = 2  # past PD + msg_type

        if len(data) > offset:
            result["eps_update_result"] = data[offset] & 0x07
            offset += 1

        # T3412 (optional IEI=0x5A)
        # TAI list (optional IEI=0x54)
        # GUTI (optional IEI=0x50)
        while offset < len(data):
            iei = data[offset]
            offset += 1

            if iei == 0x54:  # TAI list
                if offset < len(data):
                    tai_len = data[offset]
                    offset += 1
                    if offset + tai_len <= len(data):
                        result["tai_list"] = data[offset:offset + tai_len].hex()
                        offset += tai_len

            elif iei == 0x50:  # New GUTI
                if offset < len(data):
                    guti_len = data[offset]
                    offset += 1
                    if offset + guti_len <= len(data):
                        raw = data[offset:offset + guti_len]
                        result["new_guti"] = raw.hex()
                        # Extract the 10-byte GUTI payload (skip leading 0xF6 type byte)
                        if len(raw) >= 11:
                            result["new_guti_bytes"] = raw[1:11]
                        offset += guti_len

            elif iei == 0x5A:  # T3412 value
                if offset < len(data):
                    result["t3412"] = data[offset]
                    offset += 1

            elif iei == 0x4A:  # Equivalent PLMNs
                if offset < len(data):
                    l = data[offset]; offset += 1 + l

            else:
                # Unknown optional IE — try to skip
                if offset < len(data):
                    ie_len = data[offset]
                    offset += 1 + ie_len
                else:
                    break

        logger.info("Decoded TAU Accept: result=%s new_guti=%s",
                    result.get("eps_update_result"),
                    result.get("new_guti", "(none)"))
        return result

    def _decode_attach_reject(self, data: bytes, result: Dict) -> Dict[str, Any]:
        """Decode Attach Reject."""
        result["message_type_name"] = "Attach Reject"
        if len(data) > 2:
            cause = data[2]
            result["emm_cause"] = cause
            result["emm_cause_name"] = self._emm_cause_name(cause)
            logger.warning("Attach Reject: cause=%d (%s)",
                           cause, result["emm_cause_name"])
        return result

    def _decode_identity_request(self, data: bytes, result: Dict) -> Dict[str, Any]:
        """Decode Identity Request."""
        result["message_type_name"] = "Identity Request"
        if len(data) > 2:
            id_type = data[2] & 0x07
            result["identity_type"] = id_type
            type_names = {1: "IMSI", 2: "IMEI", 3: "IMEISV", 4: "TMSI"}
            result["identity_type_name"] = type_names.get(id_type, f"unknown({id_type})")
        return result

    def _decode_esm(self, data: bytes, result: Dict) -> Dict[str, Any]:
        """Decode a standalone ESM message."""
        result["protocol"] = "ESM"
        if len(data) < 3:
            return result

        bearer_id = (data[0] >> 4) & 0x0F
        pti = data[1]
        msg_type = data[2]

        result["bearer_id"] = bearer_id
        result["pti"] = pti
        result["message_type"] = msg_type

        if msg_type == ESMMessageType.ACTIVATE_DEDICATED_BEARER_CTX_REQUEST:
            result["message_type_name"] = "Activate Dedicated Bearer Context Request"
            self._parse_dedicated_bearer_request(data, result)

        return result

    def _parse_dedicated_bearer_request(self, data: bytes, result: Dict):
        """Parse Activate Dedicated EPS Bearer Context Request."""
        offset = 3
        if len(data) > offset:
            result["linked_bearer_id"] = data[offset] & 0x0F
            offset += 1

        # EPS QoS
        if len(data) > offset:
            qos_len = data[offset]
            offset += 1
            if offset + qos_len <= len(data):
                qos_data = data[offset:offset + qos_len]
                if len(qos_data) >= 1:
                    result["qci"] = qos_data[0]
                offset += qos_len

        # TFT
        if len(data) > offset:
            tft_len = data[offset]
            offset += 1
            if offset + tft_len <= len(data):
                result["tft"] = data[offset:offset + tft_len].hex()
                offset += tft_len

    @staticmethod
    def _decode_apn(data: bytes) -> str:
        """Decode APN from length-prefixed labels."""
        labels = []
        idx = 0
        while idx < len(data):
            label_len = data[idx]
            idx += 1
            if idx + label_len > len(data):
                break
            labels.append(data[idx:idx + label_len].decode('ascii', errors='replace'))
            idx += label_len
        return '.'.join(labels)

    # ================================================================
    # NAS Security
    # ================================================================
    def derive_nas_keys(self, kasme: bytes):
        """
        Derive NAS encryption and integrity keys from KASME.

        Uses KDF per TS 33.401 Annex A.7:
            Knas-enc = KDF(Kasme, algorithm-type-dist=0x01, algorithm-id)
            Knas-int = KDF(Kasme, algorithm-type-dist=0x02, algorithm-id)

        Args:
            kasme: KASME (32 bytes) derived from CK, IK during authentication
        """
        # Derive Knas_enc
        self._knas_enc = self._kdf(kasme, 0x01, self._selected_eea)

        # Derive Knas_int
        self._knas_int = self._kdf(kasme, 0x02, self._selected_eia)

        self._security_active = True
        self._nas_count_ul = 0
        self._nas_count_dl = 0

        logger.info(
            "NAS keys derived: Knas_enc=%s Knas_int=%s",
            self._knas_enc.hex() if self._knas_enc else "none",
            self._knas_int.hex() if self._knas_int else "none",
        )

    @staticmethod
    def _kdf(kasme: bytes, algorithm_type: int, algorithm_id: int) -> bytes:
        """
        Key Derivation Function per TS 33.401 Annex A.7.

        S = FC || P0 || L0 || P1 || L1
        where:
            FC = 0x15 (NAS keys)
            P0 = algorithm type distinguisher (1 byte)
            L0 = 0x0001
            P1 = algorithm identity (1 byte)
            L1 = 0x0001

        Output = HMAC-SHA-256(Kasme, S)[16:32]  (last 16 bytes)
        """
        s = bytes([
            0x15,                          # FC
            algorithm_type, 0x00, 0x01,    # P0 + L0
            algorithm_id, 0x00, 0x01,      # P1 + L1
        ])
        derived = hmac.new(kasme, s, hashlib.sha256).digest()
        return derived[16:32]  # Last 16 bytes

    @staticmethod
    def derive_kasme(ck: bytes, ik: bytes, plmn: bytes, sqn: bytes, ak: bytes) -> bytes:
        """
        Derive KASME from CK, IK per TS 33.401 Annex A.2.

        KASME = KDF(Key, S) where:
            Key = CK || IK
            S = FC || SN_ID || L0 || SQN_XOR_AK || L1
            FC = 0x10
            SN_ID = MCC + MNC (3 bytes PLMN)
            SQN_XOR_AK = 6 bytes
        """
        key = ck + ik
        sqn_xor_ak = bytes(a ^ b for a, b in zip(sqn, ak))

        s = bytes([0x10]) + plmn + b'\x00\x03' + sqn_xor_ak + b'\x00\x06'
        kasme = hmac.new(key, s, hashlib.sha256).digest()

        logger.debug("KASME derived: %s", kasme.hex())
        return kasme

    def _apply_nas_security(self, plain_msg: bytes, header_type: int) -> bytes:
        """
        Apply NAS security (integrity protection and optional ciphering).

        Format: Security header (1) + MAC (4) + SQN (1) + plain NAS message
        """
        sqn_byte = self._nas_count_ul & 0xFF

        # The MAC is computed over: SQN byte + plain NAS message
        # This is the payload that appears after the MAC in the secured message
        # Per TS 24.301 Section 4.4.3.1 and TS 33.401 Annex B
        mac_payload = bytes([sqn_byte]) + plain_msg
        mac = self._compute_nas_mac(mac_payload, self._nas_count_ul, direction=0)

        # Build secured message: header(1) + MAC(4) + SQN(1) + plain_msg
        secured = bytearray()
        secured.append((header_type << 4) | 0x07)  # Security header + EMM PD
        secured.extend(mac)          # 4 bytes MAC
        secured.append(sqn_byte)     # Sequence number
        secured.extend(plain_msg)    # Plain NAS message

        self._nas_count_ul += 1

        return bytes(secured)

    def _compute_nas_mac(self, msg: bytes, sqn: int, direction: int = 0) -> bytes:
        """
        Compute NAS MAC for integrity protection per TS 33.401.

        For EIA0 (null integrity): returns 0x00000000
        For EIA2 (128-EIA2 = AES-CMAC): proper 3GPP NAS integrity algorithm

        The MAC input per TS 33.401 Annex B.2:
            M = COUNT[32] || BEARER[5] || DIRECTION[1] || 0[26] || MESSAGE

        Args:
            msg: The NAS message to protect (plain, without security header)
            sqn: Sequence number (used as part of COUNT)
            direction: 0 = uplink, 1 = downlink
        """
        if self._selected_eia == EIA0 or self._knas_int is None:
            return b'\x00\x00\x00\x00'

        count = self._nas_count_ul if direction == 0 else self._nas_count_dl
        bearer = 0  # NAS uses bearer = 0 (TS 33.401 Section 6.5.4)

        if self._selected_eia == 2:  # EIA2 = AES-CMAC
            return self._eia2_mac(self._knas_int, count, bearer, direction, msg)
        elif self._selected_eia == 1:  # EIA1 = SNOW 3G (not implemented, use EIA2)
            return self._eia2_mac(self._knas_int, count, bearer, direction, msg)
        else:
            return b'\x00\x00\x00\x00'

    @staticmethod
    def _eia2_mac(key: bytes, count: int, bearer: int, direction: int, msg: bytes) -> bytes:
        """
        128-EIA2 (AES-CMAC based) per TS 33.401 Annex B.2.

        Input to CMAC:
            M = COUNT (4 bytes) || BEARER (5 bits) || DIRECTION (1 bit) || 0 (26 bits padding) || MESSAGE

        The first 8 bytes form:
            Byte 0-3: COUNT (big-endian 32-bit)
            Byte 4:   BEARER (5 bits) << 3 | DIRECTION (1 bit) << 2 | 0 (2 bits)
            Byte 5-7: 0x000000 (padding to 64 bits)

        Returns: 4-byte MAC (first 4 bytes of CMAC output)
        """
        from cryptography.hazmat.primitives.cmac import CMAC
        from cryptography.hazmat.primitives.ciphers.algorithms import AES

        # Build the input M per TS 33.401
        m = bytearray()
        m.extend(struct.pack('!I', count))      # COUNT: 4 bytes big-endian
        m.append(((bearer & 0x1F) << 3) | ((direction & 0x01) << 2))  # BEARER(5) | DIR(1) | pad(2)
        m.extend(b'\x00\x00\x00')              # 24 more padding bits (total 26 padding bits)
        m.extend(msg)                            # The NAS message

        # Compute AES-CMAC
        c = CMAC(AES(key))
        c.update(bytes(m))
        mac = c.finalize()

        logger.debug("EIA2 MAC: count=%d bearer=%d dir=%d msg_len=%d -> MAC=%s",
                     count, bearer, direction, len(msg), mac[:4].hex())

        return mac[:4]

    def increment_dl_count(self):
        """Increment the downlink NAS count after receiving a secured message."""
        self._nas_count_dl += 1

    @property
    def security_active(self) -> bool:
        """Whether NAS security context is established."""
        return self._security_active

    @property
    def bearer_id(self) -> int:
        """Current default EPS bearer ID."""
        return self._bearer_id

    # ================================================================
    # Helper: IMEISV encoding
    # ================================================================
    @staticmethod
    def _encode_imeisv(imeisv: str) -> bytes:
        """
        Encode IMEISV in BCD format.

        IMEISV = 16 digits. First byte: digit1 | type (0x03 for IMEISV) | even indicator.
        """
        result = bytearray()
        first_digit = int(imeisv[0])
        result.append((first_digit << 4) | 0x03)  # IMEISV type, even

        idx = 1
        while idx < len(imeisv):
            low = int(imeisv[idx])
            high = int(imeisv[idx + 1]) if idx + 1 < len(imeisv) else 0x0F
            result.append((high << 4) | low)
            idx += 2

        return bytes([len(result)]) + bytes(result)

    # ================================================================
    # Name lookups
    # ================================================================
    @staticmethod
    def _emm_type_name(msg_type: int) -> str:
        """Human-readable name for EMM message type."""
        names = {
            0x41: "Attach Request",
            0x42: "Attach Accept",
            0x43: "Attach Complete",
            0x44: "Attach Reject",
            0x45: "Detach Request",
            0x46: "Detach Accept",
            0x48: "TAU Request",
            0x49: "TAU Accept",
            0x4A: "TAU Reject",
            0x4B: "TAU Complete",
            0x52: "Authentication Request",
            0x53: "Authentication Response",
            0x54: "Authentication Reject",
            0x5C: "Authentication Failure",
            0x5D: "Security Mode Command",
            0x5E: "Security Mode Complete",
            0x5F: "Security Mode Reject",
            0x61: "EMM Information",
            0x4D: "Service Request",
            0x55: "Identity Request",
            0x56: "Identity Response",
        }
        return names.get(msg_type, f"Unknown(0x{msg_type:02X})")

    @staticmethod
    def _emm_cause_name(cause: int) -> str:
        """Human-readable name for EMM cause value."""
        causes = {
            0x02: "IMSI unknown in HSS",
            0x03: "Illegal UE",
            0x04: "IMSI unknown in VLR",
            0x05: "IMEI not accepted",
            0x06: "Illegal ME",
            0x07: "EPS services not allowed",
            0x08: "EPS services and non-EPS services not allowed",
            0x09: "UE identity cannot be derived by the network",
            0x0A: "Implicitly detached",
            0x0B: "PLMN not allowed",
            0x0C: "Tracking area not allowed",
            0x0D: "Roaming not allowed in this tracking area",
            0x0E: "EPS services not allowed in this PLMN",
            0x0F: "No suitable cells in tracking area",
            0x10: "MSC temporarily not reachable",
            0x11: "Network failure",
            0x12: "CS domain not available",
            0x13: "ESM failure",
            0x14: "MAC failure",
            0x15: "Synchronization failure",
            0x16: "Congestion",
            0x17: "UE security capabilities mismatch",
            0x18: "Security mode rejected unspecified",
            0x19: "Not authorized for this CSG",
            0x1A: "Non-EPS authentication unacceptable",
            0x1F: "Redirection to 5GCN required",
            0x23: "Requested service option not authorized in this PLMN",
            0x24: "IAB-node operation not authorized",
            0x27: "CS service temporarily not available",
            0x28: "No EPS bearer context activated",
            0x2A: "Severe network failure",
            0x4E: "PLMN not allowed to operate at the present UE location",
            0x50: (
                "Disaster roaming for the determined PLMN with disaster "
                "condition not allowed"
            ),
            0x53: (
                "Procedure cannot be completed due to unavailable feeder "
                "link while MME is operating in S&F mode"
            ),
            0x5F: "Semantically incorrect message",
            0x60: "Invalid mandatory information",
            0x61: "Message type non-existent or not implemented",
            0x62: "Message type not compatible with protocol state",
            0x63: "Information element non-existent or not implemented",
            0x64: "Conditional IE error",
            0x65: "Message not compatible with protocol state",
            0x6F: "Protocol error unspecified",
        }
        return causes.get(cause, "Unassigned or future EMM cause")


if __name__ == "__main__":
    logging.basicConfig(level=logging.DEBUG)

    # Test encoding
    nas = NASHandler("001019876540700")

    attach_req = nas.build_attach_request("internet")
    print(f"Attach Request ({len(attach_req)} bytes): {attach_req.hex()}")

    auth_resp = nas.build_authentication_response(bytes.fromhex("a54211d5e3ba50bf"))
    print(f"Auth Response ({len(auth_resp)} bytes): {auth_resp.hex()}")

    sec_complete = nas.build_security_mode_complete()
    print(f"Security Mode Complete ({len(sec_complete)} bytes): {sec_complete.hex()}")

    # Test decoding
    # Simulated Authentication Request
    auth_req_data = bytes.fromhex(
        "07"   # PD=EMM, security=plain
        "52"   # Authentication Request
        "00"   # NAS KSI
        "10"   # RAND length = 16
        + "23553cbe9637a89d218ae64dae47bf35"  # RAND
        + "10"  # AUTN length = 16
        + "55121c3c5e2b24a0b9b9fac354dfafb3"  # AUTN (fabricated)
    )
    decoded = nas.decode_message(auth_req_data)
    print(f"Decoded: {decoded}")
