#!/usr/bin/env bash
# `forge build --sizes` only fails once a contract exceeds EIP-170's
# 24,576-byte runtime limit. CreditCore hit that wall once already and keeps growing (the yield
# engine, then surplus distribution, pause paths, and migration). This gate fails CI when
# any DEPLOYABLE contract's runtime margin is inside the warning threshold below, not only
# when it is negative, so the next task that grows a contract too far gets two tasks of
# warning instead of a build that will not deploy.
#
# Scope matches `forge build --sizes` itself: only `contract`/`abstract contract` names
# declared under src/ are checked. Test harnesses and mocks (e.g. CreditCoreHarness) are
# deliberately oversized test scaffolding, never deployed outside
# Foundry's own EVM, and `forge build --sizes`'s own pass/fail already exempts them; this gate
# does the same rather than inventing a stricter rule than the tool it wraps.
set -euo pipefail

THRESHOLD_BYTES="${SIZE_GATE_THRESHOLD_BYTES:-2000}"

forge build --sizes --json 2>/dev/null | THRESHOLD_BYTES="$THRESHOLD_BYTES" python3 -c '
import json, os, re, subprocess, sys

threshold = int(os.environ["THRESHOLD_BYTES"])
sizes = json.load(sys.stdin)

deployable = set()
pattern = re.compile(r"^(?:abstract )?contract ([A-Za-z0-9_]+)")
result = subprocess.run(["grep", "-rhoE", r"^(abstract )?contract [A-Za-z0-9_]+", "src", "--include=*.sol"],
                         capture_output=True, text=True)
for line in result.stdout.splitlines():
    m = pattern.match(line)
    if m:
        deployable.add(m.group(1))

failed = False
for name in sorted(deployable):
    if name not in sizes:
        continue
    margin = sizes[name]["runtime_margin"]
    if margin < threshold:
        print(f"SIZE GATE: {name} is {margin} bytes from EIP-170s 24,576-byte limit (threshold: {threshold})")
        failed = True

if failed:
    print("")
    print(f"One or more contracts are within {threshold} bytes of EIP-170. Reduce size or plan a follow-up before this hits the hard limit.")
    sys.exit(1)

print(f"All deployable contracts have at least {threshold} bytes of runtime margin under EIP-170.")
'
