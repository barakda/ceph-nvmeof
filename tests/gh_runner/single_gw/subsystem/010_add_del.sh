#!/bin/bash
#
# single_gw/subsystem/010_add_del.sh
#
#     ceph nvmeof subsystem add --nqn <nqn> [--serial-number] [--max-namespaces]
#                               [--model-name] [--no-group-append]
#     ceph nvmeof subsystem del --nqn <nqn> [--force <bool>]
#
# Both the defaults the gateway fills in and the values it is handed are read
# back through `subsystem get`.
#
# Every subsystem here is created with --no-group-append. The gateway only
# appends a group name when one is configured, and ceph-nvmeof.conf ships with
# `group =` empty, so append is not observable in this cluster -- passing the
# flag makes the NQNs predictable rather than dependent on that config.
#
set -u -o pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=tests/gh_runner/lib/common.sh
source "$HERE/lib/common.sh"
# shellcheck source=tests/gh_runner/lib/cluster.sh
source "$HERE/lib/cluster.sh"

suite_begin "subsystem/010_add_del"

suite_cleanup() {
    suite_cleanup_subsystems
}
trap suite_exit EXIT

MINIMAL_NQN="$(suite_nqn minimal)"
FULL_NQN="$(suite_nqn full)"
SERIAL="GH$(date +%s)"

#
# One field of one subsystem, straight out of `subsystem get`.
#
subsys_field() {
    nvmeof_json subsystem get --nqn "$1" | json_get ".subsystems[0].$2"
}

subsys_count() {
    nvmeof_json subsystem list | json_get "[.subsystems[] | select(.nqn == \"$1\")] | length"
}

# ---------------------------------------------------------------------------
section "subsystem add: defaults"
# ---------------------------------------------------------------------------

assert_ok "subsystem add with only --nqn" \
    nvmeof_cmd subsystem add --nqn "$MINIMAL_NQN" --no-group-append

assert_eq "1" "$(subsys_count "$MINIMAL_NQN")" \
    "the new subsystem appears exactly once in subsystem list"

assert_ok "subsystem get finds it" nvmeof_cmd subsystem get --nqn "$MINIMAL_NQN"
assert_eq "$MINIMAL_NQN" "$(subsys_field "$MINIMAL_NQN" nqn)" \
    "subsystem get returns the subsystem we asked for"

# The gateway invents a serial number when none is given -- "Ceph" plus
# digits -- rather than leaving the field empty.
default_serial="$(subsys_field "$MINIMAL_NQN" serial_number)"
log "generated serial number: $default_serial"
assert_ne "" "$default_serial" "the gateway generated a serial number"
assert_ne "null" "$default_serial" "the generated serial number is not null"

assert_eq "Ceph bdev Controller" "$(subsys_field "$MINIMAL_NQN" model_number)" \
    "the subsystem gets the default model name"

assert_ge "$(subsys_field "$MINIMAL_NQN" max_namespaces)" 1 \
    "the subsystem gets a non-zero default max_namespaces"

assert_eq "0" "$(subsys_field "$MINIMAL_NQN" namespace_count)" \
    "a new subsystem has no namespaces"

assert_eq "false" "$(nvmeof_json subsystem get --nqn "$MINIMAL_NQN" |
    json_get 'if .subsystems[0].has_dhchap_key then "true" else "false" end')" \
    "a subsystem created without a key has no DH-HMAC-CHAP key"

# The subsystem also has to be visible to the target itself, not just in the
# gateway's own bookkeeping.
assert_contains "$(nvmeof_json get_subsystems)" "$MINIMAL_NQN" \
    "get_subsystems sees the new subsystem"

# ---------------------------------------------------------------------------
section "subsystem add: explicit options"
# ---------------------------------------------------------------------------

# --max-namespaces has a floor: create_subsystem in control/grpc.py compares
# the request against MIN_VALUE_FOR_MAX_NAMESPACES_PER_SUBSYSTEM, which is
# MAINTENANCE_ANA_GROUP (64), logs "Max namespaces can't be less than 64,
# will increase it" and silently raises anything smaller. Asking for a value
# below the floor therefore tests the clamp, not the option, so use one
# above it.
MAX_NAMESPACES=100

assert_ok "subsystem add with serial number, max namespaces and model name" \
    nvmeof_cmd subsystem add --nqn "$FULL_NQN" --no-group-append \
        --serial-number "$SERIAL" \
        --max-namespaces "$MAX_NAMESPACES" \
        --model-name "gh runner model"

assert_eq "$SERIAL" "$(subsys_field "$FULL_NQN" serial_number)" \
    "--serial-number was applied"
assert_eq "$MAX_NAMESPACES" "$(subsys_field "$FULL_NQN" max_namespaces)" \
    "--max-namespaces was applied"
assert_eq "gh runner model" "$(subsys_field "$FULL_NQN" model_number)" \
    "--model-name was applied"

# ---------------------------------------------------------------------------
section "subsystem list: filters"
# ---------------------------------------------------------------------------

assert_eq "$FULL_NQN" \
    "$(nvmeof_json subsystem list --nqn "$FULL_NQN" | json_get '.subsystems[0].nqn')" \
    "subsystem list --nqn filters to that subsystem"
assert_eq "1" \
    "$(nvmeof_json subsystem list --nqn "$FULL_NQN" | json_get '.subsystems | length')" \
    "subsystem list --nqn returns nothing else"

assert_eq "$FULL_NQN" \
    "$(nvmeof_json subsystem list --serial-number "$SERIAL" | json_get '.subsystems[0].nqn')" \
    "subsystem list --serial-number finds it by serial"

# ---------------------------------------------------------------------------
section "subsystem add: rejections"
# ---------------------------------------------------------------------------

assert_fails "subsystem add requires --nqn" \
    nvmeof_cmd subsystem add --no-group-append

assert_fails "subsystem add rejects a duplicate NQN" \
    nvmeof_cmd subsystem add --nqn "$FULL_NQN" --no-group-append

# Serial numbers identify a subsystem to an initiator, so the gateway refuses
# to hand the same one to two subsystems.
assert_fails "subsystem add rejects a serial number already in use" \
    nvmeof_cmd subsystem add --nqn "$(suite_nqn clash)" --no-group-append \
        --serial-number "$SERIAL"

assert_fails "subsystem add rejects an NQN that is not an NQN" \
    nvmeof_cmd subsystem add --nqn "not-an-nqn" --no-group-append

# A rejected add must not have created anything.
assert_eq "0" "$(subsys_count "$(suite_nqn clash)")" \
    "the rejected add left no subsystem behind"

# ---------------------------------------------------------------------------
section "subsystem del"
# ---------------------------------------------------------------------------

assert_fails "subsystem del requires --nqn" nvmeof_cmd subsystem del

assert_fails "subsystem del rejects an unknown NQN" \
    nvmeof_cmd subsystem del --nqn "$(suite_nqn never-created)"

assert_ok "subsystem del removes a subsystem" \
    nvmeof_cmd subsystem del --nqn "$MINIMAL_NQN"
assert_eq "0" "$(subsys_count "$MINIMAL_NQN")" \
    "the deleted subsystem is gone from subsystem list"
assert_not_contains "$(nvmeof_json get_subsystems)" "$MINIMAL_NQN" \
    "the deleted subsystem is gone from get_subsystems"

assert_fails "subsystem get rejects an NQN that was just deleted" \
    nvmeof_cmd subsystem get --nqn "$MINIMAL_NQN"

# --force only matters for a subsystem that still has namespaces; on an empty
# one it is simply accepted.
assert_ok "subsystem del --force true on an empty subsystem" \
    nvmeof_cmd subsystem del --nqn "$FULL_NQN" --force true
assert_eq "0" "$(subsys_count "$FULL_NQN")" \
    "the force-deleted subsystem is gone"
