#!/bin/bash
#
# single_gw/subsystem/020_network_masks.sh
#
#     ceph nvmeof subsystem add --network-mask <cidr> [--network-mask <cidr>]
#     ceph nvmeof subsystem add_network --nqn <nqn> --network-mask <cidr>
#     ceph nvmeof subsystem del_network --nqn <nqn> --network-mask <cidr>
#     ceph nvmeof subsystem set_use_group_config_network_masks
#                               --nqn <nqn> --use-group-config-network-masks <bool>
#
# A subsystem's network masks drive auto-listener creation: the gateway creates
# a listener for every local address inside a configured subnet. This suite is
# about the bookkeeping, so every mask it uses is a subnet no gateway NIC is
# on -- the compose network is 192.168.13.0/24 -- and no listener is created as
# a side effect. Auto-listeners proper belong to the listener suite.
#
# The gateway keeps the masks in a set, so their order is not stable; the
# checks are on membership and count, never on position.
#
set -u -o pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=tests/gh_runner/lib/common.sh
source "$HERE/lib/common.sh"
# shellcheck source=tests/gh_runner/lib/cluster.sh
source "$HERE/lib/cluster.sh"

suite_begin "subsystem/020_network_masks"

suite_cleanup() {
    suite_cleanup_subsystems
}
trap suite_exit EXIT

NQN="$(suite_nqn masks)"

# Subnets deliberately unrelated to the compose network (192.168.13.0/24).
MASK_A="10.253.1.0/24"
MASK_B="10.253.2.0/24"
MASK_C="10.253.3.0/24"

mask_count() {
    nvmeof_json subsystem get --nqn "$NQN" | json_get '.subsystems[0].network_mask | length'
}

has_mask() {
    nvmeof_json subsystem get --nqn "$NQN" |
        json_get "[.subsystems[0].network_mask[] | select(. == \"$1\")] | length"
}

uses_group_masks() {
    nvmeof_json subsystem get --nqn "$NQN" |
        json_get 'if .subsystems[0].use_group_config_network_masks then "true" else "false" end'
}

# ---------------------------------------------------------------------------
section "subsystem add --network-mask"
# ---------------------------------------------------------------------------

# --network-mask is a list argument: the ceph CLI builds the list from repeated
# occurrences of the flag, not from a comma separated value.
assert_ok "subsystem add with two network masks" \
    nvmeof_cmd subsystem add --nqn "$NQN" --no-group-append \
        --network-mask "$MASK_A" --network-mask "$MASK_B"

nvmeof_cmd subsystem get --nqn "$NQN"

assert_eq "2" "$(mask_count)" "both masks were stored"
assert_eq "1" "$(has_mask "$MASK_A")" "the first mask is present"
assert_eq "1" "$(has_mask "$MASK_B")" "the second mask is present"
assert_eq "false" "$(uses_group_masks)" \
    "use_group_config_network_masks defaults to false"

# ---------------------------------------------------------------------------
section "subsystem add_network"
# ---------------------------------------------------------------------------

assert_ok "add_network adds a third mask" \
    nvmeof_cmd subsystem add_network --nqn "$NQN" --network-mask "$MASK_C"
assert_eq "3" "$(mask_count)" "the third mask was stored"
assert_eq "1" "$(has_mask "$MASK_C")" "the third mask is present"

# Re-adding is accepted and warns rather than failing, and must not duplicate
# the entry.
assert_ok "add_network accepts a mask that is already configured" \
    nvmeof_cmd subsystem add_network --nqn "$NQN" --network-mask "$MASK_C"
assert_eq "3" "$(mask_count)" "re-adding a mask did not duplicate it"

assert_fails "add_network rejects a subnet that is not a subnet" \
    nvmeof_cmd subsystem add_network --nqn "$NQN" --network-mask "not-a-subnet"

assert_fails "add_network rejects an unknown subsystem" \
    nvmeof_cmd subsystem add_network --nqn "$(suite_nqn never-created)" \
        --network-mask "$MASK_A"

assert_fails "add_network requires --network-mask" \
    nvmeof_cmd subsystem add_network --nqn "$NQN"

assert_eq "3" "$(mask_count)" "the rejected add_network calls changed nothing"

# ---------------------------------------------------------------------------
section "subsystem del_network"
# ---------------------------------------------------------------------------

assert_ok "del_network removes a mask" \
    nvmeof_cmd subsystem del_network --nqn "$NQN" --network-mask "$MASK_B"
assert_eq "2" "$(mask_count)" "the mask count dropped"
assert_eq "0" "$(has_mask "$MASK_B")" "the removed mask is gone"
assert_eq "1" "$(has_mask "$MASK_A")" "the other masks were left alone"

# Removing something that is not configured warns rather than failing.
assert_ok "del_network accepts a mask that is not configured" \
    nvmeof_cmd subsystem del_network --nqn "$NQN" --network-mask "$MASK_B"
assert_eq "2" "$(mask_count)" "the no-op del_network changed nothing"

assert_fails "del_network rejects a subnet that is not a subnet" \
    nvmeof_cmd subsystem del_network --nqn "$NQN" --network-mask "not-a-subnet"

assert_fails "del_network rejects an unknown subsystem" \
    nvmeof_cmd subsystem del_network --nqn "$(suite_nqn never-created)" \
        --network-mask "$MASK_A"

# ---------------------------------------------------------------------------
section "subsystem set_use_group_config_network_masks"
# ---------------------------------------------------------------------------

# Explicit masks and the group config masks are mutually exclusive, and the
# gateway enforces that on the way in: set_subsystem_use_group_config_network
# _masks_safe() in control/grpc.py returns EINVAL ("already has an explicit
# network mask configured, delete it first") while the subsystem still holds
# any mask of its own. The sections above leave MASK_A and MASK_C on it, so
# clear both before turning the flag on -- without this the flag is never
# set and the two refusal checks below find nothing to refuse.
assert_ok "clear the explicit masks before enabling the group config masks" \
    nvmeof_cmd subsystem del_network --nqn "$NQN" --network-mask "$MASK_A"
assert_ok "clear the last explicit mask" \
    nvmeof_cmd subsystem del_network --nqn "$NQN" --network-mask "$MASK_C"
assert_eq "0" "$(mask_count)" "the subsystem has no explicit masks left"

assert_ok "turn on the group config network masks" \
    nvmeof_cmd subsystem set_use_group_config_network_masks \
        --nqn "$NQN" --use-group-config-network-masks=true
assert_eq "true" "$(uses_group_masks)" "the subsystem now uses the group config masks"

# The two are mutually exclusive: while the subsystem follows the group config,
# its own mask list is not open for editing.
assert_fails "add_network is refused while the group config masks are in use" \
    nvmeof_cmd subsystem add_network --nqn "$NQN" --network-mask "$MASK_B"
assert_fails "del_network is refused while the group config masks are in use" \
    nvmeof_cmd subsystem del_network --nqn "$NQN" --network-mask "$MASK_A"

assert_ok "turn the group config network masks back off" \
    nvmeof_cmd subsystem set_use_group_config_network_masks \
        --nqn "$NQN" --use-group-config-network-masks=false
assert_eq "false" "$(uses_group_masks)" "the subsystem no longer uses the group config masks"

assert_ok "add_network works again once the group config masks are off" \
    nvmeof_cmd subsystem add_network --nqn "$NQN" --network-mask "$MASK_B"
assert_eq "1" "$(has_mask "$MASK_B")" "the mask was added after turning group config off"

assert_fails "set_use_group_config_network_masks requires its flag" \
    nvmeof_cmd subsystem set_use_group_config_network_masks --nqn "$NQN"

assert_fails "set_use_group_config_network_masks rejects an unknown subsystem" \
    nvmeof_cmd subsystem set_use_group_config_network_masks \
        --nqn "$(suite_nqn never-created)" --use-group-config-network-masks=true

# ---------------------------------------------------------------------------
section "subsystem add --use-group-config-network-masks"
# ---------------------------------------------------------------------------

GROUP_NQN="$(suite_nqn group-masks)"
assert_ok "subsystem add --use-group-config-network-masks" \
    nvmeof_cmd subsystem add --nqn "$GROUP_NQN" --no-group-append \
        --use-group-config-network-masks=true
assert_eq "true" \
    "$(nvmeof_json subsystem get --nqn "$GROUP_NQN" |
        json_get 'if .subsystems[0].use_group_config_network_masks then "true" else "false" end')" \
    "the subsystem was created following the group config masks"
