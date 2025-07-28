#!/bin/bash

# Simple script to start FreeSWITCH
#!/bin/bash
set -e

echo "Starting FreeSWITCH..."

# This line is currently commented out. It was likely intended to replace a placeholder IP in vars.xml
# sed -i 's|DOCKER_HOST_IP|'"$DOCKER_HOST_IP"'|g' /usr/local/freeswitch/conf/vars.xml

/usr/local/freeswitch/bin/freeswitch -nonat


