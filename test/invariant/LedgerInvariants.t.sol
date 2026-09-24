// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";
import {Clones} from "openzeppelin-contracts/contracts/proxy/Clones.sol";
import {Ledger} from "../../src/Ledger.sol";
import {ILedger} from "../../src/interfaces/ILedger.sol";
import {ICommunityInit} from "../../src/interfaces/ICommunityInit.sol";
import {Venue} from "../../src/Venue.sol";
import {Config} from "../../src/Config.sol";
import {IConfig} from "../../src/interfaces/IConfig.sol";
import {ConfigKeys as K} from "../../src/ConfigKeys.sol";
import {ComplianceRegistry} from "../../src/ComplianceRegistry.sol";
import {VenueIds} from "../helpers/VenueIds.sol";
import {VaultStatus} from "../../src/VaultStatus.sol";
import {MockUSDC} from "../mocks/MockUSDC.sol";
import {MockStrategy} from "../mocks/MockStrategy.sol";
import {LedgerFactoryStub, LedgerCommunityStub, LedgerCreditCoreStub} from "../helpers/LedgerFixture.sol";

/// Drives one real ledger over two real `Venue` tiers, with several vault records in each so
/// the tier position is genuinely divided rather than held by one record. Every verb no-ops
/// rather than reverting on a failed precondition, and every ghost moves only on a success path,
/// matching the other harnesses under `test/invariant/`.
contract LedgerHandler is Test {
    Ledger public ledger;
    Venue public flexVault;
    Venue public coreVault;
    IConfig public config;
    MockUSDC public usdc;
    LedgerCommunityStub public community;

    uint256 internal constant ACTORS = 4;
    address[ACTORS] public actors;

    /// Two records per tier, so `tierUnits` is a sum of several terms and not a restatement of
    /// one. Index 0 and 1 are FLEX, 2 and 3 are CORE; index 0 is the shared one.
    uint256 internal constant VAULTS = 4;
    uint256[VAULTS] public vaultIds;

    uint256 internal constant MIN_DEPOSIT = 1e6;
    uint256 internal constant MAX_DEPOSIT = 10_000e6;
    /// Bounded so the share price stays in a sane band over a deep campaign rather than running
    /// away from unity, where every `convertToAssets` floor would cost more than the tolerances
    /// below allow.
    uint256 internal constant MAX_GAIN = 5_000e6;

    /// Any deposit that sent something to the credit core, measured across that single call.
    /// Must stay zero: money in buys units, whatever the member owes.
    uint256 public depositsRoutedToCredit;

    uint256[] internal _requestIds;
    mapping(uint256 => address) internal _requester;
    uint256[] internal _proposalIds;

    constructor(Ledger ledger_, LedgerCommunityStub community_, uint256[VAULTS] memory ids) {
        ledger = ledger_;
        flexVault = Venue(ledger_.tierVault(VenueIds.FLEX));
        coreVault = Venue(ledger_.tierVault(VenueIds.CORE));
        config = ledger_.config();
        usdc = MockUSDC(config.usdc());
        community = community_;
        vaultIds = ids;
        for (uint256 i = 0; i < ACTORS; i++) {
            actors[i] = address(uint160(uint256(keccak256(abi.encode("ledger-actor", i)))));
        }
    }

    function _pickActor(uint256 seed) internal view returns (address) {
        return actors[seed % ACTORS];
    }

    function _pickVault(uint256 seed) internal view returns (uint256) {
        return vaultIds[seed % VAULTS];
    }

    // ---- views the invariants read ----

    function vaultCount() external pure returns (uint256) {
        return VAULTS;
    }

    /// The sum of `vaultUnits` over the ACTIVE records in one tier, which is the left-hand side
    /// of the first reconciliation equality.
    function sumActiveVaultUnits(uint8 poolType) external view returns (uint256 total) {
        for (uint256 i = 0; i < VAULTS; i++) {
            (uint8 t,,,,, uint8 status,,,) = ledger.vaults(vaultIds[i]);
            if (t == poolType && status == VaultStatus.ACTIVE) total += ledger.vaultUnits(vaultIds[i]);
        }
    }

    function sumEarmarks() external view returns (uint256 total) {
        for (uint256 i = 0; i < VAULTS; i++) {
            total += ledger.earmarkedUnits(vaultIds[i]);
        }
    }

    // ---- money in ----

    function deposit(uint256 actorSeed, uint256 vaultSeed, uint256 amountSeed) external {
        address m = _pickActor(actorSeed);
        uint256 id = _pickVault(vaultSeed);
        uint256 amount = bound(amountSeed, MIN_DEPOSIT, MAX_DEPOSIT);
        uint256 creditBefore = usdc.balanceOf(address(0xC0DE));

        usdc.mint(m, amount);
        vm.prank(m);
        usdc.approve(address(ledger), amount);
        vm.prank(m);
        try ledger.deposit(id, amount) {
            if (usdc.balanceOf(address(0xC0DE)) != creditBefore) depositsRoutedToCredit++;
        } catch {}
    }

    // ---- money out ----

    function requestWithdraw(uint256 actorSeed, uint256 vaultSeed, uint256 amountSeed) external {
        address m = _pickActor(actorSeed);
        uint256 id = _pickVault(vaultSeed);
        uint256 worth = ledger.vaultBalance(id);
        if (worth == 0) return;
        vm.prank(m);
        try ledger.requestWithdraw(id, bound(amountSeed, 1, worth)) returns (uint256 rid) {
            _requestIds.push(rid);
            _requester[rid] = m;
        } catch {}
    }

    /// `jumpSeed` decides, per call, whether to first advance the clock to this request's own
    /// release time. Half the calls do, so executions actually happen; half attempt it wherever
    /// the clock is, which keeps the cooldown a live rejection rather than a formality.
    function executeWithdraw(uint256 idSeed, uint256 jumpSeed) external {
        if (_requestIds.length == 0) return;
        uint256 id = _requestIds[idSeed % _requestIds.length];
        if (jumpSeed % 2 == 0) {
            uint256 due = ledger.releaseAfter(id);
            if (block.timestamp < due) vm.warp(due);
        }
        vm.prank(_requester[id]);
        try ledger.executeWithdraw(id) {} catch {}
    }

    function cancelWithdraw(uint256 idSeed) external {
        if (_requestIds.length == 0) return;
        uint256 id = _requestIds[idSeed % _requestIds.length];
        vm.prank(_requester[id]);
        try ledger.cancelWithdraw(id) {} catch {}
    }

    function withdrawInstant(uint256 actorSeed, uint256 vaultSeed, uint256 amountSeed) external {
        address m = _pickActor(actorSeed);
        uint256 id = _pickVault(vaultSeed);
        uint256 worth = ledger.vaultBalance(id);
        if (worth == 0) return;
        vm.prank(m);
        try ledger.withdrawInstant(id, bound(amountSeed, 1, worth)) {} catch {}
    }

    // ---- the shared withdrawal ----

    function proposeWithdrawal(uint256 amountSeed) external {
        uint256 id = vaultIds[0]; // the shared one
        // Asked in USDC, as a host asks; the ledger converts to units once, at proposal time.
        uint256 free = ledger.availableBalance(id);
        if (free == 0) return;
        vm.prank(community.steward());
        try ledger.proposeWithdrawal(id, address(0xBEEF), bound(amountSeed, 1, free)) returns (uint256 pid) {
            _proposalIds.push(pid);
        } catch {}
    }

    function voteOnWithdrawal(uint256 idSeed, uint256 actorSeed, uint256 supportSeed) external {
        if (_proposalIds.length == 0) return;
        vm.prank(_pickActor(actorSeed));
        try ledger.voteOnWithdrawal(_proposalIds[idSeed % _proposalIds.length], supportSeed % 2 == 0) {} catch {}
    }

    function executeWithdrawal(uint256 idSeed, uint256 actorSeed) external {
        if (_proposalIds.length == 0) return;
        vm.prank(_pickActor(actorSeed));
        try ledger.executeWithdrawal(_proposalIds[idSeed % _proposalIds.length]) {} catch {}
    }

    function revertWithdrawal(uint256 idSeed, uint256 actorSeed) external {
        if (_proposalIds.length == 0) return;
        vm.prank(_pickActor(actorSeed));
        try ledger.revertWithdrawal(_proposalIds[idSeed % _proposalIds.length]) {} catch {}
    }

    // ---- the tier vaults underneath ----

    function gain(uint256 gainSeed, uint256 whichSeed) external {
        Venue v = whichSeed % 2 == 0 ? flexVault : coreVault;
        uint256 amount = bound(gainSeed, 0, MAX_GAIN);
        if (amount > 0) usdc.mint(address(v), amount);
        try v.accrue() {} catch {}
    }

    function rebalance(uint256 whichSeed) external {
        try (whichSeed % 2 == 0 ? flexVault : coreVault).rebalance() {} catch {}
    }

    function processQueue(uint256 stepsSeed, uint256 whichSeed) external {
        try (whichSeed % 2 == 0 ? flexVault : coreVault).processQueue(bound(stepsSeed, 1, 5)) {} catch {}
    }

    function warp(uint256 secondsSeed) external {
        vm.warp(block.timestamp + bound(secondsSeed, 1 hours, 20 days));
    }
}

/// The ledger invariant suite. The two `tierUnits` equalities that are the reconciliation
/// are `invariant_tierUnitsEqualsSumOfItsVaults` and `invariant_tierUnitsEqualsTheLedgersPosition`.
contract LedgerInvariantTest is StdInvariant, Test {
    MockUSDC usdc;
    Config config;
    LedgerFactoryStub factory;
    LedgerCommunityStub community;
    LedgerCreditCoreStub creditCore;
    Ledger ledger;
    Venue flexVault;
    Venue coreVault;
    MockStrategy flexSlow;
    MockStrategy coreSlow;
    LedgerHandler handler;

    address owner = makeAddr("vaultOwner");
    address treasury = makeAddr("treasury");
    address host = makeAddr("host");
    /// A registered depositor that deposits once and is never touched again, so a tier vault is
    /// never drained to zero shares.
    address seedHolder = makeAddr("seedHolder");

    uint256 constant SEED = 1_000e6;

    function setUp() public {
        usdc = new MockUSDC();
        // The registry is deployed before the prank: a nested `new` in the argument list would
        // consume it and leave the config owned by this contract instead.
        ComplianceRegistry registry = new ComplianceRegistry(address(this));
        vm.prank(owner);
        config = new Config(address(usdc), treasury, address(registry));
        // Headroom so a long campaign is not spent bouncing off the deposit cap, and a slow tier
        // wide enough that a single withdrawal really can overflow into the FIFO queue. Both are
        // ordinary in-bounds values, read live by the vaults like any other.
        vm.startPrank(owner);
        config.set(K.GLOBAL_DEPOSIT_CAP, 100_000_000_000e6);
        config.set(K.SLOW_TIER_CEILING_BPS, 7_500);
        vm.stopPrank();

        factory = new LedgerFactoryStub();
        flexVault = new Venue(usdc, IConfig(address(config)), address(factory), owner, "Qudi Flex", "qFLEX");
        coreVault = new Venue(usdc, IConfig(address(config)), address(factory), owner, "Qudi Core", "qCORE");
        vm.startPrank(owner);
        flexVault.setLabels(VenueIds.labels(VenueIds.FLEX));
        coreVault.setLabels(VenueIds.labels(VenueIds.CORE));
        vm.stopPrank();
        flexSlow = _slowVenue(flexVault);
        coreSlow = _slowVenue(coreVault);
        factory.addVenue(address(flexVault));
        factory.addVenue(address(coreVault));

        community = new LedgerCommunityStub();
        creditCore = new LedgerCreditCoreStub(usdc);
        vm.prank(owner);
        config.setAddress(K.CREDIT_CORE, address(creditCore));

        ledger = Ledger(Clones.clone(address(new Ledger())));
        ledger.initialize(
            ICommunityInit.CommunityWiring({
                config: address(config),
                factory: address(factory),
                seats: address(0), // the ledger reads no seat
                community: address(community),
                vault: address(0),
                creator: host,
                seatPrice: 50e6,
                name: "Invariant Community",
                poolType: 0
            })
        );
        factory.register(address(ledger));
        factory.register(seedHolder);

        community.setSteward(host);
        community.setMember(host, true);

        uint256[4] memory ids;
        vm.startPrank(host);
        ids[0] = ledger.createVault(_p(VenueIds.FLEX, true, "shared flex"));
        ids[1] = ledger.createVault(_p(VenueIds.FLEX, false, "host flex"));
        ids[2] = ledger.createVault(_p(VenueIds.CORE, false, "host core"));
        vm.stopPrank();

        handler = new LedgerHandler(ledger, community, ids);
        for (uint256 i = 0; i < 4; i++) {
            community.setMember(handler.actors(i), true);
        }
        // The fourth record belongs to an actor rather than the host, so a personal vault with an
        // owner who is not the proposer is under test too.
        vm.prank(handler.actors(0));
        ids[3] = ledger.createVault(_p(VenueIds.CORE, false, "actor core"));
        handler = new LedgerHandler(ledger, community, ids);
        for (uint256 i = 0; i < 4; i++) {
            community.setMember(handler.actors(i), true);
        }

        usdc.mint(seedHolder, SEED * 2);
        vm.startPrank(seedHolder);
        usdc.approve(address(flexVault), SEED);
        flexVault.deposit(SEED, seedHolder);
        usdc.approve(address(coreVault), SEED);
        coreVault.deposit(SEED, seedHolder);
        vm.stopPrank();

        targetContract(address(handler));
    }

    function _p(uint8 poolType, bool shared, string memory n) internal pure returns (ILedger.VaultParams memory) {
        return ILedger.VaultParams({
            poolType: poolType, shared: shared, lockedUntil: 0, contribution: 0, name: n, target: 0, targetDate: 0
        });
    }

    /// One slow venue per tier, weighted so the instant tier is genuinely scarce. Without it
    /// every share is instantly liquid and `executeWithdraw` could never take its queued branch,
    /// which is the branch the reconciliation has to survive.
    function _slowVenue(Venue v) internal returns (MockStrategy m) {
        m = new MockStrategy(usdc, address(v));
        address[] memory vs = new address[](1);
        vs[0] = address(m);
        uint16[] memory bps = new uint16[](1);
        bps[0] = 7_500;
        vm.startPrank(owner);
        v.addStrategy(address(m), 2 days);
        v.setCap(address(m), type(uint256).max);
        v.setWeights(vs, bps);
        vm.stopPrank();
    }

    /// The first reconciliation equality: `tierUnits[t]` is the sum of `vaultUnits` over the tier's
    /// active records. Exact, with no tolerance: every unit is moved on both sides in the same
    /// statement, so any drift is a bug and not rounding.
    function invariant_tierUnitsEqualsSumOfItsVaults() public view {
        assertEq(
            ledger.tierUnits(VenueIds.FLEX),
            handler.sumActiveVaultUnits(VenueIds.FLEX),
            "FLEX tierUnits is not the sum of its active vaults"
        );
        assertEq(
            ledger.tierUnits(VenueIds.CORE),
            handler.sumActiveVaultUnits(VenueIds.CORE),
            "CORE tierUnits is not the sum of its active vaults"
        );
    }

    /// The second reconciliation equality: `tierUnits[t]` is the ledger's own unit balance in that tier's
    /// `Venue`.
    ///
    /// The queued term is not in the plain statement and has to be. Once an execution hands
    /// units to the tier vault's FIFO queue the ledger's `balanceOf` no longer counts them, while
    /// the ledger has already debited `tierUnits`, so the two sides are out of step by exactly
    /// the queued amount until a keeper drains it. Subtracting it on the right is the same
    /// statement, made true in the window the queue is open.
    /// **`queuedShares` is deliberately not subtracted here, and adding it back breaks this.**
    /// `executeWithdraw` decrements `tierUnits` unconditionally, before `_payOut` chooses a
    /// branch, and `_payOut` reduces the ledger's share balance by the same units either way:
    /// `redeem` burns them, `requestRedeem` moves them to the vault. `queuedShares` rises only on
    /// the queued branch, so both sides of this comparison have already excluded those units and
    /// subtracting them again double-counts. The original expression did exactly that and
    /// underflowed whenever the fuzzer reached the queued branch, which earlier runs never did and
    /// later ledger changes reached every time.
    function invariant_tierUnitsEqualsTheLedgersPosition() public view {
        assertEq(
            ledger.tierUnits(VenueIds.FLEX),
            flexVault.balanceOf(address(ledger)),
            "FLEX tierUnits is not the ledger's position in the tier vault"
        );
        assertEq(
            ledger.tierUnits(VenueIds.CORE),
            coreVault.balanceOf(address(ledger)),
            "CORE tierUnits is not the ledger's position in the tier vault"
        );
    }

    /// Money in buys units in full; none of it is a repayment.
    function invariant_moneyInIsNeverARepayment() public view {
        assertEq(handler.depositsRoutedToCredit(), 0, "a deposit was routed to the credit core");
    }

    /// An earmark is a reservation against units the vault really holds, never a promise of units
    /// it does not. Counted in units, which is what removes the clamp: execution
    /// burns exactly what was reserved because exactly that much is still there.
    function invariant_earmarksAreCoveredByTheUnits() public view {
        for (uint256 i = 0; i < 4; i++) {
            uint256 id = handler.vaultIds(i);
            assertLe(ledger.earmarkedUnits(id), ledger.vaultUnits(id), "an earmark exceeds its vault's units");
        }
    }

    /// Vault shares are never held by a member. They live at the ledger, at the tier vault and at
    /// the seed holder; members hold no position of their own at all.
    function invariant_sharesNeverHeldByMembers() public view {
        for (uint256 i = 0; i < 4; i++) {
            assertEq(flexVault.balanceOf(handler.actors(i)), 0, "a member holds flex shares");
            assertEq(coreVault.balanceOf(handler.actors(i)), 0, "a member holds core shares");
        }
        assertEq(flexVault.balanceOf(address(handler)), 0, "the handler holds flex shares");
    }
}
