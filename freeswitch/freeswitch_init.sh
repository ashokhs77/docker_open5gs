#!/bin/bash
set -e

echo "Starting FreeSWITCH..."

echo "PCSCF_IP is: $PCSCF_IP"

cp    /mnt/freeswitch/acl.conf.xml /usr/local/freeswitch/conf/autoload_configs
cp    /mnt/freeswitch/switch.conf.xml /usr/local/freeswitch/conf/autoload_configs
cp    /mnt/freeswitch/conference.conf.xml /usr/local/freeswitch/conf/autoload_configs
cp    /mnt/freeswitch/vars.xml /usr/local/freeswitch/conf
cp    /mnt/freeswitch/external.xml /usr/local/freeswitch/conf/sip_profiles
cp    /mnt/freeswitch/internal.xml /usr/local/freeswitch/conf/sip_profiles
cp    /mnt/freeswitch/default.xml /usr/local/freeswitch/conf/dialplan
cp    /mnt/freeswitch/public.xml /usr/local/freeswitch/conf/dialplan

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


