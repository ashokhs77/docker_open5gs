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

# Fix Windows line endings in nib_registry.conf
sed -i 's/\r//' /etc/mmsc/nib_registry.conf
sed -i 's/\r//' /etc/mmsc/location_listener.py

# Substitute MMSC_IP first
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

while IFS=: read -r NIB_NUM NIB_IP; do
    [[ "$NIB_NUM" =~ ^#.*$ ]] && continue
    [[ -z "$NIB_NUM" ]] && continue
    [[ "$NIB_IP" == "${MMSC_IP}" ]] && continue       # skip self
    [[ -n "${SEEN_IPS[$NIB_IP]}" ]] && continue       # skip duplicate IPs
    SEEN_IPS[$NIB_IP]=1

    [ -z "$FIRST_REMOTE_NIB" ] && FIRST_REMOTE_NIB="$NIB_NUM"

    # Add mmsproxy group to mbuni.conf
    cat >> /tmp/mbuni.conf << EOF

group = mmsproxy
name = nib${NIB_NUM}-relay
host = ${NIB_IP}
send-mail-prog = /usr/local/bin/msmtp_route -f '%f' '%t'
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

# Generate smart msmtp routing wrapper
cat > /usr/local/bin/msmtp_route << 'SCRIPT'
#!/bin/bash
RECIPIENT=""
FROM_ADDR=""
SKIP=0

for arg in "$@"; do
    if [ "$SKIP" = "1" ]; then
        FROM_ADDR="$arg"
        SKIP=0
        continue
    fi
    if [ "$arg" = "-f" ]; then
        SKIP=1
        continue
    fi
    RECIPIENT="$arg"
done

HOST="${RECIPIENT##*@}"

ACCOUNT=""
CURRENT_ACCOUNT=""
while IFS= read -r line; do
    if [[ "$line" =~ ^account\ (.+)$ ]]; then
        CURRENT_ACCOUNT="${BASH_REMATCH[1]}"
        [[ "$CURRENT_ACCOUNT" == default* ]] && continue
    elif [[ "$line" =~ ^host\ (.+)$ ]]; then
        if [ "${BASH_REMATCH[1]}" = "$HOST" ]; then
            ACCOUNT="$CURRENT_ACCOUNT"
            break
        fi
    fi
done < /etc/msmtprc

if [ -n "$ACCOUNT" ]; then
    exec /usr/bin/msmtp -a "$ACCOUNT" -f "$FROM_ADDR" "$RECIPIENT"
else
    exec /usr/bin/msmtp -f "$FROM_ADDR" "$RECIPIENT"
fi
SCRIPT
chmod +x /usr/local/bin/msmtp_route
echo "msmtp_route wrapper created"

# Start MM4 receiver
python3 /etc/mmsc/mm4_receiver.py &
sleep 2

# Start roaming-aware location listener (tracks current-NIB overrides for
# resolve_mmsc.sh, fed by S-CSCF on every REGISTER -- see location_listener.py)
python3 /etc/mmsc/location_listener.py &
sleep 1

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

