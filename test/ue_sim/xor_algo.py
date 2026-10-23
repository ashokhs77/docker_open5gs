"""
UE-side 3GPP XOR test authentication algorithm (TS 34.108 section 8.1.2).

The algorithm of test USIMs / eSIM profiles provisioned with sim_algo "xor"
(e.g. Amarisoft test profiles). It uses no OP/OPc:

    XDOUT = K xor RAND
    MAC   = XDOUT[0..7] xor (SQN || AMF)        f1 (f1* with AMF* = 0000)
    RES   = XDOUT[0..res_len-1]                 f2
    CK    = XDOUT rotated left by 1 byte        f3
    IK    = XDOUT rotated left by 2 bytes       f4
    AK    = XDOUT[3..8]                         f5 (and f5*)

XorAlgo offers the methods the simulator calls on its Milenage object
(authenticate, authenticate_ims, f5, compute_auts), so UESimulator and SIPClient
can use either. It is written independently of PyHSS's implementation on purpose:
the sim_algo tests use it to check the vectors PyHSS produces.
"""

import logging
from typing import Tuple

from .milenage import Milenage, xor, rotate

logger = logging.getLogger(__name__)

DEFAULT_RES_LEN = 8
SUPPORTED_ALGOS = ("milenage", "xor")


class XorAlgo:
    """XOR test algorithm, duck-type compatible with ue_sim.milenage.Milenage."""

    def __init__(self, key: bytes, amf: bytes = b'\x80\x00', res_len: int = DEFAULT_RES_LEN):
        if len(key) != 16:
            raise ValueError(f"XOR test algorithm needs a 128-bit K, got {len(key)} bytes")
        if not 4 <= res_len <= 16:
            raise ValueError(f"RES length must be 4..16 bytes, got {res_len}")
        self._key = key
        self._amf = amf
        self._res_len = res_len
        # Result of the last AUTN check. Like Milenage in this simulator, a MAC
        # mismatch is logged and the response is still sent (the MME judges RES);
        # tests read this flag when they need to know what the UE saw.
        self.last_mac_ok = None

    @classmethod
    def from_hex(cls, ki_hex: str, opc_hex: str = "", amf_hex: str = "8000",
                 res_len: int = DEFAULT_RES_LEN) -> 'XorAlgo':
        """Create from hex credentials. opc_hex is accepted and ignored."""
        return cls(bytes.fromhex(ki_hex), bytes.fromhex(amf_hex), res_len)

    def _xdout(self, rand: bytes) -> bytes:
        if len(rand) != 16:
            raise ValueError(f"RAND must be 16 bytes, got {len(rand)}")
        return xor(self._key, rand)

    def f1(self, sqn: bytes, rand: bytes, amf: bytes) -> bytes:
        """MAC-A (or MAC-S when amf is AMF* = 0000)."""
        return xor(self._xdout(rand)[:8], sqn[0:6] + amf[0:2])

    def f2(self, rand: bytes) -> bytes:
        return self._xdout(rand)[:self._res_len]

    def f3(self, rand: bytes) -> bytes:
        return rotate(self._xdout(rand), 1)

    def f4(self, rand: bytes) -> bytes:
        return rotate(self._xdout(rand), 2)

    def f5(self, rand: bytes) -> bytes:
        """Anonymity key AK (same function serves as f5*)."""
        return self._xdout(rand)[3:9]

    def authenticate(self, rand: bytes, autn: bytes) -> Tuple[bytes, bytes, bytes]:
        """Check AUTN and return (RES, CK, IK)."""
        if len(autn) != 16:
            raise ValueError(f"AUTN must be 16 bytes, got {len(autn)}")
        sqn = xor(autn[0:6], self.f5(rand))
        amf = autn[6:8]
        expected_mac = self.f1(sqn, rand, amf)
        self.last_mac_ok = (expected_mac == autn[8:16])
        if not self.last_mac_ok:
            logger.warning("XOR MAC mismatch (test mode): computed=%s network=%s",
                           expected_mac.hex(), autn[8:16].hex())
        res, ck, ik = self.f2(rand), self.f3(rand), self.f4(rand)
        logger.info("XOR auth: RES=%s CK=%s IK=%s", res.hex(), ck.hex(), ik.hex())
        return res, ck, ik

    def authenticate_ims(self, rand: bytes, autn: bytes) -> Tuple[bytes, bytes, bytes]:
        return self.authenticate(rand, autn)

    def derive_kasme(self, rand: bytes, autn: bytes, plmn: bytes) -> bytes:
        ak = self.f5(rand)
        sqn = xor(autn[0:6], ak)
        return Milenage.generate_kasme(self.f3(rand), self.f4(rand), plmn, sqn, ak)

    def compute_auts(self, rand: bytes, sqn_ue: bytes) -> bytes:
        """AUTS = (SQN_UE xor AK) || MAC-S, MAC-S computed with AMF* = 0000."""
        if len(sqn_ue) != 6:
            raise ValueError(f"SQN_UE must be 6 bytes, got {len(sqn_ue)}")
        auts = xor(sqn_ue, self.f5(rand)) + self.f1(sqn_ue, rand, b'\x00\x00')
        logger.info("XOR AUTS computed: SQN_UE=%s AUTS=%s", sqn_ue.hex(), auts.hex())
        return auts


def make_auth_algo(name: str, ki_hex: str, opc_hex: str, amf_hex: str = "8000",
                   res_len: int = None):
    """Return the UE-side algorithm object for 'milenage' (default) or 'xor'."""
    algo = (name or "milenage").strip().lower()
    if algo == "xor":
        return XorAlgo.from_hex(ki_hex, opc_hex, amf_hex,
                                res_len if res_len is not None else DEFAULT_RES_LEN)
    if algo == "milenage":
        return Milenage.from_hex(ki_hex, opc_hex, amf_hex)
    raise ValueError(f"Unknown auth algorithm '{name}' (supported: {', '.join(SUPPORTED_ALGOS)})")
