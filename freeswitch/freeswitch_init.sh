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
# Ensure mod_lua is loaded (it is in the default module set, but guard anyway).
MODCONF=/usr/local/freeswitch/conf/autoload_configs/modules.conf.xml
if [ -f "$MODCONF" ] && ! grep -q 'module="mod_lua"' "$MODCONF"; then
    sed -i 's#</modules>#  <load module="mod_lua"/>\n</modules>#' "$MODCONF"
fi

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

