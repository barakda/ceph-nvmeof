#!/bin/bash
#
# single_gw/namespace/020_resize.sh
#
#     ceph nvmeof namespace resize --nqn --nsid --rbd-image-size
#     ceph nvmeof namespace refresh_size --nqn --nsid
#     ceph nvmeof namespace set_auto_resize --nqn --nsid --auto-resize-enabled=<bool>
#     ceph nvmeof namespace add --disable-auto-resize
#
# resize grows the RBD image and the namespace together. refresh_size is the
# other direction: the image was grown behind the gateway's back (here, with
# `rbd resize`) and the namespace has to be told to catch up. Which of the two
# a namespace needs is what --disable-auto-resize decides.
#
set -u -o pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=tests/gh_runner/lib/common.sh
source "$HERE/lib/common.sh"
# shellcheck source=tests/gh_runner/lib/cluster.sh
source "$HERE/lib/cluster.sh"

suite_begin "namespace/020_resize"

suite_cleanup() {
    suite_cleanup_subsystems
    suite_cleanup_images
}
trap suite_exit EXIT

NQN="$(suite_nqn ns)"
IMAGE="$(suite_image auto)"
IMAGE_MANUAL="$(suite_image manual)"

ns_size() {
    nvmeof_json namespace get --nqn "$NQN" --nsid "$1" | json_get '.namespaces[0].rbd_image_size'
}

ns_auto_resize_disabled() {
    nvmeof_json namespace get --nqn "$NQN" --nsid "$1" |
        json_get 'if .namespaces[0].disable_auto_resize then "true" else "false" end'
}

# ---------------------------------------------------------------------------
section "Setup"
# ---------------------------------------------------------------------------

assert_ok "subsystem add" nvmeof_cmd subsystem add --nqn "$NQN" --no-group-append

NSID_AUTO="$(nvmeof_json namespace add --nqn "$NQN" --rbd-image-name "$IMAGE" \
    --create-image=true --rbd-image-size 10MB | json_get '.nsid')"
assert_ge "$NSID_AUTO" 1 "namespace with auto resize created"

NSID_MANUAL="$(nvmeof_json namespace add --nqn "$NQN" --rbd-image-name "$IMAGE_MANUAL" \
    --create-image=true --rbd-image-size 10MB --disable-auto-resize=true | json_get '.nsid')"
assert_ge "$NSID_MANUAL" 1 "namespace with auto resize disabled created"

assert_eq "false" "$(ns_auto_resize_disabled "$NSID_AUTO")" \
    "auto resize is on by default"
assert_eq "true" "$(ns_auto_resize_disabled "$NSID_MANUAL")" \
    "--disable-auto-resize was applied"

# ---------------------------------------------------------------------------
section "namespace resize"
# ---------------------------------------------------------------------------

assert_eq "10485760" "$(ns_size "$NSID_AUTO")" "starts at 10MB"

assert_ok "namespace resize to 20MB" \
    nvmeof_cmd namespace resize --nqn "$NQN" --nsid "$NSID_AUTO" --rbd-image-size 20MB
assert_eq "20971520" "$(ns_size "$NSID_AUTO")" "the namespace reports the new size"

# The resize has to have reached the image itself, not just the gateway's
# bookkeeping.
assert_eq "20971520" \
    "$(rbd_cmd -p "$RBD_POOL" info "$IMAGE" --format json | json_get '.size')" \
    "the RBD image was grown too"

assert_fails "namespace resize requires --rbd-image-size" \
    nvmeof_cmd namespace resize --nqn "$NQN" --nsid "$NSID_AUTO"

# NVMe namespaces cannot shrink.
assert_fails "namespace resize refuses to shrink" \
    nvmeof_cmd namespace resize --nqn "$NQN" --nsid "$NSID_AUTO" --rbd-image-size 5MB

assert_fails "namespace resize rejects an unknown nsid" \
    nvmeof_cmd namespace resize --nqn "$NQN" --nsid 9999 --rbd-image-size 30MB

assert_eq "20971520" "$(ns_size "$NSID_AUTO")" "the rejected resizes changed nothing"

# ---------------------------------------------------------------------------
section "namespace refresh_size"
# ---------------------------------------------------------------------------

# Grow the image behind the gateway's back, so the namespace is stale.
assert_ok "grow the image with rbd, bypassing the gateway" \
    rbd_cmd -p "$RBD_POOL" resize --size 40M "$IMAGE_MANUAL"

assert_ok "namespace refresh_size picks the new size up" \
    nvmeof_cmd namespace refresh_size --nqn "$NQN" --nsid "$NSID_MANUAL"
assert_eq "41943040" "$(ns_size "$NSID_MANUAL")" \
    "the namespace caught up with the image"

assert_fails "namespace refresh_size rejects an unknown nsid" \
    nvmeof_cmd namespace refresh_size --nqn "$NQN" --nsid 9999

# ---------------------------------------------------------------------------
section "namespace set_auto_resize"
# ---------------------------------------------------------------------------

assert_ok "turn auto resize off" \
    nvmeof_cmd namespace set_auto_resize --nqn "$NQN" --nsid "$NSID_AUTO" \
        --auto-resize-enabled=false
assert_eq "true" "$(ns_auto_resize_disabled "$NSID_AUTO")" "auto resize is now disabled"

assert_ok "turn auto resize back on" \
    nvmeof_cmd namespace set_auto_resize --nqn "$NQN" --nsid "$NSID_AUTO" \
        --auto-resize-enabled=true
assert_eq "false" "$(ns_auto_resize_disabled "$NSID_AUTO")" "auto resize is enabled again"

assert_fails "set_auto_resize requires --auto-resize-enabled" \
    nvmeof_cmd namespace set_auto_resize --nqn "$NQN" --nsid "$NSID_AUTO"

assert_fails "set_auto_resize rejects an unknown nsid" \
    nvmeof_cmd namespace set_auto_resize --nqn "$NQN" --nsid 9999 --auto-resize-enabled=true
