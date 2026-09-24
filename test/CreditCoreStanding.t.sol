// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {Ownable} from "openzeppelin-contracts/contracts/access/Ownable.sol";
import {CreditCore} from "../src/CreditCore.sol";
import {ICreditCore} from "../src/interfaces/ICreditCore.sol";
import {ICreditStanding} from "../src/interfaces/ICreditStanding.sol";
import {Config} from "../src/Config.sol";
import {ConfigKeys as K} from "../src/ConfigKeys.sol";
import {IConfig} from "../src/interfaces/IConfig.sol";
import {MockUSDC} from "./mocks/MockUSDC.sol";
import {CreditCoreHarness} from "./helpers/CreditCoreHarness.sol";
import {CreditStandingHarness} from "./helpers/CreditStandingHarness.sol";
import {MockCommunityFactory} from "./helpers/MockCommunityFactory.sol";
import {MockCreditCoreWiring} from "./helpers/MockCreditCoreWiring.sol";

/// Standing, on `CreditStanding`: Impact Units and seasoning, the
/// relational share, conduct decay and scars, activity decay, phases, Trust
/// Extension, and the Line view. Every expected value is derived from the design, not from what
/// the code produced.
///
/// The subject is `CreditStandingHarness` directly, not a wired `CreditCore` pair: every test
/// here exercises Standing's own formulas and state, none of it needs a real Treasury or debt
/// ledger, and `CreditStanding` contains no call to `CreditCore` to route through in the first
/// place. `ledger` plays the `onlyCreditCore`-gated caller the way `obligationLedger` did before
/// the split: `setCreditCore(ledger)` wires an arbitrary mock address, once, in `setUp`, and
/// `test_excludedSources_mintZero` is the one exception (see its own comment) since it is the
/// one pre-split test that exercised a real Treasury path.
///
/// Fixed-point precision: the two multipliers and `share_i` are 1e18 WAD; USDC stays
/// 6-decimal. Every Line-sizing division floors.
contract CreditCoreStandingTest is Test {
    Config config;
    MockCommunityFactory factory;
    CreditStandingHarness cc;

    address governance = makeAddr("governance");
    address attributor = makeAddr("impactAttributor");
    address ledger;
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");

    uint256 constant WAD = 1e18;
    uint256 constant EPOCH = 30 days;
    uint256 constant C = 0; // the one community these tests use
    uint256 constant SCAR_QUEUE_MAX = 64;

    function setUp() public {
        MockUSDC usdc = new MockUSDC();
        config = new Config(address(usdc), makeAddr("treasury"), makeAddr("registry"));
        factory = new MockCommunityFactory();
        factory.setCommunityCount(2);
        cc = new CreditStandingHarness(IConfig(address(config)), address(factory), governance);
        // `obligationLedger` is retired in favor of `creditCore`, wired once via
        // `setCreditCore`. A mock contract plays the role here exactly as `obligationLedger` did
        // pre-split: this test file needs a gated caller to prank as, not a real `CreditCore`.
        // It must be a contract exposing `factory()`/`config()` matching `cc`'s own, not a bare
        // EOA address, because `setCreditCore` calls and checks both.
        ledger = address(new MockCreditCoreWiring(address(factory), address(config), address(cc)));
        vm.startPrank(governance);
        cc.setImpactAttributor(attributor);
        cc.setCreditCore(ledger);
        vm.stopPrank();
        vm.warp(1000 days); // a non-trivial base timestamp so "long ago" subtractions do not underflow
    }

    function _accrue(address m, uint256 amount, bytes32 id) internal {
        vm.prank(attributor);
        cc.accrueImpact(C, m, amount, ICreditCore.ImpactSource.VaultYieldSpread, id, uint64(block.timestamp));
    }

    function _accrueSeasoned(address m, uint256 amount, bytes32 id) internal {
        _accrue(m, amount, id);
        vm.warp(block.timestamp + EPOCH);
        cc.pokeSeasoning(C, m);
    }

    // =============================================================================
    // Impact Units
    // =============================================================================

    /// Test 1: each qualifying source mints; every excluded kind of addition mints
    /// zero. The only Impact entry point is `accrueImpact`, gated to the attributor and
    /// accepting only the two `ImpactSource` values.
    function test_qualifyingSourcesMint_seatFeeAndSpread() public {
        _accrueSeasoned(alice, 100e6, "seat-1");
        assertEq(cc.impactUnitsOf(C, alice), 100e6);

        vm.prank(attributor);
        cc.accrueImpact(
            C, bob, 40e6, ICreditCore.ImpactSource.SeatFeeCommunityPortion, "spread-1", uint64(block.timestamp)
        );
        vm.warp(block.timestamp + EPOCH);
        cc.pokeSeasoning(C, bob);
        assertEq(cc.impactUnitsOf(C, bob), 40e6);
    }

    function test_impactSourceEnumIsExactlyTwo() public pure {
        // A future task that adds an ImpactSource value changes this count and must re-justify
        // it against the Impact rule (only the seat-fee Community portion and seasoned realized
        // vault yield spread qualify).
        assertEq(uint256(type(ICreditCore.ImpactSource).max), 1);
    }

    /// Test 1 continued: the excluded rows. None of these reaches `accrueImpact`. Unlike the
    /// pre-split test, the Qudi Growth/Stabilization Allocation row and the raw-Treasury-inflow
    /// row are proved against a real, separately wired `CreditCore` + `CreditStanding` pair
    /// (`CreditStanding` contains no call to `CreditCore`, so there is no path from
    /// `fund`/`allocate` to `accrueImpact` for this test to exercise on the shared `cc` fixture
    /// above; a fresh pair demonstrates the same absence against a real Treasury instead of
    /// asserting it by construction alone).
    function test_excludedSources_mintZero() public {
        MockUSDC usdc2 = new MockUSDC();
        Config config2 = new Config(address(usdc2), makeAddr("treasury2"), makeAddr("registry2"));
        MockCommunityFactory factory2 = new MockCommunityFactory();
        factory2.setCommunityCount(2);
        CreditStandingHarness standing2 =
            new CreditStandingHarness(IConfig(address(config2)), address(factory2), governance);
        CreditCoreHarness cc2 = new CreditCoreHarness(
            IERC20(address(usdc2)),
            IConfig(address(config2)),
            address(factory2),
            governance,
            makeAddr("tm2"),
            makeAddr("ms2"),
            standing2
        );
        vm.prank(governance);
        standing2.setCreditCore(address(cc2));

        uint256 ucBefore = standing2.communityImpactTotal(C);

        // Row: Qudi Growth / Stabilization Allocations. `allocate` mints nothing.
        usdc2.mint(governance, 500_000e6);
        vm.startPrank(governance);
        usdc2.approve(address(cc2), 500_000e6);
        cc2.fund(500_000e6); // Row: no member-attributable value from a raw Treasury inflow
        vm.stopPrank();
        vm.prank(makeAddr("ms2"));
        cc2.allocate(C, 200_000e6, ICreditCore.AllocationType.Growth);
        vm.prank(makeAddr("ms2"));
        cc2.allocate(1, 100_000e6, ICreditCore.AllocationType.Stabilization);
        assertEq(standing2.communityImpactTotal(C), ucBefore);
        assertEq(standing2.impactUnitsOf(C, alice), 0);

        // Row: reversed or invalidated source events. A re-sent report mints once (test 4);
        // a report that is never re-sent (invalidated) never mints.
        vm.prank(attributor);
        cc.accrueImpact(C, alice, 0, ICreditCore.ImpactSource.VaultYieldSpread, "invalidated", uint64(block.timestamp));
        vm.warp(block.timestamp + EPOCH);
        cc.pokeSeasoning(C, alice);
        assertEq(cc.impactUnitsOf(C, alice), 0);

        // Rows with no CreditCore path at all: vault principal, temporary balances, internal
        // transfers, shareout claims, campaign rewards, community-level funding yield,
        // unrealized yield, principal repayments. `accrueImpact` is `onlyImpactAttributor`, so
        // no member-money path can reach it.
        vm.prank(alice);
        vm.expectRevert(ICreditStanding.NotImpactAttributor.selector);
        cc.accrueImpact(C, alice, 100e6, ICreditCore.ImpactSource.VaultYieldSpread, "x", uint64(block.timestamp));
    }

    /// Test 2: one-epoch seasoning, half-open in seconds.
    function test_seasoning_oneEpochHalfOpen() public {
        uint64 t0 = uint64(block.timestamp);
        _accrue(alice, 100e6, "s");

        vm.warp(t0 + EPOCH - 1);
        cc.pokeSeasoning(C, alice);
        assertEq(cc.impactUnitsOf(C, alice), 0, "not seasoned one second early");

        vm.warp(t0 + EPOCH);
        cc.pokeSeasoning(C, alice);
        assertEq(cc.impactUnitsOf(C, alice), 100e6, "seasoned at exactly one epoch");
        assertEq(cc.communityImpactTotal(C), 100e6);
    }

    /// Test 3: a same-block deposit and withdrawal nets to zero attributed spread, so it
    /// mints zero.
    function test_sameBlockDepositWithdraw_mintsZero() public {
        vm.prank(attributor);
        cc.accrueImpact(C, alice, 0, ICreditCore.ImpactSource.VaultYieldSpread, "same-block", uint64(block.timestamp));
        assertEq(cc.pendingImpactOf(C, alice), 0);
        vm.warp(block.timestamp + 2 * EPOCH);
        cc.pokeSeasoning(C, alice);
        assertEq(cc.impactUnitsOf(C, alice), 0);
    }

    /// Test 4: idempotent by source event.
    function test_idempotentBySourceEvent() public {
        _accrue(alice, 100e6, "dup");
        _accrue(alice, 100e6, "dup"); // same id: no-op
        vm.warp(block.timestamp + EPOCH);
        cc.pokeSeasoning(C, alice);
        assertEq(cc.impactUnitsOf(C, alice), 100e6);
    }

    /// Test 5: historical Units survive a member leaving, and U_C does not fall. CreditCore
    /// never removes a Unit; the closest thing to "leaving" is a Default disqualification,
    /// which keeps the Units in the denominator.
    function test_historicalUnitsSurvive() public {
        _accrueSeasoned(alice, 100e6, "h1");
        _accrueSeasoned(bob, 300e6, "h2");
        assertEq(cc.communityImpactTotal(C), 400e6);

        // `disqualifyPreDefaultUnits` is deleted as an external entry point;
        // `recordFormalDefault` is the only production path left that disqualifies pre-Default
        // Units (through the internal `_disqualifyPreDefaultUnits` it calls). It also sets the
        // account-wide `_accountDefaulted` floor, which does not change any assertion below:
        // `line()` already returns `(0, false)` on either flag alone.
        vm.prank(ledger);
        cc.recordFormalDefault(C, alice);

        assertEq(cc.impactUnitsOf(C, alice), 100e6, "U_i stays in the denominator");
        assertEq(cc.communityImpactTotal(C), 400e6, "U_C does not fall");
        (uint256 d, bool elig) = cc.line(C, alice);
        assertEq(d, 0);
        assertFalse(elig);
    }

    /// `line()`'s own account-default disqualification guard,
    /// long present and untested until now. `test_historicalUnitsSurvive` above also
    /// asserts a defaulted account's Line is zero, but its fixture has `te_earned == 0`, so
    /// `_conductFactor`'s account-wide zero floor already drives `drawable` to zero regardless of
    /// whether `line()`'s own guard runs: it passes for a reason other than the one it names.
    /// This fixture gives the account a live `te_earned` and community Trust Extension budget
    /// with no open delinquency and no unhealed scar, so `_trustExtension` alone is non-zero
    /// after the default (`_conductFactor`'s floor only ever zeroes `base`, never `_trustExtension`
    /// added on top of it), and only the guard itself can drive `drawable` to zero.
    /// The account-wide half of the guard,
    /// `|| _accountDefaulted[member]`, is untested if this test asserts only in the community
    /// the default was recorded in, since `_preDefaultDisqualified[C]` alone already zeroes the
    /// Line there. The name says "everywhere", so the assertions also cover a
    /// second community, `D`, where no default was recorded, which is the whole content of
    /// the account-wide consequence.
    function test_defaultedAccountLineIsZeroEverywhere() public {
        uint256 D = 1; // the second community the harness allows

        cc.primeCompletedObligations(C, alice, 3, uint64(block.timestamp - 200 days)); // Developing
        cc.primeTeEarned(C, alice, 600e6);
        cc.primeCommunityAttributedYield(C, 500_000e6);
        cc.setCommunityLiquid(C, 2_050e6 + 100_000e6);

        cc.primeCompletedObligations(D, alice, 3, uint64(block.timestamp - 200 days));
        cc.primeTeEarned(D, alice, 600e6);
        cc.primeCommunityAttributedYield(D, 500_000e6);
        cc.setCommunityLiquid(D, 2_050e6 + 100_000e6);

        (uint256 before_, bool eligibleBefore) = cc.line(C, alice);
        assertGt(before_, 0, "fixture must have a non-zero Line before the default");
        assertTrue(eligibleBefore, "fixture must be eligible before the default");

        (uint256 beforeOther, bool eligibleBeforeOther) = cc.line(D, alice);
        assertGt(beforeOther, 0, "fixture must have a non-zero Line in the other community too");
        assertTrue(eligibleBeforeOther, "fixture must be eligible in the other community too");

        // Formal Default recorded in C only.
        vm.prank(ledger);
        cc.recordFormalDefault(C, alice);

        (uint256 drawable, bool eligible) = cc.line(C, alice);
        assertEq(drawable, 0, "a defaulted account's Line is zero in the community of default");
        assertFalse(eligible, "a defaulted account is not eligible in the community of default");

        (uint256 drawableOther, bool eligibleOther) = cc.line(D, alice);
        assertEq(drawableOther, 0, "default disqualifies the account in every community");
        assertFalse(eligibleOther, "a defaulted account is ineligible everywhere");
    }

    // =============================================================================
    // conduct_factor
    // =============================================================================

    /// Test 6: the four conduct-decay worked values, exact at 1e18. Span is
    /// defaultRecoveryStart - lateStart = 155d - 65d = 90d, from the stage boundaries. The
    /// multiplier floors, so 0.67 is 666...666 and 0.33 is 333...333; both match
    /// the design's two-decimal 0.67 and 0.33.
    function test_conductDecay_workedValues() public view {
        assertEq(cc.conductDecayAt(65 days), WAD); // day 65 = 1.00
        assertEq(cc.conductDecayAt(95 days), 666_666_666_666_666_666); // day 95 ~ 0.67, floored
        assertEq(cc.conductDecayAt(125 days), 333_333_333_333_333_333); // day 125 ~ 0.33, floored
        assertEq(cc.conductDecayAt(155 days), 0); // day 155 = 0.00
        assertEq(cc.conductDecayAt(64 days), WAD); // still 1.0 the second before Late
        assertEq(cc.conductDecayAt(200 days), 0); // 0 past formal Default
    }

    /// Test 7: conduct does not vary with the unpaid principal ratio. The guarantee is
    /// structural: `conductDecayAt` takes elapsed time and nothing else, and `conductFactor`
    /// reads only scars, the open-delinquency seam and time. The value at day 95 is
    /// `1 - (95 - 65) / 90 = 2/3`, floored to 1e18 (the multiplier floors), not a
    /// number read back from the function under test.
    function test_conduct_independentOfUnpaidRatio() public view {
        // Computed by hand: 2/3 * 1e18 = 666666666666666666.666..., floor -> ...666.
        assertEq(cc.conductDecayAt(95 days), 666_666_666_666_666_666);
    }

    /// Test 8: a scar freezes at the decayed value and heals linearly to 1.0 over 90 days.
    function test_scar_freezeAndHeal() public {
        uint256 frozen = 670_000_000_000_000_000; // 0.67 WAD, e.g. a cure at day 95
        vm.prank(ledger);
        cc.recordScar(C, alice, frozen);

        assertEq(cc.conductFactor(C, alice), frozen, "freezes at the decayed value");

        vm.warp(block.timestamp + 45 days); // halfway through the 90-day heal
        // 0.67 + (1.0 - 0.67) * 45/90 = 0.67 + 0.165 = 0.835
        assertEq(cc.conductFactor(C, alice), 835_000_000_000_000_000);

        vm.warp(block.timestamp + 45 days); // 90 days total
        assertEq(cc.conductFactor(C, alice), WAD, "fully healed");
    }

    /// Test 9: two scars combine deepest-wins, and their heal windows do not stack.
    function test_scars_deepestWinsNoStacking() public {
        vm.prank(ledger);
        cc.recordScar(C, alice, 800_000_000_000_000_000); // scar A, 0.80

        vm.warp(block.timestamp + 30 days);
        vm.prank(ledger);
        cc.recordScar(C, alice, 500_000_000_000_000_000); // scar B, 0.50

        // scar A: 30/90 healed -> 0.80 + 0.20 * 30/90 = 0.8666...; scar B: 0/90 -> 0.50.
        assertEq(cc.conductFactor(C, alice), 500_000_000_000_000_000, "deepest (scar B) wins");

        // 90 more days: scar B's own window closes; scar A closed 30 days earlier. Neither
        // window was extended by the other.
        vm.warp(block.timestamp + 90 days);
        assertEq(cc.conductFactor(C, alice), WAD);
    }

    /// Scars are deepest-wins, not last-wins. `test_scars_deepestWinsNoStacking` records the
    /// deeper scar last, so last-wins gives the same answer and cannot distinguish the rule it
    /// is named after. This records the deep scar FIRST and the shallower
    /// one SECOND, in one block so neither has healed, so deepest-wins and last-wins diverge.
    function test_scars_deepestWinsNotLastWins() public {
        vm.prank(ledger);
        cc.recordScar(C, alice, 500_000_000_000_000_000); // deep scar recorded FIRST, 0.50

        vm.prank(ledger);
        cc.recordScar(C, alice, 800_000_000_000_000_000); // shallower scar recorded SECOND, 0.80

        assertEq(
            cc.conductFactor(C, alice), 500_000_000_000_000_000, "deepest-wins: record order must not change the answer"
        );
    }

    /// Test 10: past day 155 the scar mechanism does not apply. An open delinquency at day 160
    /// drives conduct to 0 through the decay, and the min with a still-healing scar is 0.
    function test_pastFormalDefault_scarDoesNotApply() public {
        vm.prank(ledger);
        cc.recordScar(C, alice, 700_000_000_000_000_000); // a scar that would otherwise heal

        cc.setOpenDelinquencyConduct(C, alice, 160 days); // conductDecayAt(160 days) == 0
        assertEq(cc.conductFactor(C, alice), 0);
    }

    /// `_recordScar`'s `ScarDropped` path
    /// used to return above the Trust Extension zeroing, so a member whose scar was
    /// dropped (the queue full of unhealed scars) kept the `te_earned` a scar is supposed to
    /// zero. The fix moves the zeroing above the queue-full check, since the scar event happened
    /// whether or not the list had room to record it. Both branches tested: the recorded scar
    /// zeroes TE as it did before, and the dropped scar now zeroes it too.
    function test_recordScar_bothBranchesZeroTrustExtension() public {
        // Branch 1: recorded (room in the queue).
        cc.primeCompletedObligations(C, alice, 3, uint64(block.timestamp - 1 days));
        cc.primeCommunityAttributedYield(C, 100_000e6);
        cc.primeTeEarned(C, alice, 600e6);
        assertEq(cc.trustExtension(C, alice), 600e6, "TE available before any scar");

        vm.prank(ledger);
        cc.recordScar(C, alice, 500_000_000_000_000_000);
        (, uint256 earnedAfterRecorded,,) = cc.standingCountersOf(C, alice);
        assertEq(earnedAfterRecorded, 0, "recorded scar zeroes te_earned");

        // Branch 2: dropped. Fill bob's queue with fresh, unhealed scars so the next one has
        // nowhere to go, then prime te_earned directly (bypassing the formula) so the assertion
        // below can only pass if the drop itself, not some other path, zeroed it.
        for (uint256 i; i < SCAR_QUEUE_MAX; i++) {
            vm.prank(ledger);
            cc.recordScar(C, bob, 5e17);
        }
        cc.primeTeEarned(C, bob, 700e6);
        (, uint256 teBeforeDrop,,) = cc.standingCountersOf(C, bob);
        assertEq(teBeforeDrop, 700e6, "primed value, not yet touched by the next scar attempt");

        vm.expectEmit(true, true, true, true, address(cc));
        emit ICreditStanding.ScarDropped(C, bob, 5e17);
        vm.prank(ledger);
        cc.recordScar(C, bob, 5e17); // the 65th unhealed scar for bob: queue full, dropped

        (, uint256 teAfterDropped,,) = cc.standingCountersOf(C, bob);
        assertEq(teAfterDropped, 0, "a dropped scar still zeroes te_earned");
    }

    // =============================================================================
    // activity_factor
    // =============================================================================

    /// Test 11: the three regions and both boundaries from both sides, in seconds. Set the
    /// heal track fully healed so activity_factor == the dormancy decay of d.
    function test_activityDecay_threeRegionsAndBoundaries() public {
        uint256 floorW = 250_000_000_000_000_000; // ACTIVITY_FLOOR_BPS 2500 -> 0.25 WAD
        uint64 grace = 90 days;
        uint64 w = 180 days;

        _primeHealed(alice, grace); // d = grace exactly
        assertEq(cc.activityFactor(C, alice), WAD, "d == GRACE: still 1.0");

        _primeHealed(alice, grace + 1);
        assertLt(cc.activityFactor(C, alice), WAD, "one second past GRACE: below 1.0");

        _primeHealed(alice, grace + 90 days); // halfway through the 180-day decay
        // 1.0 - (1.0 - 0.25) * 90d/180d = 1.0 - 0.375 = 0.625
        assertEq(cc.activityFactor(C, alice), 625_000_000_000_000_000);

        _primeHealed(alice, grace + w - 1);
        assertGt(cc.activityFactor(C, alice), floorW, "one second before the floor: above FLOOR");

        _primeHealed(alice, grace + w); // d == GRACE + W
        assertEq(cc.activityFactor(C, alice), floorW, "at GRACE + W: exactly FLOOR");

        _primeHealed(alice, grace + w + 365 days);
        assertEq(cc.activityFactor(C, alice), floorW, "well past: still FLOOR, never below");
    }

    function _primeHealed(address m, uint256 dormantFor) internal {
        uint64 t = uint64(block.timestamp - dormantFor);
        // heal track anchored at 1.0 long ago, so heal ramp reads 1.0 and decay of d governs.
        cc.primeActivity(C, m, t, WAD, t);
    }

    /// Test 12: healing does not reset on contact. A token activity after long dormancy gives
    /// a value below 1.0 and reaches 1.0 only after 90 days of continued good standing.
    function test_activityHealing_doesNotResetOnContact() public {
        uint256 floorW = 250_000_000_000_000_000;
        // deeply dormant, sitting at the floor
        uint64 old = uint64(block.timestamp - 400 days);
        cc.primeActivity(C, alice, old, floorW, old);
        assertEq(cc.activityFactor(C, alice), floorW);

        cc.pokeActivity(C, alice); // a qualifying activity
        assertEq(cc.activityFactor(C, alice), floorW, "does not snap to 1.0 on contact");

        vm.warp(block.timestamp + 45 days);
        // heal ramp: 0.25 + 0.75 * 45/90 = 0.625; decay side is 1.0 (within GRACE). min = 0.625
        assertEq(cc.activityFactor(C, alice), 625_000_000_000_000_000);

        vm.warp(block.timestamp + 45 days); // 90 days of good standing
        assertEq(cc.activityFactor(C, alice), WAD, "reaches 1.0 only after 90 days");
    }

    /// Test 13: a member whose quiet vault balance is earning attributed spread is active.
    /// A spread accrual is qualifying activity.
    function test_quietVaultBalance_isActive() public {
        uint256 floorW = 250_000_000_000_000_000;
        uint64 old = uint64(block.timestamp - 400 days);
        cc.primeActivity(C, alice, old, floorW, old);

        _accrue(alice, 5e6, "spread"); // the harvest attributes some spread to alice
        assertEq(cc.activityFactor(C, alice), floorW, "activity re-anchored, heal begun");

        vm.warp(block.timestamp + 90 days);
        assertEq(cc.activityFactor(C, alice), WAD);
    }

    // Test 14 (FLOOR rejects zero) is a Config bounds test: see test/Config.t.sol
    // test_standingBoundsRejectZero.

    // =============================================================================
    // Trust Extension
    // =============================================================================

    /// Test 15: TrustExtension = min(phase_budget, te_earned), at values where each side binds.
    function test_trustExtension_eachSideBinds() public {
        // Developing (2-5 completed, no min time). Phase budget $700.
        cc.primeCompletedObligations(C, alice, 3, uint64(block.timestamp - 1 days));
        cc.primeCommunityAttributedYield(C, 100_000e6); // large: the community cap does not bind

        cc.primeTeEarned(C, alice, 600e6);
        assertEq(cc.trustExtension(C, alice), 600e6, "te_earned binds");

        cc.primeTeEarned(C, alice, 900e6);
        assertEq(cc.trustExtension(C, alice), 700e6, "phase budget binds");
    }

    /// Test 16: a scar zeroes te_earned, phase is unchanged, and after healing it accumulates
    /// from zero rather than snapping back.
    function test_trustExtension_scarZeroesEarnedPhaseUnchanged() public {
        cc.primeCompletedObligations(C, alice, 6, uint64(block.timestamp - 200 days)); // Established
        cc.primeCommunityAttributedYield(C, 1_000_000e6);
        cc.primeTeEarned(C, alice, 150e6);
        assertEq(uint256(cc.phaseOf(C, alice)), uint256(ICreditCore.Phase.Established));
        assertEq(cc.trustExtension(C, alice), 150e6);

        vm.prank(ledger);
        cc.recordScar(C, alice, 500_000_000_000_000_000);
        (,, uint256 earned,) = _counters(alice);
        assertEq(earned, 0, "scar zeroed te_earned");
        assertEq(uint256(cc.phaseOf(C, alice)), uint256(ICreditCore.Phase.Established), "phase unchanged");
        assertEq(cc.trustExtension(C, alice), 0, "unavailable while the scar heals");

        // an accrual during the heal is dropped
        vm.prank(ledger);
        cc.creditObligationCompletion(C, alice, 100e6);
        (,, earned,) = _counters(alice);
        assertEq(earned, 0);

        vm.warp(block.timestamp + 90 days); // scar heals
        assertEq(cc.trustExtension(C, alice), 0, "does not snap back to 150");

        vm.prank(ledger);
        cc.creditObligationCompletion(C, alice, 50e6);
        (,, earned,) = _counters(alice);
        assertEq(earned, 50e6, "accumulates from zero");
        assertEq(cc.trustExtension(C, alice), 50e6);
    }

    /// Test 17: the community cap binds when it is the smaller term:
    /// min(sum of phase budgets, TE_COMMUNITY_CAP_BPS x cumulative attributed funding yield).
    function test_trustExtension_communityCapBinds() public {
        cc.primeCompletedObligations(C, alice, 3, uint64(block.timestamp - 1 days)); // Developing, budget 700
        cc.primeTeEarned(C, alice, 600e6); // member cap would be min(700, 600) = 600
        cc.primeCommunityAttributedYield(C, 1000e6); // 20% x 1000 = 200
        assertEq(cc.trustExtension(C, alice), 200e6, "community yield cap binds");
    }

    function _counters(address m) internal view returns (uint256 completed, uint256, uint256 teEarned, bool disq) {
        (completed, teEarned,, disq) = cc.standingCountersOf(C, m);
    }

    // =============================================================================
    // The Line
    // =============================================================================

    /// Test 18: each of the six `drawable` terms binds in at least one named case.
    /// The `max(0, CommunityImpactBudget)` term shares its base with CommunityConcentrationCap
    /// (both are `liquid - buffer - MIN_LENDABLE`), and concentration is 5-12% of that, so for
    /// any in-range concentration bps the budget term is dominated and never uniquely binds.
    /// Recorded as an open question; the term stays in the code because the design lists it.
    function test_line_eachTermBinds() public {
        // Common frame: fully active, no conduct scar, first-Line cap disabled.
        cc.setHasEverDrawn(C, alice, true);

        // (a) ImpactBase + TrustExtension binds. Tiny share, big budget, small everything-else
        // is avoided by giving a large exposure cap (large U_i).
        cc.primeImpact(C, alice, 10e6, 10_000e6); // share = 0.001
        cc.setCommunityLiquid(C, 1_000_000e6); // budget = 1_000_000e6 - 2000e6 - 50e6
        // ImpactBase = budget * 0.001 = ~997_950e3 ... too big vs other caps. Shrink budget.
        cc.setCommunityLiquid(C, 12_050e6); // budget = 10_000e6
        // ImpactBase = 10_000e6 * (10e6/10_000e6) = 10e6. TE = 0 (FirstAccess).
        // exposureCap = min(3 * 10e6, 5000e6) = 30e6; concentration = 5% * 10_000e6 = 500e6;
        // phaseCap FirstAccess = 100e6; global 5000e6; budget 10_000e6.
        (uint256 d,) = cc.line(C, alice);
        assertEq(d, 10e6, "(a) ImpactBase + TrustExtension binds at 10e6");

        // (b) AccountExposureCap binds. Big share so ImpactBase is large, small U_i so
        // 3 x U_i is the smallest.
        cc.primeImpact(C, bob, 5e6, 10e6); // share 0.5, U_i 5e6 -> exposureCap 15e6
        cc.setHasEverDrawn(C, bob, true);
        cc.setCommunityLiquid(C, 2_050e6 + 2_000e6); // budget 2_000e6
        // ImpactBase = 2_000e6 * 0.5 = 1_000e6; concentration 5% * 2_000e6 = 100e6;
        // phaseCap 100e6; exposureCap min(3*5e6,5000e6)=15e6. min => 15e6.
        (d,) = cc.line(C, bob);
        assertEq(d, 15e6, "(b) AccountExposureCap binds at 15e6");

        // (c) CommunityConcentrationCap binds. Large exposure cap and ImpactBase, moderate
        // budget; 5% of budget is the smallest.
        cc.primeImpact(C, alice, 2_000e6, 2_000e6); // share 1.0, exposureCap min(6000e6,5000e6)=5000e6
        cc.setCommunityLiquid(C, 2_050e6 + 1_000e6); // budget 1_000e6
        // ImpactBase = 1_000e6; concentration 5% * 1_000e6 = 50e6; phaseCap 100e6; budget 1_000e6.
        (d,) = cc.line(C, alice);
        assertEq(d, 50e6, "(c) CommunityConcentrationCap binds at 50e6");

        // (d) PhaseCap binds. Developing phase (cap 1_000e6), big budget, concentration 10%.
        cc.primeCompletedObligations(C, alice, 3, uint64(block.timestamp - 1 days)); // Developing
        cc.setCommunityLiquid(C, 2_050e6 + 20_000e6); // budget 20_000e6
        cc.primeImpact(C, alice, 20_000e6, 20_000e6); // exposureCap capped at 5000e6
        // ImpactBase = 20_000e6; concentration 10% * 20_000e6 = 2_000e6; phaseCap 1_000e6;
        // exposureCap 5000e6; global 5000e6. min => 1_000e6.
        (d,) = cc.line(C, alice);
        assertEq(d, 1_000e6, "(d) PhaseCap (Developing) binds at 1_000e6");

        // (e) QudiGlobalMemberCap. NOTE: this term does not bind
        // UNIQUELY. `accountExposureCap` embeds `min(., GLOBAL_MEMBER_CAP)` and
        // the Established phase cap equals the global cap, so three terms deliver
        // 5000e6 together. The `line()`-level global term is structurally redundant; it stays
        // because the design lists it. `test_line_globalMemberCapRespected` covers the value.
        cc.primeCompletedObligations(C, alice, 6, uint64(block.timestamp - 200 days)); // Established
        cc.setCommunityLiquid(C, 2_050e6 + 100_000e6); // budget 100_000e6
        cc.primeImpact(C, alice, 100_000e6, 100_000e6);
        cc.primeTeEarned(C, alice, 1_000_000e6); // exposureCap = min(3*100_000e6 + 1_000_000e6, 5000e6) still 5000e6
        cc.primeCommunityAttributedYield(C, 10_000_000e6);
        // ImpactBase 100_000e6; TE min(4000e6, 1_000_000e6) capped by community min(4900e6, 2_000_000e6)=4900e6;
        // base+te huge; concentration 12% * 100_000e6 = 12_000e6; phaseCap 5000e6; global 5000e6;
        // exposureCap 5000e6. All of phaseCap/global/exposureCap are 5000e6: the min is 5000e6
        // and the global cap is one of the terms delivering it.
        (d,) = cc.line(C, alice);
        assertEq(d, 5000e6, "(e) QudiGlobalMemberCap binds at 5000e6");

        // (f) documented as dominated: with concentration bps < 10000, CommunityConcentrationCap
        // <= CommunityImpactBudget in every state, so the budget term never uniquely binds.
        // (See the doc comment.)
    }

    /// Test 19: drawable < MIN_LENDABLE reports not eligible.
    function test_line_belowMinLendableNotEligible() public {
        cc.setHasEverDrawn(C, alice, true);
        cc.primeImpact(C, alice, 1e6, 10_000e6); // share 0.0001
        cc.setCommunityLiquid(C, 2_050e6 + 100e6); // budget 100e6
        // ImpactBase = 100e6 * 0.0001 = 0.01e6 = 10_000 units, well below MIN_LENDABLE 50e6.
        (uint256 d, bool elig) = cc.line(C, alice);
        assertLt(d, 50e6);
        assertFalse(elig);
    }

    /// Test 20: the first-Line cap binds on a first draw and not after.
    /// FirstLine = min(ImpactBase, $50, CommunityImpactBudget, member_exposure_headroom, $100).
    function test_firstLineCap_bindsOnFirstDrawOnly() public {
        cc.primeImpact(C, alice, 1_000e6, 1_000e6); // share 1.0
        cc.setCommunityLiquid(C, 2_050e6 + 5_000e6); // budget 5_000e6
        // ImpactBase = 5_000e6; exposureCap min(3_000e6, 5000e6) = 3_000e6; concentration 5% * 5_000e6 = 250e6;
        // phaseCap FirstAccess 100e6.
        // Without the first-Line cap: min => 100e6 (phaseCap).
        // With it: min(5_000e6, 50e6, 5_000e6, headroom=3_000e6, 100e6) = 50e6.
        cc.setHasEverDrawn(C, alice, false);
        (uint256 d,) = cc.line(C, alice);
        assertEq(d, 50e6, "first draw: capped at $50");

        cc.setHasEverDrawn(C, alice, true);
        (d,) = cc.line(C, alice);
        assertEq(d, 100e6, "after the first draw: the first-Line cap no longer applies");
    }

    /// The first-access exposure headroom
    /// `cap > exp ? cap - exp : 0` inside `line`'s `firstLine` term. `setMemberExposure` sets
    /// `MemberTabSnapshot.openAnywhere = true` and `principal`, which is what `exp` reads. Before
    /// this test nothing in `test/` ever called it, so `exp` was always zero and the headroom term
    /// was an identity on `cap`.
    function test_firstAccessHeadroom_bindsWhenExposureNearCap() public {
        cc.primeImpact(C, alice, 1_000e6, 1_000e6); // share 1.0, seasoned impact 1_000e6
        cc.setCommunityLiquid(C, 2_050e6 + 5_000e6); // budget 5_000e6
        // cap = min(1_000e6 * 3, globalMemberCap) = 3_000e6.
        // Exposure elsewhere in the community is 2_960e6, so headroom = cap - exp = 40e6, below
        // minLend (50e6) and below the other firstLine terms, so it is the binding term.
        cc.setMemberExposure(C, alice, 2_960e6);
        cc.setHasEverDrawn(C, alice, false);

        (uint256 d, bool elig) = cc.line(C, alice);
        assertEq(d, 40e6, "headroom binds firstLine below minLend");
        assertFalse(elig, "below minLend once the headroom binds");
    }

    /// Test 21: composition. A member simultaneously at the activity_factor floor and carrying
    /// a deep conduct scar. The resulting Line is recorded here; the design
    /// requires this combined floor to be checked against the phase caps.
    function test_composition_activityFloorAndDeepScar() public {
        // Established phase, generous everything so the multipliers are what bites.
        cc.primeCompletedObligations(C, alice, 6, uint64(block.timestamp - 200 days));
        cc.primeCommunityAttributedYield(C, 10_000_000e6);
        cc.setCommunityLiquid(C, 2_050e6 + 100_000e6); // budget 100_000e6
        cc.primeImpact(C, alice, 100_000e6, 100_000e6); // share 1.0
        cc.setHasEverDrawn(C, alice, true);

        // activity at the floor: 0.25 WAD
        uint64 old = uint64(block.timestamp - 400 days);
        cc.primeActivity(C, alice, old, 250_000_000_000_000_000, old);
        // a deep, freshly recorded conduct scar: 0.20 WAD
        vm.prank(ledger);
        cc.recordScar(C, alice, 200_000_000_000_000_000);

        // ImpactBase = 100_000e6 * 1.0 * 0.25 * 0.20 = 100_000e6 * 0.05 = 5_000e6.
        assertEq(cc.impactBase(C, alice), 5_000e6, "combined-floor ImpactBase");

        // Line: base 5_000e6 + TE(0, scar unhealed) = 5_000e6; exposureCap 5000e6; phaseCap 5000e6;
        // global 5000e6; concentration 12% * 100_000e6 = 12_000e6. min => 5000e6.
        (uint256 d, bool elig) = cc.line(C, alice);
        assertEq(d, 5_000e6, "composition Line");
        assertTrue(elig);
    }

    // =============================================================================
    // roles
    // =============================================================================

    /// Every external write on `CreditStanding` and its
    /// unauthorized-caller test, so the acceptance criterion is checkable rather than asserted.
    ///
    /// | Write | Gate | Test |
    /// |---|---|---|
    /// | `setImpactAttributor` | `onlyOwner` | this test |
    /// | `setCreditCore` | `onlyOwner`, then one-time, then factory/config match | this test (owner gate); `test_setCreditCore_cannotBeRewired` (one-time); `test_setCreditCore_revertsOnFactoryOrConfigMismatch` (match) |
    /// | `accrueImpact` | `onlyImpactAttributor` | `test_excludedSources_mintZero` |
    /// | `creditCommunityAttributedYield` | `onlyImpactAttributor` | this test |
    /// | `recordScar` | `onlyCreditCore` | this test |
    /// | `creditObligationCompletion` | `onlyCreditCore` | this test |
    /// | `recordFormalDefault` | `onlyCreditCore` | this test (new: had no unauthorized-caller test) |
    /// | `pokeSeasoning` | none (permissionless by design) | not applicable |
    /// | `transferOwnership` (`Ownable2Step`) | `onlyOwner` | `test_roles_ownable2StepWrites` |
    /// | `acceptOwnership` (`Ownable2Step`) | pending-owner only | `test_roles_ownable2StepWrites` |
    /// | `renounceOwnership` (`Ownable`) | `onlyOwner` | `test_roles_ownable2StepWrites` |
    function test_roles_onlyAttributorAndLedger() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        cc.setImpactAttributor(alice);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        cc.setCreditCore(alice);

        vm.prank(alice);
        vm.expectRevert(ICreditStanding.NotImpactAttributor.selector);
        cc.creditCommunityAttributedYield(C, 1e6);

        vm.prank(alice);
        vm.expectRevert(ICreditStanding.NotCreditCore.selector);
        cc.recordScar(C, alice, 0);

        vm.prank(alice);
        vm.expectRevert(ICreditStanding.NotCreditCore.selector);
        cc.creditObligationCompletion(C, alice, 1e6);

        // No test anywhere asserted this revert before.
        vm.prank(alice);
        vm.expectRevert(ICreditStanding.NotCreditCore.selector);
        cc.recordFormalDefault(C, alice);
    }

    /// The three inherited `Ownable2Step` external writes,
    /// absent from the table above until now. `transferOwnership` and `renounceOwnership` are
    /// `onlyOwner`; `acceptOwnership` is gated to the pending owner, which is unset here, so any
    /// caller including the real owner is rejected.
    function test_roles_ownable2StepWrites() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        cc.transferOwnership(alice);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        cc.renounceOwnership();

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        cc.acceptOwnership();
    }

    /// `CreditCore._communityTeBudget` and
    /// `CreditStanding._communityTeBudgetLocal` compute the same quantity from two
    /// different deployed contracts (the duplication itself is accepted), and
    /// nothing held them equal before this test: the reviewer added `+ 1` to the Standing copy
    /// and the full suite passed. Checked across several cumulative attributed-yield values on a
    /// real, wired `CreditCore`/`CreditStanding` pair: zero (the yield term binds at 0), a small
    /// value (the yield term still binds), and a large one (the phase-budget sum binds instead).
    function test_communityTeBudget_matchesAcrossBothContracts() public {
        MockUSDC usdc3 = new MockUSDC();
        Config config3 = new Config(address(usdc3), makeAddr("treasury3"), makeAddr("registry3"));
        MockCommunityFactory factory3 = new MockCommunityFactory();
        factory3.setCommunityCount(1);
        CreditStandingHarness standing3 =
            new CreditStandingHarness(IConfig(address(config3)), address(factory3), governance);
        CreditCoreHarness cc3 = new CreditCoreHarness(
            IERC20(address(usdc3)),
            IConfig(address(config3)),
            address(factory3),
            governance,
            makeAddr("tm3"),
            makeAddr("ms3"),
            standing3
        );
        vm.prank(governance);
        standing3.setCreditCore(address(cc3));
        vm.prank(governance);
        standing3.setImpactAttributor(governance);

        // Zero: the yield term is 0, so it binds below the phase-budget sum.
        assertEq(cc3.communityTeBudget(0), standing3.communityTeBudgetLocal(0), "budgets must match at zero yield");

        // Small: still low enough that the yield term binds.
        vm.prank(governance);
        standing3.creditCommunityAttributedYield(0, 100e6);
        assertEq(cc3.communityTeBudget(0), standing3.communityTeBudgetLocal(0), "budgets must match at a small yield");

        // Large: cumulative yield high enough that the phase-budget sum binds instead.
        vm.prank(governance);
        standing3.creditCommunityAttributedYield(0, 50_000_000e6);
        assertEq(
            cc3.communityTeBudget(0),
            standing3.communityTeBudgetLocal(0),
            "budgets must match where the phase-budget sum binds"
        );
    }

    /// `setCreditCore` reverts if `creditCore_`
    /// is wired to a different `factory` or `config` than this `CreditStanding`. Tested both
    /// ways: a matching pair succeeds (every other test's `setUp` already proves this, since
    /// `ledger` is a `MockCreditCoreWiring` built from `cc`'s own `factory`/`config`), and a
    /// mismatched pair reverts.
    function test_setCreditCore_revertsOnFactoryOrConfigMismatch() public {
        CreditStandingHarness fresh = new CreditStandingHarness(IConfig(address(config)), address(factory), governance);

        MockCommunityFactory wrongFactory = new MockCommunityFactory();
        wrongFactory.setCommunityCount(2);
        address wrongFactoryPair =
            address(new MockCreditCoreWiring(address(wrongFactory), address(config), address(fresh)));
        vm.prank(governance);
        vm.expectRevert(ICreditStanding.CreditCoreMismatch.selector);
        fresh.setCreditCore(wrongFactoryPair);

        Config wrongConfig = new Config(address(new MockUSDC()), makeAddr("treasury2"), makeAddr("registry2"));
        address wrongConfigPair =
            address(new MockCreditCoreWiring(address(factory), address(wrongConfig), address(fresh)));
        vm.prank(governance);
        vm.expectRevert(ICreditStanding.CreditCoreMismatch.selector);
        fresh.setCreditCore(wrongConfigPair);

        // The matching case: same factory and config as `fresh` itself, and it points back at
        // `fresh`, succeeds.
        address matchingPair = address(new MockCreditCoreWiring(address(factory), address(config), address(fresh)));
        vm.prank(governance);
        fresh.setCreditCore(matchingPair);
        assertEq(fresh.creditCore(), matchingPair, "matching factory/config pair wires successfully");
    }

    /// `setCreditCore` also reverts if `creditCore_` does
    /// not point back at this `CreditStanding`, even when its `factory`/`config` match. Tested
    /// both ways: the mismatched case here, and the matching case is
    /// `test_setCreditCore_revertsOnFactoryOrConfigMismatch`'s own `matchingPair` (every other
    /// test's `setUp` also proves it, since `ledger` points `standing()` back at `cc`).
    function test_setCreditCore_revertsOnStandingBackReferenceMismatch() public {
        CreditStandingHarness fresh = new CreditStandingHarness(IConfig(address(config)), address(factory), governance);
        CreditStandingHarness someOtherStanding =
            new CreditStandingHarness(IConfig(address(config)), address(factory), governance);

        address wrongBackReferencePair =
            address(new MockCreditCoreWiring(address(factory), address(config), address(someOtherStanding)));
        vm.prank(governance);
        vm.expectRevert(ICreditStanding.CreditCoreStandingMismatch.selector);
        fresh.setCreditCore(wrongBackReferencePair);
    }

    /// `setCreditCore` is a one-way wire. `setUp` already called it
    /// once (`ledger`); a second call, from any address including the owner, reverts.
    function test_setCreditCore_cannotBeRewired() public {
        vm.prank(governance);
        vm.expectRevert(ICreditStanding.CreditCoreAlreadySet.selector);
        cc.setCreditCore(makeAddr("someOtherCreditCore"));
    }

    function test_obligationCompletion_advancesPhaseAndActivity() public {
        // deeply dormant then complete an obligation -> activity re-anchors (qualifying), and
        // the phase advances after the min time.
        uint64 old = uint64(block.timestamp - 400 days);
        cc.primeActivity(C, alice, old, 250_000_000_000_000_000, old);

        vm.prank(ledger);
        cc.creditObligationCompletion(C, alice, 0);
        assertEq(uint256(cc.phaseOf(C, alice)), uint256(ICreditCore.Phase.FirstAccess), "n=1 but not +30 days");

        // Checked at zero elapsed time, the old assertion here read
        // `activityFactor == 250_000_000_000_000_000` whether or not `_noteActivity` ran, because
        // at zero elapsed time `_dormancyDecay` and `healRamp` both return the frozen floor
        // regardless of when it was frozen. Warping forward less than both the dormancy grace
        // (90 days) and the heal window (90 days) makes the two cases diverge: only a reset
        // anchor heals upward from the floor. Deleting `_noteActivity` from
        // `_creditObligationCompletion` leaves the factor pinned at the floor, which this catches
        // and the old assertion did not.
        vm.warp(block.timestamp + 10 days);
        assertGt(
            cc.activityFactor(C, alice),
            250_000_000_000_000_000,
            "completion is qualifying activity: the anchor moved to now and has begun healing"
        );

        vm.warp(block.timestamp + 20 days); // 30 days since the completion, matching the prior check
        assertEq(uint256(cc.phaseOf(C, alice)), uint256(ICreditCore.Phase.ProvenOnce), "n=1 and +30 days");
    }

    /// The Established phase clock measures time since the
    /// member's FIRST completed obligation, not the most recent one. Forcing
    /// `_creditObligationCompletion`'s `if (_firstObligationAt[c][m] == 0)` guard to `if (true)`
    /// rewrites the anchor on every completion, so a member who keeps borrowing never seasons
    /// into Established regardless of how long they have actually been active. No prior test
    /// calls `creditObligationCompletion` more than once with a gap between calls, so this
    /// mutation left every prior round's suite green.
    function test_creditObligationCompletion_firstObligationAnchorDoesNotReset() public {
        vm.startPrank(ledger);
        cc.creditObligationCompletion(C, alice, 0); // n=1, anchors firstObligationAt
        vm.warp(block.timestamp + 100 days);
        cc.creditObligationCompletion(C, alice, 0); // n=2
        cc.creditObligationCompletion(C, alice, 0); // n=3
        cc.creditObligationCompletion(C, alice, 0); // n=4
        cc.creditObligationCompletion(C, alice, 0); // n=5
        cc.creditObligationCompletion(C, alice, 0); // n=6
        vm.stopPrank();

        // 100 days since the TRUE first completion: not yet the 180-day Established minimum.
        assertEq(
            uint256(cc.phaseOf(C, alice)),
            uint256(ICreditCore.Phase.Developing),
            "100d since the true first completion: not yet Established"
        );

        vm.warp(block.timestamp + 81 days); // 181 days since the true first completion
        assertEq(
            uint256(cc.phaseOf(C, alice)),
            uint256(ICreditCore.Phase.Established),
            "181d since the true first completion: Established"
        );
    }

    /// The completion-count half of the Established gate (`n >= 6`) has
    /// no test. `test_phase_minTimeFromFirstObligation` covers the time half by priming 6
    /// completions and varying elapsed time; nothing primes 5 completions past `minEstablished`
    /// and checks the member stays at Developing. Mutating `n >= 6` to `n >= 5` left the suite
    /// green.
    function test_phase_establishedRequiresSixCompletions() public {
        uint64 first = uint64(block.timestamp);
        cc.primeCompletedObligations(C, alice, 5, first);
        vm.warp(first + 200 days); // well past minEstablished (180d)
        assertEq(
            uint256(cc.phaseOf(C, alice)),
            uint256(ICreditCore.Phase.Developing),
            "5 completions, however seasoned: not yet Established"
        );
    }

    // =============================================================================
    // AccountExposureCap is an account figure across all Communities
    // =============================================================================

    /// Test 26: the design defines the exposure cap over the member's realized attributable
    /// impact "across all Communities". A member with seasoned impact in two Communities gets a
    /// cap computed from the SUM, and every Community's Line view reports the same cap.
    /// Fails against a per-community reading.
    function test_accountExposureCap_aggregatesAcrossCommunities() public {
        uint256 D = 1; // the second community the harness allows

        // 400 USDC of seasoned impact in C, 600 in D. Kept small so 3 * (400 + 600) = 3,000e6
        // stays below the $5,000 global cap and the account sum is what the assertion sees.
        cc.primeImpact(C, alice, 400e6, 400e6);
        cc.primeImpact(D, alice, 600e6, 600e6);

        // account base = 3 * (400e6 + 600e6) = 3,000e6, below the 5,000e6 global cap.
        assertEq(cc.accountExposureCap(C, alice), 3_000e6, "cap uses the account-wide sum");
        assertEq(cc.accountExposureCap(D, alice), 3_000e6, "same cap in the other Community's view");

        // A per-community reading would give min(3 * 400e6, 5000e6) = 1,200e6 in C and
        // 1,800e6 in D: different, and both below the ruled figure.
        assertGt(cc.accountExposureCap(C, alice), 3 * cc.impactUnitsOf(C, alice));
    }

    /// Test 27: a scar in one Community zeroes only that Community's te_earned, and the
    /// account-wide te_earned used by the exposure cap drops by exactly that amount.
    function test_accountExposureCap_scarAdjustsAccountTeEarned() public {
        uint256 D = 1;
        cc.primeImpact(C, alice, 100e6, 100e6);
        cc.primeTeEarned(C, alice, 200e6);
        cc.primeTeEarned(D, alice, 500e6);
        // base = 3 * 100e6 + (200e6 + 500e6) = 1,000e6
        assertEq(cc.accountExposureCap(C, alice), 1_000e6);

        vm.prank(ledger);
        cc.recordScar(C, alice, 500_000_000_000_000_000); // zeroes te_earned in C only
        (, uint256 teC,,) = cc.standingCountersOf(C, alice);
        (, uint256 teD,,) = cc.standingCountersOf(D, alice);
        assertEq(teC, 0);
        assertEq(teD, 500e6, "the other Community's te_earned is untouched");
        assertEq(cc.accountExposureCap(D, alice), 300e6 + 500e6, "account te_earned dropped by 200e6");
    }

    /// `_accountExposureCap`'s internal `min(val, globalMemberCap)` sat
    /// inside a helper and was absent from every prior sweep table. An earlier redundancy proof
    /// leaned on this clamp without it ever being tested, which made the proof
    /// circular. Deleting the `line`-level `globalMemberCap` clamp alone does not catch this
    /// bound (the two are mutually redundant at the `line` level), so this asserts directly
    /// against the pass-through `accountExposureCap` read, independent of `line`'s own clamp
    /// chain: `val = 3 * 2,000e6 = 6,000e6` exceeds `GLOBAL_MEMBER_CAP` (5,000e6 at launch).
    function test_accountExposureCap_clampsToGlobalMemberCap() public {
        cc.primeImpact(C, alice, 2_000e6, 2_000e6);
        assertEq(
            cc.accountExposureCap(C, alice),
            config.globalMemberCap(),
            "account exposure clamps to the global member cap"
        );
    }

    // =============================================================================
    // The open-delinquency seam on Trust Extension
    // =============================================================================

    /// Test 28: Trust Extension is zero while a delinquency is open,
    /// months before any cure records a scar. The seam is now the `MemberTabSnapshot`
    /// `CreditCore` composes and passes in; `setOpenDelinquency` substitutes it.
    function test_trustExtension_openDelinquencyRemovesIt() public {
        cc.primeCompletedObligations(C, alice, 3, uint64(block.timestamp - 1 days)); // Developing
        cc.primeCommunityAttributedYield(C, 100_000e6);
        cc.primeTeEarned(C, alice, 600e6);
        assertEq(cc.trustExtension(C, alice), 600e6, "available with no delinquency and no scar");

        cc.setOpenDelinquency(C, alice, true);
        assertEq(cc.trustExtension(C, alice), 0, "removed at Late entry, before any scar");

        cc.setOpenDelinquency(C, alice, false);
        assertEq(cc.trustExtension(C, alice), 600e6, "restored once the delinquency clears");
    }

    // =============================================================================
    // Phase boundary semantics
    // =============================================================================

    /// Test 29: "min time" is measured from the member's first completed obligation,
    /// not from entering the previous phase. Six completions, established only once 180 days
    /// have passed since the FIRST one.
    function test_phase_minTimeFromFirstObligation() public {
        uint64 first = uint64(block.timestamp);
        cc.primeCompletedObligations(C, alice, 6, first);

        vm.warp(first + 180 days - 1);
        assertEq(uint256(cc.phaseOf(C, alice)), uint256(ICreditCore.Phase.Developing), "179d: not yet Established");

        vm.warp(first + 180 days);
        assertEq(
            uint256(cc.phaseOf(C, alice)), uint256(ICreditCore.Phase.Established), "180d since the first: Established"
        );
    }

    /// Mutation catalogue: `_requireCommunity`'s bound check has no test anywhere in the repository
    /// (confirmed by `grep -rn "UnknownCommunity" test/`, which finds only `ICreditCore`'s
    /// distinct same-named error in an unrelated function). `draw` happens to be shielded by a
    /// second, independent check in `ICommunityFactory.communityAt` right after this one runs, but the
    /// other six external entry points that call `_requireCommunity`
    /// (`accrueImpact`, `recordScar`, `creditObligationCompletion`,
    /// `creditCommunityAttributedYield`, `line`, `impactBase`) have no such backstop.
    function test_requireCommunity_unknownIdReverts() public {
        vm.expectRevert(ICreditStanding.UnknownCommunity.selector);
        cc.requireCommunity(2); // factory.setCommunityCount(2) in setUp: valid ids are 0 and 1
    }

    /// Mutation catalogue: the `n >= 2` Developing threshold has no test at its exact boundary.
    /// Unlike ProvenOnce and Established, Developing carries no minimum-time condition, so two
    /// completions reach it immediately; no existing test primes exactly 2.
    function test_phase_developingAtExactlyTwoCompletions() public {
        uint64 first = uint64(block.timestamp);
        cc.primeCompletedObligations(C, alice, 2, first);
        assertEq(
            uint256(cc.phaseOf(C, alice)),
            uint256(ICreditCore.Phase.Developing),
            "2 completions is Developing immediately, with no minProven wait"
        );
    }

    /// Test 30: a member holds the highest phase whose conditions they satisfy IN FULL.
    /// Six completions at day 150 is Developing: Established needs 180 days, and the
    /// member is not demoted below Developing, which they satisfy in full.
    function test_phase_highestFullySatisfied() public {
        uint64 first = uint64(block.timestamp);

        // one completion, 20 days: FirstAccess (ProvenOnce needs 30 days).
        cc.primeCompletedObligations(C, alice, 1, first);
        vm.warp(first + 20 days);
        assertEq(uint256(cc.phaseOf(C, alice)), uint256(ICreditCore.Phase.FirstAccess));

        // one completion, 40 days: ProvenOnce.
        vm.warp(first + 40 days);
        assertEq(uint256(cc.phaseOf(C, alice)), uint256(ICreditCore.Phase.ProvenOnce));

        // six completions, 150 days: Developing, not Established, not lower.
        cc.primeCompletedObligations(C, alice, 6, first);
        vm.warp(first + 150 days);
        assertEq(uint256(cc.phaseOf(C, alice)), uint256(ICreditCore.Phase.Developing));
    }

    // =============================================================================
    // The QudiGlobalMemberCap term
    // =============================================================================

    /// Test 31: with a governance-set GLOBAL_MEMBER_CAP below every phase cap, the Line never
    /// exceeds it. The `line()`-level global term and the `min(., GLOBAL_MEMBER_CAP)` inside
    /// `accountExposureCap` both enforce this; the
    /// `line()`-level term cannot be shown to bind uniquely.
    function test_line_globalMemberCapRespected() public {
        config.set(K.GLOBAL_MEMBER_CAP, 400e6); // below Developing's 1,000e6 phase cap

        cc.setHasEverDrawn(C, alice, true);
        cc.primeCompletedObligations(C, alice, 3, uint64(block.timestamp - 1 days)); // Developing
        cc.setCommunityLiquid(C, 2_050e6 + 100_000e6); // large budget
        cc.primeImpact(C, alice, 100_000e6, 100_000e6); // share 1.0, huge ImpactBase
        cc.primeTeEarned(C, alice, 1_000_000e6);
        cc.primeCommunityAttributedYield(C, 10_000_000e6);

        (uint256 d,) = cc.line(C, alice);
        assertEq(d, 400e6, "Line clipped to the governance-set global member cap");
    }

    /// Mutation catalogue: `line`'s first-draw exposure headroom, `cap > exp ? cap - exp : 0`.
    /// `cap` (`_accountExposureCap`) can shrink after an obligation opens (a scar can zero
    /// `te_earned`, which feeds it), so a member who has never drawn in THIS community but holds
    /// an open obligation elsewhere can have `exp` (that obligation's principal) exceed their
    /// now-lower `cap`. Without the guard, `cap - exp` underflows and `line` reverts instead of
    /// returning a clean zero-headroom Line, which would brick `draw`'s eligibility check (and
    /// therefore every draw attempt) in every OTHER community for that account until the
    /// exposure elsewhere clears.
    function test_line_firstDrawHeadroomFloorsAtZeroWhenExposureExceedsCap() public {
        cc.primeImpact(C, alice, 10e6, 10e6); // small, shrunk cap: 3 * 10e6 = 30e6
        cc.setCommunityLiquid(C, 2_050e6 + 500e6); // budget is not what this test isolates
        cc.setMemberExposure(C, alice, 500e6); // an open obligation elsewhere, well above the cap

        (uint256 d, bool eligible) = cc.line(C, alice); // must not revert
        assertEq(d, 0, "no first-draw headroom left once existing exposure exceeds the shrunk cap");
        assertFalse(eligible, "zero drawable is never eligible");
    }
}
