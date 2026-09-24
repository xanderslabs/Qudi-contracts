#!/usr/bin/env python3
"""The pinned regression-seed corpus.

Every fuzz seed a campaign has found failing is checked in permanently in
mutation/regression-seeds.json, so a fix for one regression cannot be silently
re-broken later while the nightly, unpinned `deep` job happens not to redraw
that exact seed. This script runs the full suite once per pinned seed under
FOUNDRY_PROFILE=deep and requires every one to pass.

This is deliberately the opposite policy from the nightly deep run, which stays
unpinned on purpose because its job is to keep searching, and from the mutation
gate, which pins one fixed seed as its own reproducible baseline. Three
different seed policies for three different jobs.

Usage: python3 script/regression_runner.py
Run from the repository root (or pass --root).
"""
import argparse
import json
import os
import subprocess
import sys
from pathlib import Path


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--root", default=".", help="repository root (default: cwd)")
    parser.add_argument(
        "--corpus", default=None,
        help="path to regression-seeds.json (default: <root>/mutation/regression-seeds.json)",
    )
    args = parser.parse_args()

    root = Path(args.root).resolve()
    corpus_path = Path(args.corpus).resolve() if args.corpus else root / "mutation" / "regression-seeds.json"
    corpus = json.loads(corpus_path.read_text())

    if not corpus:
        print("REFUSED: the regression corpus is empty. It starts with at least one seed.")
        return 2

    env = dict(os.environ)
    env["FOUNDRY_PROFILE"] = "deep"

    failed = []
    for entry in corpus:
        seed = entry["seed"]
        print(f"--- seed {seed} (found {entry.get('found', '?')}, {entry.get('found_by', '?')}) ---")
        proc = subprocess.run(
            ["forge", "test", "--fuzz-seed", seed],
            cwd=root, env=env, capture_output=True, text=True,
        )
        output = proc.stdout + proc.stderr
        tail = "\n".join(output.splitlines()[-15:])
        if proc.returncode == 0:
            print(f"PASS: {seed}")
        else:
            failed.append(seed)
            print(f"FAIL: {seed}")
            print(tail)

    print()
    print(f"Summary: {len(corpus) - len(failed)} of {len(corpus)} pinned seeds passed.")
    if failed:
        print("FAILED SEEDS (job fails):")
        for s in failed:
            print(f"  {s}")
        return 1

    print("Every pinned regression seed passed.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
