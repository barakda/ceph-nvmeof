#!/bin/bash
#
# tests/gh_runner/run.sh -- entry point for the gh_runner suites.
#
# Usage:
#     ./tests/gh_runner/run.sh <shape>              # every suite of a shape
#     ./tests/gh_runner/run.sh <shape>/<suite>      # one suite
#     ./tests/gh_runner/run.sh <shape>/<suite>/NNN_name.sh   # one script
#
# A "shape" is a cluster configuration (tests/gh_runner/<shape>/shape.env says
# how many gateways it needs); a "suite" is a directory of test scripts for one
# CLI noun. Running a whole shape starts the cluster once and reuses it, which
# is why each script has to clean up after itself.
#
# Environment:
#     GH_RUNNER_NO_CLUSTER=1   use the cluster that is already running
#     GH_RUNNER_TEARDOWN=1     compose down on exit. Off by default: CI copies
#                              the ceph logs out of the container afterwards,
#                              and those go away with the containers.
#
set -u -o pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
HERE="$ROOT/tests/gh_runner"

# shellcheck source=tests/gh_runner/lib/common.sh
source "$HERE/lib/common.sh"
# shellcheck source=tests/gh_runner/lib/cluster.sh
source "$HERE/lib/cluster.sh"

timestamp_wrapper "$@"

usage() {
    echo "usage: $0 <shape>[/<suite>[/<script>]] ..." >&2
    echo >&2
    echo "available targets:" >&2
    local shape suite
    for shape in "$HERE"/*/; do
        [ -f "$shape/shape.env" ] || continue
        echo "  $(basename "$shape")" >&2
        for suite in "$shape"*/; do
            [ -d "$suite" ] || continue
            echo "    $(basename "$shape")/$(basename "$suite")" >&2
        done
    done
    exit 2
}

[ $# -ge 1 ] || usage

cd "$ROOT" || die "cannot cd to $ROOT"

# ---------------------------------------------------------------------------
# Resolve the targets, and the shape they all belong to.
# ---------------------------------------------------------------------------

SHAPE=""
SCRIPTS=()

add_scripts_from_dir() {
    local dir="$1" found=0 script
    while IFS= read -r script; do
        SCRIPTS+=("$script")
        found=1
    done < <(find "$dir" -maxdepth 1 -name '*.sh' -type f | sort)
    [ "$found" -eq 1 ] || die "no test scripts under $dir"
}

for target in "$@"; do
    target="${target#tests/gh_runner/}"
    target="${target%/}"
    shape="${target%%/*}"
    rest="${target#"$shape"}"
    rest="${rest#/}"

    [ -f "$HERE/$shape/shape.env" ] || usage
    if [ -n "$SHAPE" ] && [ "$SHAPE" != "$shape" ]; then
        die "cannot run shapes '$SHAPE' and '$shape' in one invocation: " \
            "they need different clusters"
    fi
    if [ -z "$SHAPE" ]; then
        SHAPE="$shape"
        # GATEWAYS, SHAPE_SKIP, and anything else the shape needs. Read here
        # rather than after the loop because expanding a whole shape has to
        # honour SHAPE_SKIP.
        # shellcheck source=/dev/null
        source "$HERE/$SHAPE/shape.env"
        : "${GATEWAYS:?shape.env must set GATEWAYS}"
    fi

    if [ -z "$rest" ]; then
        for suite_dir in "$HERE/$shape"/*/; do
            [ -d "$suite_dir" ] || continue
            suite="$(basename "${suite_dir%/}")"
            # Named explicitly it still runs; it is only skipped when the
            # whole shape is expanded.
            if [[ " ${SHAPE_SKIP:-} " == *" $suite "* ]]; then
                log "skipping $shape/$suite (SHAPE_SKIP); run it by name to include it"
                continue
            fi
            add_scripts_from_dir "${suite_dir%/}"
        done
    elif [ -d "$HERE/$shape/$rest" ]; then
        add_scripts_from_dir "$HERE/$shape/$rest"
    elif [ -f "$HERE/$shape/$rest" ]; then
        SCRIPTS+=("$HERE/$shape/$rest")
    else
        die "no such suite or script: $target"
    fi
done

[ "${#SCRIPTS[@]}" -gt 0 ] || die "nothing to run"

# ---------------------------------------------------------------------------
# Cluster
# ---------------------------------------------------------------------------

teardown() {
    local rc=$?
    set +e
    if [ -n "${GH_RUNNER_TEARDOWN:-}" ] && [ -z "${GH_RUNNER_NO_CLUSTER:-}" ]; then
        section "Tearing down the cluster"
        docker compose down --volumes --remove-orphans
    fi
    exit $rc
}

section "gh_runner: shape '$SHAPE', ${#SCRIPTS[@]} script(s), $GATEWAYS gateway(s)"
for script in "${SCRIPTS[@]}"; do
    echo "  ${script#"$HERE"/}"
done

if [ -n "${GH_RUNNER_NO_CLUSTER:-}" ]; then
    log "reusing the running cluster"
else
    section "Starting ceph and $GATEWAYS gateway(s)"
    trap teardown EXIT
    run ./tests/ha/start_up.sh "$GATEWAYS" || die "could not start the cluster"
    run ./tests/ha/wait_gateways.sh "$GATEWAYS" || die "gateways did not come up"
fi

require_gateways "$GATEWAYS"

# start_up.sh returns only after the ceph container is healthy. Wait until
# the CLI actually answers, then print the snapshot. ceph orch ls has no
# orchestrator on a vstart cluster, so its failure is still shown and ignored.
section "Cluster snapshot"
if ! wait_until 120 ceph_cmd version; then
    die "ceph is not accepting commands"
fi
ceph_cmd orch ls || true
ceph_cmd -s || die "ceph -s failed"
ceph_cmd version || die "ceph version failed"
run docker ps || die "docker ps failed"

nvmeof_cli_setup

# ---------------------------------------------------------------------------
# Run
# ---------------------------------------------------------------------------

PASSED=()
FAILED=()
GH_RUNNER_RESULTS="$(mktemp)"
export GH_RUNNER_RESULTS

for script in "${SCRIPTS[@]}"; do
    name="${script#"$HERE"/}"
    section "Running $name"
    lines_before=$(wc -l < "$GH_RUNNER_RESULTS")
    if bash "$script"; then
        PASSED+=("$name")
    else
        FAILED+=("$name")
        lines_after=$(wc -l < "$GH_RUNNER_RESULTS")
        if [ "$lines_after" -eq "$lines_before" ]; then
            printf '%s\tfailed\texited without a recorded check\n' \
                "$name" >> "$GH_RUNNER_RESULTS"
        fi
    fi
    run docker compose ps
done

section "gh_runner summary: shape '$SHAPE'"
echo "passed: ${#PASSED[@]}"
for name in "${PASSED[@]}"; do echo "  ✅ $name"; done
echo "failed: ${#FAILED[@]}"
for name in "${FAILED[@]}"; do echo "  ❌ $name"; done

if [ "${#FAILED[@]}" -eq 0 ]; then
    echo "✅ all suites passed"
else
    echo "❌ ${#FAILED[@]} suite(s) failed"
fi
print_results_table
rm -f "$GH_RUNNER_RESULTS"

[ "${#FAILED[@]}" -eq 0 ] || exit 1
