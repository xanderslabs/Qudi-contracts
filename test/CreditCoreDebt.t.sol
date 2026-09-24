// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {Seats} from "../src/Seats.sol";
import {InviteSigner} from "./helpers/InviteSigner.sol";
import {Vm} from "forge-std/Vm.sol";
import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {ICreditCore} from "../src/interfaces/ICreditCore.sol";
import {ICreditStanding} from "../src/interfaces/ICreditStanding.sol";
import {IConfig} from "../src/interfaces/IConfig.sol";
import {Config} from "../src/Config.sol";
import {ComplianceRegistry} from "../src/ComplianceRegistry.sol";
import {ConfigKeys} from "../src/ConfigKeys.sol";
import {CommunityFactory} from "../src/CommunityFactory.sol";
import {Community} from "../src/Community.sol";
import {ICommunity} from "../src/interfaces/ICommunity.sol";
import {DebtMath} from "../src/DebtMath.sol";
import {MockUSDC} from "./mocks/MockUSDC.sol";
import {MockCommunityModule} from "./mocks/MockCommunityModule.sol";
import {MockCreditPool} from "./mocks/MockSeatSiblings.sol";
import {CreditCoreHarness} from "./helpers/CreditCoreHarness.sol";
import {CreditStandingHarness} from "./helpers/CreditStandingHarness.sol";

/// The debt lifecycle. Draw gates, settle one-to-one, the stage machine,
/// deterministic write-off, and Trust Extension removal at Late entry.
///
/// The fixture is the real stack everywhere a gate reads the world: real `Community`
/// (membership and the seasoning view), the real `ComplianceRegistry` (the
/// draw-block flag), a real `CommunityFactory`. Standing figures the draw consumes (`U_i`,
/// `te_earned`, attributed yield) are primed through the harness pokes, which write the
/// same storage the Standing paths write. The harness's seam overrides only take effect when
/// a test sets them; unset, every seam falls through to the real debt ledger.
contract CreditCoreDebtTest is InviteSigner {
    MockUSDC usdc;
    Config config;
    ComplianceRegistry registry;
    CommunityFactory factory;
    CreditStandingHarness standing;
    CreditCoreHarness cc;

    address governance = makeAddr("governance");
    address treasuryMgr = makeAddr("treasuryManager");
    address allocationMs = makeAddr("allocationMultisig");
    address screener = makeAddr("screener");
    address treasury = makeAddr("protocolTreasury");
    address member = makeAddr("member");
    address member2 = makeAddr("member2");
    address other = makeAddr("other");
    /// Founds every community here. A keyed account, because the host signs each invite.
    address creator = _keyed("creator");

    // Empty book, 1 community: required = max(2000e6, 10_000e6) + 0 + 0 + 0 + 100_000e6.
    uint256 constant BASE_REQUIRED = 110_000e6;
    uint256 constant ALLOCATION = 5000e6;
    uint256 constant SEAT = 50e6;
    bytes32 constant AGREEMENT = keccak256("qudi credit agreement v1");

    function setUp() public {
        usdc = new MockUSDC();
        registry = new ComplianceRegistry(screener);
        config = new Config(address(usdc), treasury, address(registry));
        address communityImpl = address(new Community());
        address ledgerImpl = address(new MockCommunityModule());
        Seats seats = new Seats(vm.computeCreateAddress(address(this), vm.getNonce(address(this)) + 1));
        factory = new CommunityFactory(address(config), address(seats), communityImpl, ledgerImpl, address(this));
        address[3] memory listed = _dummyPools();
        for (uint8 t = 0; t < 3; t++) {
            factory.addVenue(listed[t]);
        }
        standing = new CreditStandingHarness(IConfig(address(config)), address(factory), governance);
        cc = new CreditCoreHarness(
            IERC20(address(usdc)),
            IConfig(address(config)),
            address(factory),
            governance,
            treasuryMgr,
            allocationMs,
            standing
        );
        vm.prank(governance);
        standing.setCreditCore(address(cc));
        // A paid seat mint pays its 40% community leg to `config.creditCore()`, so a
        // fixture whose tests call `join()` has to wire it. It is the real `cc` here, not a
        // mock, so the leg lands on the same `_allocationOf[0]` these tests read.
        config.setAddress(ConfigKeys.CREDIT_CORE, address(cc));

        // Treasury funded so one community's allocation plus the stress floor leaves a
        // comfortable draw cushion; the retained-capital gate is tested separately by consuming it.
        _fund(300_000e6);
        vm.prank(creator);
        registry.attest(1);
        _createCommunity("Debt Community");
        _allocate(0, ALLOCATION);

        vm.warp(2000 days);
    }

    // ---- fixture helpers ----

    function _dummyPools() internal returns (address[3] memory p) {
        for (uint256 i; i < 3; i++) {
            p[i] = makeAddr(string.concat("pool", vm.toString(i)));
        }
    }

    function _community(uint256 communityId) internal view returns (address community) {
        community = factory.communityAt(communityId);
    }

    function _createCommunity(string memory name) internal returns (address community) {
        vm.prank(creator);
        community = factory.createCommunity(name, SEAT);
    }

    function _fund(uint256 amount) internal {
        usdc.mint(governance, amount);
        vm.startPrank(governance);
        usdc.approve(address(cc), amount);
        cc.fund(amount);
        vm.stopPrank();
    }

    function _allocate(uint256 communityId, uint256 amount) internal {
        vm.prank(allocationMs);
        cc.allocate(communityId, amount, ICreditCore.AllocationType.Growth);
    }

    /// Join `who` to community 0 and season: attest for self, pay the seat, then
    /// pass the 14-day window measured from the seat mint timestamp.
    function _joinSeasoned(address who) internal {
        vm.prank(who);
        registry.attest(1);
        usdc.mint(who, SEAT);
        vm.startPrank(who);
        usdc.approve(address(_community(0)), SEAT);
        _invitedJoin(_community(0), who);
        vm.stopPrank();
        vm.warp(block.timestamp + 14 days + 1);
    }

    /// Seasoned units and a one-half share, activity and conduct at 1.0. First-Line cap
    /// binds at MIN_LENDABLE: line() is (50e6, true).
    function _primeEligible(address who) internal {
        standing.primeImpact(0, who, 500e6, 1000e6);
    }

    function _drawFirst(address who, uint256 amount) internal returns (uint64 ts) {
        vm.prank(who);
        cc.draw(0, amount, AGREEMENT);
        ts = cc.obligationOf(who).drawTimestamp;
    }

    function _settle(address who, uint256 amount) internal {
        usdc.mint(who, amount);
        vm.startPrank(who);
        usdc.approve(address(cc), amount);
        cc.settle(amount);
        vm.stopPrank();
    }

    function _revert(bytes4 sel) internal {
        vm.expectRevert(abi.encodeWithSelector(sel));
    }

    function _boundaries() internal view returns (uint64 grace, uint64 late, uint64 fc, uint64 dr, uint64 wo) {
        return config.stageBoundaries();
    }

    // =================================================================
    // Stage machine: ten boundary assertions, both sides, in
    // seconds, from the obligation's own drawTimestamp
    // =================================================================

    function test_stageBoundaries_bothSidesInSeconds() public {
        _joinSeasoned(member);
        _primeEligible(member);
        uint64 ts = _drawFirst(member, 50e6);

        (uint64 grace, uint64 late, uint64 fc, uint64 dr, uint64 wo) = _boundaries();
        assertEq(grace, 60 days, "launch Grace start");
        assertEq(late, 65 days, "launch Late start");
        assertEq(fc, 95 days, "launch Final Cure start");
        assertEq(dr, 155 days, "launch Default Recovery start");
        assertEq(wo, 365 days, "launch write-off");

        vm.warp(ts + grace - 1);
        assertEq(uint8(cc.currentStage(member)), uint8(ICreditCore.Stage.Tenor), "60d-1s is Tenor");
        vm.warp(ts + grace);
        assertEq(uint8(cc.currentStage(member)), uint8(ICreditCore.Stage.Grace), "60d is Grace");

        vm.warp(ts + late - 1);
        assertEq(uint8(cc.currentStage(member)), uint8(ICreditCore.Stage.Grace), "65d-1s is Grace");
        vm.warp(ts + late);
        assertEq(uint8(cc.currentStage(member)), uint8(ICreditCore.Stage.Late), "65d is Late");

        vm.warp(ts + fc - 1);
        assertEq(uint8(cc.currentStage(member)), uint8(ICreditCore.Stage.Late), "95d-1s is Late");
        vm.warp(ts + fc);
        assertEq(uint8(cc.currentStage(member)), uint8(ICreditCore.Stage.FinalCure), "95d is Final Cure");

        vm.warp(ts + dr - 1);
        assertEq(uint8(cc.currentStage(member)), uint8(ICreditCore.Stage.FinalCure), "155d-1s is Final Cure");
        vm.warp(ts + dr);
        assertEq(uint8(cc.currentStage(member)), uint8(ICreditCore.Stage.DefaultRecovery), "155d is Default Recovery");

        vm.warp(ts + wo - 1);
        assertEq(
            uint8(cc.currentStage(member)), uint8(ICreditCore.Stage.DefaultRecovery), "365d-1s is Default Recovery"
        );
        vm.warp(ts + wo);
        assertEq(uint8(cc.currentStage(member)), uint8(ICreditCore.Stage.WrittenOff), "365d is Written Off");
    }

    /// This took no parameters, so Foundry ran it once as an ordinary
    /// unit test; the `testFuzz_` name claimed a fuzz campaign that never ran. Renamed to say
    /// what it is: a dense deterministic sweep (a step every 37 minutes to 1000 days) proving
    /// the stage function is monotone and total, plus the seven boundary points explicitly.
    /// `testFuzz_stageDeriveMatchesIndependentComputation` below is the genuine fuzz test the
    /// acceptance criterion asked for.
    function test_stageMonotonicAndTotal() public {
        (uint64 grace, uint64 late, uint64 fc, uint64 dr, uint64 wo) = _boundaries();
        uint8 prev;
        for (uint256 t; t <= 1000 days; t += 37 minutes) {
            uint8 s = DebtMath.deriveStage(t, grace, late, fc, dr, wo);
            assertTrue(s <= uint8(ICreditCore.Stage.WrittenOff), "total: unknown stage");
            assertGe(s, prev, "monotonic in elapsed time");
            prev = s;
        }
        assertEq(DebtMath.deriveStage(grace - 1, grace, late, fc, dr, wo), uint8(ICreditCore.Stage.Tenor));
        assertEq(DebtMath.deriveStage(grace, grace, late, fc, dr, wo), uint8(ICreditCore.Stage.Grace));
        assertEq(DebtMath.deriveStage(late - 1, grace, late, fc, dr, wo), uint8(ICreditCore.Stage.Grace));
        assertEq(DebtMath.deriveStage(late, grace, late, fc, dr, wo), uint8(ICreditCore.Stage.Late));
        assertEq(DebtMath.deriveStage(fc, grace, late, fc, dr, wo), uint8(ICreditCore.Stage.FinalCure));
        assertEq(DebtMath.deriveStage(dr, grace, late, fc, dr, wo), uint8(ICreditCore.Stage.DefaultRecovery));
        assertEq(DebtMath.deriveStage(wo, grace, late, fc, dr, wo), uint8(ICreditCore.Stage.WrittenOff));
    }

    /// The genuine fuzz test. `expected` is computed independently of
    /// `DebtMath.deriveStage` (an if/else chain over the same boundaries, not a call to the
    /// function under test), so this cannot pass by construction the way comparing a function
    /// to itself would.
    function testFuzz_stageDeriveMatchesIndependentComputation(uint256 elapsedSeed) public view {
        (uint64 grace, uint64 late, uint64 fc, uint64 dr, uint64 wo) = _boundaries();
        uint256 elapsed = _pick(elapsedSeed, 0, 400 days);
        uint8 expected;
        if (elapsed < grace) expected = uint8(ICreditCore.Stage.Tenor);
        else if (elapsed < late) expected = uint8(ICreditCore.Stage.Grace);
        else if (elapsed < fc) expected = uint8(ICreditCore.Stage.Late);
        else if (elapsed < dr) expected = uint8(ICreditCore.Stage.FinalCure);
        else if (elapsed < wo) expected = uint8(ICreditCore.Stage.DefaultRecovery);
        else expected = uint8(ICreditCore.Stage.WrittenOff);
        assertEq(
            DebtMath.deriveStage(elapsed, grace, late, fc, dr, wo),
            expected,
            "derived stage matches an independently computed expectation"
        );
    }

    /// Stage is derived from each obligation's own drawTimestamp, not a shared clock.
    function test_stagePerObligation() public {
        _joinSeasoned(member);
        _primeEligible(member);
        uint64 ts1 = _drawFirst(member, 50e6);

        vm.warp(ts1 + 30 days);
        _joinSeasoned(member2);
        standing.primeImpact(0, member2, 500e6, 1000e6);
        vm.prank(member2);
        cc.draw(0, 50e6, AGREEMENT);

        vm.warp(ts1 + 60 days);
        assertEq(uint8(cc.currentStage(member)), uint8(ICreditCore.Stage.Grace), "first obligation at Grace");
        assertEq(uint8(cc.currentStage(member2)), uint8(ICreditCore.Stage.Tenor), "second obligation still Tenor");
    }

    // =================================================================
    // Draw gates: each blocks independently, all others passing
    // =================================================================

    function _gatesPass() internal {
        _joinSeasoned(member);
        _primeEligible(member);
    }

    /// `_impactBudgetFromSnapshot`'s liquid-cash subtraction
    /// (the community's allocation less what it has currently lent out) survived
    /// deletion in the Standing suite, because `CreditStandingHarness._communitySnapshotOverride`
    /// always passes `outstandingPrincipal: 0`. This test reaches the real snapshot through
    /// `CreditCoreHarness`, which composes it from `_allocationOf`/`_outstandingPrincipalOf`.
    function test_budgetNetsOutstandingPrincipal() public {
        _gatesPass();
        uint256 budgetBefore = cc.communityImpactBudget(0);
        _drawFirst(member, 50e6);
        uint256 budgetAfter = cc.communityImpactBudget(0);
        assertEq(budgetBefore - budgetAfter, 50e6, "an open obligation's principal is not liquid community cash");
    }

    /// Mutation catalogue: `_impactBudgetFromSnapshot`'s `liquid > sub ? liquid - sub : 0` floor.
    /// A freshly created community starts at allocation 0, well below `sub` (the per-community
    /// operating buffer plus MIN_LENDABLE), so `liquid < sub` is an ordinary reachable state, not
    /// an edge case. Deleting the floor turns it into an underflow revert instead of a `0`
    /// budget; no existing test creates a community small enough to reach this branch, since the
    /// fixture's community 0 is always allocated well above `sub`.
    function test_communityImpactBudget_floorsAtZeroBelowTheOperatingBuffer() public {
        _createCommunity("Tiny Community");
        _allocate(1, 1000e6); // below OPERATING_BUFFER_PER_COMMUNITY (2000e6) + MIN_LENDABLE (50e6)
        assertEq(cc.communityImpactBudget(1), 0, "a community below its own operating buffer has no liquid budget");
    }

    function test_drawGate_notAMember() public {
        _primeEligible(member); // standing exists, but no seat
        vm.prank(member);
        _revert(ICreditCore.NotAMember.selector);
        cc.draw(0, 50e6, AGREEMENT);
    }

    function test_drawGate_blocked() public {
        _gatesPass();
        vm.prank(screener);
        registry.setBlocked(member, true);
        vm.prank(member);
        _revert(ICreditCore.AccountBlocked.selector);
        cc.draw(0, 50e6, AGREEMENT);
    }

    /// Suspension is the exit-only state, "no in only out of
    /// existing". The draw pays USDC out of the Treasury, so a member the community voted to
    /// remove opening a new obligation is a money gap, not a cosmetic one. The seat
    /// is Suspended by a removal vote and `isMember` is what refuses it.
    /// The settle half, what is in can still come out, is `RemovalTest`'s proof 11.
    function test_drawGate_suspended() public {
        _gatesPass();
        _joinSeasoned(member2); // two more seats, so the removal has three yes votes besides the
        _joinSeasoned(other); // target
        _removeByVote(member);
        vm.prank(member);
        _revert(ICreditCore.NotAMember.selector);
        cc.draw(0, 50e6, AGREEMENT);
    }

    /// The real removal path: proposed by the steward (`creator`, the founding host),
    /// carried at the community threshold, and executed once the window closes. Nothing here is
    /// a harness poke, so the gate above is proved against the state the community itself sets.
    function _removeByVote(address who) internal {
        Community community = Community(_community(0));
        vm.prank(creator);
        community.proposeRemoval(who);
        uint256 voteId = community.activeRemovalVoteId(who);
        vm.prank(creator);
        community.castVote(voteId, true);
        vm.prank(member2);
        community.castVote(voteId, true);
        vm.prank(other);
        community.castVote(voteId, true);
        (, uint64 window) = config.communityVote();
        vm.warp(block.timestamp + window + 1);
        community.executeRemoval(who);
        assertEq(uint8(community.seatStateOf(who)), uint8(ICommunity.SeatState.Suspended), "the community vote landed");
    }

    function test_drawGate_notSeasoned() public {
        vm.prank(member);
        registry.attest(1);
        usdc.mint(member, SEAT);
        vm.startPrank(member);
        usdc.approve(address(_community(0)), SEAT);
        _invitedJoin(_community(0), member);
        vm.stopPrank();
        vm.warp(block.timestamp + 14 days - 1); // one second short of the window
        _primeEligible(member);
        vm.prank(member);
        _revert(ICreditCore.NotSeasoned.selector);
        cc.draw(0, 50e6, AGREEMENT);
    }

    /// One open tab is account-wide: an open obligation in community A blocks a draw in
    /// community B, where the member is separately a seasoned, standing member.
    function test_drawGate_oneOpenTabIsAccountWide() public {
        _gatesPass();
        _drawFirst(member, 50e6);

        address community2 = _createCommunity("Other Community");
        usdc.mint(member, SEAT);
        vm.startPrank(member);
        usdc.approve(community2, SEAT);
        _invitedJoin(community2, member);
        vm.stopPrank();
        vm.warp(block.timestamp + 14 days + 1);
        _allocate(1, ALLOCATION);
        standing.primeImpact(1, member, 500e6, 1000e6);

        vm.prank(member);
        _revert(ICreditCore.TabAlreadyOpen.selector);
        cc.draw(1, 50e6, AGREEMENT);
    }

    /// The full Standing drawable: a seasoned member with no Impact Units has no Line
    /// (drawable < MIN_LENDABLE) and cannot draw, with every other gate passing.
    function test_drawGate_notEligible() public {
        _joinSeasoned(member);
        vm.prank(member);
        _revert(ICreditCore.NotEligible.selector);
        cc.draw(0, 50e6, AGREEMENT);
    }

    function test_drawGate_exceedsLine() public {
        _gatesPass();
        vm.prank(member);
        _revert(ICreditCore.ExceedsLine.selector);
        cc.draw(0, 50e6 + 1, AGREEMENT);
    }

    function test_drawGate_communityClosed() public {
        _createCommunity("Closed Community");
        vm.prank(governance);
        cc.closeCommunity(1); // no allocation, no debt: closure is allowed
        vm.prank(member);
        _revert(ICreditCore.CommunityIsClosed.selector);
        cc.draw(1, 50e6, AGREEMENT);
    }

    /// The retained-capital gate on the Treasury outflow: a draw is an outflow like
    /// any other and gets no path of its own. The allocation multisig consumes the
    /// unallocated cushion (an accounting action that moves no USDC), and the draw
    /// reverts BelowRetainedCapital, unwinding completely: no tab, no book entry, no USDC.
    function test_drawGate_retainedCapital() public {
        uint256 cushion = usdc.balanceOf(address(cc)) - (ALLOCATION + BASE_REQUIRED);
        assertGt(cushion, 50e6, "fixture must leave a cushion to consume");
        _createCommunity("Sink Community"); // a second community to park the cushion in
        _allocate(1, cushion - 1); // leaves 1e6 of slack: any draw must fail

        _gatesPass();
        uint256 walletBefore = usdc.balanceOf(member);
        vm.prank(member);
        _revert(ICreditCore.BelowRetainedCapital.selector);
        cc.draw(0, 50e6, AGREEMENT);
        assertFalse(cc.hasOpenTab(member), "failed draw left no tab");
        assertEq(cc.totalOutstandingPrincipal(), 0, "failed draw left no book entry");
        assertEq(usdc.balanceOf(member), walletBefore, "failed draw moved no USDC");
    }

    /// Mutation catalogue: `_stageOutstanding`'s four-tuple return is a straight mapping from
    /// `_stageBucket[0..3]` to `(current, late, finalCure, defaultRecovery)`. Transposing which
    /// bucket answers to which name misweights the credit-loss reserve (5% vs 25% at
    /// launch) without tripping any revert. No test independently recomputed the reserve from
    /// two real obligations sitting in different stages with different amounts, so a transposed
    /// mapping passed the whole suite green.
    function test_requiredRetainedCapital_stageBucketsAreNotTransposed() public {
        _gatesPass();
        _drawFirst(member, 50e6); // stays in Tenor: the "current" bucket

        _joinSeasoned(member2);
        _primeEligible(member2);
        uint64 ts2 = _drawFirst(member2, 40e6);
        (, uint64 late,,,) = _boundaries();
        vm.warp(ts2 + late + 1 days); // Late
        _settle(member2, 1e6); // materializes the crossing into the "late" bucket; tab stays open

        ICreditCore.TreasuryView memory v = cc.treasuryView();
        assertEq(v.current, 50e6, "current bucket holds member's obligation");
        assertEq(v.late, 39e6, "late bucket holds member2's obligation, net the partial settle");

        (uint16 cb, uint16 lb,,) = config.creditLossReserveBps();
        uint256 expectedCreditLoss = (v.current * cb) / 10_000 + (v.late * lb) / 10_000;
        assertEq(
            v.requiredRetainedCapital,
            BASE_REQUIRED + expectedCreditLoss,
            "current and late are weighted by their own bps, not each other's"
        );
    }

    // =================================================================
    // The Credit Agreement: once per account, hash in the event
    // =================================================================

    function test_creditAgreement_oncePerAccount() public {
        _gatesPass();

        vm.prank(member);
        _revert(ICreditCore.CreditAgreementRequired.selector);
        cc.draw(0, 50e6, bytes32(0));

        vm.expectEmit(true, true, true, true, address(cc));
        emit ICreditCore.Drawn(0, member, 50e6, 0, uint64(block.timestamp), AGREEMENT);
        vm.prank(member);
        cc.draw(0, 50e6, AGREEMENT);
        (bool accepted, bytes32 recorded) = cc.agreementOf(member);
        assertTrue(accepted, "agreement accepted");
        assertEq(recorded, AGREEMENT, "agreement hash recorded");

        // Settle in full, then draw again: no agreement required, hash zero in the event.
        _settle(member, 50e6);
        vm.expectEmit(true, true, true, true, address(cc));
        emit ICreditCore.Drawn(0, member, 50e6, 0, uint64(block.timestamp), bytes32(0));
        vm.prank(member);
        cc.draw(0, 50e6, bytes32(0));

        // Account-wide, not per community: a first draw in a second community needs no
        // second acceptance, because the account already accepted once.
        _settle(member, 50e6);
        address community2 = _createCommunity("Other Community");
        usdc.mint(member, SEAT);
        vm.startPrank(member);
        usdc.approve(community2, SEAT);
        _invitedJoin(community2, member);
        vm.stopPrank();
        vm.warp(block.timestamp + 14 days + 1);
        _allocate(1, ALLOCATION);
        standing.primeImpact(1, member, 500e6, 1000e6);
        vm.prank(member);
        cc.draw(1, 50e6, bytes32(0));
    }

    // =================================================================
    // The aggregate Trust Extension cap
    // =================================================================

    /// N members cannot each take the community TE budget. Two Established members with
    /// 300e6 of te_earned each, against a community budget of min(4900e6, 20% x 2500e6) =
    /// 500e6: the first draw lands, the second at the same size reverts
    /// CommunityTeCapExceeded, and a smaller draw that fits passes.
    function test_draw_aggregateTeCapBinds() public {
        vm.startPrank(governance);
        standing.setImpactAttributor(governance);
        standing.creditCommunityAttributedYield(0, 2500e6);
        vm.stopPrank();

        // Top up community 0's allocation so a 350e6 draw is a small enough slice of budget
        // that the account-wide exposure cap (360e6), not the per-community concentration
        // cap, is what binds the Line for both members: concentration falls with every draw
        // (it is 12% of the shrinking budget), so at the original allocation the second
        // member's identical draw hit ExceedsLine before ever reaching the TE-cap check this
        // test is about. Budget of 4500e6 keeps concentration (12% of it, and of what remains
        // after the first draw) comfortably above 360e6, so the exposure cap binds instead.
        _allocate(0, 1550e6);

        _joinSeasoned(member);
        _joinSeasoned(member2);
        standing.primeImpact(0, member, 20e6, 1000e6);
        standing.primeImpact(0, member2, 20e6, 1000e6);
        standing.primeCompletedObligations(0, member, 7, uint64(block.timestamp - 200 days));
        standing.primeCompletedObligations(0, member2, 7, uint64(block.timestamp - 200 days));
        standing.primeTeEarned(0, member, 300e6);
        standing.primeTeEarned(0, member2, 300e6);

        assertEq(cc.communityTeBudget(0), 500e6, "budget is min(4900e6, 500e6)");

        vm.prank(member);
        cc.draw(0, 350e6, AGREEMENT);
        ICreditCore.ObligationView memory o1 = cc.obligationOf(member);
        assertGt(o1.teDrawn, 0, "draw recorded a TE component");
        assertLe(o1.teDrawn, 300e6, "TE component within the member's TE");
        assertEq(cc.teLiveOf(0), o1.teDrawn, "live TE equals the recorded component");

        vm.prank(member2);
        _revert(ICreditCore.CommunityTeCapExceeded.selector);
        cc.draw(0, 350e6, AGREEMENT);

        uint256 remaining = cc.communityTeBudget(0) - cc.teLiveOf(0);
        vm.prank(member2);
        cc.draw(0, remaining > 100e6 ? 100e6 : remaining, AGREEMENT);
        // The prior assertion here (`teLiveOf <= communityTeBudget`)
        // restated the gate `draw` had already enforced to reach this line; a successful call
        // cannot fail it. Assert the actual value instead: live TE is exactly the sum of both
        // members' recorded `teDrawn`, independently derived from the obligation records.
        ICreditCore.ObligationView memory o2 = cc.obligationOf(member2);
        assertEq(cc.teLiveOf(0), o1.teDrawn + o2.teDrawn, "live TE is exactly the sum of both obligations' teDrawn");
    }

    /// Mutation catalogue: the aggregate cap check is `>`, not `>=` (`_teLiveOf[c] + teComponent >
    /// budget`). A draw that lands the community's live TE exactly ON the budget must succeed;
    /// the test above only exercises comfortably-under and strictly-over. Mutating the operator
    /// to `>=` rejects the boundary draw and left the rest of the suite green.
    function test_draw_aggregateTeCapBinds_exactBudgetBoundaryAllowed() public {
        vm.startPrank(governance);
        standing.setImpactAttributor(governance);
        // A small attributed yield keeps the TE community cap (`teCommunityCapBps` of it) far
        // below every other cap the Line clamps on, so `base + budget` fits comfortably inside
        // `drawable` and this test isolates the aggregate cap's own boundary.
        standing.creditCommunityAttributedYield(0, 100e6);
        vm.stopPrank();
        _allocate(0, 1550e6);
        _joinSeasoned(member);
        standing.primeImpact(0, member, 100e6, 1000e6);
        standing.primeCompletedObligations(0, member, 7, uint64(block.timestamp - 200 days));
        standing.primeTeEarned(0, member, 500e6);

        uint256 base = cc.impactBase(0, member);
        uint256 budget = cc.communityTeBudget(0);
        uint256 amount = base + budget; // teComponent lands exactly at the cap
        (uint256 drawable,) = cc.line(0, member);
        assertGe(drawable, amount, "fixture must allow drawing exactly to the cap boundary");

        vm.prank(member);
        cc.draw(0, amount, AGREEMENT); // must not revert
        assertEq(cc.teLiveOf(0), budget, "live TE lands exactly at the community cap");
    }

    // =================================================================
    // Settle (one-to-one; never pausable)
    // =================================================================

    /// Principal falls by exactly what was paid at every stage, and nothing else is owed.
    function test_settle_oneToOneAtEveryStage() public {
        _gatesPass();
        uint64 ts = _drawFirst(member, 50e6);
        (uint64 grace, uint64 late, uint64 fc, uint64 dr,) = _boundaries();

        uint256[5] memory marks = [uint256(10 days), uint256(grace), uint256(late), uint256(fc), uint256(dr)];
        for (uint256 i; i < marks.length; i++) {
            vm.warp(ts + uint64(marks[i]));
            uint256 before = cc.obligationOf(member).principal;
            uint256 walletBefore = usdc.balanceOf(member);
            _settle(member, 5e6);
            assertEq(
                cc.obligationOf(member).principal, before - 5e6, "principal fell by exactly the payment at every stage"
            );
            assertEq(usdc.balanceOf(member), walletBefore, "no charge, fee or interest was taken");
        }
    }

    /// Overpayment refunds to the unit: pay 12e6 against 10e6, principal
    /// closes, exactly 2e6 comes back.
    function test_settle_overpaymentRefundExact() public {
        _gatesPass();
        _drawFirst(member, 50e6);
        uint256 afterDraw = usdc.balanceOf(member);
        _settle(member, 40e6);
        _settle(member, 12e6);
        assertEq(cc.obligationOf(member).principal, 0, "closed");
        assertTrue(cc.obligationOf(member).closed, "closed flag");
        // Net cost check: minted 40e6 + 12e6 across the two settles, paid net exactly the
        // 50e6 principal drawn (the second settle overpays 10e6 owed by 2e6, refunded).
        assertEq(usdc.balanceOf(member), afterDraw + 40e6 + 12e6 - 50e6, "overpayment refunded to the unit");
    }

    /// Settle never pauses. No pause mechanism exists on chain yet (the
    /// Emergency Guardian comes later), so the test drives every blocking state that exists
    /// today and asserts repayment keeps working under all of them: the draw-block
    /// flag (which must never touch repayment rights), and a venue set
    /// emptied to zero (the adapter-pause analogue).
    function test_settle_neverPausable() public {
        _gatesPass();
        _drawFirst(member, 50e6);
        (, uint64 late,,,) = _boundaries();
        vm.warp(block.timestamp + late); // deep in delinquency

        vm.prank(screener);
        registry.setBlocked(member, true);
        assertEq(cc.venueCount(), 0, "no venues: the adapter surface is as paused as it can be");

        uint256 before = cc.obligationOf(member).principal;
        _settle(member, 5e6);
        assertEq(cc.obligationOf(member).principal, before - 5e6, "settle worked while blocked and venueless");
    }

    /// Test 8: full settlement before day 155 avoids Default classification, and at
    /// exactly 155 days the classification applies instead (the boundary, both sides).
    function test_settle_fullBeforeDefaultAvoidsClassification() public {
        (,,, uint64 dr,) = _boundaries();

        _gatesPass();
        _drawFirst(member, 50e6);
        vm.warp(block.timestamp + dr - 1);
        _settle(member, 50e6);
        // `standingCountersOf`'s third return, cumulative community
        // attributed yield, is not part of what this test is about and was previously
        // destructured only to assert it against itself (`2500e6 - 2500e6 == 0`, which no
        // implementation could fail); skipped here instead.
        (uint256 completed,,, bool disq) = standing.standingCountersOf(0, member);
        assertEq(completed, 1, "obligation completed");
        assertFalse(disq, "no Default classification before day 155");
        assertFalse(cc.hasOpenTab(member), "tab closed");

        _joinSeasoned(member2);
        standing.primeImpact(0, member2, 500e6, 1000e6);
        vm.prank(member2);
        cc.draw(0, 50e6, AGREEMENT);
        uint64 ts2 = cc.obligationOf(member2).drawTimestamp;
        vm.warp(ts2 + dr); // exactly 155 days: Default applies, then full settlement
        _settle(member2, 50e6);
        (,,, bool disq2) = standing.standingCountersOf(0, member2);
        assertTrue(disq2, "Default classification applied at exactly 155 days");
    }

    /// Test 9: full settlement during Late or Final Cure freezes conduct at its decayed
    /// value and records it as a scar. Day 80: decay = 1 - 15/90.
    function test_settle_scarAtDecayedValue() public {
        _gatesPass();
        _drawFirst(member, 50e6);
        vm.warp(block.timestamp + 80 days);
        uint256 decayed = standing.conductDecayAt(80 days);
        // The multiplier itself floors, computed as (span - dt) / span rather than
        // 1 - dt / span, so the rounding direction is a decision (StandingMath.conductDecay).
        uint256 remainingInWindow = 155 days - 80 days;
        uint256 window = 90 days;
        assertEq(decayed, remainingInWindow * 1e18 / window, "day-80 decay value");
        _settle(member, 50e6);
        // The scar is the frozen value: conduct reads it back at heal time zero.
        assertEq(
            standing.conductFactor(0, member, cc.tabSnapshot(0, member)), decayed, "conduct frozen at the decayed value"
        );
    }

    /// `_closeTab`'s scar gate, `if (o.stage >= uint8(Stage.Late))`, survived
    /// deletion (mutated to `if (true)`) against the full suite at one point, because every
    /// existing debt test that builds a `MemberTabSnapshot` used a test-side copy of
    /// `_tabSnapshot` (`_liveTabSnapshot`, now deleted) rather than the real composition, so the
    /// real `_closeTab` scar gate was never exercised on a punctual (never-delinquent) settle.
    /// A member who settles inside Tenor must record no scar, so the completion's te_earn
    /// increment survives; a scar zeroes `te_earned` immediately (`_recordScar`), and since
    /// `_recordScar` runs before `creditObligationCompletion` in `_closeTab`, an unconditional
    /// scar gate would zero the very increment this settle is about to earn.
    function test_punctualSettleRecordsNoScar() public {
        _gatesPass();
        _drawFirst(member, 50e6);
        _settle(member, 50e6); // still inside Tenor: never delinquent
        (, uint256 teEarned,,) = standing.standingCountersOf(0, member);
        assertEq(
            teEarned,
            config.teEarnIncrement(),
            "a settle that was never delinquent records no scar, so te_earned is credited"
        );
    }

    /// Test 10: settling the last unit closes the tab, which is what makes the account
    /// eligible to draw again.
    function test_settle_lastUnitClosesTabAndPermitsNewDraw() public {
        _gatesPass();
        _drawFirst(member, 50e6);
        _settle(member, 49e6);
        assertTrue(cc.hasOpenTab(member), "still open before the last unit");
        vm.prank(member);
        _revert(ICreditCore.TabAlreadyOpen.selector);
        cc.draw(0, 50e6, bytes32(0));

        _settle(member, 1e6);
        assertFalse(cc.hasOpenTab(member), "closed by the last unit");
        vm.prank(member);
        cc.draw(0, 50e6, bytes32(0)); // agreement already accepted; succeeds
        assertEq(cc.obligationOf(member).principal, 50e6, "new tab");
    }

    function test_settle_noTabReverts() public {
        vm.prank(member);
        _revert(ICreditCore.NoOpenTab.selector);
        cc.settle(5e6);
    }

    // =================================================================
    // total_charges == 0: the property test
    // =================================================================

    /// Fuzz over principal, elapsed time and settlement schedules: the sum of everything
    /// a member pays never exceeds the principal drawn, equals principal-minus-outstanding
    /// at every step, and is exactly the principal drawn at close. Some payments overpay.
    function testFuzz_totalChargesZero(uint128 principalSeed, uint128 scheduleSeed) public {
        _gatesPass();
        standing.primeCompletedObligations(0, member, 2, uint64(block.timestamp - 60 days)); // Developing
        (uint256 drawable, bool eligible) = cc.line(0, member);
        assertTrue(eligible, "fixture must be eligible");
        uint256 maxDraw = drawable < 295e6 ? drawable : 295e6;
        uint256 principal = 50e6 + _pick(principalSeed, 0, maxDraw - 50e6);

        uint256 minted = principal + 1_000e6;
        usdc.mint(member, minted);
        vm.startPrank(member);
        usdc.approve(address(cc), type(uint256).max);
        cc.draw(0, principal, AGREEMENT);
        vm.stopPrank();

        uint256 steps = 2 + _pick(scheduleSeed, 0, 4);
        for (uint256 i; i < steps; i++) {
            // An earlier step's deliberate overpayment can close the tab before the schedule
            // is done; once closed there is nothing left to settle.
            if (cc.obligationOf(member).closed) break;
            vm.warp(block.timestamp + _pick(scheduleSeed >> (8 * i), 0, 55 days));
            uint256 stepOutstanding = cc.obligationOf(member).principal;
            uint256 amt = _pick(scheduleSeed >> (16 * i), 1e6, stepOutstanding + 5e6); // sometimes overpays
            vm.prank(member);
            cc.settle(amt);

            // Total income is the settle-funding buffer (`minted`) plus the draw's own payout
            // (`principal`, paid directly to the member by `draw`); net is that income less
            // what remains in the wallet.
            uint256 net = (minted + principal) - usdc.balanceOf(member);
            assertLe(net, principal, "total_charges == 0: never paid more than principal");
            assertEq(net, principal - cc.obligationOf(member).principal, "net paid is exactly the principal retired");
        }

        // Close the tab, whatever is left, overpaying deliberately.
        uint256 outstanding = cc.obligationOf(member).principal;
        if (outstanding != 0) {
            vm.prank(member);
            cc.settle(outstanding + 3e6);
        }
        assertEq((minted + principal) - usdc.balanceOf(member), principal, "paid exactly the principal drawn at close");
        assertTrue(cc.obligationOf(member).closed, "tab closed");
        assertEq(cc.obligationOf(member).principal, 0, "no residual debt");
    }

    function _pick(uint256 seed, uint256 lo, uint256 hi) internal pure returns (uint256) {
        if (hi <= lo) return lo;
        return lo + seed % (hi - lo + 1);
    }

    // =================================================================
    // Deterministic write-off
    // =================================================================

    /// Tests 11 and 13: finalizes at exactly 365 days, not before, and any address can
    /// call the finalizer.
    function test_writeOff_exactly365AnyoneCanFinalize() public {
        _gatesPass();
        uint64 ts = _drawFirst(member, 50e6);
        (,,,, uint64 wo) = _boundaries();

        vm.warp(ts + wo - 1);
        vm.prank(other);
        _revert(ICreditCore.NotYetWrittenOff.selector);
        cc.finalizeWriteOff(member);

        vm.warp(ts + wo);
        vm.prank(other);
        cc.finalizeWriteOff(member);
        ICreditCore.ObligationView memory o = cc.obligationOf(member);
        assertTrue(o.writtenOff, "written off");
        assertFalse(cc.hasOpenTab(member), "terminal");
        assertEq(uint8(cc.currentStage(member)), uint8(ICreditCore.Stage.WrittenOff), "currentStage is Written Off");
        assertEq(cc.outstandingPrincipalOf(0), 0, "receivable removed from the community");
        assertEq(cc.totalOutstandingPrincipal(), 0, "book empty");
    }

    /// Test 12: finalizing twice is impossible. A second call from a different address
    /// reverts AlreadyWrittenOff, the loss counted exactly once, and exactly one event
    /// fired.
    function test_writeOff_doubleFinalizeImpossible() public {
        _gatesPass();
        uint64 ts = _drawFirst(member, 50e6);
        (,,,, uint64 wo) = _boundaries();
        vm.warp(ts + wo);

        uint256 allocatedBefore = cc.totalAllocated();
        vm.recordLogs();
        vm.prank(other);
        cc.finalizeWriteOff(member);
        assertEq(_countWriteOffEvents(vm.getRecordedLogs()), 1, "exactly one write-off event");
        assertEq(allocatedBefore - cc.totalAllocated(), 50e6, "community absorbed the loss exactly once");

        vm.prank(governance); // a different address
        _revert(ICreditCore.AlreadyWrittenOff.selector);
        cc.finalizeWriteOff(member);
        assertEq(allocatedBefore - cc.totalAllocated(), 50e6, "loss still counted once");

        vm.prank(member);
        _revert(ICreditCore.NoOpenTab.selector);
        cc.settle(1e6);
    }

    function _countWriteOffEvents(Vm.Log[] memory logs) internal view returns (uint256 n) {
        bytes32 topic = keccak256("WriteOffFinalized(uint256,address,uint256,uint256,uint256)");
        for (uint256 i; i < logs.length; i++) {
            if (logs[i].emitter == address(cc) && logs[i].topics[0] == topic) n++;
        }
    }

    /// Write-off accounting: the book emptied, TE exposure released, and the Default
    /// classification applied at 155 days even though nothing touched the tab between 95
    /// and 365 days (the skip materializes Default consequences before the write-off).
    function test_writeOff_accountingAndSkippedDefault() public {
        _gatesPass();
        uint64 ts = _drawFirst(member, 50e6);
        (,,,, uint64 wo) = _boundaries();
        vm.warp(ts + wo);

        (uint256 c, uint256 l, uint256 f, uint256 d) = cc.stageOutstanding();
        assertEq(c + l + f + d, 50e6, "book still carries the untouched obligation");

        vm.prank(other);
        cc.finalizeWriteOff(member);
        (c, l, f, d) = cc.stageOutstanding();
        assertEq(c + l + f + d, 0, "book emptied");
        (,,, bool disq) = standing.standingCountersOf(0, member);
        assertTrue(disq, "pre-Default Units disqualified at formal Default, not skipped by the jump");
        assertEq(cc.teLiveOf(0), 0, "TE exposure released");
        assertEq(cc.openObligationCountOf(0), 0, "no unresolved tabs");
    }

    /// A settle at the write-off boundary materializes nothing that survives: the debt is
    /// terminal, so the settle reverts NoOpenTab, and the write-off still awaits its
    /// permissionless finalizer (`finalizeWriteOff`, or `materialize`).
    function test_writeOff_settleAtBoundaryRevertsTerminal() public {
        _gatesPass();
        uint64 ts = _drawFirst(member, 50e6);
        (,,,, uint64 wo) = _boundaries();
        vm.warp(ts + wo);
        vm.prank(member);
        _revert(ICreditCore.NoOpenTab.selector);
        cc.settle(50e6);
        assertFalse(cc.obligationOf(member).writtenOff, "a reverting settle leaves no state");

        vm.prank(other);
        cc.finalizeWriteOff(member);
        assertTrue(cc.obligationOf(member).writtenOff, "finalizer materializes it");
    }

    // =================================================================
    // Trust Extension removed at Late entry
    // =================================================================

    /// Test 20: at 65d-1s Trust Extension is present; at 65d it is zero, with the
    /// obligation still open.
    function test_trustExtension_removedAtLateEntry() public {
        vm.startPrank(governance);
        standing.setImpactAttributor(governance);
        standing.creditCommunityAttributedYield(0, 100e6); // TE budget 20e6
        vm.stopPrank();
        _joinSeasoned(member);
        standing.primeImpact(0, member, 500e6, 1000e6);
        standing.primeCompletedObligations(0, member, 1, uint64(block.timestamp - 40 days)); // ProvenOnce
        standing.primeTeEarned(0, member, 10e6);
        assertEq(standing.trustExtension(0, member, cc.tabSnapshot(0, member)), 10e6, "TE present before the draw");

        uint64 ts = _drawFirst(member, 50e6);
        (, uint64 late,,,) = _boundaries();

        vm.warp(ts + late - 1);
        assertGt(standing.trustExtension(0, member, cc.tabSnapshot(0, member)), 0, "65d-1s: Trust Extension present");
        assertTrue(cc.hasOpenTab(member), "obligation still open");

        vm.warp(ts + late);
        assertEq(
            standing.trustExtension(0, member, cc.tabSnapshot(0, member)), 0, "65d: Trust Extension zero at Late entry"
        );
        assertTrue(cc.hasOpenTab(member), "obligation still open");
    }

    /// `_tabSnapshot`'s `o.communityId == communityId` guard is correct and necessary, not
    /// decoration. An obligation open in community 0 must read `openInCommunity == false` when
    /// the snapshot is composed for community 1, so community 1's conduct is not decayed by a
    /// delinquency that belongs to a different community's Line. This exercises the real
    /// `CreditCore._tabSnapshot` through the `tabSnapshot` pass-through, not a test-side copy.
    function test_tabSnapshot_communityGuardIsolatesDelinquency() public {
        _createCommunity("Second Community");
        _allocate(1, ALLOCATION);

        _gatesPass();
        uint64 ts = _drawFirst(member, 50e6);
        (, uint64 late,,,) = _boundaries();
        vm.warp(ts + late); // Late entry in community 0: full open delinquency decay applies

        ICreditStanding.MemberTabSnapshot memory own = cc.tabSnapshot(0, member);
        assertTrue(own.openInCommunity, "open in the community it was drawn in");
        assertGt(own.elapsedSinceDraw, 0, "elapsed measured in its own community");
        assertEq(
            standing.conductFactor(0, member, own),
            standing.conductDecayAt(late),
            "community 0 sees the decayed conduct"
        );

        ICreditStanding.MemberTabSnapshot memory other = cc.tabSnapshot(1, member);
        assertFalse(other.openInCommunity, "not open in a community it never drew in");
        assertEq(other.elapsedSinceDraw, 0, "no elapsed time attributed to the other community");
        assertEq(
            standing.conductFactor(1, member, other),
            1e18,
            "community 1's conduct is undecayed by community 0's delinquency"
        );

        // The account-wide half (`openAnywhere`/`principal`) is unaffected by the community
        // match: both snapshots see the one open tab.
        assertTrue(other.openAnywhere, "openAnywhere is account-wide, not per-community");
        assertEq(other.principal, own.principal, "principal is account-wide, not per-community");
    }

    /// A closed obligation is not an open one. `_tabSnapshot`'s `exists` guard drops the
    /// snapshot for a tab that is closed or written off; without it, a punctual repayment
    /// leaves `openInCommunity` true forever, and `elapsedSinceDraw` keeps growing off the
    /// original `drawTimestamp`, so the member's conduct decays past the Late boundary for a
    /// debt they settled on time and their Trust Extension is zeroed by
    /// `_hasOpenDelinquency`. Deleting either `!o.closed` or `!o.writtenOff` leaves the rest of
    /// the suite green, which is why this test exists.
    function test_tabSnapshot_closedTabIsNotAnOpenDelinquency() public {
        _gatesPass();
        _drawFirst(member, 50e6);
        _settle(member, 50e6); // punctual, inside Tenor: the tab closes clean

        (, uint64 late,,,) = _boundaries();
        vm.warp(block.timestamp + late + 1 days); // well past Late, measured off the old draw

        ICreditStanding.MemberTabSnapshot memory s = cc.tabSnapshot(0, member);
        assertFalse(s.openAnywhere, "a closed tab is not open anywhere");
        assertFalse(s.openInCommunity, "a closed tab is not an open delinquency");
        assertEq(s.elapsedSinceDraw, 0, "no elapsed time attributed to a closed tab");
        assertEq(
            standing.conductFactor(0, member, s), 1e18, "a settled obligation does not decay conduct after it closes"
        );
    }

    /// `_materialize` returns early for a tab that is already closed or written off. Without
    /// the `o.closed` term, a member who repaid in full and comes back more than the write-off
    /// window later has their settled obligation re-derived as Written Off and run through
    /// `_executeWriteOff` a second time: `recordFormalDefault` fires on an account that never
    /// defaulted, `_openObligationCount` is decremented for an obligation already removed from
    /// it, and the member is marked `writtenOff`. Deleting `|| o.closed` from either
    /// `_materialize` or `_tabSnapshot` leaves the rest of the suite green.
    function test_materialize_ignoresAnAlreadyClosedTab() public {
        _gatesPass();
        _drawFirst(member, 50e6);
        _settle(member, 50e6); // repaid in full, inside Tenor

        (,,,, uint64 wo) = _boundaries();
        vm.warp(block.timestamp + wo + 1 days); // past the write-off boundary, on a closed tab

        // Any debt-sensitive entry point materializes first. A second draw is the ordinary one.
        _primeEligible(member);
        vm.prank(member);
        cc.draw(0, 50e6, AGREEMENT);

        assertFalse(standing.isAccountDefaulted(member), "a fully repaid obligation never defaults the account");
        assertFalse(cc.obligationOf(member).writtenOff, "the new obligation is not written off");
    }

    /// The stronger form of `test_materialize_ignoresAnAlreadyClosedTab`. That test carries the
    /// right assertions and never reaches them: with only one obligation in the community, the
    /// second write-off underflows `_openObligationCount` and the transaction reverts on
    /// arithmetic before `recordFormalDefault`'s consequence is observable. A live deployment
    /// with any other open obligation in the community does not underflow, so the consequence
    /// lands instead. This test reproduces that state: a second member holds an open tab, and
    /// the materializing entry point is `materialize`, which applies no eligibility gate
    /// afterwards and so does not mask the result behind the very account-default lockout being asserted
    /// against. (It was moved here from `interceptedTransfer`, which had
    /// the same property and no longer exists.)
    function test_materialize_repaidTabIsNeverWrittenOffTwice() public {
        _gatesPass();
        _drawFirst(member, 50e6);
        _settle(member, 50e6); // repaid in full, inside Tenor

        _joinSeasoned(member2);
        _primeEligible(member2);
        vm.prank(member2);
        cc.draw(0, 50e6, AGREEMENT); // keeps _openObligationCount above zero

        (,,,, uint64 wo) = _boundaries();
        vm.warp(block.timestamp + wo + 1 days);

        vm.prank(other);
        cc.materialize(member);

        assertFalse(
            standing.isAccountDefaulted(member), "a fully repaid obligation never formally defaults the account"
        );
        assertFalse(cc.obligationOf(member).writtenOff, "a settled obligation is not written off later");
        (uint256 drawable, bool eligible) = cc.line(0, member);
        assertGt(drawable, 0, "the repaid account keeps a live Line");
        assertTrue(eligible, "the repaid account stays eligible everywhere");
    }

    // =================================================================
    // The permissionless `materialize`
    // =================================================================

    /// The reserve bucket each stage is reserved in, written out rather than derived, so these tests
    /// fail if the production mapping moves: Tenor and Grace are Current (0), then Late (1), Final
    /// Cure (2), Default Recovery (3).
    function _expectedBucket(ICreditCore.Stage stage) internal pure returns (uint256) {
        if (stage == ICreditCore.Stage.Tenor || stage == ICreditCore.Stage.Grace) return 0;
        if (stage == ICreditCore.Stage.Late) return 1;
        if (stage == ICreditCore.Stage.FinalCure) return 2;
        return 3;
    }

    function _buckets() internal view returns (uint256[4] memory b) {
        (b[0], b[1], b[2], b[3]) = cc.stageOutstanding();
    }

    /// A borrower who draws and never returns: nothing touches the tab, so the book still reserves
    /// it as Current long after it is Late. `materialize` moves it to the right bucket, and the
    /// reserve requirement moves with it.
    function test_materialize_movesAStaleTabToItsStageAndBucket() public {
        _gatesPass();
        uint64 ts = _drawFirst(member, 50e6);
        (, uint64 late, uint64 fc, uint64 dr,) = _boundaries();

        vm.warp(ts + late + 1 days);
        assertEq(_buckets()[0], 50e6, "fixture: the untouched tab is still booked as Current");
        uint256 requiredStale = cc.requiredRetainedCapital();
        vm.prank(other);
        cc.materialize(member);
        assertEq(_buckets()[0], 0, "left Current");
        assertEq(_buckets()[1], 50e6, "booked as Late");
        assertGt(cc.requiredRetainedCapital(), requiredStale, "the Late reserve is now required");

        vm.warp(ts + fc);
        vm.prank(other);
        cc.materialize(member);
        assertEq(_buckets()[2], 50e6, "booked as Final Cure");

        vm.warp(ts + dr);
        assertFalse(standing.isAccountDefaulted(member), "fixture: formal Default not yet recorded");
        vm.prank(other);
        cc.materialize(member);
        assertEq(_buckets()[3], 50e6, "booked as Default Recovery");
        assertTrue(standing.isAccountDefaulted(member), "formal Default's consequences recorded");
    }

    /// At the write-off boundary `materialize` executes the write-off exactly as `finalizeWriteOff`
    /// does, once.
    function test_materialize_atTheWriteOffBoundaryWritesOffOnce() public {
        _gatesPass();
        uint64 ts = _drawFirst(member, 50e6);
        (,,,, uint64 wo) = _boundaries();
        vm.warp(ts + wo);

        uint256 allocationBefore = cc.allocationOf(0);
        vm.prank(other);
        cc.materialize(member);
        assertTrue(cc.obligationOf(member).writtenOff, "written off");
        assertEq(allocationBefore - cc.allocationOf(0), 50e6, "the loss was absorbed once");

        vm.recordLogs();
        vm.prank(other);
        cc.materialize(member);
        assertEq(vm.getRecordedLogs().length, 0, "a second call emitted something");
        assertEq(allocationBefore - cc.allocationOf(0), 50e6, "the loss was absorbed twice");
    }

    /// An account with no open obligation: never drawn, repaid in full, or already written off.
    /// Nothing moves, nothing is emitted, nothing reverts.
    function test_materialize_isANoOpWithoutAnOpenObligation() public {
        uint256[4] memory before = _buckets();
        vm.recordLogs();
        cc.materialize(other);
        assertEq(vm.getRecordedLogs().length, 0, "never drawn: emitted something");
        assertEq(abi.encode(_buckets()), abi.encode(before), "never drawn: the book moved");
        assertFalse(standing.isAccountDefaulted(other), "never drawn: defaulted");

        _gatesPass();
        _drawFirst(member, 50e6);
        _settle(member, 50e6);
        (,,,, uint64 wo) = _boundaries();
        vm.warp(block.timestamp + wo + 1 days);
        before = _buckets();
        uint256 allocation = cc.allocationOf(0);
        vm.recordLogs();
        cc.materialize(member);
        assertEq(vm.getRecordedLogs().length, 0, "repaid: emitted something");
        assertEq(abi.encode(_buckets()), abi.encode(before), "repaid: the book moved");
        assertEq(cc.allocationOf(0), allocation, "repaid: a loss was absorbed");
        assertFalse(cc.obligationOf(member).writtenOff, "repaid: written off");
    }

    /// Called twice in the same block, the second call changes nothing and emits nothing.
    function testFuzz_materialize_twiceInOneBlockIsANoOp(uint256 elapsedSeed) public {
        _gatesPass();
        uint64 ts = _drawFirst(member, 50e6);
        (,,,, uint64 wo) = _boundaries();
        vm.warp(ts + bound(elapsedSeed, 0, uint256(wo) + 30 days));

        cc.materialize(member);
        uint256[4] memory afterFirst = _buckets();
        ICreditCore.ObligationView memory o = cc.obligationOf(member);
        bool defaulted = standing.isAccountDefaulted(member);
        uint256 allocation = cc.allocationOf(0);
        uint256 teLive = cc.teLiveOf(0);

        vm.recordLogs();
        vm.prank(other);
        cc.materialize(member);
        assertEq(vm.getRecordedLogs().length, 0, "the second call emitted something");
        assertEq(abi.encode(_buckets()), abi.encode(afterFirst), "the second call moved the book");
        assertEq(abi.encode(cc.obligationOf(member)), abi.encode(o), "the second call moved the obligation");
        assertEq(standing.isAccountDefaulted(member), defaulted, "the second call changed the default record");
        assertEq(cc.allocationOf(0), allocation, "the second call moved the allocation");
        assertEq(cc.teLiveOf(0), teLive, "the second call moved live Trust Extension");
    }

    /// `materialize` records only what the timestamp already says. For any elapsed time, after the
    /// call the principal sits in exactly the bucket for the live stage, never a later one; and one
    /// second before each boundary it has not crossed that boundary.
    function testFuzz_materialize_neverMovesAheadOfTheTimestamp(uint256 elapsedSeed) public {
        _gatesPass();
        uint64 ts = _drawFirst(member, 50e6);
        (,,, uint64 dr, uint64 wo) = _boundaries();
        vm.warp(ts + bound(elapsedSeed, 0, uint256(wo) - 1));

        ICreditCore.Stage live = cc.currentStage(member);
        vm.prank(other);
        cc.materialize(member);
        uint256[4] memory b = _buckets();
        for (uint256 i; i < 4; i++) {
            assertEq(b[i], i == _expectedBucket(live) ? 50e6 : 0, "principal booked outside the live stage's bucket");
        }
        assertEq(
            standing.isAccountDefaulted(member),
            block.timestamp >= uint256(ts) + dr,
            "formal Default recorded before its timestamp, or not at it"
        );
    }

    function test_materialize_oneSecondBeforeEachBoundaryDoesNotCross() public {
        _gatesPass();
        uint64 ts = _drawFirst(member, 50e6);
        (, uint64 late, uint64 fc, uint64 dr, uint64 wo) = _boundaries();

        vm.warp(ts + late - 1);
        cc.materialize(member);
        assertEq(_buckets()[0], 50e6, "crossed into Late a second early");
        vm.warp(ts + fc - 1);
        cc.materialize(member);
        assertEq(_buckets()[1], 50e6, "crossed into Final Cure a second early");
        vm.warp(ts + dr - 1);
        cc.materialize(member);
        assertEq(_buckets()[2], 50e6, "crossed into Default Recovery a second early");
        assertFalse(standing.isAccountDefaulted(member), "formally defaulted a second early");
        vm.warp(ts + wo - 1);
        cc.materialize(member);
        assertEq(_buckets()[3], 50e6, "written off a second early");
        assertFalse(cc.obligationOf(member).writtenOff, "written off a second early");
    }

    // =================================================================
    // The aggregate TE cap's release side
    // =================================================================

    /// The community cap is a LIVE exposure figure, so every path that ends an obligation
    /// releases the TE that obligation drew. Three sites do it: `_closeTab` (settled in full),
    /// `_materialize` at the formal-Default crossing, and `_executeWriteOff`
    /// for a tab that jumped straight past Default Recovery. Deleting any one of the three
    /// `_teLiveOf[...] -= o.teDrawn` statements leaves the rest of the suite green, and a
    /// community whose live TE never falls stops extending Trust Extension to anyone once the
    /// budget has been used once.
    function _teFixture() internal {
        vm.startPrank(governance);
        standing.setImpactAttributor(governance);
        standing.creditCommunityAttributedYield(0, 2500e6);
        vm.stopPrank();
        _allocate(0, 1550e6);
        _joinSeasoned(member);
        standing.primeImpact(0, member, 20e6, 1000e6);
        standing.primeCompletedObligations(0, member, 7, uint64(block.timestamp - 200 days));
        standing.primeTeEarned(0, member, 300e6);
    }

    function test_teLive_releasedWhenTheTabCloses() public {
        _teFixture();
        vm.prank(member);
        cc.draw(0, 350e6, AGREEMENT);
        assertGt(cc.teLiveOf(0), 0, "the draw took live TE");
        _settle(member, 350e6);
        assertEq(cc.teLiveOf(0), 0, "a closed obligation releases its live TE");
        // Mutation-catalogue CC-15: `_closeTab`'s `o.teDrawn = 0;` is a separate statement from
        // the `_teLiveOf` release right above it. Deleting it alone leaves the community-level
        // aggregate correct but the obligation's own record stale, which `obligationOf` would
        // report to any reader.
        assertEq(cc.obligationOf(member).teDrawn, 0, "the closed obligation's own teDrawn field is zeroed too");
    }

    function test_teLive_releasedAtTheFormalDefaultCrossing() public {
        _teFixture();
        uint64 ts = _drawFirst(member, 350e6);
        assertGt(cc.teLiveOf(0), 0, "the draw took live TE");
        (,,, uint64 dr,) = _boundaries();
        vm.warp(ts + dr);
        _settle(member, 1e6); // materializes the crossing; the tab stays open
        assertTrue(cc.hasOpenTab(member), "still open: this isolates the materialize release");
        assertEq(cc.teLiveOf(0), 0, "formal Default releases live TE");
        // Mutation-catalogue CC-16: the same separate-statement gap as CC-15, at the
        // `_materialize` formal-Default crossing instead of `_closeTab`.
        assertEq(cc.obligationOf(member).teDrawn, 0, "the still-open obligation's teDrawn field is zeroed too");
    }

    function test_teLive_releasedByAWriteOffThatSkippedDefault() public {
        _teFixture();
        uint64 ts = _drawFirst(member, 350e6);
        assertGt(cc.teLiveOf(0), 0, "the draw took live TE");
        (,,,, uint64 wo) = _boundaries();
        vm.warp(ts + wo); // straight from Tenor to Written Off: teDrawn is still live here
        cc.finalizeWriteOff(member);
        assertEq(cc.teLiveOf(0), 0, "the write-off releases live TE");
        // Mutation-catalogue CC-17: `_executeWriteOff`'s `o.teDrawn = 0;` is unconditional and
        // separate from the guarded `_teLiveOf` release above it.
        assertEq(cc.obligationOf(member).teDrawn, 0, "the written-off obligation's teDrawn field is zeroed too");
    }

    // =================================================================
    // A tab that cannot be closed by paying
    // =================================================================

    uint256 constant SCAR_QUEUE_MAX = 64;

    /// The reviewer's exact scenario: 64 scars primed and healed, a draw, a cure during Late.
    /// Before the fix, `_recordScar` reverted `QueueFull` unconditionally at 64 scars and the
    /// settle could never complete at any payment amount. After the fix, `_recordScar` prunes
    /// every fully-healed scar before the length check, so a long-lived, fully-cured account
    /// always has room to record a new one.
    function test_scarQueueFull_healedScarsArePrunedSoSettleCloses() public {
        // `onlyObligationLedger` is retired in favor of `onlyCreditCore`, wired
        // to `address(cc)` in `setUp`. Pranking as the real `cc` address exercises the gated
        // entry point directly, the same way the pre-split test pranked as an arbitrary address
        // `setObligationLedger` had assigned the role to.
        for (uint256 i; i < SCAR_QUEUE_MAX; i++) {
            vm.prank(address(cc));
            standing.recordScar(0, member, 5e17); // 0.50, an arbitrary already-cured value
        }
        vm.warp(block.timestamp + config.standingHealWindow() + 1); // every scar now fully healed

        _gatesPass();
        uint64 ts = _drawFirst(member, 50e6);
        (, uint64 late,,,) = _boundaries();
        vm.warp(ts + late + 1 days); // Late: a full settle here cures during delinquency

        // The test's name claims pruning happens, but the settle-closes
        // assertion below holds whether or not `_pruneHealedScars` ran, because the
        // `ScarDropped` branch guarantees the settle closes either way. `ScarRecorded` only
        // fires if a slot was actually freed by pruning; `ScarDropped` fires if the queue was
        // (wrongly) still full. This distinguishes "pruned, room found, scar recorded" from
        // "not pruned, still full, scar dropped", which the prior assertion could not.
        usdc.mint(member, 50e6);
        vm.startPrank(member);
        usdc.approve(address(cc), 50e6);
        vm.expectEmit(true, true, true, true, address(standing));
        emit ICreditStanding.ScarRecorded(0, member, standing.conductDecayAt(late + 1 days));
        cc.settle(50e6);
        vm.stopPrank();
        assertFalse(cc.hasOpenTab(member), "settle closed the tab despite a full scar list");
        assertTrue(cc.obligationOf(member).closed, "closed flag set");
    }

    /// The graceful-degradation half of the same fix: if the list is still full of UNHEALED
    /// scars after pruning, `_recordScar` records no scar and emits `ScarDropped` instead of
    /// reverting. The settle still completes and the tab still closes; the member (and their
    /// principal) never notice that the deepest-wins conduct machinery ran out of room.
    function test_scarQueueFull_unhealedStaysFullEmitsDroppedNotRevert() public {
        for (uint256 i; i < SCAR_QUEUE_MAX; i++) {
            vm.prank(address(cc));
            standing.recordScar(0, member, 5e17); // fresh: none of these have healed
        }

        _gatesPass();
        uint64 ts = _drawFirst(member, 50e6);
        (, uint64 late,,,) = _boundaries();
        vm.warp(ts + late + 1 days);

        usdc.mint(member, 50e6);
        vm.startPrank(member);
        usdc.approve(address(cc), 50e6);
        // `ScarDropped` is emitted by `CreditStanding`, not `CreditCore`.
        vm.expectEmit(true, true, true, true, address(standing));
        emit ICreditStanding.ScarDropped(0, member, standing.conductDecayAt(late + 1 days));
        cc.settle(50e6);
        vm.stopPrank();
        assertFalse(cc.hasOpenTab(member), "settle still closed the tab");
    }

    // =================================================================
    // A zero-amount draw climbs the ladder for free
    // =================================================================

    function test_drawGate_zeroAmountReverts() public {
        _gatesPass();
        vm.prank(member);
        _revert(ICreditCore.ZeroAmount.selector);
        cc.draw(0, 0, AGREEMENT);
        assertFalse(cc.hasOpenTab(member), "no tab opened for a rejected zero draw");
    }

    // =================================================================
    // Default consequences are
    // account-wide and persisted, not derived from one obligation's state
    // =================================================================

    /// Conduct zeroing at formal Default used to be derived from
    /// `o.closed || o.writtenOff`, so it evaporated back to 1.00 the instant a written-off (or
    /// post-Default-settled) obligation closed. The floor is now a persisted flag that
    /// survives both.
    function test_accountDefault_conductFloorPersistsPastWriteOff() public {
        _gatesPass();
        uint64 ts = _drawFirst(member, 50e6);
        (,,,, uint64 wo) = _boundaries();
        vm.warp(ts + wo);

        assertFalse(standing.isAccountDefaulted(member), "not yet defaulted before the finalizer runs");
        vm.prank(other);
        cc.finalizeWriteOff(member);

        assertTrue(standing.isAccountDefaulted(member), "account-wide default recorded");
        assertEq(
            standing.conductFactor(0, member, cc.tabSnapshot(0, member)),
            0,
            "conduct floor persists past write-off, not derived to 1.00"
        );
    }

    /// The same persistence for a full settle at or after formal Default (155 days), rather
    /// than a write-off: `_closeTab` runs, the obligation record closes, and pre-fix,
    /// `_openDelinquencyConduct`'s `o.closed` guard would have read conduct back to 1.00.
    function test_accountDefault_conductFloorPersistsPastPostDefaultSettle() public {
        _gatesPass();
        uint64 ts = _drawFirst(member, 50e6);
        (,,, uint64 dr,) = _boundaries();
        vm.warp(ts + dr);
        _settle(member, 50e6);

        assertTrue(cc.obligationOf(member).closed, "tab closed by the full settle");
        assertTrue(standing.isAccountDefaulted(member), "formal Default was already crossed");
        assertEq(
            standing.conductFactor(0, member, cc.tabSnapshot(0, member)),
            0,
            "conduct floor persists past the post-Default settle"
        );
    }

    /// Pre-Default disqualification used to be per-community, so a member written
    /// off in community 0 kept a full Line in community 1. It is now account-wide:
    /// `line()` returns `(0, false)` everywhere once the account has defaulted anywhere, with
    /// no ban and no per-community history required.
    function test_accountDefault_disqualificationIsAccountWide() public {
        _gatesPass();
        uint64 ts = _drawFirst(member, 50e6);
        (,,,, uint64 wo) = _boundaries();
        vm.warp(ts + wo);
        vm.prank(other);
        cc.finalizeWriteOff(member);

        address community2 = _createCommunity("Second Community");
        usdc.mint(member, SEAT);
        vm.startPrank(member);
        usdc.approve(community2, SEAT);
        _invitedJoin(community2, member);
        vm.stopPrank();
        vm.warp(block.timestamp + 14 days + 1);
        _allocate(1, ALLOCATION);
        standing.primeImpact(1, member, 500e6, 1000e6);

        (uint256 drawable, bool eligible) = cc.line(1, member);
        assertEq(drawable, 0, "no Line in a community the member never drew in either");
        assertFalse(eligible, "account-wide disqualification blocks every community");
        vm.prank(member);
        _revert(ICreditCore.NotEligible.selector);
        cc.draw(1, 50e6, AGREEMENT);
    }
}
