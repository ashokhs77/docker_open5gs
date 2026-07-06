"""
Dynamic subscriber provisioning for load testing.

Creates N test subscribers in PyHSS via REST API, with unique IMSI/Ki per UE.
Also fixes AUC ID mapping in MySQL and provisions IMS subscribers.
"""

import logging
import hashlib
import json
import os
import subprocess
import time
from typing import List, Dict, Optional

logger = logging.getLogger(__name__)

# Base credentials template
BASE_OPC = "8E27B6AF0E692E750F32667A3B14605D"
BASE_AMF = "8000"
BASE_IMSI_PREFIX = "00101"  # MCC=001, MNC=01
LOAD_MSISDN_PREFIX = "986"  # Keep load UEs away from fixed regression users.
_LOAD_SUBSCRIBER_BASE: Optional[int] = None


def _load_subscriber_base() -> int:
    """Return a stable per-process base for dynamic load subscriber identities."""
    global _LOAD_SUBSCRIBER_BASE
    if _LOAD_SUBSCRIBER_BASE is not None:
        return _LOAD_SUBSCRIBER_BASE

    env_base = os.environ.get("LOAD_SUBSCRIBER_BASE")
    if env_base:
        try:
            _LOAD_SUBSCRIBER_BASE = int(env_base) % 10_000_000
            return _LOAD_SUBSCRIBER_BASE
        except ValueError:
            logger.warning("Ignoring invalid LOAD_SUBSCRIBER_BASE=%r", env_base)
    _LOAD_SUBSCRIBER_BASE = (int(time.time() * 1000) + os.getpid() * 1000) % 10_000_000
    return _LOAD_SUBSCRIBER_BASE


def _generate_ki(index: int) -> str:
    """Generate a fixed-length, deterministic Ki for a dynamic subscriber."""
    return hashlib.sha256(f"lekha-load-{index}".encode("ascii")).hexdigest()[:32]


def _generate_subscriber(index: int) -> Dict[str, str]:
    """Generate subscriber credentials for a given index."""
    # IMSI: 00101 + 10-digit MSISDN. Use a run-scoped range to avoid
    # reusing stale PyHSS AUC/cache state from previous capacity tests.
    msisdn = f"{LOAD_MSISDN_PREFIX}{index % 10_000_000:07d}"
    imsi = BASE_IMSI_PREFIX + msisdn
    ki = _generate_ki(index)

    return {
        "imsi": imsi,
        "ki": ki,
        "opc": BASE_OPC,
        "amf": BASE_AMF,
        "msisdn": msisdn,
    }


def provision_subscribers(
    num_ues: int,
    pyhss_ip: str = None,
    mysql_ip: str = None,
    ims_domain: str = None,
) -> List[Dict[str, str]]:
    """
    Provision N test subscribers in PyHSS.

    Creates AUC entries, subscriber records, and IMS subscriber records.
    Handles duplicates gracefully (idempotent).

    Args:
        num_ues: Number of subscribers to create
        pyhss_ip: PyHSS API IP (default from env)
        mysql_ip: MySQL IP for AUC ID fix (default from env)
        ims_domain: IMS domain (default from env)

    Returns:
        List of subscriber dicts with imsi/ki/opc/amf/msisdn
    """
    pyhss_ip = pyhss_ip or os.environ.get("PYHSS_IP", "172.22.1.18")
    mysql_ip = mysql_ip or os.environ.get("MYSQL_IP", "172.22.1.17")
    ims_domain = ims_domain or os.environ.get("IMS_DOMAIN", "ims.mnc001.mcc001.3gppnetwork.org")

    api_base = f"http://{pyhss_ip}:8080"
    subscribers = []
    subscriber_base = _load_subscriber_base()

    logger.info(
        "Provisioning %d test subscribers in PyHSS at %s (base=%d)",
        num_ues,
        api_base,
        subscriber_base,
    )

    # Ensure APNs exist
    _ensure_apns(api_base)

    for i in range(num_ues):
        sub = _generate_subscriber(subscriber_base + i)
        subscribers.append(sub)

        # Create AUC entry and carry the actual auc_id into the subscriber row.
        # Using a placeholder auc_id causes load UEs to authenticate against the
        # wrong Ki if the direct MySQL repair step is unavailable.
        auc_id = _create_auc(api_base, sub)
        if auc_id is not None:
            sub["auc_id"] = auc_id

        # Create subscriber record
        _create_subscriber(api_base, sub)

        # Create IMS subscriber
        _create_ims_subscriber(api_base, sub, ims_domain)

    # Repair credentials and AUC ID mapping via MySQL. Existing rows are common
    # across repeated load runs, so they must be made deterministic as well.
    _fix_auc_mapping(mysql_ip, subscribers, ims_domain)

    logger.info("Provisioned %d subscribers successfully", len(subscribers))
    return subscribers


def _ensure_apns(api_base: str):
    """Ensure internet and ims APNs exist (idempotent — skips if already present)."""
    import urllib.request

    # Check existing APNs first to avoid creating duplicates
    existing_apn_names = set()
    try:
        resp = urllib.request.urlopen(f"{api_base}/apn/list", timeout=5)
        apn_list = json.loads(resp.read().decode())
        existing_apn_names = {apn.get("apn", "") for apn in apn_list}
    except Exception:
        pass  # API not ready or empty — will attempt creation

    for apn_name, qci in [("internet", 9), ("ims", 5)]:
        if apn_name in existing_apn_names:
            logger.debug("APN '%s' already exists, skipping", apn_name)
            continue

        # ip_version omitted → PyHSS defaults to 0 (IPv4-only).
        # NOTE: Set ip_version=2 (IPv4v6) here AND call _patch_apn_ip_version()
        # below once the UPF/SMF infrastructure is confirmed to support IPv6 UE
        # address allocation.  Until then ip_version=0 is the safe default:
        # TC-48 (IPv4v6) downgraded to IPv4 (valid 3GPP, PASS); TC-47/TC-49
        # (IPv6-only) skip rather than fail.
        data = json.dumps({
            "apn": apn_name,
            "apn_ambr_dl": 0,
            "apn_ambr_ul": 0,
            "qci": qci,
        }).encode()

        req = urllib.request.Request(
            f"{api_base}/apn/",
            data=data,
            headers={"Content-Type": "application/json"},
            method="PUT",
        )
        try:
            urllib.request.urlopen(req, timeout=5)
            logger.debug("Created APN '%s'", apn_name)
        except Exception:
            pass  # Already exists or creation failed


def _get_json(api_base: str, path: str) -> Optional[dict]:
    """
    GET a resource from PyHSS API. Returns parsed JSON on 200, None on 404 or error.
    Used for existence checks before PUT to avoid Duplicate-entry MySQL errors.
    """
    import urllib.request
    import urllib.error

    try:
        resp = urllib.request.urlopen(f"{api_base}/{path}", timeout=5)
        return json.loads(resp.read().decode())
    except urllib.error.HTTPError as e:
        if e.code == 404:
            return None  # Does not exist yet — caller should create it
        logger.debug("GET %s/%s returned HTTP %d", api_base, path, e.code)
        return None
    except Exception as e:
        logger.debug("GET %s/%s failed: %s", api_base, path, e)
        return None


def _put_json(api_base: str, path: str, payload: dict) -> bool:
    """PUT a resource to the PyHSS API. Returns True on success, False on error."""
    import urllib.request
    import urllib.error

    data = json.dumps(payload).encode()
    req = urllib.request.Request(
        f"{api_base}/{path}",
        data=data,
        headers={"Content-Type": "application/json"},
        method="PUT",
    )
    try:
        urllib.request.urlopen(req, timeout=5)
        return True
    except urllib.error.HTTPError as e:
        logger.warning("PUT %s/%s returned HTTP %d", api_base, path, e.code)
        return False
    except Exception as e:
        logger.warning("PUT %s/%s failed: %s", api_base, path, e)
        return False


def _patch_apn_ip_version(api_base: str, apn_name: str, ip_version: int):
    """
    PATCH the ip_version field on an existing APN.

    Called unconditionally after ensure/create so that APNs provisioned before
    this fix (PyHSS default ip_version=0 = IPv4-only) are updated to dual-stack
    (ip_version=2).  Without this the MME sends Diameter PDN-Type=0 back to the
    UE, causing IPv6/dual-stack PDN attach to be rejected with UNKNOWN_PDN_TYPE
    even when the SMF has an IPv6 pool configured.

    ip_version values (TS 29.272 §7.3.62 / PyHSS database.py):
      0=IPv4  1=IPv6  2=IPv4v6  3=IPv4orIPv6
    """
    import urllib.request
    import urllib.error

    # Locate APN ID from list
    apn_id = None
    try:
        resp = urllib.request.urlopen(f"{api_base}/apn/list", timeout=5)
        apn_list = json.loads(resp.read().decode())
        for apn in apn_list:
            if apn.get("apn") == apn_name:
                apn_id = apn.get("apn_id")
                break
    except Exception as e:
        logger.debug("Could not fetch APN list for PATCH: %s", e)
        return

    if apn_id is None:
        logger.debug("APN '%s' not found in list — skipping ip_version PATCH", apn_name)
        return

    data = json.dumps({"ip_version": ip_version}).encode()
    req = urllib.request.Request(
        f"{api_base}/apn/{apn_id}",
        data=data,
        headers={"Content-Type": "application/json"},
        method="PATCH",
    )
    try:
        urllib.request.urlopen(req, timeout=5)
        logger.debug("PATCH APN '%s' (id=%s) ip_version=%d", apn_name, apn_id, ip_version)
    except urllib.error.HTTPError as e:
        logger.warning("PATCH APN '%s' ip_version returned HTTP %d", apn_name, e.code)
    except Exception as e:
        logger.warning("PATCH APN '%s' ip_version failed: %s", apn_name, e)


def _create_auc(api_base: str, sub: Dict[str, str]) -> Optional[int]:
    """Create AUC entry for subscriber and return its auc_id when available."""
    # GET-before-PUT: avoids MySQLdb.IntegrityError duplicate-key spam in PyHSS logs
    existing = _get_json(api_base, f"auc/imsi/{sub['imsi']}")
    if existing is not None:
        logger.debug("AUC already exists for IMSI %s — skipping", sub["imsi"])
        return existing.get("auc_id")

    if not _put_json(api_base, "auc/", {
        "ki": sub["ki"],
        "opc": sub["opc"],
        "amf": sub["amf"],
        "sqn": 0,
        "imsi": sub["imsi"],
    }):
        return None

    created = _get_json(api_base, f"auc/imsi/{sub['imsi']}")
    if created is not None:
        return created.get("auc_id")
    return None


def _create_subscriber(api_base: str, sub: Dict[str, str]):
    """Create subscriber record — skips silently if already present."""
    # GET-before-PUT: avoids MySQLdb.IntegrityError duplicate-key spam in PyHSS logs
    if _get_json(api_base, f"subscriber/imsi/{sub['imsi']}") is not None:
        logger.debug("Subscriber already exists for IMSI %s — skipping", sub["imsi"])
        return

    _put_json(api_base, "subscriber/", {
        "imsi": sub["imsi"],
        "enabled": True,
        "auc_id": int(sub.get("auc_id") or 1),
        "default_apn": 1,
        "apn_list": "1,2",
        "msisdn": sub["msisdn"],
        "ue_ambr_dl": 0,
        "ue_ambr_ul": 0,
    })


def _create_ims_subscriber(api_base: str, sub: Dict[str, str], ims_domain: str):
    """Create IMS subscriber record — skips silently if already present."""
    # GET-before-PUT: avoids MySQLdb.IntegrityError duplicate-key spam in PyHSS logs
    if _get_json(api_base, f"ims_subscriber/ims_subscriber_msisdn/{sub['msisdn']}") is not None:
        logger.debug("IMS subscriber already exists for MSISDN %s — skipping", sub["msisdn"])
        return

    _put_json(api_base, "ims_subscriber/", {
        "imsi": sub["imsi"],
        "msisdn": sub["msisdn"],
        "msisdn_list": f"[{sub['msisdn']}]",
        "ifc_path": "default_ifc.xml",
        "scscf_peer": f"scscf.{ims_domain}",
        "scscf": f"sip:scscf.{ims_domain}:6060",
        "scscf_realm": ims_domain,
    })


def _sql_literal(value: str) -> str:
    """Return a SQL string literal for deterministic test data."""
    return "'" + str(value).replace("\\", "\\\\").replace("'", "''") + "'"


def _fix_auc_mapping(mysql_ip: str, subscribers: List[Dict[str, str]], ims_domain: str):
    """
    Fix load-subscriber MySQL state so repeated runs use the expected credentials.

    PyHSS returns duplicates for existing rows, but an old row can still contain
    stale Ki/OPc or subscriber-to-AUC mapping from a previous test image. Repairing
    those rows keeps load pre-flight failures honest: auth failures should come
    from EPC/HSS behavior, not from stale provisioning data.
    """
    statements = []
    imsi_list = []
    for sub in subscribers:
        imsi = sub["imsi"]
        msisdn = sub["msisdn"]
        imsi_list.append(imsi)
        statements.extend([
            (
                "UPDATE auc SET "
                f"ki={_sql_literal(sub['ki'])}, "
                f"opc={_sql_literal(sub['opc'])}, "
                f"amf={_sql_literal(sub.get('amf', BASE_AMF))}, "
                "algo=3, "
                "sqn=0 "
                f"WHERE imsi={_sql_literal(imsi)}"
            ),
            (
                "UPDATE subscriber s JOIN auc a ON a.imsi = s.imsi SET "
                "s.auc_id = a.auc_id, "
                "s.enabled = 1, "
                "s.default_apn = 1, "
                "s.apn_list = '1,2', "
                f"s.msisdn = {_sql_literal(msisdn)}, "
                "s.ue_ambr_dl = 0, "
                "s.ue_ambr_ul = 0 "
                f"WHERE s.imsi = {_sql_literal(imsi)}"
            ),
            (
                "UPDATE ims_subscriber SET "
                f"imsi = {_sql_literal(imsi)}, "
                f"msisdn = {_sql_literal(msisdn)}, "
                f"msisdn_list = {_sql_literal('[' + msisdn + ']')}, "
                "ifc_path = 'default_ifc.xml', "
                f"scscf_peer = {_sql_literal('scscf.' + ims_domain)}, "
                f"scscf = {_sql_literal('sip:scscf.' + ims_domain + ':6060')}, "
                f"scscf_realm = {_sql_literal(ims_domain)} "
                f"WHERE imsi = {_sql_literal(imsi)} OR msisdn = {_sql_literal(msisdn)}"
            ),
        ])

    sql = ";\n".join(statements) + ";"

    mysql_attempts = [
        (
            "docker exec mysql (no password)",
            ["docker", "exec", "mysql", "mysql", "-u", "root", "ims_hss_db", "-N", "-e", sql],
            15,
        ),
        (
            "docker exec mysql (configured password)",
            ["docker", "exec", "mysql", "mysql", "-u", "root", "-pMySQL_PaSsW0rD", "ims_hss_db", "-N", "-e", sql],
            15,
        ),
        (
            "direct MySQL (no password)",
            ["mysql", "-h", mysql_ip, "-u", "root", "ims_hss_db", "-N", "-e", sql],
            10,
        ),
        (
            "direct MySQL (configured password)",
            ["mysql", "-h", mysql_ip, "-u", "root", "-pMySQL_PaSsW0rD", "ims_hss_db", "-N", "-e", sql],
            10,
        ),
    ]

    for label, cmd, timeout_secs in mysql_attempts:
        try:
            result = subprocess.run(
                cmd,
                capture_output=True,
                text=True,
                timeout=timeout_secs,
            )
        except FileNotFoundError:
            logger.warning("%s failed: command not available", label)
            continue
        except Exception as e:
            logger.warning("%s failed: %s", label, e)
            continue

        if result.returncode == 0:
            logger.info("Load subscriber credentials/mapping fixed via %s for %d subscribers", label, len(imsi_list))
            return
        logger.warning("%s failed: %s", label, result.stderr.strip()[:200])

    logger.error("Could not fix load subscriber credentials/mapping - attach may fail!")
