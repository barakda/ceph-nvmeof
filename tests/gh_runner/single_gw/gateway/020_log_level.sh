#!/bin/bash
#
# single_gw/gateway/020_log_level.sh
#
#     ceph nvmeof gateway get_log_level   (alias: gw get_log_level)
#     ceph nvmeof gateway set_log_level --log-level <level>
#
# Every level of the GwLogLevel enum is set and read back. The gateway's log
# level is global state shared with the other suites of this shape, so the
# original value is restored on the way out.
#
set -u -o pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=tests/gh_runner/lib/common.sh
source "$HERE/lib/common.sh"
# shellcheck source=tests/gh_runner/lib/cluster.sh
source "$HERE/lib/cluster.sh"

suite_begin "gateway/020_log_level"

ORIGINAL_LEVEL=""

suite_cleanup() {
    [ -n "$ORIGINAL_LEVEL" ] || return 0
    log "restoring log level '$ORIGINAL_LEVEL'"
    nvmeof_cmd gateway set_log_level --log-level "$ORIGINAL_LEVEL" ||
        warn "could not restore the gateway log level"
}
trap suite_exit EXIT

#
# Read the current level, lowercased: the gateway accepts either case and we
# do not want the comparison to depend on which one it echoes back.
#
current_level() {
    nvmeof_json gateway get_log_level | json_get '.log_level' | tr '[:upper:]' '[:lower:]'
}

# ---------------------------------------------------------------------------
section "gateway get_log_level"
# ---------------------------------------------------------------------------

assert_ok "gateway get_log_level succeeds" nvmeof_cmd gateway get_log_level
assert_ok "gw get_log_level alias succeeds" nvmeof_cmd gw get_log_level

ORIGINAL_LEVEL="$(current_level)"
log "current gateway log level: '$ORIGINAL_LEVEL'"
assert_ne "" "$ORIGINAL_LEVEL" "get_log_level reports a level"
assert_ne "null" "$ORIGINAL_LEVEL" "get_log_level level is not null"

# ---------------------------------------------------------------------------
section "gateway set_log_level: every level of the enum"
# ---------------------------------------------------------------------------

# GwLogLevel in control/proto/gateway.proto. `notset` is the zero value and is
# not something a user sets, so it is left out.
for level in debug info warning error critical; do
    assert_ok "set_log_level --log-level $level" \
        nvmeof_cmd gateway set_log_level --log-level "$level"
    assert_eq "$level" "$(current_level)" \
        "get_log_level reads back '$level'"
done

# The alias has its own command registration, so exercise it too.
assert_ok "gw set_log_level alias" nvmeof_cmd gw set_log_level --log-level info
assert_eq "info" "$(current_level)" "alias set_log_level took effect"

# ---------------------------------------------------------------------------
section "gateway set_log_level: rejections"
# ---------------------------------------------------------------------------

assert_fails "set_log_level rejects an unknown level" \
    nvmeof_cmd gateway set_log_level --log-level no_such_level

assert_fails "set_log_level requires --log-level" \
    nvmeof_cmd gateway set_log_level

# A rejected request must not have changed anything.
assert_eq "info" "$(current_level)" "a rejected set_log_level left the level alone"
