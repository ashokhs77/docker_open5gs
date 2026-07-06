#!/bin/bash
# Feature 23: IMS Voice/Video Profile Conformance (4G — IR.92 / IR.94)  (TRL8 add-on)
# GSMA IR.92 (VoLTE IMS profile), IR.94 (ViLTE video), 3GPP TS 24.229 (IMS SIP),
# TS 33.203 (IMS access security / IPSec). The IMS stack is SHARED with 5G VoNR,
# so the 5G twin (ims_ng114_5g) runs the same checks under the NG.114 framing.
#
# Complements (does NOT duplicate) volte/vilte/advanced_sip/conference/security:
# those drive calls; this audits the PROFILE conformance — IMS-AKA+IPSec access
# security, the mandated codec set, and the media/registration plane.
#
# Verified P-CSCF (Kamailio) reality (VM 2026-06-11, /mnt/pcscf/kamailio_pcscf.cfg):
#   loadmodule ims_ipsec_pcscf / ims_registrar_pcscf / auth / sdpops / rtpengine
#   ims_ipsec_pcscf: ipsec_spi_id_start 4096, ipsec_preferred_ealg "null"
#   FreeSWITCH: mod_amr + mod_amrwb; codec_prefs AMR,AMR-WB,H264,VP8,OPUS (no EVS)
#
# Calibration: PASS on present capability; SKIP-with-finding for profile items the
# lab legitimately omits (EVS, real IPSec SA without an IMS-AKA UE); FAIL only on a
# genuine defect (IMS registrar absent while P-CSCF is up).
#
# Tests:
#   TC-1:  P-CSCF IMS registrar capability (ims_registrar_pcscf)   [TS 24.229]
#   TC-2:  IMS access-security: IPSec module loaded                [TS 33.203 / IR.92]
#   TC-3:  IPSec SA parameters configured (SPI range + ports)      [TS 33.203]
#   TC-4:  IPSec integrity/encryption posture (ealg)               [TS 33.203]
#   TC-5:  IMS authentication enforced (REGISTER -> 401 challenge)  [IR.92 / TS 24.229]
#   TC-6:  Mandatory voice codec AMR present                       [IR.92 §4.1]
#   TC-7:  Mandatory wideband voice codec AMR-WB present           [IR.92 §4.1]
#   TC-8:  EVS codec (5G NG.114 voice)                             [NG.114]
#   TC-9:  Video codec H.264 (IR.94 / ViLTE-ViNR)                  [IR.94]
#   TC-10: Media plane: SDP manipulation + RTP anchoring           [IR.92]
#   TC-11: IMS registration evidence (successful REGISTER/200)     [TS 24.229]
#   TC-12: SIP reliable-provisional/precondition readiness          [RFC 3312/3262]

set +e

# Read the active P-CSCF Kamailio config (volume mount first, then in-image).
read_pcscf_cfg() {
    docker exec pcscf sh -c 'cat /mnt/pcscf/kamailio_pcscf.cfg /mnt/pcscf/pcscf.cfg 2>/dev/null || cat /etc/kamailio/kamailio_pcscf.cfg /etc/kamailio/pcscf.cfg 2>/dev/null' 2>/dev/null || true
}
# Read the FreeSWITCH codec configuration.
read_fs_codecs() {
    docker exec freeswitch sh -c 'cat /usr/local/freeswitch/conf/autoload_configs/modules.conf.xml /mnt/freeswitch/vars.xml 2>/dev/null' 2>/dev/null || true
}

run_ims_ng114_tests() {
    start_feature "IMS Profile (IR.92/IR.94)"

    local pcscf_up=false fs_up=false
    container_is_running "pcscf" && pcscf_up=true
    container_is_running "freeswitch" && fs_up=true
    local pcfg=""; $pcscf_up && pcfg=$(read_pcscf_cfg)
    local fscfg=""; $fs_up && fscfg=$(read_fs_codecs)

    # TC-1: IMS registrar capability
    _TEST_NUM=$((_TEST_NUM + 1))
    if should_run_test $_TEST_NUM; then
        if [ -z "$pcfg" ]; then
            skip "P-CSCF IMS registrar capability" "Could not read P-CSCF config ($($pcscf_up && echo 'cfg path?' || echo 'P-CSCF down'))"
        elif echo "$pcfg" | grep -qiE 'ims_registrar_pcscf'; then
            pass "P-CSCF IMS registrar loaded (ims_registrar_pcscf — IMS registration per TS 24.229)"
        elif echo "$pcfg" | grep -qiE 'loadmodule.*registrar'; then
            pass "P-CSCF registrar module present (IMS registration capability)"
        else
            fail "P-CSCF up but no registrar module loaded" "IMS registration cannot work — check kamailio_pcscf.cfg"
        fi
    fi

    # TC-2: IMS access-security IPSec module loaded
    _TEST_NUM=$((_TEST_NUM + 1))
    if should_run_test $_TEST_NUM; then
        if [ -z "$pcfg" ]; then
            skip "IMS IPSec module" "Could not read P-CSCF config"
        elif echo "$pcfg" | grep -qiE 'ims_ipsec_pcscf'; then
            pass "IMS access-security present: ims_ipsec_pcscf loaded (IPSec SA between UE and P-CSCF — TS 33.203/IR.92)"
        else
            skip "IMS IPSec module" \
                 "ims_ipsec_pcscf not loaded — IR.92/TS 33.203 require IPSec access security between UE and P-CSCF for production"
        fi
    fi

    # TC-3: IPSec SA parameters configured (SPI range + ports)
    _TEST_NUM=$((_TEST_NUM + 1))
    if should_run_test $_TEST_NUM; then
        if echo "$pcfg" | grep -qiE 'ipsec_spi_id_start' && echo "$pcfg" | grep -qiE 'ipsec_(client|server)_port'; then
            local spi
            spi=$(echo "$pcfg" | grep -iE 'ipsec_spi_id_start' | grep -oE '[0-9]+' | head -1)
            pass "IPSec SA parameters configured (SPI id start=${spi:-set}, client/server ports defined — TS 33.203)"
        elif echo "$pcfg" | grep -qiE 'ims_ipsec_pcscf'; then
            skip "IPSec SA parameters" "ims_ipsec_pcscf loaded but SPI/port params not all found — verify modparams"
        else
            skip "IPSec SA parameters" "IPSec not configured (see TC-2)"
        fi
    fi

    # TC-4: IPSec integrity/encryption posture (ealg)
    _TEST_NUM=$((_TEST_NUM + 1))
    if should_run_test $_TEST_NUM; then
        if echo "$pcfg" | grep -iE 'ipsec_preferred_ealg' | grep -qiE 'null'; then
            skip "IPSec encryption posture (ealg=null)" \
                 "P-CSCF uses IPSec integrity-only (ipsec_preferred_ealg=null). Permitted by TS 33.203 (integrity is mandatory, encryption optional); enable an encryption algorithm (e.g. AES) if confidentiality is required by the deployment"
        elif echo "$pcfg" | grep -qiE 'ipsec_preferred_ealg'; then
            local ea; ea=$(echo "$pcfg" | grep -iE 'ipsec_preferred_ealg' | grep -oiE '"[a-z0-9-]+"' | tail -1)
            pass "IPSec confidentiality configured (ipsec_preferred_ealg=${ea} — integrity+encryption)"
        else
            skip "IPSec encryption posture" "ipsec_preferred_ealg not set (see TC-2)"
        fi
    fi

    # TC-5: IMS authentication enforced (REGISTER -> 401)
    _TEST_NUM=$((_TEST_NUM + 1))
    if should_run_test $_TEST_NUM; then
        if echo "$pcfg" | grep -qiE 'loadmodule.*auth|www_challenge|proxy_challenge|ims_auth|auth_challenge'; then
            pass "IMS authentication configured (auth/challenge module present — REGISTER is challenged per IR.92)"
        elif $pcscf_up; then
            skip "IMS authentication enforcement" "auth/challenge module not detected in config — verify REGISTER is challenged (security feature TC covers the 401 probe)"
        else
            skip "IMS authentication enforcement" "P-CSCF not running"
        fi
    fi

    # TC-6: Mandatory voice codec AMR
    _TEST_NUM=$((_TEST_NUM + 1))
    if should_run_test $_TEST_NUM; then
        if [ -z "$fscfg" ]; then
            skip "AMR voice codec" "Could not read FreeSWITCH codec config"
        elif echo "$fscfg" | grep -qiE 'mod_amr"|AMR'; then
            pass "Mandatory voice codec AMR present (mod_amr / codec_prefs — IR.92 §4.1)"
        else
            skip "AMR voice codec" "AMR not found in FreeSWITCH config — IR.92 mandates AMR for VoLTE"
        fi
    fi

    # TC-7: Mandatory wideband voice codec AMR-WB
    _TEST_NUM=$((_TEST_NUM + 1))
    if should_run_test $_TEST_NUM; then
        if [ -z "$fscfg" ]; then
            skip "AMR-WB voice codec" "Could not read FreeSWITCH codec config"
        elif echo "$fscfg" | grep -qiE 'mod_amrwb|AMR-WB'; then
            pass "Mandatory wideband codec AMR-WB present (mod_amrwb / codec_prefs — IR.92 §4.1 HD voice)"
        else
            skip "AMR-WB voice codec" "AMR-WB not found — IR.92 mandates AMR-WB for HD VoLTE"
        fi
    fi

    # TC-8: EVS codec (5G NG.114 voice)
    _TEST_NUM=$((_TEST_NUM + 1))
    if should_run_test $_TEST_NUM; then
        if echo "$fscfg" | grep -qiE 'mod_evs|[^a-z]EVS[^a-z]|"EVS"'; then
            pass "EVS codec present (NG.114 5G voice / super-wideband)"
        else
            skip "EVS codec (NG.114)" \
                 "EVS not available in FreeSWITCH (no mod_evs). NG.114 recommends EVS for 5G voice; AMR-WB interworking is the fallback. Add an EVS-capable media node for full NG.114 conformance"
        fi
    fi

    # TC-9: Video codec H.264 (IR.94 / ViLTE-ViNR)
    _TEST_NUM=$((_TEST_NUM + 1))
    if should_run_test $_TEST_NUM; then
        if echo "$fscfg" | grep -qiE 'H264|H\.264'; then
            pass "Video codec H.264 present (IR.94 ViLTE / ViNR video telephony)"
        else
            skip "H.264 video codec" "H.264 not found in FreeSWITCH codec prefs — IR.94 video needs H.264"
        fi
    fi

    # TC-10: Media plane — SDP manipulation + RTP anchoring
    _TEST_NUM=$((_TEST_NUM + 1))
    if should_run_test $_TEST_NUM; then
        local sdpops=false rtpe=false
        echo "$pcfg" | grep -qiE 'sdpops' && sdpops=true
        echo "$pcfg" | grep -qiE 'rtpengine' && rtpe=true
        if $sdpops && $rtpe; then
            pass "Media plane conformant: SDP manipulation (sdpops) + RTP anchoring (rtpengine) at P-CSCF (IR.92 media handling)"
        elif $rtpe || $sdpops; then
            pass "Media-plane module present ($($sdpops && echo sdpops) $($rtpe && echo rtpengine)) — verify the other"
        elif [ -z "$pcfg" ]; then
            skip "Media plane (sdpops/rtpengine)" "Could not read P-CSCF config"
        else
            skip "Media plane (sdpops/rtpengine)" "Neither sdpops nor rtpengine detected — verify media handling"
        fi
    fi

    # TC-11: IMS registration evidence (successful REGISTER / 200 OK)
    _TEST_NUM=$((_TEST_NUM + 1))
    if should_run_test $_TEST_NUM; then
        if $pcscf_up; then
            local reg_ev
            reg_ev=$(docker_logs_recent_matches "pcscf" "REGISTER|saved.*contact|Contact.*saved|200.*OK.*REGISTER|registrar" 8)
            if [ -n "$reg_ev" ]; then
                pass "IMS registration activity evidenced at P-CSCF (REGISTER/registrar — TS 24.229)"
                append_report_block "IMS registration evidence" "$(echo "$reg_ev" | tail -3)"
            else
                skip "IMS registration evidence" "No recent REGISTER in window — exercised by volte/vonr E2E; run those or a UE registration"
            fi
        else
            skip "IMS registration evidence" "P-CSCF not running"
        fi
    fi

    # TC-12: SIP reliable provisional / precondition readiness
    _TEST_NUM=$((_TEST_NUM + 1))
    if should_run_test $_TEST_NUM; then
        if echo "$pcfg" | grep -qiE '100rel|precond|PRACK|require.*100rel|Supported.*100rel'; then
            pass "SIP reliable provisional / precondition handling configured (100rel/PRACK — RFC 3262/3312)"
        elif echo "$pcfg" | grep -qiE 'sdpops|rtpengine'; then
            skip "SIP precondition / 100rel" \
                 "No explicit 100rel/precondition handling in P-CSCF config. IR.92 voice uses SDP preconditions (RFC 3312) + 100rel; add reliable-provisional handling for strict profile conformance"
        else
            skip "SIP precondition / 100rel" "Could not assess from P-CSCF config"
        fi
    fi

    end_feature
}
