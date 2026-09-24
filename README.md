# Qudi contracts

Qudi is community finance on Arc, in USDC. A host creates a community, and members join by
buying a seat. Members save into vaults at three tiers, Flex, Core and Term, each kept on a
per-community ledger over shared yield vaults. A shared vault pays out only by a vote of the
people who put money in. Each community has a credit balance, funded by Qudi and by a share of
seat fees and vault yield, and a member with standing in the community can draw an
interest-free advance from it and repay it one to one.

## Status

Beta. The contracts are unaudited and are not deployed to any public network yet. Do not use
them with real funds.

## Layout

```text
src/               the contracts
src/interfaces/    their interfaces
test/              unit, fuzz and invariant tests, with helpers and mocks
script/            the deploy script, the CI guard scripts and the mutation runners
mutation/          the mutation catalogue and the pinned regression seeds
lib/               dependencies, as git submodules
```

The main contracts are `CommunityFactory`, `Community`, `Ledger`, `Venue`, `CreditCore`,
`CreditStanding`, `ComplianceRegistry` and `Config`. `ManualStrategy` is a stand-in for a real
yield venue, and its share price is moved by hand.

## Build and test

You need [Foundry](https://getfoundry.sh). Clone with the submodules:

```sh
git clone --recurse-submodules https://github.com/xanderslabs/Qudi-contracts.git
cd Qudi-contracts
```

Build and run the tests:

```sh
forge build
forge test
```

Run the guard scripts from the repository root. CI runs the first five on every push and pull
request.

```sh
bash script/check-config-literals.sh
bash script/check-config-key-enumeration.sh
bash script/check-config-first-access-floor.sh
bash script/check-contract-size-margin.sh
bash script/check-no-internal-ids.sh
bash script/check-mutation-catalogue.sh
```

## License

The contracts, tests and scripts are licensed under AGPL-3.0-only. Files under `src/interfaces/`
are licensed under MIT, as their SPDX headers state. See [LICENSE](LICENSE).
