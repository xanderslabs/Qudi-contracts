#!/usr/bin/env bash
# Public code carries no internal ids. A comment states the rule and its reason directly, so a
# reader can follow it without access to anything outside this repository. This fails on any
# reference to a planning id, a review finding, a work unit, or an internal document.
#
# Run from the repository root. It scans src, test, script and mutation, and skips itself.
set -euo pipefail

dirs=(src test script mutation)
self="script/check-no-internal-ids.sh"

# Matched case-sensitively: ids and document names.
ids=(
  '(^|[^A-Za-z])[Ll][Bb]-?[0-9]'
  '\bP[0-9]\.[0-9]'
  'P1\.'
  'P2\.'
  'P3\.'
  '\bP[0-9]-[0-9]'
  '\bB\.[0-9]'
  'QUDI-'
  '\b(CREDIT|TRD|PRD|DESIGN|ARCHITECTURE|INVARIANTS|OPERATIONS-RISK|GATE-CRASHSAFE)\b'
  '\b[A-Z][A-Z-]+\.md\b'
  '\bI-(CFG|SEAT)-[0-9]'
  '\bAppendix [A-Z]\b'
  '\b[Ff]inding [0-9]'
  '\breview [A-Z]?[0-9]'
  '\bD[0-9]+\b'
  '\bM[0-9]+\b'
  '\bM-R[0-9]'
  '\bT[0-9]+-R[0-9]'
  '\bTask [0-9]'
  '\bPhase [0-9]'
  '[Ss]ection [0-9]'
  '[Oo]pen [Qq]uestion [0-9]'
)

# Matched case-insensitively: words that only ever point at internal process.
words=(
  'ruling'
  'build report'
  'build prompt'
  '\bfounder'
  'Qudi-internal'
  'decisions/'
  'flow walk'
)

found=0
scan() {
  local flag=$1 pattern=$2 hits
  hits=$(grep -rnE $flag "$pattern" "${dirs[@]}" | grep -v "^${self}:" || true)
  if [[ -n "$hits" ]]; then
    echo "internal reference (${pattern}):"
    echo "$hits"
    echo
    found=1
  fi
}

for p in "${ids[@]}"; do scan "" "$p"; done
for p in "${words[@]}"; do scan "-i" "$p"; done

if [[ $found -ne 0 ]]; then
  echo "Internal references found. State the rule and its reason instead of pointing at an id."
  exit 1
fi

echo "no internal references in ${dirs[*]}"
