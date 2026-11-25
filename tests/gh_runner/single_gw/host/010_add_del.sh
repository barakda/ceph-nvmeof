#!/bin/bash
#
# single_gw/host/010_add_del.sh
#
#     ceph nvmeof host add --nqn --host-nqn [--dhchap-key] [--dhchap-controller-key] [--psk]
#     ceph nvmeof host del --nqn --host-nqn [--force] [--keep-connections]
#     ceph nvmeof host list --nqn
#
# The access list only, without any in-band authentication: keys and PSKs are
# the secure shape's business. "*" is the wildcard that opens a subsystem to
# every host, and it is mutually exclusive with naming hosts individually.
#
set -u -o pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=tests/gh_runner/lib/common.sh
source "$HERE/lib/common.sh"
# shellcheck source=tests/gh_runner/lib/cluster.sh
source "$HERE/lib/cluster.sh"

suite_begin "host/010_add_del"

suite_cleanup() {
    suite_cleanup_subsystems
}
trap suite_exit EXIT

NQN="$(suite_nqn hosts)"
OPEN_NQN="$(suite_nqn open)"
HOST_A="nqn.2014-08.org.nvmexpress:uuid:$(uuidgen 2>/dev/null ||
    echo 11111111-2222-3333-4444-555555555555)"
HOST_B="nqn.2014-08.org.nvmexpress:uuid:$(uuidgen 2>/dev/null ||
    echo 66666666-7777-8888-9999-aaaaaaaaaaaa)"

host_count() {
    nvmeof_json host list --nqn "${1:-$NQN}" | json_get '.hosts | length'
}

has_host() {
    nvmeof_json host list --nqn "$NQN" |
        json_get "[.hosts[] | select(.nqn == \"$1\")] | length"
}

allows_any_host() {
    nvmeof_json host list --nqn "${1:-$NQN}" |
        json_get 'if .allow_any_host then "true" else "false" end'
}

# ---------------------------------------------------------------------------
section "Setup"
# ---------------------------------------------------------------------------

assert_ok "subsystem add" nvmeof_cmd subsystem add --nqn "$NQN" --no-group-append
assert_ok "a second subsystem for the wildcard" \
    nvmeof_cmd subsystem add --nqn "$OPEN_NQN" --no-group-append

assert_ok "host list on a subsystem with none" nvmeof_cmd host list --nqn "$NQN"
assert_eq "0" "$(host_count)" "a new subsystem allows no hosts"
assert_eq "false" "$(allows_any_host)" "and does not allow any host"

# ---------------------------------------------------------------------------
section "host add / list"
# ---------------------------------------------------------------------------

assert_ok "host add" nvmeof_cmd host add --nqn "$NQN" --host-nqn "$HOST_A"
assert_eq "1" "$(has_host "$HOST_A")" "the host is on the access list"
assert_eq "1" "$(host_count)" "exactly one host"

assert_ok "host add for a second host" nvmeof_cmd host add --nqn "$NQN" --host-nqn "$HOST_B"
assert_eq "2" "$(host_count)" "both hosts are listed"

# Nothing was given a key, so neither mechanism should be flagged.
hosts="$(nvmeof_json host list --nqn "$NQN")"
assert_eq "0" "$(json_get '[.hosts[] | select(.use_dhchap)] | length' <<< "$hosts")" \
    "no host is using DH-HMAC-CHAP"
assert_eq "0" "$(json_get '[.hosts[] | select(.use_psk)] | length' <<< "$hosts")" \
    "no host is using a PSK"

assert_fails "host add requires --host-nqn" nvmeof_cmd host add --nqn "$NQN"

assert_fails "host add rejects a malformed host NQN" \
    nvmeof_cmd host add --nqn "$NQN" --host-nqn "not-an-nqn"

assert_fails "host add rejects an unknown subsystem" \
    nvmeof_cmd host add --nqn "$(suite_nqn never-created)" --host-nqn "$HOST_A"

assert_eq "2" "$(host_count)" "the rejected adds changed nothing"

# ---------------------------------------------------------------------------
section "host add: the \"*\" wildcard"
# ---------------------------------------------------------------------------

assert_ok "host add \"*\" opens the subsystem to everyone" \
    nvmeof_cmd host add --nqn "$OPEN_NQN" --host-nqn '*'
assert_eq "true" "$(allows_any_host "$OPEN_NQN")" "the subsystem allows any host"

# An open subsystem has no use for an individual entry, so the two cannot be
# combined.
assert_fails "host add of a named host is refused while \"*\" is set" \
    nvmeof_cmd host add --nqn "$OPEN_NQN" --host-nqn "$HOST_A"

assert_ok "host del \"*\" closes it again" \
    nvmeof_cmd host del --nqn "$OPEN_NQN" --host-nqn '*'
assert_eq "false" "$(allows_any_host "$OPEN_NQN")" "the subsystem is closed again"

# ---------------------------------------------------------------------------
section "host del"
# ---------------------------------------------------------------------------

assert_fails "host del requires --host-nqn" nvmeof_cmd host del --nqn "$NQN"

assert_fails "host del rejects a host that is not on the list" \
    nvmeof_cmd host del --nqn "$NQN" --host-nqn \
        "nqn.2014-08.org.nvmexpress:uuid:00000000-0000-0000-0000-000000000000"

assert_ok "host del" nvmeof_cmd host del --nqn "$NQN" --host-nqn "$HOST_B"
assert_eq "0" "$(has_host "$HOST_B")" "the removed host is gone"
assert_eq "1" "$(has_host "$HOST_A")" "the other host was left alone"

# --keep-connections leaves an already connected initiator alone instead of
# dropping it along with its access. Nothing is connected here, so this only
# establishes that the option is accepted and still removes the entry.
assert_ok "host del --keep-connections" \
    nvmeof_cmd host del --nqn "$NQN" --host-nqn "$HOST_A" --keep-connections=true
assert_eq "0" "$(host_count)" "no hosts left"
