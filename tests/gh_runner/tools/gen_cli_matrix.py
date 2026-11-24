#!/usr/bin/env python3
#
#  Copyright (c) 2025 International Business Machines
#  All rights reserved.
#
#  SPDX-License-Identifier: LGPL-3.0-or-later
#
"""Generate the NVMe-oF CLI command/option matrix.

Two CLIs expose the gateway control plane and both must be covered by the
gh_runner suites:

  1. ``nvmeof-cli`` (this repo, ``control/cli.py``).  Extracted by *importing*
     the module and walking the live ``argparse`` tree, so the output cannot
     drift from the real parser.

  2. ``ceph nvmeof ...`` (ceph repo, ``src/pybind/mgr/dashboard``).  Extracted
     by parsing the AST for ``@NvmeofCLICommand(...)`` decorators and the
     signature of the function each one decorates.  The ceph mgr framework
     turns every keyword parameter into a ``--kebab-case`` option, so the
     signature *is* the option list.

Running it::

    python3 tests/gh_runner/tools/gen_cli_matrix.py \
        --ceph-repo /path/to/ceph \
        --out-dir tests/gh_runner

Importing ``control.cli`` needs the generated protobuf stubs; create them with
``make protoc`` (or ``python -m grpc_tools.protoc``) first.  Pass
``--skip-nvmeof-cli`` to generate only the ceph half without them.
"""

import argparse
import ast
import json
import os
import sys
from typing import Any, Dict, List, Optional

REPO_ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", "..", ".."))

CEPH_CLI_SOURCES = (
    "src/pybind/mgr/dashboard/controllers/nvmeof.py",
    "src/pybind/mgr/dashboard/services/nvmeof_top_cli.py",
    "src/pybind/mgr/dashboard/services/nvmeof_cli.py",
)
CEPH_MON_COMMANDS = "src/mon/MonCommands.h"


# ---------------------------------------------------------------------------
# nvmeof-cli (this repo): live argparse introspection
# ---------------------------------------------------------------------------

def _format_argparse_type(action) -> str:
    t = getattr(action, "type", None)
    if t is None:
        if action.__class__.__name__ in ("_StoreTrueAction", "_StoreFalseAction"):
            return "flag"
        return "str"
    if type(t).__name__ == "FileType":
        return "path"
    name = getattr(t, "__name__", None)
    if name in ("lower", "upper"):
        # argparse `type=str.lower` / `str.upper`
        return "str"
    if name:
        return name
    return str(t)


def _format_choices(action) -> str:
    choices = getattr(action, "choices", None)
    if not choices:
        return ""
    # The CLI registers both the lower and the upper spelling of every enum
    # key; collapse them so the table stays readable.
    seen: List[str] = []
    for c in choices:
        c = str(c)
        if c.lower() not in [s.lower() for s in seen]:
            seen.append(c.lower())
    return ",".join(seen)


def _collect_arguments(parser) -> List[Dict[str, Any]]:
    args: List[Dict[str, Any]] = []
    for action in parser._actions:
        if action.__class__.__name__ in ("_HelpAction", "_SubParsersAction"):
            continue
        args.append({
            "flags": list(action.option_strings) or [action.dest],
            "dest": action.dest,
            "required": bool(getattr(action, "required", False)),
            "type": _format_argparse_type(action),
            "nargs": action.nargs if action.nargs is not None else "",
            "choices": _format_choices(action),
            "default": "" if action.default is None else str(action.default),
            "help": " ".join((action.help or "").split()),
        })
    return args


def _subparsers_action(parser):
    for action in parser._actions:
        if action.__class__.__name__ == "_SubParsersAction":
            return action
    return None


def _subparser_entries(action) -> List[Dict[str, Any]]:
    """Return one entry per distinct subparser, with its aliases grouped."""
    by_id: Dict[int, Dict[str, Any]] = {}
    for name, sub in action.choices.items():
        entry = by_id.setdefault(id(sub), {"names": [], "parser": sub})
        entry["names"].append(name)
    out = []
    for entry in by_id.values():
        names = entry["names"]
        out.append({
            "name": names[0],
            "aliases": names[1:],
            "parser": entry["parser"],
        })
    return out


def extract_nvmeof_cli(repo_root: str) -> Dict[str, Any]:
    sys.path.insert(0, repo_root)
    sys.path.insert(0, os.path.join(repo_root, "control", "proto"))
    import control.cli as control_cli  # noqa: E402

    root = control_cli.GatewayClient.cli.parser
    result: Dict[str, Any] = {
        "global_options": _collect_arguments(root),
        "commands": [],
    }

    top = _subparsers_action(root)
    for cmd in _subparser_entries(top):
        cmd_parser = cmd["parser"]
        actions_action = _subparsers_action(cmd_parser)
        entry = {
            "command": cmd["name"],
            "aliases": cmd["aliases"],
            "help": " ".join((cmd_parser.description or "").split()),
            "actions": [],
        }
        # `cli.cmd()` always adds a subparsers action, but leaf commands such as
        # `version` register no actions under it.
        if actions_action is None or not actions_action.choices:
            entry["actions"].append({
                "action": "",
                "aliases": [],
                "help": entry["help"],
                "options": _collect_arguments(cmd_parser),
            })
        else:
            for act in _subparser_entries(actions_action):
                entry["actions"].append({
                    "action": act["name"],
                    "aliases": act["aliases"],
                    "help": " ".join((act["parser"].description or "").split()),
                    "options": _collect_arguments(act["parser"]),
                })
        entry["actions"].sort(key=lambda a: a["action"])
        result["commands"].append(entry)

    result["commands"].sort(key=lambda c: c["command"])
    return result


# ---------------------------------------------------------------------------
# ceph nvmeof (ceph repo): AST extraction
# ---------------------------------------------------------------------------

def _unparse(node: Optional[ast.AST]) -> str:
    if node is None:
        return ""
    try:
        return ast.unparse(node)
    except Exception:  # pragma: no cover - defensive
        return "?"


def _simplify_annotation(text: str) -> str:
    text = text.replace("typing.", "")
    if text.startswith("Optional[") and text.endswith("]"):
        text = text[len("Optional["):-1]
    return text


def _decorator_calls(node: ast.FunctionDef, name: str) -> List[ast.Call]:
    out = []
    for dec in node.decorator_list:
        if isinstance(dec, ast.Call):
            func = dec.func
            if isinstance(func, ast.Name) and func.id == name:
                out.append(dec)
            elif isinstance(func, ast.Attribute) and func.attr == name:
                out.append(dec)
    return out


def _grpc_calls(node: ast.FunctionDef) -> List[str]:
    """Which gateway gRPC methods the handler ends up calling."""
    found: List[str] = []
    for sub in ast.walk(node):
        if not isinstance(sub, ast.Call):
            continue
        func = sub.func
        if not isinstance(func, ast.Attribute):
            continue
        owner = func.value
        # NVMeoFClient(...).stub.<method>(...)  /  <x>.stub.<method>(...)
        if isinstance(owner, ast.Attribute) and owner.attr == "stub":
            if func.attr not in found:
                found.append(func.attr)
    return found


def _function_params(node: ast.FunctionDef) -> List[Dict[str, Any]]:
    a = node.args
    positional = list(a.posonlyargs) + list(a.args)
    defaults: List[Optional[ast.AST]] = [None] * (len(positional) - len(a.defaults))
    defaults += list(a.defaults)

    params: List[Dict[str, Any]] = []

    def describe(arg: ast.arg, default: Optional[ast.AST]) -> Dict[str, Any]:
        type_name = _simplify_annotation(_unparse(arg.annotation)) or "str"
        flag = "--" + arg.arg.replace("_", "-")
        # ceph's parser does not take the next token as the value of a
        # CephBool keyword, so a bool option has to be spelled `--flag=value`
        # (or bare `--flag`, meaning true). Spell it that way in the table so
        # it does not get copied out of here in the broken form.
        if type_name == "bool":
            flag += "=<bool>"
        return {
            "name": arg.arg,
            "flag": flag,
            "type": type_name,
            "required": default is None,
            "default": _unparse(default),
        }

    for arg, default in zip(positional, defaults):
        if arg.arg in ("self", "cls", "_"):
            continue
        params.append(describe(arg, default))
    for arg, default in zip(a.kwonlyargs, a.kw_defaults):
        params.append(describe(arg, default))
    return params


def _dbclicommand_name(node: ast.FunctionDef) -> Optional[str]:
    """`@DBCLICommand.Read('nvmeof top io', ...)` -> the command string."""
    for dec in node.decorator_list:
        if not isinstance(dec, ast.Call) or not dec.args:
            continue
        func = dec.func
        if not (isinstance(func, ast.Attribute) and func.attr in ("Read", "Write")):
            continue
        if not (isinstance(func.value, ast.Name) and func.value.id == "DBCLICommand"):
            continue
        return _unparse(dec.args[0]).strip("'\"")
    return None


def extract_ceph_nvmeof(ceph_repo: str) -> Dict[str, Any]:
    commands: List[Dict[str, Any]] = []
    dashboard: List[Dict[str, Any]] = []

    for rel in CEPH_CLI_SOURCES:
        path = os.path.join(ceph_repo, rel)
        if not os.path.exists(path):
            raise SystemExit(f"missing ceph source: {path}")
        with open(path, encoding="utf-8") as fh:
            tree = ast.parse(fh.read(), filename=path)

        for node in ast.walk(tree):
            if not isinstance(node, (ast.FunctionDef, ast.AsyncFunctionDef)):
                continue

            # The REST controllers: @NvmeofCLICommand("nvmeof ...", model, alias=...)
            for dec in _decorator_calls(node, "NvmeofCLICommand"):
                if not dec.args:
                    continue
                alias = ""
                for kw in dec.keywords:
                    if kw.arg == "alias":
                        alias = _unparse(kw.value).strip("'\"")
                commands.append({
                    "command": _unparse(dec.args[0]).strip("'\""),
                    "alias": alias,
                    "source": rel,
                    "handler": node.name,
                    "grpc": _grpc_calls(node),
                    "options": _function_params(node),
                })

            # Plain mgr commands: `nvmeof top ...` and `dashboard nvmeof-*`.
            name = _dbclicommand_name(node)
            if not name or "nvmeof" not in name:
                continue
            entry = {
                "command": name,
                "alias": "",
                "source": rel,
                "handler": node.name,
                "grpc": _grpc_calls(node),
                "options": [p for p in _function_params(node) if p["name"] != "inbuf"],
            }
            (commands if name.startswith("nvmeof ") else dashboard).append(entry)

    commands.sort(key=lambda c: c["command"])
    dashboard.sort(key=lambda c: c["command"])
    return {
        "commands": commands,
        "dashboard_commands": dashboard,
        "mon_commands": extract_ceph_mon_commands(ceph_repo),
    }


def extract_ceph_mon_commands(ceph_repo: str) -> List[Dict[str, Any]]:
    """`ceph nvme-gw ...` monitor commands, from src/mon/MonCommands.h."""
    path = os.path.join(ceph_repo, CEPH_MON_COMMANDS)
    if not os.path.exists(path):
        return []
    with open(path, encoding="utf-8") as fh:
        text = fh.read()

    out: List[Dict[str, Any]] = []
    for pos in _find_all(text, 'COMMAND("nvme-gw'):
        args = _c_call_args(text, pos + len("COMMAND"))
        if not args:
            continue
        spec, desc = args[0], (args[1] if len(args) > 1 else "")

        parts = [p for p in spec.split(" name=") if p.strip()]
        opts = []
        for part in parts[1:]:
            fields = part.strip().split(",")
            meta = dict(f.split("=", 1) for f in fields[1:] if "=" in f)
            opts.append({
                "name": fields[0],
                "type": meta.get("type", "CephString").replace("Ceph", "").lower(),
                "required": meta.get("req", "true") != "false",
                "choices": meta.get("strings", ""),
            })
        command = " ".join(parts[0].split())
        usage = " ".join(
            [command] + [f"<{o['name']}>" if o["required"] else f"[{o['name']}]" for o in opts])
        out.append({
            "command": command,
            "usage": usage,
            "help": " ".join(desc.split()),
            "options": opts,
        })
    out.sort(key=lambda c: c["command"])
    return out


def _find_all(text: str, needle: str) -> List[int]:
    out, pos = [], text.find(needle)
    while pos != -1:
        out.append(pos)
        pos = text.find(needle, pos + 1)
    return out


def _c_call_args(text: str, open_paren: int) -> List[str]:
    """Split a C call's arguments, concatenating adjacent string literals."""
    assert text[open_paren] == "("
    args: List[str] = []
    current = ""
    depth = 1
    i = open_paren + 1
    while i < len(text) and depth > 0:
        ch = text[i]
        if ch == '"':
            j = i + 1
            while j < len(text) and text[j] != '"':
                j += 2 if text[j] == "\\" else 1
            current += text[i + 1:j]
            i = j + 1
            continue
        if ch in "([{":
            depth += 1
        elif ch in ")]}":
            depth -= 1
            if depth == 0:
                break
        elif ch == "," and depth == 1:
            args.append(current)
            current = ""
        i += 1
    args.append(current)
    return args


# ---------------------------------------------------------------------------
# Rendering
# ---------------------------------------------------------------------------

def _md_escape(text: str) -> str:
    return text.replace("|", "\\|")


def render_nvmeof_cli(data: Dict[str, Any]) -> List[str]:
    out = ["## `nvmeof-cli` (ceph-nvmeof, `control/cli.py`)", ""]
    out.append("Invocation: `nvmeof-cli [global options] <command> <action> [options]`.")
    out.append("")
    out.append("### Global options")
    out.append("")
    out.append("| Option | Type | Choices | Default | Description |")
    out.append("| --- | --- | --- | --- | --- |")
    for opt in data["global_options"]:
        out.append("| `{}` | {} | {} | {} | {} |".format(
            "`, `".join(opt["flags"]), opt["type"],
            _md_escape(opt["choices"]) or "-",
            _md_escape(opt["default"]) or "-",
            _md_escape(opt["help"]) or "-"))
    out.append("")

    for cmd in data["commands"]:
        title = f"### `{cmd['command']}`"
        if cmd["aliases"]:
            title += " (alias: " + ", ".join(f"`{a}`" for a in cmd["aliases"]) + ")"
        out.append(title)
        if cmd["help"]:
            out.append("")
            out.append(cmd["help"])
        out.append("")
        out.append("| Action | Option | Req | Type | Choices | Description |")
        out.append("| --- | --- | --- | --- | --- | --- |")
        for act in cmd["actions"]:
            label = act["action"] or "-"
            if act["aliases"]:
                label += " (" + ", ".join(act["aliases"]) + ")"
            if not act["options"]:
                out.append(f"| `{label}` | _(none)_ |  |  |  | {_md_escape(act['help'])} |")
                continue
            first = True
            for opt in act["options"]:
                out.append("| {} | `{}` | {} | {} | {} | {} |".format(
                    f"`{label}`" if first else "",
                    "`, `".join(opt["flags"]),
                    "yes" if opt["required"] else "",
                    opt["type"] + (f" ({opt['nargs']})" if opt["nargs"] else ""),
                    _md_escape(opt["choices"]) or "",
                    _md_escape(opt["help"])))
                first = False
        out.append("")
    return out


def render_ceph_cli(data: Dict[str, Any]) -> List[str]:
    out = ["## `ceph nvmeof ...` (ceph mgr/dashboard)", ""]
    out.append("Invocation: `ceph nvmeof [--format json|plain|yaml] <command> [--option value]`.")
    out.append("")
    out.append("Every keyword parameter of the handler becomes a `--kebab-case` option; "
               "`--gw-group` / `--server-address` select which gateway answers.")
    out.append("")

    groups: Dict[str, List[Dict[str, Any]]] = {}
    for cmd in data["commands"]:
        key = cmd["command"].split()[1] if len(cmd["command"].split()) > 1 else "(root)"
        groups.setdefault(key, []).append(cmd)

    for key in sorted(groups):
        out.append(f"### `ceph nvmeof {key} ...`")
        out.append("")
        out.append("| Command | Alias | Option | Req | Type | Default | gRPC |")
        out.append("| --- | --- | --- | --- | --- | --- | --- |")
        for cmd in groups[key]:
            grpc = ", ".join(f"`{g}`" for g in cmd["grpc"]) or "-"
            if not cmd["options"]:
                out.append("| `{}` | {} | _(none)_ |  |  |  | {} |".format(
                    cmd["command"], f"`{cmd['alias']}`" if cmd["alias"] else "-", grpc))
                continue
            first = True
            for opt in cmd["options"]:
                out.append("| {} | {} | `{}` | {} | {} | {} | {} |".format(
                    f"`{cmd['command']}`" if first else "",
                    (f"`{cmd['alias']}`" if cmd["alias"] else "-") if first else "",
                    opt["flag"],
                    "yes" if opt["required"] else "",
                    _md_escape(opt["type"]),
                    _md_escape(opt["default"]) or "-",
                    grpc if first else ""))
                first = False
        out.append("")

    if data.get("mon_commands"):
        out.append("### `ceph nvme-gw ...` (monitor, `src/mon/MonCommands.h`)")
        out.append("")
        out.append("Gateway membership and HA state live in the monitor, not in the gateway; "
                   "these are what the HA/failover suites drive. Arguments are positional "
                   "(`ceph nvme-gw show rbd ''`); `<x>` is required, `[x]` optional.")
        out.append("")
        out.append("| Usage | Argument | Req | Type | Choices | Description |")
        out.append("| --- | --- | --- | --- | --- | --- |")
        for cmd in data["mon_commands"]:
            if not cmd["options"]:
                out.append("| `ceph {}` | _(none)_ |  |  |  | {} |".format(
                    cmd["command"], _md_escape(cmd["help"])))
                continue
            first = True
            for opt in cmd["options"]:
                out.append("| {} | `{}` | {} | {} | {} | {} |".format(
                    f"`ceph {cmd['usage']}`" if first else "",
                    opt["name"], "yes" if opt["required"] else "",
                    opt["type"], _md_escape(opt["choices"]) or "",
                    _md_escape(cmd["help"]) if first else ""))
                first = False
        out.append("")

    if data["dashboard_commands"]:
        out.append("### `ceph dashboard nvmeof-*` (gateway registration)")
        out.append("")
        out.append("| Command | Option | Req | Type | Default |")
        out.append("| --- | --- | --- | --- | --- |")
        for cmd in data["dashboard_commands"]:
            if not cmd["options"]:
                out.append(f"| `{cmd['command']}` | _(none)_ |  |  |  |")
                continue
            first = True
            for opt in cmd["options"]:
                out.append("| {} | `{}` | {} | {} | {} |".format(
                    f"`{cmd['command']}`" if first else "",
                    opt["flag"], "yes" if opt["required"] else "",
                    _md_escape(opt["type"]), _md_escape(opt["default"]) or "-"))
                first = False
        out.append("")
    return out


def render_crossref(nvmeof: Dict[str, Any], ceph: Dict[str, Any]) -> List[str]:
    """Which verbs exist on one CLI but not the other."""
    local = set()
    for cmd in nvmeof["commands"]:
        for act in cmd["actions"]:
            local.add(f"{cmd['command']} {act['action']}".strip())
    remote = {c["command"].removeprefix("nvmeof ").strip() for c in ceph["commands"]}

    out = ["## Cross-reference: `nvmeof-cli` vs `ceph nvmeof`", ""]
    out.append("Matched on `<command> <action>`. A verb present on only one side still needs "
               "coverage -- it is simply driven through that one CLI.")
    out.append("")
    out.append("| Verb | `nvmeof-cli` | `ceph nvmeof` |")
    out.append("| --- | --- | --- |")
    for verb in sorted(local | remote):
        out.append("| `{}` | {} | {} |".format(
            verb, "yes" if verb in local else "-", "yes" if verb in remote else "-"))
    out.append("")
    return out


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--ceph-repo", help="path to a ceph.git checkout")
    ap.add_argument("--nvmeof-repo", default=REPO_ROOT, help="path to this ceph-nvmeof checkout")
    ap.add_argument("--out-dir", default=os.path.join(REPO_ROOT, "tests", "gh_runner"))
    ap.add_argument("--skip-nvmeof-cli", action="store_true")
    args = ap.parse_args()

    payload: Dict[str, Any] = {}
    body: List[str] = []

    if not args.skip_nvmeof_cli:
        nvmeof = extract_nvmeof_cli(args.nvmeof_repo)
        payload["nvmeof_cli"] = nvmeof
        body += render_nvmeof_cli(nvmeof)

    if args.ceph_repo:
        ceph = extract_ceph_nvmeof(args.ceph_repo)
        payload["ceph_nvmeof"] = ceph
        body += render_ceph_cli(ceph)

    if "nvmeof_cli" in payload and "ceph_nvmeof" in payload:
        body += render_crossref(payload["nvmeof_cli"], payload["ceph_nvmeof"])

    os.makedirs(args.out_dir, exist_ok=True)
    json_path = os.path.join(args.out_dir, "cli_matrix.json")
    with open(json_path, "w", encoding="utf-8") as fh:
        json.dump(payload, fh, indent=2, sort_keys=True)
        fh.write("\n")

    md_path = os.path.join(args.out_dir, "CLI_MATRIX.md")
    header = [
        "# NVMe-oF CLI command matrix",
        "",
        "Generated by `tests/gh_runner/tools/gen_cli_matrix.py` -- do not edit by hand.",
        "",
    ]
    counts = []
    if "nvmeof_cli" in payload:
        n = sum(len(c["actions"]) for c in payload["nvmeof_cli"]["commands"])
        counts.append(f"`nvmeof-cli`: {len(payload['nvmeof_cli']['commands'])} commands, "
                      f"{n} actions")
    if "ceph_nvmeof" in payload:
        counts.append(f"`ceph nvmeof`: {len(payload['ceph_nvmeof']['commands'])} commands")
        counts.append(f"`ceph nvme-gw`: {len(payload['ceph_nvmeof']['mon_commands'])} commands")
        counts.append("`ceph dashboard nvmeof-*`: "
                      f"{len(payload['ceph_nvmeof']['dashboard_commands'])} commands")
    if counts:
        header.append("Coverage surface: " + "; ".join(counts) + ".")
        header.append("")

    with open(md_path, "w", encoding="utf-8") as fh:
        fh.write("\n".join(header + body).rstrip() + "\n")

    print(f"wrote {md_path}")
    print(f"wrote {json_path}")
    for line in counts:
        print("  " + line)
    return 0


if __name__ == "__main__":
    sys.exit(main())
