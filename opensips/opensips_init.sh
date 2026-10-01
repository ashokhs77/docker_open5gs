#!/bin/bash
# Entrypoint for the OpenSIPS-4.0 in-path AS container.
# Mirrors the repo's *_init.sh pattern: derive IMS_DOMAIN from MCC/MNC, expand the
# config tokens at boot (so nothing is baked into the image), then exec opensips.
set -e

# IMS_DOMAIN is not in .env — derive it exactly like the other init scripts
# (MNC zero-padded to 3 digits).
if [ ${#MNC} -eq 3 ]; then
	export IMS_DOMAIN="ims.mnc${MNC}.mcc${MCC}.3gppnetwork.org"
else
	export IMS_DOMAIN="ims.mnc0${MNC}.mcc${MCC}.3gppnetwork.org"
fi

# Locate the module path for this build (source install puts modules under
# /usr/local/lib{,64}); export so the cfg can reference ${OPENSIPS_MPATH}.
if [ -d /usr/local/lib64/opensips/modules ]; then
	export OPENSIPS_MPATH="/usr/local/lib64/opensips/modules/"
else
	export OPENSIPS_MPATH="/usr/local/lib/x86_64-linux-gnu/opensips/modules/"
fi

echo "[opensips_init] IMS_DOMAIN=$IMS_DOMAIN OPENSIPS_IP=$OPENSIPS_IP SCSCF_IP=$SCSCF_IP MPATH=$OPENSIPS_MPATH"

# --- Fix Docker-hairpin NAT for in-dialog requests toward the caller -----------
# The S-CSCF Record-Routes its ADVERTISED address (DOCKER_HOST_IP:6060), and
# sending there hairpins through Docker NAT -- our source becomes the bridge GW,
# so the S-CSCF sends every response to the P-CSCF instead of to us and in-dialog
# requests (video re-INVITE, BYE) time out. Container-local DNAT keeps the source
# as OPENSIPS_IP. Requires cap_add NET_ADMIN (set in 4g-volte-deploy.yaml).
if [ -n "$DOCKER_HOST_IP" ] && [ -n "$SCSCF_IP" ]; then
	iptables -t nat -A OUTPUT -d "$DOCKER_HOST_IP" -p udp --dport 6060 -j DNAT --to-destination "$SCSCF_IP:6060" \
		&& iptables -t nat -A OUTPUT -d "$DOCKER_HOST_IP" -p tcp --dport 6060 -j DNAT --to-destination "$SCSCF_IP:6060" \
		&& echo "[opensips_init] DNAT $DOCKER_HOST_IP:6060 -> $SCSCF_IP:6060 installed" \
		|| echo "[opensips_init] WARNING: could not install DNAT rule (NET_ADMIN missing?) -- in-dialog requests toward the caller will fail"
else
	echo "[opensips_init] WARNING: DOCKER_HOST_IP/SCSCF_IP unset -- skipping hairpin DNAT"
fi

# Preprocess: envsubst expands ${VAR} from the container env (only real env-var
# names, so OpenSIPS $pvars survive), then m4 expands global.m4 macros.
mkdir -p /etc/opensips
envsubst "$(printf '${%s} ' $(env | cut -d'=' -f1))" \
	< /mnt/opensips/opensips.cfg \
	| m4 /mnt/opensips/global.m4 - \
	> /etc/opensips/opensips.cfg

echo "[opensips_init] --- expanded opensips.cfg (head) ---"
sed -n '1,60p' /etc/opensips/opensips.cfg

# Config syntax check (fail fast with a clear message before going daemonless).
opensips -c -f /etc/opensips/opensips.cfg || { echo "[opensips_init] CONFIG CHECK FAILED"; exit 1; }

# Run in the foreground (-F), logging to stderr, so docker captures the log.
exec opensips -F -f /etc/opensips/opensips.cfg
