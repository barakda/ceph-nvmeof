#!/bin/bash
#
# multi_gw/ha/010_nvme_gw.sh
#
#     ceph nvme-gw show <pool> <group>        ceph nvme-gw enable <id> <pool> <group>
#     ceph nvme-gw show-all                   ceph nvme-gw disable <id> <pool> <group>
#     ceph nvme-gw listeners <pool> <group>   ceph nvme-gw set-location <id> <pool> <group> <loc>
#     ceph nvme-gw ok-to-stop <pool> <group> [id] [disable-if-ok]
#     ceph nvme-gw disaster-set <pool> <group> <location>
#     ceph nvme-gw disaster-clear <pool> <group> <location>
#     ceph nvme-gw create / delete <id> <pool> <group>
#
# These live in the monitor, not the gateway, and their arguments are
# positional rather than flags. This suite needs two gateways: ok-to-stop is
# meaningless with one, and availability only becomes interesting once a
# second gateway can take over.
#
# `create` and `delete` are deliberately not exercised against the running
# gateways -- tests/ha/start_up.sh already created them, and deleting one
# would strand the gateway for every suite that follows in this shape. They
# are covered using an id that no gateway claims.
#
set -u -o pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=tests/gh_runner/lib/common.sh
source "$HERE/lib/common.sh"
# shellcheck source=tests/gh_runner/lib/cluster.sh
source "$HERE/lib/cluster.sh"

suite_begin "ha/010_nvme_gw"

GROUP=""
GW1=""
DISABLED_GW=""

suite_cleanup() {
    # Leave every gateway enabled, whatever happened above: the suites that
    # follow in this shape expect both of them serving.
    if [ -n "$DISABLED_GW" ]; then
        log "re-enabling gateway $DISABLED_GW"
        nvme_gw_cmd enable "$DISABLED_GW" "$RBD_POOL" "$GROUP" ||
            warn "could not re-enable gateway $DISABLED_GW"
    fi
    use_gateway 1
    suite_cleanup_subsystems
}
trap suite_exit EXIT

GROUP="$(gateway_group)"
mapfile -t CONTAINERS < <(gateway_containers)
GW1="${CONTAINERS[0]}"
GW2="${CONTAINERS[1]}"
log "gateways: $GW1, $GW2 in pool '$RBD_POOL' group '$GROUP'"

gw_count() {
    nvme_gw_cmd show "$RBD_POOL" "$GROUP" --format json |
        json_get '."Created Gateways:" | length'
}

gw_field() {
    nvme_gw_cmd show "$RBD_POOL" "$GROUP" --format json |
        json_get "[.\"Created Gateways:\"[] | select(.\"gw-id\" == \"$1\")] | first | .\"$2\""
}

# ---------------------------------------------------------------------------
section "ceph nvme-gw show / show-all"
# ---------------------------------------------------------------------------

assert_ok "nvme-gw show" nvme_gw_cmd show "$RBD_POOL" "$GROUP"
assert_ok "nvme-gw show-all" nvme_gw_cmd show-all

show="$(nvme_gw_cmd show "$RBD_POOL" "$GROUP")"
assert_contains "$show" "$GW1" "show lists the first gateway"
assert_contains "$show" "$GW2" "show lists the second gateway"

assert_eq "2" "$(gw_count)" "show reports exactly the two gateways we started"

# A running gateway is not yet an AVAILABLE one. update_gw_subsystems() in
# the monitor (src/mon/NVMeofGwMon.cc) forces the availability back to
# GW_CREATED for any gateway whose beacon reports no subsystems or no
# listeners, which is exactly what a gateway with nothing configured
# reports. So give each of them something to serve -- one subsystem, shared
# by the group, with a listener of its own on each gateway -- before asking
# the monitor whether they are available. `ok-to-stop` below needs the same
# thing: it refuses while the group has no available gateway to take over.
AVAIL_NQN="$(suite_nqn avail)"
assert_ok "subsystem add for the availability check" \
    nvmeof_cmd subsystem add --nqn "$AVAIL_NQN" --no-group-append

for i in 1 2; do
    use_gateway "$i"
    # The subsystem was created through gateway 1 and reaches the other one
    # through the OMAP, which is not instant.
    wait_until 60 nvmeof_cmd subsystem get --nqn "$AVAIL_NQN" ||
        warn "gateway $i does not report $AVAIL_NQN yet"
    assert_ok "listener add on gateway $i" \
        nvmeof_cmd listener add --nqn "$AVAIL_NQN" \
            --host-name "$(gateway_hostname "$NVMEOF_TARGET_CONTAINER")" \
            --traddr "$NVMEOF_TARGET_ADDRESS" --trsvcid "${NVMEOF_IO_PORT:-4420}"
done
use_gateway 1

# wait_gateways.sh only waits for the gateway to answer gRPC. The monitor
# learns a gateway is available from its beacons, which lag that, so poll
# rather than reading once.
for gw in "$GW1" "$GW2"; do
    avail=""
    for _ in $(seq 60); do
        avail="$(gw_field "$gw" "Availability")"
        [ "$avail" = "AVAILABLE" ] && break
        sleep 2
    done
    assert_eq "AVAILABLE" "$avail" "gateway $gw is AVAILABLE"
done

assert_ok "nvme-gw listeners" nvme_gw_cmd listeners "$RBD_POOL" "$GROUP"

# nvme-gw show never validates the pool. NVMeofGwMon::nvme_gw_show_command
# in the monitor builds the (pool, group) key and dumps whatever the gateway
# map holds for it; an unknown pool is simply a map with nothing in it, so
# the command succeeds and reports no gateways.
assert_ok "nvme-gw show on a pool that does not exist" \
    nvme_gw_cmd show no-such-pool "$GROUP"
assert_eq "0" "$(nvme_gw_cmd show no-such-pool "$GROUP" --format json |
    json_get '."num gws"')" \
    "nvme-gw show reports no gateways for a pool that does not exist"

# ---------------------------------------------------------------------------
section "ceph nvme-gw ok-to-stop"
# ---------------------------------------------------------------------------

# With two gateways available, stopping one has to be allowed.
# NVMeofGwMap::is_ok_to_stop() answers EBUSY while the group has no
# available gateway, or while as many are already down as
# mon_nvmeofgw_max_down_gws permits -- hence the AVAILABLE poll above, which
# is what makes this a question about HA rather than about a group that was
# never serving.
assert_ok "ok-to-stop for the group" nvme_gw_cmd ok-to-stop "$RBD_POOL" "$GROUP"
assert_ok "ok-to-stop for a named gateway" \
    nvme_gw_cmd ok-to-stop "$RBD_POOL" "$GROUP" "$GW1"

# ---------------------------------------------------------------------------
section "ceph nvme-gw disable / enable"
# ---------------------------------------------------------------------------

assert_eq "ENABLED" "$(gw_field "$GW2" "admin state")" "the gateway starts enabled"

assert_ok "nvme-gw disable" nvme_gw_cmd disable "$GW2" "$RBD_POOL" "$GROUP"
DISABLED_GW="$GW2"
assert_eq "DISABLED" "$(gw_field "$GW2" "admin state")" "show reports it as DISABLED"

assert_ok "nvme-gw enable" nvme_gw_cmd enable "$GW2" "$RBD_POOL" "$GROUP"
DISABLED_GW=""
assert_eq "ENABLED" "$(gw_field "$GW2" "admin state")" "show reports it as ENABLED again"

assert_fails "nvme-gw disable rejects an unknown gateway id" \
    nvme_gw_cmd disable gh-no-such-gateway "$RBD_POOL" "$GROUP"

assert_fails "nvme-gw enable rejects an unknown gateway id" \
    nvme_gw_cmd enable gh-no-such-gateway "$RBD_POOL" "$GROUP"

# ---------------------------------------------------------------------------
section "ceph nvme-gw set-location and the disaster commands"
# ---------------------------------------------------------------------------

LOCATION="gh-runner-dc1"

assert_ok "nvme-gw set-location" \
    nvme_gw_cmd set-location "$GW1" "$RBD_POOL" "$GROUP" "$LOCATION"
assert_eq "$LOCATION" "$(gw_field "$GW1" location)" "show reports the new location"

assert_ok "nvme-gw disaster-set" \
    nvme_gw_cmd disaster-set "$RBD_POOL" "$GROUP" "$LOCATION"
assert_ok "nvme-gw disaster-clear" \
    nvme_gw_cmd disaster-clear "$RBD_POOL" "$GROUP" "$LOCATION"

# Put the location back so the rest of the shape sees an unpinned gateway.
assert_ok "nvme-gw set-location back to empty" \
    nvme_gw_cmd set-location "$GW1" "$RBD_POOL" "$GROUP" ""

# ---------------------------------------------------------------------------
section "ceph nvme-gw create / delete"
# ---------------------------------------------------------------------------

# An id no real gateway will claim, so adding and removing it cannot disturb
# the two that the other suites depend on.
SPARE="gh-runner-spare-gw"

assert_ok "nvme-gw create" nvme_gw_cmd create "$SPARE" "$RBD_POOL" "$GROUP"
assert_eq "3" "$(gw_count)" "the spare gateway shows up"

# No daemon is behind it, so it can never become available.
assert_ne "AVAILABLE" "$(gw_field "$SPARE" "Availability")" \
    "a gateway with no daemon is not AVAILABLE"

assert_ok "nvme-gw delete" nvme_gw_cmd delete "$SPARE" "$RBD_POOL" "$GROUP"
assert_eq "2" "$(gw_count)" "the spare gateway is gone again"

assert_fails "nvme-gw create rejects a missing group argument" \
    nvme_gw_cmd create "$SPARE" "$RBD_POOL"
