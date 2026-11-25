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

suite_cleanup() {
    suite_cleanup_subsystems
    suite_cleanup_images
}
trap suite_exit EXIT

NQN="$(suite_nqn ns)"
IMAGE_KEEP="$(suite_image keep)"
IMAGE_TRASH="$(suite_image trash)"
LOCATION="gh-runner-dc1"

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

assert_ok "namespace change_location" \
    nvmeof_cmd namespace change_location --nqn "$NQN" --nsid "$NSID_KEEP" \
        --location "$LOCATION"
assert_eq "$LOCATION" "$(ns_field "$NSID_KEEP" location)" "the location was set"

assert_ok "namespace list_locations" nvmeof_cmd namespace list_locations --nqn "$NQN"
assert_contains "$(nvmeof_json namespace list_locations --nqn "$NQN")" "$LOCATION" \
    "list_locations reports the location"

# Giving a namespace a location pins it there.
assert_eq "true" "$(ns_pinned "$NSID_KEEP")" "setting a location pinned the namespace"

assert_ok "namespace unpin" nvmeof_cmd namespace unpin --nqn "$NQN" --nsid "$NSID_KEEP"
assert_eq "false" "$(ns_pinned "$NSID_KEEP")" "the namespace is no longer pinned"

assert_fails "change_location requires --location" \
    nvmeof_cmd namespace change_location --nqn "$NQN" --nsid "$NSID_KEEP"

assert_fails "change_location rejects an unknown nsid" \
    nvmeof_cmd namespace change_location --nqn "$NQN" --nsid 9999 --location "$LOCATION"

assert_fails "unpin rejects an unknown nsid" \
    nvmeof_cmd namespace unpin --nqn "$NQN" --nsid 9999

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
