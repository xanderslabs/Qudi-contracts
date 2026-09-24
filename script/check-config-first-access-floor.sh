#!/usr/bin/env bash
# Cross-key validation is not allowed inside Config itself (a constraint
# tying two keys together can deadlock their own setters through the 48-hour timelock: whichever
# key moves first would violate the relation against the other key's still-old value). The check
# instead lives here, in the script that already gates CI on config-shaped facts.
#
# PHASE_CAP_FIRST_ACCESS < MIN_LENDABLE is admissible under Config's own per-key bounds
# (a config footgun) and makes every First Access member's Line land
# below MIN_LENDABLE, so `line()` reports every one of them `eligible == false` permanently: the
# phase cap can never let a first draw clear the minimum. This reads both launch values out of
# Config.sol's own constructor and fails loud if the combination is present.
set -euo pipefail

config_file="src/Config.sol"
[[ -f "$config_file" ]] || { echo "missing $config_file (run from the repository root)"; exit 1; }

# Evaluates a Solidity numeric literal of the shape `123e6` or `1_000_000` (underscores allowed)
# to a plain base-10 integer, without invoking a shell arithmetic that overflows on 1e18-sized
# values.
eval_literal() {
  python3 -c '
import sys
lit = sys.argv[1].replace("_", "")
if "e" in lit:
    mantissa, exponent = lit.split("e")
    print(int(mantissa) * 10 ** int(exponent))
else:
    print(int(lit))
' "$1"
}

min_lendable_lit=$(grep -oE '_init\(K\.MIN_LENDABLE, [0-9_]+e?[0-9]*\)' "$config_file" \
  | sed -E 's/.*, ([0-9_]+e?[0-9]*)\)/\1/')
first_access_cap_lit=$(grep -oE '_init\(K\.PHASE_CAP_FIRST_ACCESS, [0-9_]+e?[0-9]*\)' "$config_file" \
  | sed -E 's/.*, ([0-9_]+e?[0-9]*)\)/\1/')

if [[ -z "$min_lendable_lit" || -z "$first_access_cap_lit" ]]; then
  echo "could not find MIN_LENDABLE and/or PHASE_CAP_FIRST_ACCESS launch values in $config_file"
  exit 1
fi

min_lendable=$(eval_literal "$min_lendable_lit")
first_access_cap=$(eval_literal "$first_access_cap_lit")

if (( first_access_cap < min_lendable )); then
  echo "PHASE_CAP_FIRST_ACCESS ($first_access_cap_lit) < MIN_LENDABLE ($min_lendable_lit):"
  echo "every First Access member's Line would land below MIN_LENDABLE and report"
  echo "eligible == false permanently. Raise PHASE_CAP_FIRST_ACCESS's launch value or lower"
  echo "MIN_LENDABLE's so PHASE_CAP_FIRST_ACCESS >= MIN_LENDABLE."
  exit 1
fi

echo "PHASE_CAP_FIRST_ACCESS ($first_access_cap_lit) >= MIN_LENDABLE ($min_lendable_lit)"
