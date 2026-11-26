#!/bin/bash
#
# single_gw/connection/010_list_stats.sh
#
#     ceph nvmeof connection list [--nqn]
#     ceph nvmeof connection get_io_statistics --nqn --host-nqn
#     ceph nvmeof connection reset_io_statistics --nqn --host-nqn
#     ceph nvmeof connection get_extended_io_statistics [--nqn] [--host-nqn]
#                                                       [--verbose-statistics-mode]
#     ceph nvmeof connection reset_extended_io_statistics [--nqn] [--host-nqn]
#
# No initiator is connected on the runner during this suite, so what is being
# checked is the shape of the answers and the argument handling, not traffic
# counters: an allowed host with no live connection, and the rejections. Real
# connections are the fio suite's territory.
#
set -u -o pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=tests/gh_runner/lib/common.sh
source "$HERE/lib/common.sh"
# shellcheck source=tests/gh_runner/lib/cluster.sh
source "$HERE/lib/cluster.sh"

suite_begin "connection/010_list_stats"

ORIGINAL_IO_STATS=""

suite_cleanup() {
    suite_cleanup_subsystems
    suite_cleanup_images
    if [ -n "$ORIGINAL_IO_STATS" ]; then
        log "restoring io stats mode '$ORIGINAL_IO_STATS'"
        nvmeof_cmd gateway set_io_stats_mode --enabled="$ORIGINAL_IO_STATS" ||
            warn "could not restore the gateway io stats mode"
    fi
}
trap suite_exit EXIT

NQN="$(suite_nqn conn)"
HOST="nqn.2014-08.org.nvmexpress:uuid:$(uuidgen 2>/dev/null ||
    echo 11111111-2222-3333-4444-555555555555)"

# ---------------------------------------------------------------------------
section "Setup: a subsystem with a namespace and an allowed host"
# ---------------------------------------------------------------------------

ORIGINAL_IO_STATS="$(nvmeof_json gateway info |
    json_get 'if .io_stats_enabled then "true" else "false" end')"
log "io stats mode on entry: $ORIGINAL_IO_STATS"

assert_ok "subsystem add" nvmeof_cmd subsystem add --nqn "$NQN" --no-group-append
assert_ok "namespace add" \
    nvmeof_cmd namespace add --nqn "$NQN" --rbd-image-name "$(suite_image conn)" \
        --create-image=true --rbd-image-size 10MB
assert_ok "host add" nvmeof_cmd host add --nqn "$NQN" --host-nqn "$HOST"

# The per-connection counters are only collected when the gateway is keeping
# IO statistics, so turn them on before asking for any.
assert_ok "enable gateway io statistics" \
    nvmeof_cmd gateway set_io_stats_mode --enabled=true

# ---------------------------------------------------------------------------
section "connection list"
# ---------------------------------------------------------------------------

assert_ok "connection list for the subsystem" nvmeof_cmd connection list --nqn "$NQN"

conns="$(nvmeof_json connection list --nqn "$NQN")"
assert_eq "0" "$(json_get '.status' <<< "$conns")" "connection list reports status 0"
assert_eq "array" "$(json_get '.connections | type' <<< "$conns")" \
    "connection list returns a connection list"

# The host is allowed but has never connected, so it is listed as not
# connected rather than left out.
assert_eq "1" \
    "$(json_get "[.connections[] | select(.nqn == \"$HOST\")] | length" <<< "$conns")" \
    "the allowed host appears in the connection list"
assert_eq "0" "$(json_get '[.connections[] | select(.connected)] | length' <<< "$conns")" \
    "nothing is actually connected"

# Without --nqn the command covers every subsystem on the gateway.
assert_ok "connection list without --nqn" nvmeof_cmd connection list

assert_fails "connection list rejects an unknown subsystem" \
    nvmeof_cmd connection list --nqn "$(suite_nqn never-created)"

# ---------------------------------------------------------------------------
section "connection get_io_statistics"
# ---------------------------------------------------------------------------

# Per-host counters only exist for a host that is actually connected:
# get_connection_io_statistics_common() in control/grpc.py calls
# is_host_connected() as soon as both --nqn and --host-nqn are given, and
# returns ENOTCONN when the host has no live qpair. This suite runs with no
# initiator on the runner by design (see the header), so the only env that
# would make the call succeed is a real `nvme connect`, which belongs to the
# qos/fio suite. The allowed-but-unconnected host is therefore a rejection to
# test against, not a success.
assert_fails "connection get_io_statistics for a host that is not connected" \
    nvmeof_cmd connection get_io_statistics --nqn "$NQN" --host-nqn "$HOST"

assert_fails "get_io_statistics requires --nqn" \
    nvmeof_cmd connection get_io_statistics --host-nqn "$HOST"
assert_fails "get_io_statistics requires --host-nqn" \
    nvmeof_cmd connection get_io_statistics --nqn "$NQN"

# Same is_host_connected() gate on the reset side.
assert_fails "connection reset_io_statistics for a host that is not connected" \
    nvmeof_cmd connection reset_io_statistics --nqn "$NQN" --host-nqn "$HOST"

assert_fails "reset_io_statistics requires --host-nqn" \
    nvmeof_cmd connection reset_io_statistics --nqn "$NQN"

# ---------------------------------------------------------------------------
section "connection get_extended_io_statistics"
# ---------------------------------------------------------------------------

# Both arguments are optional here, unlike the plain variant above.
assert_ok "connection get_extended_io_statistics for the subsystem" \
    nvmeof_cmd connection get_extended_io_statistics --nqn "$NQN"

# Naming a host brings the same is_host_connected() gate as the plain
# variant above, so with no initiator connected these two are rejections.
assert_fails "connection get_extended_io_statistics for a host that is not connected" \
    nvmeof_cmd connection get_extended_io_statistics --nqn "$NQN" --host-nqn "$HOST"

assert_ok "connection get_extended_io_statistics --verbose-statistics-mode" \
    nvmeof_cmd connection get_extended_io_statistics --nqn "$NQN" \
        --verbose-statistics-mode=true

assert_fails "connection reset_extended_io_statistics for a host that is not connected" \
    nvmeof_cmd connection reset_extended_io_statistics --nqn "$NQN" --host-nqn "$HOST"

assert_fails "get_extended_io_statistics rejects an unknown subsystem" \
    nvmeof_cmd connection get_extended_io_statistics --nqn "$(suite_nqn never-created)"
