#!/bin/bash
#
# single_gw/namespace/040_qos_stats.sh
#
#     ceph nvmeof namespace set_qos --nqn --nsid [--rw-ios-per-second]
#                   [--rw-mbytes-per-second] [--r-mbytes-per-second]
#                   [--w-mbytes-per-second] [--force]
#     ceph nvmeof namespace get_io_stats --nqn --nsid
#     ceph nvmeof namespace update --nqn --nsid [--rbd-image-size]
#                   [--load-balancing-group] [--rw-ios-per-second] ... [--location]
#
# The QOS limits are read back through `namespace get`, which reports all four
# on every namespace. `namespace update` is the omnibus setter -- the same
# limits plus size and location in one call -- so it is checked here against
# the dedicated commands.
#
set -u -o pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=tests/gh_runner/lib/common.sh
source "$HERE/lib/common.sh"
# shellcheck source=tests/gh_runner/lib/cluster.sh
source "$HERE/lib/cluster.sh"

suite_begin "namespace/040_qos_stats"

suite_cleanup() {
    suite_cleanup_subsystems
    suite_cleanup_images
}
trap suite_exit EXIT

NQN="$(suite_nqn ns)"

ns_field() {
    nvmeof_json namespace get --nqn "$NQN" --nsid "$1" | json_get ".namespaces[0].$2"
}

# ---------------------------------------------------------------------------
section "Setup"
# ---------------------------------------------------------------------------

assert_ok "subsystem add" nvmeof_cmd subsystem add --nqn "$NQN" --no-group-append
NSID="$(nvmeof_json namespace add --nqn "$NQN" --rbd-image-name "$(suite_image qos)" \
    --create-image=true --rbd-image-size 20MB | json_get '.nsid')"
assert_ge "$NSID" 1 "namespace created"

# QOS is off until something sets it.
assert_eq "0" "$(ns_field "$NSID" rw_ios_per_second)" "no IOPS limit to begin with"
assert_eq "0" "$(ns_field "$NSID" rw_mbytes_per_second)" "no R/W bandwidth limit to begin with"

# ---------------------------------------------------------------------------
section "namespace set_qos"
# ---------------------------------------------------------------------------

assert_ok "set_qos with an IOPS limit" \
    nvmeof_cmd namespace set_qos --nqn "$NQN" --nsid "$NSID" --rw-ios-per-second 2000
assert_eq "2000" "$(ns_field "$NSID" rw_ios_per_second)" "the IOPS limit was applied"

assert_ok "set_qos with every bandwidth limit" \
    nvmeof_cmd namespace set_qos --nqn "$NQN" --nsid "$NSID" \
        --rw-mbytes-per-second 100 \
        --r-mbytes-per-second 50 \
        --w-mbytes-per-second 30
assert_eq "100" "$(ns_field "$NSID" rw_mbytes_per_second)" "the R/W limit was applied"
assert_eq "50" "$(ns_field "$NSID" r_mbytes_per_second)" "the read limit was applied"
assert_eq "30" "$(ns_field "$NSID" w_mbytes_per_second)" "the write limit was applied"

# Setting one limit must not quietly reset the others.
assert_eq "2000" "$(ns_field "$NSID" rw_ios_per_second)" \
    "the IOPS limit survived the bandwidth call"

# 0 is how a limit is lifted, not an invalid value.
assert_ok "set_qos with 0 lifts a limit" \
    nvmeof_cmd namespace set_qos --nqn "$NQN" --nsid "$NSID" --rw-ios-per-second 0
assert_eq "0" "$(ns_field "$NSID" rw_ios_per_second)" "the IOPS limit was lifted"

assert_fails "set_qos rejects an unknown nsid" \
    nvmeof_cmd namespace set_qos --nqn "$NQN" --nsid 9999 --rw-ios-per-second 100

assert_fails "set_qos rejects a non-numeric limit" \
    nvmeof_cmd namespace set_qos --nqn "$NQN" --nsid "$NSID" --rw-ios-per-second lots

# ---------------------------------------------------------------------------
section "namespace get_io_stats"
# ---------------------------------------------------------------------------

assert_ok "namespace get_io_stats" \
    nvmeof_cmd namespace get_io_stats --nqn "$NQN" --nsid "$NSID"

stats="$(nvmeof_json namespace get_io_stats --nqn "$NQN" --nsid "$NSID")"
assert_eq "$NQN" "$(json_get '.subsystem_nqn' <<< "$stats")" \
    "get_io_stats names the subsystem"
assert_eq "$NSID" "$(json_get '.nsid' <<< "$stats")" "get_io_stats names the namespace"
assert_ne "null" "$(json_get '.bytes_read' <<< "$stats")" "get_io_stats reports bytes read"
assert_ne "null" "$(json_get '.num_write_ops' <<< "$stats")" \
    "get_io_stats reports write op count"

assert_fails "get_io_stats rejects an unknown nsid" \
    nvmeof_cmd namespace get_io_stats --nqn "$NQN" --nsid 9999

# ---------------------------------------------------------------------------
section "namespace update"
# ---------------------------------------------------------------------------

assert_ok "namespace update sets the QOS limits" \
    nvmeof_cmd namespace update --nqn "$NQN" --nsid "$NSID" \
        --rw-ios-per-second 3000 --rw-mbytes-per-second 200
assert_eq "3000" "$(ns_field "$NSID" rw_ios_per_second)" "update applied the IOPS limit"
assert_eq "200" "$(ns_field "$NSID" rw_mbytes_per_second)" "update applied the R/W limit"

assert_ok "namespace update grows the image" \
    nvmeof_cmd namespace update --nqn "$NQN" --nsid "$NSID" --rbd-image-size 30MB
assert_eq "31457280" "$(ns_field "$NSID" rbd_image_size)" "update resized the namespace"

assert_fails "namespace update rejects an unknown nsid" \
    nvmeof_cmd namespace update --nqn "$NQN" --nsid 9999 --rw-ios-per-second 10
