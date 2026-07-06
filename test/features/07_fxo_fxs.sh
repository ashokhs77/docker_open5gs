#!/bin/bash
# Feature 07: FXO/FXS
# Temporarily disabled until the production call path is confirmed.

set +e

source /opt/test/lib/common.sh

run_fxo_fxs_tests() {
    start_feature "FXO/FXS"

    local reason="Temporarily disabled pending confirmed production FXO/FXS call path"

    _TEST_NUM=$((_TEST_NUM + 1))
    if should_run_test $_TEST_NUM; then
        log "TC-${_TEST_NUM}: FXO/FXS feature availability"
        skip "FXO/FXS test case disabled" "$reason"
    fi

    _TEST_NUM=$((_TEST_NUM + 1))
    if should_run_test $_TEST_NUM; then
        log "TC-${_TEST_NUM}: FXO/FXS feature availability"
        skip "FXO/FXS test case disabled" "$reason"
    fi

    _TEST_NUM=$((_TEST_NUM + 1))
    if should_run_test $_TEST_NUM; then
        log "TC-${_TEST_NUM}: FXO/FXS feature availability"
        skip "FXO/FXS test case disabled" "$reason"
    fi

    _TEST_NUM=$((_TEST_NUM + 1))
    if should_run_test $_TEST_NUM; then
        log "TC-${_TEST_NUM}: FXO/FXS feature availability"
        skip "FXO/FXS test case disabled" "$reason"
    fi

    _TEST_NUM=$((_TEST_NUM + 1))
    if should_run_test $_TEST_NUM; then
        log "TC-${_TEST_NUM}: FXO/FXS feature availability"
        skip "FXO/FXS test case disabled" "$reason"
    fi

    end_feature
}
