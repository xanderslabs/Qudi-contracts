// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.30;

import {Script, console} from "forge-std/Script.sol";
import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {Config} from "../src/Config.sol";
import {IConfig} from "../src/interfaces/IConfig.sol";
import {ComplianceRegistry} from "../src/ComplianceRegistry.sol";
import {ManualStrategy} from "../src/ManualStrategy.sol";
import {Venue} from "../src/Venue.sol";
import {IVenue} from "../src/interfaces/IVenue.sol";
import {Community} from "../src/Community.sol";
import {Seats} from "../src/Seats.sol";
import {Ledger} from "../src/Ledger.sol";
import {ILedger} from "../src/interfaces/ILedger.sol";
import {CommunityFactory} from "../src/CommunityFactory.sol";
import {CreditCore} from "../src/CreditCore.sol";
import {CreditStanding} from "../src/CreditStanding.sol";
import {ICreditStanding} from "../src/interfaces/ICreditStanding.sol";
import {CloneImpactSource} from "../src/CloneImpactSource.sol";
import {ICommunityFactory} from "../src/interfaces/ICommunityFactory.sol";
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
///   compliance registry -> config -> implementations -> factory -> venues + strategies -> venue wiring
///   -> config wiring assertions -> smoke community -> ownership handover
///
/// Two orderings worth naming, both forced rather than chosen:
///   - the compliance registry is deployed BEFORE config, because
///     `Config(usdc, treasury, complianceRegistry)` takes its address and rejects zero;
///   - every other call happens AFTER the factory is created, never between the nonce read and the
///     factory, because each broadcast call advances the deployer's nonce and would move the
///     factory's predicted address.
/// `CreditStanding` and `CreditCore` are deployed here, and
/// `Config.CREDIT_CORE` is set to the latter. Both come AFTER the factory, because each takes
/// it as an immutable constructor argument, and BEFORE the smoke community, because a paid seat mint
/// routes its pool leg to `CreditCore` and reverts `CreditCoreUnset` while the key is zero.
/// Neither is created before the factory, so `_FACTORY_NONCE_OFFSET` is unaffected.
///
/// **`ManualStrategy` reaches Arc mainnet for the beta, deliberately.** Its yield is paid in by
/// Qudi's operator ahead of time and released at a set rate, so this is a deployment whose yield
/// is what Qudi funds. It is not a third-party venue and must not be described as one. A partner
/// strategy plugs in beside it later through the same interface.
///
/// Three `Venue` instances, each over one `ManualStrategy`, listed in the factory's venue registry
/// in order: Flex (id 0), Core (id 1), Term (id 2). A `Venue` takes the factory's address as an
/// immutable, but the factory no longer takes the venues, so the venues are created after it. The
/// one circular constructor dependency left is between `Seats` and the factory, resolved by
/// precomputing the factory's CREATE address from the deployer's nonce. `_FACTORY_NONCE_OFFSET`
/// below is the number of contract creations this script performs between reading the nonce and
/// creating the factory; the factory's landing address is asserted against the precomputed one, so
/// a miscount fails the deployment loudly.
///
/// Environment contract:
///   USDC_ADDRESS   the ERC-20 USDC for the target chain. Required on every chain, local
///                  included: this script never deploys a token. Arc testnet:
///                  0x3600000000000000000000000000000000000000. Local anvil: deploy
///                  `test/mocks/MockUSDC.sol:MockUSDC` first with `forge create` and pass its
///                  address here (keeping test-only code out of the production deploy path).
///   TREASURY       optional; the protocol treasury. Defaults to the deployer.
///   CONFIG_OWNER   optional; the address config, the registry, the factory, the three venues and
///                  the three strategies are handed to at the end. Defaults to the deployer (the
///                  testnet posture: the config owner is a single EOA). On mainnet this is the
///                  TimelockController.
///   CREDIT_AGREEMENT_HASH  required; the hash of the Credit Agreement a member's first draw
///                  must carry.
///   STRATEGY_OPERATOR  optional; each `ManualStrategy`'s operator, who funds yield, sets the rate,
///                  deploys to listed destinations, returns money and reports losses. Defaults to
///                  the deployer. Not behind the timelock: those are routine steps, and the
///                  timelock already decides where money may go.
///   SKIP_SMOKE_COMMUNITY  optional, "true" to skip the end-of-script smoke community. The smoke community is
///                  a permanent artifact with the deployer as its founding steward and no removal
///                  path, so a deployment whose community directory is not throwaway should skip it
///                  and verify the wiring by other means. The smoke community opens one
///                  personal vault in each of the three venues and deposits
///                  `_SMOKE_AMOUNT` (50 USDC) of the deployer's own USDC into each: on anvil every
///                  mint is free via `MockUSDC.mint`; on every other chain the deployer must
///                  already hold that much real USDC per vault. The deposits stay as standing
///                  balances, and the Term one is locked for a day. Separately,
///                  `_SMOKE_AMOUNT` of USDC (regardless of `SKIP_SMOKE_COMMUNITY`) so it
///                  can pay real redemptions.
///
/// Run: forge script script/Deploy.s.sol --rpc-url <url> --broadcast
contract Deploy is Script {
    /// registry, config, the community impl, the ledger impl, `Seats`: 5 creations before the
    /// factory. Changing what this script deploys before the factory means changing this number in
    /// the same commit; the assertion after the factory is created is what stops a miscount from
    /// shipping silently.
    uint256 internal constant _FACTORY_NONCE_OFFSET = 5;

    /// What each smoke vault takes. It was the seat price floor, which is now 0.
    uint256 internal constant _SMOKE_AMOUNT = 50e6;

    /// Chains the testnet stand-ins may be deployed on: anvil and Arc testnet. `ManualStrategy` is
    /// the one that still carries the guard (`_deployManualStrategy`). The credit-pool stub carried
    /// one too until it was deleted, and that guard was the only thing refusing Arc mainnet.
    uint256 internal constant _ANVIL_CHAIN_ID = 31337;
    uint256 internal constant _ARC_TESTNET_CHAIN_ID = 5042002;
    uint256 internal constant _ARC_MAINNET_CHAIN_ID = 5042;

    /// Venue ids in the factory's registry, in the order this script lists them.
    uint8 internal constant _FLEX = 0;
    uint8 internal constant _CORE = 1;
    uint8 internal constant _TERM = 2;
    uint8 internal constant _VENUES = 3;

    /// Each venue's one `ManualStrategy` is listed with no exit delay, because its principal cash
    /// can be withdrawn at once, and holds this share of the venue; the rest stays idle as the
    /// venue's cash buffer. Inside the launch group limits.
    uint16 internal constant _STRATEGY_WEIGHT_BPS = 7500;

    // Deployment results live in script storage rather than in `run()`'s frame: the full order is
    // one linear sequence and reads best as one, but the many live locals four-times-over
    // overflow the stack under the legacy codegen this repo builds with (no `via_ir`).
    /// Dev key (the deployer) holds the screener role on testnet; on mainnet
    /// ownership hands to the Risk Committee timelock alongside config.
    ComplianceRegistry internal registry;
    Config internal config;
    /// Indexed by venue id, Flex through Term.
    Venue[3] internal vaults;
    ManualStrategy[3] internal strategies;
    Community internal communityImpl;
    Seats internal seats;
    Ledger internal ledgerImpl;
    CommunityFactory internal factory;
    CreditStanding internal standing;
    CreditCore internal creditCore;
    CloneImpactSource internal seatSource;
    CloneImpactSource internal yieldSource;

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
        communityImpl = new Community();
        ledgerImpl = new Ledger();
        // `Seats` trusts one factory, fixed here, and the factory refuses a `Seats` that names
        // any other.
        seats = new Seats(predictedFactory, IConfig(address(config)));

        factory = new CommunityFactory(
            address(config), address(seats), address(communityImpl), address(ledgerImpl), deployer
        );
        // Loud, not silent: `Seats` trusts one factory, fixed at its construction, so a nonce
        // miscount here would ship a `Seats` that refuses every community.
        require(address(factory) == predictedFactory, "factory address mismatch");

        _deployVenues(usdc, deployer, vm.envOr("STRATEGY_OPERATOR", deployer));

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
        // The two impact sources: the seat leg in each community's `Community` and the yield leg in
        // each community's `Ledger`, both reached through the factory. No pool strategy is listed
        // yet; the pool holds only community balances until one is.
        seatSource = new CloneImpactSource(ICommunityFactory(address(factory)), false);
        yieldSource = new CloneImpactSource(ICommunityFactory(address(factory)), true);
        standing.addImpactSource(address(seatSource));
        standing.addImpactSource(address(yieldSource));
        config.setAddress(K.CREDIT_CORE, address(creditCore));
        require(config.creditCore() == address(creditCore), "credit core not wired");
        // The Credit Agreement members sign on their first draw. Credit stays shut until it is set.
        config.setCreditAgreementHash(vm.envBytes32("CREDIT_AGREEMENT_HASH"));

        // ---- labels, strategies, weights and the registry (the deployer owns all of them) ----
        _wireVenues();

        // ---- wire addresses into config ----
        // `Config` holds exactly two address parameters, PROTOCOL_TREASURY and
        // COMPLIANCE_REGISTRY, both already set by the constructor above. There is no config slot for the vaults or the
        // factory: ledgers reach their venue through `CommunityFactory`'s venue registry, and
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
        // One owner for all of it. The strategies' routine steps belong to their operator, not
        // their owner, so nothing an operator runs every day sits behind the timelock.
        if (configOwner != deployer) {
            config.transferOwnership(configOwner);
            // The registry owner is the Risk Committee: it rotates the screener key.
            // The screener role itself stays on the dev key for now.
            registry.transferOwnership(configOwner);
            factory.transferOwnership(configOwner);
            for (uint8 i; i < _VENUES; i++) {
                vaults[i].transferOwnership(configOwner);
                strategies[i].transferOwnership(configOwner);
            }
            console.log("ownership NOMINATED to (must acceptOwnership):", configOwner);
        }

        vm.stopBroadcast();

        console.log("registry:      ", address(registry));
        console.log("config:        ", address(config));
        for (uint8 i; i < _VENUES; i++) {
            console.log(string.concat("venue[", _poolLabel(i), "]:"), address(vaults[i]));
            console.log(string.concat("strategy[", _poolLabel(i), "]:"), address(strategies[i]));
        }
        console.log("communityImpl: ", address(communityImpl));
        console.log("seats:         ", address(seats));
        console.log("ledgerImpl:    ", address(ledgerImpl));
        console.log("factory:       ", address(factory));
        console.log("creditStanding:", address(standing));
        console.log("creditCore:    ", address(creditCore));
        console.log("seatSource:    ", address(seatSource));
        console.log("yieldSource:   ", address(yieldSource));
    }

    /// The three venues and their strategies. The array index is the venue id the registry hands
    /// out in `_wireVenues`, which asserts it.
    function _deployVenues(address usdc, address deployer, address operator) internal {
        string[3] memory names = ["Qudi Flex", "Qudi Core", "Qudi Term"];
        string[3] memory symbols = ["qFLEX", "qCORE", "qTERM"];
        for (uint8 i; i < _VENUES; i++) {
            vaults[i] =
                new Venue(IERC20(usdc), IConfig(address(config)), address(factory), deployer, names[i], symbols[i]);
            strategies[i] = _deployManualStrategy(usdc, address(vaults[i]), deployer, operator);
        }
    }

    /// The labels each venue is shown with. `maxRateBps` sits a little above the gross the
    /// strategy earns, so the cap binds only on a jump.
    function _labels(uint8 id) internal pure returns (IVenue.Labels memory) {
        if (id == _FLEX) {
            return IVenue.Labels({
                name: "Flex", kind: IVenue.Kind.Open, riskKey: 1, estReturnBps: 200, exitSeconds: 0, maxRateBps: 300
            });
        }
        if (id == _CORE) {
            return IVenue.Labels({
                name: "Core",
                kind: IVenue.Kind.Open,
                riskKey: 3,
                estReturnBps: 350,
                exitSeconds: 1 days,
                maxRateBps: 520
            });
        }
        return IVenue.Labels({
            name: "Term", kind: IVenue.Kind.Locked, riskKey: 3, estReturnBps: 450, exitSeconds: 0, maxRateBps: 660
        });
    }

    /// Labels each venue, lists its strategy with a cap of the global deposit cap (one strategy may
    /// hold everything the venue can take), sets its weight, and lists the venue in the registry,
    /// asserting the id it gets is its index.
    function _wireVenues() internal {
        for (uint8 i; i < _VENUES; i++) {
            vaults[i].setLabels(_labels(i));
            vaults[i].addStrategy(address(strategies[i]), 0);
            vaults[i].setCap(address(strategies[i]), config.globalDepositCap());
            address[] memory list = new address[](1);
            uint16[] memory bps = new uint16[](1);
            list[0] = address(strategies[i]);
            bps[0] = _STRATEGY_WEIGHT_BPS;
            vaults[i].setWeights(list, bps);
            require(factory.addVenue(address(vaults[i])) == i, "venue listed under the wrong id");
        }
    }

    /// Venue name for the printed address block, so an operator reading the log sees
    /// `venue[CORE]` rather than an index they have to decode.
    function _poolLabel(uint8 id) internal pure returns (string memory) {
        if (id == _FLEX) return "FLEX";
        if (id == _CORE) return "CORE";
        if (id == _TERM) return "TERM";
        revert("unknown venue");
    }

    /// `ManualStrategy` pays a yield Qudi funds by hand, so it belongs only on the chains listed
    /// here: anvil, Arc testnet, and Arc mainnet for the beta.
    ///
    /// The guard is a hard allowlist with no environment override on purpose: an override is a
    /// flag someone can set under pressure, and this is the one deployment mistake that cannot be
    /// undone. Adding a chain is a reviewable code change.
    function _deployManualStrategy(address usdc_, address venue_, address owner_, address operator_)
        internal
        returns (ManualStrategy)
    {
        require(
            block.chainid == _ANVIL_CHAIN_ID || block.chainid == _ARC_TESTNET_CHAIN_ID
                || block.chainid == _ARC_MAINNET_CHAIN_ID,
            "ManualStrategy: unsupported chain"
        );
        return new ManualStrategy(IERC20(usdc_), IConfig(address(config)), venue_, owner_, operator_);
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
        // venue registry the first time a record names it.
        address ledger = factory.ledgerOf(communityAddr);
        require(ledger != address(0), "smoke ledger not deployed");
        require(factory.isCommunityContract(ledger), "smoke ledger not registered");
        console.log("smoke ledger:  ", ledger);

        for (uint8 t; t < _VENUES; t++) {
            require(
                Ledger(ledger).tierVault(t) == address(vaults[t]), "smoke ledger resolves a tier to the wrong vault"
            );
            require(factory.vaultOf(communityAddr, t) == ledger, "smoke tier does not answer with the ledger");
        }

        for (uint8 t; t < _VENUES; t++) {
            _smokeDeposit(deployer, usdc, ledger, t, _SMOKE_AMOUNT);
        }
    }

    /// One personal vault in venue `venueId`, and one deposit of `amount` into it. A Term vault
    /// carries a one-day lock, because a Locked-kind venue takes no vault without one.
    function _smokeDeposit(address deployer, address usdc, address ledger, uint8 venueId, uint256 amount) internal {
        if (block.chainid == _ANVIL_CHAIN_ID) {
            // MockUSDC's `mint` is open to anyone; funding the deposit this way keeps the script
            // runnable against a fresh anvil chain with no other setup than what the
            // USDC_ADDRESS doc comment already asks for.
            IMintableTestUsdc(usdc).mint(deployer, amount);
        }

        IERC20(usdc).approve(ledger, amount);
        Ledger smokeLedger = Ledger(ledger);
        uint64 lockedUntil = vaults[venueId].labels().kind == IVenue.Kind.Locked ? uint64(block.timestamp + 1 days) : 0;
        uint256 vaultId = smokeLedger.createVault(
            ILedger.VaultParams({venueId: venueId, shared: false, lockedUntil: lockedUntil, name: "Smoke savings"})
        );
        smokeLedger.deposit(vaultId, amount);
        require(smokeLedger.vaultValue(vaultId) == amount, "smoke deposit did not credit the vault");
        require(smokeLedger.vaultCapital(vaultId) == amount, "smoke deposit did not record its capital");

        console.log("smoke deposit: OK, venue:", _poolLabel(venueId));
    }
}
