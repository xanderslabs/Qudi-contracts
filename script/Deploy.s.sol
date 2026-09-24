// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.30;

import {Script, console} from "forge-std/Script.sol";
import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {Config} from "../src/Config.sol";
import {IConfig} from "../src/interfaces/IConfig.sol";
import {ComplianceRegistry} from "../src/ComplianceRegistry.sol";
import {ManualStrategy} from "../src/ManualStrategy.sol";
import {Venue} from "../src/Venue.sol";
import {PoolTypes} from "../src/PoolTypes.sol";
import {Community} from "../src/Community.sol";
import {Seats} from "../src/Seats.sol";
import {Ledger} from "../src/Ledger.sol";
import {ILedger} from "../src/interfaces/ILedger.sol";
import {CommunityFactory} from "../src/CommunityFactory.sol";
import {CreditCore} from "../src/CreditCore.sol";
import {CreditStanding} from "../src/CreditStanding.sol";
import {ICreditStanding} from "../src/interfaces/ICreditStanding.sol";
import {ConfigKeys as K} from "../src/ConfigKeys.sol";

/// Minimal interface onto `test/mocks/MockUSDC.sol`'s open `mint`, declared locally rather than
/// imported so this production deploy path never depends on test scaffolding (see the
/// USDC_ADDRESS environment note below). Only ever called against the address anvil's own
/// `_ANVIL_CHAIN_ID` branch has already gated to a chain the operator was told to put a
/// `MockUSDC` at.
interface IMintableTestUsdc {
    function mint(address to, uint256 amount) external;
}

/// Deployment entry point. Order, dictated by what the constructors actually require:
///
///   compliance registry -> config -> vaults + venues -> implementations -> factory -> venue wiring -> config wiring assertions -> smoke community
///   -> ownership handover
///
/// Two orderings worth naming, both forced rather than chosen:
///   - the compliance registry is deployed BEFORE config, because
///     `Config(usdc, treasury, complianceRegistry)` takes its address and rejects zero;
///   - every owner call (`setRedeemDelay`, `addVenue`, `setWeights`) happens AFTER the factory is
///     created, never between the nonce read and the factory, because each broadcast call
///     advances the deployer's nonce and would move the factory's predicted address.
/// `CreditStanding` and `CreditCore` are deployed here, and
/// `Config.CREDIT_CORE` is set to the latter. Both come AFTER the factory, because each takes
/// it as an immutable constructor argument, and BEFORE the smoke community, because a paid seat mint
/// routes its pool leg to `CreditCore` and reverts `CreditCoreUnset` while the key is zero.
/// Neither is created before the factory, so `_FACTORY_NONCE_OFFSET` is unaffected.
///
/// **`ManualStrategy` reaches Arc mainnet from 2026-09-22, deliberately.** Its share price is moved
/// by its owner, so this is a deployment whose yield is whatever the operator says it is. That
/// is deliberate: there are no third-party users, the owner and the operator are the same
/// person, and the alternative was no mainnet deployment at all. It is not a real-venue
/// deployment and must not be described as one. A real venue replaces it later.
///
/// Three `Venue` instances, one per pool type (PoolTypes.sol), each with its own pair
/// of `ManualStrategy`s: a vault's `poolType` is immutable, so "one shared vault per pool type" is a
/// constructor-time decision, not a runtime one, and `CommunityFactory.pools` (an `address[3]` indexed
/// by the `PoolTypes` constant) is what lets a community's `Ledger` resolve a tier to the
/// right one. The TERM slot is an ordinary Venue too:
/// Term is a venue profile, not a fixed-term instrument.
///
/// The circular constructor dependency between Venue and CommunityFactory
/// (`Venue(usdc, config, factory, poolType, owner, name, symbol)` / `CommunityFactory(config,
/// seats, community, ledger, pools)`, both immutable), and the same one between `Seats` and the
/// factory, is resolved by precomputing
/// the factory's CREATE address from the deployer's nonce. `_FACTORY_NONCE_OFFSET` below is the
/// number of contract creations this script performs between reading the nonce and creating the
/// factory; the factory's landing address is asserted against the precomputed one, so a miscount
/// fails the deployment loudly instead of shipping four vaults permanently pointed at the wrong
/// registry.
///
/// Environment contract:
///   USDC_ADDRESS   the ERC-20 USDC for the target chain. Required on every chain, local
///                  included: this script never deploys a token. Arc testnet:
///                  0x3600000000000000000000000000000000000000. Local anvil: deploy
///                  `test/mocks/MockUSDC.sol:MockUSDC` first with `forge create` and pass its
///                  address here (keeping test-only code out of the production deploy path).
///   TREASURY       optional; the protocol treasury. Defaults to the deployer.
///   CONFIG_OWNER   optional; the address config and all four vaults' ownership is handed to at
///                  the end. Defaults to the deployer (the testnet
///                  posture: the config owner is a single EOA). On mainnet this is the
///                  TimelockController for the economic instance.
///   VENUE_OWNER    optional; the address all eight venues (two per FLEX/CORE pool type) and the
///                  fixed-term adapter are handed to. Defaults to CONFIG_OWNER. Set it separately
///                  on mainnet: the venues' owner functions are the every-epoch manual procedure,
///                  not economic parameters, and must not sit behind the timelock.
///   SKIP_SMOKE_COMMUNITY  optional, "true" to skip the end-of-script smoke community. The smoke community is
///                  a permanent artifact with the deployer as its founding steward and no removal
///                  path, so a deployment whose community directory is not throwaway should skip it
///                  and verify the wiring by other means. The smoke community runs a
///                  contribute/withdraw round against CORE, an instant-withdrawal round
///                  against FLEX, each spending
///                  `_SMOKE_AMOUNT` (50 USDC) of the deployer's own USDC: on anvil every mint is
///                  free via `MockUSDC.mint`; on every other chain the deployer must already hold
///                  that much real USDC per round. CORE's round returns its principal
///                  (cancel); FLEX's round only instant-withdraws half back, leaving the other
///                  half as a standing balance in the smoke FLEX ledger. Separately,
///                  `_SMOKE_AMOUNT` of USDC (regardless of `SKIP_SMOKE_COMMUNITY`) so it
///                  can pay real redemptions.
///
/// Run: forge script script/Deploy.s.sol --rpc-url <url> --broadcast
contract Deploy is Script {
    /// registry, config; three pool types x (vault, instant venue, slow venue); the community
    /// impl, the ledger impl, `Seats`. 2 + 3*3 + 3 = 14 creations before the factory. Changing
    /// what this script deploys before the factory means changing this number in the same
    /// commit; the assertion after the factory is created is what stops a miscount from shipping
    /// silently.
    uint256 internal constant _FACTORY_NONCE_OFFSET = 14;

    /// What each smoke round moves. It was the seat price floor, which is now 0.
    uint256 internal constant _SMOKE_AMOUNT = 50e6;

    /// Chains the testnet stand-ins may be deployed on: anvil and Arc testnet. `ManualStrategy` is
    /// the one that still carries the guard (`_deployManualStrategy`). The credit-pool stub carried
    /// one too until it was deleted, and that guard was the only thing refusing Arc mainnet.
    uint256 internal constant _ANVIL_CHAIN_ID = 31337;
    uint256 internal constant _ARC_TESTNET_CHAIN_ID = 5042002;
    uint256 internal constant _ARC_MAINNET_CHAIN_ID = 5042;

    /// The initial manual whitelist: one instant-tier venue and one notice-tier venue per pool
    /// type, so the tier machinery (instant floor, slow ceiling, notice periods, the FIFO redeem
    /// queue) is exercised from the first transaction rather than only in tests. Weights satisfy
    /// the launch defaults: instant >= INSTANT_TIER_FLOOR_BPS, slow <= SLOW_TIER_CEILING_BPS,
    /// and the total at most 10,000.
    uint64 internal constant _SLOW_VENUE_DELAY = 2 days;
    uint16 internal constant _INSTANT_WEIGHT_BPS = 7500;
    uint16 internal constant _SLOW_WEIGHT_BPS = 2500;

    // Deployment results live in script storage rather than in `run()`'s frame: the full order is
    // one linear sequence and reads best as one, but the many live locals four-times-over
    // overflow the stack under the legacy codegen this repo builds with (no `via_ir`).
    /// Dev key (the deployer) holds the screener role on testnet; on mainnet
    /// ownership hands to the Risk Committee timelock alongside config.
    ComplianceRegistry internal registry;
    Config internal config;
    /// Indexed by the `PoolTypes` constant, FLEX through TERM.
    // 3 is PoolTypes.COUNT, spelled out because a library constant is not a valid array length.
    // TERM is an ordinary tier.
    Venue[3] internal vaults;
    ManualStrategy[3] internal instantVenues;
    ManualStrategy[3] internal slowVenues;
    Community internal communityImpl;
    Seats internal seats;
    Ledger internal ledgerImpl;
    CommunityFactory internal factory;
    CreditStanding internal standing;
    CreditCore internal creditCore;

    function run() external {
        address usdc = vm.envAddress("USDC_ADDRESS");
        address deployer = msg.sender;
        address treasury = vm.envOr("TREASURY", deployer);
        address configOwner = vm.envOr("CONFIG_OWNER", deployer);

        console.log("chain id:", block.chainid);
        console.log("deployer:", deployer);
        console.log("USDC:    ", usdc);
        console.log("treasury:", treasury);

        address predictedFactory = vm.computeCreateAddress(deployer, vm.getNonce(deployer) + _FACTORY_NONCE_OFFSET);
        console.log("factory (precomputed):", predictedFactory);

        vm.startBroadcast();

        registry = new ComplianceRegistry(deployer);
        config = new Config(usdc, treasury, address(registry));

        // Creations only until the factory exists: see `_FACTORY_NONCE_OFFSET`.
        _deployPoolStack(usdc, predictedFactory, deployer);

        communityImpl = new Community();
        ledgerImpl = new Ledger();
        // `Seats` trusts one factory, fixed here, and the factory refuses a `Seats` that names
        // any other.
        seats = new Seats(predictedFactory);

        address[3] memory pools_;
        // Every slot is a Venue since 2026-09-21: TERM is an ordinary
        // tier, served by the same vault machinery as Flex and Core.
        for (uint8 i; i < PoolTypes.COUNT; i++) {
            pools_[i] = address(vaults[i]);
        }
        factory =
            new CommunityFactory(address(config), address(seats), address(communityImpl), address(ledgerImpl), pools_);
        // Loud, not silent: each vault's `factory` is immutable, so a nonce miscount here would
        // ship vaults that reject every real community ledger forever. The loop restates what each
        // vault was already constructed with (`predictedFactory`), so it follows once the first
        // require passes; kept only as defensive redundancy against a future edit that changes
        // what the vault constructor is handed, not an independent check.
        require(address(factory) == predictedFactory, "factory address mismatch");
        for (uint8 i; i < PoolTypes.COUNT; i++) {
            require(vaults[i].factory() == address(factory), "vault not wired to factory");
        }

        // ---- the credit singletons ----
        // After the factory, because both take it as an immutable constructor argument, and
        // before the smoke community, because a paid seat mint routes its pool leg to `CreditCore`
        // and reverts `CreditCoreUnset` while the config key is zero. Neither is created before
        // the factory, so `_FACTORY_NONCE_OFFSET` is unaffected.
        standing = new CreditStanding(IConfig(address(config)), address(factory), deployer);
        creditCore = new CreditCore(
            IERC20(usdc),
            IConfig(address(config)),
            address(factory),
            deployer,
            vm.envOr("TREASURY_MANAGER", deployer),
            vm.envOr("ALLOCATION_MULTISIG", deployer),
            ICreditStanding(address(standing))
        );
        standing.setCreditCore(address(creditCore));
        // The dev key attributes impact until the real role is wired.
        standing.setImpactAttributor(vm.envOr("IMPACT_ATTRIBUTOR", deployer));
        config.setAddress(K.CREDIT_CORE, address(creditCore));
        require(config.creditCore() == address(creditCore), "credit core not wired");

        // ---- venue whitelist and weights (owner-only, deployer is every vault's owner) ----
        _wireVenues();

        // ---- wire addresses into config ----
        // `Config` holds exactly two address parameters, PROTOCOL_TREASURY and
        // COMPLIANCE_REGISTRY, both already set by the constructor above. There is no config slot for the vaults or the
        // factory: ledgers reach their vault through `CommunityFactory`'s immutable `pools` array, and
        // each vault reaches the registry through its own immutable `factory`. Nothing further to
        // wire; re-asserted here so a future reader does not go looking for a missing step.
        require(config.complianceRegistry() == address(registry), "compliance registry not wired");
        require(config.protocolTreasury() == treasury, "treasury not wired");

        // ---- smoke community: proves clone init, factory registration, tier resolution
        // path, and ledger/vault deposit/redeem wiring ----
        // Optional, because it is permanent: the deployer becomes its founding steward, holds an
        // unpaid founding seat, and there is no path to remove the community from the factory's
        // directory afterwards. Fine on a throwaway chain, unwanted on one whose community list is
        // shown to real users.
        if (!vm.envOr("SKIP_SMOKE_COMMUNITY", false)) {
            // The founding mint in `createCommunity` requires the creator to have
            // self-attested. Done here rather than right after the registry is deployed
            // because any broadcast call between the nonce read and the factory creation
            // would move the factory's predicted address (see `_FACTORY_NONCE_OFFSET`).
            registry.attest(1);
            _createSmokeCommunity(deployer, usdc);
        } else {
            console.log("smoke community: SKIPPED (SKIP_SMOKE_COMMUNITY=true)");
        }

        // ---- ownership handover, last ----
        // `Ownable2Step`: this only nominates. The recipient must call `acceptOwnership()` on
        // each contract to take it, which is the point (a fat-fingered address cannot orphan the
        // deployment). Skipped entirely when the deployer keeps ownership, which is the local and
        // testnet default, since nominating yourself is a no-op that still costs transactions.
        //
        // Two owners, not one: a timelock for economic control and a multisig for
        // operations. Config and every vault are
        // economic: parameter changes and venue whitelisting are exactly what the timelock exists
        // to slow down. The venues are operational: `fund`, `skim`, and `setRedeemDelay` are the
        // manual epoch procedure, run every epoch, and putting them behind a timelock would make
        // the ops runbook unrunnable. `VENUE_OWNER` defaults to `CONFIG_OWNER` so a single-owner
        // deployment stays a single variable.
        address venueOwner = vm.envOr("VENUE_OWNER", configOwner);
        if (configOwner != deployer) {
            config.transferOwnership(configOwner);
            // The registry owner is the Risk Committee: it rotates the screener key.
            // The screener role itself stays on the dev key for now.
            registry.transferOwnership(configOwner);
            for (uint8 i; i < PoolTypes.COUNT; i++) {
                vaults[i].transferOwnership(configOwner);
            }
            console.log("config + registry + vaults ownership NOMINATED to (must acceptOwnership):", configOwner);
        }
        if (venueOwner != deployer) {
            for (uint8 i; i < PoolTypes.COUNT; i++) {
                instantVenues[i].transferOwnership(venueOwner);
                slowVenues[i].transferOwnership(venueOwner);
            }
            // `setOfferedRate`/`returnFrom` are the same kind of operational, run-every-epoch
            console.log("venue ownership NOMINATED to (must acceptOwnership):", venueOwner);
        }

        vm.stopBroadcast();

        console.log("registry:      ", address(registry));
        console.log("config:        ", address(config));
        for (uint8 i; i < PoolTypes.COUNT; i++) {
            console.log(string.concat("vault[", _poolLabel(i), "]:"), address(vaults[i]));
            console.log(string.concat("instantVenue[", _poolLabel(i), "]:"), address(instantVenues[i]));
            console.log(string.concat("slowVenue[", _poolLabel(i), "]:"), address(slowVenues[i]));
        }
        console.log("communityImpl: ", address(communityImpl));
        console.log("seats:         ", address(seats));
        console.log("ledgerImpl:    ", address(ledgerImpl));
        console.log("factory:       ", address(factory));
        console.log("creditStanding:", address(standing));
        console.log("creditCore:    ", address(creditCore));
    }

    /// The three shared vaults and their six venues, in one creation-only block. The array index
    /// IS the `PoolTypes` constant (FLEX 0 .. TERM 2), which is what makes the `pools_` array
    /// handed to the factory line up slot for slot. Nothing here may make a non-creation broadcast
    /// call: `setRedeemDelay`, `addVenue` and `setWeights` all wait for `_wireVenues`, after the
    /// factory has landed at its predicted address.
    function _deployPoolStack(address usdc, address predictedFactory, address deployer) internal {
        string[3] memory names = ["Qudi Flex", "Qudi Core", "Qudi Term"];
        string[3] memory symbols = ["qFLEX", "qCORE", "qTERM"];
        for (uint8 i; i < PoolTypes.COUNT; i++) {
            vaults[i] =
                new Venue(IERC20(usdc), IConfig(address(config)), predictedFactory, i, deployer, names[i], symbols[i]);
            instantVenues[i] = _deployManualStrategy(
                usdc, deployer, string.concat(names[i], " Instant Venue"), string.concat(symbols[i], "-VI")
            );
            slowVenues[i] = _deployManualStrategy(
                usdc, deployer, string.concat(names[i], " Notice Venue"), string.concat(symbols[i], "-VN")
            );
        }
    }

    /// Whitelists both venues on each vault and sets the tier weights. The notice delay is set
    /// BEFORE `addVenue`, because `addVenue` reads `redeemDelay()` once and files the venue in the
    /// instant or slow tier on the spot; setting the delay afterwards would leave a two-day venue
    /// counted as instant liquidity forever. The two `isInstant` assertions are what make that
    /// ordering mistake fail the deployment instead of shipping.
    function _wireVenues() internal {
        for (uint8 i; i < PoolTypes.COUNT; i++) {
            slowVenues[i].setRedeemDelay(_SLOW_VENUE_DELAY);
            vaults[i].addVenue(address(instantVenues[i]));
            vaults[i].addVenue(address(slowVenues[i]));
            require(vaults[i].isInstant(address(instantVenues[i])), "instant venue filed as slow");
            require(!vaults[i].isInstant(address(slowVenues[i])), "slow venue filed as instant");

            address[] memory venues_ = new address[](2);
            uint16[] memory bps = new uint16[](2);
            venues_[0] = address(instantVenues[i]);
            venues_[1] = address(slowVenues[i]);
            bps[0] = _INSTANT_WEIGHT_BPS;
            bps[1] = _SLOW_WEIGHT_BPS;
            vaults[i].setWeights(venues_, bps);
        }
    }

    /// Pool-type name for the printed address block, so an operator reading the log sees
    /// `vault[CORE]` rather than an index they have to decode.
    function _poolLabel(uint8 poolType) internal pure returns (string memory) {
        if (poolType == PoolTypes.FLEX) return "FLEX";
        if (poolType == PoolTypes.CORE) return "CORE";
        if (poolType == PoolTypes.TERM) return "TERM";
        revert("unknown pool type");
    }

    /// `ManualStrategy` is a fake: its share price moves by hand, with `fund` adding USDC without
    /// minting and `skim` removing it without burning. Its own header says "Never deployed to
    /// mainnet" and, until 2026-09-21, said it in a comment and nothing else. The only thing
    /// stopping ten of them reaching Arc mainnet was that the credit-pool stub's own guard
    /// happened to revert first, which was protection by accident; that guard was deleted,
    /// and this guard is
    /// now the only one refusing the stand-ins on a real chain.
    ///
    /// The guard is a hard allowlist with no environment override on purpose: an override is a
    /// flag someone can set under pressure, and this is the one deployment mistake that cannot be
    /// undone. Adding a chain is a reviewable code change.
    function _deployManualStrategy(address usdc_, address deployer_, string memory name_, string memory symbol_)
        internal
        returns (ManualStrategy)
    {
        require(
            block.chainid == _ANVIL_CHAIN_ID || block.chainid == _ARC_TESTNET_CHAIN_ID
                || block.chainid == _ARC_MAINNET_CHAIN_ID,
            "ManualStrategy: unsupported chain"
        );
        return new ManualStrategy(IERC20(usdc_), deployer_, name_, symbol_);
    }

    /// The smoke community created at the end, purely to prove clone-init, factory registration and
    /// the money paths work end to end. Its seat price is read from config rather than hardcoded
    /// so it can never fall outside the range.
    function _createSmokeCommunity(address deployer, address usdc) internal {
        address communityAddr = factory.createCommunity("Smoke Community", config.seatPriceFloor());
        require(seats.isRegistered(communityAddr), "smoke community not registered with Seats");
        require(seats.balanceOf(deployer) == 1, "smoke founding seat not minted in Seats");
        require(factory.isCommunityContract(communityAddr), "smoke community not registered");
        require(factory.communityIdOf(communityAddr) == 1, "smoke community is not community 0");
        console.log("smoke community:", communityAddr);

        // Every tier is available from the moment the community exists:
        // nothing opens one, and the ledger resolves each tier's vault from the factory's own
        // `pools` the first time a record names it.
        address ledger = factory.ledgerOf(communityAddr);
        require(ledger != address(0), "smoke ledger not deployed");
        require(factory.isCommunityContract(ledger), "smoke ledger not registered");
        console.log("smoke ledger:  ", ledger);

        for (uint8 t; t < PoolTypes.COUNT; t++) {
            require(
                Ledger(ledger).tierVault(t) == address(vaults[t]), "smoke ledger resolves a tier to the wrong vault"
            );
            require(factory.vaultOf(communityAddr, t) == ledger, "smoke tier does not answer with the ledger");
        }

        _smokeContributeWithdrawRound(deployer, usdc, ledger, PoolTypes.CORE, _SMOKE_AMOUNT);

        // ---- FLEX: one instant withdrawal, proving Ledger.withdrawInstant end to end ----
        _smokeInstantWithdrawal(deployer, usdc, ledger, _SMOKE_AMOUNT);

        // ---- TERM: opened as an ordinary tier since 2026-09-21. It needs
        // no smoke round of its own: it is the same Ledger against the same Venue the
        // FLEX round above already proves, differing only in which venues sit under it and how
        // long its declared withdrawal period is.
    }

    /// One contribute/withdraw round against the CORE ledger: contribute `amount`, queue its
    /// full withdrawal, then cancel the request rather than waiting out CORE's real withdrawal
    /// term (`config.withdrawTerm`, a real multi-day term this script cannot fast-forward on a
    /// live chain). `cancelWithdraw` has no cooldown of its own, so this proves `contribute` ->
    /// `Venue.deposit` -> `requestWithdraw` -> `cancelWithdraw` end to end without waiting on
    /// wall-clock time.
    function _smokeContributeWithdrawRound(
        address deployer,
        address usdc,
        address ledger,
        uint8 poolType,
        uint256 amount
    ) internal {
        if (block.chainid == _ANVIL_CHAIN_ID) {
            // MockUSDC's `mint` is open to anyone; funding the round this way keeps the script
            // runnable against a fresh anvil chain with no other setup than what the
            // USDC_ADDRESS doc comment already asks for.
            IMintableTestUsdc(usdc).mint(deployer, amount);
        }

        IERC20(usdc).approve(ledger, amount);
        Ledger smokeLedger = Ledger(ledger);
        uint256 vaultId = smokeLedger.createVault(_smokeVaultParams(poolType, "Smoke savings"));
        smokeLedger.deposit(vaultId, amount);
        require(smokeLedger.vaultBalance(vaultId) == amount, "smoke deposit did not credit the vault");

        uint256 requestId = smokeLedger.requestWithdraw(vaultId, amount);
        smokeLedger.cancelWithdraw(requestId);
        require(smokeLedger.vaultBalance(vaultId) == amount, "smoke withdraw round did not restore the balance");

        console.log("smoke contribute/withdraw round: OK, amount:", amount);
    }

    /// One instant withdrawal against the FLEX ledger: contribute `amount`, then withdraw half of
    /// it same-block via `Ledger.withdrawInstant`. Half, not the full amount, so the smoke
    /// FLEX pool is left holding a real standing balance the app can show; the vault serves the
    /// payout from idle USDC either way, since nothing has called `rebalance()` to push the
    /// contribution out to the venues yet.
    function _smokeInstantWithdrawal(address deployer, address usdc, address ledger, uint256 amount) internal {
        if (block.chainid == _ANVIL_CHAIN_ID) {
            IMintableTestUsdc(usdc).mint(deployer, amount);
        }

        IERC20(usdc).approve(ledger, amount);
        Ledger smokeLedger = Ledger(ledger);
        uint256 vaultId = smokeLedger.createVault(_smokeVaultParams(PoolTypes.FLEX, "Smoke flex"));
        smokeLedger.deposit(vaultId, amount);
        require(smokeLedger.vaultBalance(vaultId) == amount, "smoke FLEX deposit did not credit the vault");

        uint256 walletBefore = IERC20(usdc).balanceOf(deployer);
        uint256 withdrawAmount = amount / 2;
        smokeLedger.withdrawInstant(vaultId, withdrawAmount);
        require(
            smokeLedger.vaultBalance(vaultId) == amount - withdrawAmount,
            "smoke FLEX instant withdrawal did not debit the vault"
        );
        require(
            IERC20(usdc).balanceOf(deployer) == walletBefore + withdrawAmount,
            "smoke FLEX instant withdrawal did not pay out wallet"
        );

        console.log("smoke FLEX instant withdrawal: OK, amount:", withdrawAmount);
    }

    /// An open, personal, anytime record: the plainest vault the smoke rounds can use, so what
    /// they prove is the tier wiring and the money path rather than any one axis combination.
    function _smokeVaultParams(uint8 poolType, string memory name_) internal pure returns (ILedger.VaultParams memory) {
        return ILedger.VaultParams({
            poolType: poolType, shared: false, lockedUntil: 0, contribution: 0, name: name_, target: 0, targetDate: 0
        });
    }
}
