# gh_runner suites

End-to-end tests that drive the **ceph-side** NVMe-oF CLIs against a real
cluster on the self-hosted GitHub runner:

- `ceph nvmeof ...` — 62 commands, served by the dashboard mgr module
- `ceph nvme-gw ...` — 12 monitor commands for gateway membership and HA state

They deliberately do **not** use ceph-nvmeof's own `nvmeof-cli`. The two CLIs
are close to 1:1 (see [CLI_MATRIX.md](CLI_MATRIX.md)), and `nvmeof-cli` is
already covered by the pytest suites under `tests/`.

`CLI_MATRIX.md` is the coverage target: every command and option in it should
end up exercised by a suite here.

## Layout

    tests/gh_runner/
      run.sh                 entry point
      CLI_MATRIX.md          the command/option table (generated)
      cli_matrix.json        the same, machine-readable
      tools/
        gen_cli_matrix.py    regenerates both
      lib/
        common.sh            output formatting and assertions
        cluster.sh           talking to the cluster; `ceph nvmeof` setup
      <shape>/
        shape.env            how many gateways this shape needs
        <noun>/              one directory per CLI noun
          NNN_topic.sh

A **shape** is a cluster configuration. A **suite** is a directory of scripts
covering one CLI noun. Scripts run in filename order, which is what the `NNN_`
prefix is for.

| Shape | Gateways | For |
| --- | --- | --- |
| `single_gw` | 1 | Everything that does not need a second gateway |
| `multi_gw` | 2 | Load balancing groups, per-gateway listeners, `ceph nvme-gw` HA |
| `secure` | 1 | DH-HMAC-CHAP, PSK, secure listeners, KMIP endpoints |

`secure` has the same cluster as `single_gw`. It is separate because its
suites leave authentication turned on while they run, which would break the
unauthenticated suites sharing a cluster with them.

## Running

    ./tests/gh_runner/run.sh single_gw              # every suite of a shape
    ./tests/gh_runner/run.sh single_gw/subsystem    # one suite
    ./tests/gh_runner/run.sh single_gw/subsystem/010_add_del.sh

`run.sh` starts the cluster, enables `ceph nvmeof`, runs the scripts, and
prints a per-suite summary. It does not tear the cluster down, so that CI can
copy the ceph logs out afterwards.

| Variable | Effect |
| --- | --- |
| `GH_RUNNER_NO_CLUSTER=1` | Use the cluster that is already running |
| `GH_RUNNER_TEARDOWN=1` | `docker compose down` on exit |

A suite named explicitly always runs, even when `SHAPE_SKIP` in `shape.env`
excludes it from the whole-shape expansion. That is how `single_gw/qos` — the
half-hour fio soak — stays out of the CLI job.

## Reading the output

Every command is traced on its own line, followed by what the machine said
back, then the verdict, and — when it failed — why:

```
>>> CMD: docker compose exec -T ceph ceph nvmeof subsystem add --nqn nqn.2016-06.io.spdk:x_y --server-address 192.168.13.3
<<< OUT (exit 22):
    [stderr] Error EINVAL: Invalid NQN "nqn.2016-06.io.spdk:x_y", contains invalid characters
❌ subsystem add with only --nqn
   exit status 22
    ROOT CAUSE: A name contains "_". Names become OMAP key elements, where "_" is
                the delimiter, so GatewayState.is_key_element_valid() rejects them.
                Use "-" instead.
```

The `>>> CMD:` line is the whole command, `docker compose exec` prefix and
all, so it can be copied straight out of the console and pasted into a shell
at the repository root — no editing, no guessing at the gateway address.
Arguments are quoted where they need to be, so something like
`--model-name "gh runner model"` survives the round trip as one argument.

It is also built from the argv that actually runs, rather than being written
out a second time next to it, so the line cannot drift from what happened.

`grep '>>> CMD:'` over a run is the list of commands it covered:

```bash
grep '>>> CMD:' ci.log | sed 's/.*ceph nvmeof /ceph nvmeof /' | sort -u
grep -E '^(✅|❌)' ci.log                          # every verdict
grep -A3 'ROOT CAUSE' ci.log                      # the failures, explained
```

The trace goes to file descriptor 3, not stdout, so that `out=$(nvmeof_json
...)` and `cmd 2>&1` cannot swallow it into a value being captured. The
`WARNING: all dangerous and experimental features are enabled` line that
vstart prints on every single ceph call is filtered out of stderr.

`ROOT CAUSE` is best effort. `diagnose()` in `lib/common.sh` matches error
text that has actually come out of this stack; when nothing matches it echoes
the `Error EXXX:` line rather than guessing, because a confident wrong cause
is worse than none. Add a case there when you hit a new one.

## Running the commands by hand

`nvmeof_cmd` and friends are shell functions, not programs — they do not exist
until something sources them, which is why `nvmeof_cmd gw info` at a bare
prompt gives "command not found". Against a cluster that is already up:

```bash
source tests/gh_runner/shell.sh      # from the repository root
nvmeof_cmd gateway info
nvmeof_json subsystem list | json_get '.subsystems[].nqn'
nvme_gw_cmd show rbd ''
```

Nothing requires the helpers, though. Each is a thin wrapper, and the
`>>> CMD:` line in the log is already the complete command — copy it out of
the console and run it as is:

```bash
docker compose exec -T ceph ceph nvmeof gateway info --server-address 192.168.13.3
```

Or get a shell in the ceph container and drop the prefix from the rest:

```bash
docker compose exec ceph bash
ceph nvmeof gateway info --server-address 192.168.13.3
```

## Writing a suite

```bash
#!/bin/bash
set -u -o pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$HERE/lib/common.sh"
source "$HERE/lib/cluster.sh"

suite_begin "subsystem/030_example"

suite_cleanup() { suite_cleanup_subsystems; }
trap suite_exit EXIT

NQN="$(suite_nqn example)"

assert_ok "subsystem add" nvmeof_cmd subsystem add --nqn "$NQN" --no-group-append
assert_eq "$NQN" "$(nvmeof_json subsystem get --nqn "$NQN" |
    json_get '.subsystems[0].nqn')" "subsystem get returns it"
```

Rules that the harness depends on:

- **Clean up after yourself.** Suites of one shape share a cluster. Create
  only resources whose name contains `$SUITE_PREFIX` (use `suite_nqn`), and
  remove them in `suite_cleanup`.
- **Restore global state.** Gateway log level, SPDK log flags and the IO
  statistics mode are gateway-wide. Read the old value first and put it back.
- **`trap suite_exit EXIT`, never `trap finish EXIT`.** Bash discards the
  status a trap *returns*; `suite_exit` calls `exit` explicitly. Without it a
  suite with failed checks exits 0 and CI calls it green.
- **A failed assertion does not stop the suite.** That is deliberate: one job
  should report every problem it can find. Use `die` only when the environment
  is broken and the verdict would be meaningless.

### Assertions

`assert_ok`, `assert_fails`, `assert_eq`, `assert_ne`, `assert_ge`,
`assert_contains`, `assert_not_contains`, and `wait_until <seconds> <cmd...>`
for state that is not visible on the next read.

### Talking to the cluster

`nvmeof_cmd` / `nvmeof_json` run `ceph nvmeof ...` against the gateway chosen
by `use_gateway`; `nvme_gw_cmd` runs `ceph nvme-gw ...` (positional arguments,
not flags); `ceph_cmd` runs anything else. `json_get <jq filter>` reads JSON on
stdin, falling back to the jq inside the ceph container when the host has none.

### Two things that will bite you

**Boolean options need `--flag=value`.** Ceph's parser does not take the
following token as the value of a `CephBool` keyword: `--enabled true` sets
`enabled` to true and *then* fails on a stray positional `true` — which looks
like a rejected option but is not. Bare `--flag` also means true. This applies
only where the handler annotates the parameter `bool`; `CLI_MATRIX.md` spells
those as `--flag=<bool>`. `subsystem del --force` is a `str`, so `--force true`
is right there.

**`--format json` returns the raw response, not the pretty table.** The keys
are the model's fields from ceph's `mgr/dashboard/model/nvmeof.py`. Lists are
nested (`.subsystems[0].nqn`) even for `subsystem get`, which returns a
one-element list. Gateway-side sets — network masks, for one — come back in no
particular order, so check membership and count, never position.

## How `ceph nvmeof` gets enabled

`Dockerfile.ceph` starts vstart with `--without-dashboard`, so the dashboard
mgr module — which is what registers every `ceph nvmeof` command — is off in
the compose cluster. The image does ship `ceph-mgr-dashboard` and
`python3-grpcio`, so no rebuild is needed; `nvmeof_cli_setup` in `lib/cluster.sh`
enables the module at runtime and registers each running gateway with
`ceph dashboard nvmeof-gateway-add`. `run.sh` calls it once per cluster.

Two limits follow from there being no orchestrator in this cluster:

- Every gateway is registered under **one** service name. The dashboard's
  `_get_default_service()` raises as soon as two service names exist and no
  orchestrator can disambiguate them, so gateways differ only by
  `daemon_name`, and `--server-address` is what selects one.
- `--gw-group` cannot really resolve a group: without an orchestrator it falls
  back to the default service. Multi-group behaviour is not testable here.
- mTLS between the mgr and the gateway is not testable either — the dashboard
  only enables it when the orchestrator reports `enable_auth` on the service.

## Regenerating the matrix

```bash
make protoc                     # gen_cli_matrix.py imports control.cli
python3 tests/gh_runner/tools/gen_cli_matrix.py --ceph-repo /path/to/ceph
```

The table is extracted, never hand-written: `nvmeof-cli` by walking the live
`argparse` tree, `ceph nvmeof` from the `@NvmeofCLICommand` decorators and
handler signatures, `ceph nvme-gw` from `src/mon/MonCommands.h`. Re-run it when
either repo changes and commit the result.
