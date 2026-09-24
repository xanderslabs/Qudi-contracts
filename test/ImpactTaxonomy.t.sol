// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {ICreditCore} from "../src/interfaces/ICreditCore.sol";
import {Config} from "../src/Config.sol";
import {IConfig} from "../src/interfaces/IConfig.sol";
import {MockUSDC} from "./mocks/MockUSDC.sol";
import {CreditStandingHarness} from "./helpers/CreditStandingHarness.sol";
import {MockCommunityFactory, MockSeatStamps} from "./helpers/MockCommunityFactory.sol";
import {MockCreditCoreWiring} from "./helpers/MockCreditCoreWiring.sol";

/// What is earned belongs to the seat,
/// what is a consequence belongs to the account.
///
/// Leaving a community and coming back is a new seat, so everything earned there starts again
/// from zero: impact and its seasoning, Trust Extension, completed obligations and the Phase
/// they feed, and activity. A scar and a pre-Default disqualification are the
/// person's, so they reach every community and survive a rejoin. The one exception
/// is the Trust Extension a scar wipes: that stays in the community where the scar happened.
///
/// These change who can borrow what: impact feeds the Line, Phase gates the caps, and the
/// account exposure cap sums impact and Trust Extension across communities. A cap
/// that still counts a forfeited seat's impact lends against impact that no longer exists.
contract ImpactTaxonomyTest is Test {
    Config config;
    MockCommunityFactory factory;
    CreditStandingHarness cc;
    MockSeatStamps communityA;
    MockSeatStamps communityB;

    address governance = makeAddr("governance");
    address attributor = makeAddr("impactAttributor");
    address ledger;
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");

    uint256 constant WAD = 1e18;
    uint256 constant EPOCH = 30 days;
    uint256 constant A = 0;
    uint256 constant B = 1;

    function setUp() public {
        MockUSDC usdc = new MockUSDC();
        config = new Config(address(usdc), makeAddr("treasury"), makeAddr("registry"));
        factory = new MockCommunityFactory();
        factory.setCommunityCount(2);
        communityA = new MockSeatStamps();
        communityB = new MockSeatStamps();
        factory.setCommunity(A, address(communityA));
        factory.setCommunity(B, address(communityB));
        cc = new CreditStandingHarness(IConfig(address(config)), address(factory), governance);
        ledger = address(new MockCreditCoreWiring(address(factory), address(config), address(cc)));
        vm.startPrank(governance);
        cc.setImpactAttributor(attributor);
        cc.setCreditCore(ledger);
        vm.stopPrank();
        vm.warp(1000 days);

        // Both members hold a seat in both communities from here on.
        communityA.join(alice);
        communityB.join(alice);
        communityA.join(bob);
    }

    function _accrue(uint256 c, address m, uint256 amount, bytes32 id) internal {
        vm.prank(attributor);
        cc.accrueImpact(c, m, amount, ICreditCore.ImpactSource.VaultYieldSpread, id, uint64(block.timestamp));
    }

    function _rejoin(MockSeatStamps community, address m) internal {
        community.forfeit(m);
        vm.warp(block.timestamp + 1 days);
        community.join(m);
    }

    // =============================================================================
    // Seat-held
    // =============================================================================

    /// Proof 1. Impact belongs to the seat: forfeiting and rejoining the same community is a new
    /// seat, so the impact the old one earned is gone and seasoning starts over. That includes a
    /// pending accrual whose epoch had already passed: it was the old seat's, so it never mints.
    function test_rejoin_impactIsZeroAndSeasoningRestarts() public {
        _accrue(A, alice, 100e6, "a-1");
        vm.warp(block.timestamp + EPOCH);
        cc.pokeSeasoning(A, alice);
        _accrue(A, alice, 40e6, "a-2"); // pending, and ripe by the time the member rejoins
        assertEq(cc.impactUnitsOf(A, alice), 100e6, "seasoned on the first seat");
        assertEq(cc.shareWad(A, alice), WAD, "the whole community share");

        vm.warp(block.timestamp + EPOCH);
        _rejoin(communityA, alice);

        assertEq(cc.impactUnitsOf(A, alice), 0, "the new seat has earned nothing");
        assertEq(cc.pendingImpactOf(A, alice), 0, "the old seat's pending accrual died with it");
        assertEq(cc.shareWad(A, alice), 0, "so it holds no share of the community");

        cc.pokeSeasoning(A, alice);
        assertEq(cc.impactUnitsOf(A, alice), 0, "a poke cannot mint the old seat's ripe accrual");
        assertEq(cc.communityImpactTotal(A), 100e6, "and U_C gains nothing from it either");

        _accrue(A, alice, 30e6, "a-3");
        vm.warp(block.timestamp + EPOCH - 1);
        cc.pokeSeasoning(A, alice);
        assertEq(cc.impactUnitsOf(A, alice), 0, "one second short of a full epoch: not seasoned");
        vm.warp(block.timestamp + 1);
        cc.pokeSeasoning(A, alice);
        assertEq(cc.impactUnitsOf(A, alice), 30e6, "a full epoch on the new seat");
    }

    /// Proof 2, the one that matters. The account exposure cap sums impact across
    /// communities. When the member forfeits B, B's impact is dead in that same transaction, and
    /// the cap and the Line in A computed straight afterwards use the smaller figure. Nothing
    /// touches B's storage in between: no poke, no accrual, no write of any kind. A cap that
    /// waited for one would lend against impact the member no longer has.
    function test_forfeit_accountTotalFallsAtOnceAndTheCapUsesIt() public {
        _accrue(A, alice, 100e6, "a-1");
        _accrue(B, alice, 400e6, "b-1");
        vm.warp(block.timestamp + EPOCH);
        cc.pokeSeasoning(A, alice);
        cc.pokeSeasoning(B, alice);

        // A deep community, and an Established history in A, so neither the budget, the
        // concentration limit, the phase cap nor the first-draw clamp binds before the exposure
        // cap does: 3 x (100e6 + 400e6) = 1,500e6 is the Line.
        cc.setCommunityLiquid(A, 1_000_000e6);
        cc.primeCompletedObligations(A, alice, 6, uint64(block.timestamp - 365 days));
        assertEq(cc.accountExposureCap(A, alice), 1_500e6, "cap on both seats' impact");
        (uint256 before,) = cc.line(A, alice);
        assertEq(before, 1_500e6, "the exposure cap is what binds the Line");

        communityB.forfeit(alice);

        assertEq(cc.accountExposureCap(A, alice), 300e6, "B's impact left the cap with the seat");
        (uint256 afterForfeit, bool eligible) = cc.line(A, alice);
        assertEq(afterForfeit, 300e6, "and the Line in A is sized on the reduced cap");
        assertTrue(eligible);

        // A write that observes the stale seat changes nothing about the cap: it was already right.
        cc.pokeSeasoning(B, alice);
        assertEq(cc.accountExposureCap(A, alice), 300e6);
    }

    /// Proof 7. Completed obligations and Phase belong to the seat. A returning member gets a
    /// first-access member's caps: the same Line as a member who has never drawn and holds the
    /// same impact, with the First Access clamp applying to both. The old seat's Trust Extension
    /// and dormant activity are gone as well, so the two are the same member in every figure.
    /// The seat stamp is the seat's **token id**, not its `mintedAt`, and this is the case that
    /// needs it. Every other test here forfeits and rejoins with time in between, so the two seats
    /// have different timestamps and either stamp resets correctly.
    ///
    /// The hole is when the old seat and the new one share a `mintedAt` to the second, which means
    /// the join, the write, the forfeit and the rejoin all land in one block. What survives then is
    /// a **pending** accrual: it was written under the old seat's stamp, the stamp still matches,
    /// so it seasons onto the new seat an epoch later. Impact the forfeited seat earned becomes
    /// impact the new one holds.
    ///
    /// Not theoretical: EIP-7702 batching, which the account already uses, puts all of it in one
    /// transaction. `tokenOf` comes from `nextTokenId++`, so the two seats differ by construction.
    function test_rejoinInTheSameBlock_isStillANewSeat() public {
        // Alice's seat in A was minted at setUp, in this same block. Accrue against it here, so
        // the stamp written now equals the `mintedAt` any seat minted in this block would have.
        _accrue(A, alice, 100e6, "same-block-1");
        assertEq(cc.pendingImpactOf(A, alice), 100e6, "pending on the first seat");

        uint256 t = block.timestamp;
        communityA.forfeit(alice);
        communityA.join(alice);
        assertEq(block.timestamp, t, "the point of this test: the two seats share a mintedAt");

        assertEq(cc.pendingImpactOf(A, alice), 0, "the old seat's pending accrual died with it");

        vm.warp(block.timestamp + EPOCH);
        cc.pokeSeasoning(A, alice);
        assertEq(cc.impactUnitsOf(A, alice), 0, "and it cannot season onto the new seat");
        assertEq(cc.shareWad(A, alice), 0, "so the new seat holds no share of the community");
    }

    function test_rejoin_obligationsAndPhaseReset_firstAccessCaps() public {
        cc.setCommunityLiquid(A, 100_000e6);
        cc.primeCompletedObligations(A, alice, 6, uint64(block.timestamp - 365 days));
        cc.primeCommunityAttributedYield(A, 100_000e6);
        cc.primeTeEarned(A, alice, 500e6);
        // Dormant well past grace plus the whole decay, so the old seat's activity is at the floor.
        cc.primeActivity(A, alice, uint64(block.timestamp - 400 days), WAD, uint64(block.timestamp - 400 days));
        assertEq(uint8(cc.phaseOf(A, alice)), uint8(ICreditCore.Phase.Established), "Established on the first seat");

        _rejoin(communityA, alice);

        (uint256 completed, uint256 teEarned,,) = cc.standingCountersOf(A, alice);
        assertEq(completed, 0, "no completed obligations on the new seat");
        assertEq(teEarned, 0, "no Trust Extension earned on the new seat");
        assertEq(uint8(cc.phaseOf(A, alice)), uint8(ICreditCore.Phase.FirstAccess), "back to First Access");
        assertEq(cc.activityFactor(A, alice), WAD, "the old seat's dormancy is not the new seat's");

        // Alice (returning) and Bob (never drawn) earn the same impact at the same moment.
        _accrue(A, alice, 200e6, "a-alice");
        _accrue(A, bob, 200e6, "a-bob");
        vm.warp(block.timestamp + EPOCH);
        cc.pokeSeasoning(A, alice);
        cc.pokeSeasoning(A, bob);

        (uint256 aliceLine, bool aliceEligible) = cc.line(A, alice);
        (uint256 bobLine,) = cc.line(A, bob);
        assertEq(aliceLine, bobLine, "a returning member's Line is a first-access member's Line");
        assertEq(aliceLine, config.minLendable(), "the first-draw clamp binds, at MIN_LENDABLE");
        assertTrue(aliceEligible);

        // The same after writes have landed on the new seat, not only before.
        (completed, teEarned,,) = cc.standingCountersOf(A, alice);
        assertEq(completed, 0, "the old count did not carry onto the new seat");
        assertEq(teEarned, 0, "nor the old Trust Extension");
        assertEq(cc.accountExposureCap(A, alice), cc.accountExposureCap(A, bob), "the same exposure cap");
        assertEq(cc.activityFactor(A, alice), cc.activityFactor(A, bob), "the old seat's dormancy is gone");
    }

    /// Proof 7, continued. The first obligation completed on a new seat is the first, and it
    /// starts the Phase clock again: one completion a moment ago is First Access, not the
    /// Proven Once the old seat's year-old anchor would give.
    function test_rejoin_firstCompletionOnTheNewSeatStartsThePhaseClock() public {
        cc.primeCompletedObligations(A, alice, 6, uint64(block.timestamp - 365 days));
        _rejoin(communityA, alice);

        vm.prank(ledger);
        cc.creditObligationCompletion(A, alice, 0);

        (uint256 completed,,,) = cc.standingCountersOf(A, alice);
        assertEq(completed, 1, "counted on the new seat");
        assertEq(uint8(cc.phaseOf(A, alice)), uint8(ICreditCore.Phase.FirstAccess), "anchored now, not a year ago");
    }

    /// Impact reported for a member with no seat counts nowhere: not in the community, not in
    /// the account cap, and not on a seat taken later. Seat-held means there must be a seat.
    function test_impactAccruedWithoutASeat_countsNowhere() public {
        _accrue(A, alice, 100e6, "a-1");
        vm.warp(block.timestamp + EPOCH);
        cc.pokeSeasoning(A, alice);
        communityB.forfeit(alice);

        _accrue(B, alice, 400e6, "b-after-forfeit");
        vm.warp(block.timestamp + EPOCH);
        cc.pokeSeasoning(B, alice);

        assertEq(cc.impactUnitsOf(B, alice), 0, "no seat in B, so no impact in B");
        assertEq(cc.accountExposureCap(A, alice), 300e6, "and none in the account cap: 3 x A's 100e6");

        communityB.join(alice);
        assertEq(cc.impactUnitsOf(B, alice), 0, "nor on the seat taken afterwards");
        assertEq(cc.accountExposureCap(A, alice), 300e6);
    }

    // =============================================================================
    // Account-held
    // =============================================================================

    /// Proof 3. A scar recorded in A reduces conduct in B, for a member in both.
    function test_scarInA_reducesConductInB() public {
        uint256 frozen = 400_000_000_000_000_000;
        vm.prank(ledger);
        cc.recordScar(A, alice, frozen);

        assertEq(cc.conductFactor(A, alice), frozen, "where it was recorded");
        assertEq(cc.conductFactor(B, alice), frozen, "and in the other community");
    }

    /// Proof 4. The scar heals in both communities on the one schedule: 90 days, linearly, from
    /// the moment of cure. An account-wide scar is a fading penalty, not a mark.
    function test_scarHealsInBothOnTheSameSchedule() public {
        uint256 frozen = 400_000_000_000_000_000;
        vm.prank(ledger);
        cc.recordScar(A, alice, frozen);

        vm.warp(block.timestamp + 45 days);
        // 0.4 + (1.0 - 0.4) x 45/90 = 0.7
        assertEq(cc.conductFactor(A, alice), 700_000_000_000_000_000);
        assertEq(cc.conductFactor(B, alice), 700_000_000_000_000_000);

        vm.warp(block.timestamp + 45 days);
        assertEq(cc.conductFactor(A, alice), WAD, "healed where it was recorded");
        assertEq(cc.conductFactor(B, alice), WAD, "healed in the other community at the same moment");
    }

    /// Proof 5. The conduct penalty travels, the Trust Extension wipe does not: a
    /// scar in A zeroes A's te_earned and leaves B's exactly as it was, and once the scar has
    /// healed B's Trust Extension is available again in full.
    function test_scarZeroesTeEarnedInAOnly() public {
        cc.primeCompletedObligations(A, alice, 3, uint64(block.timestamp - 1 days));
        cc.primeCompletedObligations(B, alice, 3, uint64(block.timestamp - 1 days));
        cc.primeCommunityAttributedYield(B, 100_000e6);
        cc.primeTeEarned(A, alice, 300e6);
        cc.primeTeEarned(B, alice, 500e6);

        vm.prank(ledger);
        cc.recordScar(A, alice, 500_000_000_000_000_000);

        (, uint256 teA,,) = cc.standingCountersOf(A, alice);
        (, uint256 teB,,) = cc.standingCountersOf(B, alice);
        assertEq(teA, 0, "wiped where the scar happened");
        assertEq(teB, 500e6, "untouched where nothing went wrong");
        // `_anyUnhealedScar` is the account's now, so while the scar heals
        // B's Trust Extension is held back, not taken: the stored figure above is unchanged.
        assertEq(cc.trustExtension(B, alice), 0, "held back in B while the scar heals");

        vm.warp(block.timestamp + config.standingHealWindow());
        (, teB,,) = cc.standingCountersOf(B, alice);
        assertEq(teB, 500e6, "still there once the scar has healed");
        assertEq(cc.trustExtension(B, alice), 500e6, "and available again in B");
    }

    /// Proof 6. A pre-Default disqualification is the account's. Set by a formal Default in A,
    /// it survives forfeiting and rejoining A, and reads the same from B.
    function test_preDefaultDisqualified_survivesRejoin() public {
        vm.prank(ledger);
        cc.recordFormalDefault(A, alice);
        (,,, bool disqA) = cc.standingCountersOf(A, alice);
        assertTrue(disqA, "set where the Default happened");

        _rejoin(communityA, alice);

        (,,, disqA) = cc.standingCountersOf(A, alice);
        (,,, bool disqB) = cc.standingCountersOf(B, alice);
        assertTrue(disqA, "a new seat does not clear it");
        assertTrue(disqB, "and it is the account's, so B reads it too");
        (uint256 drawable, bool eligible) = cc.line(A, alice);
        assertEq(drawable, 0);
        assertFalse(eligible);
    }
}
