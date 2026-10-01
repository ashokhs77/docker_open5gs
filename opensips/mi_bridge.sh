#!/bin/bash
# Fire an MI b2b_bridge at our own OpenSIPS and WAIT for it to execute, re-anchoring
# one call into a FreeSWITCH conference room.
# $1 = dialog_id  "callid;from-tag;to-tag" from the REFER's Replaces
# $2 = new_uri    the room extension, e.g. sip:confp-<tag>@FS:5094 (audio) or
#                 confpv-<tag>@FS:5096 (video). Passed through verbatim.
# [$3 = flag]     optional: 1 = bridge the callee entity instead of the caller
#
# STDOUT IS THE HANDSHAKE: one line, written last. exec() only waits for the child
# if the caller asks for stdout, so route[conf_req] must pass its 3rd arg.
# Blocking is deliberate: the refer-NOTIFY that follows makes the handset BYE its
# leg, and a BYE before the bridge runs destroys the whole b2b tuple.
# Reply fifo name must be dot-free or mi_fifo silently discards the command.
# DEAD END: never add a lock or settle delay, and never delay the NOTIFY -- the
# handset already serialises the two REFERs.

FIFO=/tmp/opensips_fifo
REPLY_DIR=/tmp
REPLY_NAME="mi_bridge_r_$$"
REPLY_PATH="$REPLY_DIR/$REPLY_NAME"
# Cap on how long one OpenSIPS udp worker is held here. The handset drops the
# leg ~5 s after its REFER if it hears no result, so keep this well under that.
WAIT=2

echo "[mi_bridge] dialog_id=$1 new_uri=$2 flag=${3:-<none>}" >&2

# MI command is "bridge" under module "b2b_logic" => method "b2b_logic:bridge"
# (source: modules/b2b_logic mi_cmds; README 1.6.2 example uses this name).
if [ -n "$3" ]; then
	PARAMS=$(printf '{"dialog_id":"%s","new_uri":"%s","flag":"%s"}' "$1" "$2" "$3")
else
	PARAMS=$(printf '{"dialog_id":"%s","new_uri":"%s"}' "$1" "$2")
fi

rm -f "$REPLY_PATH"
if mkfifo -m 0666 "$REPLY_PATH" 2>/dev/null; then
	printf ':%s:{"jsonrpc":"2.0","id":1,"method":"b2b_logic:bridge","params":%s}\n' \
		"$REPLY_NAME" "$PARAMS" > "$FIFO"
	# Blocks until OpenSIPS closes the fifo, i.e. once the bridge has run;
	# timeout keeps a missing reply from wedging the worker.
	REPL=$(timeout "$WAIT" cat "$REPLY_PATH" 2>/dev/null)
	rc=$?
	rm -f "$REPLY_PATH"
	if [ "$rc" -ne 0 ]; then
		# Not retried: a second bridge on an already-bridged tuple is worse
		# than the race.
		echo "[mi_bridge] WARNING: no MI reply in ${WAIT}s (rc=$rc) -- bridge state" \
		     "unknown; grep the opensips log for 'mi_fifo' errors, then for" \
		     "'b2bl_add_client' to see whether it actually ran" >&2
		STATUS="timeout-$rc"
	elif printf '%s' "$REPL" | grep -q '"error"'; then
		# A REPLY IS NOT A SUCCESS. Folded into the "ok" case this reported a failed bridge
		# as ok, and the AS then told the handset "SIP/2.0 200 OK" for a party that was
		# never bridged -- visible only as a handset left on hold until it dropped.
		echo "[mi_bridge] ERROR: MI returned an error, the bridge did NOT run:" \
		     "$REPL" >&2
		STATUS="mi-error"
	else
		echo "[mi_bridge] bridge executed, MI reply: $REPL" >&2
		STATUS="ok"
	fi
else
	echo "[mi_bridge] WARNING: mkfifo $REPLY_PATH failed -- falling back to" \
	     "fire-and-forget (racy, see header)" >&2
	printf '::{"jsonrpc":"2.0","method":"b2b_logic:bridge","params":%s}\n' \
		"$PARAMS" > "$FIFO"
	STATUS="nofifo"
fi

# The single stdout line, written LAST and nowhere else: closing stdout is what
# releases the OpenSIPS worker.
echo "$STATUS"
