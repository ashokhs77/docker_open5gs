#!/bin/bash

# BSD 2-Clause License

# Copyright (c) 2020-2025, Supreeth Herle
# All rights reserved.

# Redistribution and use in source and binary forms, with or without
# modification, are permitted provided that the following conditions are met:

# 1. Redistributions of source code must retain the above copyright notice, this
#    list of conditions and the following disclaimer.

# 2. Redistributions in binary form must reproduce the above copyright notice,
#    this list of conditions and the following disclaimer in the documentation
#    and/or other materials provided with the distribution.

# THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS"
# AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
# IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE
# DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT HOLDER OR CONTRIBUTORS BE LIABLE
# FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL
# DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR
# SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER
# CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY,
# OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE
# OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.

RUNTIME=${1:-rtpengine}
KERNEL_FORWARDING_MODE=${KERNEL_FORWARDING_MODE:-userspace}
KERNEL_FORWARDING_AVAILABLE=no

case "$KERNEL_FORWARDING_MODE" in
	userspace|off|no)
		echo "rtpengine kernel forwarding disabled by KERNEL_FORWARDING_MODE=$KERNEL_FORWARDING_MODE; starting in userspace mode only."
	;;
	auto|kernel|yes)
		if lsmod | grep -q '^xt_RTPENGINE'; then
			echo "rtpengine kernel module already loaded."
			KERNEL_FORWARDING_AVAILABLE=yes
		elif [ -e /proc/rtpengine/control ]; then
			echo "rtpengine kernel procfs interface already available."
			KERNEL_FORWARDING_AVAILABLE=yes
		elif modinfo xt_RTPENGINE >/dev/null 2>&1; then
			if modprobe xt_RTPENGINE >/dev/null 2>&1; then
				echo "rtpengine kernel module loaded successfully."
				KERNEL_FORWARDING_AVAILABLE=yes
			else
				echo "rtpengine kernel module exists but failed to load; continuing with userspace fallback."
			fi
		else
			echo "rtpengine kernel module xt_RTPENGINE not available on host kernel $(uname -r); continuing with userspace fallback."
		fi
		;;
	*)
		echo "Unknown KERNEL_FORWARDING_MODE=$KERNEL_FORWARDING_MODE; defaulting to auto/userspace fallback."
		if modinfo xt_RTPENGINE >/dev/null 2>&1 && modprobe xt_RTPENGINE >/dev/null 2>&1; then
			KERNEL_FORWARDING_AVAILABLE=yes
		fi
		;;
esac

# Populate options of the rtpengine cli command
#[ -z "$INTERFACE" ] && INTERFACE="$(awk 'END{print $1}' /etc/hosts)"
if [ -z "$TABLE" ]; then
	if [ "$KERNEL_FORWARDING_AVAILABLE" = "yes" ]; then
		TABLE="0"
	else
		TABLE="-1"
	fi
elif [ "$KERNEL_FORWARDING_AVAILABLE" != "yes" ] && [ "$TABLE" = "0" ]; then
	echo "rtpengine kernel forwarding unavailable; overriding TABLE=0 to TABLE=-1 for userspace-only operation."
	TABLE="-1"
fi
#[ -z "$LISTEN_NG" ] && LISTEN_NG="$(awk 'END{print $1}' /etc/hosts):2223"
[ -z "$PORT_MIN" ] && PORT_MIN="30000"
[ -z "$PORT_MAX" ] && PORT_MAX="40000"
[ -z "$TOS" ] && TOS="184"
[ -z "$PIDFILE" ] && PIDFILE="/run/ngcp-rtpengine-daemon.pid"
# NUM_THREADS: RTP worker thread count. Default to the available CPU count
# (one worker per core) — this matches rtpengine's own built-in default and the
# long-standing SVN behaviour. Do NOT hardcode a high value: on a 4-vCPU host,
# 16 workers oversubscribe the scheduler, starve rtpengine's housekeeping timers,
# and cause "Too many packets in UDP receive queue" drops that froze multi-UE
# ViLTE conferences. Override explicitly with RTPENGINE_NUM_THREADS for a bigger host.
if [ -z "$NUM_THREADS" ]; then
	NUM_THREADS="$(nproc 2>/dev/null || echo 4)"
	# rtpengine's own default is max(CPU cores, 4): it floors at 4 when fewer
	# than 4 cores are visible. Match that so small hosts aren't under-provisioned.
	[ "$NUM_THREADS" -lt 4 ] && NUM_THREADS=4
fi

# POLLER_SIZE: max number of event items (file descriptors) rtpengine pulls from
# epoll per poll iteration. rtpengine's default is 128. Per the man page a LOWER
# value only helps "load-balancing among a large number of threads" — it was the
# partner of the old num-threads=16. With one worker per core it just drains
# fewer sockets per pass and yields MORE "Too many packets" blips, not fewer.
# Leave unset => --poller-size omitted => rtpengine uses its 128 default (= SVN).
# Override via RTPENGINE_POLLER_SIZE only on big multi-core hosts, with measurement.
# Default ON: raise the kernel UDP receive buffers so a multi-UE video conference
# burst is absorbed instead of dropped ("Too many packets in UDP receive queue ...
# Dropped packets possible"). net.core.* are global (not namespaced), so this only
# takes effect if the rtpengine container can sysctl (privileged/host-net); if not,
# it no-ops and the SAME values must be set on the HOST (/etc/sysctl.d/99-rtpengine.conf).
RTPENGINE_APPLY_HOST_NET_TUNING=${RTPENGINE_APPLY_HOST_NET_TUNING:-yes}
RTPENGINE_EXTRA_ARGS=${RTPENGINE_EXTRA_ARGS:-}

#LISTEN_CLI="$(awk 'END{print $1}' /etc/hosts):9901"
LISTEN_CLI="0.0.0.0:9901"

OPTIONS=""
OPTIONS="$OPTIONS --interface=$INTERFACE"
OPTIONS="$OPTIONS --listen-ng=$LISTEN_NG"
OPTIONS="$OPTIONS --listen-cli=$LISTEN_CLI  --pidfile=$PIDFILE --port-min=$PORT_MIN --port-max=$PORT_MAX"
OPTIONS="$OPTIONS --table=$TABLE  --tos=$TOS --num-threads=$NUM_THREADS --foreground"

supports_rtpengine_option() {
	$RUNTIME --help 2>&1 | grep -q -- "$1"
}

if [ -n "$POLLER_SIZE" ]; then
	if supports_rtpengine_option "--poller-size"; then
		OPTIONS="$OPTIONS --poller-size=$POLLER_SIZE"
	else
		echo "rtpengine runtime does not support --poller-size; ignoring POLLER_SIZE=$POLLER_SIZE."
	fi
fi

if test "$NO_FALLBACK" = "yes" && test "$KERNEL_FORWARDING_AVAILABLE" = "yes" ; then
	OPTIONS="$OPTIONS --no-fallback"
elif test "$NO_FALLBACK" = "yes" ; then
	echo "NO_FALLBACK requested but kernel forwarding is unavailable; ignoring to keep userspace forwarding alive."
fi

if [ "$RTPENGINE_APPLY_HOST_NET_TUNING" = "yes" ]; then
	echo "Applying host UDP receive buffer tuning for RTPengine userspace forwarding."
	sysctl -w net.core.rmem_max=16777216 >/dev/null 2>&1 || true
	sysctl -w net.core.rmem_default=4194304 >/dev/null 2>&1 || true
	sysctl -w net.core.wmem_max=16777216 >/dev/null 2>&1 || true
	sysctl -w net.core.wmem_default=4194304 >/dev/null 2>&1 || true
	sysctl -w net.core.netdev_max_backlog=250000 >/dev/null 2>&1 || true
fi

if [ -n "$RTPENGINE_EXTRA_ARGS" ]; then
	OPTIONS="$OPTIONS $RTPENGINE_EXTRA_ARGS"
fi

echo "rtpengine startup: table=$TABLE kernel_forwarding=$KERNEL_FORWARDING_AVAILABLE threads=$NUM_THREADS poller_size=${POLLER_SIZE:-default} ports=$PORT_MIN-$PORT_MAX tos=$TOS"

# Sync docker time
#ln -snf /usr/share/zoneinfo/$TZ /etc/localtime && echo $TZ > /etc/timezone

set +e

# Add static route to route traffic back to UE as there is not NATing
ip r add ${UE_IPV4_IMS} via ${UPF_IP}
# Route needed for VoWiFi client where internet APN is used
ip r add ${UE_IPV4_INTERNET} via ${UPF_IP}

exec $RUNTIME $OPTIONS


