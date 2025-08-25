#!/bin/bash

# Simple script to start FreeSWITCH
#!/bin/bash
set -e

echo "Starting FreeSWITCH..."

echo "PCSCF_IP is: $PCSCF_IP"

cp    /mnt/freeswitch/acl.conf.xml /usr/local/freeswitch/conf/autoload_configs
#cp    /mnt/freeswitch/acl.conf.xml /usr/local/src/freeswitch/conf/vanilla/autoload_configs

sed -i 's|PCSCF_IP|'$PCSCF_IP'|g' /usr/local/freeswitch/conf/autoload_configs/acl.conf.xml
#sed -i 's|PCSCF_IP|'$PCSCF_IP'|g' /usr/local/src/freeswitch/conf/vanilla/autoload_configs/acl.conf.xml


/usr/local/freeswitch/bin/freeswitch -nonat


