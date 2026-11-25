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
SECBAR=${_bar// /#}     # section titles
CMDBAR=${_bar// /-}     # around each command
# shellcheck disable=SC2034  # read by bob_analyze in lib/bob.sh
BOBBAR=${_bar// /=}     # around a Bob analysis
unset _bar

# Assertion tallies for the current suite.
CHECKS_PASSED=0
CHECKS_FAILED=0
FAILED_CHECKS=()

# Set by the command wrappers in cluster.sh, read by the assertions when they
# need to explain a failure. Only reliable when the wrapper ran in this shell
# rather than inside `$( )`.
LAST_ERR=""

# The same thing again, but through a file.
#
# A check like `assert_eq x "$(nvmeof_json ...)" "..."` runs its command in a
# subshell, so any variable the wrapper sets there is gone by the time the
# assertion fails and wants to report on it. A file survives that, which is
# what lets Bob be told the command that actually produced the bad value.
#
# Removed by suite_exit rather than by a trap here: a suite installs its own
# `trap suite_exit EXIT`, which would replace anything set at this point.
LAST_CMD_FILE="$(mktemp -t gh_runner_lastcmd.XXXXXX)"

#
# Remember the command and its result for whoever has to explain a failure.
#
record_last() {
    { printf 'CMD\t%s\n' "$1"
      printf 'RC\t%s\n' "$4"
      printf 'OUT\t%s\n' "${2//$'\n'/\\n}"
      printf 'ERR\t%s\n' "${3//$'\n'/\\n}"
    } > "$LAST_CMD_FILE" 2>/dev/null || true
}

#
# Read a field back out. recall_last CMD|OUT|ERR|RC
#
recall_last() {
    [ -r "$LAST_CMD_FILE" ] || return 0
    local line
    line="$(grep -m1 "^$1"$'\t' "$LAST_CMD_FILE" 2>/dev/null)" || return 0
    printf '%b' "${line#*$'\t'}"
}

# fd 3 is the transcript. Command tracing goes there rather than to stdout,
# because `out=$(nvmeof_json ...)` and `cmd 2>&1` would otherwise swallow the
# trace into the value being captured.
exec 3>&1

# vstart prints this on every single ceph invocation. Two lines of it per
# command buries the output that matters.
# Read by _ceph_exec in cluster.sh.
# shellcheck disable=SC2034
CEPH_NOISE='dangerous and experimental features are enabled'

#
# Render an argv as a command line that can be pasted into a shell.
#
# Arguments that need no quoting are left bare, so the common case stays
# readable; anything else is quoted by printf %q. Without this, an argument
# such as --model-name "gh runner model" would be logged as three words and
# would not survive being copied out of the console.
#
shell_quote() {
    local out="" arg
    for arg in "$@"; do
        if [[ "$arg" =~ ^[A-Za-z0-9_@%+=:,./-]+$ ]]; then
            out+="$arg "
        else
            printf -v arg '%q' "$arg"
            out+="$arg "
        fi
    done
    printf '%s' "${out% }"
}

#
# The command about to run, on a line of its own between two rules, and
# complete enough to paste straight into a shell at the repository root.
#
log_cmd() {
    [ -n "${LOG_QUIET:-}" ] && return 0
    printf '\n%s\n%s\n%s\n' "$CMDBAR" "$*" "$CMDBAR" >&3
}

#
# What the machine said back, indented under the command.
#
# stdout and stderr are kept apart so that an error stands out, and so the
# ceph noise can be dropped from stderr without touching a response a check
# is about to parse. The exit status is only printed when it is non-zero: on
# success it says nothing a reader does not already know, and a failed
# assertion reports it on its own line anyway.
#
log_out() {
    local out="$1" err="$2" rc="$3"
    [ -n "${LOG_QUIET:-}" ] && return 0
    if [ -n "$out" ]; then
        printf '%s\n' "$out" | sed 's/^/    /' >&3
    fi
    if [ -n "$err" ]; then
        printf '%s\n' "$err" | sed 's/^/    [stderr] /' >&3
    fi
    if [ -z "$out" ] && [ -z "$err" ]; then
        printf '    (no output)\n' >&3
    fi
    if [ "$rc" -ne 0 ]; then
        printf '    (exit status %s)\n' "$rc" >&3
    fi
}

#
# Best effort explanation of why a command failed, printed under the verdict.
#
# Everything here is a pattern that has actually come out of this stack. When
# nothing matches, the ceph error line is echoed on its own rather than a
# guess -- a wrong cause is worse than none.
#
diagnose() {
    local err="$1" rc="${2:-}" why=""
    # Read by assert_ok, which stores this text in the end-of-run results table.
    DIAGNOSIS=""

    # Order matters: the environment-level causes come first, because their
    # messages contain phrases such as "does not exist" that the generic
    # object-not-found arm below would otherwise swallow.
    case "$err" in
    *"Module 'dashboard' is not enabled"*|*"No such module"*)
        why="The dashboard mgr module is off, so no 'ceph nvmeof' command exists.
Dockerfile.ceph starts vstart with --without-dashboard and nvmeof_cli_setup
is what turns it back on." ;;
    *"Gateway group does not exist"*|*"No gateway found matching server address"*)
        why="The dashboard has no gateway registered for this address. nvmeof_cli_setup
should have done that; check the 'Enabling the ceph nvmeof CLI' section." ;;
    *UNAVAILABLE*|*"failed to connect"*|*"Deadline Exceeded"*|*504*)
        why="The mgr could not reach the gateway over gRPC. The gateway may have died;
check 'docker compose ps' and the gateway container log." ;;
    *"no valid command found"*|*"unrecognized command"*|*"Invalid command"*)
        why="The ceph build in this cluster does not have this command. CLI_MATRIX.md
is generated from a ceph checkout that may be newer than the container;
compare 'ceph version' with the matrix." ;;
    *"contains invalid characters"*)
        why="A name contains \"_\". Names become OMAP key elements, where \"_\" is
the delimiter, so GatewayState.is_key_element_valid() rejects them.
Use \"-\" instead." ;;
    *"Invalid NQN"*)
        why="The NQN is malformed. It must start with \"nqn.\", be 11..222 characters,
and carry a date and reverse-domain part, as in nqn.2016-06.io.spdk:name." ;;
    *"missing required parameter"*)
        why="A required option was not passed. CLI_MATRIX.md marks required options
with 'yes' in the Req column." ;;
    *"Unexpected argument"*)
        why="Almost certainly a boolean written as \"--flag value\". Ceph does not take
the next token as a CephBool's value, so the value is left over as a stray
positional. Write \"--flag=value\", or bare \"--flag\" for true." ;;
    *"not one of 'true', 'false'"*)
        why="A boolean option got something other than true/false/1/0." ;;
    *"already used by subsystem"*)
        why="Serial numbers are unique per gateway; another subsystem has this one." ;;
    *"already exists"*|*EEXIST*)
        why="The object is already there. A previous run may have left it behind:
check that the suite's cleanup removed everything it created." ;;
    *"Can't find entry"*|*ENOENT*|*"does not exist"*)
        why="The object was not found. Either it was never created, or an earlier
step in this suite failed and this one depends on it." ;;
    *"Invalid subnet"*|*EADDRNOTAVAIL*)
        why="The network mask is not a valid CIDR subnet." ;;
    *"Too many open files"*|*E2BIG*)
        why="A configured limit was exceeded." ;;
    esac

    if [ -z "$why" ]; then
        # No pattern matched. Surface the ceph error line verbatim, if there
        # is one, rather than inventing a cause.
        why="$(printf '%s\n' "$err" | grep -m1 -E '^Error [A-Z0-9]+:' || true)"
        [ -n "$why" ] || return 0
    fi

    DIAGNOSIS="$why"
    printf '    ROOT CAUSE: ' >&3
    printf '%s\n' "$why" | sed '2,$s/^/                /' >&3
}

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
# For things that are not ceph commands -- docker, the start_up scripts. The
# ceph wrappers in cluster.sh trace themselves; do not wrap those in `run`, or
# the command gets logged twice.
run() {
    log_cmd "$*"
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

#
# One row of the table run.sh prints after the last suite. Append-only so each
# suite, which runs in its own process, can contribute. No-op when a suite is
# executed on its own and run.sh has not set the file.
#
_record() {
    local result="$1" desc="$2" reason="${3:-}"
    [ -n "${GH_RUNNER_RESULTS:-}" ] || return 0
    local name="$desc"
    [ -n "${SUITE_NAME:-}" ] && name="$SUITE_NAME: $desc"
    reason="${reason//$'\t'/ }"
    reason="${reason//$'\n'/ }"
    printf '%s\t%s\t%s\n' "$name" "$result" "$reason" >> "$GH_RUNNER_RESULTS"
}

_pass() {
    CHECKS_PASSED=$((CHECKS_PASSED + 1))
    echo "✅ $1"
    _record pass "$1"
}

#
# A failed assertion does not abort the suite: the remaining checks still run
# so that one CI job reports every problem it can find, not just the first.
#
_fail() {
    local desc="$1" reason="${2:-}" show="${3:-show}"
    CHECKS_FAILED=$((CHECKS_FAILED + 1))
    FAILED_CHECKS+=("$desc")
    echo "❌ $desc"
    # assert_ok already printed this text as ROOT CAUSE.
    if [ -n "$reason" ] && [ "$show" != "quiet" ]; then
        echo "   $reason"
    fi
    _record failed "$desc" "$reason"
    _ask_bob "$desc"
    return 0
}

#
# Hand the failure to Bob, before the suite moves on to the next check.
#
# The command and its output are read back out of LAST_CMD_FILE rather than
# from variables, so a check whose value came out of `$( )` -- where a
# subshell would have thrown the variables away -- still reports the command
# that actually produced the bad value.
#
# A no-op unless lib/bob.sh has been sourced and BOB_ENABLED=1.
#
_ask_bob() {
    declare -F bob_analyze > /dev/null 2>&1 || return 0
    bob_analyze "$1" \
        "$(recall_last CMD)" \
        "$(recall_last OUT)" \
        "$(recall_last ERR)" \
        "$(recall_last RC)"
}

#
# assert_ok <description> <command...>
#
# The command is run in this shell, not in `$( )`, so that the wrapper's
# LAST_ERR survives for diagnose(). Its stdout is thrown away here because the
# wrapper has already written the command and the response to the transcript.
#
assert_ok() {
    local desc="$1"; shift
    local status
    LAST_ERR=""
    "$@" > /dev/null; status=$?
    if [ "$status" -eq 0 ]; then
        _pass "$desc"
    else
        # The status is already on the command's own block, just above.
        diagnose "$LAST_ERR" "$status"
        _fail "$desc" "${DIAGNOSIS:-command failed}" quiet
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
    local status
    LAST_ERR=""
    "$@" > /dev/null; status=$?
    if [ "$status" -ne 0 ]; then
        _pass "$desc (rejected as expected)"
    else
        _fail "$desc" "the command was expected to be refused, but it succeeded"
    fi
    return 0
}

#
# Why a value read out of a response is not what was expected. The two cases
# worth naming are the ones that do not mean "the gateway disagrees with us".
#
_diagnose_value() {
    local actual="$1"
    case "$actual" in
    null)
        printf '    ROOT CAUSE: the jq path matched nothing. The field is absent from the\n' >&3
        printf '                response -- check the name against the model in ceph'"'"'s\n' >&3
        printf '                mgr/dashboard/model/nvmeof.py.\n' >&3 ;;
    "")
        printf '    ROOT CAUSE: the read produced nothing at all, so the command it reads\n' >&3
        printf '                from most likely failed. Look at the CMD above this one.\n' >&3 ;;
    esac
}

assert_eq() {
    local expected="$1" actual="$2" desc="$3"
    if [ "$expected" = "$actual" ]; then
        _pass "$desc"
    else
        _fail "$desc" "expected '$expected', got '$actual'"
        _diagnose_value "$actual"
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
        _diagnose_value "$actual"
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
    local deadline=$((SECONDS + timeout)) rc=1
    # Polling would otherwise put one CMD/OUT pair per second into the
    # transcript and bury the command the suite is actually testing.
    printf '\nℹ️  waiting up to %ss for: %s\n' "$timeout" "$*" >&3
    local saved="${LOG_QUIET:-}"
    LOG_QUIET=1
    while [ $SECONDS -lt $deadline ]; do
        if "$@" > /dev/null 2>&1; then
            rc=0
            break
        fi
        sleep 1
    done
    LOG_QUIET="$saved"
    if [ "$rc" -eq 0 ]; then
        printf 'ℹ️  satisfied after %ss\n' "$((SECONDS - deadline + timeout))" >&3
    else
        printf '⚠️  gave up after %ss\n' "$timeout" >&3
    fi
    return "$rc"
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
    rm -f "$LAST_CMD_FILE"
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

#
# The table at the end of a run.sh console.
#
# Column 1 is the suite and the check. Column 2 is pass or failed. Column 3
# is empty for a pass, and for a failure it is the expected/got text or the
# ceph error line.
#
print_results_table() {
    local name result reason
    local -a names=() results=() reasons=()
    local name_w=9 result_w=11
    local sep_name sep_result i passed=0 failed=0

    if [ -s "${GH_RUNNER_RESULTS:-}" ]; then
        while IFS=$'\t' read -r name result reason || [ -n "${name:-}" ]; do
            names+=("$name")
            results+=("$result")
            reasons+=("${reason:-}")
            [ "${#name}" -gt "$name_w" ] && name_w=${#name}
            [ "${#result}" -gt "$result_w" ] && result_w=${#result}
            name=""
        done < "$GH_RUNNER_RESULTS"
    fi

    section "Test results"
    if [ "${#names[@]}" -eq 0 ]; then
        echo "(no checks recorded)"
        return 0
    fi

    printf -v sep_name '%*s' "$name_w" ''
    sep_name=${sep_name// /-}
    printf -v sep_result '%*s' "$result_w" ''
    sep_result=${sep_result// /-}
    printf '%-*s  %-*s  %s\n' "$name_w" "test name" "$result_w" "pass/failed" "failure reason"
    printf '%-*s  %-*s  %s\n' "$name_w" "$sep_name" "$result_w" "$sep_result" "--------------"
    for i in "${!names[@]}"; do
        printf '%-*s  %-*s  %s\n' \
            "$name_w" "${names[$i]}" "$result_w" "${results[$i]}" "${reasons[$i]}"
        if [ "${results[$i]}" = "pass" ]; then
            passed=$((passed + 1))
        else
            failed=$((failed + 1))
        fi
    done
    echo
    echo "checks passed: $passed    checks failed: $failed"
}
