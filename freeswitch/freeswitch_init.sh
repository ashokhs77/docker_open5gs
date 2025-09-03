#!/bin/bash

# Simple script to start FreeSWITCH
#!/bin/bash
set -e

echo "Starting FreeSWITCH..."

echo "PCSCF_IP is: $PCSCF_IP"

cp    /mnt/freeswitch/acl.conf.xml /usr/local/freeswitch/conf/autoload_configs
cp    /mnt/freeswitch/switch.conf.xml /usr/local/freeswitch/conf/autoload_configs
cp    /mnt/freeswitch/vars.xml /usr/local/freeswitch/conf
cp    /mnt/freeswitch/external.xml /usr/local/freeswitch/conf/sip_profiles
cp    /mnt/freeswitch/internal.xml /usr/local/freeswitch/conf/sip_profiles
cp    /mnt/freeswitch/default.xml /usr/local/freeswitch/conf/dialplan
cp    /mnt/freeswitch/public.xml /usr/local/freeswitch/conf/dialplan

sed -i 's|PCSCF_IP|'$PCSCF_IP'|g' /usr/local/freeswitch/conf/autoload_configs/acl.conf.xml
sed -i 's|RTPENGINE_IP|'$RTPENGINE_IP'|g' /usr/local/freeswitch/conf/vars.xml
sed -i 's|DOCKER_HOST_IP|'$DOCKER_HOST_IP'|g' /usr/local/freeswitch/conf/vars.xml


/usr/local/freeswitch/bin/freeswitch -nonat


