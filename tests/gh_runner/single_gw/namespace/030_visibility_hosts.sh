#!/bin/bash
#
# single_gw/namespace/030_visibility_hosts.sh
#
#     ceph nvmeof namespace add --no-auto-visible
#     ceph nvmeof namespace add_host --nqn --nsid --host-nqn [--force]
#     ceph nvmeof namespace del_host --nqn --nsid --host-nqn
#     ceph nvmeof namespace list_hosts [--nqn] [--nsid] [--uuid]
#     ceph nvmeof namespace change_visibility --nqn --nsid --auto-visible [--force]
#
# A namespace is either visible to every host that can reach the subsystem,
# or visible only to the hosts named on it. The two are mutually exclusive,
# so adding a host to an auto-visible namespace is refused, and the host list
# is what change_visibility has to clear on the way back.
#
set -u -o pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=tests/gh_runner/lib/common.sh
source "$HERE/lib/common.sh"
# shellcheck source=tests/gh_runner/lib/cluster.sh
source "$HERE/lib/cluster.sh"

suite_begin "namespace/030_visibility_hosts"

suite_cleanup() {
    suite_cleanup_subsystems
    suite_cleanup_images
}
trap suite_exit EXIT

NQN="$(suite_nqn ns)"
HOST_A="nqn.2014-08.org.nvmexpress:uuid:$(uuidgen 2>/dev/null ||
    echo 11111111-2222-3333-4444-555555555555)"
HOST_B="nqn.2014-08.org.nvmexpress:uuid:$(uuidgen 2>/dev/null ||
    echo 66666666-7777-8888-9999-aaaaaaaaaaaa)"

ns_auto_visible() {
    nvmeof_json namespace get --nqn "$NQN" --nsid "$1" |
        json_get 'if .namespaces[0].auto_visible then "true" else "false" end'
}

ns_host_count() {
    nvmeof_json namespace get --nqn "$NQN" --nsid "$1" |
        json_get '.namespaces[0].hosts | length'
}

ns_has_host() {
    nvmeof_json namespace get --nqn "$NQN" --nsid "$1" |
        json_get "[.namespaces[0].hosts[] | select(. == \"$2\")] | length"
}

# ---------------------------------------------------------------------------
section "Setup: one auto-visible namespace and one restricted"
# ---------------------------------------------------------------------------

assert_ok "subsystem add" nvmeof_cmd subsystem add --nqn "$NQN" --no-group-append

NSID_OPEN="$(nvmeof_json namespace add --nqn "$NQN" --rbd-image-name "$(suite_image open)" \
    --create-image=true --rbd-image-size 10MB | json_get '.nsid')"
NSID_REST="$(nvmeof_json namespace add --nqn "$NQN" --rbd-image-name "$(suite_image rest)" \
    --create-image=true --rbd-image-size 10MB --no-auto-visible=true | json_get '.nsid')"

assert_ge "$NSID_OPEN" 1 "auto-visible namespace created"
assert_ge "$NSID_REST" 1 "restricted namespace created"

assert_eq "true" "$(ns_auto_visible "$NSID_OPEN")" "the first is auto-visible"
assert_eq "false" "$(ns_auto_visible "$NSID_REST")" "--no-auto-visible was applied"
assert_eq "0" "$(ns_host_count "$NSID_REST")" "a restricted namespace starts with no hosts"

# ---------------------------------------------------------------------------
section "namespace add_host / list_hosts"
# ---------------------------------------------------------------------------

assert_ok "namespace add_host" \
    nvmeof_cmd namespace add_host --nqn "$NQN" --nsid "$NSID_REST" --host-nqn "$HOST_A"
assert_eq "1" "$(ns_has_host "$NSID_REST" "$HOST_A")" "the host is on the namespace"
assert_eq "1" "$(ns_host_count "$NSID_REST")" "exactly one host"

assert_ok "namespace add_host for a second host" \
    nvmeof_cmd namespace add_host --nqn "$NQN" --nsid "$NSID_REST" --host-nqn "$HOST_B"
assert_eq "2" "$(ns_host_count "$NSID_REST")" "both hosts are on the namespace"

assert_ok "namespace list_hosts" nvmeof_cmd namespace list_hosts --nqn "$NQN"
assert_contains "$(nvmeof_json namespace list_hosts --nqn "$NQN" --nsid "$NSID_REST")" \
    "$HOST_A" "list_hosts reports the host"

# An auto-visible namespace is already open to everyone, so naming a host on
# it is contradictory rather than redundant.
assert_fails "add_host is refused on an auto-visible namespace" \
    nvmeof_cmd namespace add_host --nqn "$NQN" --nsid "$NSID_OPEN" --host-nqn "$HOST_A"

assert_fails "add_host rejects a malformed host NQN" \
    nvmeof_cmd namespace add_host --nqn "$NQN" --nsid "$NSID_REST" --host-nqn "not-an-nqn"

assert_fails "add_host rejects an unknown nsid" \
    nvmeof_cmd namespace add_host --nqn "$NQN" --nsid 9999 --host-nqn "$HOST_A"

assert_eq "2" "$(ns_host_count "$NSID_REST")" "the rejected add_host calls changed nothing"

# ---------------------------------------------------------------------------
section "namespace del_host"
# ---------------------------------------------------------------------------

assert_ok "namespace del_host" \
    nvmeof_cmd namespace del_host --nqn "$NQN" --nsid "$NSID_REST" --host-nqn "$HOST_B"
assert_eq "0" "$(ns_has_host "$NSID_REST" "$HOST_B")" "the removed host is gone"
assert_eq "1" "$(ns_has_host "$NSID_REST" "$HOST_A")" "the other host was left alone"

assert_fails "del_host rejects an unknown nsid" \
    nvmeof_cmd namespace del_host --nqn "$NQN" --nsid 9999 --host-nqn "$HOST_A"

# ---------------------------------------------------------------------------
section "namespace change_visibility"
# ---------------------------------------------------------------------------

# Going from restricted to visible-to-all throws the host list away, so the
# gateway wants --force while hosts are still on it.
assert_fails "change_visibility to auto is refused while hosts are listed" \
    nvmeof_cmd namespace change_visibility --nqn "$NQN" --nsid "$NSID_REST" --auto-visible yes

assert_ok "change_visibility to auto with --force" \
    nvmeof_cmd namespace change_visibility --nqn "$NQN" --nsid "$NSID_REST" \
        --auto-visible yes --force=true
assert_eq "true" "$(ns_auto_visible "$NSID_REST")" "the namespace is now auto-visible"
assert_eq "0" "$(ns_host_count "$NSID_REST")" "its host list was cleared"

assert_ok "change_visibility back to restricted" \
    nvmeof_cmd namespace change_visibility --nqn "$NQN" --nsid "$NSID_REST" --auto-visible no
assert_eq "false" "$(ns_auto_visible "$NSID_REST")" "the namespace is restricted again"

assert_fails "change_visibility requires --auto-visible" \
    nvmeof_cmd namespace change_visibility --nqn "$NQN" --nsid "$NSID_REST"

assert_fails "change_visibility rejects a value that is not yes/no" \
    nvmeof_cmd namespace change_visibility --nqn "$NQN" --nsid "$NSID_REST" \
        --auto-visible perhaps
