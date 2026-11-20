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



# N6 and PFCP on the docker bridge (EUPF_IP); N3 on the gNB LAN through the n3lan ipvlan (EUPF_N3_IP)
N6_IF=$(ip -o -4 addr show | awk -v a="$EUPF_IP/" 'index($4, a) == 1 { print $2 }')
N3_IF=$(ip -o -4 addr show | awk -v a="$EUPF_N3_IP/" 'index($4, a) == 1 { print $2 }')

# Internet traffic leaves through the host (rtpengine_init.sh NATs it there). The host's own
# IP also goes over the bridge, because an ipvlan child can't reach its parent's address.
N6_GW=${TEST_NETWORK%.*}.1
ip route replace default via $N6_GW dev $N6_IF
ip route replace ${DOCKER_HOST_IP}/32 via $N6_GW dev $N6_IF

# The Open5GS UPF (ims DNN) advertises this same N3 address, because some gNBs keep a single
# N3 peer per UE. XDP passes GTP-U with TEIDs it doesn't own to the kernel: hand it to that UPF.
echo 0 > /proc/sys/net/ipv4/conf/all/rp_filter
echo 0 > /proc/sys/net/ipv4/conf/$N3_IF/rp_filter
iptables -t nat -C PREROUTING -d $EUPF_N3_IP -p udp --dport 2152 -j DNAT --to-destination $UPF_IP 2>/dev/null || \
    iptables -t nat -A PREROUTING -d $EUPF_N3_IP -p udp --dport 2152 -j DNAT --to-destination $UPF_IP

# The bool flags need "=": "--ueip false" would turn ueip on
exec ./bin/eupf \
    --iface $N6_IF \
    --iface $N3_IF \
    --aaddr $EUPF_IP:8181 \
    --paddr $EUPF_IP:8805 \
    --maddr $EUPF_IP:9091 \
    --nodeid $EUPF_IP \
    --ueip=false \
    --ftup=true \
    --loglvl info \
    --n3addr $EUPF_N3_IP $@
