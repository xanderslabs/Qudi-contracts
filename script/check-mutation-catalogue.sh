#!/usr/bin/env bash
# Every catalogued entry in mutation/catalogue.json must have a `match` that appears exactly
# once in its file, and every test it names in `test` must exist.
#
# A drifted entry does not fail loudly on the gate. `mutation_runner.py` records it as an ERROR
# and moves on, so the bound it was written for stops being covered and nothing says so. That
# exact thing shipped once (QV-109, whose match text a change moved and did not re-point) and was
# only caught two tasks later, by hand.
#
# This makes the check cheap enough to run every time. It reads the whole catalogue, not only
# the entries a task touched, because the way an entry goes stale is that somebody edits the
# source near it without knowing it was there.
set -euo pipefail

[[ -f mutation/catalogue.json ]] || { echo "missing mutation/catalogue.json (run from the repository root)"; exit 1; }

python3 - <<'PY'
import json, pathlib, re, sys

cat = json.loads(pathlib.Path("mutation/catalogue.json").read_text())

# Every test function name in the suite. `test` fields are checked against this because the
# runner tries a named test before the full suite, and a name that does not exist silently
# falls through: correct, but with none of the speed and no signal that the field is rotten.
# QV-26 was once found naming a test that was not in the repo; QV-10 was still doing it afterwards.
have = set()
for tf in pathlib.Path("test").rglob("*.sol"):
    have.update(re.findall(r"function ((?:test|invariant|testFuzz)[A-Za-z0-9_]*)", tf.read_text()))

src, bad, stale_tests, checked = {}, [], [], 0
for e in cat:
    if e.get("status") != "catalogued":
        continue
    checked += 1
    f = e["file"]
    if f not in src:
        p = pathlib.Path(f)
        src[f] = p.read_text() if p.exists() else None
    text = src[f]
    n = -1 if text is None else text.count(e["match"])
    if n != 1:
        bad.append((e["id"], f, "file missing" if n < 0 else f"{n} matches"))
    # A `test` field may name several tests, comma separated.
    for name in (x.strip() for x in e.get("test", "").split(",")):
        if name and name not in have:
            stale_tests.append((e["id"], name))

for entry_id, f, why in bad:
    print(f"STALE: {entry_id} in {f}: {why}")

for entry_id, name in stale_tests:
    print(f"NO SUCH TEST: {entry_id} names {name}, which is not in the suite")

if stale_tests and not bad:
    print()
    print(f"{len(stale_tests)} catalogued entries name a test that does not exist. The gate still")
    print("kills them via the full suite, so this is not a coverage hole, but the name is rotten")
    print("and the narrow path it exists for is dead. Re-point each to the test that actually")
    print("kills the mutant.")
    sys.exit(1)

if bad:
    print()
    print(f"{len(bad)} of {checked} catalogued entries would ERROR the mutation gate instead of")
    print("killing. Re-point each `match` where the bound moved, and delete it only where the")
    print("bound genuinely no longer exists: a bound that moved and got deleted is coverage lost")
    print("silently.")
    sys.exit(1)

if stale_tests:
    sys.exit(1)

print(f"all {checked} catalogued entries match exactly once in their file, and every test they "
      f"name exists ({len(cat)} entries total, including non-catalogued)")
PY
