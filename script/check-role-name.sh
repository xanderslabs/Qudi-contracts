#!/usr/bin/env bash
# The role that runs a community is called the host everywhere a member or an integrator reads it.
# Public names cannot change once a contract is deployed, so an old name that slips back in ships
# for good. This fails on the old word, in any case, anywhere in src, test or script.
#
# Run from the repository root. It builds the word from two halves so it never matches itself.
set -euo pipefail

dirs=(src test script)
word="stew""ard"

hits=$(grep -rniE "$word" "${dirs[@]}" || true)
if [[ -n "$hits" ]]; then
  echo "the role is called host:"
  echo "$hits"
  exit 1
fi

echo "no old role name in ${dirs[*]}"
