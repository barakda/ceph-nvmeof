#!/bin/bash
#
# secure/subsystem/010_dhchap_keys.sh
#
#     ceph nvmeof subsystem add --dhchap-key
#     ceph nvmeof subsystem change_key --nqn --dhchap-key
#     ceph nvmeof subsystem del_key --nqn
#
# The subsystem-level DH-HMAC-CHAP key, which is what a host authenticates
# the *target* with. Per-host keys are host/010_dhchap_psk.sh.
#
# The gateway never gives a key back, so has_dhchap_key on the subsystem is
# the only thing to assert against -- which is the point: a check that read
# the key back would be a check that the key had leaked.
#
set -u -o pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=tests/gh_runner/lib/common.sh
source "$HERE/lib/common.sh"
# shellcheck source=tests/gh_runner/lib/cluster.sh
source "$HERE/lib/cluster.sh"

suite_begin "subsystem/010_dhchap_keys"

suite_cleanup() {
    suite_cleanup_subsystems
}
trap suite_exit EXIT

PLAIN_NQN="$(suite_nqn plain)"
KEYED_NQN="$(suite_nqn keyed)"

# Valid DHHC-1 keys, same shape as the ones tests/test_dhchap.py uses.
KEY1="DHHC-1:00:MWPqcx1Ug1debg8fPIGpkqbQhLcYUt39k7UWirkblaKEH1kE:"
KEY2="DHHC-1:01:Ei7kUrD7iyrjzXDwIZ666sSPBswUk4wDjSQtodytVB5YiBru:"
BAD_KEY="DHHC-1:09:notarealkeyatall:"

has_key() {
    nvmeof_json subsystem get --nqn "$1" |
        json_get 'if .subsystems[0].has_dhchap_key then "true" else "false" end'
}

# ---------------------------------------------------------------------------
section "subsystem add --dhchap-key"
# ---------------------------------------------------------------------------

assert_ok "subsystem add without a key" \
    nvmeof_cmd subsystem add --nqn "$PLAIN_NQN" --no-group-append
assert_eq "false" "$(has_key "$PLAIN_NQN")" "it has no DH-HMAC-CHAP key"

assert_ok "subsystem add with a key" \
    nvmeof_cmd subsystem add --nqn "$KEYED_NQN" --no-group-append --dhchap-key "$KEY1"
assert_eq "true" "$(has_key "$KEYED_NQN")" "it has a DH-HMAC-CHAP key"

# The key itself must not come back out of the gateway.
assert_not_contains "$(nvmeof_json subsystem get --nqn "$KEYED_NQN")" "$KEY1" \
    "subsystem get does not echo the key back"

assert_fails "subsystem add rejects a malformed key" \
    nvmeof_cmd subsystem add --nqn "$(suite_nqn badkey)" --no-group-append \
        --dhchap-key "$BAD_KEY"

# ---------------------------------------------------------------------------
section "subsystem change_key"
# ---------------------------------------------------------------------------

assert_ok "change_key replaces the key" \
    nvmeof_cmd subsystem change_key --nqn "$KEYED_NQN" --dhchap-key "$KEY2"
assert_eq "true" "$(has_key "$KEYED_NQN")" "the subsystem still has a key"

assert_ok "change_key adds a key to a subsystem that had none" \
    nvmeof_cmd subsystem change_key --nqn "$PLAIN_NQN" --dhchap-key "$KEY1"
assert_eq "true" "$(has_key "$PLAIN_NQN")" "the plain subsystem now has a key"

assert_fails "change_key requires --dhchap-key" \
    nvmeof_cmd subsystem change_key --nqn "$KEYED_NQN"

assert_fails "change_key rejects a malformed key" \
    nvmeof_cmd subsystem change_key --nqn "$KEYED_NQN" --dhchap-key "$BAD_KEY"

assert_fails "change_key rejects an unknown subsystem" \
    nvmeof_cmd subsystem change_key --nqn "$(suite_nqn never-created)" --dhchap-key "$KEY1"

assert_eq "true" "$(has_key "$KEYED_NQN")" "the rejected calls left the key in place"

# ---------------------------------------------------------------------------
section "subsystem del_key"
# ---------------------------------------------------------------------------

assert_ok "del_key removes the key" nvmeof_cmd subsystem del_key --nqn "$KEYED_NQN"
assert_eq "false" "$(has_key "$KEYED_NQN")" "the subsystem no longer has a key"

# Removing a key that is not there is a no-op rather than an error.
assert_ok "del_key on a subsystem with no key" \
    nvmeof_cmd subsystem del_key --nqn "$KEYED_NQN"
assert_eq "false" "$(has_key "$KEYED_NQN")" "still no key"

assert_fails "del_key rejects an unknown subsystem" \
    nvmeof_cmd subsystem del_key --nqn "$(suite_nqn never-created)"
