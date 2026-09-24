#!/usr/bin/env bash
# No-charge structural guard (`total_charges == 0`): credit carries no charge.
#
# `test_noChargeParameterIsReachable` in test/Config.t.sol enumerates the config key set and
# checks none of it is charge-shaped. That check is only as good as the enumeration: a hand
# maintained list in the test file can fall behind ConfigKeys.sol, and a charge parameter
# added under a novel name then passes the whole suite (a fixed list of six shipped once and
# was later widened, and the hole was the same shape both times).
#
# This script makes the enumeration structural. It reads ConfigKeys.sol as the source of
# truth and fails if any declared key is missing from `_allConfigKeys()`, or if the count
# assertion in the test does not match the number of declared keys. A new key then fails CI
# until someone adds it to `_allConfigKeys()` and, in the same edit, audits it against the no-charge rule.
set -euo pipefail

keys_file="src/ConfigKeys.sol"
test_file="test/Config.t.sol"

for f in "$keys_file" "$test_file"; do
  [[ -f "$f" ]] || { echo "missing $f (run from the repository root)"; exit 1; }
done

# Every `bytes32 constant NAME = keccak256("qudi.NAME");` in ConfigKeys.sol. `while read`
# rather than `mapfile` so the script runs under bash 3.2 (macOS) as well as CI's bash.
declared_count=0
missing=""
while IFS= read -r name; do
  declared_count=$((declared_count + 1))
  # The test enumerates them one per line as `k[i++] = K.NAME;`.
  if ! grep -qE "k\[i\+\+\] = K\.${name};" "$test_file"; then
    missing="${missing}  ${name}"$'\n'
  fi
done < <(grep -oE 'bytes32 constant [A-Z0-9_]+' "$keys_file" | awk '{print $3}')

if [[ -n "$missing" ]]; then
  echo "ConfigKeys.sol declares keys not enumerated in ${test_file} _allConfigKeys():"
  printf '%s' "$missing"
  echo
  echo "Add each as 'k[i++] = K.<NAME>;' and audit it against the no-charge rule (interest-free: no"
  echo "parameter may put a charge on an obligation) before it lands."
  exit 1
fi

# The test asserts the enumerated length against a hardcoded count; `all.length` is the size
# of the `_allConfigKeys()` array, so this one literal pins both.
asserted_len=$(grep -oE 'assertEq\(all\.length, [0-9]+' "$test_file" | grep -oE '[0-9]+$' | head -1)

if [[ "$asserted_len" != "$declared_count" ]]; then
  echo "Count mismatch: ConfigKeys.sol declares ${declared_count} keys, but ${test_file}"
  echo "asserts all.length == ${asserted_len:-?}. Update the assertEq in"
  echo "test_noChargeParameterIsReachable and re-audit the new key against the no-charge rule."
  exit 1
fi

echo "all ${declared_count} ConfigKeys enumerated in ${test_file}"
