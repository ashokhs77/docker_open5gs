"""
5G-NAS (5GMM) codec and NAS-security wrapper for the native NGAP UE simulator.

Message *bodies* are built and parsed with pycrate's TS 24.501 modules
(``TS24501_FGMM`` / ``NAS5G``) which are byte-exact with the 3GPP spec and
present in the test image. What pycrate cannot do here (the optional
``CryptoMobile`` dependency is not installed) is the NAS *security* layer -
integrity (128-NIA2 = AES-CMAC) and ciphering (128-NEA*). We own that instead,
using :mod:`ue_sim.keys5g` for the keys and ``cryptography``'s AES-CMAC for the
MAC. For a registration load test NEA0 (null ciphering) is used, so only the
integrity MAC has to be computed.

Security-protected NAS message layout (TS 24.501 clause 9.1.1):

    EPD(0x7E) | SecHdrType(1 octet) | MAC(4 octets) | Seqn(1 octet) | NASMessage

The 128-NIA2 MAC (TS 33.501 / TS 33.401 Annex B.2.3) is computed over:

    M = COUNT(4) | (BEARER<<3 | DIR<<2)(1) | 0x00 0x00 0x00 | MESSAGE
    MAC = AES-CMAC(KNASint, M)[0:4]

where MESSAGE = Seqn | NASMessage, COUNT is the 24-bit NAS COUNT in the low
bits, DIR = 0 uplink, and BEARER is the NAS connection identifier.

LIVE-VALIDATION NOTES (things that must match the open5gs AMF exactly; if the
AMF logs "MAC verification failed" adjust these):
  * NAS_MAC_BEARER - the NAS connection identifier used as BEARER. open5gs uses
    the 3GPP access type (1). Fallback to try: 0.
  * SMC uplink NAS COUNT starts at 0 (Security Mode Complete), then increments.
  * Security Mode Complete uses SecHdrType 4 (integrity+ciphered, new context).
"""

import logging
import struct
from typing import Optional, Tuple, Dict, Any

from cryptography.hazmat.primitives.cmac import CMAC
from cryptography.hazmat.primitives.ciphers import algorithms

from pycrate_mobile.TS24501_FGMM import (
    FGMMRegistrationRequest,
    FGMMAuthenticationResponse,
    FGMMSecurityModeComplete,
    FGMMRegistrationComplete,
)
from pycrate_mobile.NAS5G import parse_NAS5G

logger = logging.getLogger(__name__)

# --- NAS constants ---------------------------------------------------------
EPD_5GMM = 0x7E

# Security header types (TS 24.501 9.3.1)
SHT_PLAIN = 0
SHT_INTEGRITY = 1
SHT_INTEGRITY_CIPHERED = 2
SHT_INTEGRITY_NEW_CTX = 3
SHT_INTEGRITY_CIPHERED_NEW_CTX = 4

# 5GMM message types (TS 24.501 9.7)
MT_REGISTRATION_REQUEST = 0x41
MT_REGISTRATION_ACCEPT = 0x42
MT_REGISTRATION_COMPLETE = 0x43
MT_REGISTRATION_REJECT = 0x44
MT_DEREGISTRATION_REQ_UE = 0x45
MT_SERVICE_REQUEST = 0x4C
MT_SERVICE_REJECT = 0x4D
MT_SERVICE_ACCEPT = 0x4E
MT_AUTHENTICATION_REQUEST = 0x56
MT_AUTHENTICATION_RESPONSE = 0x57
MT_AUTHENTICATION_REJECT = 0x58
MT_AUTHENTICATION_FAILURE = 0x59
MT_AUTHENTICATION_RESULT = 0x5A
MT_IDENTITY_REQUEST = 0x5B
MT_IDENTITY_RESPONSE = 0x5C
MT_SECURITY_MODE_COMMAND = 0x5D
MT_SECURITY_MODE_COMPLETE = 0x5E
MT_SECURITY_MODE_REJECT = 0x5F
MT_DL_NAS_TRANSPORT = 0x68
MT_UL_NAS_TRANSPORT = 0x67

# BEARER (NAS connection identifier) for the integrity MAC - see live notes.
NAS_MAC_BEARER = 1
DIR_UPLINK = 0
DIR_DOWNLINK = 1


# ---------------------------------------------------------------------------
# 128-NIA2 integrity (AES-CMAC)
# ---------------------------------------------------------------------------
def nia2_mac(knas_int: bytes, count: int, bearer: int, direction: int,
             message: bytes) -> bytes:
    """Compute the 4-octet 128-NIA2 MAC over ``message`` (Seqn||NASMessage)."""
    prefix = struct.pack(">I", count & 0xFFFFFFFF)
    prefix += bytes([((bearer & 0x1F) << 3) | ((direction & 0x1) << 2)])
    prefix += b"\x00\x00\x00"
    c = CMAC(algorithms.AES(knas_int))
    c.update(prefix + message)
    return c.finalize()[:4]


# ---------------------------------------------------------------------------
# Security wrapper (encapsulate / decapsulate)
# ---------------------------------------------------------------------------
def nas_protect(inner: bytes, knas_int: bytes, count: int, sht: int,
                *, knas_enc: Optional[bytes] = None, nea_id: int = 0,
                bearer: int = NAS_MAC_BEARER) -> bytes:
    """Wrap a plaintext inner NAS message in a security-protected NAS message.

    NEA0 (null ciphering) is assumed unless ``nea_id``/``knas_enc`` request
    otherwise (only NEA0 is supported here - enough for a load test). The MAC
    is 128-NIA2 over ``Seqn||inner``.
    """
    seqn = count & 0xFF
    payload = bytes([seqn]) + inner            # MESSAGE = Seqn || NASMessage
    mac = nia2_mac(knas_int, count, bearer, DIR_UPLINK, payload)
    return bytes([EPD_5GMM, sht]) + mac + payload


def nas_decapsulate(raw: bytes) -> Tuple[int, int, bytes]:
    """Split a downlink security-protected NAS message.

    Returns (sec_hdr_type, seqn, inner_plaintext_nas). If ``raw`` is already a
    plain 5GMM message (SHT 0 or non-protected), it is returned as the inner.
    """
    if len(raw) >= 2 and raw[0] == EPD_5GMM and raw[1] in (
            SHT_INTEGRITY, SHT_INTEGRITY_CIPHERED,
            SHT_INTEGRITY_NEW_CTX, SHT_INTEGRITY_CIPHERED_NEW_CTX):
        sht = raw[1]
        # EPD | SHT | MAC(4) | Seqn(1) | inner
        seqn = raw[6]
        return sht, seqn, raw[7:]
    return SHT_PLAIN, 0, raw


# ---------------------------------------------------------------------------
# UE security capability / NSSAI helpers
# ---------------------------------------------------------------------------
def ue_security_capability(ea: int = 0xF0, ia: int = 0xF0) -> bytes:
    """5GS UE security capability value: octet1=5G-EA bits, octet2=5G-IA bits.

    Default advertises 5G-EA0..3 (0xF0) and 5G-IA0..3 (0xF0). open5gs' default
    order then selects 128-NIA2 for integrity and NEA0 for ciphering.
    """
    return bytes([ea & 0xFF, ia & 0xFF])


# ---------------------------------------------------------------------------
# Message builders
# ---------------------------------------------------------------------------
def encode_nssai_ie(iei: int, entries) -> bytes:
    """Encode an NSSAI IE (Requested/Allowed NSSAI, TS 24.501 9.11.3.37).

    ``entries`` is a list of (sst, sd) tuples; sd may be None for SST-only.
    Each S-NSSAI = length | SST[ | SD(3 octets)]. Returns IEI | L | value.
    """
    body = b""
    for sst, sd in entries:
        if sd is None:
            body += bytes([1, sst & 0xFF])
        else:
            body += bytes([4, sst & 0xFF]) + int(sd).to_bytes(3, "big")
    return bytes([iei, len(body)]) + body


def build_registration_request(suci: bytes, *, ksi: int = 7,
                               reg_type: int = 1, follow_on: int = 1,
                               ue_sec_cap: Optional[bytes] = None,
                               requested_nssai=((1, 0x000001),)) -> bytes:
    """Initial Registration Request carrying a SUCI 5GS mobile identity.

    ``suci`` is the 5GS-mobile-identity contents from
    :func:`ue_sim.keys5g.encode_suci_nai`. ``ksi=7`` = no key available.
    ``requested_nssai`` is a list of (sst, sd) tuples; the AMF intersects it
    with the subscribed NSSAI to build the Allowed-NSSAI (empty => reject 62).
    """
    m = FGMMRegistrationRequest()
    m["5GMMHeader"]["EPD"].set_val(EPD_5GMM)
    m["5GMMHeader"]["SecHdr"].set_val(0)
    m["5GMMHeader"]["Type"].set_val(MT_REGISTRATION_REQUEST)
    m["NAS_KSI"]["V"].set_val(ksi & 0x0F)
    # 5GS registration type: bit4 = follow-on, bits1-3 = type
    m["5GSRegType"]["V"].set_val(((follow_on & 1) << 3) | (reg_type & 0x07))
    # 5GS mobile identity (SUCI) via its LVE bytes (2-octet length + value)
    m["5GSID"].from_bytes(len(suci).to_bytes(2, "big") + suci)
    raw = m.to_bytes()
    # Append the UE security capability IE (T=0x2E) so the AMF can select algos.
    cap = ue_sec_cap if ue_sec_cap is not None else ue_security_capability()
    raw += bytes([0x2E, len(cap)]) + cap
    # Append the Requested NSSAI IE (T=0x2F) so the AMF can build Allowed-NSSAI.
    if requested_nssai:
        raw += encode_nssai_ie(0x2F, list(requested_nssai))
    return raw


def build_authentication_response(res_star: bytes) -> bytes:
    """Authentication Response carrying RES* (16 octets)."""
    m = FGMMAuthenticationResponse()
    m["5GMMHeader"]["EPD"].set_val(EPD_5GMM)
    m["5GMMHeader"]["SecHdr"].set_val(0)
    m["5GMMHeader"]["Type"].set_val(MT_AUTHENTICATION_RESPONSE)
    # RES is an optional Type4TLV (T=0x2D), transparent by default - make it
    # present, then set its value to RES*.
    m["RES"].set_trans(False)
    m["RES"]["V"].set_val(res_star)
    return m.to_bytes()


def build_security_mode_complete(*, nas_container: Optional[bytes] = None,
                                 imeisv: Optional[bytes] = None) -> bytes:
    """Security Mode Complete, optionally replaying the full Registration
    Request in the NAS message container (open5gs expects this so it can
    complete the registration from the ciphered/complete message)."""
    m = FGMMSecurityModeComplete()
    m["5GMMHeader"]["EPD"].set_val(EPD_5GMM)
    m["5GMMHeader"]["SecHdr"].set_val(0)
    m["5GMMHeader"]["Type"].set_val(MT_SECURITY_MODE_COMPLETE)
    if imeisv is not None:
        m["IMEISV"].set_trans(False)
        m["IMEISV"]["V"].set_val(imeisv)
    if nas_container is not None:
        m["NASContainer"].set_trans(False)
        m["NASContainer"]["V"].set_val(nas_container)
    return m.to_bytes()


def build_registration_complete() -> bytes:
    """Registration Complete (no SOR container)."""
    m = FGMMRegistrationComplete()
    m["5GMMHeader"]["EPD"].set_val(EPD_5GMM)
    m["5GMMHeader"]["SecHdr"].set_val(0)
    m["5GMMHeader"]["Type"].set_val(MT_REGISTRATION_COMPLETE)
    return m.to_bytes()


# ---------------------------------------------------------------------------
# Parsers / field extraction
# ---------------------------------------------------------------------------
def parse(raw: bytes):
    """parse_NAS5G wrapper -> (msg_obj_or_None, err_code)."""
    return parse_NAS5G(raw)


def message_type(msg) -> Optional[int]:
    """Return the 5GMM message type of a parsed plain message, or None."""
    try:
        return msg["5GMMHeader"]["Type"].get_val()
    except Exception:
        return None


def _ie_val(msg, name, value_fields=("V",)) -> Optional[bytes]:
    """Return the raw value octets of IE ``name``.

    pycrate names the value subfield differently per IE type: most use ``V``,
    but some (e.g. AUTN) name it after the IE itself. Try each candidate and
    fall back to serializing the IE's own value part.
    """
    try:
        ie = msg[name]
    except Exception:
        return None
    for vf in value_fields:
        try:
            return bytes(ie[vf].to_bytes())
        except Exception:
            continue
    return None


def extract_auth_request(msg) -> Dict[str, Any]:
    """Extract RAND, AUTN, ABBA and ngKSI from an Authentication Request."""
    out: Dict[str, Any] = {}
    rand = _ie_val(msg, "RAND", ("V",))
    autn = _ie_val(msg, "AUTN", ("AUTN", "V"))     # AUTN value subfield is "AUTN"
    abba = _ie_val(msg, "ABBA", ("V",))
    out["rand"] = rand[-16:] if rand else None
    out["autn"] = autn[-16:] if autn else None
    out["abba"] = abba
    try:
        out["ngksi"] = msg["NAS_KSI"]["V"].get_val()
    except Exception:
        out["ngksi"] = None
    return out


def extract_security_mode_command(msg) -> Dict[str, Any]:
    """Extract selected NEA/NIA algorithm ids and the IMEISV request flag."""
    out: Dict[str, Any] = {"nea": 0, "nia": 0, "imeisv_req": 0}
    algo = _ie_val(msg, "NASSecAlgo", ("NASSecAlgo", "V"))
    if algo:
        out["nea"] = (algo[0] >> 4) & 0x0F
        out["nia"] = algo[0] & 0x0F
    imeisv = _ie_val(msg, "IMEISVReq", ("V", "IMEISVReq"))
    if imeisv:
        out["imeisv_req"] = imeisv[0] & 0x07
    return out


def extract_reject_cause(msg) -> Optional[int]:
    """Extract the 5GMM cause from a Registration/Service Reject."""
    b = _ie_val(msg, "5GMMCause", ("V", "5GMMCause"))
    return b[0] if b else None


# ---------------------------------------------------------------------------
# Self-test (offline; structural)
# ---------------------------------------------------------------------------
if __name__ == "__main__":
    from .keys5g import encode_suci_nai

    suci = encode_suci_nai("001", "01", "0000000001")
    reg = build_registration_request(suci)
    print("RegistrationRequest :", reg.hex())
    msg, err = parse(reg)
    assert err == 0 and message_type(msg) == MT_REGISTRATION_REQUEST, (err, msg)
    print("  parsed type       :", hex(message_type(msg)))

    res_star = bytes(range(16))
    ar = build_authentication_response(res_star)
    print("AuthResponse        :", ar.hex())
    msg, err = parse(ar)
    assert err == 0 and message_type(msg) == MT_AUTHENTICATION_RESPONSE, (err,)
    assert res_star.hex() in ar.hex(), "RES* missing from Authentication Response!"

    smc = build_security_mode_complete(nas_container=reg, imeisv=bytes.fromhex("0891606101020304"))
    print("SecurityModeComplete:", smc.hex())
    msg, err = parse(smc)
    assert err == 0 and message_type(msg) == MT_SECURITY_MODE_COMPLETE, (err,)
    assert reg.hex() in smc.hex(), "NAS container (Reg Request) missing from SMC!"

    rc = build_registration_complete()
    msg, err = parse(rc)
    assert err == 0 and message_type(msg) == MT_REGISTRATION_COMPLETE, (err,)

    # Integrity wrapper: MAC is deterministic; round-trip the header split.
    knas_int = bytes(range(16))
    prot = nas_protect(rc, knas_int, count=0, sht=SHT_INTEGRITY_CIPHERED_NEW_CTX)
    sht, seqn, inner = nas_decapsulate(prot)
    assert sht == SHT_INTEGRITY_CIPHERED_NEW_CTX and seqn == 0 and inner == rc, (sht, seqn)
    print("Protected(RC)       :", prot.hex())

    # NIA2 known-shape check: AES-CMAC of the constructed M, first 4 octets.
    mac = nia2_mac(bytes(16), 0, 1, 0, b"\x00" + rc)
    assert len(mac) == 4
    print("NIA2 MAC (len4)     :", mac.hex())
    print("\nnas5g self-test PASSED")
