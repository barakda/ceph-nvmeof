#!/bin/bash
#
# secure/host/010_dhchap_psk.sh
#
#     ceph nvmeof host add --dhchap-key --dhchap-controller-key --psk
#     ceph nvmeof host change_key --nqn --host-nqn --dhchap-key
#     ceph nvmeof host del_key --nqn --host-nqn
#     ceph nvmeof host change_controller_key --nqn --host-nqn --dhchap-controller-key
#     ceph nvmeof host del_controller_key --nqn --host-nqn
#
# Three separate things per host: a DH-HMAC-CHAP key (host authenticates to
# the target), a controller key (the other direction, bidirectional auth),
# and a PSK (TLS pre-shared key). `host list` reports use_dhchap and use_psk
# but never the keys themselves.
#
# A controller key only means something alongside a host key, so the gateway
# refuses one on its own -- that ordering is what most of the rejections here
# are about.
#
set -u -o pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=tests/gh_runner/lib/common.sh
source "$HERE/lib/common.sh"
# shellcheck source=tests/gh_runner/lib/cluster.sh
source "$HERE/lib/cluster.sh"

suite_begin "host/010_dhchap_psk"

suite_cleanup() {
    suite_cleanup_subsystems
}
trap suite_exit EXIT

NQN="$(suite_nqn auth)"
HOST_KEY="nqn.2014-08.org.nvmexpress:uuid:11111111-2222-3333-4444-555555555555"
HOST_PSK="nqn.2014-08.org.nvmexpress:uuid:66666666-7777-8888-9999-aaaaaaaaaaaa"
HOST_PLAIN="nqn.2014-08.org.nvmexpress:uuid:bbbbbbbb-cccc-dddd-eeee-ffffffffffff"

# Valid keys, same shapes tests/test_dhchap.py and tests/test_psk.py use.
KEY1="DHHC-1:00:MWPqcx1Ug1debg8fPIGpkqbQhLcYUt39k7UWirkblaKEH1kE:"
KEY2="DHHC-1:01:Ei7kUrD7iyrjzXDwIZ666sSPBswUk4wDjSQtodytVB5YiBru:"
CTRL_KEY="DHHC-1:01:x7ecfGgIdOEl+J5cJ9JcZHOS2By2Me6eDJUnrsT9MVrCWRYV:"
CTRL_KEY2="DHHC-1:01:eNNXGjidEHHStbUi2Gmpps0JcnofReFfy+NaulguGgt327hz:"
PSK="NVMeTLSkey-1:01:YzrPElk4OYy1uUERriPwiiyEJE/+J5ckYpLB+5NHMsR2iBuT:"
BAD_KEY="DHHC-1:09:notarealkeyatall:"
BAD_PSK="xVMeTLSkey-1:01:YzrPElk4OYy1uUERriPwiiyEJE/+J5ckYpLB+5NHMsR2iBuT:"

host_flag() {
    nvmeof_json host list --nqn "$NQN" |
        json_get "if ([.hosts[] | select(.nqn == \"$1\")] | first | .$2) then \"true\" else \"false\" end"
}

# ---------------------------------------------------------------------------
section "Setup"
# ---------------------------------------------------------------------------

assert_ok "subsystem add" nvmeof_cmd subsystem add --nqn "$NQN" --no-group-append

# ---------------------------------------------------------------------------
section "host add with keys"
# ---------------------------------------------------------------------------

assert_ok "host add with a DH-HMAC-CHAP key" \
    nvmeof_cmd host add --nqn "$NQN" --host-nqn "$HOST_KEY" --dhchap-key "$KEY1"
assert_eq "true" "$(host_flag "$HOST_KEY" use_dhchap)" "the host is using DH-HMAC-CHAP"

assert_ok "host add with a PSK" \
    nvmeof_cmd host add --nqn "$NQN" --host-nqn "$HOST_PSK" --psk "$PSK"
assert_eq "true" "$(host_flag "$HOST_PSK" use_psk)" "the host is using a PSK"
assert_eq "false" "$(host_flag "$HOST_PSK" use_dhchap)" \
    "a PSK on its own does not turn on DH-HMAC-CHAP"

assert_ok "host add with no keys at all" \
    nvmeof_cmd host add --nqn "$NQN" --host-nqn "$HOST_PLAIN"
assert_eq "false" "$(host_flag "$HOST_PLAIN" use_dhchap)" "no DH-HMAC-CHAP"
assert_eq "false" "$(host_flag "$HOST_PLAIN" use_psk)" "no PSK"

# Neither secret may come back out.
hosts="$(nvmeof_json host list --nqn "$NQN")"
assert_not_contains "$hosts" "$KEY1" "host list does not echo the DH-HMAC-CHAP key"
assert_not_contains "$hosts" "$PSK" "host list does not echo the PSK"

assert_fails "host add rejects a malformed DH-HMAC-CHAP key" \
    nvmeof_cmd host add --nqn "$NQN" --host-nqn \
        "nqn.2014-08.org.nvmexpress:uuid:00000000-0000-0000-0000-000000000001" \
        --dhchap-key "$BAD_KEY"

assert_fails "host add rejects a malformed PSK" \
    nvmeof_cmd host add --nqn "$NQN" --host-nqn \
        "nqn.2014-08.org.nvmexpress:uuid:00000000-0000-0000-0000-000000000002" \
        --psk "$BAD_PSK"

# A controller key authenticates the target back to the host, so it is
# meaningless without a host key to pair with.
assert_fails "host add rejects a controller key with no host key" \
    nvmeof_cmd host add --nqn "$NQN" --host-nqn \
        "nqn.2014-08.org.nvmexpress:uuid:00000000-0000-0000-0000-000000000003" \
        --dhchap-controller-key "$CTRL_KEY"

# ---------------------------------------------------------------------------
section "host change_key / del_key"
# ---------------------------------------------------------------------------

assert_ok "change_key replaces the host key" \
    nvmeof_cmd host change_key --nqn "$NQN" --host-nqn "$HOST_KEY" --dhchap-key "$KEY2"
assert_eq "true" "$(host_flag "$HOST_KEY" use_dhchap)" "the host still uses DH-HMAC-CHAP"

assert_ok "change_key adds a key to a host that had none" \
    nvmeof_cmd host change_key --nqn "$NQN" --host-nqn "$HOST_PLAIN" --dhchap-key "$KEY1"
assert_eq "true" "$(host_flag "$HOST_PLAIN" use_dhchap)" "the plain host now has a key"

assert_fails "change_key requires --dhchap-key" \
    nvmeof_cmd host change_key --nqn "$NQN" --host-nqn "$HOST_KEY"

assert_fails "change_key rejects a malformed key" \
    nvmeof_cmd host change_key --nqn "$NQN" --host-nqn "$HOST_KEY" --dhchap-key "$BAD_KEY"

assert_fails "change_key rejects a host that is not on the list" \
    nvmeof_cmd host change_key --nqn "$NQN" --host-nqn \
        "nqn.2014-08.org.nvmexpress:uuid:00000000-0000-0000-0000-000000000004" \
        --dhchap-key "$KEY1"

assert_ok "del_key removes the host key" \
    nvmeof_cmd host del_key --nqn "$NQN" --host-nqn "$HOST_PLAIN"
assert_eq "false" "$(host_flag "$HOST_PLAIN" use_dhchap)" "the host no longer uses DH-HMAC-CHAP"

# ---------------------------------------------------------------------------
section "host change_controller_key / del_controller_key"
# ---------------------------------------------------------------------------

# HOST_KEY still has a host key from above, so a controller key is allowed.
assert_ok "change_controller_key on a host that has a key" \
    nvmeof_cmd host change_controller_key --nqn "$NQN" --host-nqn "$HOST_KEY" \
        --dhchap-controller-key "$CTRL_KEY"
assert_ne "" "$(nvmeof_json host list --nqn "$NQN" |
    json_get "[.hosts[] | select(.nqn == \"$HOST_KEY\")] | first | .dhchap_controller_origin")" \
    "the controller key origin is reported"

assert_ok "change_controller_key replaces it" \
    nvmeof_cmd host change_controller_key --nqn "$NQN" --host-nqn "$HOST_KEY" \
        --dhchap-controller-key "$CTRL_KEY2"

assert_fails "change_controller_key requires --dhchap-controller-key" \
    nvmeof_cmd host change_controller_key --nqn "$NQN" --host-nqn "$HOST_KEY"

assert_fails "change_controller_key rejects a malformed key" \
    nvmeof_cmd host change_controller_key --nqn "$NQN" --host-nqn "$HOST_KEY" \
        --dhchap-controller-key "$BAD_KEY"

# HOST_PSK has no host key, so it cannot take a controller key either.
assert_fails "change_controller_key is refused on a host with no host key" \
    nvmeof_cmd host change_controller_key --nqn "$NQN" --host-nqn "$HOST_PSK" \
        --dhchap-controller-key "$CTRL_KEY"

assert_ok "del_controller_key" \
    nvmeof_cmd host del_controller_key --nqn "$NQN" --host-nqn "$HOST_KEY"

assert_fails "del_controller_key rejects a host that is not on the list" \
    nvmeof_cmd host del_controller_key --nqn "$NQN" --host-nqn \
        "nqn.2014-08.org.nvmexpress:uuid:00000000-0000-0000-0000-000000000005"

# The host key itself must survive losing the controller key.
assert_eq "true" "$(host_flag "$HOST_KEY" use_dhchap)" \
    "removing the controller key left the host key alone"
