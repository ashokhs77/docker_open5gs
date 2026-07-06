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
from .ue_simulator import UESimulator

__all__ = ["Config", "Milenage", "UESimulator"]
