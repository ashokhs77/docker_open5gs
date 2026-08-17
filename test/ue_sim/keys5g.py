"""
5G-AKA key hierarchy, SUCI and NAS-security key derivation (TS 33.501).

This is the 5G counterpart of the EPS-AKA / KASME logic in ``milenage.py``.
The underlying Milenage functions (f1-f5, CK, IK, RES, AK) are *identical*
between EPS-AKA and 5G-AKA, so this module reuses :class:`Milenage` and only
adds the 5G-specific hierarchy on top:

    CK, IK  --(A.2, FC=0x6A)-->  KAUSF
    KAUSF   --(A.6, FC=0x6C)-->  KSEAF
    KSEAF   --(A.7, FC=0x6D)-->  KAMF
    KAMF    --(A.8, FC=0x69)-->  KNASenc / KNASint
    CK, IK  --(A.4, FC=0x6B)-->  RES*          (sent in Authentication Response)

All derivations use the generic KDF of TS 33.220 Annex B.2.1:

    derived_key = HMAC-SHA-256(Key, S)
    S = FC || P0 || L0 || P1 || L1 || ... || Pn || Ln

where FC is one octet, each Pi is a parameter and each Li is the two-octet
big-endian length of Pi.

References:
  * 3GPP TS 33.501 Annex A (key derivation functions)
  * 3GPP TS 33.220 Annex B.2 (generic KDF)
  * 3GPP TS 23.003 clause 2.2B / 28.7.3 (SUPI, SUCI)

Everything here is deterministic and unit-testable in isolation (see the
``__main__`` self-test at the bottom). Byte-exactness with the open5gs AMF is
what ultimately matters, and is validated live once wired into the simulator.
"""

import hashlib
import hmac
from typing import Tuple

from .milenage import Milenage

# ---------------------------------------------------------------------------
# FC (Function Code) constants - TS 33.501 Annex A
# ---------------------------------------------------------------------------
FC_KAUSF = 0x6A        # A.2  KAUSF  <- CK||IK
FC_RES_STAR = 0x6B     # A.4  RES*   <- CK||IK
FC_KSEAF = 0x6C        # A.6  KSEAF  <- KAUSF
FC_KAMF = 0x6D         # A.7  KAMF   <- KSEAF
FC_ALGORITHM_KEY = 0x69  # A.8  KNASenc / KNASint <- KAMF

# Algorithm type distinguishers - TS 33.501 A.8 (same values as TS 33.401)
N_NAS_ENC_ALG = 0x01
N_NAS_INT_ALG = 0x02
N_RRC_ENC_ALG = 0x03
N_RRC_INT_ALG = 0x04
N_UP_ENC_ALG = 0x05
N_UP_INT_ALG = 0x06

# Algorithm identities (NEA / NIA), TS 33.501 clause 5.11
NEA0 = 0x00            # null ciphering
NEA1 = 0x01
NEA2 = 0x02
NEA3 = 0x03
NIA0 = 0x00            # null integrity
NIA1 = 0x01
NIA2 = 0x02            # 128-NIA2 (AES-CMAC) - what open5gs prefers
NIA3 = 0x03

# ABBA parameter - a single ABBA value of 0x0000 is used in this release
# (TS 33.501 clause 6.9.3 / Annex A.7.1).
ABBA_DEFAULT = b"\x00\x00"


# ---------------------------------------------------------------------------
# Generic KDF (TS 33.220 Annex B.2.1)
# ---------------------------------------------------------------------------
def kdf(key: bytes, fc: int, *params: bytes) -> bytes:
    """Generic 3GPP key derivation function.

    Args:
        key: the input key (K) for HMAC-SHA-256.
        fc:  the one-octet Function Code.
        *params: the parameters P0, P1, ... (each is appended as Pi||Li,
                 where Li is the 2-octet big-endian length of Pi).

    Returns:
        The 32-byte HMAC-SHA-256 output.
    """
    s = bytes([fc])
    for p in params:
        s += p + len(p).to_bytes(2, "big")
    return hmac.new(key, s, hashlib.sha256).digest()


# ---------------------------------------------------------------------------
# Serving Network Name (SNN) - TS 24.501 / TS 33.501
# ---------------------------------------------------------------------------
def build_snn(mcc: str, mnc: str) -> bytes:
    """Build the Serving Network Name.

    Format: ``5G:mnc<MNC>.mcc<MCC>.3gppnetwork.org`` where MNC is always
    3 digits (a 2-digit MNC is left-padded with a single ``0``) and MCC is
    3 digits.
    """
    mcc = str(mcc).zfill(3)
    mnc = str(mnc)
    if len(mnc) == 2:
        mnc = "0" + mnc
    mnc = mnc.zfill(3)
    return f"5G:mnc{mnc}.mcc{mcc}.3gppnetwork.org".encode("ascii")


# ---------------------------------------------------------------------------
# BCD / PLMN helpers (TS 24.008 / TS 24.501)
# ---------------------------------------------------------------------------
def encode_plmn(mcc: str, mnc: str) -> bytes:
    """Encode MCC/MNC as the 3-octet PLMN (MCC/MNC) used in NAS IEs.

    Octet layout (nibble-swapped BCD):
        octet1: MCC digit2 | MCC digit1
        octet2: MNC digit3 | MCC digit3   (MNC digit3 = 0xF for 2-digit MNC)
        octet3: MNC digit2 | MNC digit1
    """
    mcc = str(mcc).zfill(3)
    mnc = str(mnc)
    m = [int(d) for d in mcc]
    if len(mnc) == 2:
        n = [int(mnc[0]), int(mnc[1]), 0xF]  # 2-digit MNC -> filler nibble
    else:
        mnc = mnc.zfill(3)
        n = [int(mnc[0]), int(mnc[1]), int(mnc[2])]
    octet1 = (m[1] << 4) | m[0]
    octet2 = (n[2] << 4) | m[2]
    octet3 = (n[1] << 4) | n[0]
    return bytes([octet1, octet2, octet3])


def _bcd_digits(digits: str) -> bytes:
    """Nibble-swapped BCD of a digit string (odd length -> high nibble 0xF)."""
    ds = [int(d) for d in digits]
    if len(ds) % 2:
        ds.append(0xF)
    out = bytearray()
    for i in range(0, len(ds), 2):
        out.append((ds[i + 1] << 4) | ds[i])
    return bytes(out)


# ---------------------------------------------------------------------------
# SUCI (null scheme) - TS 24.501 5GS mobile identity / TS 23.003
# ---------------------------------------------------------------------------
def split_imsi(imsi: str, mcc: str, mnc: str) -> str:
    """Return the MSIN portion of an IMSI given MCC/MNC."""
    mcc = str(mcc).zfill(3)
    mnc3 = ("0" + mnc) if len(str(mnc)) == 2 else str(mnc).zfill(3)
    prefix = mcc + (mnc if len(str(mnc)) == 2 else mnc3)
    if imsi.startswith(mcc):
        return imsi[len(mcc) + len(str(mnc)):]
    return imsi[len(prefix):]


def encode_suci_nai(mcc: str, mnc: str, msin: str,
                    routing_indicator: str = "0") -> bytes:
    """Encode a SUCI with the null protection scheme as the *contents* of the
    5GS mobile identity IE (i.e. without the outer 2-octet length).

    Layout (TS 24.501 Figure 9.11.3.4.x, SUPI format = IMSI):
        octet1: SPARE(0) | SUPI-format(0=IMSI)<<4 | type-of-identity(1=SUCI)
        octet2-4: MCC/MNC (3-octet PLMN, nibble-swapped BCD)
        octet5-6: Routing Indicator (2 octets, BCD, 0xF filler)
        octet7:   Protection scheme id (0x00 = null scheme)
        octet8:   Home network public key id (0x00 for null scheme)
        octet9+:  Scheme output = MSIN in nibble-swapped BCD
    """
    # bits: type-of-identity(1-3)=001 SUCI, supi-format(5-7)=000 IMSI
    first = 0b0000_0001  # SUPI format IMSI (0) in bits 5-7, SUCI (1) in bits 1-3
    plmn = encode_plmn(mcc, mnc)

    ri = routing_indicator or "0"
    ri_digits = [int(d) for d in ri]
    while len(ri_digits) < 4:
        ri_digits.append(0xF)  # pad to 2 octets with 0xF nibbles
    ri_bytes = bytes([
        (ri_digits[1] << 4) | ri_digits[0],
        (ri_digits[3] << 4) | ri_digits[2],
    ])

    prot_scheme = 0x00     # null scheme
    hn_pki = 0x00          # home network public key id (0 for null scheme)
    scheme_output = _bcd_digits(msin)

    return bytes([first]) + plmn + ri_bytes + bytes([prot_scheme, hn_pki]) + scheme_output


# ---------------------------------------------------------------------------
# 5G key hierarchy
# ---------------------------------------------------------------------------
def derive_kausf(ck: bytes, ik: bytes, snn: bytes, sqn_xor_ak: bytes) -> bytes:
    """KAUSF <- CK||IK  (TS 33.501 A.2, FC=0x6A).

    ``sqn_xor_ak`` is SQN(+)AK, which equals the first 6 octets of AUTN.
    """
    return kdf(ck + ik, FC_KAUSF, snn, sqn_xor_ak)


def derive_res_star(ck: bytes, ik: bytes, snn: bytes, rand: bytes,
                    res: bytes) -> bytes:
    """RES* <- CK||IK  (TS 33.501 A.4, FC=0x6B).

    RES* is the 128 least-significant bits of the KDF output.
    """
    out = kdf(ck + ik, FC_RES_STAR, snn, rand, res)
    return out[16:32]


def derive_kseaf(kausf: bytes, snn: bytes) -> bytes:
    """KSEAF <- KAUSF  (TS 33.501 A.6, FC=0x6C)."""
    return kdf(kausf, FC_KSEAF, snn)


def derive_kamf(kseaf: bytes, supi: bytes, abba: bytes = ABBA_DEFAULT) -> bytes:
    """KAMF <- KSEAF  (TS 33.501 A.7, FC=0x6D).

    ``supi`` is the SUPI in IMSI form, encoded as the ASCII digit string
    (this matches open5gs' ogs_kdf_kamf, which passes the SUPI digit string).
    """
    return kdf(kseaf, FC_KAMF, supi, abba)


def derive_nas_algo_key(kamf: bytes, algo_type_dist: int, algo_id: int) -> bytes:
    """NAS algorithm key (KNASenc/KNASint) <- KAMF (TS 33.501 A.8, FC=0x69).

    Returns the 128 least-significant bits (16 bytes) of the KDF output.
    """
    out = kdf(kamf, FC_ALGORITHM_KEY,
              bytes([algo_type_dist]), bytes([algo_id]))
    return out[16:32]


def derive_nas_keys(kamf: bytes, nea_id: int, nia_id: int) -> Tuple[bytes, bytes]:
    """Return (KNASenc, KNASint) for the selected NEA/NIA algorithm ids."""
    knas_enc = derive_nas_algo_key(kamf, N_NAS_ENC_ALG, nea_id)
    knas_int = derive_nas_algo_key(kamf, N_NAS_INT_ALG, nia_id)
    return knas_enc, knas_int


# ---------------------------------------------------------------------------
# Convenience: full UE-side 5G-AKA from an Authentication Request
# ---------------------------------------------------------------------------
class FiveGAkaResult:
    """Holds the outputs of a UE-side 5G-AKA run."""

    __slots__ = ("res", "ck", "ik", "res_star", "kausf", "kseaf",
                 "kamf", "knas_enc", "knas_int", "sqn_xor_ak")

    def __init__(self, res, ck, ik, res_star, kausf, kseaf, kamf,
                 knas_enc, knas_int, sqn_xor_ak):
        self.res = res
        self.ck = ck
        self.ik = ik
        self.res_star = res_star
        self.kausf = kausf
        self.kseaf = kseaf
        self.kamf = kamf
        self.knas_enc = knas_enc
        self.knas_int = knas_int
        self.sqn_xor_ak = sqn_xor_ak


def run_5g_aka(milenage: "Milenage", rand: bytes, autn: bytes, *,
               supi: str, mcc: str, mnc: str,
               nea_id: int = NEA0, nia_id: int = NIA2,
               abba: bytes = ABBA_DEFAULT) -> FiveGAkaResult:
    """Perform the full UE-side 5G-AKA from a received (RAND, AUTN).

    Computes RES, CK, IK via Milenage, then RES* and the whole KAUSF -> KSEAF
    -> KAMF -> KNASenc/KNASint chain. ``supi`` is the IMSI digit string.
    """
    res, ck, ik = milenage.authenticate(rand, autn)
    sqn_xor_ak = autn[0:6]                    # SQN(+)AK is the first 6 AUTN octets
    snn = build_snn(mcc, mnc)

    res_star = derive_res_star(ck, ik, snn, rand, res)
    kausf = derive_kausf(ck, ik, snn, sqn_xor_ak)
    kseaf = derive_kseaf(kausf, snn)
    kamf = derive_kamf(kseaf, supi.encode("ascii"), abba)
    knas_enc, knas_int = derive_nas_keys(kamf, nea_id, nia_id)

    return FiveGAkaResult(res, ck, ik, res_star, kausf, kseaf, kamf,
                          knas_enc, knas_int, sqn_xor_ak)


# ---------------------------------------------------------------------------
# Self-test
# ---------------------------------------------------------------------------
if __name__ == "__main__":
    # Deterministic structural checks (no official 5G-AKA vectors required).
    snn = build_snn("001", "01")
    assert snn == b"5G:mnc001.mcc001.3gppnetwork.org", snn
    print("SNN                :", snn.decode())

    plmn = encode_plmn("001", "01")
    assert plmn == bytes.fromhex("00f110"), plmn.hex()
    print("PLMN 001/01        :", plmn.hex())

    # KDF shape: HMAC-SHA-256 -> 32 bytes; S = FC||P0||L0...
    out = kdf(b"\x00" * 32, FC_KSEAF, snn)
    assert len(out) == 32
    manual = hmac.new(b"\x00" * 32, bytes([FC_KSEAF]) + snn + len(snn).to_bytes(2, "big"),
                      hashlib.sha256).digest()
    assert out == manual
    print("KDF(KSEAF) ok      :", out.hex()[:16], "...")

    suci = encode_suci_nai("001", "01", "0000000001")
    print("SUCI (001/01/...1) :", suci.hex())
    assert suci[0] == 0x01                     # SUCI, IMSI format
    assert suci[1:4] == plmn

    # Full 5G-AKA smoke using UE1 test creds from .env (Milenage OPc from OP).
    ki = bytes.fromhex("8baf473f2f8fd09487cccbd7097c6862")
    op = bytes.fromhex("11111111111111111111111111111111")
    opc = Milenage.compute_opc(ki, op)
    mil = Milenage(ki, opc, amf=b"\x80\x00")
    rand = bytes.fromhex("00112233445566778899aabbccddeeff")
    # Build a self-consistent AUTN (SQN(+)AK || AMF || MAC) so authenticate() runs.
    sqn = bytes.fromhex("000000000021")
    _, ak = Milenage.f2_f5(ki, rand, opc)
    mac_a, _ = Milenage.f1(ki, sqn, rand, opc, b"\x80\x00")
    from .milenage import xor as _xor
    autn = _xor(sqn, ak) + b"\x80\x00" + mac_a
    r = run_5g_aka(mil, rand, autn, supi="001010000000001", mcc="001", mnc="01")
    print("RES                :", r.res.hex())
    print("RES*               :", r.res_star.hex(), "(16B)")
    print("KAUSF              :", r.kausf.hex())
    print("KSEAF              :", r.kseaf.hex())
    print("KAMF               :", r.kamf.hex())
    print("KNASenc            :", r.knas_enc.hex(), "(16B)")
    print("KNASint            :", r.knas_int.hex(), "(16B)")
    assert len(r.res_star) == 16 and len(r.knas_enc) == 16 and len(r.knas_int) == 16
    print("\nkeys5g self-test PASSED")
