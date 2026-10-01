#!/bin/bash
# Is NUMBER already a participant of a merge conference, and if so which room?
# $1 = the number from the factory INVITE's From ($fU)
#
# WHY: merge is not the initiator's privilege -- any participant can press it, and
# its handset dials the same factory. Without this lookup the AS opens a SECOND room
# and the two mixers get trunked together with no rtpengine between them, which goes
# deaf. So if the caller is already in a room, hand its tag back and join THAT room.
#
# STDOUT IS THE HANDSHAKE, one token written last:
#   a:<tag> | v:<tag>   already in that audio/video room
#   none                not in any room -- caller creates its own
#   mi-error | timeout-<rc> | nofifo
# EVERY non-a:/v: status means "create your own room", so a failed lookup can never
# break a plain initiator-led merge.
#
# NO TRAILING NEWLINE, and the tag is validated strictly alphanumeric: the caller
# splices this into a SIP RURI, re.subst does NOT strip a trailing newline, and a
# malformed RURI does not degrade -- it segfaults b2b_init_request and kills the AS.
# Reply fifo name must be dot-free or mi_fifo silently discards the command.

FIFO=/tmp/opensips_fifo
REPLY_NAME="mi_findroom_r_$$"
REPLY_PATH="/tmp/$REPLY_NAME"
# Shorter than mi_drop.sh's 2 s: this runs on the INVITE before b2b_init_request has
# created a transaction, so nothing is absorbing INVITE retransmissions while it
# blocks. A failure ceiling, not a budget -- the MI round trip is normally ms.
WAIT=1

NUM="$1"

echo "[mi_findroom] number=$NUM" >&2

if [ -z "$NUM" ]; then
	echo "[mi_findroom] ERROR: need <number>" >&2
	printf '%s' "mi-error"
	exit 0
fi

rm -f "$REPLY_PATH"
if ! mkfifo -m 0666 "$REPLY_PATH" 2>/dev/null; then
	echo "[mi_findroom] WARNING: mkfifo $REPLY_PATH failed" >&2
	printf '%s' "nofifo"
	exit 0
fi
printf ':%s:%s\n' "$REPLY_NAME" \
	'{"jsonrpc":"2.0","id":1,"method":"b2b_logic:list"}' > "$FIFO"
LIST=$(timeout "$WAIT" cat "$REPLY_PATH" 2>/dev/null)
rc=$?
rm -f "$REPLY_PATH"

if [ "$rc" -ne 0 ]; then
	echo "[mi_findroom] ERROR: no MI reply to b2b_logic:list in ${WAIT}s (rc=$rc)" >&2
	printf '%s' "timeout-$rc"
	exit 0
fi
if printf '%s' "$LIST" | grep -q '"error"'; then
	echo "[mi_findroom] ERROR: b2b_logic:list returned an error: $LIST" >&2
	printf '%s' "mi-error"
	exit 0
fi

# Same parser as mi_drop.sh: the member and the room must be read off ONE entity
# (from_uri = member, to_uri = room). Matching them anywhere in the tuple also hits
# tuples where this member merely DIALLED someone, which is what broke Drop. So
# split on braces/brackets only, NEVER on commas, or the two fields separate.
# confpv- is tested before confp- because the latter is a prefix of the former.
FROMRE="\"from_uri\":\"sip:$NUM@"
HITS=$(printf '%s' "$LIST" \
	| tr '{}[]' '\n\n\n\n' \
	| awk -v fromre="$FROMRE" '
		function flush_tuple() {
			if (key != "" && tag != "") print type ":" tag
		}
		{
			if (match($0, /"key":"[0-9]+\.[0-9]+"/)) {
				flush_tuple()
				key = substr($0, RSTART + 7, RLENGTH - 8)
				tag = ""; type = ""
				next
			}
			if ($0 ~ fromre) {
				if (match($0, /"to_uri":"sip:confpv-[0-9a-zA-Z]+@/)) {
					m = substr($0, RSTART, RLENGTH)
					sub(/^.*sip:confpv-/, "", m); sub(/@.*$/, "", m)
					type = "v"; tag = m
				} else if (match($0, /"to_uri":"sip:confp-[0-9a-zA-Z]+@/)) {
					m = substr($0, RSTART, RLENGTH)
					sub(/^.*sip:confp-/, "", m); sub(/@.*$/, "", m)
					type = "a"; tag = m
				}
			}
		}
		END { flush_tuple() }
	' | sort -u)

COUNT=$(printf '%s' "$HITS" | grep -c ':')

if [ -z "$HITS" ] || [ "$COUNT" -eq 0 ]; then
	echo "[mi_findroom] $NUM is not in any room -- caller creates its own" >&2
	printf '%s' "none"
	exit 0
fi
if [ "$COUNT" -gt 1 ]; then
	# In two rooms at once: joining either would be a guess, so fall back to opening our
	# own. Loud, because it should not happen.
	echo "[mi_findroom] AMBIGUOUS: $NUM appears in $COUNT rooms: $(echo $HITS)" \
	     "-- falling back to creating a new room" >&2
	printf '%s' "none"
	exit 0
fi

# Last gate before a value that becomes part of a SIP RURI. A case pattern, not a
# regex: [!0-9A-Za-z] matches a newline too, which is the character that crashed
# the AS. Anything unexpected degrades to "none".
TYPE=${HITS%%:*}
TAG=${HITS#*:}
case "$TYPE" in
	a|v) ;;
	*)   echo "[mi_findroom] REFUSING malformed type in [$HITS]" >&2
	     printf '%s' "none"; exit 0 ;;
esac
case "$TAG" in
	""|*[!0-9A-Za-z]*)
	     echo "[mi_findroom] REFUSING non-alphanumeric tag in [$HITS] --" \
	          "it would be spliced into a SIP RURI" >&2
	     printf '%s' "none"; exit 0 ;;
esac

echo "[mi_findroom] $NUM is already in room $TYPE:$TAG" >&2
printf '%s' "$TYPE:$TAG"
