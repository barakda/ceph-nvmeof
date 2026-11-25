#!/bin/bash
#
# secure/subsystem/020_kmip.sh
#
#     ceph nvmeof subsystem add_kmip_server_endpoint --nqn --server-name
#                                                    [--address] [--port]
#     ceph nvmeof subsystem del_kmip_server_endpoint --nqn --server-name
#                                                    [--address] [--port] [--force]
#     ceph nvmeof subsystem list_kmip_server_endpoints [--nqn] [--server-name]
#
# These only record where a KMIP server lives; nothing here contacts one, and
# no KMIP server runs on the runner. So this is about the endpoint
# bookkeeping -- defaults, duplicates, removal -- not about fetching keys.
#
set -u -o pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=tests/gh_runner/lib/common.sh
source "$HERE/lib/common.sh"
# shellcheck source=tests/gh_runner/lib/cluster.sh
source "$HERE/lib/cluster.sh"

suite_begin "subsystem/020_kmip"

suite_cleanup() {
    suite_cleanup_subsystems
}
trap suite_exit EXIT

NQN="$(suite_nqn kmip)"
SERVER_A="gh-kmip-a"
SERVER_B="gh-kmip-b"
ADDRESS="10.252.0.10"
DEFAULT_PORT=5696
ALT_PORT=5697

endpoint_count() {
    nvmeof_json subsystem list_kmip_server_endpoints --nqn "$NQN" |
        json_get '.endpoints | length'
}

has_endpoint() {
    nvmeof_json subsystem list_kmip_server_endpoints --nqn "$NQN" |
        json_get "[.endpoints[] | select(.server_name == \"$1\")] | length"
}

# ---------------------------------------------------------------------------
section "Setup"
# ---------------------------------------------------------------------------

assert_ok "subsystem add" nvmeof_cmd subsystem add --nqn "$NQN" --no-group-append

assert_ok "list_kmip_server_endpoints with none configured" \
    nvmeof_cmd subsystem list_kmip_server_endpoints --nqn "$NQN"
assert_eq "0" "$(endpoint_count)" "a new subsystem has no KMIP endpoints"

# ---------------------------------------------------------------------------
section "subsystem add_kmip_server_endpoint"
# ---------------------------------------------------------------------------

assert_ok "add_kmip_server_endpoint with an address" \
    nvmeof_cmd subsystem add_kmip_server_endpoint --nqn "$NQN" \
        --server-name "$SERVER_A" --address "$ADDRESS"

assert_eq "1" "$(has_endpoint "$SERVER_A")" "the endpoint was recorded"
assert_eq "$ADDRESS" "$(nvmeof_json subsystem list_kmip_server_endpoints --nqn "$NQN" |
    json_get "[.endpoints[] | select(.server_name == \"$SERVER_A\")] | first | .address")" \
    "the address was recorded"
assert_eq "$DEFAULT_PORT" "$(nvmeof_json subsystem list_kmip_server_endpoints --nqn "$NQN" |
    json_get "[.endpoints[] | select(.server_name == \"$SERVER_A\")] | first | .port")" \
    "the port defaults to $DEFAULT_PORT"

assert_ok "add_kmip_server_endpoint on a non-default port" \
    nvmeof_cmd subsystem add_kmip_server_endpoint --nqn "$NQN" \
        --server-name "$SERVER_B" --address "$ADDRESS" --port "$ALT_PORT"
assert_eq "$ALT_PORT" "$(nvmeof_json subsystem list_kmip_server_endpoints --nqn "$NQN" |
    json_get "[.endpoints[] | select(.server_name == \"$SERVER_B\")] | first | .port")" \
    "--port was applied"

assert_eq "2" "$(endpoint_count)" "both endpoints are recorded"

assert_fails "add_kmip_server_endpoint requires --server-name" \
    nvmeof_cmd subsystem add_kmip_server_endpoint --nqn "$NQN" --address "$ADDRESS"

assert_fails "add_kmip_server_endpoint rejects an unknown subsystem" \
    nvmeof_cmd subsystem add_kmip_server_endpoint --nqn "$(suite_nqn never-created)" \
        --server-name "$SERVER_A" --address "$ADDRESS"

# ---------------------------------------------------------------------------
section "subsystem list_kmip_server_endpoints: filters"
# ---------------------------------------------------------------------------

assert_eq "1" "$(nvmeof_json subsystem list_kmip_server_endpoints --nqn "$NQN" \
    --server-name "$SERVER_A" | json_get '.endpoints | length')" \
    "--server-name narrows to one endpoint"

# Without --nqn the listing covers every subsystem.
assert_ok "list_kmip_server_endpoints without --nqn" \
    nvmeof_cmd subsystem list_kmip_server_endpoints

# ---------------------------------------------------------------------------
section "subsystem del_kmip_server_endpoint"
# ---------------------------------------------------------------------------

assert_fails "del_kmip_server_endpoint requires --server-name" \
    nvmeof_cmd subsystem del_kmip_server_endpoint --nqn "$NQN"

assert_ok "del_kmip_server_endpoint" \
    nvmeof_cmd subsystem del_kmip_server_endpoint --nqn "$NQN" --server-name "$SERVER_B"
assert_eq "0" "$(has_endpoint "$SERVER_B")" "the endpoint is gone"
assert_eq "1" "$(has_endpoint "$SERVER_A")" "the other endpoint was left alone"

assert_ok "del_kmip_server_endpoint --force" \
    nvmeof_cmd subsystem del_kmip_server_endpoint --nqn "$NQN" \
        --server-name "$SERVER_A" --force=true
assert_eq "0" "$(endpoint_count)" "no endpoints left"
