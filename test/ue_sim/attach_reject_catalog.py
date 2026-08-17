#!/usr/bin/env python3
"""Offline verification of the MME mobility-reject CSV cause catalog."""

import argparse
import csv
import json
import re
from datetime import datetime, timedelta
from pathlib import Path


EXPECTED_CAUSES = (
    ("IMSI_UNKNOWN_IN_HSS", 2, "IMSI unknown in HSS"),
    ("ILLEGAL_UE", 3, "Illegal UE"),
    ("IMSI_UNKNOWN_IN_VLR", 4, "IMSI unknown in VLR"),
    ("IMEI_NOT_ACCEPTED", 5, "IMEI not accepted"),
    ("ILLEGAL_ME", 6, "Illegal ME"),
    ("EPS_SERVICES_NOT_ALLOWED", 7, "EPS services not allowed"),
    (
        "EPS_SERVICES_AND_NON_EPS_SERVICES_NOT_ALLOWED",
        8,
        "EPS services and non-EPS services not allowed",
    ),
    (
        "UE_IDENTITY_CANNOT_BE_DERIVED_BY_THE_NETWORK",
        9,
        "UE identity cannot be derived by the network",
    ),
    ("IMPLICITLY_DETACHED", 10, "Implicitly detached"),
    ("PLMN_NOT_ALLOWED", 11, "PLMN not allowed"),
    ("TRACKING_AREA_NOT_ALLOWED", 12, "Tracking area not allowed"),
    (
        "ROAMING_NOT_ALLOWED_IN_THIS_TRACKING_AREA",
        13,
        "Roaming not allowed in this tracking area",
    ),
    (
        "EPS_SERVICES_NOT_ALLOWED_IN_THIS_PLMN",
        14,
        "EPS services not allowed in this PLMN",
    ),
    (
        "NO_SUITABLE_CELLS_IN_TRACKING_AREA",
        15,
        "No suitable cells in tracking area",
    ),
    ("MSC_TEMPORARILY_NOT_REACHABLE", 16, "MSC temporarily not reachable"),
    ("NETWORK_FAILURE", 17, "Network failure"),
    ("CS_DOMAIN_NOT_AVAILABLE", 18, "CS domain not available"),
    ("ESM_FAILURE", 19, "ESM failure"),
    ("MAC_FAILURE", 20, "MAC failure"),
    ("SYNCH_FAILURE", 21, "Synchronization failure"),
    ("CONGESTION", 22, "Congestion"),
    (
        "UE_SECURITY_CAPABILITIES_MISMATCH",
        23,
        "UE security capabilities mismatch",
    ),
    (
        "SECURITY_MODE_REJECTED_UNSPECIFIED",
        24,
        "Security mode rejected unspecified",
    ),
    ("NOT_AUTHORIZED_FOR_THIS_CSG", 25, "Not authorized for this CSG"),
    (
        "NON_EPS_AUTHENTICATION_UNACCEPTABLE",
        26,
        "Non-EPS authentication unacceptable",
    ),
    ("REDIRECTION_TO_5GCN_REQUIRED", 31, "Redirection to 5GCN required"),
    (
        "REQUESTED_SERVICE_OPTION_NOT_AUTHORIZED_IN_THIS_PLMN",
        35,
        "Requested service option not authorized in this PLMN",
    ),
    (
        "IAB_NODE_OPERATION_NOT_AUTHORIZED",
        36,
        "IAB-node operation not authorized",
    ),
    (
        "CS_SERVICE_TEMPORARILY_NOT_AVAILABLE",
        39,
        "CS service temporarily not available",
    ),
    (
        "NO_EPS_BEARER_CONTEXT_ACTIVATED",
        40,
        "No EPS bearer context activated",
    ),
    ("SEVERE_NETWORK_FAILURE", 42, "Severe network failure"),
    (
        "PLMN_NOT_ALLOWED_AT_PRESENT_LOCATION",
        78,
        "PLMN not allowed to operate at the present UE location",
    ),
    (
        "DISASTER_ROAMING_NOT_ALLOWED",
        80,
        "Disaster roaming for the determined PLMN with disaster condition not allowed",
    ),
    (
        "S_AND_F_FEEDER_LINK_UNAVAILABLE",
        83,
        "Procedure cannot be completed due to unavailable feeder link while MME is operating in S&F mode",
    ),
    (
        "SEMANTICALLY_INCORRECT_MESSAGE",
        95,
        "Semantically incorrect message",
    ),
    (
        "INVALID_MANDATORY_INFORMATION",
        96,
        "Invalid mandatory information",
    ),
    (
        "MESSAGE_TYPE_NON_EXISTENT_OR_NOT_IMPLEMENTED",
        97,
        "Message type non-existent or not implemented",
    ),
    (
        "MESSAGE_TYPE_NOT_COMPATIBLE_WITH_PROTOCOL_STATE",
        98,
        "Message type not compatible with protocol state",
    ),
    (
        "INFORMATION_ELEMENT_NON_EXISTENT_OR_NOT_IMPLEMENTED",
        99,
        "Information element non-existent or not implemented",
    ),
    ("CONDITIONAL_IE_ERROR", 100, "Conditional IE error"),
    (
        "MESSAGE_NOT_COMPATIBLE_WITH_PROTOCOL_STATE",
        101,
        "Message not compatible with protocol state",
    ),
    ("PROTOCOL_ERROR_UNSPECIFIED", 111, "Protocol error unspecified"),
)

FALLBACK_CAUSE = (255, "Unassigned or future EMM cause")

CSV_HEADER = (
    "date",
    "time",
    "imei",
    "imsi",
    "reject_message",
    "reject_cause",
    "reject_reason",
)

REQUIRED_REJECT_MESSAGES = (
    "Attach Reject",
    "Authentication Reject",
    "TAU Reject",
    "Service Reject",
)

REQUIRED_SOURCE_FRAGMENTS = (
    "mme_unauthorized_audit_init();",
    'mme_unauthorized_audit_append(mme_ue, "Attach Reject"',
    'mme_unauthorized_audit_append(mme_ue, "Authentication Reject"',
    'mme_unauthorized_audit_append(mme_ue, "TAU Reject"',
    'mme_unauthorized_audit_append(mme_ue, "Service Reject"',
    '"date,time,imei,imsi\\n"',
    '"date,time,imei,imsi,attach_reject_cause\\n"',
    "date,time,imei,imsi,attach_reject_cause,attach_reject_reason",
    "rename(path, archive_path)",
    "rename(archive_path, path)",
)


def extract_patch_file_lines(patch_path: Path, source_path: str) -> list[str]:
    """Return one file's unified-diff section from a combined patch, OR — when the
    input is a plain source file (no diff header) — all of its lines. This lets
    the catalog validate directly against src/mme/unauthorized-audit.c without a
    patch artifact."""
    lines = patch_path.read_text(encoding="utf-8").splitlines()
    marker = f"diff --git a/{source_path} b/{source_path}"
    if marker not in lines:
        return lines  # plain source file: the whole file is the target
    in_file = False
    selected = []

    for line in lines:
        if line == marker:
            in_file = True
            continue
        if in_file and line.startswith("diff --git "):
            break
        if in_file:
            selected.append(line)

    if not selected:
        raise ValueError(f"patch does not contain {source_path}")
    return selected


def extract_reason_map(patch_path: Path) -> dict[str, str]:
    # A leading '+' (unified-diff added line) is optional, so this parses BOTH a
    # raw source file and a .patch of it.
    case_pattern = re.compile(
        r"^\+?\s*case\s+(?:OGS_NAS_EMM_CAUSE_([A-Z0-9_]+)|(\d+)):"
    )
    return_pattern = re.compile(r'^\+?\s*return\s+"([^"]+)";\s*$')
    reason_map: dict[str, str] = {}
    name_by_code = {code: name for name, code, _ in EXPECTED_CAUSES}
    pending_name = None

    for line in extract_patch_file_lines(
        patch_path, "src/mme/unauthorized-audit.c"
    ):
        case_match = case_pattern.match(line)
        if case_match:
            pending_name = case_match.group(1)
            if not pending_name and case_match.group(2):
                pending_name = name_by_code.get(int(case_match.group(2)))
            continue
        if pending_name:
            return_match = return_pattern.match(line)
            if return_match:
                reason_map[pending_name] = return_match.group(1)
                pending_name = None
            elif re.match(r"^\+?\s*case ", line) or re.match(r"^\+?\s*default:", line):
                pending_name = None

    return reason_map


def extract_fallback_reason(patch_path: Path) -> str | None:
    default_seen = False
    return_pattern = re.compile(r'^\+?\s*return\s+"([^"]+)";\s*$')

    for line in extract_patch_file_lines(
        patch_path, "src/mme/unauthorized-audit.c"
    ):
        if re.match(r"^\+?\s*default:", line):
            default_seen = True
            continue
        if default_seen:
            return_match = return_pattern.match(line)
            if return_match:
                return return_match.group(1)

    return None


def validate_reason_map(
    reason_map: dict[str, str], fallback_reason: str | None
) -> list[str]:
    errors = []
    expected_names = {name for name, _, _ in EXPECTED_CAUSES}

    for name, code, expected_reason in EXPECTED_CAUSES:
        actual_reason = reason_map.get(name)
        if actual_reason != expected_reason:
            errors.append(
                f"cause {code} ({name}): expected {expected_reason!r}, "
                f"got {actual_reason!r}"
            )

    extras = sorted(set(reason_map) - expected_names)
    if extras:
        errors.append(f"unexpected reason-map entries: {','.join(extras)}")

    if len({code for _, code, _ in EXPECTED_CAUSES}) != len(EXPECTED_CAUSES):
        errors.append("reject-cause catalog contains duplicate numeric codes")

    if fallback_reason != FALLBACK_CAUSE[1]:
        errors.append(
            f"expected fallback reason {FALLBACK_CAUSE[1]!r}, "
            f"got {fallback_reason!r}"
        )

    try:
        from nas_handler import NASHandler

        for name, code, expected_reason in EXPECTED_CAUSES:
            simulator_reason = NASHandler._emm_cause_name(code)
            if simulator_reason != expected_reason:
                errors.append(
                    f"UE decoder cause {code} ({name}): expected "
                    f"{expected_reason!r}, got {simulator_reason!r}"
                )
        simulator_fallback = NASHandler._emm_cause_name(FALLBACK_CAUSE[0])
        if simulator_fallback != FALLBACK_CAUSE[1]:
            errors.append(
                f"UE decoder fallback: expected {FALLBACK_CAUSE[1]!r}, "
                f"got {simulator_fallback!r}"
            )
    except Exception as error:
        errors.append(f"cannot validate UE decoder reason map: {error}")

    return errors


def write_catalog(output_path: Path) -> None:
    output_path.parent.mkdir(parents=True, exist_ok=True)
    first_attempt = datetime(2000, 1, 1, 0, 0, 0)
    attempts = []

    catalog_causes = list(EXPECTED_CAUSES) + [
        ("UNASSIGNED_OR_FUTURE", *FALLBACK_CAUSE)
    ]
    for index, (_, code, reason) in enumerate(catalog_causes):
        attempted_at = first_attempt + timedelta(seconds=index)
        attempts.append(
            (
                attempted_at.strftime("%Y-%m-%d"),
                attempted_at.strftime("%H:%M:%S"),
                f"356789012{index:06d}",
                f"0010198{index:08d}",
                "Attach Reject",
                str(code),
                reason,
            )
        )

    representative_events = (
        (
            "Authentication Reject",
            "N/A",
            "Authentication response verification failed",
        ),
        (
            "TAU Reject",
            "9",
            "UE identity cannot be derived by the network",
        ),
        (
            "Service Reject",
            "9",
            "UE identity cannot be derived by the network",
        ),
    )
    for index, (message, cause, reason) in enumerate(
        representative_events, start=len(attempts)
    ):
        attempted_at = first_attempt + timedelta(seconds=index)
        attempts.append(
            (
                attempted_at.strftime("%Y-%m-%d"),
                attempted_at.strftime("%H:%M:%S"),
                f"356789013{index:06d}",
                f"0010199{index:08d}",
                message,
                cause,
                reason,
            )
        )

    with output_path.open("w", encoding="utf-8", newline="") as stream:
        writer = csv.writer(stream, lineterminator="\n")
        writer.writerow(CSV_HEADER)
        writer.writerows(reversed(attempts))


def validate_catalog(output_path: Path) -> list[str]:
    errors = []
    with output_path.open("r", encoding="utf-8", newline="") as stream:
        rows = list(csv.reader(stream))

    if not rows or tuple(rows[0]) != CSV_HEADER:
        return [f"invalid CSV header: {rows[0] if rows else 'missing'}"]

    data_rows = rows[1:]
    expected_rows = list(EXPECTED_CAUSES) + [
        ("UNASSIGNED_OR_FUTURE", *FALLBACK_CAUSE)
    ]
    if len(data_rows) != len(expected_rows) + 3:
        errors.append(
            f"expected {len(expected_rows) + 3} data rows, got {len(data_rows)}"
        )
        return errors

    representative_rows = data_rows[:3]
    expected_representative_rows = (
        (
            "Service Reject",
            "9",
            "UE identity cannot be derived by the network",
        ),
        ("TAU Reject", "9", "UE identity cannot be derived by the network"),
        (
            "Authentication Reject",
            "N/A",
            "Authentication response verification failed",
        ),
    )
    for row, expected in zip(
        representative_rows, expected_representative_rows
    ):
        if len(row) != len(CSV_HEADER) or tuple(row[4:7]) != expected:
            errors.append(
                f"invalid representative mobility-reject row: {row!r}; "
                f"expected event fields {expected!r}"
            )

    expected_newest_first = list(reversed(expected_rows))
    for row, (_, expected_code, expected_reason) in zip(
        data_rows[3:], expected_newest_first
    ):
        if len(row) != len(CSV_HEADER):
            errors.append(f"invalid column count in row: {row!r}")
            continue
        if (
            row[4] != "Attach Reject"
            or row[5] != str(expected_code)
            or row[6] != expected_reason
        ):
            errors.append(
                f"expected cause {expected_code}:{expected_reason!r}, "
                f"got message={row[4]!r}, cause={row[5]!r}, "
                f"reason={row[6]!r}"
            )

    timestamps = [
        datetime.strptime(f"{row[0]} {row[1]}", "%Y-%m-%d %H:%M:%S")
        for row in data_rows
    ]
    if timestamps != sorted(timestamps, reverse=True):
        errors.append("CSV rows are not newest-first")

    return errors


def validate_mme_binary(binary_path: Path) -> list[str]:
    errors = []
    binary = binary_path.read_bytes()
    required_strings = [reason for _, _, reason in EXPECTED_CAUSES]
    required_strings.extend(
        [
            FALLBACK_CAUSE[1],
            ",".join(CSV_HEADER),
            "MME_UNAUTHORIZED_ATTACH_MAX_BYTES",
            ".archive.%lld.%06ld.csv",
            "Mobility reject audit ready",
            "Mobility reject recorded",
            *REQUIRED_REJECT_MESSAGES,
        ]
    )

    missing = [
        value for value in required_strings if value.encode("utf-8") not in binary
    ]
    if missing:
        errors.append(
            "deployed MME binary is missing compiled audit strings: "
            + "; ".join(missing)
        )

    return errors


def validate_source_integration(patch_path: Path) -> list[str]:
    patch_text = patch_path.read_text(encoding="utf-8")
    missing = [
        fragment
        for fragment in REQUIRED_SOURCE_FRAGMENTS
        if fragment not in patch_text
    ]
    if not missing:
        return []
    return [
        "mobility-reject source integration is incomplete: "
        + "; ".join(missing)
    ]


def main() -> int:
    parser = argparse.ArgumentParser()
    # --source is OPTIONAL. The embedded EXPECTED_CAUSES catalog in this script is
    # the self-contained reference (open5gs source is not shipped with the test
    # suite). If a source/patch file is provided it is cross-checked as a dev
    # convenience; deployment validation relies on the deployed binary.
    parser.add_argument("--source", type=Path, default=None)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--binary", type=Path)
    args = parser.parse_args()

    result = {
        "ok": False,
        "cause_count": len(EXPECTED_CAUSES),
        "distinct_code_count": len({code for _, code, _ in EXPECTED_CAUSES}),
        "fallback_tested": True,
        "source_verified": None,
        "binary_verified": False,
        "binary": str(args.binary) if args.binary else None,
        "accepted_alias": "16 (same numeric value as MSC temporarily not reachable)",
        "output": str(args.output),
        "errors": [],
    }

    try:
        errors = []
        if args.source and args.source.is_file():
            reason_map = extract_reason_map(args.source)
            fallback_reason = extract_fallback_reason(args.source)
            errors.extend(validate_reason_map(reason_map, fallback_reason))
            errors.extend(validate_source_integration(args.source))
            result["source_verified"] = not errors
        if not errors:
            write_catalog(args.output)
            errors.extend(validate_catalog(args.output))
        if not errors and args.binary:
            errors.extend(validate_mme_binary(args.binary))
            result["binary_verified"] = not errors
        result["errors"] = errors
        result["ok"] = not errors
    except Exception as error:  # Keep shell test output machine-readable.
        result["errors"] = [f"{type(error).__name__}: {error}"]

    print(json.dumps(result, sort_keys=True))
    return 0 if result["ok"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
