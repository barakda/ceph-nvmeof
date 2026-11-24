#!/bin/bash
#
# single_gw/gateway/010_info.sh
#
# The read-only gateway introspection commands:
#
#     ceph nvmeof gateway info          (alias: gw info)
#     ceph nvmeof gateway version       (alias: gw version)
#     ceph nvmeof gateway get_stats
#     ceph nvmeof gateway get_thread_stats
#     ceph nvmeof get_subsystems
#
# These take no arguments beyond the gateway selectors, so the semantic check
# is on the content: `gateway info` has to describe the gateway we actually
# targeted, and `gateway version` has to agree with it.
#
set -u -o pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=tests/gh_runner/lib/common.sh
source "$HERE/lib/common.sh"
# shellcheck source=tests/gh_runner/lib/cluster.sh
source "$HERE/lib/cluster.sh"

suite_begin "gateway/010_info"
trap suite_exit EXIT   # read-only suite: nothing to clean up

# ---------------------------------------------------------------------------
section "gateway info"
# ---------------------------------------------------------------------------

assert_ok "gateway info succeeds" nvmeof_cmd gateway info
assert_ok "gw info alias succeeds" nvmeof_cmd gw info

info_json="$(nvmeof_json gateway info)"
echo "$info_json"

assert_eq "0" "$(json_get '.status' <<< "$info_json")" \
    "gateway info reports status 0"

# The dashboard was told to talk to NVMEOF_TARGET_ADDRESS; the gateway that
# answered must be the one running in that container. Without this, a wrong
# --server-address would go unnoticed and every later suite would silently
# test the wrong gateway.
#
# `addr` is no use for that -- the gateway echoes back the `addr` from
# ceph-nvmeof.conf, which is 0.0.0.0 -- but `hostname` is the container's own.
assert_eq "$(gateway_hostname "$NVMEOF_TARGET_CONTAINER")" \
    "$(json_get '.hostname' <<< "$info_json")" \
    "gateway info comes from the container we targeted"

assert_eq "$NVMEOF_GW_PORT" "$(json_get '.port' <<< "$info_json")" \
    "gateway info reports the gRPC port"

gw_version="$(json_get '.version' <<< "$info_json")"
assert_ne "" "$gw_version" "gateway info reports a version"
assert_ne "null" "$gw_version" "gateway info version is not null"

assert_ne "" "$(json_get '.spdk_version' <<< "$info_json")" \
    "gateway info reports an SPDK version"

# A gateway that is still initializing answers RPCs but has not loaded its
# OMAP state yet, so anything a later suite reads could be stale.
assert_eq "True" "$(json_get 'if .gateway_initialization_over then "True" else "False" end' \
    <<< "$info_json")" "gateway has finished initializing"

assert_eq "$(gateway_group)" "$(json_get '.group' <<< "$info_json")" \
    "gateway info reports the configured group"

# ---------------------------------------------------------------------------
section "gateway version"
# ---------------------------------------------------------------------------

assert_ok "gateway version succeeds" nvmeof_cmd gateway version
assert_ok "gw version alias succeeds" nvmeof_cmd gw version

version_json="$(nvmeof_json gateway version)"
echo "$version_json"
assert_eq "$gw_version" "$(json_get '.version' <<< "$version_json")" \
    "gateway version agrees with gateway info"

# ---------------------------------------------------------------------------
section "gateway get_stats / get_thread_stats"
# ---------------------------------------------------------------------------

assert_ok "gateway get_stats succeeds" nvmeof_cmd gateway get_stats
assert_ok "gateway get_thread_stats succeeds" nvmeof_cmd gateway get_thread_stats

thread_json="$(nvmeof_json gateway get_thread_stats)"
echo "$thread_json"
assert_eq "0" "$(json_get '.status' <<< "$thread_json")" \
    "get_thread_stats reports status 0"
# An NVMf target always runs at least one reactor thread.
assert_ne "0" "$(json_get '.threads | length' <<< "$thread_json")" \
    "get_thread_stats lists at least one thread"

# ---------------------------------------------------------------------------
section "get_subsystems"
# ---------------------------------------------------------------------------

assert_ok "get_subsystems succeeds" nvmeof_cmd get_subsystems

# GetSubsystems has no status field -- the model is just the list. That this
# list actually tracks what gets created is checked in the subsystem suite;
# here we only establish that the command answers with a well formed list.
subsys_json="$(nvmeof_json get_subsystems)"
echo "$subsys_json"
assert_eq "array" "$(json_get '.subsystems | type' <<< "$subsys_json")" \
    "get_subsystems returns a subsystem list"
