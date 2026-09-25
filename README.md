# Qudi contracts

Qudi is community finance on Arc, in USDC. A host creates a community, and members join by
buying a seat. Members save into vaults at three tiers, Flex, Core and Term, each kept on a
per-community ledger over shared yield vaults. A shared vault pays out only by a vote of the
people who put money in. Each community has a credit balance, funded by a share of its own seat
fees and vault yield, and a member with standing in the community can draw an interest-free
advance from it and repay it one to one. Members' savings are never lent.

## Status

Deployed to Arc mainnet and Arc testnet. Beta and unaudited. The app is not yet open to the
public on mainnet.

## Arc mainnet

Chain id 5042, from block 22658745, at commit `b026fcd`. The full record is
[`deployments/5042.json`](deployments/5042.json).

| Contract | Address |
| --- | --- |
| `CommunityFactory` | [`0x4d2EE54b81c664C6B10E8631e1D99cecDD9EB4B5`](https://explorer.arc.io/address/0x4d2EE54b81c664C6B10E8631e1D99cecDD9EB4B5) |
| `CommunityImplementation` | [`0x89bFBd4E145f4D9Eb16943d833A5efF362757782`](https://explorer.arc.io/address/0x89bFBd4E145f4D9Eb16943d833A5efF362757782) |
| `LedgerImplementation` | [`0xC09Bc55637e767EeE3366eFfBCc9B8B848A33CBb`](https://explorer.arc.io/address/0xC09Bc55637e767EeE3366eFfBCc9B8B848A33CBb) |
| `Seats` | [`0x166Bc4e0e7c1c9bc81DBF55FE2712580F25bA820`](https://explorer.arc.io/address/0x166Bc4e0e7c1c9bc81DBF55FE2712580F25bA820) |
| `Config` | [`0x4c1Dd078c1e8fc764901490076d88837AB4176E7`](https://explorer.arc.io/address/0x4c1Dd078c1e8fc764901490076d88837AB4176E7) |
| `ComplianceRegistry` | [`0x10f391578B2Fbc83F86A2183c14CfB40b669b1Dc`](https://explorer.arc.io/address/0x10f391578B2Fbc83F86A2183c14CfB40b669b1Dc) |
| `CreditCore` | [`0xfC1Eb5bE3c7bffE8658C850BBa2Ae5f93A79bA3f`](https://explorer.arc.io/address/0xfC1Eb5bE3c7bffE8658C850BBa2Ae5f93A79bA3f) |
| `CreditStanding` | [`0x0737A30E3FD674F442D7eA3E1035071a4ACc14C4`](https://explorer.arc.io/address/0x0737A30E3FD674F442D7eA3E1035071a4ACc14C4) |
| `ImpactSourceSeats` | [`0x696bCA8635649806890277bF0ACC0360D82EFF56`](https://explorer.arc.io/address/0x696bCA8635649806890277bF0ACC0360D82EFF56) |
| `ImpactSourceLedger` | [`0x0C2dC3Bea622EDBd464a4167AE0DEc3d7fC03132`](https://explorer.arc.io/address/0x0C2dC3Bea622EDBd464a4167AE0DEc3d7fC03132) |
| `PauseGuard` | [`0x85F9C8992917089Fcd4811dC719C0B33968eBDd3`](https://explorer.arc.io/address/0x85F9C8992917089Fcd4811dC719C0B33968eBDd3) |
| `Timelock` | [`0x6FeD84cB58caB820a1aB825a5b9144453D7Ad9e8`](https://explorer.arc.io/address/0x6FeD84cB58caB820a1aB825a5b9144453D7Ad9e8) |
| `TimelockLong` | [`0x918B059aF0e0E641321CA466BE368AB3871587d9`](https://explorer.arc.io/address/0x918B059aF0e0E641321CA466BE368AB3871587d9) |
| `VenueFlex` | [`0x808fB4B1942efC38D46782c302b2D5De1E6B5e5c`](https://explorer.arc.io/address/0x808fB4B1942efC38D46782c302b2D5De1E6B5e5c) |
| `ManualStrategyFlex` | [`0x73c7E65f4F104C66121142B2c734027c68aF5ef4`](https://explorer.arc.io/address/0x73c7E65f4F104C66121142B2c734027c68aF5ef4) |
| `VenueCore` | [`0x7081120D262B1AB92B02eB3413ad1C16E2Da5a8E`](https://explorer.arc.io/address/0x7081120D262B1AB92B02eB3413ad1C16E2Da5a8E) |
| `ManualStrategyCore` | [`0xFAC9bEEa9a5A60FA5A7f0592D9Ca939f2ee96eBe`](https://explorer.arc.io/address/0xFAC9bEEa9a5A60FA5A7f0592D9Ca939f2ee96eBe) |
| `VenueTerm` | [`0x799fDf702d306B994BA6629693cF353196bdE772`](https://explorer.arc.io/address/0x799fDf702d306B994BA6629693cF353196bdE772) |
| `ManualStrategyTerm` | [`0x255aA78e053440293a766166A5C459952bC806A7`](https://explorer.arc.io/address/0x255aA78e053440293a766166A5C459952bC806A7) |
| `Calibur` (EIP-7702 delegate) | [`0x000000005c84F8Fd50b21CAC312528A64437030e`](https://explorer.arc.io/address/0x000000005c84F8Fd50b21CAC312528A64437030e) |

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
