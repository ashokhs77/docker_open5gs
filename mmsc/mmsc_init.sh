#!/bin/bash

# Copy to tmp, substitute, copy back to original location
cp /usr/local/kannel/etc/kannel.conf /tmp/kannel.conf
cp /usr/local/mbuni/etc/mbuni.conf /tmp/mbuni.conf

sed -i "s|OSMOMSC_IP|${OSMOMSC_IP}|g" /tmp/kannel.conf
sed -i "s|MMSC_IP|${MMSC_IP}|g" /tmp/kannel.conf
sed -i "s|MMSC_IP|${MMSC_IP}|g" /tmp/mbuni.conf

# Copy back to original location
cat /tmp/kannel.conf > /usr/local/kannel/etc/kannel.conf
cat /tmp/mbuni.conf > /usr/local/mbuni/etc/mbuni.conf

echo "Starting Kannel bearerbox..."
/usr/local/kannel/sbin/bearerbox -v 2 /usr/local/kannel/etc/kannel.conf &
BEARERBOX_PID=$!
sleep 5

if ! kill -0 $BEARERBOX_PID 2>/dev/null; then
    echo "ERROR: bearerbox failed to start"
    cat /tmp/kannel.log
    exit 1
fi

echo "Starting Kannel smsbox..."
/usr/local/kannel/sbin/smsbox  /usr/local/kannel/etc/kannel.conf &
sleep 3

echo "Starting Mbuni MMSC..."
exec /usr/local/mbuni/bin/mmsc /usr/local/mbuni/etc/mbuni.conf
