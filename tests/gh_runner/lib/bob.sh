#
# tests/gh_runner/lib/bob.sh
#
# Ask Bob to explain a failed check, inline, before the suite moves on.
#
# diagnose() in common.sh only recognises error text someone has already met
# and written a case for. Bob reads the actual command, the actual output,
# and the two sources of truth -- ceph-nvmeof devel and ceph main -- and says
# why it failed, including whether the fault is the test's or the product's.
#
# Bob analysis never changes a verdict. A failed check stays failed whatever
# Bob concludes, and Bob being unavailable, unauthenticated or slow is a
# warning, never a failure: this is a reporting aid, not an assertion.
#
# Cost and time are real here. A trivial prompt measured ~8s and ~$0.02; one
# that reads two repositories costs more, and the first full run produced 72
# failures. Three things keep that bounded:
#
#   - identical failures are analysed once (BOB_DEDUP),
#   - each suite analyses at most BOB_MAX_ANALYSES distinct failures,
#   - each call is capped by --max-turns, --max-cost and a hard timeout.
#
# shellcheck shell=bash

[ -n "${GH_RUNNER_BOB_SOURCED:-}" ] && return 0
GH_RUNNER_BOB_SOURCED=1

# Off unless asked for, so a local run does not spend money by surprise. The
# CI job turns it on.
BOB_ENABLED="${BOB_ENABLED:-0}"

BOB_CMD="${BOB_CMD:-bob}"
BOB_TIMEOUT="${BOB_TIMEOUT:-420}"

# These two are deliberately generous. Measured on a real failure: with
# --max-turns 12 Bob spent 13 tool calls fetching ceph sources, hit the cap,
# and returned no answer at all -- $0.63 for nothing. A budget too small to
# finish is worse than no analysis, so the caps are set where the work
# completes, and BOB_MAX_ANALYSES is what bounds the total instead.
BOB_MAX_TURNS="${BOB_MAX_TURNS:-40}"
BOB_MAX_COST="${BOB_MAX_COST:-1.50}"

# The real brake. --max-turns and --max-cost only abort Bob mid-thought,
# which spends the money and returns nothing; telling Bob up front how many
# commands it may run is what actually gets an answer out of it.
BOB_MAX_TOOL_CALLS="${BOB_MAX_TOOL_CALLS:-8}"

BOB_MAX_ANALYSES="${BOB_MAX_ANALYSES:-5}"
BOB_DEDUP="${BOB_DEDUP:-1}"

# Bob reads the checkout it is pointed at. Without this it runs wherever the
# suite happens to be and can only speculate about the gateway source.
BOB_WORKSPACE="${BOB_WORKSPACE:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)}"

# A ceph.git checkout on the runner, if there is one.
#
# Worth providing: fetching the mgr sources from GitHub cost 15 tool calls
# and ~$0.73 on a measured analysis, where grepping them on disk is a couple
# of calls. Falls back to the raw URLs when none of these exist, so this is
# an optimisation rather than a requirement.
#
# Bob reads these with shell commands rather than its own file tools, so the
# path does not have to be inside --workspace.
_bob_find_ceph_src() {
    [ -n "${BOB_CEPH_SRC:-}" ] && { printf '%s' "$BOB_CEPH_SRC"; return; }
    local candidate
    for candidate in \
        "$HOME/workspace/ceph" \
        /home/cephnvme/workspace/ceph \
        /opt/ceph-src
    do
        if [ -d "$candidate/src/pybind/mgr/dashboard" ]; then
            printf '%s' "$candidate"
            return
        fi
    done
    printf ''
}
BOB_CEPH_SRC="$(_bob_find_ceph_src)"

# How much of a response to hand over. Enough to see the error, not a whole
# JSON dump of every namespace.
BOB_MAX_OUTPUT_CHARS="${BOB_MAX_OUTPUT_CHARS:-1500}"

# Where to read the key from when the environment does not already carry it.
# Never the repository: see README, "Bob credentials".
BOB_KEY_FILE="${BOB_KEY_FILE:-/etc/gh_runner/bob.env}"

NVMEOF_REPO_URL="https://github.com/ceph/ceph-nvmeof"
CEPH_REPO_URL="https://github.com/ceph/ceph"
CEPH_RAW="https://raw.githubusercontent.com/ceph/ceph/main"

_BOB_ANALYSES=0
_BOB_SEEN=""
_BOB_UNAVAILABLE=""

#
# Pull the key out of BOB_KEY_FILE if the environment has none.
#
# The file is sourced rather than read so it can hold `BOBSHELL_API_KEY=...`,
# which is also what `env` and systemd EnvironmentFile expect.
#
_bob_load_key() {
    [ -n "${BOBSHELL_API_KEY:-}" ] && return 0
    [ -r "$BOB_KEY_FILE" ] || return 1
    # shellcheck source=/dev/null
    . "$BOB_KEY_FILE"
    [ -n "${BOBSHELL_API_KEY:-}" ]
}

#
# Is Bob usable at all? Answered once; the reason is reported once.
#
bob_available() {
    [ "$BOB_ENABLED" = "1" ] || return 1
    [ -n "$_BOB_UNAVAILABLE" ] && return 1

    if ! command -v "$BOB_CMD" > /dev/null 2>&1; then
        _BOB_UNAVAILABLE="not installed"
        warn "Bob analysis is on but '$BOB_CMD' is not on PATH; skipping it."
        warn "Install with: curl -fsSL https://bob.ibm.com/download/bobshell.sh | bash"
        return 1
    fi
    if ! _bob_load_key; then
        _BOB_UNAVAILABLE="no api key"
        warn "Bob analysis is on but no API key was found; skipping it."
        warn "Set BOBSHELL_API_KEY, or put it in $BOB_KEY_FILE."
        return 1
    fi
    return 0
}

#
# A short signature for a failure, so the same one is not paid for twice.
#
# Keyed on the ceph error line where there is one, falling back to the check
# description. The nqn and nsid are stripped: the same bug hit from three
# namespaces is one bug.
#
_bob_signature() {
    local desc="$1" err="$2" sig
    sig="$(printf '%s\n' "$err" | grep -m1 -E 'Error [A-Z0-9]+:' || true)"
    [ -n "$sig" ] || sig="$desc"
    printf '%s' "$sig" |
        sed -E 's/nqn\.[^ "]+/NQN/g; s/[0-9]+/N/g' |
        tr -d '\n'
}

_bob_truncate() {
    local text="$1"
    if [ "${#text}" -gt "$BOB_MAX_OUTPUT_CHARS" ]; then
        printf '%s\n[... truncated, %s characters total ...]' \
            "${text:0:$BOB_MAX_OUTPUT_CHARS}" "${#text}"
    else
        printf '%s' "$text"
    fi
}

#
# bob_analyze <description> <command> <stdout> <stderr> <exit status>
#
# Prints Bob's report to the transcript. Returns 0 whatever happens.
#
bob_analyze() {
    local desc="$1" cmd="$2" out="$3" err="$4" rc="$5"
    local sig prompt report status ceph_source

    bob_available || return 0

    if [ "$_BOB_ANALYSES" -ge "$BOB_MAX_ANALYSES" ]; then
        if [ "$_BOB_ANALYSES" -eq "$BOB_MAX_ANALYSES" ]; then
            _BOB_ANALYSES=$((_BOB_ANALYSES + 1))
            printf '    BOB: analysis budget for this suite is used up (%s); \n' \
                "$BOB_MAX_ANALYSES" >&3
            printf '         raise BOB_MAX_ANALYSES to see more.\n' >&3
        fi
        return 0
    fi

    if [ "$BOB_DEDUP" = "1" ]; then
        sig="$(_bob_signature "$desc" "$err")"
        case "$_BOB_SEEN" in
            *"<$sig>"*)
                printf '    BOB: same failure as one analysed earlier in this suite.\n' >&3
                return 0 ;;
        esac
        _BOB_SEEN="$_BOB_SEEN<$sig>"
    fi

    _BOB_ANALYSES=$((_BOB_ANALYSES + 1))

    if [ -n "$BOB_CEPH_SRC" ] && [ -d "$BOB_CEPH_SRC/src/pybind/mgr/dashboard" ]; then
        ceph_source="The ceph sources are on disk at $BOB_CEPH_SRC. Read them with shell
commands (grep, sed) -- that path is outside your workspace, so your file
tools will refuse it while execute_command will not. Do not fetch anything
over the network. The files that matter:
  $BOB_CEPH_SRC/src/pybind/mgr/dashboard/controllers/nvmeof.py
  $BOB_CEPH_SRC/src/pybind/mgr/dashboard/services/nvmeof_cli.py
  $BOB_CEPH_SRC/src/pybind/mgr/dashboard/services/nvmeof_client.py
  $BOB_CEPH_SRC/src/pybind/mgr/dashboard/model/nvmeof.py
  $BOB_CEPH_SRC/src/mon/NVMeofGwMon.cc
  $BOB_CEPH_SRC/src/mon/MonCommands.h"
    else
        ceph_source="The ceph side is not on disk. Fetch only what you need, straight from
these raw URLs -- do not search GitHub for them:
  $CEPH_RAW/src/pybind/mgr/dashboard/controllers/nvmeof.py
  $CEPH_RAW/src/pybind/mgr/dashboard/services/nvmeof_cli.py
  $CEPH_RAW/src/pybind/mgr/dashboard/services/nvmeof_client.py
  $CEPH_RAW/src/pybind/mgr/dashboard/model/nvmeof.py
  $CEPH_RAW/src/mon/NVMeofGwMon.cc
They are large: fetch with curl and grep rather than reading them whole."
    fi

    prompt="You are debugging a failed end-to-end test of the Ceph NVMe-oF CLI.

Suite:   ${SUITE_NAME:-unknown}
Check:   $desc
Command: $cmd
Exit:    $rc
Stdout:
$(_bob_truncate "$out")
Stderr:
$(_bob_truncate "$err")

The command is a ceph CLI call running inside the ceph container of a vstart
cluster. The gateway is ceph-nvmeof ($NVMEOF_REPO_URL, branch devel); the
'ceph nvmeof' commands are served by the dashboard mgr module and the
'ceph nvme-gw' commands by the monitor, both in $CEPH_REPO_URL, branch main.

Your workspace is a ceph-nvmeof checkout: read control/grpc.py,
control/utils.py, control/state.py and control/proto/gateway.proto from disk
rather than fetching them.

WHERE TO LOOK FIRST. The error text says which side produced it, so use this
before you go exploring:

  - The message contains 'Failure <verb>ing ...' -- for example 'Failure
    creating subsystem X: ...'. That wording comes from the gateway, which
    builds it in ceph-nvmeof control/grpc.py. Start in the workspace.
  - Anything else -- 'missing required parameter', 'Unexpected argument',
    \"not one of 'true', 'false'\", 'Can use X or Y but not both', 'Invalid
    sort-by', 'Gateway group does not exist' -- was raised before the request
    ever reached the gateway, by ceph's argument parser
    (src/pybind/ceph_argparse.py) or by the dashboard mgr module. Start in
    the ceph sources.

A wrong option name, a wrong type, a bad default, a missing required
argument or a mismatched output field is almost always the ceph side,
because that is where the 'ceph nvmeof' commands are defined. What the
gateway actually did with a valid request is the ceph-nvmeof side.

$ceph_source

BUDGET, and this matters more than thoroughness: you may run at most
$BOB_MAX_TOOL_CALLS shell commands. Count them. When you reach that number
you must stop looking and answer with whatever you have.

Returning no answer is the one unacceptable outcome -- it has happened twice,
burning the whole budget on exploration and reporting nothing. A short answer
that says 'probably X, unconfirmed' is worth far more than a thorough
investigation that never concludes. State your confidence rather than
chasing certainty.

Answer in under 150 words:

1. ROOT CAUSE: the specific reason this command failed. Name the file and
   function that produced the message where you can.
2. VERDICT: is this a TEST BUG (the test expects the wrong thing, uses a
   wrong option name or a wrong value) or a PRODUCT BUG (the gateway or the
   mgr module is wrong)? Say which, and why.
3. FIX: the concrete change. If it is a test bug, give the corrected command
   line.

Be concise and specific. Do not speculate: if the repositories do not settle
it, say what else you would need."

    printf '\n    BOB: analysing (%s/%s)...\n' "$_BOB_ANALYSES" "$BOB_MAX_ANALYSES" >&3

    # --trust: headless, in a checkout the job already owns.
    # The key is passed through the environment and never printed.
    report="$(timeout "$BOB_TIMEOUT" "$BOB_CMD" run \
        --accept-license \
        --trust \
        --log-level silent \
        --workspace "$BOB_WORKSPACE" \
        --max-turns "$BOB_MAX_TURNS" \
        --max-cost "$BOB_MAX_COST" \
        -f pretty \
        "$prompt" 2>&1)"
    status=$?

    # Running out of turns or budget exits 0 but answers nothing. Say so,
    # rather than printing a wall of tool calls and leaving the reader to
    # work out that there is no conclusion in it.
    case "$report" in
    *"reached the maximum of"*|*"maximum cost"*)
        printf '    BOB: ran out of budget before answering.\n' >&3
        printf '         Raise BOB_MAX_TURNS (now %s) or BOB_MAX_COST (now %s).\n' \
            "$BOB_MAX_TURNS" "$BOB_MAX_COST" >&3
        return 0 ;;
    esac

    if [ "$status" -ne 0 ]; then
        printf '    BOB: analysis failed (exit %s); the check result stands.\n' "$status" >&3
        [ "$status" -eq 124 ] &&
            printf '         timed out after %ss.\n' "$BOB_TIMEOUT" >&3
        [ -n "$report" ] && printf '%s\n' "$report" | tail -5 | sed 's/^/         /' >&3
        return 0
    fi

    printf '%s\n' "$BOBBAR" >&3
    printf 'BOB ANALYSIS: %s\n' "$desc" >&3
    printf '%s\n' "$BOBBAR" >&3
    printf '%s\n' "$report" | sed 's/^/    /' >&3
    printf '%s\n' "$BOBBAR" >&3
    return 0
}
