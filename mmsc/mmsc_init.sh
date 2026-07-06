#!/bin/bash

# Select kannel config based on DEPLOY_MODE:
#   DEPLOY_MODE=5G  → kannel_5g.conf  (HTTP smsc → SMSC xhttp, no OsmoMSC)
#   anything else   → kannel.conf     (SMPP smsc → OsmoMSC, classic 4G path)
if [ "${DEPLOY_MODE:-}" = "5G" ]; then
    echo "DEPLOY_MODE=5G: using kannel_5g.conf (HTTP smsc -> SMSC xhttp)"
    cp /usr/local/kannel/etc/kannel_5g.conf /tmp/kannel.conf
else
    echo "DEPLOY_MODE=4G (default): using kannel.conf (SMPP smsc -> OsmoMSC)"
    cp /usr/local/kannel/etc/kannel.conf /tmp/kannel.conf
fi
cp /usr/local/mbuni/etc/mbuni.conf /tmp/mbuni.conf

# Substitute MMSC_IP first (needed before proxy group generation)
sed -i "s|MMSC_IP|${MMSC_IP}|g" /tmp/kannel.conf
# In 5G mode SMSC_IP replaces the SMSC_IP placeholder in kannel_5g.conf.
# In 4G mode OSMOMSC_IP replaces the OsmoMSC host placeholder in kannel.conf.
if [ "${DEPLOY_MODE:-}" = "5G" ]; then
    sed -i "s|SMSC_IP|${SMSC_IP}|g" /tmp/kannel.conf
else
    sed -i "s|OSMOMSC_IP|${OSMOMSC_IP}|g" /tmp/kannel.conf
fi
sed -i "s|MMSC_IP|${MMSC_IP}|g" /tmp/mbuni.conf

echo "Local MMSC IP: ${MMSC_IP}"

# Add one mmsproxy group per unique remote NIB IP
# and build msmtp config
cat > /etc/msmtprc << EOF
defaults
tls off
auth off

EOF

FIRST_REMOTE_NIB=""
declare -A SEEN_IPS

while IFS=: read -r NIB_NUM NIB_IP RANGE_START RANGE_END; do
    [[ "$NIB_NUM" =~ ^#.*$ ]] && continue
    [[ -z "$NIB_NUM" ]] && continue
    [[ "$NIB_IP" == "${MMSC_IP}" ]] && continue       # skip self
    [[ -n "${SEEN_IPS[$NIB_IP]}" ]] && continue       # skip duplicate IPs
    SEEN_IPS[$NIB_IP]=1

    # Track first remote NIB for default msmtp account
    if [ -z "$FIRST_REMOTE_NIB" ]; then
        FIRST_REMOTE_NIB="$NIB_NUM"
    fi

    # Add mmsproxy group to mbuni.conf
    cat >> /tmp/mbuni.conf << EOF

group = mmsproxy
name = nib${NIB_NUM}-relay
host = ${NIB_IP}
send-mail-prog = /usr/bin/msmtp -f '%f' '%t'
confirmed-delivery = false
EOF
    echo "Added mmsproxy for NIB${NIB_NUM} at ${NIB_IP}"

    # Add msmtp account for this remote NIB
    cat >> /etc/msmtprc << EOF
account nib${NIB_NUM}
host ${NIB_IP}
port 25
from mmsc@${MMSC_IP}

EOF
    echo "Added msmtp account for NIB${NIB_NUM} ? ${NIB_IP}:25"

done < /etc/mmsc/nib_registry.conf

# Set default msmtp account
if [ -n "$FIRST_REMOTE_NIB" ]; then
    echo "account default : nib${FIRST_REMOTE_NIB}" >> /etc/msmtprc
    echo "msmtp default account: nib${FIRST_REMOTE_NIB}"
else
    echo "WARNING: No remote NIBs found in nib_registry.conf"
fi

chmod 644 /etc/msmtprc

# Start MM4 receiver
python3 /etc/mmsc/mm4_receiver.py &
sleep 2

# Start Kannel bearerbox
echo "Starting Kannel bearerbox..."
/usr/local/kannel/sbin/bearerbox -v 2 /tmp/kannel.conf &
BEARERBOX_PID=$!
sleep 5

if ! kill -0 $BEARERBOX_PID 2>/dev/null; then
    echo "ERROR: bearerbox failed to start"
    cat /tmp/kannel.log
    exit 1
fi

# Start Kannel smsbox
echo "Starting Kannel smsbox..."
/usr/local/kannel/sbin/smsbox /tmp/kannel.conf &
sleep 3

# Start Mbuni MMSBox VAS gateway for SendMMS/MM7 application ingress.
# The mmsc daemon handles subscriber-facing MM1/MM7; mmsbox owns sendmms-port.
echo "Starting Mbuni MMSBox VAS gateway..."
/usr/local/mbuni/bin/mmsbox /tmp/mbuni.conf &
MMSBOX_PID=$!
sleep 3

if ! kill -0 $MMSBOX_PID 2>/dev/null; then
    echo "ERROR: mmsbox failed to start"
    cat /tmp/mbuni.log
    exit 1
fi

# Start Mbuni MMSC
echo "Starting Mbuni MMSC..."
exec /usr/local/mbuni/bin/mmsc /tmp/mbuni.conf

