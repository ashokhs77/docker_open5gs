#!/bin/bash
# Copy from bind-mounted host files to /tmp
cp /usr/local/kannel/etc/kannel.conf /tmp/kannel.conf
cp /usr/local/mbuni/etc/mbuni.conf /tmp/mbuni.conf

# Substitute placeholders in /tmp copies
sed -i "s|OSMOMSC_IP|${OSMOMSC_IP}|g" /tmp/kannel.conf
sed -i "s|MMSC_IP|${MMSC_IP}|g"       /tmp/kannel.conf
sed -i "s|MMSC_IP|${MMSC_IP}|g"       /tmp/mbuni.conf

# DON'T copy back — start services pointing to /tmp directly
echo "Starting Kannel bearerbox..."
/usr/local/kannel/sbin/bearerbox -v 2 /tmp/kannel.conf &
BEARERBOX_PID=$!
sleep 5

if ! kill -0 $BEARERBOX_PID 2>/dev/null; then
    echo "ERROR: bearerbox failed to start"
    cat /tmp/kannel.log
    exit 1
fi

echo "Starting Kannel smsbox..."
/usr/local/kannel/sbin/smsbox /tmp/kannel.conf &
sleep 3

echo "Starting Mbuni MMSC..."
exec /usr/local/mbuni/bin/mmsc /tmp/mbuni.conf
