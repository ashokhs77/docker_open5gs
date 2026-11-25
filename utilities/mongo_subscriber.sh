#!/usr/bin/env bash
# Add or delete Open5GS subscribers in MongoDB (what the WebUI shows), from subscribers_list.
#
# Usage:
#   bash mongo_subscriber.sh                       # update profile "UE", then add everyone in subscribers_list
#   bash mongo_subscriber.sh del                   # delete everyone in subscribers_list
#   bash mongo_subscriber.sh add <imsi> <msisdn>   # add one
#   bash mongo_subscriber.sh del <imsi>            # delete one
#   bash mongo_subscriber.sh profile               # only create/update the WebUI profile "UE"
#
# Every subscriber, and the WebUI profile "UE", gets the same values: Ki/OPc/AMF
# below, and the QoS further down (internet 5QI 9; ims 5QI 5; voice 5QI 1 at
# 128 Kbps; video 5QI 2 at MBR 1 Mbps / GBR 512 Kbps). Subscribers already in
# MongoDB are skipped. Uses the same subscribers_list as subscriber.sh (PyHSS).
# Run it on the docker host.
#
# Options:
#   --list FILE        use another list file
#   --container NAME   MongoDB container (default: mongo)

# ---------- fixed values for every subscriber ----------
KI=5e4ab35891375d2aee812e67c309a629
OPC=24c2d90f545ae2f7a87cacdc705a7950
AMF=8000
PROFILE="UE"

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIST="$SCRIPT_DIR/subscribers_list"
CONTAINER="${MONGO_CONTAINER:-mongo}"

usage() { sed -n '2,/^$/s/^# \{0,1\}//p' "$0"; }
die()   { echo "ERROR: $*" >&2; exit 1; }
err()   { echo "ERROR: $*" >&2; }

# ---------- MongoDB side (JavaScript, works with mongosh and the old mongo shell) ----------
# Every number is stored as NumberInt: Open5GS only reads int32 values.
# Units: 1 Kbps, 2 Mbps, 3 Gbps.  ARP pre-emption: 1 Disabled, 2 Enabled.
# Session type: 1 IPv4, 3 IPv4v6.
JS_MAIN=$(cat <<'EOF'
function I(n) { return NumberInt(n); }
function bw(dl, dlUnit, ul, ulUnit) {
  return { downlink: { value: I(dl), unit: I(dlUnit) }, uplink: { value: I(ul), unit: I(ulUnit) } };
}
function arp(level, cap, vul) {
  return { priority_level: I(level), pre_emption_capability: I(cap), pre_emption_vulnerability: I(vul) };
}
var KBPS = 1, MBPS = 2, GBPS = 3, DIS = 1, EN = 2;

function slices() {
  return [{ sst: I(1), sd: "000001", default_indicator: true, session: [
    { name: "internet", type: I(3), lbo_roaming_allowed: false,
      qos: { index: I(9), arp: arp(8, DIS, DIS) },
      ambr: bw(1, GBPS, 1, GBPS),
      pcc_rule: [] },
    { name: "ims", type: I(1), lbo_roaming_allowed: false,
      qos: { index: I(5), arp: arp(1, DIS, DIS) },
      ambr: bw(3850, KBPS, 1520, KBPS),
      pcc_rule: [
        // voice: 5QI 1, MBR/GBR 128 Kbps
        { flow: [], qos: { index: I(1), arp: arp(2, EN, EN), mbr: bw(128, KBPS, 128, KBPS), gbr: bw(128, KBPS, 128, KBPS) } },
        // video: 5QI 2, MBR 1 Mbps, GBR 512 Kbps
        { flow: [], qos: { index: I(2), arp: arp(4, EN, EN), mbr: bw(1, MBPS, 1, MBPS), gbr: bw(512, KBPS, 512, KBPS) } }
      ] }
  ] }];
}

function security() { return { k: KI, op: null, opc: OPC, amf: AMF }; }

function profileDoc() {
  return { schema_version: I(1), title: PROFILE, msisdn: [], imeisv: [],
    security: security(), ambr: bw(1, GBPS, 1, GBPS), slice: slices(),
    subscriber_status: I(0), operator_determined_barring: I(0), __v: I(0) };
}

function subscriberDoc(imsi, msisdn) {
  return { schema_version: I(1), imsi: imsi, msisdn: [msisdn], imeisv: [],
    mme_host: [], mme_realm: [], purge_flag: [],
    security: security(), ambr: bw(1, GBPS, 1, GBPS), slice: slices(),
    access_restriction_data: I(32), subscriber_status: I(0), operator_determined_barring: I(0),
    network_access_mode: I(0), subscribed_rau_tau_timer: I(12), __v: I(0) };
}

var ok = 0, skip = 0, bad = BAD;

function saveProfile() {
  try {
    var r = db.profiles.replaceOne({ title: PROFILE }, profileDoc(), { upsert: true });
    print("OK   profile " + PROFILE + (r.matchedCount ? " updated" : " created"));
  } catch (e) {
    print("ERROR: profile " + PROFILE + ": " + e);
    bad++;
  }
}

function addAll() {
  LIST.forEach(function (s) {
    if (db.subscribers.findOne({ imsi: s[0] })) {
      print("SKIP " + s[0] + " already in MongoDB");
      skip++;
      return;
    }
    try {
      db.subscribers.insertOne(subscriberDoc(s[0], s[1]));
      print("OK   added " + s[0] + " msisdn=" + s[1]);
      ok++;
    } catch (e) {
      print("ERROR: " + s[0] + ": " + e);
      bad++;
    }
  });
}

function delAll() {
  LIST.forEach(function (s) {
    var r = db.subscribers.deleteOne({ imsi: s[0] });
    if (r.deletedCount) { print("OK   deleted " + s[0]); ok++; }
    else { print("SKIP " + s[0] + " not in MongoDB"); skip++; }
  });
}

function finish(word) {
  if (SUMMARY) print("Done: " + ok + " " + word + ", " + skip + " skipped, " + bad + " failed");
  quit(bad ? 1 : 0);
}
EOF
)

# ---------- bash side ----------

ENTRIES="" BAD=0 COUNT=0

add_entry() {   # mode imsi [msisdn]: validate and add to the JS list
    local imsi=$2 msisdn=${3:-}
    msisdn=${msisdn#+}
    COUNT=$((COUNT + 1))
    [[ $imsi =~ ^[0-9]{6,15}$ ]] || { err "bad IMSI '$imsi' (6-15 digits)"; BAD=$((BAD + 1)); return; }
    if [ "$1" = add ] && ! [[ $msisdn =~ ^[0-9]{1,15}$ ]]; then
        err "$imsi: bad MSISDN '$msisdn' (digits only)"; BAD=$((BAD + 1)); return
    fi
    ENTRIES+="[\"$imsi\",\"$msisdn\"],"
}

read_list() {   # mode: every "IMSI MSISDN" line in $LIST
    local line imsi msisdn rest
    [ -f "$LIST" ] || die "list file not found: $LIST"
    echo "Using $LIST"
    while IFS= read -r line <&3 || [ -n "$line" ]; do
        line=${line%%#*}; line=${line//$'\r'/}; line=${line//,/ }
        read -r imsi msisdn rest <<< "$line"
        [ -z "${imsi:-}" ] && continue
        [[ $imsi =~ ^[iI][mM][sS][iI] ]] && continue   # header line
        add_entry "$1" "$imsi" "${msisdn:-}"
    done 3< "$LIST"
    [ $COUNT -gt 0 ] || die "no subscribers in $LIST"
}

run_js() {   # summary(true|false) actions
    local sh
    command -v docker >/dev/null || die "docker is not installed"
    sh=$(docker exec "$CONTAINER" sh -c 'command -v mongosh >/dev/null && echo mongosh || echo mongo' 2>/dev/null) \
        || die "MongoDB container '$CONTAINER' is not running (use --container NAME)"
    docker exec "$CONTAINER" "$sh" --quiet open5gs --eval "
var KI = \"$KI\", OPC = \"$OPC\", AMF = \"$AMF\", PROFILE = \"$PROFILE\";
var LIST = [${ENTRIES%,}], BAD = $BAD, SUMMARY = $1;
$JS_MAIN
$2"
}

ARGS=()
while [ $# -gt 0 ]; do
    case "$1" in
        --list)      LIST=${2:?--list needs a file}; shift 2 ;;
        --container) CONTAINER=${2:?--container needs a name}; shift 2 ;;
        -h|--help)   usage; exit 0 ;;
        --*)         die "unknown option $1 (see --help)" ;;
        *)           ARGS+=("$1"); shift ;;
    esac
done
set -- ${ARGS[@]+"${ARGS[@]}"}

[[ $KI =~ ^[0-9a-fA-F]{32}$ ]]       || die "KI in $0 must be 32 hex chars"
[[ $OPC =~ ^[0-9a-fA-F]{32}$ ]]      || die "OPC in $0 must be 32 hex chars"
[[ $AMF =~ ^[0-9a-fA-F]{4}$ ]]       || die "AMF in $0 must be 4 hex chars"
[[ $PROFILE =~ ^[A-Za-z0-9_.\ -]+$ ]] || die "PROFILE in $0: letters, digits, space, . _ - only"

case "${1:-add}" in
    add)     if   [ $# -le 1 ]; then read_list add; run_js true  "saveProfile(); addAll(); finish('added');"
             elif [ $# -eq 3 ]; then add_entry add "$2" "$3"; [ $BAD -eq 0 ] || exit 1
                                     run_js false "addAll(); finish('added');"
             else die "usage: add [<imsi> <msisdn>]"; fi ;;
    del)     if   [ $# -le 1 ]; then read_list del; run_js true  "delAll(); finish('deleted');"
             elif [ $# -eq 2 ]; then add_entry del "$2"; [ $BAD -eq 0 ] || exit 1
                                     run_js false "delAll(); finish('deleted');"
             else die "usage: del [<imsi>]"; fi ;;
    profile) [ $# -eq 1 ] || die "usage: profile"; run_js false "saveProfile(); finish('');" ;;
    *)       usage; exit 1 ;;
esac
