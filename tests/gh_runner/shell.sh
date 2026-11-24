#
# tests/gh_runner/shell.sh -- get the suite helpers in an interactive shell.
#
# nvmeof_cmd and friends are shell functions, not programs, so they do not
# exist until something sources them. From the repository root, against a
# cluster that is already up:
#
#     source tests/gh_runner/shell.sh
#     nvmeof_cmd gateway info
#     nvmeof_cmd subsystem add --nqn nqn.2016-06.io.spdk:test1 --no-group-append
#     nvmeof_json subsystem list | json_get '.subsystems[].nqn'
#     nvme_gw_cmd show rbd ''
#
# Nothing here needs the helpers, though. Every one of them is a thin wrapper
# around a command you can type yourself -- see the hint printed at the end.
#
# shellcheck shell=bash

_gh_runner_shell_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

# shellcheck source=tests/gh_runner/lib/common.sh
source "$_gh_runner_shell_root/tests/gh_runner/lib/common.sh"
# shellcheck source=tests/gh_runner/lib/cluster.sh
source "$_gh_runner_shell_root/tests/gh_runner/lib/cluster.sh"

cd "$_gh_runner_shell_root" || return 1

if [ "$(gateway_containers | wc -l | tr -d ' ')" -eq 0 ]; then
    echo "⚠️  no nvmeof gateway container is running."
    echo "    start one with: ./tests/ha/start_up.sh 1 && ./tests/ha/wait_gateways.sh 1"
else
    use_gateway "${1:-1}"
    echo
    echo "Ready. Helpers: nvmeof_cmd  nvmeof_json  nvme_gw_cmd  ceph_cmd  json_get"
    echo
    echo "Each is a wrapper around a command you can also run directly:"
    echo
    echo "    docker compose exec -T ceph ceph nvmeof gateway info \\"
    echo "        --server-address $NVMEOF_TARGET_ADDRESS"
    echo
    echo "Or get a shell in the ceph container and drop the prefix entirely:"
    echo
    echo "    docker compose exec ceph bash"
    echo "    ceph nvmeof gateway info --server-address $NVMEOF_TARGET_ADDRESS"
    echo
    echo "Remember: boolean options take --flag=value, never --flag value."
fi

unset _gh_runner_shell_root
