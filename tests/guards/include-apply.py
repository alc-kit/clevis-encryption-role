#!/usr/bin/env python3
"""A dynamic include that carries its OWN tags must also carry `apply:`.

THE FAILURE
    A tag written on an `include_tasks` / `include_role` task selects the INCLUDE
    and nothing inside it: under `--tags <x>` the include runs and every included
    task is skipped, and the run still exits 0. `tags: always` on the include is no
    exception — its contents do not run either. Measured (ansible-core, 2026-10-06):

        tag on the include, no apply:,  --tags feat   -> included tasks: NOT run
        tag inherited from a block,     --tags feat   -> included tasks: run
        tags: always on the include,    --tags other  -> included tasks: NOT run
        any of the above WITH apply:                  -> included tasks: run

    So only the first and third shapes are defects, and only they are flagged; a
    block's tags already reach the tasks an include inside it pulls in.

    In this role that made the README's documented `--tags prestage` install
    nothing, and `--tags provision` skip disk discovery, the disk assessment and
    the post-condition that proves the end state.

Self-tests both directions on every run before judging the real files.

Usage: python3 tests/guards/include-apply.py   (from the repo root)
"""
import sys
from pathlib import Path

import yaml

INCLUDES = ("ansible.builtin.include_tasks", "include_tasks",
            "ansible.builtin.include_role", "include_role")
SCAN = ("tasks", "handlers")


def offenders(tasks, where):
    """Self-tagged dynamic includes without apply:, recursing into blocks."""
    out = []
    for t in tasks or []:
        if not isinstance(t, dict):
            continue
        for k in ("block", "rescue", "always"):
            if k in t:
                out += offenders(t[k], where)
        for k in INCLUDES:
            if k in t and t.get("tags"):
                v = t[k]
                if not (isinstance(v, dict) and "apply" in v):
                    out.append(f"{where}: '{t.get('name', '(unnamed)')}' — {k} carries "
                               f"tags {t['tags']} but no apply:, so --tags runs none of "
                               f"the included tasks")
    return out


def self_test():
    bad = [{"name": "x", "ansible.builtin.include_tasks": "f.yml", "tags": ["p"]},
           {"name": "y", "include_tasks": "f.yml", "tags": "always"},
           {"block": [{"name": "z", "include_role": {"name": "r"}, "tags": ["p"]}]}]
    good = [{"name": "a", "ansible.builtin.include_tasks":
             {"file": "f.yml", "apply": {"tags": ["p"]}}, "tags": ["p"]},
            {"name": "b", "tags": ["p"], "block": [
                {"name": "c", "ansible.builtin.include_tasks": "f.yml"}]},
            {"name": "d", "ansible.builtin.include_tasks": "f.yml"}]
    problems = []
    if len(offenders(bad, "self-test")) != 3:
        problems.append(f"self-test: flagged {len(offenders(bad, 'self-test'))} of 3 bad includes")
    if offenders(good, "self-test"):
        problems.append(f"self-test: flagged a good include: {offenders(good, 'self-test')}")
    return problems


def main():
    root = Path(__file__).resolve().parents[2]
    problems = self_test()
    if problems:
        print("\n".join(f"FAIL  {p}" for p in problems))
        return 1
    found, scanned = [], 0
    for d in SCAN:
        for f in sorted((root / d).rglob("*.yml")):
            scanned += 1
            data = yaml.safe_load(f.read_text())
            if isinstance(data, list):
                found += offenders(data, str(f.relative_to(root)))
    for p in found:
        print(f"FAIL  {p}")
    if found:
        return 1
    print(f"include-apply: PASS — no self-tagged dynamic include lacks apply: "
          f"({scanned} file(s) scanned; self-test ok)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
