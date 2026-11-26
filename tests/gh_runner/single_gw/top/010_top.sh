#!/bin/bash
#
# single_gw/top/010_top.sh
#
#     ceph nvmeof top io [--nqn] [--sort-by] [--summary] [--no-header] ...
#     ceph nvmeof top cpu [--sort-by] [--no-header] ...
#     ceph nvmeof top connection --nqn --host-nqn [--sort-by] ...
#
# These are registered with poll=True, so the ceph client re-runs them every
# --period seconds (1 by default) and never returns on its own: the loop in
# ceph.in's do_command() only ends on an error, on Ctrl-C, or when the period
# is not positive. There is no --count or --once. So every call here goes
# through `timeout`, and the command being killed at the end of that window
# is the normal outcome -- top_cmd() below treats the resulting exit 124 as
# success and the checks read the frames the command printed before it was
# killed.
#
# --sort-by takes a column *title* rather than a field name, and the command
# validates it, so a wrong one is a clean rejection to test against.
#
set -u -o pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=tests/gh_runner/lib/common.sh
source "$HERE/lib/common.sh"
# shellcheck source=tests/gh_runner/lib/cluster.sh
source "$HERE/lib/cluster.sh"

suite_begin "top/010_top"

suite_cleanup() {
    suite_cleanup_subsystems
    suite_cleanup_images
}
trap suite_exit EXIT

NQN="$(suite_nqn top)"
HOST="nqn.2014-08.org.nvmexpress:uuid:$(uuidgen 2>/dev/null ||
    echo 11111111-2222-3333-4444-555555555555)"
# A few seconds is enough for several frames; the command is a stream, so
# the only thing a longer window buys is a longer suite.
TOP_TIMEOUT=5

#
# `ceph nvmeof top ...`, never allowed to run longer than TOP_TIMEOUT.
#
# `timeout` reports 124 when it had to kill the command, which for a poll
# command is what a healthy run looks like: it streamed until the window
# closed. Report that as success, so the checks below are about the output
# and the argument handling rather than about a command that was never going
# to exit by itself.
#
top_cmd() {
    local rc=0
    _ceph_exec timeout "$TOP_TIMEOUT" ceph nvmeof top "$@" \
        --server-address "$NVMEOF_TARGET_ADDRESS" || rc=$?
    [ "$rc" -eq 124 ] && rc=0
    return "$rc"
}

# ---------------------------------------------------------------------------
section "Setup"
# ---------------------------------------------------------------------------

assert_ok "subsystem add" nvmeof_cmd subsystem add --nqn "$NQN" --no-group-append
assert_ok "namespace add" \
    nvmeof_cmd namespace add --nqn "$NQN" --rbd-image-name "$(suite_image top)" \
        --create-image=true --rbd-image-size 10MB
assert_ok "host add" nvmeof_cmd host add --nqn "$NQN" --host-nqn "$HOST"

# ---------------------------------------------------------------------------
section "nvmeof top io"
# ---------------------------------------------------------------------------

assert_ok "top io" top_cmd io
assert_ok "top io --nqn" top_cmd io --nqn "$NQN"
assert_ok "top io --summary" top_cmd io --nqn "$NQN" --summary=true
assert_ok "top io --no-header" top_cmd io --nqn "$NQN" --no-header=true
assert_ok "top io --with-timestamp" top_cmd io --nqn "$NQN" --with-timestamp=true
assert_ok "top io --sort-by NSID" top_cmd io --nqn "$NQN" --sort-by NSID
assert_ok "top io --descending" top_cmd io --nqn "$NQN" --sort-by NSID --descending=true

# The namespace created above has to show up in the IO view.
assert_contains "$(top_cmd io --nqn "$NQN")" "$(suite_image top)" \
    "top io lists the namespace's image"

assert_fails "top io rejects a sort column that does not exist" \
    top_cmd io --nqn "$NQN" --sort-by NoSuchColumn

# ---------------------------------------------------------------------------
section "nvmeof top cpu"
# ---------------------------------------------------------------------------

assert_ok "top cpu" top_cmd cpu
assert_ok "top cpu --no-header" top_cmd cpu --no-header=true
assert_ok "top cpu --sort-by 'Thread Name'" top_cmd cpu --sort-by "Thread Name"
assert_ok "top cpu --descending" top_cmd cpu --descending=true

assert_fails "top cpu rejects a sort column that does not exist" \
    top_cmd cpu --sort-by NoSuchColumn

# ---------------------------------------------------------------------------
section "nvmeof top connection"
# ---------------------------------------------------------------------------

assert_ok "top connection" top_cmd connection --nqn "$NQN" --host-nqn "$HOST"
assert_ok "top connection --no-header" \
    top_cmd connection --nqn "$NQN" --host-nqn "$HOST" --no-header=true

# Both are checked by the command itself rather than by the argument parser,
# so the message is its own rather than ceph's "missing required parameter".
assert_fails "top connection requires --nqn" top_cmd connection --host-nqn "$HOST"
assert_fails "top connection requires --host-nqn" top_cmd connection --nqn "$NQN"

assert_fails "top connection rejects a sort column that does not exist" \
    top_cmd connection --nqn "$NQN" --host-nqn "$HOST" --sort-by NoSuchColumn
