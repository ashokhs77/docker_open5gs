#!/bin/bash
# Cancel the PEER b2b leg of a call the caller has just CANCELled.
# $1 = Call-ID of the incoming (caller-facing) dialog, i.e. $ci on the CANCEL.
#
# WHY: b2b_entities claims a request only if EVERY Route hdr is its own, and an IMS
# S-CSCF always adds its ODI return hop, so its prescript refuses the CANCEL
# ("Second Route uri is not mine") before any of its own CANCEL handling runs.
# CANCEL is the only method affected -- it alone reuses the INITIAL Route set; an
# in-dialog BYE arrives against our own top-hiding contact and passes.
# t_relay() then cancels a transaction with NO BRANCHES (the callee-facing leg is a
# separate UAC transaction), so tm 487s the CALLER -- which is why "callee rejects"
# always worked and hid this -- and never stops the callee ringing.
# Upstream limitation, not a misconfiguration; there is no modparam for it.
#
# HOW: b2b_entities:list -> the entity whose callid is ours -> its logic_key ->
# b2b_logic:terminate_call. That ends BOTH bridge entities unconditionally, and
# ending an EARLY CLIENT entity is what emits the CANCEL (b2b_send_request rewrites
# BYE to METHOD_CANCEL and runs t_cancel_trans on the pending INVITE).
#
# STDOUT IS THE HANDSHAKE: one line, written last.
#   ok | notfound | ambiguous | mi-error | timeout-<rc> | nofifo
# Every failure leaves today's behaviour (callee keeps ringing) rather than breaking
# the caller's teardown, which t_relay() has already done by this point.
# Reply fifo name must be dot-free or mi_fifo silently discards the command.

FIFO=/tmp/opensips_fifo
REPLY_NAME="mi_cancel_r_$$"
REPLY_PATH="/tmp/$REPLY_NAME"
WAIT=2

CI="$1"

echo "[mi_cancel] callid=$CI" >&2

if [ -z "$CI" ]; then
	echo "[mi_cancel] ERROR: need <callid>" >&2
	echo "mi-error"
	exit 0
fi

mi_call() {
	rm -f "$REPLY_PATH"
	if ! mkfifo -m 0666 "$REPLY_PATH" 2>/dev/null; then
		echo "[mi_cancel] WARNING: mkfifo $REPLY_PATH failed" >&2
		MI_OUT=""
		MI_RC=90
		return
	fi
	printf ':%s:%s\n' "$REPLY_NAME" "$1" > "$FIFO"
	MI_OUT=$(timeout "$WAIT" cat "$REPLY_PATH" 2>/dev/null)
	MI_RC=$?
	rm -f "$REPLY_PATH"
}

mi_call '{"jsonrpc":"2.0","id":1,"method":"b2b_entities:list"}'
if [ "$MI_RC" -eq 90 ]; then
	echo "nofifo"
	exit 0
fi
if [ "$MI_RC" -ne 0 ]; then
	echo "[mi_cancel] ERROR: no MI reply to b2b_entities:list in ${WAIT}s (rc=$MI_RC)" >&2
	echo "timeout-$MI_RC"
	exit 0
fi
LIST="$MI_OUT"
if printf '%s' "$LIST" | grep -q '"error"'; then
	echo "[mi_cancel] ERROR: b2b_entities:list returned an error: $LIST" >&2
	echo "mi-error"
	exit 0
fi

# Split on braces/brackets ONLY, never on commas: logic_key and callid must stay on
# ONE line so they are read off the SAME entity. Both precede every nested object
# in the entity, so one brace-split segment holds both.
# Call-ID is matched with index(), not a regex -- a real one is full of dots and @.
TARGET="\"callid\":\"$CI\""
KEYS=$(printf '%s' "$LIST" \
	| tr '{}[]' '\n\n\n\n' \
	| awk -v target="$TARGET" '
		index($0, target) > 0 {
			if (match($0, /"logic_key":"[0-9]+\.[0-9]+"/))
				print substr($0, RSTART + 13, RLENGTH - 14)
		}
	' | sort -u)

COUNT=$(printf '%s' "$KEYS" | grep -c '[0-9]')

if [ -z "$KEYS" ] || [ "$COUNT" -eq 0 ]; then
	# Dump the raw reply: if the entity field order ever changes so logic_key and callid
	# land in different brace segments, this line is what reveals it.
	echo "[mi_cancel] no b2b entity has callid=$CI -- nothing to cancel." >&2
	echo "[mi_cancel] raw b2b_entities:list follows:" >&2
	printf '%s\n' "$LIST" >&2
	echo "notfound"
	exit 0
fi
if [ "$COUNT" -gt 1 ]; then
	echo "[mi_cancel] AMBIGUOUS: callid=$CI maps to $COUNT tuples: $(echo $KEYS) --" \
	     "refusing to guess which call to tear down" >&2
	echo "ambiguous"
	exit 0
fi

KEY="$KEYS"
echo "[mi_cancel] callid=$CI is b2b tuple $KEY -- terminating so the peer leg is CANCELled" >&2

mi_call "$(printf '{"jsonrpc":"2.0","id":2,"method":"b2b_logic:terminate_call","params":{"key":"%s"}}' "$KEY")"
if [ "$MI_RC" -ne 0 ]; then
	echo "[mi_cancel] ERROR: no MI reply to terminate_call key=$KEY in ${WAIT}s (rc=$MI_RC)" >&2
	echo "timeout-$MI_RC"
	exit 0
fi
if printf '%s' "$MI_OUT" | grep -q '"error"'; then
	echo "[mi_cancel] ERROR: terminate_call key=$KEY failed: $MI_OUT" >&2
	echo "mi-error"
	exit 0
fi

echo "[mi_cancel] terminated tuple $KEY" >&2
echo "ok"
