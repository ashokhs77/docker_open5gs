#!/bin/bash
# Drop ONE participant from a merge conference, leaving the conference and the other
# members up.
# $1 = target number   digits from the REFER's Refer-To
# $2 = room extension  confp-<tag> / confpv-<tag>, scoping the search to THIS room
#                      so a same-number call elsewhere is never touched
# [$3 = "drop"]        see below
#
# WHY: the handset's per-participant Drop button sends REFER Refer-To:
# <tel:NUMBER;method=BYE> -- a number and no Replaces, so mi_bridge.sh's dialog_id
# path cannot be used. MI b2b_logic:list is the only index from number to tuple.
#
# STDOUT IS THE HANDSHAKE: one line, written last.
#   ok | notfound | ambiguous | mi-error | timeout-<rc> | nofifo
# The caller MUST NOT 202 the REFER unless this says ok.
# Reply fifo name must be dot-free or mi_fifo silently discards the command.

FIFO=/tmp/opensips_fifo
REPLY_NAME="mi_drop_r_$$"
REPLY_PATH="/tmp/$REPLY_NAME"
# Keep well under the ~5 s the handset waits before giving up on its REFER. Two MI
# round trips fit comfortably; each is a local fifo write plus OpenSIPS' reply.
WAIT=2

NUM="$1"
ROOM="$2"
MODE="$3"

# $3 = "drop" selects the Drop-button semantics: widen the room match to ANY
# participant extension (confj-/confjv- too, for a participant that pressed merge
# and joined as a second focus), and transitively drop everyone that member
# introduced -- they came in behind it, so they leave with it.
#
# The narrow default is REQUIRED for the retire path: a joiner momentarily holds
# both confp-<tag> (the leg to retire) and confj-<tag> (its new focus), so a wide
# match would see two member rows, hit the ambiguity guard, retire nothing, and the
# room would echo.
# conf-/confv- are never matched in either mode: that is the OWNING focus, it carries
# endconf, so terminating it would end the conference for everyone.
ROOMRE="$ROOM"
if [ "$MODE" = "drop" ]; then
	ROOMRE=$(printf '%s' "$ROOM" | sed 's/^[^-]*-/conf(p|pv|j|jv)-/')
fi
TORE="\"to_uri\":\"sip:$ROOMRE@"

echo "[mi_drop] number=$NUM room=$ROOM mode=${MODE:-exact} roommatch=$ROOMRE" >&2

if [ -z "$NUM" ] || [ -z "$ROOM" ]; then
	echo "[mi_drop] ERROR: need <number> <room> [drop]" >&2
	echo "mi-error"
	exit 0
fi

# --- one MI round trip; prints the raw reply on stdout, status in $mi_rc -------------
mi_rc=0
mi_call() {
	rm -f "$REPLY_PATH"
	if ! mkfifo -m 0666 "$REPLY_PATH" 2>/dev/null; then
		mi_rc=90
		return
	fi
	printf ':%s:%s\n' "$REPLY_NAME" "$1" > "$FIFO"
	MI_OUT=$(timeout "$WAIT" cat "$REPLY_PATH" 2>/dev/null)
	mi_rc=$?
	rm -f "$REPLY_PATH"
}

# --- 1. read the tuple list ---------------------------------------------------------
mi_call '{"jsonrpc":"2.0","id":1,"method":"b2b_logic:list"}'
if [ "$mi_rc" -eq 90 ]; then
	echo "[mi_drop] WARNING: mkfifo $REPLY_PATH failed" >&2
	echo "nofifo"
	exit 0
fi
if [ "$mi_rc" -ne 0 ]; then
	echo "[mi_drop] ERROR: no MI reply to b2b_logic:list in ${WAIT}s (rc=$mi_rc)" >&2
	echo "timeout-$mi_rc"
	exit 0
fi
LIST="$MI_OUT"
if printf '%s' "$LIST" | grep -q '"error"'; then
	echo "[mi_drop] ERROR: b2b_logic:list returned an error: $LIST" >&2
	echo "mi-error"
	exit 0
fi

# --- 2. PARSER: build this room's membership table -----------------------------------
# PARSER. b2b_logic:list shape (read off a live conference; there is NO callid field,
# which is why a Call-ID lookup can never work here):
#   Tuples[] -> {"key":"171.0", ..., SERVERS[], CLIENTS[], BRIDGE_ENTITIES[]}
#   entity   -> {"to_uri":"sip:X@...","from_uri":"sip:Y@...", ...}
#
# THE PAIRING IS THE WHOLE POINT. "the number appears in this tuple" is NOT "this is
# that member's leg": a member who DIALLED another member also appears in the
# callee's tuple, as from_uri of the leg toward the callee. Requiring from_uri=member
# AND to_uri=room ON THE SAME ENTITY excludes that by construction -- without it,
# dropping B could hang up D instead.
# So split on braces/brackets ONLY, never on commas, or the two fields separate.
# Take the tuple key from its own "key":"N.N" field, or "jsonrpc":"2.0" reads as one.
#
# One pass builds a table, one row per tuple:  <key> <member> <introducer>
#   member     = from_uri of the entity whose to_uri IS a room extension (so the
#                owning focus never appears and can never be dropped)
#   introducer = the OTHER party on the entity whose to_uri is NOT the room, i.e. the
#                far end of the original call that became this membership.
# The introducer link needs no extra state: the original call leg SURVIVES the
# bridge inside the tuple.
#
# READ BOTH SIDES OF THAT ENTITY, never from_uri alone. Who dialled whom is not fixed:
# B->D leaves from_uri=B,to_uri=D, but D->B leaves from_uri=D,to_uri=B. Taking from_uri
# blindly made the introducer come out as D ITSELF in the second case, the chain guard
# mem!=intro then dropped the link, and "drop B" left D in the room. MEASURED 2026-09-01;
# the 2026-08-19 test only ever exercised B->D, which is why it passed.
TABLE=$(printf '%s' "$LIST" \
	| tr '{}[]' '\n\n\n\n' \
	| awk -v tore="$TORE" '
		function num_of(field,   m) {
			if (!match($0, "\"" field "\":\"sip:[0-9]+@")) return ""
			m = substr($0, RSTART, RLENGTH)
			sub(/^.*sip:/, "", m); sub(/@.*$/, "", m)
			return m
		}
		# Resolved only at flush: the room-facing entity can appear either side of the
		# call-facing one, so the member is not always known when the latter is read.
		function flush_tuple(   who) {
			if (key == "" || member == "") return
			who = (peer_from != "" && peer_from != member) ? peer_from : peer_to
			if (who == "") who = member
			print key "\t" member "\t" who
		}
		{
			if (match($0, /"key":"[0-9]+\.[0-9]+"/)) {
				flush_tuple()
				key = substr($0, RSTART + 7, RLENGTH - 8)
				member = ""; peer_from = ""; peer_to = ""
				next
			}
			if ($0 ~ tore) {
				# an entity facing the room: its from_uri is the member itself
				if (member == "") member = num_of("from_uri")
			} else {
				# an entity facing the other party: keep BOTH numbers, pick at flush
				if (peer_from == "") peer_from = num_of("from_uri")
				if (peer_to == "")   peer_to   = num_of("to_uri")
			}
		}
		END { flush_tuple() }
	' | sort -u)

echo "[mi_drop] room members (key member introducer):" >&2
printf '%s\n' "$TABLE" | sed 's/^/[mi_drop]   /' >&2

# --- 3. select the tuples to terminate -----------------------------------------------
# exact mode (retire) takes ONLY this member's own tuple. drop mode also takes
# everyone it introduced, transitively.
SEL=$(printf '%s\n' "$TABLE" | awk -F'\t' -v target="$NUM" -v chain="$MODE" '
	{ k[NR] = $1; mem[NR] = $2; intro[NR] = $3; n = NR; ismember[$2] = 1 }
	END {
		# The target must be a member of THIS room in its own right. Without this, a
		# number that is only ever an INTRODUCER would still seed the chain: the owner
		# A introduces every party it merged in, so "drop A" would hang up those
		# parties while A itself (on conf-/confv-) is not even droppable.
		if (!(target in ismember)) exit
		want[target] = 1
		if (chain == "drop") {
			# transitive closure; bounded by n passes, and only NEW members re-arm it
			do {
				added = 0
				for (i = 1; i <= n; i++)
					if (intro[i] in want && !(mem[i] in want) && mem[i] != intro[i]) {
						want[mem[i]] = 1; added = 1
					}
			} while (added)
		}
		for (i = 1; i <= n; i++) if (mem[i] in want) print k[i] "\t" mem[i]
	}
')

COUNT=$(printf '%s' "$SEL" | grep -c '[0-9]')

if [ -z "$SEL" ] || [ "$COUNT" -eq 0 ]; then
	echo "[mi_drop] NOTFOUND: $NUM is not a member of room $ROOM." >&2
	echo "[mi_drop] RAW b2b_logic:list follows so the parser can be corrected:" >&2
	echo "$LIST" >&2
	echo "notfound"
	exit 0
fi
# Paired on one entity a member maps to exactly one tuple, so a duplicate means the
# parse is wrong, not that there is a choice. Refuse rather than guess.
if [ "$(printf '%s\n' "$SEL" | cut -f2 | sort | uniq -d)" != "" ]; then
	echo "[mi_drop] AMBIGUOUS: a member maps to more than one tuple: $(echo $SEL)" >&2
	echo "ambiguous"
	exit 0
fi

# --- 4. terminate them -----------------------------------------------------------------
# Reverse table order so introduced parties tend to go first. Best effort: each tuple
# is terminated independently, so order affects log readability, not correctness.
FAILED=""
for KEY in $(printf '%s\n' "$SEL" | cut -f1 | tac); do
	WHO=$(printf '%s\n' "$SEL" | awk -F'\t' -v k="$KEY" '$1 == k { print $2 }')
	if [ "$WHO" = "$NUM" ]; then
		echo "[mi_drop] terminating tuple key=$KEY (member=$WHO, the drop target)" >&2
	else
		echo "[mi_drop] terminating tuple key=$KEY (member=$WHO, introduced by the target)" >&2
	fi
	mi_call "$(printf '{"jsonrpc":"2.0","id":2,"method":"b2b_logic:terminate_call","params":{"key":"%s"}}' "$KEY")"
	if [ "$mi_rc" -ne 0 ]; then
		echo "[mi_drop] ERROR: no MI reply to terminate_call for $KEY in ${WAIT}s" \
		     "(rc=$mi_rc); state unknown, NOT retried" >&2
		FAILED="$FAILED $KEY(timeout)"
		continue
	fi
	if printf '%s' "$MI_OUT" | grep -q '"error"'; then
		echo "[mi_drop] ERROR: terminate_call failed for $KEY: $MI_OUT" >&2
		FAILED="$FAILED $KEY(mi-error)"
		continue
	fi
	echo "[mi_drop] terminate_call OK for $KEY, MI reply: $MI_OUT" >&2
done

if [ -n "$FAILED" ]; then
	# Partial teardown: say so rather than claim success. The caller must not tell the
	# handset a drop worked when part of it did not.
	echo "[mi_drop] ERROR: these tuples were NOT terminated:$FAILED" >&2
	echo "mi-error"
	exit 0
fi

echo "ok"
