#!/bin/bash
#
# single_gw/gateway/030_io_stats_mode.sh
#
#     ceph nvmeof gateway set_io_stats_mode --enabled <bool>
#
# The effect is only observable through `gateway info`'s io_stats_enabled, so
# that is what the check reads back. IO statistics are gateway-wide state that
# the connection and namespace statistics suites depend on, so the original
# setting is restored on the way out.
#
set -u -o pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=tests/gh_runner/lib/common.sh
source "$HERE/lib/common.sh"
# shellcheck source=tests/gh_runner/lib/cluster.sh
source "$HERE/lib/cluster.sh"

suite_begin "gateway/030_io_stats_mode"

ORIGINAL_MODE=""

suite_cleanup() {
    [ -n "$ORIGINAL_MODE" ] || return 0
    log "restoring io stats mode '$ORIGINAL_MODE'"
    nvmeof_cmd gateway set_io_stats_mode --enabled="$ORIGINAL_MODE" ||
        warn "could not restore the gateway io stats mode"
}
trap suite_exit EXIT

#
# io_stats_enabled as the literal "true" or "false", whatever jq would
# otherwise render a JSON boolean or a missing field as.
#
io_stats_mode() {
    nvmeof_json gateway info |
        json_get 'if .io_stats_enabled then "true" else "false" end'
}

ORIGINAL_MODE="$(io_stats_mode)"
log "current io stats mode: $ORIGINAL_MODE"

# ---------------------------------------------------------------------------
section "gateway set_io_stats_mode"
# ---------------------------------------------------------------------------

for mode in true false true; do
    assert_ok "set_io_stats_mode --enabled $mode" \
        nvmeof_cmd gateway set_io_stats_mode --enabled="$mode"
    assert_eq "$mode" "$(io_stats_mode)" \
        "gateway info reports io_stats_enabled=$mode"
done

assert_ok "gw set_io_stats_mode alias" \
    nvmeof_cmd gw set_io_stats_mode --enabled=true
assert_eq "true" "$(io_stats_mode)" "alias set_io_stats_mode took effect"

# ---------------------------------------------------------------------------
section "gateway set_io_stats_mode: rejections"
# ---------------------------------------------------------------------------

assert_fails "set_io_stats_mode requires --enabled" \
    nvmeof_cmd gateway set_io_stats_mode

assert_fails "set_io_stats_mode rejects a non-boolean" \
    nvmeof_cmd gateway set_io_stats_mode --enabled=perhaps

assert_eq "true" "$(io_stats_mode)" "a rejected set_io_stats_mode left the mode alone"
