// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {Seats} from "../src/Seats.sol";
import {InviteSigner} from "./helpers/InviteSigner.sol";
import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {CreditCore} from "../src/CreditCore.sol";
import {ICreditCore} from "../src/interfaces/ICreditCore.sol";
import {IConfig} from "../src/interfaces/IConfig.sol";
import {Config} from "../src/Config.sol";
import {ConfigKeys} from "../src/ConfigKeys.sol";
import {ComplianceRegistry} from "../src/ComplianceRegistry.sol";
import {CommunityFactory} from "../src/CommunityFactory.sol";
import {Community} from "../src/Community.sol";
import {Ledger} from "../src/Ledger.sol";
import {ILedger} from "../src/interfaces/ILedger.sol";
import {Venue} from "../src/Venue.sol";
import {MockStrategy} from "./mocks/MockStrategy.sol";
import {VenueIds} from "./helpers/VenueIds.sol";
import {CreditStandingHarness} from "./helpers/CreditStandingHarness.sol";
import {MockUSDC} from "./mocks/MockUSDC.sol";
import {MockCreditPoolForVault} from "./mocks/MockVaultSiblings.sol";

/// Qudi never takes
/// money a member would receive to recover what they owe. Every test here holds a member with an
/// open CreditCore advance, and checks that nothing they are paid, deposit, or wait for moves
/// because of it.
///
/// The fixture is the real stack: `CreditCore`, a real Flex `Ledger` over a real
/// `Venue` and a real locked `Venue` for the early break. The Term cohort contracts it
/// also covered were deleted on 2026-09-21; TERM is an ordinary ledger now,
/// so the flex and queue cases below cover it. `Config.CREDIT_CORE` points at CreditCore, as a deployment
/// wires it.
///
/// `pool` is a mock that reports each debtor's CreditCore principal as their tab: exactly the
/// future per-community credit pool the no-intercept rule exists to stop, held here as the
/// adversary these tests must survive. It is deployed standalone and wired to nothing, because
/// `NullCreditPool` and the factory's credit-pool slot are deleted, so
/// every assertion that money did not reach it now holds for two reasons instead of one: no
/// path routes to it, and no path would even if one were wired.
contract NoInterceptTest is InviteSigner {
    MockUSDC usdc;
    Config config;
    ComplianceRegistry registry;
    CommunityFactory factory;
    CreditStandingHarness standing;
    CreditCore cc;
    Venue flexVault;
    Venue coreVault;

    address community;
    MockCreditPoolForVault pool;
    /// One ledger per community, so these two are the same address. Kept as
    /// two names because every proof below reads as "the Flex path" or "the Core path", and the
    /// tier a call acts on is now the vault record it names rather than which clone it hits.
    Ledger flexLedger;
    Ledger coreLedger;
    /// Each member's own personal record in each tier. A vault is a record, not a contract.
    mapping(address => uint256) flexVaultOf;
    mapping(address => uint256) coreVaultOf;

    address screener = makeAddr("screener");
    address allocationMs = makeAddr("allocationMultisig");
    address member = makeAddr("member");
    address behind = makeAddr("behind");

    uint256 constant SEAT = 50e6;
    uint256 constant ALLOCATION = 5000e6;
    bytes32 constant AGREEMENT = keccak256("qudi credit agreement v1");

    enum Stage {
        Tenor,
        Grace,
        Late,
        FinalCure,
        DefaultRecovery,
        WrittenOff
    }

    function setUp() public {
        usdc = new MockUSDC();
        registry = new ComplianceRegistry(screener);
        config = new Config(address(usdc), makeAddr("protocolTreasury"), address(registry));

        address communityImpl = address(new Community());
        address ledgerImpl = address(new Ledger());

        // Three creations sit between this nonce read and the factory: the two vaults and `Seats`,
        // each of which takes the factory address as a constructor argument.
        address predicted = vm.computeCreateAddress(address(this), vm.getNonce(address(this)) + 3);
        flexVault = new Venue(IERC20(address(usdc)), IConfig(address(config)), predicted, address(this), "F", "F");
        coreVault = new Venue(IERC20(address(usdc)), IConfig(address(config)), predicted, address(this), "C", "C");
        address[3] memory pools;
        pools[VenueIds.FLEX] = address(flexVault);
        pools[VenueIds.CORE] = address(coreVault);
        pools[VenueIds.TERM] = makeAddr("poolTerm");
        Seats seats = new Seats(predicted);
        factory = new CommunityFactory(address(config), address(seats), communityImpl, ledgerImpl, address(this));
        flexVault.setLabels(VenueIds.labels(VenueIds.FLEX));
        coreVault.setLabels(VenueIds.labels(VenueIds.CORE));
        for (uint8 t = 0; t < 3; t++) {
            factory.addVenue(pools[t]);
        }
        require(address(factory) == predicted, "factory precompute mismatch");

        standing = new CreditStandingHarness(IConfig(address(config)), address(factory), address(this));
        cc = new CreditCore(
            IERC20(address(usdc)),
            IConfig(address(config)),
            address(factory),
            address(this),
            makeAddr("tm"),
            allocationMs,
            standing
        );
        standing.setCreditCore(address(cc));
        config.setAddress(ConfigKeys.CREDIT_CORE, address(cc));

        usdc.mint(address(this), 300_000e6);
        usdc.approve(address(cc), 300_000e6);
        cc.fund(300_000e6);

        // The host signs invites, so it is a keyed account rather than this contract.
        address host = _keyed("host");
        vm.prank(host);
        registry.attest(1);
        vm.prank(host);
        community = factory.createCommunity("No Intercept Community", SEAT);
        pool = new MockCreditPoolForVault();
        vm.prank(allocationMs);
        cc.allocate(0, ALLOCATION, ICreditCore.AllocationType.Growth);

        flexLedger = Ledger(factory.ledgerOf(community));
        coreLedger = flexLedger;

        _join(member);
        _join(behind);
    }

    // =================================================================
    // Fixture helpers
    // =================================================================

    function _join(address who) internal {
        vm.prank(who);
        registry.attest(1);
        usdc.mint(who, SEAT);
        vm.startPrank(who);
        usdc.approve(community, SEAT);
        _invitedJoin(community, who);
        flexVaultOf[who] = flexLedger.createVault(_vaultParams(VenueIds.FLEX));
        coreVaultOf[who] = flexLedger.createVault(_vaultParams(VenueIds.CORE));
        vm.stopPrank();
    }

    /// An open, personal, anytime record: the plainest vault these proofs can save into, so what
    /// they show is the payout path and not any one axis combination.
    function _vaultParams(uint8 poolType) internal pure returns (ILedger.VaultParams memory) {
        return ILedger.VaultParams({venueId: poolType, shared: false, lockedUntil: 0, name: "savings"});
    }

    /// Opens a CreditCore advance of `debt` for `who`, and has the community's credit pool report the
    /// same figure as their tab (see the contract comment). Returns the draw timestamp.
    function _openAdvance(address who, uint256 debt) internal returns (uint64 ts) {
        vm.warp(block.timestamp + config.memberSeasoningWindow() + 1);
        standing.primeImpact(0, who, 500e6, 1000e6);
        vm.prank(who);
        cc.draw(0, debt, AGREEMENT);
        ts = cc.obligationOf(who).drawTimestamp;
        pool.setTab(who, debt);
    }

    /// An elapsed time inside `stage`, at least `minElapsed` when the stage allows it.
    function _elapsedIn(Stage stage, uint256 seed, uint256 minElapsed) internal view returns (uint256) {
        (uint64 grace, uint64 late, uint64 finalCure, uint64 dr, uint64 wo) = config.stageBoundaries();
        uint256[7] memory b = [uint256(0), grace, late, finalCure, dr, wo, uint256(wo) + 400 days];
        uint256 lo = b[uint8(stage)];
        uint256 hi = b[uint8(stage) + 1] - 1;
        if (minElapsed > lo) lo = minElapsed;
        return bound(seed, lo, hi);
    }

    function _warpInto(uint64 ts, Stage stage, uint256 seed, uint256 minElapsed) internal {
        vm.warp(uint256(ts) + _elapsedIn(stage, seed, minElapsed));
        assertEq(uint8(cc.obligationOf(member).stage), uint8(stage), "fixture: warped into the wrong stage");
    }

    function _contributeFlex(address who, uint256 amount) internal {
        usdc.mint(who, amount);
        vm.startPrank(who);
        usdc.approve(address(flexLedger), amount);
        flexLedger.deposit(flexVaultOf[who], amount);
        vm.stopPrank();
    }

    /// The slow strategy `_addSlowVenue` lists. It gives nothing back until `_releaseSlow`.
    MockStrategy slowV;

    /// A slow venue holding the slow tier's ceiling and giving nothing back yet, so a large enough
    /// request cannot be paid at once and waits in the vault's FIFO queue.
    function _addSlowVenue() internal {
        MockStrategy instantV = new MockStrategy(IERC20(address(usdc)), address(flexVault));
        slowV = new MockStrategy(IERC20(address(usdc)), address(flexVault));
        flexVault.addStrategy(address(instantV), 0);
        flexVault.addStrategy(address(slowV), 2 days);
        flexVault.setCap(address(instantV), type(uint256).max);
        flexVault.setCap(address(slowV), type(uint256).max);
        address[] memory vs = new address[](2);
        uint16[] memory bps = new uint16[](2);
        vs[0] = address(instantV);
        vs[1] = address(slowV);
        bps[0] = 7500;
        bps[1] = 2500;
        flexVault.setWeights(vs, bps);
        flexVault.rebalance();
        slowV.setWithdrawCap(0);
    }

    function _releaseSlow() internal {
        slowV.setWithdrawCap(type(uint256).max);
    }

    struct Snap {
        uint256 receiver;
        uint256 core;
        uint256 principal;
        bool closed;
        bool writtenOff;
    }

    function _snap(address who) internal view returns (Snap memory s) {
        ICreditCore.ObligationView memory o = cc.obligationOf(who);
        s.receiver = usdc.balanceOf(who);
        s.core = usdc.balanceOf(address(cc));
        s.principal = o.principal;
        s.closed = o.closed;
        s.writtenOff = o.writtenOff;
    }

    /// The three no-intercept properties, for one payout.
    function _assertPaidInFull(address who, Snap memory before, uint256 payout) internal view {
        Snap memory afterPay = _snap(who);
        assertEq(afterPay.receiver, before.receiver + payout, "receiver was not paid the full payout");
        assertEq(afterPay.core, before.core, "CreditCore's USDC moved on a payout");
        assertEq(afterPay.principal, before.principal, "the debt moved on a payout");
        assertEq(afterPay.closed, before.closed, "the tab closed on a payout");
        assertEq(afterPay.writtenOff, before.writtenOff, "the tab was written off on a payout");
    }

    // =================================================================
    // Proof 1: every payout path pays in full
    // =================================================================

    /// `Ledger.requestWithdraw` in a liquid venue, which pays in the same transaction.
    function testFuzz_payout_flexInstant(uint8 stageSeed, uint256 debtSeed, uint256 payoutSeed, uint256 when) public {
        Stage stage = Stage(stageSeed % 6);
        uint256 debt = bound(debtSeed, 1e6, 50e6);
        uint256 payout = bound(payoutSeed, 1e6, 2000e6);
        _instant(stage, debt, payout, when);
    }

    function test_payout_flexInstant_payoutAboveDebt() public {
        _instant(Stage.DefaultRecovery, 50e6, 80e6, 0);
    }

    function test_payout_flexInstant_payoutBelowDebt() public {
        _instant(Stage.DefaultRecovery, 50e6, 20e6, 0);
    }

    function _instant(Stage stage, uint256 debt, uint256 payout, uint256 when) internal {
        uint64 ts = _openAdvance(member, debt);
        _contributeFlex(member, payout);
        _warpInto(ts, stage, when, 0);

        Snap memory before = _snap(member);
        vm.prank(member);
        flexLedger.requestWithdraw(flexVaultOf[member], payout);
        _assertPaidInFull(member, before, payout);
    }

    /// `Venue.withdraw`, the ERC-4626 entry point, called by the ledger that holds the shares.
    function testFuzz_payout_vaultWithdraw(uint8 stageSeed, uint256 debtSeed, uint256 payoutSeed, uint256 when) public {
        Stage stage = Stage(stageSeed % 6);
        uint256 debt = bound(debtSeed, 1e6, 50e6);
        uint256 payout = bound(payoutSeed, 1e6, 2000e6);

        uint64 ts = _openAdvance(member, debt);
        _contributeFlex(member, payout);
        _warpInto(ts, stage, when, 0);

        Snap memory before = _snap(member);
        vm.prank(address(flexLedger));
        flexVault.withdraw(payout, member, address(flexLedger));
        _assertPaidInFull(member, before, payout);
    }

    /// The FIFO queue: `processQueue` pays a request the instant tier could not cover.
    function testFuzz_payout_processQueue(uint8 stageSeed, uint256 debtSeed, uint256 payoutSeed, uint256 when) public {
        Stage stage = Stage(stageSeed % 6);
        uint256 debt = bound(debtSeed, 1e6, 50e6);
        // A request for the whole balance always exceeds the 75% that stays instant.
        uint256 payout = bound(payoutSeed, 100e6, 2000e6);
        _queued(stage, debt, payout, when);
    }

    function test_payout_processQueue_payoutAboveDebt() public {
        _queued(Stage.DefaultRecovery, 50e6, 200e6, 0);
    }

    function test_payout_processQueue_payoutBelowDebt() public {
        // Below the 50e6 debt and still above the instant tier: 40 contributed, 30 instant.
        _queued(Stage.DefaultRecovery, 50e6, 40e6, 0);
    }

    function _queued(Stage stage, uint256 debt, uint256 payout, uint256 when) internal {
        uint64 ts = _openAdvance(member, debt);
        _contributeFlex(member, payout);
        _addSlowVenue();
        vm.prank(member);
        flexLedger.requestWithdraw(flexVaultOf[member], payout);
        assertGt(flexVault.queuedShares(address(flexLedger)), 0, "fixture: request did not reach the queue");
        _warpInto(ts, stage, when, 31 days);
        _releaseSlow();

        uint256 owed = flexVault.queuedRedeemEstimate(1);
        Snap memory before = _snap(member);
        flexVault.processQueue(5);
        _assertPaidInFull(member, before, owed);
        assertEq(owed, payout, "fixture: the queue struck a different price");
    }

    /// `releaseHeldPayout`: a queue payout held while the receiver refused USDC, released later.
    function testFuzz_payout_releaseHeldPayout(uint8 stageSeed, uint256 debtSeed, uint256 payoutSeed, uint256 when)
        public
    {
        Stage stage = Stage(stageSeed % 6);
        uint256 debt = bound(debtSeed, 1e6, 50e6);
        uint256 payout = bound(payoutSeed, 100e6, 2000e6);

        uint64 ts = _openAdvance(member, debt);
        _contributeFlex(member, payout);
        _addSlowVenue();
        vm.prank(member);
        flexLedger.requestWithdraw(flexVaultOf[member], payout);
        _releaseSlow();
        usdc.setBlocked(member, true);
        flexVault.processQueue(5);
        usdc.setBlocked(member, false);
        uint256 held = flexVault.heldPayout(member);
        assertEq(held, payout, "fixture: payout not held");

        _warpInto(ts, stage, when, 31 days);
        Snap memory before = _snap(member);
        flexVault.releaseHeldPayout(member);
        _assertPaidInFull(member, before, held);
    }

    // =================================================================
    // Proof 2: a deposit is not a repayment
    // =================================================================

    function testFuzz_deposit_flexLedgerCreditsInFull(uint256 debtSeed, uint256 amountSeed, uint256 when) public {
        uint256 debt = bound(debtSeed, 1e6, 50e6);
        uint256 amount = bound(amountSeed, 1e6, 2000e6);
        uint64 ts = _openAdvance(member, debt);
        _warpInto(ts, Stage.DefaultRecovery, when, 0);

        Snap memory before = _snap(member);
        _contributeFlex(member, amount);
        assertEq(flexLedger.vaultCapital(flexVaultOf[member]), amount, "savings capital short of the deposit");
        assertEq(flexLedger.vaultValue(flexVaultOf[member]), amount, "savings value short of the deposit");
        assertEq(pool.paymentsReceived(member), 0, "the credit pool received a repayment");
        assertEq(usdc.balanceOf(address(cc)), before.core, "CreditCore received part of the deposit");
        assertEq(cc.obligationOf(member).principal, before.principal, "the deposit moved the debt");
    }

    // =================================================================
    // Proof 3: no withdrawal is delayed because a member owes
    // =================================================================

    /// A withdrawal by a member with an open advance is paid in the same transaction, in every
    /// stage the advance can be open in, for Flex and for Core: the ledger has no wait of its own
    /// to lengthen for someone who owes.
    function testFuzz_withdrawal_notDelayedByDebt(uint8 stageSeed, uint256 debtSeed, uint256 when) public {
        Stage stage = Stage(stageSeed % 5); // an advance is open from Tenor through Default Recovery
        uint64 ts = _openAdvance(member, bound(debtSeed, 1e6, 50e6));
        _contributeFlex(member, 100e6);
        usdc.mint(member, 100e6);
        vm.startPrank(member);
        usdc.approve(address(coreLedger), 100e6);
        coreLedger.deposit(coreVaultOf[member], 100e6);
        vm.stopPrank();
        _warpInto(ts, stage, when, 0);
        assertTrue(cc.hasOpenTab(member), "fixture: the advance is not open");

        uint256 before = usdc.balanceOf(member);
        vm.startPrank(member);
        flexLedger.requestWithdraw(flexVaultOf[member], 60e6);
        coreLedger.requestWithdraw(coreVaultOf[member], 60e6);
        vm.stopPrank();
        assertEq(usdc.balanceOf(member), before + 120e6, "a request by a member who owes was delayed");
    }

    /// The instant Flex path is not blocked by an open advance, or by a pool reporting a tab.
    /// The pool is wired to nothing; the tab it reports is the adversary, not a route.
    function testFuzz_instantFlex_notBlockedByDebt(uint8 stageSeed, uint256 debtSeed, uint256 when) public {
        Stage stage = Stage(stageSeed % 5);
        uint64 ts = _openAdvance(member, bound(debtSeed, 1e6, 50e6));
        _contributeFlex(member, 100e6);
        _warpInto(ts, stage, when, 0);
        assertTrue(cc.hasOpenTab(member), "fixture: the advance is not open");
        assertGt(pool.tabOutstanding(member), 0, "fixture: the pool reports no tab");

        vm.prank(member);
        flexLedger.requestWithdraw(flexVaultOf[member], 100e6);
        assertEq(flexLedger.vaultValue(flexVaultOf[member]), 0, "the instant withdrawal did not complete");
    }

    // =================================================================
    // Proof 7: the queue still holds a payout it cannot deliver
    // =================================================================

    /// The head receiver refuses USDC and holds an advance in Default Recovery. The request behind
    /// them is paid in the same call, the head's payout is held, and `releaseHeldPayout` pays it
    /// in full once the receiver can take USDC again. In older code a receiver in Default Recovery
    /// took an atomic branch instead, and one refusing receiver reverted the whole queue.
    function test_queue_refusingReceiverDoesNotBlockTheQueue() public {
        uint64 ts = _openAdvance(member, 50e6);
        _contributeFlex(member, 350e6);
        _contributeFlex(behind, 50e6);
        _addSlowVenue(); // 300e6 of the 400e6 stays instant

        vm.prank(member);
        flexLedger.requestWithdraw(flexVaultOf[member], 350e6);
        vm.prank(behind);
        flexLedger.requestWithdraw(flexVaultOf[behind], 50e6);
        _warpInto(ts, Stage.DefaultRecovery, 0, 31 days);
        assertEq(flexVault.queuedShares(address(flexLedger)), 400e6, "fixture: both requests must be queued");
        _releaseSlow();

        usdc.setBlocked(member, true);
        uint256 behindBefore = usdc.balanceOf(behind);
        flexVault.processQueue(5);
        assertEq(usdc.balanceOf(behind), behindBefore + 50e6, "the request behind a refusing receiver was not paid");
        assertEq(flexVault.heldPayout(member), 350e6, "the refused payout was not held");
        assertEq(flexVault.nextToPay(), 3, "the queue did not advance past the refusing receiver");

        usdc.setBlocked(member, false);
        Snap memory before = _snap(member);
        flexVault.releaseHeldPayout(member);
        _assertPaidInFull(member, before, 350e6);
        assertEq(flexVault.heldPayout(member), 0, "held payout not cleared");
        assertEq(flexVault.totalHeld(), 0, "total held not cleared");
    }

    // =================================================================
    // Proof 5: the guard
    // =================================================================

    /// Fails if the intercept or the set-off comes back under its old selectors. Each call is made
    /// against the deployed contract in a state where the old function would have answered, and
    /// passes only if the call reverts with empty return data, which is what a contract with no
    /// matching selector and no fallback does. `hasOpenTab` and `balanceOf` are the positive
    /// controls: the same call shape succeeds for a selector that exists.
    function test_guard_removedSelectorsAreGone() public {
        _openAdvance(member, 50e6);
        _contributeFlex(member, 100e6);

        _assertOk(address(cc), abi.encodeWithSignature("hasOpenTab(address)", member));
        _assertOk(address(flexLedger), abi.encodeWithSignature("vaultValue(uint256)", flexVaultOf[member]));

        // As the owner, so an existing `setClaimPath` would succeed.
        _assertNoSelector(address(cc), abi.encodeWithSignature("setClaimPath(address,bool)", address(this), true));
        _assertNoSelector(address(cc), abi.encodeWithSignature("interceptionActiveFor(address)", member));
        // As a caller holding an approval, so an existing intercept would pull and forward.
        usdc.mint(address(this), 1e6);
        usdc.approve(address(cc), 1e6);
        _assertNoSelector(address(cc), abi.encodeWithSignature("interceptedTransfer(address,uint256)", member, 1e6));

        _assertNoSelector(address(flexLedger), abi.encodeWithSignature("seizable(address)", member));
        vm.prank(address(pool)); // the only caller an existing `seizeBalance` accepted
        (bool ok, bytes memory ret) =
            address(flexLedger).call(abi.encodeWithSignature("seizeBalance(address,uint256)", member, 1e6));
        assertFalse(ok, "Ledger answers seizeBalance");
        assertEq(ret.length, 0, "Ledger answers seizeBalance");
    }

    function _assertOk(address target, bytes memory data) internal {
        (bool ok,) = target.call(data);
        assertTrue(ok, "positive control failed: the call shape itself is broken");
    }

    function _assertNoSelector(address target, bytes memory data) internal {
        (bool ok, bytes memory ret) = target.call(data);
        assertFalse(ok, "a removed selector answered");
        assertEq(ret.length, 0, "a removed selector answered");
    }
}
