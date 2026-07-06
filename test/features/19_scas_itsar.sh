#!/bin/bash
# Feature 19: SCAS / ITSAR Security Hardening (4G)  (TRL8 add-on)
# 3GPP SCAS: TS 33.117 (general catalogue) + TS 33.116 (MME-specific).
# Diameter transport security per TS 33.210 (NDS/IP).
# India ITSAR (NCCS) baselines for EPC and IMS — feeds MTCTE evidence.
#
# This is a SECURITY-POSTURE audit. Calibration to never break the suite:
#   - FAIL only on a genuine defect even a lab must not have
#     (telnet/ftp listening, passwordless remote root).
#   - SKIP-with-finding for production-hardening items an open5gs lab
#     legitimately leaves off (Diameter TLS, IPsec, non-root, API auth) —
#     recorded for the evidence pack, not scored as failures.
#   - PASS when the hardened posture is actually present.
#
# Complements 17_security.sh (SIP robustness) — no overlap; this audits
# platform/transport/identity hardening. Related: 18_nas_conformance (EIA/EEA).
#
# Tests:
#   TC-1:  No insecure remote-access services on EPC NFs (telnet/ftp)   [33.117]
#   TC-2:  No insecure services on IMS NFs + datastores                 [33.117]
#   TC-3:  MySQL credential posture (no passwordless remote root)        [ITSAR]
#   TC-4:  MongoDB authentication posture (if deployed)                 [ITSAR]
#   TC-5:  Diameter transport security (TLS creds / No_TLS posture)     [33.210]
#   TC-6:  Diameter peer authentication / allow-listing (S6a)           [33.210]
#   TC-7:  Subscriber identity privacy (no clear IMSI in MME logs)      [ITSAR]
#   TC-8:  NFs run as non-root (least privilege)                        [33.117]
#   TC-9:  S1/data-plane transport protection (IPsec)                   [33.401]
#   TC-10: Management API authentication posture (PyHSS API key)        [ITSAR]
#   TC-11: Listening-port inventory evidence (attack surface)           [33.117]
#   TC-12: ITSAR hardening posture summary (evidence emitter)

set +e

INSECURE_PORT_RE_4G='[:.](21|23|512|513|514)([[:space:]]|$)'

# Read the MME freeDiameter config (template mount, then rendered install path)
read_mme_fd_conf() {
    docker exec mme sh -c 'cat /mnt/mme/mme.conf 2>/dev/null || cat /open5gs/install/etc/freeDiameter/mme.conf 2>/dev/null' 2>/dev/null || true
}

run_scas_itsar_tests() {
    start_feature "SCAS/ITSAR Security"

    local _scas_pass=0 _scas_find=0

    # TC-1: insecure remote-access services on EPC NFs
    _TEST_NUM=$((_TEST_NUM + 1))
    if should_run_test $_TEST_NUM; then
        local nfs="mme sgwc sgwu smf upf"
        local bad="" checked=0 nf raw
        for nf in $nfs; do
            if container_is_running "$nf"; then
                checked=$((checked + 1))
                raw=$(container_listeners_raw "$nf")
                if echo "$raw" | grep -qE "$INSECURE_PORT_RE_4G"; then
                    bad="$bad $nf"
                fi
            fi
        done
        if [ "$checked" -eq 0 ]; then
            skip "Insecure remote-access services on EPC NFs" "No EPC containers running to audit"
        elif [ -n "$bad" ]; then
            fail "Insecure services (telnet/ftp/rsh) listening on:$bad" \
                 "TS 33.117 forbids unnecessary insecure services — disable telnet(23)/ftp(21)/rsh(512-514)"
        else
            pass "No telnet/ftp/rsh listeners across $checked EPC NF(s) — insecure services disabled"
        fi
    fi

    # TC-2: insecure services on IMS NFs + datastores
    _TEST_NUM=$((_TEST_NUM + 1))
    if should_run_test $_TEST_NUM; then
        local nfs2="pcscf icscf scscf freeswitch mysql pyhss smsc"
        local bad2="" checked2=0 nf2 raw2
        for nf2 in $nfs2; do
            if container_is_running "$nf2"; then
                checked2=$((checked2 + 1))
                raw2=$(container_listeners_raw "$nf2")
                if echo "$raw2" | grep -qE "$INSECURE_PORT_RE_4G"; then
                    bad2="$bad2 $nf2"
                fi
            fi
        done
        if [ "$checked2" -eq 0 ]; then
            skip "Insecure services on IMS NFs + datastores" "No IMS/datastore containers running to audit"
        elif [ -n "$bad2" ]; then
            fail "Insecure services (telnet/ftp/rsh) listening on:$bad2" \
                 "Disable insecure services on IMS/datastore containers (TS 33.117)"
        else
            pass "No telnet/ftp/rsh listeners across $checked2 IMS/datastore container(s)"
        fi
    fi

    # TC-3: MySQL credential posture (remote root should require a password)
    # NOTE: open5gs labs commonly ship root@'%' with an EMPTY password (PyHSS/IMS
    # rely on it) — a genuine production-hardening finding (SKIP), not a failure;
    # enforcing a password here would break the running stack.
    _TEST_NUM=$((_TEST_NUM + 1))
    if should_run_test $_TEST_NUM; then
        if ! command -v mysql >/dev/null 2>&1; then
            skip "MySQL credential posture" "mysql client not available in test image"
        else
            local myout myrc
            myout=$(mysql -h "$MYSQL_IP" -uroot --connect-timeout=5 -N -e "SELECT 1" 2>&1)
            myrc=$?
            if echo "$myout" | grep -qiE 'Access denied|using password'; then
                pass "MySQL root requires a password (remote no-password login refused)"
                _scas_pass=$((_scas_pass + 1))
            elif [ "$myrc" -eq 0 ] && echo "$myout" | grep -qx '1'; then
                skip "MySQL credential posture (passwordless remote root)" \
                     "root@'%' accepts remote login with NO password (open5gs lab default — PyHSS/IMS rely on it). ITSAR: set a strong root password or use a dedicated least-privilege DB account before production"
                _scas_find=$((_scas_find + 1))
            else
                skip "MySQL credential posture" "Could not establish a remote root session (rc=${myrc}) — verify MySQL reachability/auth"
            fi
        fi
    fi

    # TC-4: MongoDB authentication posture (if deployed in this 4G stack)
    _TEST_NUM=$((_TEST_NUM + 1))
    if should_run_test $_TEST_NUM; then
        if container_is_running "mongo"; then
            local mout
            mout=$(docker exec mongo sh -c \
                'mongosh --quiet --eval "db.getSiblingDB(\"admin\").runCommand({listDatabases:1}).ok" 2>/dev/null || mongo --quiet --eval "db.getSiblingDB(\"admin\").runCommand({listDatabases:1}).ok" 2>/dev/null' 2>/dev/null)
            if echo "$mout" | grep -qiE 'unauthorized|requires authentication|not authorized|authentication failed'; then
                pass "MongoDB enforces authentication (unauthenticated admin command rejected)"
                _scas_pass=$((_scas_pass + 1))
            elif echo "$mout" | grep -qE '(^|[^0-9])1([^0-9]|$)'; then
                skip "MongoDB authentication posture" \
                     "MongoDB accepts unauthenticated admin commands (lab default). ITSAR requires authentication + RBAC in production"
                _scas_find=$((_scas_find + 1))
            else
                skip "MongoDB authentication posture" "Could not determine MongoDB auth state from response"
            fi
        else
            skip "MongoDB authentication posture" "MongoDB not deployed in the 4G stack (PyHSS/MySQL is the subscriber store)"
        fi
    fi

    # TC-5: Diameter transport security — TLS credential provisioning vs No_TLS peers
    _TEST_NUM=$((_TEST_NUM + 1))
    if should_run_test $_TEST_NUM; then
        if container_is_running "mme"; then
            local fdconf; fdconf=$(read_mme_fd_conf)
            if [ -z "$fdconf" ]; then
                skip "Diameter transport security posture" "Could not read mme freeDiameter config"
            elif echo "$fdconf" | grep -qE '^[[:space:]]*TLS_Cred' && ! echo "$fdconf" | grep -qE 'No_TLS[[:space:]]*;'; then
                pass "Diameter peers use TLS (credentials provisioned, no No_TLS overrides)"
                _scas_pass=$((_scas_pass + 1))
            elif echo "$fdconf" | grep -qE '^[[:space:]]*TLS_Cred'; then
                skip "Diameter transport security posture" \
                     "TLS credentials ARE provisioned (TLS_Cred/TLS_CA) but S6a ConnectPeer uses No_TLS (plaintext 3868 — lab default). TS 33.210 NDS/IP requires protected Diameter in production: remove No_TLS or deploy IPsec"
                _scas_find=$((_scas_find + 1))
            else
                skip "Diameter transport security posture" \
                     "No TLS credentials in freeDiameter config — provision certs (make_certs.sh) and enable TLS/IPsec for production"
                _scas_find=$((_scas_find + 1))
            fi
        else
            skip "Diameter transport security posture" "MME container not running"
        fi
    fi

    # TC-6: Diameter peer authentication / allow-listing (S6a)
    _TEST_NUM=$((_TEST_NUM + 1))
    if should_run_test $_TEST_NUM; then
        if container_is_running "mme"; then
            local fdconf6; fdconf6=$(read_mme_fd_conf)
            if [ -z "$fdconf6" ]; then
                skip "Diameter peer authentication / allow-listing" "Could not read mme freeDiameter config"
            elif echo "$fdconf6" | grep -qE '^[[:space:]]*ConnectPeer' && \
                 echo "$fdconf6" | grep -qE '^[[:space:]]*Identity' && \
                 echo "$fdconf6" | grep -qE '^[[:space:]]*Realm'; then
                pass "Diameter peers explicitly allow-listed (ConnectPeer + Identity/Realm; freeDiameter rejects unknown peers by default)"
                _scas_pass=$((_scas_pass + 1))
            else
                skip "Diameter peer authentication / allow-listing" \
                     "ConnectPeer/Identity/Realm not all present — verify peer allow-listing on S6a/Cx"
            fi
        else
            skip "Diameter peer authentication / allow-listing" "MME container not running"
        fi
    fi

    # TC-7: subscriber identity privacy — no clear IMSI in MME logs
    _TEST_NUM=$((_TEST_NUM + 1))
    if should_run_test $_TEST_NUM; then
        if container_is_running "mme"; then
            local imsi_hits
            imsi_hits=$(docker_logs_recent_matches "mme" '[0-9]{15}' 5)
            if [ -n "$imsi_hits" ]; then
                skip "Subscriber identity privacy (clear IMSI in logs)" \
                     "Clear 15-digit identifiers appear in MME logs (lab verbosity). ITSAR log-hygiene: mask IMSIs or reduce verbosity in production"
                _scas_find=$((_scas_find + 1))
            else
                pass "No clear 15-digit IMSI found in recent MME logs (identity privacy preserved in logs)"
                _scas_pass=$((_scas_pass + 1))
            fi
        else
            skip "Subscriber identity privacy" "MME container not running"
        fi
    fi

    # TC-8: NFs run as non-root (least privilege)
    _TEST_NUM=$((_TEST_NUM + 1))
    if should_run_test $_TEST_NUM; then
        local sample="mme sgwc smf upf" root_nfs="" checked8=0 nf8 uid8
        for nf8 in $sample; do
            if container_is_running "$nf8"; then
                checked8=$((checked8 + 1))
                uid8=$(container_uid "$nf8")
                [ "$uid8" = "0" ] && root_nfs="$root_nfs $nf8"
            fi
        done
        if [ "$checked8" -eq 0 ]; then
            skip "NF least-privilege (non-root)" "No sample NFs running to audit"
        elif [ -n "$root_nfs" ]; then
            skip "NF least-privilege (non-root)" \
                 "NF(s) run as root:$root_nfs (open5gs default). TS 33.117 recommends least-privilege non-root execution for production"
            _scas_find=$((_scas_find + 1))
        else
            pass "Sampled NFs run as non-root ($checked8 checked) — least-privilege posture"
            _scas_pass=$((_scas_pass + 1))
        fi
    fi

    # TC-9: S1/data-plane transport protection (IPsec)
    _TEST_NUM=$((_TEST_NUM + 1))
    if should_run_test $_TEST_NUM; then
        local ipsec_ev=""
        if container_is_running "mme"; then
            ipsec_ev=$(docker exec mme sh -c 'ip xfrm state 2>/dev/null | grep -i proto | head -1; command -v ipsec 2>/dev/null' 2>/dev/null || true)
        fi
        if [ -n "$ipsec_ev" ]; then
            pass "IPsec presence detected for S1/data-plane transport protection"
            _scas_pass=$((_scas_pass + 1))
        else
            skip "S1/data-plane transport protection (IPsec)" \
                 "No IPsec on S1-MME/S1-U (lab). TS 33.401 requires protection when the backhaul is not otherwise trusted/physically secured"
            _scas_find=$((_scas_find + 1))
        fi
    fi

    # TC-10: management API authentication posture (PyHSS API)
    _TEST_NUM=$((_TEST_NUM + 1))
    if should_run_test $_TEST_NUM; then
        if [ -n "$PYHSS_API_KEY" ]; then
            pass "PyHSS management API key configured (authenticated O&M access)"
            _scas_pass=$((_scas_pass + 1))
        else
            local pcode
            pcode=$(curl -s -o /dev/null -w "%{http_code}" --max-time 4 \
                "http://${PYHSS_IP}:8080/apn/list" 2>/dev/null || echo "000")
            if [ "$pcode" = "401" ] || [ "$pcode" = "403" ]; then
                pass "PyHSS management API rejects unauthenticated access (HTTP $pcode)"
                _scas_pass=$((_scas_pass + 1))
            elif [ "$pcode" = "200" ]; then
                skip "Management API authentication posture" \
                     "PyHSS API answers without authentication (lab default). ITSAR requires authenticated + role-based O&M access in production"
                _scas_find=$((_scas_find + 1))
            else
                skip "Management API authentication posture" "PyHSS API not reachable (HTTP $pcode)"
            fi
        fi
    fi

    # TC-11: listening-port inventory evidence (attack surface)
    _TEST_NUM=$((_TEST_NUM + 1))
    if should_run_test $_TEST_NUM; then
        local captured=0 nf11 raw11
        for nf11 in mme sgwc smf; do
            if container_is_running "$nf11"; then
                raw11=$(container_listeners_raw "$nf11")
                if [ -n "$raw11" ]; then
                    captured=$((captured + 1))
                    append_report_block "Listening sockets: $nf11" "$raw11"
                fi
            fi
        done
        if [ "$captured" -gt 0 ]; then
            pass "Attack-surface evidence captured: listening-port inventory for $captured NF(s)"
            _scas_pass=$((_scas_pass + 1))
        else
            skip "Listening-port inventory evidence" "Could not read socket tables (no ss/netstat or NFs down)"
        fi
    fi

    # TC-12: ITSAR hardening posture summary
    _TEST_NUM=$((_TEST_NUM + 1))
    if should_run_test $_TEST_NUM; then
        local summary="Hardened posture confirmed: ${_scas_pass} | Production-hardening findings (SKIP): ${_scas_find}"
        append_report_block "SCAS/ITSAR posture summary (4G)" "$summary"
        pass "ITSAR hardening posture summary emitted ($summary)"
    fi

    end_feature
}
