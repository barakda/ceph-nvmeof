#!/bin/bash
#
# single_gw/listener/010_add_del.sh
#
#     ceph nvmeof listener add --nqn --host-name --traddr [--trsvcid] [--adrfam]
#                              [--secure] [--force] [--verify-host-name]
#     ceph nvmeof listener del --nqn --host-name --trsvcid [--adrfam] [--force]
#     ceph nvmeof listener list --nqn
#     ceph nvmeof gateway listener_info --nqn
#     ceph nvmeof gateway refresh_network [--nqn]
#
# --host-name has to be the gateway's own hostname: a listener is created on
# the gateway that owns that name, and the dashboard sends the request to the
# gateway picked by --server-address. The two have to agree, which is what
# --verify-host-name enforces.
#
# `gateway listener_info` and `refresh_network` live here rather than in the
# gateway suite because both need a subsystem with listeners to say anything.
#
set -u -o pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=tests/gh_runner/lib/common.sh
source "$HERE/lib/common.sh"
# shellcheck source=tests/gh_runner/lib/cluster.sh
source "$HERE/lib/cluster.sh"

suite_begin "listener/010_add_del"

suite_cleanup() {
    suite_cleanup_subsystems
}
trap suite_exit EXIT

NQN="$(suite_nqn lst)"
GW_HOST="$(gateway_hostname "$NVMEOF_TARGET_CONTAINER")"
GW_ADDR="$NVMEOF_TARGET_ADDRESS"
PORT1=4420
PORT2=4421

listener_count() {
    nvmeof_json listener list --nqn "$NQN" | json_get '.listeners | length'
}

has_listener_on_port() {
    nvmeof_json listener list --nqn "$NQN" |
        json_get "[.listeners[] | select(.trsvcid == $1)] | length"
}

# ---------------------------------------------------------------------------
section "Setup"
# ---------------------------------------------------------------------------

log "gateway host name: $GW_HOST, address: $GW_ADDR"
assert_ok "subsystem add" nvmeof_cmd subsystem add --nqn "$NQN" --no-group-append

assert_ok "listener list on a subsystem with none" nvmeof_cmd listener list --nqn "$NQN"
assert_eq "0" "$(listener_count)" "a new subsystem has no listeners"

# ---------------------------------------------------------------------------
section "listener add"
# ---------------------------------------------------------------------------

assert_ok "listener add" \
    nvmeof_cmd listener add --nqn "$NQN" --host-name "$GW_HOST" \
        --traddr "$GW_ADDR" --trsvcid "$PORT1"

assert_eq "1" "$(listener_count)" "the listener was created"
assert_eq "1" "$(has_listener_on_port "$PORT1")" "it is on the port we asked for"

listener="$(nvmeof_json listener list --nqn "$NQN")"
assert_eq "$GW_ADDR" "$(json_get '.listeners[0].traddr' <<< "$listener")" \
    "the listener reports the address we gave it"
assert_eq "$GW_HOST" "$(json_get '.listeners[0].host_name' <<< "$listener")" \
    "the listener reports the gateway host name"
# adrfam is numeric on the wire: 0 is IPv4, 1 is IPv6.
assert_eq "0" "$(json_get '.listeners[0].adrfam' <<< "$listener")" \
    "adrfam defaults to IPv4 (0)"

assert_ok "listener add on a second port" \
    nvmeof_cmd listener add --nqn "$NQN" --host-name "$GW_HOST" \
        --traddr "$GW_ADDR" --trsvcid "$PORT2"
assert_eq "2" "$(listener_count)" "both listeners are there"

# ---------------------------------------------------------------------------
section "listener add: rejections"
# ---------------------------------------------------------------------------

assert_fails "listener add requires --host-name" \
    nvmeof_cmd listener add --nqn "$NQN" --traddr "$GW_ADDR" --trsvcid 4430

assert_fails "listener add requires --traddr" \
    nvmeof_cmd listener add --nqn "$NQN" --host-name "$GW_HOST" --trsvcid 4430

assert_fails "listener add rejects an unknown subsystem" \
    nvmeof_cmd listener add --nqn "$(suite_nqn never-created)" --host-name "$GW_HOST" \
        --traddr "$GW_ADDR" --trsvcid 4430

assert_fails "listener add rejects a duplicate address and port" \
    nvmeof_cmd listener add --nqn "$NQN" --host-name "$GW_HOST" \
        --traddr "$GW_ADDR" --trsvcid "$PORT1"

# --verify-host-name makes the mismatch between the named host and the
# gateway actually answering an error instead of a silent misconfiguration.
assert_fails "listener add with --verify-host-name rejects a foreign host name" \
    nvmeof_cmd listener add --nqn "$NQN" --host-name "not-this-gateway" \
        --traddr "$GW_ADDR" --trsvcid 4430 --verify-host-name=true

assert_eq "2" "$(listener_count)" "the rejected adds created nothing"

# ---------------------------------------------------------------------------
section "gateway listener_info and refresh_network"
# ---------------------------------------------------------------------------

assert_ok "gateway listener_info" nvmeof_cmd gateway listener_info --nqn "$NQN"
assert_contains "$(nvmeof_json gateway listener_info --nqn "$NQN")" "$GW_ADDR" \
    "listener_info mentions the listener address"

assert_ok "gw listener_info alias" nvmeof_cmd gw listener_info --nqn "$NQN"

assert_fails "gateway listener_info requires --nqn" \
    nvmeof_cmd gateway listener_info

# refresh_network re-evaluates the subsystem's network masks. This subsystem
# has none and only manual listeners, so the call has nothing to do -- it
# still has to succeed rather than error on the empty case.
assert_ok "gateway refresh_network" nvmeof_cmd gateway refresh_network --nqn "$NQN"
assert_eq "2" "$(listener_count)" "refresh_network left the manual listeners alone"

# ---------------------------------------------------------------------------
section "listener del"
# ---------------------------------------------------------------------------

assert_fails "listener del requires --trsvcid" \
    nvmeof_cmd listener del --nqn "$NQN" --host-name "$GW_HOST"

assert_fails "listener del rejects a port with no listener" \
    nvmeof_cmd listener del --nqn "$NQN" --host-name "$GW_HOST" --trsvcid 4999

assert_ok "listener del" \
    nvmeof_cmd listener del --nqn "$NQN" --host-name "$GW_HOST" --trsvcid "$PORT2"
assert_eq "1" "$(listener_count)" "one listener left"
assert_eq "0" "$(has_listener_on_port "$PORT2")" "the deleted listener is gone"
assert_eq "1" "$(has_listener_on_port "$PORT1")" "the other listener was left alone"

# Deleting a listener that initiators may be using needs --force; nothing is
# connected here, so it is simply accepted.
assert_ok "listener del --force" \
    nvmeof_cmd listener del --nqn "$NQN" --host-name "$GW_HOST" \
        --trsvcid "$PORT1" --force=true
assert_eq "0" "$(listener_count)" "no listeners left"
