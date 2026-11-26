#!/bin/bash
#
# single_gw/namespace/050_location_trash.sh
#
#     ceph nvmeof namespace change_location --nqn --nsid --location
#     ceph nvmeof namespace list_locations [--nqn] [--nsid] [--uuid]
#     ceph nvmeof namespace unpin --nqn --nsid
#     ceph nvmeof namespace set_rbd_trash_image --nqn --nsid --rbd-trash-image-on-delete
#
# A namespace's location pins it to a failure domain; unpin takes that back
# off. set_rbd_trash_image decides whether deleting the namespace also sends
# its RBD image to the trash, which this suite checks by deleting one of each
# and looking at `rbd ls` afterwards.
#
set -u -o pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=tests/gh_runner/lib/common.sh
source "$HERE/lib/common.sh"
# shellcheck source=tests/gh_runner/lib/cluster.sh
source "$HERE/lib/cluster.sh"

suite_begin "namespace/050_location_trash"

GW_LOCATION_SET=""

suite_cleanup() {
    # A gateway carrying a location makes get_ana_grp_list_per_location("")
    # empty, which would make every later `namespace add` without a location
    # fail for the suites that share this cluster. Put it back whatever
    # happened above.
    if [ -n "$GW_LOCATION_SET" ]; then
        log "clearing the location on gateway $GW_ID"
        nvme_gw_cmd set-location "$GW_ID" "$RBD_POOL" "$GW_GROUP" "" ||
            warn "could not clear the gateway location"
    fi
    suite_cleanup_subsystems
    suite_cleanup_images
}
trap suite_exit EXIT

NQN="$(suite_nqn ns)"
IMAGE_KEEP="$(suite_image keep)"
IMAGE_TRASH="$(suite_image trash)"
LOCATION="gh-runner-dc1"
GW_ID="$(gateway_hostname "$NVMEOF_TARGET_CONTAINER")"
GW_GROUP="$(gateway_group)"

gw_location() {
    nvme_gw_cmd show "$RBD_POOL" "$GW_GROUP" --format json |
        json_get "[.\"Created Gateways:\"[] | select(.\"gw-id\" == \"$GW_ID\")] |
            first | .location"
}

gw_has_location() {
    [ "$(gw_location)" = "$1" ]
}

ns_field() {
    nvmeof_json namespace get --nqn "$NQN" --nsid "$1" | json_get ".namespaces[0].$2"
}

ns_pinned() {
    nvmeof_json namespace get --nqn "$NQN" --nsid "$1" |
        json_get 'if .namespaces[0].pinned then "true" else "false" end'
}

# ---------------------------------------------------------------------------
section "Setup"
# ---------------------------------------------------------------------------

assert_ok "subsystem add" nvmeof_cmd subsystem add --nqn "$NQN" --no-group-append

NSID_KEEP="$(nvmeof_json namespace add --nqn "$NQN" --rbd-image-name "$IMAGE_KEEP" \
    --create-image=true --rbd-image-size 10MB | json_get '.nsid')"
NSID_TRASH="$(nvmeof_json namespace add --nqn "$NQN" --rbd-image-name "$IMAGE_TRASH" \
    --create-image=true --rbd-image-size 10MB --trash-image=true | json_get '.nsid')"

assert_ge "$NSID_KEEP" 1 "namespace that keeps its image created"
assert_ge "$NSID_TRASH" 1 "namespace that trashes its image created"

assert_eq "false" "$(nvmeof_json namespace get --nqn "$NQN" --nsid "$NSID_KEEP" |
    json_get 'if .namespaces[0].trash_image then "true" else "false" end')" \
    "trash_image is off by default"
assert_eq "true" "$(nvmeof_json namespace get --nqn "$NQN" --nsid "$NSID_TRASH" |
    json_get 'if .namespaces[0].trash_image then "true" else "false" end')" \
    "--trash-image was applied"

# ---------------------------------------------------------------------------
section "namespace change_location / list_locations / unpin"
# ---------------------------------------------------------------------------

# A location is not a free-form label: namespace_change_location_safe() in
# control/grpc.py asks ceph_utils.get_ana_grp_list_per_location() for the ANA
# groups whose gateway reports exactly this location, and rejects the request
# with ENODEV ("invalid location") when that list is empty. Nothing in the
# cluster setup gives a gateway a location, so the monitor has to be told
# first -- that is the monitor-side `ceph nvme-gw set-location`, not a
# gateway command. It is put back to empty at the end of this section.
assert_ok "nvme-gw set-location so the location exists" \
    nvme_gw_cmd set-location "$GW_ID" "$RBD_POOL" "$GW_GROUP" "$LOCATION"
GW_LOCATION_SET=1
if ! wait_until 30 gw_has_location "$LOCATION"; then
    warn "the monitor still does not report location '$LOCATION' for $GW_ID"
fi
assert_eq "$LOCATION" "$(gw_location)" "the gateway reports the new location"

assert_ok "namespace change_location" \
    nvmeof_cmd namespace change_location --nqn "$NQN" --nsid "$NSID_KEEP" \
        --location "$LOCATION"
assert_eq "$LOCATION" "$(ns_field "$NSID_KEEP" location)" "the location was set"

assert_ok "namespace list_locations" nvmeof_cmd namespace list_locations --nqn "$NQN"
assert_contains "$(nvmeof_json namespace list_locations --nqn "$NQN")" "$LOCATION" \
    "list_locations reports the location"

# A location does not pin a namespace. is_pinned() in control/grpc.py is
# anagrpid < 0, and a negative group id is only ever stored by the gateway's
# own persistent-ANA path; namespace_change_location_safe() never touches
# anagrpid. There is no `ceph nvmeof` command that pins, so unpin on a
# namespace that only has a location is a rejection, not a success.
assert_eq "false" "$(ns_pinned "$NSID_KEEP")" \
    "setting a location did not pin the namespace"

assert_fails "namespace unpin on a namespace that is not pinned" \
    nvmeof_cmd namespace unpin --nqn "$NQN" --nsid "$NSID_KEEP"
assert_eq "false" "$(ns_pinned "$NSID_KEEP")" "the namespace is still not pinned"

assert_fails "change_location requires --location" \
    nvmeof_cmd namespace change_location --nqn "$NQN" --nsid "$NSID_KEEP"

assert_fails "change_location rejects an unknown nsid" \
    nvmeof_cmd namespace change_location --nqn "$NQN" --nsid 9999 --location "$LOCATION"

assert_fails "unpin rejects an unknown nsid" \
    nvmeof_cmd namespace unpin --nqn "$NQN" --nsid 9999

# Put the gateway back to no location: while it carries one,
# get_ana_grp_list_per_location("") is empty and every `namespace add` that
# does not name a location is refused, which would break the suites that
# share this cluster.
assert_ok "nvme-gw set-location back to empty" \
    nvme_gw_cmd set-location "$GW_ID" "$RBD_POOL" "$GW_GROUP" ""
GW_LOCATION_SET=""

# ---------------------------------------------------------------------------
section "namespace set_rbd_trash_image"
# ---------------------------------------------------------------------------

assert_ok "set_rbd_trash_image on" \
    nvmeof_cmd namespace set_rbd_trash_image --nqn "$NQN" --nsid "$NSID_KEEP" \
        --rbd-trash-image-on-delete true
assert_eq "true" "$(nvmeof_json namespace get --nqn "$NQN" --nsid "$NSID_KEEP" |
    json_get 'if .namespaces[0].trash_image then "true" else "false" end')" \
    "the namespace will now trash its image"

assert_ok "set_rbd_trash_image off again" \
    nvmeof_cmd namespace set_rbd_trash_image --nqn "$NQN" --nsid "$NSID_KEEP" \
        --rbd-trash-image-on-delete false
assert_eq "false" "$(nvmeof_json namespace get --nqn "$NQN" --nsid "$NSID_KEEP" |
    json_get 'if .namespaces[0].trash_image then "true" else "false" end')" \
    "the namespace will keep its image"

assert_fails "set_rbd_trash_image requires its flag" \
    nvmeof_cmd namespace set_rbd_trash_image --nqn "$NQN" --nsid "$NSID_KEEP"

# ---------------------------------------------------------------------------
section "deleting: the image follows the setting"
# ---------------------------------------------------------------------------

assert_ok "delete the namespace that keeps its image" \
    nvmeof_cmd namespace del --nqn "$NQN" --nsid "$NSID_KEEP"
assert_contains "$(rbd_cmd -p "$RBD_POOL" ls)" "$IMAGE_KEEP" \
    "its RBD image is still there"

assert_ok "delete the namespace that trashes its image" \
    nvmeof_cmd namespace del --nqn "$NQN" --nsid "$NSID_TRASH" --force true
assert_not_contains "$(rbd_cmd -p "$RBD_POOL" ls)" "$IMAGE_TRASH" \
    "its RBD image was trashed"
