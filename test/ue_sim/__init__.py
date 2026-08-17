"""
UE/eNB Simulator for Open5GS EPC + IMS Testing

Provides a complete Python-based UE simulator that exercises the full
EPC attach and IMS registration/call chain without real hardware.

Components:
    milenage    - 3GPP Milenage AKA authentication (TS 35.206)
    nas_handler - NAS message encoding/decoding (TS 24.301)
    s1ap_client - SCTP-based S1AP client toward MME (TS 36.413)
    sip_client  - SIP UA with AKA auth for IMS registration and VoLTE/ViLTE calls
    ue_simulator- Main orchestrator tying all layers together
    config      - Environment-driven configuration
"""

__version__ = "1.0.0"
__author__ = "Lekha Wireless Test Framework"

from .config import Config
from .milenage import Milenage

# The 4G orchestrator pulls in the whole S1AP/NAS/SIP stack. Import it lazily so
# the standalone 5G modules (keys5g/nas5g/ngap_client/ue5g_simulator) can be run
# via `python -m ue_sim.ue5g_simulator` without requiring the 4G stack to load.
try:
    from .ue_simulator import UESimulator
    __all__ = ["Config", "Milenage", "UESimulator"]
except Exception:  # pragma: no cover - 4G stack optional for 5G-only use
    UESimulator = None
    __all__ = ["Config", "Milenage"]
