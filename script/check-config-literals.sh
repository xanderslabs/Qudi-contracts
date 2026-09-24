#!/usr/bin/env bash
# Launch values must live only in Config's constructor defaults.
# This is a tripwire, not a proof; code review is the other half.
#
# The banned list names every value it protects, so it does not protect a value that is not
# listed. When you introduce a new timed or numeric config parameter, add its launch value
# here in the same change, or a consumer can hardcode the value and this check stays silent.
set -euo pipefail
banned='50e6|56 days|30 days|7 days|90 days|14 days|3 days|\b6667\b|\b2500\b|\b9950\b|\b600\b|\b4000\b|\b3000\b'
hits=$(grep -rEn "$banned" src/ \
  --include='*.sol' \
  | grep -v 'src/Config.sol' \
  | grep -v 'src/ConfigKeys.sol' \
  | grep -v '// config-literal-ok' || true)
if [[ -n "$hits" ]]; then
  echo "Launch-value literal outside Config (annotate false positives with // config-literal-ok):"
  echo "$hits"
  exit 1
fi
echo "no config literals found outside Config"
