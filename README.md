# Qudi contracts

Qudi is community finance on Arc, in USDC. A host creates a community, and members join by
buying a seat. Members save into vaults at three tiers, Flex, Core and Term, each kept on a
per-community ledger over shared yield vaults. A shared vault pays out only by a vote of the
people who put money in. Each community has a credit balance, funded by Qudi and by a share of
seat fees and vault yield, and a member with standing in the community can draw an
interest-free advance from it and repay it one to one.

## Status

Deployed to Arc testnet, beta, unaudited. Do not use the contracts with real funds.

## Arc testnet

Chain id 5042002, from block 63817719, at commit `f3e323e`. The full record is
[`deployments/5042002.json`](deployments/5042002.json).

| Contract | Address |
| --- | --- |
| `CommunityFactory` | [`0x663d440d1758Ae486Bd7ecC7115A80a8c6DC7Ef5`](https://testnet.arcscan.app/address/0x663d440d1758Ae486Bd7ecC7115A80a8c6DC7Ef5) |
| `CommunityImplementation` | [`0x9F54b8a97dF12FDfBbcD93A357934cfAEe4438F0`](https://testnet.arcscan.app/address/0x9F54b8a97dF12FDfBbcD93A357934cfAEe4438F0) |
| `LedgerImplementation` | [`0xAbE8d67Ed2E2aCb49Dd3FCd0A6F59D0181Cc76d4`](https://testnet.arcscan.app/address/0xAbE8d67Ed2E2aCb49Dd3FCd0A6F59D0181Cc76d4) |
| `Seats` | [`0xBa70C9aC18202596C57b7aED73b9e68e7386869E`](https://testnet.arcscan.app/address/0xBa70C9aC18202596C57b7aED73b9e68e7386869E) |
| `Config` | [`0x1082AD667bb745FFfB082299e73AC5abd2c62C56`](https://testnet.arcscan.app/address/0x1082AD667bb745FFfB082299e73AC5abd2c62C56) |
| `ComplianceRegistry` | [`0xF775AB776b6676050097986a6781A274d2AD505f`](https://testnet.arcscan.app/address/0xF775AB776b6676050097986a6781A274d2AD505f) |
| `CreditCore` | [`0x8Cc920483379C3fC39b21d41ED69627BA750AbD3`](https://testnet.arcscan.app/address/0x8Cc920483379C3fC39b21d41ED69627BA750AbD3) |
| `CreditStanding` | [`0x5FBec4F6650A4E36e587D2CcBF86Def2a022621a`](https://testnet.arcscan.app/address/0x5FBec4F6650A4E36e587D2CcBF86Def2a022621a) |
| `ImpactSourceSeats` | [`0x14e41fF7bC1CE3bf1eF8B8e1e8293Ca75C8347F0`](https://testnet.arcscan.app/address/0x14e41fF7bC1CE3bf1eF8B8e1e8293Ca75C8347F0) |
| `ImpactSourceLedger` | [`0x33Bde4a5867b1D5D6C60d8a094896A1dc2Dd56eC`](https://testnet.arcscan.app/address/0x33Bde4a5867b1D5D6C60d8a094896A1dc2Dd56eC) |
| `PauseGuard` | [`0x9861B3F022bf42c146bbf5c4bDEfd803c9aC2D6f`](https://testnet.arcscan.app/address/0x9861B3F022bf42c146bbf5c4bDEfd803c9aC2D6f) |
| `Timelock` | [`0xf78Cb9B32bc3Ea6182B8C204AA44E8c6B19C388D`](https://testnet.arcscan.app/address/0xf78Cb9B32bc3Ea6182B8C204AA44E8c6B19C388D) |
| `TimelockLong` | [`0x08C5DC61121EeA98F9647421B65939584D647982`](https://testnet.arcscan.app/address/0x08C5DC61121EeA98F9647421B65939584D647982) |
| `VenueFlex` | [`0xa408968412bc4D193B40355A9a2146603213e12C`](https://testnet.arcscan.app/address/0xa408968412bc4D193B40355A9a2146603213e12C) |
| `ManualStrategyFlex` | [`0xee4598cb327cD8B7ba8f6BB15169fAcb4f2612a8`](https://testnet.arcscan.app/address/0xee4598cb327cD8B7ba8f6BB15169fAcb4f2612a8) |
| `VenueCore` | [`0x1ddA06c88638c0292860F28E54cD13CdFdB65431`](https://testnet.arcscan.app/address/0x1ddA06c88638c0292860F28E54cD13CdFdB65431) |
| `ManualStrategyCore` | [`0x51Ace3CF39298451035f13660708Bb0c68A3B182`](https://testnet.arcscan.app/address/0x51Ace3CF39298451035f13660708Bb0c68A3B182) |
| `VenueTerm` | [`0x72C98eed1FB68E1092d648727C1AC7a090508f15`](https://testnet.arcscan.app/address/0x72C98eed1FB68E1092d648727C1AC7a090508f15) |
| `ManualStrategyTerm` | [`0xBf0e779FCc5ED8F77A93735476C5DD31e2a13051`](https://testnet.arcscan.app/address/0xBf0e779FCc5ED8F77A93735476C5DD31e2a13051) |
| `Calibur` (EIP-7702 delegate) | [`0x000000005c84F8Fd50b21CAC312528A64437030e`](https://testnet.arcscan.app/address/0x000000005c84F8Fd50b21CAC312528A64437030e) |

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
