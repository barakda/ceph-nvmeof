#
# tests/gh_runner/lib/cluster.sh
#
# Talking to the compose cluster.
#
# These suites drive the ceph-side CLIs only -- `ceph nvmeof ...` and
# `ceph nvme-gw ...` -- not ceph-nvmeof's own `nvmeof-cli`. Both run inside the
# `ceph` container, which is the only place a configured `ceph` binary exists.
#
# `ceph nvmeof` is served by the dashboard mgr module, and Dockerfile.ceph
# starts vstart with `--without-dashboard`. nvmeof_cli_setup() enables the
# module and registers the running gateways with it; nothing works before it
# has run.
#
# shellcheck shell=bash

[ -n "${GH_RUNNER_CLUSTER_SOURCED:-}" ] && return 0
GH_RUNNER_CLUSTER_SOURCED=1

# Failure analysis. Inert unless BOB_ENABLED=1, so sourcing it always is safe.
# shellcheck source=tests/gh_runner/lib/bob.sh
source "$(dirname "${BASH_SOURCE[0]}")/bob.sh"

RBD_POOL="${RBD_POOL:-rbd}"
NVMEOF_GW_PORT="${NVMEOF_GW_PORT:-5500}"

# One dashboard "service name" for every gateway. The dashboard's
# _get_default_service() raises as soon as two service names are registered
# and no orchestrator is available to disambiguate them, so all gateways must
# share this one name and differ only by daemon_name.
NVMEOF_SERVICE_NAME="${NVMEOF_SERVICE_NAME:-nvmeof.$RBD_POOL}"

# ---------------------------------------------------------------------------
# ceph
# ---------------------------------------------------------------------------

#
# Run a command in the ceph container, tracing it to the transcript.
#
# The arguments are the argv to run inside the container. The traced line is
# built from that same argv, so what the log shows is exactly what ran, and
# it is the whole command -- `docker compose exec` prefix included -- so it
# can be copied out of the console and pasted into a shell at the repository
# root without editing.
#
# stdout and stderr are kept apart. stdout is returned unchanged, so a caller
# can pipe it straight into json_get; stderr is logged separately with the
# vstart noise filtered out, and kept in LAST_ERR for diagnose().
#
_ceph_exec() {
    local out err rc errfile
    local -a argv=(docker compose exec -T ceph "$@")

    log_cmd "$(shell_quote "${argv[@]}")"
    errfile="$(mktemp)"
    out="$("${argv[@]}" 2>"$errfile")"; rc=$?
    err="$(grep -v "$CEPH_NOISE" "$errfile")" || true
    rm -f "$errfile"

    log_out "$out" "$err" "$rc"
    # Read by assert_ok -> diagnose() in common.sh.
    # shellcheck disable=SC2034
    LAST_ERR="$err"
    # And again through a file, which survives `$( )`, for Bob.
    record_last "$(shell_quote "${argv[@]}")" "$out" "$err" "$rc"

    [ -n "$out" ] && printf '%s\n' "$out"
    return "$rc"
}

#
# Run `ceph ...` inside the ceph container.
#
ceph_cmd() {
    _ceph_exec ceph "$@"
}

#
# `ceph nvmeof ...` against a specific gateway.
#
# $NVMEOF_TARGET_ADDRESS, set by use_gateway(), is passed as --server-address
# so that the dashboard talks to the gateway the suite means to test instead
# of whichever one it registered first.
#
# Boolean options must be written `--flag=value`, never `--flag value`. Ceph's
# argument parser does not consume the following token for a CephBool keyword:
# `--enabled true` sets enabled to true and then fails on a stray positional
# `true`, which looks like the option was rejected when it was not. `--flag`
# on its own also means true. This only applies to parameters the handler
# annotates `bool`; `subsystem del --force` is a str and takes `--force true`.
#
nvmeof_cmd() {
    if [ -n "${NVMEOF_TARGET_ADDRESS:-}" ]; then
        _ceph_exec ceph nvmeof "$@" --server-address "$NVMEOF_TARGET_ADDRESS"
    else
        _ceph_exec ceph nvmeof "$@"
    fi
}

#
# As nvmeof_cmd, but asking for JSON. Feed the output to json_get.
#
nvmeof_json() {
    if [ -n "${NVMEOF_TARGET_ADDRESS:-}" ]; then
        _ceph_exec ceph nvmeof --format json "$@" --server-address "$NVMEOF_TARGET_ADDRESS"
    else
        _ceph_exec ceph nvmeof --format json "$@"
    fi
}

#
# `ceph nvme-gw ...` -- monitor-side gateway membership and HA state.
# Arguments are positional, not flags: nvme_gw_cmd show "$RBD_POOL" "$GW_GROUP"
#
nvme_gw_cmd() {
    _ceph_exec ceph nvme-gw "$@"
}

#
# `rbd ...` inside the ceph container, for checking what a namespace did to
# the image behind it.
#
rbd_cmd() {
    _ceph_exec rbd "$@"
}

#
# json_get <jq filter>, reading JSON on stdin.
#
# jq is not guaranteed on the runner host but is installed in the ceph image,
# so fall back to running it there.
#
json_get() {
    if command -v jq > /dev/null 2>&1; then
        jq -r "$1"
    else
        docker compose exec -T ceph jq -r "$1"
    fi
}

# ---------------------------------------------------------------------------
# Gateways
# ---------------------------------------------------------------------------

#
# Container ids of the running gateways, in `docker ps` order.
# Excludes the cli and discovery containers.
#
gateway_containers() {
    docker ps --format '{{.ID}}\t{{.Names}}' |
        awk '$2 ~ /nvmeof/ && $2 !~ /cli/ && $2 !~ /discovery/ {print $1}'
}

gateway_ip() {
    docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' "$1"
}

#
# The hostname the gateway process sees, which is what it reports back in
# `gateway info`. Docker defaults it to the container id, but read it rather
# than assume it.
#
gateway_hostname() {
    docker inspect -f '{{.Config.Hostname}}' "$1"
}

#
# The gateway group name, as the gateways themselves read it from
# ceph-nvmeof.conf. Empty by default.
#
gateway_group() {
    local root
    root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
    sed -n 's/^[[:space:]]*group[[:space:]]*=[[:space:]]*//p' "$root/ceph-nvmeof.conf" |
        head -1 | sed 's/[[:space:]]*$//'
}

#
# Point the ceph nvmeof commands at the Nth running gateway (1-based).
#
# Sets NVMEOF_TARGET_CONTAINER and NVMEOF_TARGET_ADDRESS, which nvmeof_cmd and
# nvmeof_json read.
#
use_gateway() {
    local index="${1:-1}" containers=()
    mapfile -t containers < <(gateway_containers)
    if [ "${#containers[@]}" -lt "$index" ]; then
        die "gateway $index requested but only ${#containers[@]} are running"
    fi
    NVMEOF_TARGET_CONTAINER="${containers[$((index - 1))]}"
    NVMEOF_TARGET_ADDRESS="$(gateway_ip "$NVMEOF_TARGET_CONTAINER")"
    export NVMEOF_TARGET_CONTAINER NVMEOF_TARGET_ADDRESS
    log "driving gateway $index: container $NVMEOF_TARGET_CONTAINER at $NVMEOF_TARGET_ADDRESS"
}

#
# Fail unless exactly <n> gateways are running. A suite written for one
# gateway produces nonsense on two, so check before creating anything.
#
require_gateways() {
    local want="$1" have
    have=$(gateway_containers | wc -l | tr -d ' ')
    if [ "$have" -ne "$want" ]; then
        run docker ps --format '{{.ID}}\t{{.Names}}\t{{.Status}}'
        die "expected exactly $want running nvmeof gateway(s), found $have"
    fi
    log "$have gateway(s) running, as required"
}

# ---------------------------------------------------------------------------
# Enabling `ceph nvmeof`
# ---------------------------------------------------------------------------

#
# Start a suite.
#
# Sets SUITE_NAME and SUITE_PREFIX (which every resource the suite creates must
# carry, because the cluster is shared with the other suites of the shape), and
# makes sure the ceph nvmeof commands have a gateway to talk to when the suite
# is run on its own rather than through run.sh.
#
suite_begin() {
    SUITE_NAME="$1"
    # The prefix ends up inside NQNs, and an NQN becomes part of an OMAP key,
    # where "_" is the delimiter: GatewayState.is_key_element_valid() rejects
    # any element containing one. Suite names are taken from file names such
    # as 010_add_del, so the underscores have to go here, not just the "/".
    local slug="${SUITE_NAME//\//-}"
    SUITE_PREFIX="gh-${slug//_/-}"
    # Every command here goes through `docker compose`, which has to run where
    # the compose file and .env are. run.sh already does this; doing it again
    # is what lets a suite be run on its own from any directory.
    cd "$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)" ||
        die "cannot cd to the repository root"
    [ -n "${NVMEOF_TARGET_ADDRESS:-}" ] || use_gateway 1
    section "Suite: $SUITE_NAME"
}

#
# An NQN belonging to this suite. suite_nqn 1 -> nqn.2016-06.io.spdk:gh-...-1
#
# The suffix is sanitised the same way the prefix is: no underscores, or the
# gateway refuses the NQN as an invalid OMAP key element.
#
suite_nqn() {
    local suffix="${1:-1}"
    echo "nqn.2016-06.io.spdk:${SUITE_PREFIX:?suite_begin was not called}-${suffix//_/-}"
}

#
# An RBD image name belonging to this suite.
#
suite_image() {
    echo "${SUITE_PREFIX:?suite_begin was not called}-${1:-1}"
}

#
# Remove every RBD image this suite created.
#
# Deleting a namespace does not delete the image behind it unless the
# namespace was told to trash it, so images outlive their subsystem and would
# otherwise collect across runs and collide on the next one.
#
suite_cleanup_images() {
    local img
    while read -r img; do
        [ -n "$img" ] || continue
        case "$img" in
            *"${SUITE_PREFIX:?}"*) ;;
            *) continue ;;
        esac
        log "cleanup: removing image $img"
        rbd_cmd -p "$RBD_POOL" rm "$img" > /dev/null 2>&1 ||
            warn "cleanup: could not remove image $img"
    done < <(rbd_cmd -p "$RBD_POOL" ls 2>/dev/null)
}

#
# Remove every subsystem this suite created, namespaces and all. Safe to call
# when nothing was created.
#
suite_cleanup_subsystems() {
    local nqn
    while read -r nqn; do
        [ -n "$nqn" ] || continue
        case "$nqn" in
            *"${SUITE_PREFIX:?}"*) ;;
            *) continue ;;
        esac
        log "cleanup: removing $nqn"
        nvmeof_cmd subsystem del --nqn "$nqn" --force true > /dev/null 2>&1 ||
            warn "cleanup: could not remove $nqn"
    done < <(nvmeof_json subsystem list 2>/dev/null | json_get '.subsystems[]?.nqn' 2>/dev/null)
}

#
# Enable the dashboard mgr module and register every running gateway with it.
#
# Idempotent: safe to call once per suite even when several suites share a
# cluster.
#
nvmeof_cli_setup() {
    local group container ip daemon i=0

    section "Enabling the ceph nvmeof CLI"

    if ! ceph_cmd mgr module ls --format json | json_get '.enabled_modules[]' |
            grep -qx dashboard; then
        # The dashboard serves HTTPS by default and has no certificate in a
        # vstart cluster. Its CLI commands register regardless of whether the
        # web server comes up, but turning SSL off keeps the mgr log quiet.
        ceph_cmd config set mgr mgr/dashboard/ssl false
        ceph_cmd mgr module enable dashboard || die "could not enable the dashboard module"
    else
        log "dashboard module already enabled"
    fi

    # The module registers its commands asynchronously after loading.
    if ! wait_until 60 ceph_cmd dashboard nvmeof-gateway-list; then
        ceph_cmd mgr module ls --format json
        die "the dashboard module did not register its nvmeof commands"
    fi

    group="$(gateway_group)"
    log "gateway group: '${group}'"

    while read -r container; do
        i=$((i + 1))
        ip="$(gateway_ip "$container")"
        daemon="$NVMEOF_SERVICE_NAME.$container"
        log "registering gateway $i: $daemon -> $ip:$NVMEOF_GW_PORT"
        # -i wants a file holding the service URL, and it has to be a file the
        # ceph container can see. Traced like everything else, so the log
        # shows how the gateway got registered.
        #
        # $1..$4 below belong to the inner `bash -c` script and are supplied
        # after the `_`, so the single quotes are deliberate.
        # shellcheck disable=SC2016
        _ceph_exec bash -c '
            set -e
            printf "%s" "$1" > /tmp/nvmeof_gw_url
            ceph dashboard nvmeof-gateway-add -i /tmp/nvmeof_gw_url "$2" "$3" "$4"
        ' _ "$ip:$NVMEOF_GW_PORT" "$NVMEOF_SERVICE_NAME" "$group" "$daemon" ||
            die "could not register gateway $container with the dashboard"
    done < <(gateway_containers)

    ceph_cmd dashboard nvmeof-gateway-list

    use_gateway 1
    if ! wait_until 60 nvmeof_cmd gateway info; then
        ceph_cmd nvmeof gateway info --server-address "$NVMEOF_TARGET_ADDRESS"
        run docker logs --tail 50 "$NVMEOF_TARGET_CONTAINER"
        die "'ceph nvmeof gateway info' does not reach the gateway"
    fi
    log "ceph nvmeof CLI is live"
}
