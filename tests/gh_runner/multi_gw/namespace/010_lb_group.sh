#!/bin/bash
#
# multi_gw/namespace/010_lb_group.sh
#
#     ceph nvmeof namespace add --load-balancing-group
#     ceph nvmeof namespace change_load_balancing_group --nqn --nsid
#                                                       --load-balancing-group
#
# A load balancing group is an ANA group, and each one is owned by a gateway.
# With a single gateway every group resolves to the same place and moving a
# namespace between them proves nothing, which is why this is the multi_gw
# shape: here group 1 and group 2 are owned by different gateways, so the
# move is a real change of owner.
#
set -u -o pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=tests/gh_runner/lib/common.sh
source "$HERE/lib/common.sh"
# shellcheck source=tests/gh_runner/lib/cluster.sh
source "$HERE/lib/cluster.sh"

suite_begin "namespace/010_lb_group"

suite_cleanup() {
    suite_cleanup_subsystems
    suite_cleanup_images
}
trap suite_exit EXIT

NQN="$(suite_nqn lb)"

ns_lb_group() {
    nvmeof_json namespace get --nqn "$NQN" --nsid "$1" |
        json_get '.namespaces[0].load_balancing_group'
}

# ---------------------------------------------------------------------------
section "Setup"
# ---------------------------------------------------------------------------

require_gateways 2

assert_ok "subsystem add" nvmeof_cmd subsystem add --nqn "$NQN" --no-group-append

# ---------------------------------------------------------------------------
section "namespace add --load-balancing-group"
# ---------------------------------------------------------------------------

NSID1="$(nvmeof_json namespace add --nqn "$NQN" --rbd-image-name "$(suite_image lb1)" \
    --create-image=true --rbd-image-size 10MB --load-balancing-group 1 | json_get '.nsid')"
assert_ge "$NSID1" 1 "namespace in group 1 created"
assert_eq "1" "$(ns_lb_group "$NSID1")" "--load-balancing-group 1 was applied"

NSID2="$(nvmeof_json namespace add --nqn "$NQN" --rbd-image-name "$(suite_image lb2)" \
    --create-image=true --rbd-image-size 10MB --load-balancing-group 2 | json_get '.nsid')"
assert_ge "$NSID2" 1 "namespace in group 2 created"
assert_eq "2" "$(ns_lb_group "$NSID2")" "--load-balancing-group 2 was applied"

# Left to itself the gateway spreads namespaces over the groups rather than
# piling them all into one.
NSID3="$(nvmeof_json namespace add --nqn "$NQN" --rbd-image-name "$(suite_image lb3)" \
    --create-image=true --rbd-image-size 10MB | json_get '.nsid')"
assert_ge "$(ns_lb_group "$NSID3")" 1 "an unasked-for namespace still lands in a group"

# ---------------------------------------------------------------------------
section "namespace change_load_balancing_group"
# ---------------------------------------------------------------------------

assert_ok "move the namespace to group 2" \
    nvmeof_cmd namespace change_load_balancing_group --nqn "$NQN" --nsid "$NSID1" \
        --load-balancing-group 2
assert_eq "2" "$(ns_lb_group "$NSID1")" "the namespace reports its new group"

assert_ok "move it back to group 1" \
    nvmeof_cmd namespace change_load_balancing_group --nqn "$NQN" --nsid "$NSID1" \
        --load-balancing-group 1
assert_eq "1" "$(ns_lb_group "$NSID1")" "the namespace is back in group 1"

# Moving to the group it is already in is accepted rather than refused.
assert_ok "move to the group it is already in" \
    nvmeof_cmd namespace change_load_balancing_group --nqn "$NQN" --nsid "$NSID1" \
        --load-balancing-group 1
assert_eq "1" "$(ns_lb_group "$NSID1")" "still group 1"

assert_fails "change_load_balancing_group rejects an unknown nsid" \
    nvmeof_cmd namespace change_load_balancing_group --nqn "$NQN" --nsid 9999 \
        --load-balancing-group 1

# There are only as many groups as the gateway advertises; a wildly out of
# range one has to be refused rather than silently clamped.
assert_fails "change_load_balancing_group rejects an out of range group" \
    nvmeof_cmd namespace change_load_balancing_group --nqn "$NQN" --nsid "$NSID1" \
        --load-balancing-group 9999
assert_eq "1" "$(ns_lb_group "$NSID1")" "the rejected move changed nothing"

# ---------------------------------------------------------------------------
section "both gateways agree on the namespaces"
# ---------------------------------------------------------------------------

# The namespaces were created through gateway 1. Gateway 2 shares the same
# OMAP state, so it has to report the same three.
count_gw1="$(nvmeof_json namespace list --nqn "$NQN" | json_get '.namespaces | length')"

use_gateway 2
count_gw2="$(nvmeof_json namespace list --nqn "$NQN" | json_get '.namespaces | length')"
assert_eq "$count_gw1" "$count_gw2" "both gateways report the same namespace count"
assert_eq "1" "$(ns_lb_group "$NSID1")" "gateway 2 agrees on the load balancing group"

# Back to gateway 1 so the cleanup and any later suite start where they expect.
use_gateway 1
