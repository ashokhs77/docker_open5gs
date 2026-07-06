"""
Configuration for UE/eNB Simulator

All values can be overridden via environment variables. Defaults match the
Lekha Wireless docker_open5gs test stack.
"""

import os
import logging
from dataclasses import dataclass, field
from typing import List

logger = logging.getLogger(__name__)


@dataclass
class SubscriberConfig:
    """Configuration for a single test subscriber (UE)."""
    imsi: str
    ki: str          # hex, 32 chars = 16 bytes
    opc: str         # hex, 32 chars = 16 bytes
    amf: str = "8000"  # hex, 4 chars = 2 bytes
    msisdn: str = ""
    imei_sv: str = ""  # IMEI-SV (16 digits) for +sip.instance in Contact header
    apn_internet: str = "internet"
    apn_ims: str = "ims"

    @property
    def ki_bytes(self) -> bytes:
        return bytes.fromhex(self.ki)

    @property
    def opc_bytes(self) -> bytes:
        """Return OPc bytes.

        PyHSS algo=3 stores the 'opc' field as OPc directly (already derived).
        We use it as-is without further derivation.
        """
        return bytes.fromhex(self.opc)

    @property
    def amf_bytes(self) -> bytes:
        return bytes.fromhex(self.amf)

    @property
    def imei_urn(self) -> str:
        """URN for +sip.instance based on IMEI-SV (TS 23.003 §13.3)."""
        if not self.imei_sv or len(self.imei_sv) < 14:
            return ""
        # Format: urn:gsma:imei:TTTTTTTT-SSSSSS-V  (TAC-SNR-SVN)
        tac = self.imei_sv[:8]
        snr = self.imei_sv[8:14]
        svn = self.imei_sv[14:16] if len(self.imei_sv) >= 16 else "0"
        return f"urn:gsma:imei:{tac[:8]}-{snr}-{svn}"

    @property
    def sip_uri(self) -> str:
        """SIP URI based on MSISDN or IMSI."""
        identity = self.msisdn if self.msisdn else self.imsi
        return f"sip:{identity}@{Config.IMS_DOMAIN}"

    @property
    def tel_uri(self) -> str:
        """tel: URI based on MSISDN."""
        return f"tel:{self.msisdn}" if self.msisdn else f"tel:{self.imsi}"


class Config:
    """
    Central configuration loaded from environment variables.

    All class attributes are populated at module load time and can be
    overridden by setting the corresponding environment variable.
    """

    # ----------------------------------------------------------------
    # EPC / MME
    # ----------------------------------------------------------------
    MME_IP: str = os.getenv("MME_IP", "172.22.1.9")
    MME_PORT: int = int(os.getenv("MME_PORT", "36412"))

    # ----------------------------------------------------------------
    # PLMN identity
    # ----------------------------------------------------------------
    MCC: str = os.getenv("MCC", "001")
    MNC: str = os.getenv("MNC", "01")
    TAC: int = int(os.getenv("TAC", "1"))
    MME_GID: int = int(os.getenv("MME_GID", "2"))
    MME_CODE: int = int(os.getenv("MME_CODE", "1"))
    NETWORK_NAME: str = os.getenv("NETWORK_NAME", "Lekha Wireless")

    # ----------------------------------------------------------------
    # eNB parameters
    # ----------------------------------------------------------------
    ENB_ID: int = int(os.getenv("ENB_ID", "0x12345"), 0)  # 20-bit macro eNB ID
    ENB_NAME: str = os.getenv("ENB_NAME", "SIPp-Test-eNB")
    CELL_ID: int = int(os.getenv("CELL_ID", "0x12345"), 0)  # 28-bit cell ID
    PAGING_DRX: str = os.getenv("PAGING_DRX", "v128")

    # ----------------------------------------------------------------
    # IMS / SIP
    # ----------------------------------------------------------------
    PCSCF_IP: str = os.getenv("PCSCF_IP", "172.22.1.21")
    PCSCF_PORT: int = int(os.getenv("PCSCF_PORT", "5060"))
    ICSCF_IP: str = os.getenv("ICSCF_IP", "172.22.1.19")
    ICSCF_PORT: int = int(os.getenv("ICSCF_PORT", "4060"))
    SCSCF_IP: str = os.getenv("SCSCF_IP", "172.22.1.20")
    SCSCF_PORT: int = int(os.getenv("SCSCF_PORT", "6060"))
    IMS_DOMAIN: str = os.getenv("IMS_DOMAIN", "ims.mnc001.mcc001.3gppnetwork.org")

    # ----------------------------------------------------------------
    # PyHSS
    # ----------------------------------------------------------------
    PYHSS_IP: str = os.getenv("PYHSS_IP", "172.22.1.18")
    PYHSS_REST_PORT: int = int(os.getenv("PYHSS_REST_PORT", "8080"))
    PYHSS_DIAMETER_PORT: int = int(os.getenv("PYHSS_DIAMETER_PORT", "3868"))

    # ----------------------------------------------------------------
    # DNS
    # ----------------------------------------------------------------
    DNS_IP: str = os.getenv("DNS_IP", "172.22.1.17")

    # ----------------------------------------------------------------
    # IP address pools
    # ----------------------------------------------------------------
    UE_IPV4_INTERNET_POOL: str = os.getenv("UE_IPV4_INTERNET_POOL", "10.45.0.0/16")
    UE_IPV4_IMS_POOL: str = os.getenv("UE_IPV4_IMS_POOL", "10.46.0.0/16")

    # ----------------------------------------------------------------
    # NAS algorithm capability presets (UE Network Capability overrides)
    # Used to force specific ciphering/integrity algorithm negotiation.
    #
    # EPS-EEA byte (byte 1): bit8=EEA0, bit7=EEA1(SNOW3G), bit6=EEA2(AES)
    # EPS-EIA byte (byte 2): bit8=EIA0, bit7=EIA1(SNOW3G), bit6=EIA2(AES)
    # Full 4-byte field per TS 24.301 §9.9.3.34
    # ----------------------------------------------------------------
    # All algorithms (default): EEA0+EEA1+EEA2, EIA1+EIA2
    UE_CAP_ALL_ALGOS: bytes = bytes([0xE0, 0x60, 0xC0, 0x60])
    # SNOW3G only: EEA0+EEA1, EIA1  — MME must pick EEA1/EIA1
    UE_CAP_SNOW3G_ONLY: bytes = bytes([0xC0, 0x60, 0xC0, 0x60])
    # AES only: EEA0+EEA2, EIA2  — MME must pick EEA2/EIA2
    UE_CAP_AES_ONLY: bytes = bytes([0xA0, 0x20, 0xC0, 0x60])
    # Null cipher only: EEA0, EIA1+EIA2  — negative / null-cipher test
    UE_CAP_NULL_CIPHER: bytes = bytes([0x80, 0x60, 0xC0, 0x60])

    # ----------------------------------------------------------------
    # PDN type constants (TS 24.301 §9.9.4.10)
    # ----------------------------------------------------------------
    PDN_TYPE_IPV4: int = 1
    PDN_TYPE_IPV6: int = 2
    PDN_TYPE_IPV4V6: int = 3

    # ----------------------------------------------------------------
    # Simulator tuning
    # ----------------------------------------------------------------
    S1AP_TIMEOUT: float = float(os.getenv("S1AP_TIMEOUT", "20.0"))
    SIP_TIMEOUT: float = float(os.getenv("SIP_TIMEOUT", "20.0"))
    LOG_LEVEL: str = os.getenv("LOG_LEVEL", "INFO")
    LOCAL_IP: str = os.getenv("LOCAL_IP", "0.0.0.0")
    SIP_LOCAL_PORT_BASE: int = int(os.getenv("SIP_LOCAL_PORT_BASE", "15060"))

    # ----------------------------------------------------------------
    # Multi-eNB scaling
    # UEs are distributed across multiple virtual eNBs so that the MME
    # can process their S1AP attach chains in parallel (each eNB has its
    # own SCTP association and independent NAS state machine context).
    #
    # UES_PER_ENB: override value when set explicitly in the environment.
    # When unset, run_load_test() auto-calculates based on num_ues:
    #   ≤  10 UEs → 1 UE/eNB  (each UE its own SCTP — max MME parallelism)
    #   ≤  64 UEs → 4 UEs/eNB (up to 16 concurrent eNBs)
    #   ≤ 256 UEs → 16 UEs/eNB (up to 16 concurrent eNBs)
    #   > 256 UEs → 32 UEs/eNB (1024 UEs = 32 eNBs × 32 UEs each)
    #
    # This value is used as fallback only when UES_PER_ENB env var is set.
    # ----------------------------------------------------------------
    UES_PER_ENB: int = int(os.getenv("UES_PER_ENB", "32"))

    # eNB ID base: each virtual eNB gets ENB_ID_BASE + index (20-bit eNB ID space)
    ENB_ID_BASE: int = int(os.getenv("ENB_ID_BASE", "0x12340"), 0)

    # ----------------------------------------------------------------
    # PLMN encoding helpers
    # ----------------------------------------------------------------
    @classmethod
    def plmn_bytes(cls) -> bytes:
        """
        Encode MCC+MNC into 3-byte PLMN identity per 3GPP TS 24.008.

        For MCC=001, MNC=01:
            Byte 1: MCC digit 2 | MCC digit 1 = 0x00
            Byte 2: MNC digit 3 | MCC digit 3 = 0xF1  (F = filler for 2-digit MNC)
            Byte 3: MNC digit 2 | MNC digit 1 = 0x10
        """
        mcc = cls.MCC.zfill(3)
        mnc = cls.MNC.zfill(2)

        if len(mnc) == 2:
            # 2-digit MNC: MCC2|MCC1, 0xF|MCC3, MNC2|MNC1
            b1 = (int(mcc[1]) << 4) | int(mcc[0])
            b2 = 0xF0 | int(mcc[2])
            b3 = (int(mnc[1]) << 4) | int(mnc[0])
        else:
            # 3-digit MNC: MCC2|MCC1, MNC3|MCC3, MNC2|MNC1
            b1 = (int(mcc[1]) << 4) | int(mcc[0])
            b2 = (int(mnc[2]) << 4) | int(mcc[2])
            b3 = (int(mnc[1]) << 4) | int(mnc[0])

        return bytes([b1, b2, b3])

    @classmethod
    def tac_bytes(cls) -> bytes:
        """Encode TAC as 2 bytes big-endian."""
        return cls.TAC.to_bytes(2, 'big')

    # ----------------------------------------------------------------
    # Test subscribers
    # ----------------------------------------------------------------
    @classmethod
    def default_subscribers(cls) -> List[SubscriberConfig]:
        """Return the three default test subscribers."""
        return [
            SubscriberConfig(
                imsi="001019876540700",
                ki="8baf473f2f8fd09487cccbd7097c6862",
                opc="8E27B6AF0E692E750F32667A3B14605D",
                amf="8000",
                msisdn="9876540700",
                imei_sv="3569380356438001",
            ),
            SubscriberConfig(
                imsi="001019876541000",
                ki="8baf473f2f8fd09487cccbd7097c6863",
                opc="8E27B6AF0E692E750F32667A3B14605D",
                amf="8000",
                msisdn="9876541000",
                imei_sv="3569380356438002",
            ),
            SubscriberConfig(
                imsi="001019876542000",
                ki="8baf473f2f8fd09487cccbd7097c6864",
                opc="8E27B6AF0E692E750F32667A3B14605D",
                amf="8000",
                msisdn="9876542000",
                imei_sv="3569380356438003",
            ),
        ]

    @classmethod
    def log_config(cls):
        """Log the current configuration at INFO level."""
        logger.info("=== UE Simulator Configuration ===")
        logger.info("MME:        %s:%d", cls.MME_IP, cls.MME_PORT)
        logger.info("PLMN:       MCC=%s MNC=%s TAC=%d", cls.MCC, cls.MNC, cls.TAC)
        logger.info("eNB:        ID=0x%05X Name=%s", cls.ENB_ID, cls.ENB_NAME)
        logger.info("P-CSCF:     %s:%d", cls.PCSCF_IP, cls.PCSCF_PORT)
        logger.info("I-CSCF:     %s:%d", cls.ICSCF_IP, cls.ICSCF_PORT)
        logger.info("S-CSCF:     %s:%d", cls.SCSCF_IP, cls.SCSCF_PORT)
        logger.info("IMS Domain: %s", cls.IMS_DOMAIN)
        logger.info("PyHSS:      %s:%d (REST) :%d (Diameter)",
                     cls.PYHSS_IP, cls.PYHSS_REST_PORT, cls.PYHSS_DIAMETER_PORT)
        logger.info("Network:    %s", cls.NETWORK_NAME)
        logger.info("==================================")


def setup_logging(level: str = None):
    """Configure logging for the simulator."""
    if level is None:
        level = Config.LOG_LEVEL

    numeric_level = getattr(logging, level.upper(), logging.INFO)
    logging.basicConfig(
        level=numeric_level,
        format="%(asctime)s [%(name)-20s] %(levelname)-7s %(message)s",
        datefmt="%Y-%m-%d %H:%M:%S",
    )
    # Suppress noisy libraries
    logging.getLogger("cryptography").setLevel(logging.WARNING)


if __name__ == "__main__":
    setup_logging("DEBUG")
    Config.log_config()
    print(f"PLMN bytes: {Config.plmn_bytes().hex()}")
    print(f"TAC bytes:  {Config.tac_bytes().hex()}")
    for sub in Config.default_subscribers():
        print(f"  {sub.imsi} -> {sub.sip_uri}")
