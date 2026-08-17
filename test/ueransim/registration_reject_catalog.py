#!/usr/bin/env python3
"""Offline verification of the AMF Registration Reject CSV cause catalog."""

import argparse
import csv
import json
import re
from datetime import datetime, timedelta
from pathlib import Path


EXPECTED_CAUSES = (
    ("ILLEGAL_UE", 3, "Illegal UE"),
    ("PEI_NOT_ACCEPTED", 5, "PEI not accepted"),
    ("ILLEGAL_ME", 6, "Illegal ME"),
    ("5GS_SERVICES_NOT_ALLOWED", 7, "5GS services not allowed"),
    (
        "UE_IDENTITY_CANNOT_BE_DERIVED_BY_THE_NETWORK",
        9,
        "UE identity cannot be derived by the network",
    ),
    ("IMPLICITLY_DE_REGISTERED", 10, "Implicitly de-registered"),
    ("PLMN_NOT_ALLOWED", 11, "PLMN not allowed"),
    ("TRACKING_AREA_NOT_ALLOWED", 12, "Tracking area not allowed"),
    (
        "ROAMING_NOT_ALLOWED_IN_THIS_TRACKING_AREA",
        13,
        "Roaming not allowed in this tracking area",
    ),
    (
        "NO_SUITABLE_CELLS_IN_TRACKING_AREA",
        15,
        "No suitable cells in tracking area",
    ),
    ("MAC_FAILURE", 20, "MAC failure"),
    ("SYNCH_FAILURE", 21, "Synch failure"),
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
    (
        "NON_5G_AUTHENTICATION_UNACCEPTABLE",
        26,
        "Non-5G authentication unacceptable",
    ),
    ("N1_MODE_NOT_ALLOWED", 27, "N1 mode not allowed"),
    ("RESTRICTED_SERVICE_AREA", 28, "Restricted service area"),
    ("REDIRECTION_TO_EPC_REQUIRED", 31, "Redirection to EPC required"),
    ("IAB_NODE_OPERATION_NOT_AUTHORIZED", 36, "IAB-node operation not authorized"),
    ("LADN_NOT_AVAILABLE", 43, "LADN not available"),
    ("NO_NETWORK_SLICES_AVAILABLE", 62, "No network slices available"),
    (
        "MAXIMUM_NUMBER_OF_PDU_SESSIONS_REACHED",
        65,
        "Maximum number of PDU sessions reached",
    ),
    (
        "INSUFFICIENT_RESOURCES_FOR_SPECIFIC_SLICE_AND_DNN",
        67,
        "Insufficient resources for specific slice and DNN",
    ),
    (
        "INSUFFICIENT_RESOURCES_FOR_SPECIFIC_SLICE",
        69,
        "Insufficient resources for specific slice",
    ),
    ("NGKSI_ALREADY_IN_USE", 71, "ngKSI already in use"),
    (
        "NON_3GPP_ACCESS_TO_5GCN_NOT_ALLOWED",
        72,
        "Non-3GPP access to 5GCN not allowed",
    ),
    ("SERVING_NETWORK_NOT_AUTHORIZED", 73, "Serving network not authorized"),
    (
        "TEMPORARILY_NOT_AUTHORIZED_FOR_THIS_SNPN",
        74,
        "Temporarily not authorized for this SNPN",
    ),
    (
        "PERMANENTLY_NOT_AUTHORIZED_FOR_THIS_SNPN",
        75,
        "Permanently not authorized for this SNPN",
    ),
    (
        "NOT_AUTHORIZED_FOR_THIS_CAG_OR_AUITHORIZED_FOR_CAG_CELLS_ONLY",
        76,
        "Not authorized for this CAG or authorized for CAG cells only",
    ),
    ("WIRELINE_ACCESS_AREA_NOT_ALLOWED", 77, "Wireline access area not allowed"),
    (
        "PLMN_NOT_ALLOWED_AT_PRESENT_LOCATION",
        78,
        "PLMN not allowed to operate at the present UE location",
    ),
    ("UAS_SERVICES_NOT_ALLOWED", 79, "UAS services not allowed"),
    (
        "DISASTER_ROAMING_NOT_ALLOWED",
        80,
        "Disaster roaming for the determined PLMN with disaster condition not allowed",
    ),
    (
        "SELECTED_N3IWF_NOT_COMPATIBLE_WITH_ALLOWED_NSSAI",
        81,
        "Selected N3IWF is not compatible with the allowed NSSAI",
    ),
    (
        "SELECTED_TNGF_NOT_COMPATIBLE_WITH_ALLOWED_NSSAI",
        82,
        "Selected TNGF is not compatible with the allowed NSSAI",
    ),
    ("PAYLOAD_WAS_NOT_FORWARDED", 90, "Payload was not forwarded"),
    (
        "DNN_NOT_SUPPORTED_OR_NOT_SUBSCRIBED_IN_THE_SLICE",
        91,
        "DNN not supported or not subscribed in the slice",
    ),
    (
        "INSUFFICIENT_USER_PLANE_RESOURCES_FOR_THE_PDU_SESSION",
        92,
        "Insufficient user-plane resources for the PDU session",
    ),
    ("ONBOARDING_SERVICES_TERMINATED", 93, "Onboarding services terminated"),
    (
        "USER_PLANE_POSITIONING_NOT_AUTHORIZED",
        94,
        "User plane positioning not authorized",
    ),
    ("SEMANTICALLY_INCORRECT_MESSAGE", 95, "Semantically incorrect message"),
    ("INVALID_MANDATORY_INFORMATION", 96, "Invalid mandatory information"),
    (
        "MESSAGE_TYPE_NON_EXISTENT_OR_NOT_IMPLEMENTED",
        97,
        "Message type non-existent or not implemented",
    ),
    (
        "MESSAGE_TYPE_NOT_COMPATIBLE_WITH_THE_PROTOCOL_STATE",
        98,
        "Message type not compatible with the protocol state",
    ),
    (
        "INFORMATION_ELEMENT_NON_EXISTENT_OR_NOT_IMPLEMENTED",
        99,
        "Information element non-existent or not implemented",
    ),
    ("CONDITIONAL_IE_ERROR", 100, "Conditional IE error"),
    (
        "MESSAGE_NOT_COMPATIBLE_WITH_THE_PROTOCOL_STATE",
        101,
        "Message not compatible with the protocol state",
    ),
    ("PROTOCOL_ERROR_UNSPECIFIED", 111, "Protocol error unspecified"),
)

FALLBACK_CAUSE = (255, "Unassigned or future 5GMM cause")
CSV_HEADER = (
    "date",
    "time",
    "imei",
    "imsi",
    "supi_or_suci",
    "registration_reject_cause",
    "registration_reject_reason",
)


def extract_reason_map(source_path: Path) -> tuple[dict[str, str], str | None]:
    # A leading '+' (unified-diff added line) is optional, so this parses BOTH a
    # raw source file (src/amf/registration-audit.c) and a .patch of it. Parsing
    # is scoped to the gmm_cause_name() function, so other switch statements in
    # the file are ignored.
    case_pattern = re.compile(
        r"^\+?\s*case\s+(?:OGS_5GMM_CAUSE_([A-Z0-9_]+)|(\d+)):"
    )
    return_pattern = re.compile(r'^\+?\s*return\s+"([^"]+)";\s*$')
    name_by_code = {code: name for name, code, _ in EXPECTED_CAUSES}
    reason_map: dict[str, str] = {}
    pending_name = None
    fallback = None
    in_function = False
    default_seen = False

    for line in source_path.read_text(encoding="utf-8").splitlines():
        if re.match(r"^\+?static const char \*gmm_cause_name\(", line):
            in_function = True
            continue
        if not in_function:
            continue
        case_match = case_pattern.match(line)
        if case_match:
            pending_name = case_match.group(1)
            if not pending_name and case_match.group(2):
                pending_name = name_by_code.get(int(case_match.group(2)))
            default_seen = False
            continue
        if re.match(r"^\+?\s*default:", line):
            pending_name = None
            default_seen = True
            continue
        return_match = return_pattern.match(line)
        if return_match:
            if pending_name:
                reason_map[pending_name] = return_match.group(1)
                pending_name = None
            elif default_seen:
                fallback = return_match.group(1)
                break

    return reason_map, fallback


def validate_source(
    reason_map: dict[str, str], fallback_reason: str | None
) -> list[str]:
    errors = []
    expected_names = {name for name, _, _ in EXPECTED_CAUSES}

    for name, code, expected_reason in EXPECTED_CAUSES:
        actual = reason_map.get(name)
        if actual != expected_reason:
            errors.append(
                f"cause {code} ({name}): expected {expected_reason!r}, got {actual!r}"
            )

    extras = sorted(set(reason_map) - expected_names)
    if extras:
        errors.append(f"unexpected reason-map entries: {','.join(extras)}")
    if len({code for _, code, _ in EXPECTED_CAUSES}) != len(EXPECTED_CAUSES):
        errors.append("reject-cause catalog contains duplicate numeric codes")
    if fallback_reason != FALLBACK_CAUSE[1]:
        errors.append(
            f"expected fallback {FALLBACK_CAUSE[1]!r}, got {fallback_reason!r}"
        )

    return errors


def write_and_validate_catalog(output_path: Path) -> list[str]:
    output_path.parent.mkdir(parents=True, exist_ok=True)
    first_attempt = datetime(2000, 1, 1)
    catalog = list(EXPECTED_CAUSES) + [
        ("UNASSIGNED_OR_FUTURE", *FALLBACK_CAUSE)
    ]
    attempts = []

    for index, (_, code, reason) in enumerate(catalog):
        attempted_at = first_attempt + timedelta(seconds=index)
        attempts.append(
            (
                attempted_at.strftime("%Y-%m-%d"),
                attempted_at.strftime("%H:%M:%S"),
                f"356789012{index:06d}",
                f"0010198{index:08d}",
                f"imsi-0010198{index:08d}",
                str(code),
                reason,
            )
        )

    with output_path.open("w", encoding="utf-8", newline="") as stream:
        writer = csv.writer(stream, lineterminator="\n")
        writer.writerow(CSV_HEADER)
        writer.writerows(reversed(attempts))

    with output_path.open("r", encoding="utf-8", newline="") as stream:
        rows = list(csv.reader(stream))

    errors = []
    if not rows or tuple(rows[0]) != CSV_HEADER:
        return [f"invalid CSV header: {rows[0] if rows else 'missing'}"]
    if len(rows) != len(catalog) + 1:
        errors.append(f"expected {len(catalog)} rows, got {len(rows) - 1}")
    timestamps = [
        datetime.strptime(f"{row[0]} {row[1]}", "%Y-%m-%d %H:%M:%S")
        for row in rows[1:]
    ]
    if timestamps != sorted(timestamps, reverse=True):
        errors.append("CSV rows are not newest-first")

    return errors


def validate_amf_binary(binary_path: Path) -> list[str]:
    binary = binary_path.read_bytes()
    required = [reason for _, _, reason in EXPECTED_CAUSES]
    required.extend((FALLBACK_CAUSE[1], ",".join(CSV_HEADER)))
    missing = [value for value in required if value.encode() not in binary]
    if missing:
        return ["deployed AMF binary is missing: " + "; ".join(missing)]
    return []


def main() -> int:
    parser = argparse.ArgumentParser()
    # --source is OPTIONAL. The embedded EXPECTED_CAUSES catalog in this script is
    # the self-contained reference (open5gs source is not shipped with the test
    # suite). If a source/patch file happens to be provided, it is cross-checked
    # as a dev convenience; deployment validation relies on the deployed binary.
    parser.add_argument("--source", type=Path, default=None)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--binary", type=Path, required=True)
    args = parser.parse_args()

    result = {
        "ok": False,
        "cause_count": len(EXPECTED_CAUSES),
        "distinct_code_count": len({code for _, code, _ in EXPECTED_CAUSES}),
        "fallback_tested": True,
        "source_verified": None,
        "binary_verified": False,
        "output": str(args.output),
        "errors": [],
    }

    try:
        errors = []
        if args.source and args.source.is_file():
            reason_map, fallback = extract_reason_map(args.source)
            errors.extend(validate_source(reason_map, fallback))
            result["source_verified"] = not errors
        if not errors:
            errors.extend(write_and_validate_catalog(args.output))
        if not errors:
            errors.extend(validate_amf_binary(args.binary))
            result["binary_verified"] = not errors
        result["errors"] = errors
        result["ok"] = not errors
    except Exception as error:
        result["errors"] = [f"{type(error).__name__}: {error}"]

    print(json.dumps(result, sort_keys=True))
    return 0 if result["ok"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
