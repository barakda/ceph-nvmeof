#!/usr/bin/env python3
#
#  Copyright (c) 2025 International Business Machines
#  All rights reserved.
#
#  SPDX-License-Identifier: LGPL-3.0-or-later
#
"""Report which commands in CLI_MATRIX.md no gh_runner suite invokes.

This answers "is every command exercised somewhere", not "is every command
exercised well" -- it looks for the command being called, and says nothing
about whether the suite checks the result. Treat a 100% report as the floor,
not as a finish line.

    python3 tests/gh_runner/tools/check_coverage.py          # summary
    python3 tests/gh_runner/tools/check_coverage.py -v       # with the suites
    python3 tests/gh_runner/tools/check_coverage.py --strict # exit 1 on a gap

Run tools/gen_cli_matrix.py first if either CLI has changed.
"""

import argparse
import json
import os
import re
import sys
from typing import Dict, List

HERE = os.path.dirname(os.path.abspath(__file__))
GH_RUNNER = os.path.dirname(HERE)

# The shell helpers a suite reaches the cluster through.
WRAPPERS = r"(?:nvmeof_cmd|nvmeof_json|top_cmd|nvme_gw_cmd)"


def suite_sources() -> Dict[str, str]:
    """Every suite script, keyed by its path relative to tests/gh_runner."""
    out: Dict[str, str] = {}
    for root, _dirs, files in os.walk(GH_RUNNER):
        if os.path.basename(root) in ("tools", "lib"):
            continue
        for name in sorted(files):
            if not name.endswith(".sh"):
                continue
            path = os.path.join(root, name)
            with open(path, encoding="utf-8") as fh:
                out[os.path.relpath(path, GH_RUNNER)] = fh.read()
    return out


def words_to_match(command: str) -> List[str]:
    """The words a suite would actually type after the wrapper.

    `nvmeof top io` is reached through top_cmd, which already supplies the
    `top`, so that word is dropped. Everything else is matched in full.
    """
    parts = command.split()
    if parts and parts[0] == "top":
        return parts[1:]
    return parts


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("-v", "--verbose", action="store_true",
                    help="name the suites that invoke each command")
    ap.add_argument("--strict", action="store_true",
                    help="exit non-zero when something is uncovered")
    ap.add_argument("--matrix", default=os.path.join(GH_RUNNER, "cli_matrix.json"))
    args = ap.parse_args()

    if not os.path.exists(args.matrix):
        print(f"no matrix at {args.matrix}; run tools/gen_cli_matrix.py first",
              file=sys.stderr)
        return 2

    with open(args.matrix, encoding="utf-8") as fh:
        matrix = json.load(fh)
    ceph = matrix.get("ceph_nvmeof")
    if not ceph:
        print("the matrix has no ceph_nvmeof section", file=sys.stderr)
        return 2

    sources = suite_sources()
    if not sources:
        print("no suite scripts found", file=sys.stderr)
        return 2

    groups = [
        ("ceph nvmeof",
         [c["command"].removeprefix("nvmeof ") for c in ceph["commands"]]),
        ("ceph nvme-gw",
         [c["command"].removeprefix("nvme-gw ") for c in ceph.get("mon_commands", [])]),
    ]

    gaps = 0
    for title, commands in groups:
        covered: Dict[str, List[str]] = {}
        missing: List[str] = []
        for command in commands:
            pattern = re.compile(WRAPPERS + r"\s+" + r"\s+".join(
                re.escape(w) for w in words_to_match(command)))
            hits = sorted(name for name, text in sources.items() if pattern.search(text))
            if hits:
                covered[command] = hits
            else:
                missing.append(command)

        print(f"\n{title}: {len(covered)}/{len(commands)} commands invoked by a suite")
        if args.verbose:
            for command in sorted(covered):
                print(f"    {command:<44} {', '.join(covered[command])}")
        for command in missing:
            print(f"    NOT COVERED: {command}")
        gaps += len(missing)

    print()
    if gaps:
        print(f"{gaps} command(s) no suite invokes.")
        return 1 if args.strict else 0
    print("Every command in the matrix is invoked by at least one suite.")
    print("That is the floor, not the finish line: it says nothing about how "
          "well each one is checked.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
