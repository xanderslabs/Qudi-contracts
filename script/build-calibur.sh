#!/usr/bin/env bash
# Builds Calibur's `CaliburEntry` exactly as Uniswap built the copy at the canonical address
# 0x000000005c84F8Fd50b21CAC312528A64437030e, and checks the result before anything uses it.
#
# Calibur is built with its own foundry.toml (solc 0.8.29, cancun, 1,000 optimizer runs, via-IR,
# no bytecode hash), never with this repository's settings. Two more things are pinned:
#   - solc 0.8.29, which `CaliburEntry.sol` names exactly;
#   - the import remappings, with Foundry's automatic remapping turned off. A current Foundry maps
#     `webauthn-sol`'s imports of `solady` and `openzeppelin-contracts` to webauthn-sol's own
#     nested copies, which are older versions of `LibString` and `Base64`. Uniswap's build mapped
#     them to Calibur's top-level copies. That one difference makes the runtime 94 bytes longer,
#     moves the init code hash, and sends the canonical salt to a different address.
#
# Calibur's own libraries must be checked out first:
#   git submodule update --init --recursive lib/calibur
# CALIBUR_ROOT points the build at another checkout of Calibur 249cac5e, if needed.
#
# Output: cache/calibur/out/CaliburEntry.sol/CaliburEntry.json, read by script/DeployCalibur.s.sol.
set -euo pipefail

root="${CALIBUR_ROOT:-lib/calibur}"
here="$PWD"
out="$here/cache/calibur/out"

# The init code hash of Uniswap's published build. With the canonical salt and the deterministic
# deployer it gives the canonical address, so a build that matches it is the canonical build.
expected_init_hash="0xd3a7ea2bc0c320de0cb9288c0a3f67e8e07f7982d99fdac28208501bd1e74149"

if [[ ! -f "$root/lib/solady/src/utils/LibString.sol" ]]; then
  echo "Calibur's own libraries are missing under $root/lib."
  echo "Run: git submodule update --init --recursive lib/calibur"
  exit 1
fi

remappings=(
  "webauthn-sol/=lib/webauthn-sol/"
  "@openzeppelin/contracts/=lib/openzeppelin-contracts/contracts/"
  "FreshCryptoLib/=lib/webauthn-sol/lib/FreshCryptoLib/solidity/src/"
  "account-abstraction/=lib/account-abstraction/contracts/"
  "ds-test/=lib/erc20-eth/lib/solmate/lib/ds-test/src/"
  "erc20-eth/=lib/erc20-eth/src/"
  "erc4626-tests/=lib/openzeppelin-contracts/lib/erc4626-tests/"
  "forge-gas-snapshot/=lib/permit2/lib/forge-gas-snapshot/src/"
  "forge-std/=lib/forge-std/src/"
  "halmos-cheatcodes/=lib/openzeppelin-contracts/lib/halmos-cheatcodes/src/"
  "openzeppelin-contracts/=lib/openzeppelin-contracts/"
  "permit2/=lib/permit2/"
  "solady/=lib/solady/src/"
  "solmate/=lib/permit2/lib/solmate/"
)
args=()
for r in "${remappings[@]}"; do args+=(--remappings "$r"); done

(
  cd "$root"
  FOUNDRY_AUTO_DETECT_REMAPPINGS=false forge build --use 0.8.29 "${args[@]}" \
    --out "$out" --cache-path "$here/cache/calibur/cache" src/CaliburEntry.sol
)

artifact="$out/CaliburEntry.sol/CaliburEntry.json"
init_hash=$(cast keccak "$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["bytecode"]["object"])' "$artifact")")
if [[ "$init_hash" != "$expected_init_hash" ]]; then
  echo "CaliburEntry init code hash $init_hash is not the canonical $expected_init_hash"
  exit 1
fi
echo "CaliburEntry matches the canonical build: init code hash $init_hash"
