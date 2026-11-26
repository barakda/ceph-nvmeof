#!/bin/bash
#
# single_gw/namespace/010_add_del.sh
#
#     ceph nvmeof namespace add --nqn --rbd-image-name [--rbd-pool]
#                               [--create-image] [--rbd-image-size] [--size]
#                               [--nsid] [--uuid] [--block-size]
#                               [--load-balancing-group] [--read-only] [--force]
#     ceph nvmeof namespace list [--nqn] [--nsid] [--uuid]
#     ceph nvmeof namespace get --nqn --nsid
#     ceph nvmeof namespace del --nqn --nsid [--force]
#
# `--create-image` makes the gateway create the RBD image, so the suite does
# not need to lay one down first. Deleting the namespace leaves that image
# behind, which is why suite_cleanup_images runs at the end.
#
set -u -o pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=tests/gh_runner/lib/common.sh
source "$HERE/lib/common.sh"
# shellcheck source=tests/gh_runner/lib/cluster.sh
source "$HERE/lib/cluster.sh"

suite_begin "namespace/010_add_del"

suite_cleanup() {
    suite_cleanup_subsystems
    suite_cleanup_images
}
trap suite_exit EXIT

NQN="$(suite_nqn ns)"
IMAGE1="$(suite_image 1)"
IMAGE2="$(suite_image 2)"
IMAGE3="$(suite_image 3)"

ns_field() {
    nvmeof_json namespace get --nqn "$NQN" --nsid "$1" | json_get ".namespaces[0].$2"
}

ns_count() {
    nvmeof_json namespace list --nqn "$NQN" | json_get '.namespaces | length'
}

# ---------------------------------------------------------------------------
section "Setup: a subsystem to hang namespaces off"
# ---------------------------------------------------------------------------

assert_ok "subsystem add" nvmeof_cmd subsystem add --nqn "$NQN" --no-group-append

# ---------------------------------------------------------------------------
section "namespace add: defaults"
# ---------------------------------------------------------------------------

assert_ok "namespace add with a created image" \
    nvmeof_cmd namespace add --nqn "$NQN" --rbd-image-name "$IMAGE1" \
        --create-image=true --rbd-image-size 10MB

# The gateway picks the nsid when none is given; everything below needs it.
NSID1="$(nvmeof_json namespace add --nqn "$NQN" --rbd-image-name "$IMAGE2" \
    --create-image=true --rbd-image-size 10MB | json_get '.nsid')"
log "second namespace got nsid $NSID1"
assert_ge "$NSID1" 1 "namespace add reports the nsid it assigned"

assert_eq "2" "$(ns_count)" "both namespaces are listed"

assert_ok "namespace get" nvmeof_cmd namespace get --nqn "$NQN" --nsid "$NSID1"
assert_eq "$IMAGE2" "$(ns_field "$NSID1" rbd_image_name)" \
    "namespace get returns the image we asked for"
assert_eq "$RBD_POOL" "$(ns_field "$NSID1" rbd_pool_name)" \
    "--rbd-pool defaults to $RBD_POOL"
assert_eq "512" "$(ns_field "$NSID1" block_size)" \
    "block size defaults to 512"
assert_eq "$NQN" "$(ns_field "$NSID1" ns_subsystem_nqn)" \
    "the namespace belongs to our subsystem"
assert_ne "" "$(ns_field "$NSID1" uuid)" "the gateway generated a uuid"
assert_ne "" "$(ns_field "$NSID1" bdev_name)" "the namespace has a bdev"

# 10MB was asked for; the gateway reports the image size in bytes.
assert_eq "10485760" "$(ns_field "$NSID1" rbd_image_size)" \
    "--rbd-image-size 10MB became 10485760 bytes"

# A namespace is visible to every host unless told otherwise.
assert_eq "true" \
    "$(nvmeof_json namespace get --nqn "$NQN" --nsid "$NSID1" |
        json_get 'if .namespaces[0].auto_visible then "true" else "false" end')" \
    "a new namespace is auto-visible"

# The subsystem's own view has to agree.
assert_eq "2" "$(nvmeof_json subsystem list --nqn "$NQN" |
    json_get '.subsystems[0].namespace_count')" \
    "subsystem list counts both namespaces"

# ---------------------------------------------------------------------------
section "namespace add: explicit options"
# ---------------------------------------------------------------------------

assert_ok "namespace add with an explicit nsid, block size and read-only" \
    nvmeof_cmd namespace add --nqn "$NQN" --rbd-image-name "$IMAGE3" \
        --create-image=true --rbd-image-size 10MB \
        --nsid 42 --block-size 4096 --read-only=true

assert_eq "42" "$(ns_field 42 nsid)" "--nsid was honoured"
assert_eq "4096" "$(ns_field 42 block_size)" "--block-size was applied"
assert_eq "true" "$(nvmeof_json namespace get --nqn "$NQN" --nsid 42 |
    json_get 'if .namespaces[0].read_only then "true" else "false" end')" \
    "--read-only was applied"

# ---------------------------------------------------------------------------
section "namespace list: filters"
# ---------------------------------------------------------------------------

assert_eq "1" "$(nvmeof_json namespace list --nqn "$NQN" --nsid 42 |
    json_get '.namespaces | length')" \
    "namespace list --nsid narrows to one namespace"

uuid42="$(ns_field 42 uuid)"
assert_eq "42" "$(nvmeof_json namespace list --nqn "$NQN" --uuid "$uuid42" |
    json_get '.namespaces[0].nsid')" \
    "namespace list --uuid finds it by uuid"

# ---------------------------------------------------------------------------
section "namespace add: rejections"
# ---------------------------------------------------------------------------

assert_fails "namespace add requires --rbd-image-name" \
    nvmeof_cmd namespace add --nqn "$NQN" --create-image=true --rbd-image-size 10MB

assert_fails "namespace add rejects an unknown subsystem" \
    nvmeof_cmd namespace add --nqn "$(suite_nqn never-created)" \
        --rbd-image-name "$(suite_image 99)" --create-image=true --rbd-image-size 10MB

assert_fails "namespace add rejects an nsid already in use" \
    nvmeof_cmd namespace add --nqn "$NQN" --rbd-image-name "$(suite_image 98)" \
        --create-image=true --rbd-image-size 10MB --nsid 42

# --size is the deprecated spelling of --rbd-image-size; the two together are
# refused rather than one silently winning.
assert_fails "namespace add rejects --size together with --rbd-image-size" \
    nvmeof_cmd namespace add --nqn "$NQN" --rbd-image-name "$(suite_image 97)" \
        --create-image=true --rbd-image-size 10MB --size 10MB

# Without --create-image there has to be an image already.
assert_fails "namespace add rejects a missing image when not creating one" \
    nvmeof_cmd namespace add --nqn "$NQN" --rbd-image-name "$(suite_image no-such)"

# Re-using an image that another namespace already owns needs --force.
assert_fails "namespace add rejects an image already used by another namespace" \
    nvmeof_cmd namespace add --nqn "$NQN" --rbd-image-name "$IMAGE1"

assert_eq "3" "$(ns_count)" "none of the rejected adds created a namespace"

# ---------------------------------------------------------------------------
section "namespace del"
# ---------------------------------------------------------------------------

assert_fails "namespace del requires --nsid" nvmeof_cmd namespace del --nqn "$NQN"

assert_fails "namespace del rejects an unknown nsid" \
    nvmeof_cmd namespace del --nqn "$NQN" --nsid 9999

assert_ok "namespace del removes a namespace" \
    nvmeof_cmd namespace del --nqn "$NQN" --nsid 42
assert_eq "2" "$(ns_count)" "the deleted namespace is gone from the list"

# `namespace get` is a filtered list_namespaces, not a lookup: list_namespaces
# in control/grpc.py skips every nsid that does not match and returns
# status 0 with an empty list, so a deleted nsid is an empty answer and exit
# 0 rather than an error. Assert on the answer, not on the exit code.
assert_ok "namespace get on the nsid that was just deleted" \
    nvmeof_cmd namespace get --nqn "$NQN" --nsid 42
assert_eq "0" "$(nvmeof_json namespace list --nqn "$NQN" |
    json_get '[.namespaces[] | select(.nsid == 42)] | length')" \
    "the nsid that was just deleted is gone"

# The image behind it stays, because nothing asked for it to be trashed.
assert_contains "$(rbd_cmd -p "$RBD_POOL" ls)" "$IMAGE3" \
    "deleting a namespace left its RBD image alone"

# A subsystem with namespaces will not go without --force.
assert_fails "subsystem del is refused while the subsystem has namespaces" \
    nvmeof_cmd subsystem del --nqn "$NQN"
assert_ok "subsystem del --force takes the namespaces with it" \
    nvmeof_cmd subsystem del --nqn "$NQN" --force true
