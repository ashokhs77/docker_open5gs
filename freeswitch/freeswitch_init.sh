#!/bin/bash
set -e

echo "Starting FreeSWITCH..."

echo "PCSCF_IP is: $PCSCF_IP"

cp    /mnt/freeswitch/acl.conf.xml /usr/local/freeswitch/conf/autoload_configs
cp    /mnt/freeswitch/switch.conf.xml /usr/local/freeswitch/conf/autoload_configs
cp    /mnt/freeswitch/conference.conf.xml /usr/local/freeswitch/conf/autoload_configs
cp    /mnt/freeswitch/av.conf.xml /usr/local/freeswitch/conf/autoload_configs
cp    /mnt/freeswitch/vars.xml /usr/local/freeswitch/conf
cp    /mnt/freeswitch/external.xml /usr/local/freeswitch/conf/sip_profiles
cp    /mnt/freeswitch/internal.xml /usr/local/freeswitch/conf/sip_profiles
cp    /mnt/freeswitch/default.xml /usr/local/freeswitch/conf/dialplan
cp    /mnt/freeswitch/public.xml /usr/local/freeswitch/conf/dialplan

# --- Conference CDR (FreeSWITCH-native) -------------------------------------
# mod_lua startup script consumes conference::maintenance events and writes
# /cdr-logs/conf_cdr.csv via the shared conf_cdr_logger.sh. This is the single
# source of conference CDR (the P-CSCF conf-CDR path is disabled) and captures
# ALL members — including participants relayed in from other NIBs.
cp    /mnt/freeswitch/lua.conf.xml /usr/local/freeswitch/conf/autoload_configs
mkdir -p /usr/local/freeswitch/scripts
cp    /mnt/freeswitch/conference_cdr.lua /usr/local/freeswitch/scripts/
# Strip any CR (Windows->VM sync can reintroduce CRLF, which breaks Lua/shell).
sed -i 's/\r$//' /usr/local/freeswitch/scripts/conference_cdr.lua 2>/dev/null || true
# The shared logger is bind-mounted read-only from the host, so it keeps whatever
# mode/line endings the checkout gave it: git stores it non-executable and a
# Windows sync can add CRLF, and either makes every CDR write fail silently.
# conference_cdr.lua therefore runs this normalized local copy via bash.
if [ -f /usr/local/bin/conf_cdr_logger.sh ]; then
    install -m 0755 /usr/local/bin/conf_cdr_logger.sh /usr/local/freeswitch/scripts/conf_cdr_logger.sh
    sed -i 's/\r$//' /usr/local/freeswitch/scripts/conf_cdr_logger.sh
else
    echo "WARNING: /usr/local/bin/conf_cdr_logger.sh not mounted - conference CDR disabled"
fi
# Ensure mod_lua is loaded (it is in the default module set, but guard anyway).
MODCONF=/usr/local/freeswitch/conf/autoload_configs/modules.conf.xml
if [ -f "$MODCONF" ] && ! grep -q 'module="mod_lua"' "$MODCONF"; then
    sed -i 's#</modules>#  <load module="mod_lua"/>\n</modules>#' "$MODCONF"
fi

# merge-call participant profiles: audio on 5094, video on 5096. Plain copies of
# internal.xml maintained by hand (each file's header lists the few lines that differ).
# They exist so that enable-3pcc lives ONLY where the AS's no-SDP b2b_bridge INVITE
# lands: on internal/5090 that flag put inbound video one participant behind.
cp    /mnt/freeswitch/merge-audio.xml /usr/local/freeswitch/conf/sip_profiles
cp    /mnt/freeswitch/merge-video.xml /usr/local/freeswitch/conf/sip_profiles

# A merge profile that lost enable-3pcc answers the bridge INVITE with 480
# MANDATORY_IE_MISSING and NOTHING else looks wrong, so check it at boot instead of
# during a call. Commented out or absent both fail this test.
for P in merge-audio merge-video; do
	if ! grep -q '^[[:space:]]*<param name="enable-3pcc" value="true"/>' \
	     "/usr/local/freeswitch/conf/sip_profiles/${P}.xml"; then
		echo "[merge] FATAL: ${P}.xml has no active enable-3pcc=true -- every merge would 480" >&2
		exit 1
	fi
done
# The converse: internal.xml must NOT have it, or plain inbound video goes one
# participant behind (measured 2026-08-25 on the 10XX dial-in).
if grep -q '^[[:space:]]*<param name="enable-3pcc"' \
   /usr/local/freeswitch/conf/sip_profiles/internal.xml; then
	echo "[merge] FATAL: internal.xml has an active enable-3pcc -- this breaks plain inbound video; it belongs on merge-audio/merge-video only" >&2
	exit 1
fi
echo "[merge] merge-audio (5094) and merge-video (5096) installed, 3pcc confined to them"

sed -i 's|PCSCF_IP|'$PCSCF_IP'|g' /usr/local/freeswitch/conf/autoload_configs/acl.conf.xml
sed -i 's|RTPENGINE_IP|'$RTPENGINE_IP'|g' /usr/local/freeswitch/conf/vars.xml
sed -i 's|DOCKER_HOST_IP|'$DOCKER_HOST_IP'|g' /usr/local/freeswitch/conf/vars.xml

# IMS log capture — symlink FreeSWITCH's log file into the shared ./log/ directory
# so it appears alongside mme.log, smf.log etc. on the host.
# Set IMS_LOG_ENABLED=false to disable (FreeSWITCH will log only to its default path).
IMS_LOG_DIR="/open5gs/install/var/log/open5gs"
FS_LOG_DIR="/usr/local/freeswitch/log"
if [ "${IMS_LOG_ENABLED:-true}" = "true" ]; then
    mkdir -p "$IMS_LOG_DIR" "$FS_LOG_DIR"
    # Replace any existing freeswitch.log with a symlink into the shared volume.
    rm -f "${FS_LOG_DIR}/freeswitch.log"
    ln -sf "${IMS_LOG_DIR}/freeswitch.log" "${FS_LOG_DIR}/freeswitch.log"
    echo "FreeSWITCH log → ${IMS_LOG_DIR}/freeswitch.log"
fi

/usr/local/freeswitch/bin/freeswitch -nonat

