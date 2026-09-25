#!/usr/bin/env bash
# The smoke run on a live Arc deployment, with `cast`.
#
# It is not a Forge script. Forge runs every script in its own local EVM first and only then
# broadcasts, and that EVM cannot run the Arc system precompiles behind USDC: USDC keeps balances
# in the native coin and moves them through 0x1800...0000, and checks its blocklist at
# 0x1800...0001. So any Forge script that moves USDC on Arc fails in simulation and sends nothing.
# `cast send` asks the node to estimate and run each call, so the precompiles run where they exist.
#
# Run from the repository root, in phases, because on a real chain time must pass between them:
#   bash script/smoke/smoke.sh open       # community, invite, join, deposits, yield funding
#   bash script/smoke/smoke.sh accrue     # hours later: accrue, and show the 70/15/15 split
#   bash script/smoke/smoke.sh withdraw   # a withdrawal paid to the wallet
#   bash script/smoke/smoke.sh pauses     # each flag set: money in refused, a withdrawal paid
#
# Environment (read from .env if present):
#   ARC_TESTNET_RPC_URL                  the RPC (or RPC_URL to point elsewhere)
#   SMOKE_HOST, SMOKE_JOINER             the two test accounts' addresses
#   HOST_ACCOUNT, JOINER_ACCOUNT,
#   OPERATOR_ACCOUNT, PAUSER_ACCOUNT     their Foundry keystore names; each `cast send` asks for the
#                                        keystore's password. No key is ever read from a file here.
#   SMOKE_COMMUNITY                      printed by `open`, needed by the later phases
#   DEPLOYMENT_RECORD                    default deployments/<chainId>.json
#   UNLOCKED=1                           a local anvil only: send from unlocked accounts instead
#
# The only private key this script handles is the throwaway invite key it makes with
# `cast wallet new`. A host's app makes the same kind of key and puts it in the invite link; it
# can do nothing but seat the one joiner it signs for.
#
# A draw needs five members whose seats are 14 days old, so it cannot run on a fresh deployment.
set -euo pipefail

[[ -f .env ]] && { set -a; source .env; set +a; }
RPC="${RPC_URL:-${ARC_TESTNET_RPC_URL:?set ARC_TESTNET_RPC_URL}}"
CHAIN=$(cast chain-id --rpc-url "$RPC")
RECORD="${DEPLOYMENT_RECORD:-deployments/$CHAIN.json}"
[[ $(jq -r .chainId "$RECORD") == "$CHAIN" ]] || { echo "$RECORD is not for chain $CHAIN"; exit 1; }

addr() { jq -r ".contracts.$1" "$RECORD"; }
FACTORY=$(addr CommunityFactory)
REGISTRY=$(addr ComplianceRegistry)
CONFIG=$(addr Config)
CORE=$(addr CreditCore)
GUARD=$(addr PauseGuard)
VENUES=("$(addr VenueFlex)" "$(addr VenueCore)" "$(addr VenueTerm)")
STRATEGIES=("$(addr ManualStrategyFlex)" "$(addr ManualStrategyCore)" "$(addr ManualStrategyTerm)")
NAMES=(Flex Core Term)
OPERATOR=$(jq -r .roles.operator "$RECORD")
PAUSER=$(jq -r .roles.pauser "$RECORD")
USDC=$(cast call "$CONFIG" "usdc()(address)" --rpc-url "$RPC")
HOST="${SMOKE_HOST:?set SMOKE_HOST}"
JOINER="${SMOKE_JOINER:?set SMOKE_JOINER}"

SEAT_PRICE=1000000   # $1
DEPOSIT=2000000      # $2 into each vault
YIELD_FUND=1000000   # $1 of yield paid into each strategy
GROSS=(290 500 640)  # each venue's gross rate in basis points, as its label states
PAUSED=0x9e87fac8    # the selector of IPauseGuard.Paused()

# The signer flags for one role: a keystore name, or an unlocked address on a local anvil.
signer() {
  local role=$1 address=$2
  if [[ "${UNLOCKED:-0}" == 1 ]]; then
    echo "--unlocked --from $address"
  else
    local var="${role}_ACCOUNT"
    echo "--account ${!var:?set $var}"
  fi
}

# `send <role> <address> <to> <sig> [args...]`, waiting for the receipt, printing its hash.
#
# The gas limit is the node's estimate plus 30% plus a flat 1,000,000. The estimate alone is not
# enough, for two reasons. It can come in short of the real cost (a strategy's first accrual after
# funding costs more than the estimate saw). And the ledger makes some calls best-effort, inside
# `try`: settling fees, and telling `CreditCore` a deposit happened. The contracts now revert a
# transaction whose best-effort call ran out of gas, so the estimate includes those calls; the
# margin stays for the first case and costs little on Arc.
send() {
  local role=$1 from=$2 to=$3; shift 3
  local est receipt
  est=$(cast estimate --from "$from" "$to" "$@" --rpc-url "$RPC")
  # shellcheck disable=SC2046
  receipt=$(cast send $(signer "$role" "$from") "$to" "$@" --gas-limit $(( est * 13 / 10 + 1000000 )) --rpc-url "$RPC" --json)
  echo "$receipt" | jq -r '"  tx " + .transactionHash + " status " + .status'
  [[ $(echo "$receipt" | jq -r .status) == 0x1 ]] || { echo "  that transaction failed"; exit 1; }
}

call() { cast call "$@" --rpc-url "$RPC" | awk '{print $1}'; }
balance() { call "$USDC" "balanceOf(address)(uint256)" "$1"; }

community() { echo "${SMOKE_COMMUNITY:?set SMOKE_COMMUNITY from the open phase}"; }
ledger_of() { call "$FACTORY" "ledgerOf(address)(address)" "$1"; }
community_id() { echo $(( $(call "$FACTORY" "communityIdOf(address)(uint256)" "$1") - 1 )); }

# The host's vault ids, in the order `open` made them: Flex, Core, Term.
host_vault() {
  cast call "$1" "vaultsOf(address)(uint256[])" "$HOST" --rpc-url "$RPC" | tr -d '[]' | tr ',' '\n' | sed -n "$(( $2 + 1 ))p" | tr -d ' '
}

attest() {
  if [[ $(call "$REGISTRY" "isAttested(address)(bool)" "$2") != true ]]; then
    send "$1" "$2" "$REGISTRY" "attest(uint32)" 1
  fi
}

open() {
  echo "chain $CHAIN, USDC $USDC"
  echo "1. a community with a \$1 seat"
  attest HOST "$HOST"
  send HOST "$HOST" "$FACTORY" "createCommunity(string,uint256)" "Qudi smoke" "$SEAT_PRICE"
  local n c l
  n=$(call "$FACTORY" "communityCount()(uint256)")
  c=$(call "$FACTORY" "communityAt(uint256)(address)" $(( n - 1 )))
  [[ $(call "$c" "host()(address)" | tr '[:upper:]' '[:lower:]') == $(echo "$HOST" | tr '[:upper:]' '[:lower:]') ]] \
    || { echo "the newest community is not the host's"; exit 1; }
  l=$(ledger_of "$c")
  echo "  community $c, ledger $l"

  echo "2. an invite registered onchain, and the second account joins with it"
  local wallet key pk typed sig
  wallet=$(cast wallet new --json)
  # Newer cast nests the key under `.data`; older cast prints a bare array.
  key=$(echo "$wallet" | jq -r '(.data // .) | if type == "array" then .[0] else . end | .address')
  pk=$(echo "$wallet" | jq -r '(.data // .) | if type == "array" then .[0] else . end | .private_key')
  send HOST "$HOST" "$c" "createInvite(address,uint16,uint64)" "$key" 1 $(( $(date +%s) + 7 * 86400 ))
  typed=$(jq -n --arg c "$c" --arg j "$JOINER" --argjson id "$CHAIN" '{
    types: {
      EIP712Domain: [{name: "name", type: "string"}, {name: "version", type: "string"},
                     {name: "chainId", type: "uint256"}, {name: "verifyingContract", type: "address"}],
      Join: [{name: "community", type: "address"}, {name: "joiner", type: "address"}]
    },
    primaryType: "Join",
    domain: {name: "Qudi Community", version: "1", chainId: $id, verifyingContract: $c},
    message: {community: $c, joiner: $j}
  }')
  sig=$(cast wallet sign --data "$typed" --private-key "$pk")
  unset pk wallet
  attest JOINER "$JOINER"
  send JOINER "$JOINER" "$USDC" "approve(address,uint256)" "$c" "$SEAT_PRICE"
  local hostBefore
  hostBefore=$(balance "$HOST")
  send JOINER "$JOINER" "$c" "join(address,bytes)" "$key" "$sig"
  echo "  invite key $key; members $(call "$c" "memberCount()(uint256)"); host leg paid $(( $(balance "$HOST") - hostBefore )) USDC wei"

  echo "3. a personal vault in each venue, and one shared vault"
  send HOST "$HOST" "$USDC" "approve(address,uint256)" "$l" $(( 3 * DEPOSIT ))
  local v id lock
  for v in 0 1 2; do
    lock=0
    [[ $v == 2 ]] && lock=$(( $(date +%s) + 3600 ))
    send HOST "$HOST" "$l" "createVault((uint8,bool,uint64,string))" "($v,false,$lock,smoke)"
    id=$(call "$l" "vaultCount()(uint256)")
    send HOST "$HOST" "$l" "deposit(uint256,uint256)" "$id" "$DEPOSIT"
    echo "  ${NAMES[$v]} personal vault $id, value $(call "$l" "vaultValue(uint256)(uint256)" "$id") USDC wei"
  done
  send HOST "$HOST" "$l" "createVault((uint8,bool,uint64,string))" "(0,true,0,smoke shared)"
  id=$(call "$l" "vaultCount()(uint256)")
  send JOINER "$JOINER" "$USDC" "approve(address,uint256)" "$l" "$DEPOSIT"
  send JOINER "$JOINER" "$l" "deposit(uint256,uint256)" "$id" "$DEPOSIT"
  echo "  shared Flex vault $id, value $(call "$l" "vaultValue(uint256)(uint256)" "$id") USDC wei"

  echo "4. yield paid in ahead of time at each label's gross rate, and the money put to work"
  for v in 0 1 2; do
    send OPERATOR "$OPERATOR" "$USDC" "approve(address,uint256)" "${STRATEGIES[$v]}" "$YIELD_FUND"
    send OPERATOR "$OPERATOR" "${STRATEGIES[$v]}" "fundYield(uint256)" "$YIELD_FUND"
    send OPERATOR "$OPERATOR" "${STRATEGIES[$v]}" "setRate(uint16)" "${GROSS[$v]}"
    send HOST "$HOST" "${VENUES[$v]}" "rebalance()"
    echo "  ${NAMES[$v]}: principal $(call "${STRATEGIES[$v]}" "principalHeld()(uint256)"), rate $(call "${STRATEGIES[$v]}" "rateBps()(uint16)") bps, buffer $(call "${STRATEGIES[$v]}" "buffer()(uint256)")"
  done
  echo "next phases: export SMOKE_COMMUNITY=$c"
}

accrue() {
  local c l id treasury tBefore aBefore receipt
  c=$(community); l=$(ledger_of "$c"); id=$(community_id "$c")
  treasury=$(call "$CONFIG" "protocolTreasury()(address)")
  tBefore=$(balance "$treasury")
  aBefore=$(cast call "$CORE" "communityCreditOf(uint256)((uint256,uint256,uint256,uint256,uint256,uint64,bool))" "$id" --rpc-url "$RPC" | tr -d '(' | awk -F', ' '{print $1}' | awk '{print $1}')
  local est
  est=$(cast estimate --from "$HOST" "$l" "accrue()" --rpc-url "$RPC")
  # shellcheck disable=SC2046
  receipt=$(cast send $(signer HOST "$HOST") "$l" "accrue()" --gas-limit $(( est * 13 / 10 + 1000000 )) --rpc-url "$RPC" --json)
  echo "  tx $(echo "$receipt" | jq -r .transactionHash) status $(echo "$receipt" | jq -r .status)"
  local accrued settled
  accrued=$(cast keccak "Accrued(uint8,uint256,uint256,uint256)")
  settled=$(cast keccak "FeesSettled(uint8,uint256,uint256)")
  echo "$receipt" | jq -c --arg l "$(echo "$l" | tr '[:upper:]' '[:lower:]')" '.logs[] | select((.address | ascii_downcase) == $l)' |
    while read -r log; do
      local topic venue data
      topic=$(echo "$log" | jq -r '.topics[0]')
      venue=$(( $(echo "$log" | jq -r '.topics[1]') ))
      data=$(echo "$log" | jq -r .data)
      if [[ $topic == "$accrued" ]]; then
        read -r price tFee cFee < <(cast abi-decode --input "f(uint256,uint256,uint256)" "$data" | awk '{print $1}' | xargs)
        gain=$(( cFee * 10000 / 1500 ))
        echo "  ${NAMES[$venue]}: price $price, gain above the peak $gain USDC wei"
        echo "    members keep $(( gain - tFee - cFee )) (70%), treasury $tFee (15%), credit $cFee (15%)"
      elif [[ $topic == "$settled" ]]; then
        read -r toT toC < <(cast abi-decode --input "f(uint256,uint256)" "$data" | awk '{print $1}' | xargs)
        echo "  ${NAMES[$venue]}: settled $toT to the treasury and $toC to the credit account"
      fi
    done
  # The fees must be paid out in the accrual's own transaction.
  echo "$receipt" | jq -e --arg l "$(echo "$l" | tr '[:upper:]' '[:lower:]')" --arg t "$settled" \
    '[.logs[] | select((.address | ascii_downcase) == $l and .topics[0] == $t)] | length > 0' >/dev/null \
    || { echo "  the accrual charged fees but did not settle them"; exit 1; }
  local aAfter
  aAfter=$(cast call "$CORE" "communityCreditOf(uint256)((uint256,uint256,uint256,uint256,uint256,uint64,bool))" "$id" --rpc-url "$RPC" | tr -d '(' | awk -F', ' '{print $1}' | awk '{print $1}')
  echo "  treasury received $(( $(balance "$treasury") - tBefore )); community credit balance rose by $(( aAfter - aBefore ))"
  echo "  impact: host $(call "$l" "impactOf(address)(uint256)" "$HOST"), joiner $(call "$l" "impactOf(address)(uint256)" "$JOINER"), community total $(call "$l" "totalImpact()(uint256)")"
}

withdraw() {
  local c l id value before
  c=$(community); l=$(ledger_of "$c"); id=$(host_vault "$l" 0)
  value=$(call "$l" "vaultValue(uint256)(uint256)" "$id")
  before=$(balance "$HOST")
  send HOST "$HOST" "$l" "requestWithdraw(uint256,uint256)" "$id" $(( value / 2 ))
  echo "  asked for $(( value / 2 )) USDC wei from Flex vault $id; paid to the wallet $(( $(balance "$HOST") - before ))"
}

# Simulates a call from `who` and requires the pause to refuse it. Nothing is sent.
refused() {
  local what=$1 who=$2; shift 2
  local out
  if out=$(cast call --from "$who" "$@" --rpc-url "$RPC" 2>&1); then
    echo "  $what was NOT refused"; exit 1
  fi
  if [[ $out == *"$PAUSED"* || $out == *"Paused"* ]]; then
    echo "  $what refused: Paused()"
  else
    echo "  $what refused, but not by the pause: $out"; exit 1
  fi
}

pauses() {
  local c l id core_vault f value before
  c=$(community); l=$(ledger_of "$c"); id=$(community_id "$c"); core_vault=$(host_vault "$l" 1)
  for f in 0 1 2; do
    send PAUSER "$PAUSER" "$GUARD" "setPaused(uint8,bool)" "$f" true
  done
  echo "  flags: deposits $(call "$GUARD" "paused(uint8)(bool)" 0), draws $(call "$GUARD" "paused(uint8)(bool)" 1), venues $(call "$GUARD" "paused(uint8)(bool)" 2)"
  refused "DEPOSITS: a deposit" "$HOST" "$l" "deposit(uint256,uint256)" "$core_vault" 1
  refused "DRAWS: a draw" "$JOINER" "$CORE" "draw(uint256,uint256,bytes32)" "$id" 10000000 "$(call "$CONFIG" "creditAgreementHash()(bytes32)")"
  refused "VENUES: a strategy deploy" "$OPERATOR" "${STRATEGIES[0]}" "deploy(uint256,address,bytes32)" 1 "$OPERATOR" 0x0000000000000000000000000000000000000000000000000000000000000000
  value=$(call "$l" "vaultValue(uint256)(uint256)" "$core_vault")
  before=$(balance "$HOST")
  send HOST "$HOST" "$l" "requestWithdraw(uint256,uint256)" "$core_vault" $(( value / 2 ))
  echo "  paused: asked for $(( value / 2 )) from Core vault $core_vault, paid to the wallet $(( $(balance "$HOST") - before ))"
  for f in 0 1 2; do
    send PAUSER "$PAUSER" "$GUARD" "setPaused(uint8,bool)" "$f" false
  done
  echo "  flags cleared: $(call "$GUARD" "paused(uint8)(bool)" 0) $(call "$GUARD" "paused(uint8)(bool)" 1) $(call "$GUARD" "paused(uint8)(bool)" 2)"
}

case "${1:-}" in
  open) open ;;
  accrue) accrue ;;
  withdraw) withdraw ;;
  pauses) pauses ;;
  *) echo "usage: $0 open|accrue|withdraw|pauses"; exit 2 ;;
esac
