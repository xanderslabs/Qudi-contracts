// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {Config} from "../src/Config.sol";
import {ConfigKeys as K} from "../src/ConfigKeys.sol";
import {PoolTypes} from "../src/PoolTypes.sol";
import {IConfig} from "../src/interfaces/IConfig.sol";

contract ConfigTest is Test {
    Config cfg;
    address usdc;
    address treasury;
    address complianceRegistry;

    function setUp() public {
        usdc = makeAddr("usdc");
        treasury = makeAddr("treasury");
        complianceRegistry = makeAddr("complianceRegistry");
        cfg = new Config(usdc, treasury, complianceRegistry);
    }

    // ---------------------------------------------------------------------
    // Launch defaults
    // ---------------------------------------------------------------------

    function test_launchDefaults() public view {
        assertEq(cfg.seatPriceFloor(), 0);
        assertEq(cfg.seatPriceCeiling(), 100e6);
        assertEq(cfg.memberCap(), 150);
        (uint32 inviteUses, uint64 inviteTtl) = cfg.inviteLimits();
        assertEq(inviteUses, 25);
        assertEq(inviteTtl, 30 days);
        (uint16 h, uint16 p, uint16 pr) = cfg.mintSplit();
        assertEq(h, 3000); // host
        assertEq(p, 4000); // Community Credit Account
        assertEq(pr, 3000); // protocol
        assertEq(cfg.epochLength(), 30 days);
        assertEq(cfg.dormancyGrace(), 90 days);
        (uint8 mm, uint8 ce, uint8 mo, uint8 gap) = cfg.eligibility();
        assertEq(mm, 5);
        assertEq(ce, 1);
        assertEq(mo, 3);
        assertEq(gap, 1);
        (uint16 ym, uint16 yp, uint16 ypr) = cfg.yieldSplit();
        assertEq(ym, 7000);
        assertEq(yp, 1500);
        assertEq(ypr, 1500);
        assertEq(cfg.navPauseThresholdBps(), 9950);
        assertEq(cfg.instantTierFloorBps(), 2500);
        assertEq(cfg.slowTierCeilingBps(), 2500);
        assertEq(cfg.maxNoticePeriod(), 30 days);
        assertEq(cfg.globalDepositCap(), 1_000_000e6);
        (uint16 vt, uint64 vw) = cfg.hostVote();
        assertEq(vt, 6667);
        assertEq(vw, 7 days);
        assertEq(cfg.protocolTreasury(), treasury);
        assertEq(cfg.complianceRegistry(), complianceRegistry);
        assertEq(cfg.memberSeasoningWindow(), 14 days);
        assertEq(cfg.usdc(), usdc);
    }

    // ---------------------------------------------------------------------
    // Test 1: every retired key is gone (absent, not zero)
    // ---------------------------------------------------------------------

    /// The charge machinery: no key, no setter, no getter. Setting the old key
    /// reverts because `bounds()` returns (1, 0) for anything it does not recognise.
    function test_retiredKeys_chargeMachinery() public {
        bytes32[5] memory retired = [
            keccak256("qudi.ADVANCE_FEE_BPS"),
            keccak256("qudi.STEWARD_FEE_BPS"),
            keccak256("qudi.PROTOCOL_FEE_BPS"),
            keccak256("qudi.LATE_FEE_BPS"),
            keccak256("qudi.DEFAULT_AFTER")
        ];
        for (uint256 i; i < retired.length; i++) {
            (uint256 lo, uint256 hi) = cfg.bounds(retired[i]);
            assertEq(lo, 1);
            assertEq(hi, 0);
            vm.expectRevert(abi.encodeWithSelector(Config.ValueOutOfBounds.selector, retired[i]));
            cfg.set(retired[i], 1);
        }
        // The composite `setAdvanceFee` setter is gone: this call would not compile if it
        // still existed. Left as a comment so a reader knows the omission is deliberate.
    }

    /// The retired stage-timeline scalars (replaced by five ordered boundaries).
    function test_retiredKeys_oldTimeline() public {
        bytes32[2] memory retired = [keccak256("qudi.ADVANCE_TENOR"), keccak256("qudi.ADVANCE_GRACE")];
        for (uint256 i; i < retired.length; i++) {
            vm.expectRevert(abi.encodeWithSelector(Config.ValueOutOfBounds.selector, retired[i]));
            cfg.set(retired[i], 30 days);
        }
    }

    /// The retired scoring weights (old Line/k/F formula state removed).
    function test_retiredKeys_scoringWeights() public {
        bytes32[3] memory retired =
            [keccak256("qudi.SCORE_SETTLE"), keccak256("qudi.SCORE_CONTRIBUTE"), keccak256("qudi.SCORE_CLEAN_MONTH")];
        for (uint256 i; i < retired.length; i++) {
            vm.expectRevert(abi.encodeWithSelector(Config.ValueOutOfBounds.selector, retired[i]));
            cfg.set(retired[i], 1);
        }
    }

    // ---------------------------------------------------------------------
    // Test 2: total_charges == 0 is structural
    // ---------------------------------------------------------------------

    /// Structural guard on `total_charges == 0`: credit carries no charge.
    ///
    /// The enumeration `_allConfigKeys()` is checked against `ConfigKeys.sol` itself by
    /// `script/check-config-key-enumeration.sh` in CI: every declared key must appear here,
    /// and the `all.length` assertion below must equal the declared count. A new config key,
    /// under any name, fails that script until it is added here, which forces a no-charge audit
    /// of it. This test then asserts, over the enumerated set:
    ///   a) no key is charge-shaped (against `_chargeShapedKeys()`, a heuristic, not the guard), and
    ///   b) no charge-shaped key is settable (`bounds()` returns the reject sentinel (1, 0)).
    /// The script is the guard; parts (a) and (b) are a second layer for the anticipated names.
    function test_noChargeParameterIsReachable() public {
        bytes32[] memory all = _allConfigKeys();
        // Count pinned to ConfigKeys.sol by check-config-key-enumeration.sh (CI).
        assertEq(all.length, 81, "ConfigKeys count changed: update _allConfigKeys and re-audit");

        bytes32[] memory chargeShaped = _chargeShapedKeys();
        for (uint256 c; c < chargeShaped.length; c++) {
            (uint256 lo, uint256 hi) = cfg.bounds(chargeShaped[c]);
            assertTrue(lo > hi, "a charge-shaped key is settable");
            vm.expectRevert();
            cfg.set(chargeShaped[c], 1);
            for (uint256 k; k < all.length; k++) {
                assertTrue(all[k] != chargeShaped[c], "a charge-shaped key is in the key set");
            }
        }
    }

    /// Heuristic second layer: keccak preimages of parameter names a charge could hide behind.
    /// The four an earlier contract held, plus names a re-introduced charge would plausibly
    /// use. Not the guard: `check-config-key-enumeration.sh` is. A charge under a name absent
    /// from this list is caught by that script, not here.
    function _chargeShapedKeys() internal pure returns (bytes32[] memory k) {
        string[17] memory names = [
            "qudi.ADVANCE_FEE_BPS",
            "qudi.STEWARD_FEE_BPS",
            "qudi.PROTOCOL_FEE_BPS",
            "qudi.LATE_FEE_BPS",
            "qudi.MINT_FEE_BPS",
            "qudi.INTEREST_BPS",
            "qudi.ORIGINATION_FEE_BPS",
            "qudi.COMPOUND_RATE_BPS",
            "qudi.DRAW_FEE_BPS",
            "qudi.SERVICE_FEE_BPS",
            "qudi.SPREAD_BPS",
            "qudi.MARKUP_BPS",
            "qudi.SURCHARGE_BPS",
            "qudi.PENALTY_BPS",
            "qudi.CARRY_BPS",
            "qudi.APR_BPS",
            "qudi.FINANCE_CHARGE_BPS"
        ];
        k = new bytes32[](names.length);
        for (uint256 i; i < names.length; i++) {
            k[i] = keccak256(bytes(names[i]));
        }
    }

    /// The complete ConfigKeys set, maintained in lockstep with ConfigKeys.sol. The count
    /// assertion in test_noChargeParameterIsReachable forces this to stay complete.
    function _allConfigKeys() internal pure returns (bytes32[] memory k) {
        k = new bytes32[](81);
        uint256 i;
        k[i++] = K.SEAT_PRICE_FLOOR;
        k[i++] = K.SEAT_PRICE_CEILING;
        k[i++] = K.MEMBER_CAP;
        k[i++] = K.INVITE_MAX_USES;
        k[i++] = K.INVITE_MAX_TTL;
        k[i++] = K.MINT_SPLIT_HOST;
        k[i++] = K.MINT_SPLIT_POOL;
        k[i++] = K.MINT_SPLIT_PROTOCOL;
        k[i++] = K.EPOCH_LENGTH;
        k[i++] = K.WITHDRAW_TERM_CORE;
        k[i++] = K.HOST_VOTE_THRESHOLD_BPS;
        k[i++] = K.HOST_VOTE_WINDOW;
        k[i++] = K.COMMUNITY_VOTE_THRESHOLD_BPS;
        k[i++] = K.COMMUNITY_VOTE_WINDOW;
        k[i++] = K.STAGE_GRACE_START;
        k[i++] = K.STAGE_LATE_START;
        k[i++] = K.STAGE_FINAL_CURE_START;
        k[i++] = K.STAGE_DEFAULT_RECOVERY_START;
        k[i++] = K.STAGE_WRITTEN_OFF_AT;
        k[i++] = K.DORMANCY_GRACE;
        k[i++] = K.ELIG_MIN_MEMBERS;
        k[i++] = K.ELIG_CLEAN_EPOCHS;
        k[i++] = K.ELIG_MEMBER_MONTHS;
        k[i++] = K.ELIG_MAX_GAP_MONTHS;
        k[i++] = K.YIELD_SPLIT_MEMBER;
        k[i++] = K.YIELD_SPLIT_POOL;
        k[i++] = K.YIELD_SPLIT_PROTOCOL;
        k[i++] = K.NAV_PAUSE_BPS;
        k[i++] = K.INSTANT_TIER_FLOOR_BPS;
        k[i++] = K.SLOW_TIER_CEILING_BPS;
        k[i++] = K.MAX_NOTICE_PERIOD;
        k[i++] = K.GLOBAL_DEPOSIT_CAP;
        k[i++] = K.PROTOCOL_TREASURY;
        k[i++] = K.COMPLIANCE_REGISTRY;
        k[i++] = K.MEMBER_SEASONING_WINDOW;
        k[i++] = K.WITHDRAW_TERM_FLEX;
        k[i++] = K.FLEX_BUFFER_TARGET_BPS;
        // The Term tier's withdrawal waiting period. No-charge
        // audit: not charge-shaped. It is a duration read only by `withdrawTerm(TERM)`, which
        // decides how long a queued withdrawal waits, and it is never read on any repayment path.
        // It cannot add anything to what a member owes.
        k[i++] = K.WITHDRAW_TERM_TERM;
        k[i++] = K.MIN_LENDABLE;
        k[i++] = K.GLOBAL_MEMBER_CAP;
        k[i++] = K.EXPOSURE_IMPACT_MULT_X100;
        k[i++] = K.ACTIVITY_DECAY_LENGTH;
        k[i++] = K.ACTIVITY_FLOOR_BPS;
        k[i++] = K.STANDING_HEAL_WINDOW;
        k[i++] = K.PHASE_CAP_FIRST_ACCESS;
        k[i++] = K.PHASE_CAP_PROVEN_ONCE;
        k[i++] = K.PHASE_CAP_DEVELOPING;
        k[i++] = K.CONCENTRATION_FIRST_ACCESS_BPS;
        k[i++] = K.CONCENTRATION_PROVEN_ONCE_BPS;
        k[i++] = K.CONCENTRATION_DEVELOPING_BPS;
        k[i++] = K.CONCENTRATION_ESTABLISHED_BPS;
        k[i++] = K.TE_BUDGET_PROVEN_ONCE;
        k[i++] = K.TE_BUDGET_DEVELOPING;
        k[i++] = K.TE_BUDGET_ESTABLISHED;
        k[i++] = K.TE_COMMUNITY_CAP_BPS;
        k[i++] = K.PHASE_MIN_TIME_PROVEN_ONCE;
        k[i++] = K.PHASE_MIN_TIME_ESTABLISHED;
        k[i++] = K.OPERATING_BUFFER_PER_COMMUNITY;
        k[i++] = K.OPERATING_FLOOR_GLOBAL;
        k[i++] = K.CREDIT_LOSS_RESERVE_CURRENT_BPS;
        k[i++] = K.CREDIT_LOSS_RESERVE_LATE_BPS;
        k[i++] = K.CREDIT_LOSS_RESERVE_FINAL_CURE_BPS;
        k[i++] = K.CREDIT_LOSS_RESERVE_DEFAULT_RECOVERY_BPS;
        k[i++] = K.VENUE_LOSS_RESERVE_BPS;
        k[i++] = K.VENUE_ALLOCATION_MAX_BPS;
        k[i++] = K.PER_VENUE_CAP_BPS;
        k[i++] = K.MAX_VENUE_REDEMPTION_DELAY;
        k[i++] = K.MAX_VENUE_SLIPPAGE_BPS;
        k[i++] = K.STRESS_CAPITAL_RATE_BPS;
        k[i++] = K.STRESS_CAPITAL_FLOOR;
        // The debt half. CREDIT_CORE is an address (not settable via `set`, so not
        // charge-shaped by construction). TE_EARN_INCREMENT sizes what a member CAN borrow
        // (Trust Extension capacity), never what they owe (no charge, no fee, no
        // interest at any stage) - it is not a charge under any name.
        k[i++] = K.CREDIT_CORE;
        k[i++] = K.TE_EARN_INCREMENT;
        // The Yield Engine's vault half. No-charge audit: none of the three is charge-shaped.
        // UNLOCK_PERIOD and HARVEST_PERIOD time how the vault recognizes its own venue yield,
        // and HARVEST_DEVIATION_X100 is a circuit-breaker multiple on that yield. None of them
        // is read on any repayment path, and none can add anything to what a member owes.
        k[i++] = K.UNLOCK_PERIOD;
        k[i++] = K.HARVEST_PERIOD;
        k[i++] = K.HARVEST_DEVIATION_X100;
        // The shared-vault withdrawal. No-charge audit: none of the three is charge-shaped.
        // The two bps keys are vote bars, counts of people that decide whether a community's own
        // pot may pay a recipient it voted for. SHARED_PROPOSAL_REVERT_DELAY times when an
        // unexecuted earmark may be returned to that pot. None is read on any repayment path,
        // and none can add anything to what a member owes: they move a community's own savings
        // between the community and a recipient it chose, never between a member and a debt.
        k[i++] = K.SHARED_WITHDRAWAL_QUORUM_BPS;
        k[i++] = K.SHARED_WITHDRAWAL_APPROVAL_BPS;
        k[i++] = K.SHARED_PROPOSAL_REVERT_DELAY;
        // No-charge audit: neither bar can add anything to what a member owes. They decide who is
        // in the electorate for a vote over a community's own savings, which is a count of
        // people, and no repayment path reads either.
        k[i++] = K.QUALIFYING_CONTRIBUTOR_MIN_DEPOSIT;
        k[i++] = K.QUALIFYING_CONTRIBUTOR_SEASONING;
        // The removal cooldown. No-charge audit: not charge-shaped. It is a duration read only by
        // `Community.proposeRemoval`, which decides when the steward may propose removing the
        // same member again after a failed vote. It is never read on any repayment path and
        // cannot add anything to what a member owes.
        k[i++] = K.REMOVAL_REPROPOSE_COOLDOWN;
        require(i == k.length, "key list length mismatch");
    }

    // ---------------------------------------------------------------------
    // Tests 3 and 4: stage boundaries
    // ---------------------------------------------------------------------

    function test_stageBoundaries_launchValues() public view {
        (uint64 g, uint64 l, uint64 fc, uint64 dr, uint64 wo) = cfg.stageBoundaries();
        assertEq(g, 60 days);
        assertEq(l, 65 days);
        assertEq(fc, 95 days);
        assertEq(dr, 155 days);
        assertEq(wo, 365 days);
        // Stored in seconds, exactly.
        assertEq(g, 5_184_000);
        assertEq(wo, 31_536_000);
    }

    function test_stageBoundaries_storeAndReadBack() public {
        cfg.setStageBoundaries(50 days, 55 days, 80 days, 140 days, 300 days);
        (uint64 g, uint64 l, uint64 fc, uint64 dr, uint64 wo) = cfg.stageBoundaries();
        assertEq(g, 50 days);
        assertEq(l, 55 days);
        assertEq(fc, 80 days);
        assertEq(dr, 140 days);
        assertEq(wo, 300 days);
    }

    /// Each adjacent pair out of order reverts. The timeline can never express Grace before
    /// Tenor, Late before Grace, and so on.
    function test_stageBoundaries_outOfOrderReverts() public {
        vm.expectRevert(Config.TimelineOutOfOrder.selector);
        cfg.setStageBoundaries(0, 65 days, 95 days, 155 days, 365 days); // grace at 0
        vm.expectRevert(Config.TimelineOutOfOrder.selector);
        cfg.setStageBoundaries(65 days, 60 days, 95 days, 155 days, 365 days); // late < grace
        vm.expectRevert(Config.TimelineOutOfOrder.selector);
        cfg.setStageBoundaries(60 days, 95 days, 65 days, 155 days, 365 days); // finalCure < late
        vm.expectRevert(Config.TimelineOutOfOrder.selector);
        cfg.setStageBoundaries(60 days, 65 days, 155 days, 95 days, 365 days); // defaultRec < finalCure
        vm.expectRevert(Config.TimelineOutOfOrder.selector);
        cfg.setStageBoundaries(60 days, 65 days, 95 days, 365 days, 155 days); // writtenOff < defaultRec
        vm.expectRevert(Config.TimelineOutOfOrder.selector);
        cfg.setStageBoundaries(60 days, 65 days, 95 days, 155 days, 60 days); // equal, not strictly increasing
        vm.expectRevert(Config.TimelineOutOfOrder.selector);
        cfg.setStageBoundaries(60 days, 65 days, 95 days, 155 days, 2000 days); // past the sanity ceiling
    }

    /// Boundary arithmetic is half-open and in seconds. A consumer deriving the stage as
    /// `t < graceStart ? Tenor : t < lateStart ? Grace : ...` lands exactly where the design says.
    /// This is the off-by-one class the calibration packet planted; the check lives with the
    /// stored values here and again in the CreditCore stage-derivation tests.
    function test_stageBoundaries_halfOpenInSeconds() public view {
        (uint64 g, uint64 l, uint64 fc, uint64 dr, uint64 wo) = cfg.stageBoundaries();
        assertEq(_stageAt(g - 1, g, l, fc, dr, wo), 0); // 60d - 1s: Tenor
        assertEq(_stageAt(g, g, l, fc, dr, wo), 1); // 60d exactly: Grace
        assertEq(_stageAt(l - 1, g, l, fc, dr, wo), 1); // 65d - 1s: Grace
        assertEq(_stageAt(l, g, l, fc, dr, wo), 2); // 65d exactly: Late
        assertEq(_stageAt(fc - 1, g, l, fc, dr, wo), 2); // 95d - 1s: Late
        assertEq(_stageAt(fc, g, l, fc, dr, wo), 3); // 95d exactly: Final Cure
        assertEq(_stageAt(dr - 1, g, l, fc, dr, wo), 3); // 155d - 1s: Final Cure
        assertEq(_stageAt(dr, g, l, fc, dr, wo), 4); // 155d exactly: Default Recovery
        assertEq(_stageAt(wo - 1, g, l, fc, dr, wo), 4); // 365d - 1s: Default Recovery
        assertEq(_stageAt(wo, g, l, fc, dr, wo), 5); // 365d exactly: Written Off
    }

    function _stageAt(uint64 t, uint64 g, uint64 l, uint64 fc, uint64 dr, uint64 wo) internal pure returns (uint8) {
        if (t < g) return 0;
        if (t < l) return 1;
        if (t < fc) return 2;
        if (t < dr) return 3;
        if (t < wo) return 4;
        return 5;
    }

    function test_stageBoundaries_notScalarSettable() public {
        vm.expectRevert(abi.encodeWithSelector(Config.ValueOutOfBounds.selector, K.STAGE_GRACE_START));
        cfg.set(K.STAGE_GRACE_START, 61 days);
    }

    // ---------------------------------------------------------------------
    // Test 5: seat split
    // ---------------------------------------------------------------------

    function test_seatSplit_launchValues() public view {
        (uint16 host, uint16 pool, uint16 protocol) = cfg.mintSplit();
        assertEq(host, 3000);
        assertEq(pool, 4000);
        assertEq(protocol, 3000);
        assertEq(uint256(host) + pool + protocol, 10_000);
    }

    function test_seatSplit_mustSumToTenThousand() public {
        vm.expectRevert(Config.SplitMismatch.selector);
        cfg.setMintSplit(4000, 3000, 2000); // 9000
        vm.expectRevert(Config.SplitMismatch.selector);
        cfg.setMintSplit(4000, 4000, 4000); // 12000
        cfg.setMintSplit(5000, 2500, 2500); // ok
        (uint16 host, uint16 pool, uint16 protocol) = cfg.mintSplit();
        assertEq(host, 5000);
        assertEq(pool, 2500);
        assertEq(protocol, 2500);
    }

    function test_yieldSplit_mustSumToTenThousand() public {
        vm.expectRevert(Config.SplitMismatch.selector);
        cfg.setYieldSplit(7000, 2000, 2000); // 11000
        cfg.setYieldSplit(6000, 3000, 1000); // ok
    }

    // ---------------------------------------------------------------------
    // Test 6: retained-capital parameters
    // ---------------------------------------------------------------------

    function test_retainedCapital_launchValues() public view {
        (uint256 perCommunity, uint256 globalFloor) = cfg.operatingRequirement();
        assertEq(perCommunity, 2000e6); // $2,000, 6-decimal
        assertEq(globalFloor, 10_000e6); // $10,000
        assertEq(perCommunity, 2_000_000_000); // not 2000
        (uint16 current, uint16 late, uint16 finalCure, uint16 defaultRecovery) = cfg.creditLossReserveBps();
        assertEq(current, 500); // 5%
        assertEq(late, 2500); // 25%
        assertEq(finalCure, 5000); // 50%
        assertEq(defaultRecovery, 10_000); // 100%
        assertEq(cfg.venueLossReserveBps(), 2000); // 20% of largest single-venue exposure
        assertEq(cfg.venueAllocationMaxBps(), 5000); // 50% of liquid above buffer
        (uint16 rateBps, uint256 floor) = cfg.stressCapital();
        assertEq(rateBps, 1000); // 10% of total outstanding
        assertEq(floor, 100_000e6); // $100,000
    }

    function test_retainedCapital_boundsEnforced() public {
        cfg.set(K.CREDIT_LOSS_RESERVE_LATE_BPS, 10_000); // hi bound
        cfg.set(K.CREDIT_LOSS_RESERVE_LATE_BPS, 0); // lo bound
        vm.expectRevert(abi.encodeWithSelector(Config.ValueOutOfBounds.selector, K.CREDIT_LOSS_RESERVE_LATE_BPS));
        cfg.set(K.CREDIT_LOSS_RESERVE_LATE_BPS, 10_001);
    }

    // ---------------------------------------------------------------------
    // Treasury Manager venue limits
    // ---------------------------------------------------------------------

    function test_venueLimits_launchValues() public view {
        assertEq(cfg.perVenueCapBps(), 2500); // 25% of total Treasury cash
        assertEq(cfg.maxVenueSlippageBps(), 50); // 50 bps
        // The redemption-delay limit is the pending-obligation window. That window's
        // own key was retired as unread, so the 7 days is now asserted directly.
        assertEq(cfg.maxVenueRedemptionDelay(), 7 days);
    }

    function test_venueLimits_rejectZero() public {
        vm.expectRevert(abi.encodeWithSelector(Config.ValueOutOfBounds.selector, K.PER_VENUE_CAP_BPS));
        cfg.set(K.PER_VENUE_CAP_BPS, 0);
        vm.expectRevert(abi.encodeWithSelector(Config.ValueOutOfBounds.selector, K.MAX_VENUE_REDEMPTION_DELAY));
        cfg.set(K.MAX_VENUE_REDEMPTION_DELAY, 0);
        vm.expectRevert(abi.encodeWithSelector(Config.ValueOutOfBounds.selector, K.MAX_VENUE_SLIPPAGE_BPS));
        cfg.set(K.MAX_VENUE_SLIPPAGE_BPS, 0);
    }

    function test_venueLimits_boundsEnforced() public {
        // The per-venue ceiling is 5000 (50%), not 10_000. At 10_000 a
        // venue's own exposure, part of the cap's base, could never exceed the cap.
        cfg.set(K.PER_VENUE_CAP_BPS, 1); // lo
        cfg.set(K.PER_VENUE_CAP_BPS, 5000); // hi
        vm.expectRevert(abi.encodeWithSelector(Config.ValueOutOfBounds.selector, K.PER_VENUE_CAP_BPS));
        cfg.set(K.PER_VENUE_CAP_BPS, 5001);

        // The redemption-delay ceiling was set at the pending-obligation
        // window's own ceiling. That key is retired, so the same 30 days is asserted here
        // as a literal; the value and the reason for it are unchanged.
        (, uint256 delayHi) = cfg.bounds(K.MAX_VENUE_REDEMPTION_DELAY);
        assertEq(delayHi, 30 days);
        cfg.set(K.MAX_VENUE_REDEMPTION_DELAY, 1); // lo
        cfg.set(K.MAX_VENUE_REDEMPTION_DELAY, delayHi); // hi
        vm.expectRevert(abi.encodeWithSelector(Config.ValueOutOfBounds.selector, K.MAX_VENUE_REDEMPTION_DELAY));
        cfg.set(K.MAX_VENUE_REDEMPTION_DELAY, delayHi + 1);

        cfg.set(K.MAX_VENUE_SLIPPAGE_BPS, 1); // lo
        cfg.set(K.MAX_VENUE_SLIPPAGE_BPS, 1000); // hi, well below a meaningless level
        vm.expectRevert(abi.encodeWithSelector(Config.ValueOutOfBounds.selector, K.MAX_VENUE_SLIPPAGE_BPS));
        cfg.set(K.MAX_VENUE_SLIPPAGE_BPS, 1001);
    }

    // ---------------------------------------------------------------------
    // Test 7: role gating and ownership
    // ---------------------------------------------------------------------

    function test_roleGating_onlyOwnerSets() public {
        // The "Risk Committee" is the owner (a 48h timelock on mainnet, ConfigTimelock.t.sol).
        // Any other caller, the Emergency Guardian included, cannot set parameters.
        address guardian = makeAddr("guardian");
        vm.prank(guardian);
        vm.expectRevert();
        cfg.set(K.SEAT_PRICE_FLOOR, 60e6);

        vm.prank(guardian);
        vm.expectRevert();
        cfg.setStageBoundaries(60 days, 65 days, 95 days, 155 days, 365 days);

        vm.prank(guardian);
        vm.expectRevert();
        cfg.setMintSplit(4000, 3000, 3000);

        // The owner can.
        cfg.set(K.SEAT_PRICE_FLOOR, 60e6);
        assertEq(cfg.seatPriceFloor(), 60e6);
    }

    function test_ownershipIsTwoStep() public {
        address next = makeAddr("next");
        cfg.transferOwnership(next);
        assertEq(cfg.owner(), address(this)); // not yet
        vm.prank(next);
        cfg.acceptOwnership();
        assertEq(cfg.owner(), next);
    }

    // ---------------------------------------------------------------------
    // Test 9: bounds are not settable
    // ---------------------------------------------------------------------

    function test_boundsAreNotSettable() public {
        (uint256 loBefore, uint256 hiBefore) = cfg.bounds(K.SEAT_PRICE_FLOOR);
        cfg.set(K.SEAT_PRICE_FLOOR, 75e6);
        (uint256 loAfter, uint256 hiAfter) = cfg.bounds(K.SEAT_PRICE_FLOOR);
        assertEq(loBefore, loAfter);
        assertEq(hiBefore, hiAfter);
        // `bounds()` is `pure`: there is no state it could read, so no setter can move it.
        // A setter targeting bounds would not compile.
    }

    // ---------------------------------------------------------------------
    // Test 10: every surviving setter emits its event
    // ---------------------------------------------------------------------

    function testFuzz_scalarSetEmits(uint256 v) public {
        v = bound(v, 1e6, 1000e6);
        vm.expectEmit(true, false, false, true);
        emit Config.ParameterChanged(K.SEAT_PRICE_FLOOR, bytes32(uint256(0)), bytes32(v));
        cfg.set(K.SEAT_PRICE_FLOOR, v);
        assertEq(cfg.seatPriceFloor(), v);
    }

    function test_setMintSplitEmitsEachLeg() public {
        vm.expectEmit(true, false, false, true);
        emit Config.ParameterChanged(K.MINT_SPLIT_HOST, bytes32(uint256(3000)), bytes32(uint256(5000)));
        vm.expectEmit(true, false, false, true);
        emit Config.ParameterChanged(K.MINT_SPLIT_POOL, bytes32(uint256(4000)), bytes32(uint256(2500)));
        vm.expectEmit(true, false, false, true);
        emit Config.ParameterChanged(K.MINT_SPLIT_PROTOCOL, bytes32(uint256(3000)), bytes32(uint256(2500)));
        cfg.setMintSplit(5000, 2500, 2500);
    }

    function test_setStageBoundariesEmitsEachBoundary() public {
        vm.expectEmit(true, false, false, true);
        emit Config.ParameterChanged(K.STAGE_GRACE_START, bytes32(uint256(60 days)), bytes32(uint256(50 days)));
        vm.expectEmit(true, false, false, true);
        emit Config.ParameterChanged(K.STAGE_LATE_START, bytes32(uint256(65 days)), bytes32(uint256(55 days)));
        vm.expectEmit(true, false, false, true);
        emit Config.ParameterChanged(K.STAGE_FINAL_CURE_START, bytes32(uint256(95 days)), bytes32(uint256(80 days)));
        vm.expectEmit(true, false, false, true);
        emit Config.ParameterChanged(
            K.STAGE_DEFAULT_RECOVERY_START, bytes32(uint256(155 days)), bytes32(uint256(140 days))
        );
        vm.expectEmit(true, false, false, true);
        emit Config.ParameterChanged(K.STAGE_WRITTEN_OFF_AT, bytes32(uint256(365 days)), bytes32(uint256(300 days)));
        cfg.setStageBoundaries(50 days, 55 days, 80 days, 140 days, 300 days);
    }

    function test_setAddressEmits() public {
        address t2 = makeAddr("treasury2");
        vm.expectEmit(true, false, false, true);
        emit Config.ParameterChanged(
            K.PROTOCOL_TREASURY, bytes32(uint256(uint160(treasury))), bytes32(uint256(uint160(t2)))
        );
        cfg.setAddress(K.PROTOCOL_TREASURY, t2);
    }

    // ---------------------------------------------------------------------
    // Retained behaviour from an earlier suite
    // ---------------------------------------------------------------------

    function testFuzz_boundsEnforced(uint256 v) public {
        (uint256 lo, uint256 hi) = cfg.bounds(K.EPOCH_LENGTH);
        vm.assume(v < lo || v > hi);
        vm.expectRevert(abi.encodeWithSelector(Config.ValueOutOfBounds.selector, K.EPOCH_LENGTH));
        cfg.set(K.EPOCH_LENGTH, v);
    }

    function test_scalarSetRejectsCompositeKeys() public {
        vm.expectRevert(abi.encodeWithSelector(Config.ValueOutOfBounds.selector, K.MINT_SPLIT_HOST));
        cfg.set(K.MINT_SPLIT_HOST, 5000);
        vm.expectRevert(abi.encodeWithSelector(Config.ValueOutOfBounds.selector, K.PROTOCOL_TREASURY));
        cfg.set(K.PROTOCOL_TREASURY, 1);
    }

    function test_setAddress() public {
        address t2 = makeAddr("treasury2");
        cfg.setAddress(K.PROTOCOL_TREASURY, t2);
        assertEq(cfg.protocolTreasury(), t2);
        address r2 = makeAddr("registry2");
        cfg.setAddress(K.COMPLIANCE_REGISTRY, r2);
        assertEq(cfg.complianceRegistry(), r2);
        vm.expectRevert(Config.ZeroAddress.selector);
        cfg.setAddress(K.COMPLIANCE_REGISTRY, address(0));
        vm.expectRevert(Config.UnknownAddressKey.selector);
        cfg.setAddress(K.SEAT_PRICE_FLOOR, t2);
    }

    function test_memberSeasoningWindowBounds() public {
        cfg.set(K.MEMBER_SEASONING_WINDOW, 1 days); // lo
        cfg.set(K.MEMBER_SEASONING_WINDOW, 90 days); // hi
        cfg.set(K.MEMBER_SEASONING_WINDOW, 14 days); // launch value
        vm.expectRevert(abi.encodeWithSelector(Config.ValueOutOfBounds.selector, K.MEMBER_SEASONING_WINDOW));
        cfg.set(K.MEMBER_SEASONING_WINDOW, 91 days);
    }

    /// The launch value is 30 days, and both ends of the range are fixed: at least 7 days, so a
    /// timelocked change cannot make it zero and let a steward re-freeze a member the moment a
    /// vote fails, and at most 180.
    function test_removalReproposeCooldownBounds() public {
        assertEq(cfg.removalReproposeCooldown(), 30 days, "launch value");
        cfg.set(K.REMOVAL_REPROPOSE_COOLDOWN, 7 days); // lo
        cfg.set(K.REMOVAL_REPROPOSE_COOLDOWN, 180 days); // hi
        vm.expectRevert(abi.encodeWithSelector(Config.ValueOutOfBounds.selector, K.REMOVAL_REPROPOSE_COOLDOWN));
        cfg.set(K.REMOVAL_REPROPOSE_COOLDOWN, 7 days - 1);
        vm.expectRevert(abi.encodeWithSelector(Config.ValueOutOfBounds.selector, K.REMOVAL_REPROPOSE_COOLDOWN));
        cfg.set(K.REMOVAL_REPROPOSE_COOLDOWN, 180 days + 1);
    }

    /// A free seat is allowed, so the floor may be 0. Each key's range holds at both ends.
    function test_seatPriceMemberCapAndInviteBounds() public {
        _assertRange(K.SEAT_PRICE_FLOOR, 0, 1000e6);
        _assertRange(K.SEAT_PRICE_CEILING, 0, 1000e6);
        _assertRange(K.MEMBER_CAP, 10, 1000);
        _assertRange(K.INVITE_MAX_USES, 1, 150);
        _assertRange(K.INVITE_MAX_TTL, 1 days, 90 days);
    }

    /// `lo` and `hi` are settable, and one past either end is refused. A `lo` of 0 has no value
    /// below it.
    function _assertRange(bytes32 key, uint256 lo, uint256 hi) internal {
        cfg.set(key, lo);
        cfg.set(key, hi);
        if (lo != 0) {
            vm.expectRevert(abi.encodeWithSelector(Config.ValueOutOfBounds.selector, key));
            cfg.set(key, lo - 1);
        }
        vm.expectRevert(abi.encodeWithSelector(Config.ValueOutOfBounds.selector, key));
        cfg.set(key, hi + 1);
    }

    function test_prospectiveOnly() public {
        uint256 valueBefore = cfg.seatPriceFloor();
        cfg.set(K.SEAT_PRICE_FLOOR, 75e6);
        assertEq(valueBefore, 0);
        assertEq(cfg.seatPriceFloor(), 75e6);
    }

    function test_communityVoteDefaults() public view {
        (uint16 thresholdBps, uint64 window) = cfg.communityVote();
        assertEq(thresholdBps, 5001);
        assertEq(window, 7 days);
    }

    function test_communityVoteBounds() public {
        vm.expectRevert(abi.encodeWithSelector(Config.ValueOutOfBounds.selector, K.COMMUNITY_VOTE_THRESHOLD_BPS));
        cfg.set(K.COMMUNITY_VOTE_THRESHOLD_BPS, 5000);
        cfg.set(K.COMMUNITY_VOTE_THRESHOLD_BPS, 5001);
        cfg.set(K.COMMUNITY_VOTE_THRESHOLD_BPS, 10_000);
        vm.expectRevert(abi.encodeWithSelector(Config.ValueOutOfBounds.selector, K.COMMUNITY_VOTE_WINDOW));
        cfg.set(K.COMMUNITY_VOTE_WINDOW, 12 hours);
    }

    function test_hostVoteBounds() public {
        vm.expectRevert(abi.encodeWithSelector(Config.ValueOutOfBounds.selector, K.HOST_VOTE_THRESHOLD_BPS));
        cfg.set(K.HOST_VOTE_THRESHOLD_BPS, 5000);
        cfg.set(K.HOST_VOTE_THRESHOLD_BPS, 6667);
        (uint16 t,) = cfg.hostVote();
        assertEq(t, 6667);
    }

    /// Every tier's withdrawal term, and the one place the ordering is stated. Term is 0 since
    /// 2026-09-22: it is the tier whose venue has had the whole lock
    /// period to arrange liquidity, so it is the one with nothing left to wait for. The 7 days it
    /// carried before came from extending the Flex and Core pattern, which had it backwards.
    /// The other two figures are unchanged by that change, and asserting them here is what
    /// shows it did not leak into them.
    function test_withdrawTermsPerPoolType() public view {
        assertEq(cfg.withdrawTerm(PoolTypes.CORE), 3 days);
        assertEq(cfg.withdrawTerm(PoolTypes.FLEX), 1 days);
        assertEq(cfg.withdrawTerm(PoolTypes.TERM), 0);
    }

    /// TERM resolves a withdrawal term since 2026-09-21: it became an
    /// ordinary tier, so it answers like the others. This test used to assert it reverted; the
    /// value itself is asserted above.
    function test_everyPoolTypeResolvesAWithdrawTerm() public view {
        for (uint8 i; i < PoolTypes.COUNT; i++) {
            cfg.withdrawTerm(i);
        }
    }

    function test_withdrawTermUnknownPoolTypeReverts() public {
        vm.expectRevert(IConfig.UnknownPoolType.selector);
        cfg.withdrawTerm(7);
    }

    function test_flexAndLockDefaultsAndBounds() public {
        assertEq(cfg.flexBufferTargetBps(), 1000);
        cfg.set(K.WITHDRAW_TERM_FLEX, 0);
        cfg.set(K.WITHDRAW_TERM_FLEX, 30 days);
        vm.expectRevert(abi.encodeWithSelector(Config.ValueOutOfBounds.selector, K.WITHDRAW_TERM_FLEX));
        cfg.set(K.WITHDRAW_TERM_FLEX, 31 days);
    }

    // ---- Standing keys ----

    function test_standing_launchValues() public view {
        assertEq(cfg.minLendable(), 50e6);
        assertEq(cfg.globalMemberCap(), 5000e6);
        assertEq(cfg.exposureImpactMultX100(), 300); // 3x
        assertEq(cfg.activityDecayLength(), 180 days); // W
        assertEq(cfg.activityFloorBps(), 2500); // FLOOR 0.25
        assertEq(cfg.standingHealWindow(), 90 days);
        assertEq(cfg.teCommunityCapBps(), 2000); // 20%

        (uint256 c0, uint16 conc0, uint256 te0, uint64 mt0) = cfg.phaseCaps(0);
        assertEq(c0, 100e6);
        assertEq(conc0, 500);
        assertEq(te0, 0);
        assertEq(mt0, 0);
        (uint256 c1, uint16 conc1, uint256 te1, uint64 mt1) = cfg.phaseCaps(1);
        assertEq(c1, 300e6);
        assertEq(conc1, 800);
        assertEq(te1, 200e6);
        assertEq(mt1, 30 days);
        (uint256 c2, uint16 conc2, uint256 te2, uint64 mt2) = cfg.phaseCaps(2);
        assertEq(c2, 1000e6);
        assertEq(conc2, 1000);
        assertEq(te2, 700e6);
        assertEq(mt2, 0);
        (uint256 c3, uint16 conc3, uint256 te3, uint64 mt3) = cfg.phaseCaps(3);
        assertEq(c3, 5000e6); // Established caps at the Global Member Cap
        assertEq(conc3, 1200);
        assertEq(te3, 4000e6);
        assertEq(mt3, 180 days);
    }

    /// The activity FLOOR rejects zero. So do MIN_LENDABLE and the
    /// exposure multiplier, for the same reason (a zero repeals the mechanism).
    function test_standingBoundsRejectZero() public {
        vm.expectRevert(abi.encodeWithSelector(Config.ValueOutOfBounds.selector, K.ACTIVITY_FLOOR_BPS));
        cfg.set(K.ACTIVITY_FLOOR_BPS, 0);
        vm.expectRevert(abi.encodeWithSelector(Config.ValueOutOfBounds.selector, K.MIN_LENDABLE));
        cfg.set(K.MIN_LENDABLE, 0);
        vm.expectRevert(abi.encodeWithSelector(Config.ValueOutOfBounds.selector, K.EXPOSURE_IMPACT_MULT_X100));
        cfg.set(K.EXPOSURE_IMPACT_MULT_X100, 0);
        vm.expectRevert(abi.encodeWithSelector(Config.ValueOutOfBounds.selector, K.ACTIVITY_DECAY_LENGTH));
        cfg.set(K.ACTIVITY_DECAY_LENGTH, 0);
        vm.expectRevert(abi.encodeWithSelector(Config.ValueOutOfBounds.selector, K.STANDING_HEAL_WINDOW));
        cfg.set(K.STANDING_HEAL_WINDOW, 0);
    }

    /// The activity FLOOR also cannot be set to a value at which the decay is dead (1.0).
    function test_activityFloorCeilingBelowOne() public {
        cfg.set(K.ACTIVITY_FLOOR_BPS, 9999);
        vm.expectRevert(abi.encodeWithSelector(Config.ValueOutOfBounds.selector, K.ACTIVITY_FLOOR_BPS));
        cfg.set(K.ACTIVITY_FLOOR_BPS, 10_000);
    }
}
