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

Chain id 5042002, from block 63896663, at commit `b026fcd`. The full record is
[`deployments/5042002.json`](deployments/5042002.json).

| Contract | Address |
| --- | --- |
| `CommunityFactory` | [`0x8A2Ddf7dBF899bB2171a1625A75b038873Fb5F4f`](https://testnet.arcscan.app/address/0x8A2Ddf7dBF899bB2171a1625A75b038873Fb5F4f) |
| `CommunityImplementation` | [`0x34B2b774fd540896c290caE2813E9962120cee17`](https://testnet.arcscan.app/address/0x34B2b774fd540896c290caE2813E9962120cee17) |
| `LedgerImplementation` | [`0x4bdb5e88aFfaf4De8fa83dE62cB5f70f5519E22E`](https://testnet.arcscan.app/address/0x4bdb5e88aFfaf4De8fa83dE62cB5f70f5519E22E) |
| `Seats` | [`0x28b4fc84e5C20fa5a4E150C6d9554BA619c0941f`](https://testnet.arcscan.app/address/0x28b4fc84e5C20fa5a4E150C6d9554BA619c0941f) |
| `Config` | [`0x13985F1183f1dB0F314c12eA422bB7610a504A85`](https://testnet.arcscan.app/address/0x13985F1183f1dB0F314c12eA422bB7610a504A85) |
| `ComplianceRegistry` | [`0x2Fd973d88C13e7f37AC07a1C26AbE54885768652`](https://testnet.arcscan.app/address/0x2Fd973d88C13e7f37AC07a1C26AbE54885768652) |
| `CreditCore` | [`0x5108101723Ac9e416c653EbeC5ce66dAE6d15E1D`](https://testnet.arcscan.app/address/0x5108101723Ac9e416c653EbeC5ce66dAE6d15E1D) |
| `CreditStanding` | [`0x12ea81e07C900BCbd4fa29caA75330d6CBC5bFfd`](https://testnet.arcscan.app/address/0x12ea81e07C900BCbd4fa29caA75330d6CBC5bFfd) |
| `ImpactSourceSeats` | [`0xD2dE8260E2d366E65a5750B7ccf346c7D08D7de2`](https://testnet.arcscan.app/address/0xD2dE8260E2d366E65a5750B7ccf346c7D08D7de2) |
| `ImpactSourceLedger` | [`0xcbBeC3365e33F23c404414a6ad94dE151ab34727`](https://testnet.arcscan.app/address/0xcbBeC3365e33F23c404414a6ad94dE151ab34727) |
| `PauseGuard` | [`0x5c44cD5CA98b7b00bf6e87bdff42507DEEBF115e`](https://testnet.arcscan.app/address/0x5c44cD5CA98b7b00bf6e87bdff42507DEEBF115e) |
| `Timelock` | [`0x2c447a16a9F9530CA8E5Da326084A33eB27B9aFB`](https://testnet.arcscan.app/address/0x2c447a16a9F9530CA8E5Da326084A33eB27B9aFB) |
| `TimelockLong` | [`0xF1F23bb3C6342246f336ba6077218c1624789332`](https://testnet.arcscan.app/address/0xF1F23bb3C6342246f336ba6077218c1624789332) |
| `VenueFlex` | [`0x9C161220C8eff7a38343E860EfeC58Df577BCFae`](https://testnet.arcscan.app/address/0x9C161220C8eff7a38343E860EfeC58Df577BCFae) |
| `ManualStrategyFlex` | [`0xC4be257679965B2a9f946750529c35C2c9533812`](https://testnet.arcscan.app/address/0xC4be257679965B2a9f946750529c35C2c9533812) |
| `VenueCore` | [`0xEA4c441fD3Dc0AA9386047ceD4Bd49678F4BE7ad`](https://testnet.arcscan.app/address/0xEA4c441fD3Dc0AA9386047ceD4Bd49678F4BE7ad) |
| `ManualStrategyCore` | [`0xAeaf86b6adF878431867cB207d6F7B0DB9582023`](https://testnet.arcscan.app/address/0xAeaf86b6adF878431867cB207d6F7B0DB9582023) |
| `VenueTerm` | [`0x4D781C09A239424ad0992BE40aAeC7a29D56fbA9`](https://testnet.arcscan.app/address/0x4D781C09A239424ad0992BE40aAeC7a29D56fbA9) |
| `ManualStrategyTerm` | [`0xD66Eb3FEEd71203296b5547969A72fD023573013`](https://testnet.arcscan.app/address/0xD66Eb3FEEd71203296b5547969A72fD023573013) |
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
