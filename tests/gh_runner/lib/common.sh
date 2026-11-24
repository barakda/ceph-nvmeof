#
# tests/gh_runner/lib/common.sh
#
# Output formatting and assertions shared by every gh_runner suite.
#
# Suites source this file; they never execute it. Every suite runs against a
# cluster that is shared with the other suites of the same shape, so a suite
# must create only resources carrying its own $SUITE_PREFIX and must remove
# them again in its cleanup trap.
#
# shellcheck shell=bash

# Sourced more than once when a shape runs several suites in one process.
[ -n "${GH_RUNNER_COMMON_SOURCED:-}" ] && return 0
GH_RUNNER_COMMON_SOURCED=1

printf -v _bar '%130s' ''
BANNER=${_bar// /=}
SECBAR=${_bar// /#}
unset _bar

# Assertion tallies for the current suite.
CHECKS_PASSED=0
CHECKS_FAILED=0
FAILED_CHECKS=()

#
# Prefix every line of this script's output with a timestamp.
#
# A suite calls this as its very first statement. It re-executes itself under
# a formatting pipe and never returns in the parent.
#
timestamp_wrapper() {
    [ -n "${GH_RUNNER_TS_WRAPPED:-}" ] && return 0
    export GH_RUNNER_TS_WRAPPED=1
    set +e              # never abort the wrapper, always report the real status
    set -o pipefail
    bash "$0" "$@" 2>&1 | while IFS= read -r line; do
        printf '%(%b%d %H:%M:%S)T - %s\n' -1 "$line"
    done
    exit "${PIPESTATUS[0]}"
}

section() {
    echo "$SECBAR"
    echo "### $*"
    echo "$SECBAR"
}

#
# Echo a command, then run it. Returns the command's status.
#
run() {
    echo "$BANNER"
    echo "$*"
    echo "$BANNER"
    "$@"
}

log()  { echo "ℹ️  $*"; }
warn() { echo "⚠️  $*"; }

#
# Unrecoverable problem with the environment rather than a failed assertion:
# the suite cannot produce a meaningful verdict, so stop.
#
die() {
    echo "❌ $*" >&2
    exit 1
}

_pass() {
    CHECKS_PASSED=$((CHECKS_PASSED + 1))
    echo "✅ $1"
}

#
# A failed assertion does not abort the suite: the remaining checks still run
# so that one CI job reports every problem it can find, not just the first.
#
_fail() {
    CHECKS_FAILED=$((CHECKS_FAILED + 1))
    FAILED_CHECKS+=("$1")
    echo "❌ $1"
    [ -n "${2:-}" ] && echo "   $2"
    return 0
}

#
# assert_ok <description> <command...>
#
assert_ok() {
    local desc="$1"; shift
    local out status
    echo "$BANNER"
    echo "$*"
    echo "$BANNER"
    out=$("$@" 2>&1); status=$?
    [ -n "$out" ] && echo "$out"
    if [ $status -eq 0 ]; then
        _pass "$desc"
    else
        _fail "$desc" "exit status $status"
    fi
    return 0
}

#
# assert_fails <description> <command...>
#
# For options whose whole purpose is to refuse something: --force guards,
# required arguments, duplicate names.
#
assert_fails() {
    local desc="$1"; shift
    local out status
    echo "$BANNER"
    echo "! $*"
    echo "$BANNER"
    out=$("$@" 2>&1); status=$?
    [ -n "$out" ] && echo "$out"
    if [ $status -ne 0 ]; then
        _pass "$desc (rejected as expected)"
    else
        _fail "$desc" "command unexpectedly succeeded"
    fi
    return 0
}

assert_eq() {
    local expected="$1" actual="$2" desc="$3"
    if [ "$expected" = "$actual" ]; then
        _pass "$desc"
    else
        _fail "$desc" "expected '$expected', got '$actual'"
    fi
    return 0
}

assert_ne() {
    local unexpected="$1" actual="$2" desc="$3"
    if [ "$unexpected" != "$actual" ]; then
        _pass "$desc"
    else
        _fail "$desc" "expected anything but '$unexpected'"
    fi
    return 0
}

#
# assert_ge <actual> <minimum> <description> -- numeric.
#
assert_ge() {
    local actual="$1" minimum="$2" desc="$3"
    if [[ "$actual" =~ ^-?[0-9]+$ ]] && [ "$actual" -ge "$minimum" ]; then
        _pass "$desc"
    else
        _fail "$desc" "expected a number >= $minimum, got '$actual'"
    fi
    return 0
}

assert_contains() {
    local haystack="$1" needle="$2" desc="$3"
    if [[ "$haystack" == *"$needle"* ]]; then
        _pass "$desc"
    else
        _fail "$desc" "'$needle' not found in: $haystack"
    fi
    return 0
}

assert_not_contains() {
    local haystack="$1" needle="$2" desc="$3"
    if [[ "$haystack" != *"$needle"* ]]; then
        _pass "$desc"
    else
        _fail "$desc" "'$needle' unexpectedly present in: $haystack"
    fi
    return 0
}

#
# Poll until <command> succeeds. Gateway state changes (ANA group moves,
# listener creation) are not always visible on the next read.
#
# wait_until <timeout_seconds> <command...>
#
wait_until() {
    local timeout="$1"; shift
    local deadline=$((SECONDS + timeout))
    while [ $SECONDS -lt $deadline ]; do
        if "$@" > /dev/null 2>&1; then
            return 0
        fi
        sleep 1
    done
    return 1
}

#
# The EXIT trap every suite installs: `trap suite_exit EXIT`.
#
# A suite that creates anything defines a suite_cleanup function to remove it;
# this calls it before reporting.
#
# The explicit `exit` matters. Bash discards the status a trap *returns* -- a
# `trap finish EXIT` would leave a suite with failed checks exiting 0, and CI
# would call it green.
#
suite_exit() {
    local rc=$?
    set +e
    if declare -F suite_cleanup > /dev/null 2>&1; then
        section "Cleanup: ${SUITE_NAME:-suite}"
        suite_cleanup
    fi
    finish || rc=1
    exit "$rc"
}

#
# Print the suite verdict and return a status CI can use. Called by suite_exit;
# a suite should not call it directly.
#
finish() {
    local name="${1:-$SUITE_NAME}"
    section "Result: $name"
    echo "checks passed: $CHECKS_PASSED"
    echo "checks failed: $CHECKS_FAILED"
    if [ "$CHECKS_FAILED" -ne 0 ]; then
        echo
        echo "failed checks:"
        local c
        for c in "${FAILED_CHECKS[@]}"; do
            echo "  - $c"
        done
        echo "❌ $name failed"
        return 1
    fi
    if [ "$CHECKS_PASSED" -eq 0 ]; then
        echo "❌ $name ran no checks at all"
        return 1
    fi
    echo "✅ $name passed"
    return 0
}
