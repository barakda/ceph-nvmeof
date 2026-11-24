#!/bin/bash
#
# single_gw/gateway/040_spdk_log_level.sh
#
#     ceph nvmeof spdk_log_level get [--all-log-flags]
#     ceph nvmeof spdk_log_level set [--log-level] [--print-level] [--extra-log-flags]
#     ceph nvmeof spdk_log_level disable [--extra-log-flags]
#
# SPDK's own log levels, which are a different enum from the gateway's:
# ERROR/WARNING/NOTICE/INFO/DEBUG (proto `LogLevel`), not debug/info/.../critical
# (proto `GwLogLevel`). Mixing the two up is the easy mistake here, so both the
# accepted and the rejected spellings are checked.
#
# SPDK log state is gateway-wide; `disable` at the end puts it back.
#
set -u -o pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=tests/gh_runner/lib/common.sh
source "$HERE/lib/common.sh"
# shellcheck source=tests/gh_runner/lib/cluster.sh
source "$HERE/lib/cluster.sh"

suite_begin "gateway/040_spdk_log_level"

suite_cleanup() {
    log "disabling the SPDK log flags this suite set"
    nvmeof_cmd spdk_log_level disable || warn "could not disable the SPDK log flags"
}
trap suite_exit EXIT

spdk_level() {
    nvmeof_json spdk_log_level get | json_get '.log_level' | tr '[:lower:]' '[:upper:]'
}

spdk_print_level() {
    nvmeof_json spdk_log_level get | json_get '.log_print_level' | tr '[:lower:]' '[:upper:]'
}

# ---------------------------------------------------------------------------
section "spdk_log_level get"
# ---------------------------------------------------------------------------

assert_ok "spdk_log_level get succeeds" nvmeof_cmd spdk_log_level get

get_json="$(nvmeof_json spdk_log_level get)"
echo "$get_json"
assert_eq "0" "$(json_get '.status' <<< "$get_json")" \
    "spdk_log_level get reports status 0"
assert_ne "" "$(json_get '.log_level' <<< "$get_json")" \
    "spdk_log_level get reports a log level"
assert_eq "array" "$(json_get '.nvmf_log_flags | type' <<< "$get_json")" \
    "spdk_log_level get reports the nvmf log flags"

# --all-log-flags widens the result to SPDK's non-NVMF flags as well, so it can
# never return fewer of them than the default.
nvmf_only_count="$(json_get '.nvmf_log_flags | length' <<< "$get_json")"
all_count="$(nvmeof_json spdk_log_level get --all-log-flags | json_get '.nvmf_log_flags | length')"
log "log flags: $nvmf_only_count nvmf, $all_count with --all-log-flags"
assert_ok "spdk_log_level get --all-log-flags succeeds" \
    nvmeof_cmd spdk_log_level get --all-log-flags
assert_ge "$nvmf_only_count" 1 "the default listing has nvmf log flags in it"
assert_ge "$all_count" "$nvmf_only_count" \
    "--all-log-flags reports at least as many flags as the default"

# ---------------------------------------------------------------------------
section "spdk_log_level set"
# ---------------------------------------------------------------------------

# proto `LogLevel`: ERROR, WARNING, NOTICE, INFO, DEBUG.
for level in ERROR WARNING NOTICE INFO DEBUG; do
    assert_ok "spdk_log_level set --log-level $level" \
        nvmeof_cmd spdk_log_level set --log-level "$level"
    assert_eq "$level" "$(spdk_level)" "spdk_log_level get reads back $level"
done

assert_ok "spdk_log_level set --print-level NOTICE" \
    nvmeof_cmd spdk_log_level set --print-level NOTICE
assert_eq "NOTICE" "$(spdk_print_level)" "spdk_log_level get reads back print level NOTICE"

assert_ok "spdk_log_level set accepts both levels at once" \
    nvmeof_cmd spdk_log_level set --log-level INFO --print-level INFO
assert_eq "INFO" "$(spdk_level)" "combined set applied the log level"
assert_eq "INFO" "$(spdk_print_level)" "combined set applied the print level"

assert_ok "spdk_log_level set --extra-log-flags" \
    nvmeof_cmd spdk_log_level set --log-level DEBUG --extra-log-flags bdev
assert_contains "$(nvmeof_json spdk_log_level get --all-log-flags)" "bdev" \
    "the extra 'bdev' log flag shows up in --all-log-flags"

# ---------------------------------------------------------------------------
section "spdk_log_level set: rejections"
# ---------------------------------------------------------------------------

assert_fails "spdk_log_level set rejects an unknown level" \
    nvmeof_cmd spdk_log_level set --log-level no_such_level

# `critical` belongs to GwLogLevel, not to SPDK's LogLevel.
assert_fails "spdk_log_level set rejects a gateway-only level name" \
    nvmeof_cmd spdk_log_level set --log-level critical

assert_fails "spdk_log_level set rejects an unknown extra flag" \
    nvmeof_cmd spdk_log_level set --extra-log-flags no_such_flag

# ---------------------------------------------------------------------------
section "spdk_log_level disable"
# ---------------------------------------------------------------------------

assert_ok "spdk_log_level disable succeeds" nvmeof_cmd spdk_log_level disable
assert_ok "spdk_log_level disable --extra-log-flags" \
    nvmeof_cmd spdk_log_level disable --extra-log-flags bdev

disabled_json="$(nvmeof_json spdk_log_level get)"
echo "$disabled_json"
assert_eq "0" "$(json_get '[.nvmf_log_flags[] | select(.enabled)] | length' <<< "$disabled_json")" \
    "no nvmf log flag is left enabled after disable"
