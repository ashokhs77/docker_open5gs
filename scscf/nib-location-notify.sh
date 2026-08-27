#!/bin/bash
# Tell the local mmsc container which NIB this MSISDN is currently registered
# on. Fired via route[NIB_LOCATION_NOTIFY] from route[PRE_REG_SAR_REPLY] /
# route[REG_SAR_REPLY] on successful REGISTER, after that route has already
# resolved the real MSISDN from PyHSS (REGISTER's $fU is an IMSI, not the
# MSISDN -- see kamailio_scscf.cfg). Must never block the SIP worker for long
# or fail loudly -- a network hiccup here must not affect the REGISTER
# response, so every path below exits 0.

PORT="${LOCATION_LISTENER_PORT:-7891}"

# Defensive digit-only filter in case the PyHSS JSON value carries whitespace
# or stray characters -- the input here should already be a bare MSISDN.
MSISDN="${1//[^0-9]/}"

[ -z "$MSISDN" ] && exit 0
[ -z "$DOCKER_HOST_IP" ] && exit 0

timeout 1 bash -c "exec 3<>/dev/tcp/${DOCKER_HOST_IP}/${PORT} && echo 'LOCUPD:${MSISDN}:${DOCKER_HOST_IP}' >&3" 2>/dev/null

exit 0
