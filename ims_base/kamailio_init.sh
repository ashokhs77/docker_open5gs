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

if [[ -z "$COMPONENT_NAME" ]]; then
	echo "Error: COMPONENT_NAME environment variable not set"; exit 1;
fi
# Strip trailing digits (pcscf1 -> pcscf) to match pidfile naming convention
COMPONENT_BASE=$(echo "$COMPONENT_NAME" | sed 's/[0-9]*$//')
PIDFILE="/kamailio_${COMPONENT_BASE}.pid"

# Launch fully-detached license monitor before starting Kamailio.
# setsid detaches it from this shell's process group so its parent becomes
#setsid /usr/local/sbin/license_monitor.sh "$PIDFILE" 180 < /dev/null > /var/log/license_monitor.log 2>&1 &
#disown
# Launch license monitor only when license checking is enabled
if [[ "$LICENSE" == "ON" ]]; then
    echo "License checking enabled. Starting license monitor..."
    setsid /usr/local/sbin/license_monitor.sh "$PIDFILE" < /dev/null > /proc/1/fd/1 2>/proc/1/fd/2 &
else
    echo "License checking disabled. Skipping license monitor."
fi

if [[ "$COMPONENT_NAME" =~ ^(icscf[[:digit:]]*$) ]]; then
	echo "Deploying component: '$COMPONENT_NAME'"
	/mnt/icscf/${COMPONENT_NAME}_init.sh
elif [[ "$COMPONENT_NAME" =~ ^(scscf[[:digit:]]*$) ]]; then
	echo "Deploying component: '$COMPONENT_NAME'"
	/mnt/scscf/${COMPONENT_NAME}_init.sh
elif [[ "$COMPONENT_NAME" =~ ^(pcscf[[:digit:]]*$) ]]; then
	echo "Deploying component: '$COMPONENT_NAME'"
	/mnt/pcscf/${COMPONENT_NAME}_init.sh
elif [[ "$COMPONENT_NAME" =~ ^(smsc[[:digit:]]*$) ]]; then
	echo "Deploying component: '$COMPONENT_NAME'"
	/mnt/smsc/${COMPONENT_NAME}_init.sh
else
	echo "Error: Invalid component name: '$COMPONENT_NAME'"
fi
