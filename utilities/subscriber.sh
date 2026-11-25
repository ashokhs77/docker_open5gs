#!/usr/bin/env bash
# Add or delete PyHSS subscribers in one step (AUC + SUBSCRIBER + IMS_SUBSCRIBER).
#
# Put IMSI and MSISDN of each subscriber in subscribers_list (next to this script):
#     001010100008004 9876548004
#
# Usage:
#   bash subscriber.sh                       # add everyone in subscribers_list
#   bash subscriber.sh del                   # delete everyone in subscribers_list
#   bash subscriber.sh add <imsi> <msisdn>   # add one
#   bash subscriber.sh del <imsi>            # delete one
#   bash subscriber.sh show <imsi>           # show what PyHSS has for an IMSI
#
# Ki, OPc, AMF and APNs are the same for every subscriber: edit them below.
# Subscribers already in PyHSS are skipped. The IMS domain uses MCC/MNC from the
# repo .env (MNC padded to 3 digits).
#
# Options:
#   --list FILE          use another list file
#   --api URL            PyHSS REST API (default: $PYHSS_API or http://127.0.0.1:8080)
#   --mcc MCC --mnc MNC  override the PLMN from .env
#
# Set PYHSS_PROV_KEY if PyHSS has lock_provisioning enabled (sent as Provisioning-Key).

# ---------- fixed values for every subscriber ----------
KI=5e4ab35891375d2aee812e67c309a629
OPC=24c2d90f545ae2f7a87cacdc705a7950
AMF=8000
APN_LIST="1,2"
DEFAULT_APN=1

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${ENV_FILE:-$SCRIPT_DIR/../.env}"
LIST="$SCRIPT_DIR/subscribers_list"
API="${PYHSS_API:-http://127.0.0.1:8080}"
MCC="" MNC=""

usage() { sed -n '2,/^$/s/^# \{0,1\}//p' "$0"; }
die()   { echo "ERROR: $*" >&2; exit 1; }
err()   { echo "ERROR: $*" >&2; }

# ---------- helpers ----------

env_get() {   # value of KEY=... from .env
    [ -f "$ENV_FILE" ] || return 0
    sed -n "s/^[[:space:]]*$1=//p" "$ENV_FILE" | head -1 | sed 's/[[:space:]]*#.*//' | tr -d '\r"'"'"
}

# api METHOD PATH [JSON] -> sets HTTP_CODE and BODY; returns 1 if PyHSS is unreachable
api() {
    local out rc args=(-s -m 10 -X "$1" -w $'\n%{http_code}' -H 'Content-Type: application/json')
    [ -n "${PYHSS_PROV_KEY:-}" ] && args+=(-H "Provisioning-Key: $PYHSS_PROV_KEY")
    [ $# -ge 3 ] && args+=(--data "$3")
    out=$(curl "${args[@]}" "$API/$2" </dev/null); rc=$?
    if [ $rc -ne 0 ]; then HTTP_CODE=000; BODY="curl exit $rc"; return 1; fi
    HTTP_CODE=${out##*$'\n'}
    BODY=${out%$'\n'*}
}

json_id()    { printf '%s' "$BODY" | tr -d '\n' | grep -o "\"$1\"[[:space:]]*:[[:space:]]*[0-9]\+" | head -1 | grep -o '[0-9]\+$'; }
json_str()   { printf '%s' "$BODY" | tr -d '\n' | grep -o "\"$1\"[[:space:]]*:[[:space:]]*\"[^\"]*\"" | head -1 | sed 's/.*:[[:space:]]*"//; s/"$//'; }
short_body() { printf '%s' "$BODY" | tr -d '\n' | tr -s ' ' | cut -c1-300; }

# find_id PATH KEY -> sets ID; returns 1 if not found.
# (PyHSS answers an unknown IMSI with 200 "null" or 400, so check for the id field.)
find_id() {
    ID=""
    api GET "$1" || die "cannot reach PyHSS API at $API ($BODY)"
    [ "$HTTP_CODE" = 200 ] && ID=$(json_id "$2")
    [ -n "$ID" ]
}

# create PATH KEY JSON -> sets ID of the new record; on failure sets ERR
create() {
    ID="" ERR=""
    api PUT "$1" "$3" || { ERR="cannot reach PyHSS API at $API ($BODY)"; return 1; }
    ID=$(json_id "$2")
    [ "$HTTP_CODE" = 200 ] && [ -n "$ID" ] && return 0
    ERR="HTTP $HTTP_CODE: $(short_body)"
    return 1
}

# ims_domain IMSI -> prints ims.mncXXX.mccYYY.3gppnetwork.org (MNC padded to 3 digits)
ims_domain() {
    local imsi=$1 mcc=$MCC mnc=$MNC
    [ -z "$mcc" ] && mcc=$(env_get MCC)
    [ -z "$mnc" ] && mnc=$(env_get MNC)
    if [ -z "$mcc" ] || [ -z "$mnc" ]; then
        mcc=${imsi:0:3} mnc=${imsi:3:2}
        echo "NOTE: no --mcc/--mnc and no MCC/MNC in $ENV_FILE; using $mcc/$mnc from the IMSI (pass --mnc for a 3-digit MNC)" >&2
    fi
    [[ $mcc =~ ^[0-9]{3}$ ]]   || { err "bad MCC '$mcc'"; return 1; }
    [[ $mnc =~ ^[0-9]{2,3}$ ]] || { err "bad MNC '$mnc'"; return 1; }
    local mnc3=$mnc
    while [ ${#mnc3} -lt 3 ]; do mnc3="0$mnc3"; done
    if [[ $imsi != "$mcc$mnc"* && $imsi != "$mcc$mnc3"* ]]; then
        echo "NOTE: IMSI $imsi is not in PLMN $mcc/$mnc; IMS domain still uses $mcc/$mnc" >&2
    fi
    echo "ims.mnc${mnc3}.mcc${mcc}.3gppnetwork.org"
}

# ---------- commands (return 0 = done, 2 = skipped, 1 = failed) ----------

do_add() {   # imsi msisdn
    local imsi=$1 msisdn=${2#+} domain

    [[ $imsi =~ ^[0-9]{6,15}$ ]]   || { err "bad IMSI '$imsi' (6-15 digits)"; return 1; }
    [[ $msisdn =~ ^[0-9]{1,15}$ ]] || { err "$imsi: bad MSISDN '$msisdn' (digits only)"; return 1; }
    domain=$(ims_domain "$imsi") || return 1

    # Skip if fully there; refuse if only partly there, so we never half-overwrite.
    local have=0 exist=""
    find_id "auc/imsi/$imsi" auc_id                                      && { have=$((have + 1)); exist+=" AUC(auc_id=$ID)"; }
    find_id "subscriber/imsi/$imsi" subscriber_id                        && { have=$((have + 1)); exist+=" SUBSCRIBER(subscriber_id=$ID)"; }
    find_id "ims_subscriber/ims_subscriber_imsi/$imsi" ims_subscriber_id && { have=$((have + 1)); exist+=" IMS_SUBSCRIBER(ims_subscriber_id=$ID)"; }
    if [ $have -eq 3 ]; then
        echo "SKIP $imsi already in PyHSS:$exist"
        return 2
    fi
    if [ $have -gt 0 ]; then
        err "$imsi is partly in PyHSS:$exist"
        echo "       Delete it first: bash $0 del $imsi" >&2
        return 1
    fi
    if find_id "ims_subscriber/ims_subscriber_msisdn/$msisdn" ims_subscriber_id; then
        err "$imsi: MSISDN $msisdn is already used by IMS_SUBSCRIBER(ims_subscriber_id=$ID)"
        return 1
    fi

    local auc_id made=""
    if ! create auc/ auc_id \
        "{\"ki\": \"$KI\", \"opc\": \"$OPC\", \"amf\": \"$AMF\", \"sqn\": 0, \"imsi\": \"$imsi\"}"; then
        err "$imsi: AUC create failed: $ERR"
        echo "       Nothing was created." >&2
        return 1
    fi
    auc_id=$ID; made="AUC(auc_id=$auc_id)"

    if ! create subscriber/ subscriber_id \
        "{\"imsi\": \"$imsi\", \"enabled\": true, \"auc_id\": $auc_id, \"default_apn\": $DEFAULT_APN, \"apn_list\": \"$APN_LIST\", \"msisdn\": \"$msisdn\", \"ue_ambr_dl\": 0, \"ue_ambr_ul\": 0}"; then
        err "$imsi: SUBSCRIBER create failed: $ERR"
        echo "       Already created: $made   To undo: bash $0 del $imsi" >&2
        return 1
    fi
    made+=" SUBSCRIBER(subscriber_id=$ID)"

    if ! create ims_subscriber/ ims_subscriber_id \
        "{\"imsi\": \"$imsi\", \"msisdn\": \"$msisdn\", \"sh_profile\": \"string\", \"scscf_peer\": \"scscf.$domain\", \"msisdn_list\": \"[$msisdn]\", \"ifc_path\": \"default_ifc.xml\", \"scscf\": \"sip:scscf.$domain:6060\", \"scscf_realm\": \"$domain\"}"; then
        err "$imsi: IMS_SUBSCRIBER create failed: $ERR"
        echo "       Already created: $made   To undo: bash $0 del $imsi" >&2
        return 1
    fi
    made+=" IMS_SUBSCRIBER(ims_subscriber_id=$ID)"

    echo "OK   added $imsi msisdn=$msisdn: $made  [$domain]"
}

do_del() {   # imsi
    local imsi=$1 deleted="" missing="" step label path key base
    [[ $imsi =~ ^[0-9]{6,15}$ ]] || { err "bad IMSI '$imsi' (6-15 digits)"; return 1; }

    # Order matters: SUBSCRIBER points to AUC, so AUC goes last.
    for step in "IMS_SUBSCRIBER ims_subscriber/ims_subscriber_imsi ims_subscriber_id ims_subscriber" \
                "SUBSCRIBER subscriber/imsi subscriber_id subscriber" \
                "AUC auc/imsi auc_id auc"; do
        read -r label path key base <<< "$step"
        if ! find_id "$path/$imsi" "$key"; then
            missing+=" $label"
            continue
        fi
        api DELETE "$base/$ID" || die "cannot reach PyHSS API at $API ($BODY)"
        if [ "$HTTP_CODE" != 200 ]; then
            err "$imsi: $label($key=$ID) delete failed: HTTP $HTTP_CODE: $(short_body)"
            echo "       Deleted so far:${deleted:- nothing}. Stopped here." >&2
            return 1
        fi
        deleted+=" $label($key=$ID)"
    done

    if [ -z "$deleted" ]; then
        echo "SKIP $imsi not in PyHSS"
        return 2
    fi
    echo "OK   deleted $imsi:$deleted${missing:+   (not found, skipped:$missing)}"
}

do_show() {  # imsi
    local imsi=$1
    [[ $imsi =~ ^[0-9]{6,15}$ ]] || { err "bad IMSI '$imsi' (6-15 digits)"; return 1; }
    echo "$imsi:"
    if find_id "auc/imsi/$imsi" auc_id; then echo "  AUC             auc_id=$ID amf=$(json_str amf)"
    else echo "  AUC             not found"; fi
    if find_id "subscriber/imsi/$imsi" subscriber_id; then
        echo "  SUBSCRIBER      subscriber_id=$ID auc_id=$(json_id auc_id) msisdn=$(json_str msisdn) apn_list=$(json_str apn_list) default_apn=$(json_id default_apn)"
    else echo "  SUBSCRIBER      not found"; fi
    if find_id "ims_subscriber/ims_subscriber_imsi/$imsi" ims_subscriber_id; then
        echo "  IMS_SUBSCRIBER  ims_subscriber_id=$ID msisdn=$(json_str msisdn) scscf=$(json_str scscf)"
    else echo "  IMS_SUBSCRIBER  not found"; fi
}

do_list() {  # add|del: run for every "IMSI MSISDN" line in $LIST
    local mode=$1 line imsi msisdn rest ok=0 skip=0 bad=0
    [ -f "$LIST" ] || die "list file not found: $LIST"
    echo "Using $LIST"
    while IFS= read -r line <&3 || [ -n "$line" ]; do
        line=${line%%#*}; line=${line//$'\r'/}; line=${line//,/ }
        read -r imsi msisdn rest <<< "$line"
        [ -z "${imsi:-}" ] && continue
        [[ $imsi =~ ^[iI][mM][sS][iI] ]] && continue   # header line
        if [ "$mode" = add ]; then do_add "$imsi" "${msisdn:-}"; else do_del "$imsi"; fi
        case $? in 0) ok=$((ok + 1)) ;; 2) skip=$((skip + 1)) ;; *) bad=$((bad + 1)) ;; esac
    done 3< "$LIST"
    [ $((ok + skip + bad)) -eq 0 ] && die "no subscribers in $LIST"
    local word=added; [ "$mode" = del ] && word=deleted
    echo "Done: $ok $word, $skip skipped, $bad failed"
    [ $bad -eq 0 ]
}

# ---------- main ----------

ARGS=()
while [ $# -gt 0 ]; do
    case "$1" in
        --list) LIST=${2:?--list needs a file}; shift 2 ;;
        --api)  API=${2:?--api needs a URL}; shift 2 ;;
        --mcc)  MCC=${2:?--mcc needs a value}; shift 2 ;;
        --mnc)  MNC=${2:?--mnc needs a value}; shift 2 ;;
        -h|--help) usage; exit 0 ;;
        --*)    die "unknown option $1 (see --help)" ;;
        *)      ARGS+=("$1"); shift ;;
    esac
done
set -- ${ARGS[@]+"${ARGS[@]}"}
API=${API%/}
command -v curl >/dev/null || die "curl is not installed"
[[ $KI =~ ^[0-9a-fA-F]{32}$ ]]           || die "KI in $0 must be 32 hex chars"
[[ $OPC =~ ^[0-9a-fA-F]{32}$ ]]          || die "OPC in $0 must be 32 hex chars"
[[ $AMF =~ ^[0-9a-fA-F]{4}$ ]]           || die "AMF in $0 must be 4 hex chars"
[[ $APN_LIST =~ ^[0-9]+(,[0-9]+)*$ ]]    || die "APN_LIST in $0 must look like 1,2"
[[ $DEFAULT_APN =~ ^[0-9]+$ ]]           || die "DEFAULT_APN in $0 must be a number"

case "${1:-add}" in
    add)  if   [ $# -le 1 ]; then do_list add
          elif [ $# -eq 3 ]; then do_add "$2" "$3"
          else die "usage: add [<imsi> <msisdn>]"; fi ;;
    del)  if   [ $# -le 1 ]; then do_list del
          elif [ $# -eq 2 ]; then do_del "$2"
          else die "usage: del [<imsi>]"; fi ;;
    show) [ $# -eq 2 ] || die "usage: show <imsi>"; do_show "$2" ;;
    *)    usage; exit 1 ;;
esac
