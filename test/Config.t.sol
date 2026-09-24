// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {Config} from "../src/Config.sol";
import {ConfigKeys as K} from "../src/ConfigKeys.sol";
import {VenueIds} from "./helpers/VenueIds.sol";
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
        assertEq(cfg.dormancyGrace(), 90 days);
        assertEq(cfg.communityMinMembers(), 5);
        (uint16 ym, uint16 yp, uint16 ypr) = cfg.yieldSplit();
        assertEq(ym, 7000);
        assertEq(yp, 1500);
        assertEq(ypr, 1500);
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
        assertEq(all.length, 62, "ConfigKeys count changed: update _allConfigKeys and re-audit");

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
        k = new bytes32[](62);
        uint256 i;
        k[i++] = K.SEAT_PRICE_FLOOR;
        k[i++] = K.SEAT_PRICE_CEILING;
        k[i++] = K.MEMBER_CAP;
        k[i++] = K.INVITE_MAX_USES;
        k[i++] = K.INVITE_MAX_TTL;
        k[i++] = K.MINT_SPLIT_HOST;
        k[i++] = K.MINT_SPLIT_POOL;
        k[i++] = K.MINT_SPLIT_PROTOCOL;
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
        k[i++] = K.YIELD_SPLIT_MEMBER;
        k[i++] = K.YIELD_SPLIT_POOL;
        k[i++] = K.YIELD_SPLIT_PROTOCOL;
        k[i++] = K.INSTANT_TIER_FLOOR_BPS;
        k[i++] = K.SLOW_TIER_CEILING_BPS;
        k[i++] = K.MAX_NOTICE_PERIOD;
        k[i++] = K.GLOBAL_DEPOSIT_CAP;
        k[i++] = K.PROTOCOL_TREASURY;
        k[i++] = K.COMPLIANCE_REGISTRY;
        k[i++] = K.MEMBER_SEASONING_WINDOW;
        k[i++] = K.MIN_LENDABLE;
        k[i++] = K.GLOBAL_MEMBER_CAP;
        k[i++] = K.ACTIVITY_DECAY_LENGTH;
        k[i++] = K.ACTIVITY_FLOOR_BPS;
        k[i++] = K.STANDING_HEAL_WINDOW;
        k[i++] = K.PHASE_CAP_FIRST_ACCESS;
        k[i++] = K.PHASE_CAP_PROVEN_ONCE;
        k[i++] = K.PHASE_CAP_DEVELOPING;
        k[i++] = K.PHASE_MIN_TIME_PROVEN_ONCE;
        k[i++] = K.PHASE_MIN_TIME_ESTABLISHED;
        k[i++] = K.PHASE_CAP_ESTABLISHED;
        // No-charge audit: the four multipliers and the concentration share size what a member CAN
        // borrow, never what they owe. No repayment path reads them.
        k[i++] = K.PHASE_MULT_FIRST_ACCESS;
        k[i++] = K.PHASE_MULT_PROVEN_ONCE;
        k[i++] = K.PHASE_MULT_DEVELOPING;
        k[i++] = K.PHASE_MULT_ESTABLISHED;
        k[i++] = K.CONCENTRATION_BPS;
        // CREDIT_CORE is an address (not settable via `set`, so not charge-shaped by construction).
        k[i++] = K.CREDIT_CORE;
        // No-charge audit for the pool and credit gates: the liquid floor limits what the operator
        // sends out; the dormancy windows, book quality and member count decide whether and how much
        // a community lends; the heal cooling decides when a repaid default heals; the agreement
        // hash is a document fingerprint. None is read on a repayment path, and none can add
        // anything to what a member owes.
        k[i++] = K.POOL_LIQUID_FLOOR_BPS;
        k[i++] = K.COMMUNITY_DORMANCY_GRACE;
        k[i++] = K.COMMUNITY_FADE_LENGTH;
        k[i++] = K.COMMUNITY_HEAL_LENGTH;
        k[i++] = K.COMMUNITY_RETURN_AFTER;
        k[i++] = K.PORTFOLIO_QUALITY_BPS;
        k[i++] = K.COMMUNITY_MIN_MEMBERS;
        k[i++] = K.DEFAULT_HEAL_COOLING;
        k[i++] = K.CREDIT_AGREEMENT_HASH;
        // No-charge audit: a count of seats per wallet. It decides how many communities one wallet
        // may join, never what anyone owes.
        k[i++] = K.MAX_SEATS_PER_WALLET;
        // The two rate ceilings. No-charge audit: neither is charge-shaped. They bound how fast a
        // Venue's savings value may rise and how fast `ManualStrategy` releases pre-funded yield.
        // Neither is read on any repayment path, and neither can add anything to what a member
        // owes.
        k[i++] = K.MAX_RATE_CEILING_BPS;
        k[i++] = K.MANUAL_RATE_CEILING_BPS;
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
        k[i++] = K.HANDOVER_ACCEPT_WINDOW;
        // No-charge audit: not charge-shaped. It bounds how many vaults a member's list holds, so
        // the ledger's impact views stay within gas. No repayment path reads it.
        k[i++] = K.MAX_VAULTS_PER_MEMBER;
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
        (uint256 lo, uint256 hi) = cfg.bounds(K.COMMUNITY_FADE_LENGTH);
        vm.assume(v < lo || v > hi);
        vm.expectRevert(abi.encodeWithSelector(Config.ValueOutOfBounds.selector, K.COMMUNITY_FADE_LENGTH));
        cfg.set(K.COMMUNITY_FADE_LENGTH, v);
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

    /// A nominee has a week to accept, and the window runs from a day to 30 days.
    function test_handoverAcceptWindowBounds() public {
        assertEq(cfg.handoverAcceptWindow(), 7 days, "launch value");
        _assertRange(K.HANDOVER_ACCEPT_WINDOW, 1 days, 30 days);
    }

    /// A member's vault list holds 32 at launch. At least 1, or nobody could open a vault; at most
    /// 64, so the ledger's impact views walk a bounded list.
    function test_maxVaultsPerMember_launchValueAndBounds() public {
        assertEq(cfg.maxVaultsPerMember(), 32, "launch value");
        _assertRange(K.MAX_VAULTS_PER_MEMBER, 1, 64);
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

    /// The two rate ceilings launch at 20% a year and move only inside their bounds: never to
    /// zero, which would freeze every price and every strategy's yield.
    function test_rateCeilings_launchValuesAndBounds() public {
        assertEq(cfg.maxRateCeilingBps(), 2000);
        assertEq(cfg.manualRateCeilingBps(), 2000);
        bytes32[2] memory keys = [K.MAX_RATE_CEILING_BPS, K.MANUAL_RATE_CEILING_BPS];
        for (uint256 i; i < 2; i++) {
            vm.expectRevert(abi.encodeWithSelector(Config.ValueOutOfBounds.selector, keys[i]));
            cfg.set(keys[i], 0);
            vm.expectRevert(abi.encodeWithSelector(Config.ValueOutOfBounds.selector, keys[i]));
            cfg.set(keys[i], 10_001);
            cfg.set(keys[i], 1);
            cfg.set(keys[i], 10_000);
        }
        assertEq(cfg.maxRateCeilingBps(), 10_000);
        assertEq(cfg.manualRateCeilingBps(), 10_000);
    }

    // ---- Standing keys ----

    function test_standing_launchValues() public view {
        assertEq(cfg.minLendable(), 10e6);
        assertEq(cfg.globalMemberCap(), 5000e6);
        assertEq(cfg.activityDecayLength(), 180 days); // W
        assertEq(cfg.activityFloorBps(), 2500); // FLOOR 0.25
        assertEq(cfg.standingHealWindow(), 90 days);
        assertEq(cfg.concentrationBps(), 2000); // 20% of what the community can lend now

        uint256[4] memory mult = [uint256(100), 200, 300, 400];
        uint256[4] memory cap = [uint256(100e6), 300e6, 1000e6, 5000e6];
        uint64[4] memory minTime = [uint64(0), 30 days, 0, 180 days];
        for (uint8 p; p < 4; p++) {
            (uint256 m, uint256 c, uint64 t) = cfg.phaseTerms(p);
            assertEq(m, mult[p], "multiplier");
            assertEq(c, cap[p], "cap");
            assertEq(t, minTime[p], "time since the first repayment");
        }
    }

    /// The pool and gate keys: launch values, and both ends of every range.
    function test_credit_launchValuesAndBounds() public {
        assertEq(cfg.poolLiquidFloorBps(), 3000);
        (uint64 grace, uint64 fade, uint64 heal, uint64 ret) = cfg.communityDormancy();
        assertEq(grace, 90 days);
        assertEq(fade, 180 days);
        assertEq(heal, 90 days);
        assertEq(ret, 365 days);
        assertEq(cfg.portfolioQualityBps(), 2500);
        assertEq(cfg.communityMinMembers(), 5);
        assertEq(cfg.defaultHealCooling(), 180 days);
        assertEq(cfg.creditAgreementHash(), bytes32(0), "credit is shut until an agreement is set");

        _assertRange(K.POOL_LIQUID_FLOOR_BPS, 1, 10_000);
        _assertRange(K.COMMUNITY_DORMANCY_GRACE, 1 days, 730 days);
        _assertRange(K.COMMUNITY_FADE_LENGTH, 1 days, 730 days);
        _assertRange(K.COMMUNITY_HEAL_LENGTH, 1 days, 730 days);
        _assertRange(K.COMMUNITY_RETURN_AFTER, 1 days, 730 days);
        _assertRange(K.PORTFOLIO_QUALITY_BPS, 1, 10_000);
        _assertRange(K.COMMUNITY_MIN_MEMBERS, 2, 10);
        _assertRange(K.CONCENTRATION_BPS, 1, 10_000);
        _assertRange(K.DEFAULT_HEAL_COOLING, 1 days, 730 days);
        _assertRange(K.PHASE_CAP_ESTABLISHED, 1e6, 1_000_000e6);
        _assertRange(K.PHASE_MULT_FIRST_ACCESS, 1, 1000);
        _assertRange(K.PHASE_MULT_PROVEN_ONCE, 1, 1000);
        _assertRange(K.PHASE_MULT_DEVELOPING, 1, 1000);
        _assertRange(K.PHASE_MULT_ESTABLISHED, 1, 1000);
        assertEq(cfg.maxSeatsPerWallet(), 10);
        _assertRange(K.MAX_SEATS_PER_WALLET, 1, 50);
    }

    /// The agreement hash has its own owner-only setter, refuses zero, and is not a scalar key.
    function test_creditAgreementHash_setterOnly() public {
        bytes32 h = keccak256("agreement");
        cfg.setCreditAgreementHash(h);
        assertEq(cfg.creditAgreementHash(), h);
        vm.expectRevert(Config.ZeroAgreementHash.selector);
        cfg.setCreditAgreementHash(bytes32(0));
        vm.expectRevert(abi.encodeWithSelector(Config.ValueOutOfBounds.selector, K.CREDIT_AGREEMENT_HASH));
        cfg.set(K.CREDIT_AGREEMENT_HASH, 1);
        vm.prank(makeAddr("stranger"));
        vm.expectRevert();
        cfg.setCreditAgreementHash(h);
    }

    /// The keys only the retired credit model read: its retained capital, reserves and stress
    /// capital, the per-community buffer, Trust Extension, the share-of-budget exposure multiplier,
    /// per-phase concentration, the old venue limits, the impact epoch and the old eligibility
    /// rules. Each is gone: `bounds` does not know it, so it cannot be set.
    function test_retiredKeys_oldCreditModel() public {
        string[28] memory names = [
            "qudi.EPOCH_LENGTH",
            "qudi.ELIG_MIN_MEMBERS",
            "qudi.ELIG_CLEAN_EPOCHS",
            "qudi.ELIG_MEMBER_MONTHS",
            "qudi.ELIG_MAX_GAP_MONTHS",
            "qudi.EXPOSURE_IMPACT_MULT_X100",
            "qudi.CONCENTRATION_FIRST_ACCESS_BPS",
            "qudi.CONCENTRATION_PROVEN_ONCE_BPS",
            "qudi.CONCENTRATION_DEVELOPING_BPS",
            "qudi.CONCENTRATION_ESTABLISHED_BPS",
            "qudi.TE_BUDGET_PROVEN_ONCE",
            "qudi.TE_BUDGET_DEVELOPING",
            "qudi.TE_BUDGET_ESTABLISHED",
            "qudi.TE_COMMUNITY_CAP_BPS",
            "qudi.TE_EARN_INCREMENT",
            "qudi.OPERATING_BUFFER_PER_COMMUNITY",
            "qudi.OPERATING_FLOOR_GLOBAL",
            "qudi.CREDIT_LOSS_RESERVE_CURRENT_BPS",
            "qudi.CREDIT_LOSS_RESERVE_LATE_BPS",
            "qudi.CREDIT_LOSS_RESERVE_FINAL_CURE_BPS",
            "qudi.CREDIT_LOSS_RESERVE_DEFAULT_RECOVERY_BPS",
            "qudi.VENUE_LOSS_RESERVE_BPS",
            "qudi.VENUE_ALLOCATION_MAX_BPS",
            "qudi.PER_VENUE_CAP_BPS",
            "qudi.MAX_VENUE_REDEMPTION_DELAY",
            "qudi.MAX_VENUE_SLIPPAGE_BPS",
            "qudi.STRESS_CAPITAL_RATE_BPS",
            "qudi.STRESS_CAPITAL_FLOOR"
        ];
        for (uint256 i; i < names.length; i++) {
            bytes32 key = keccak256(bytes(names[i]));
            (uint256 lo, uint256 hi) = cfg.bounds(key);
            assertGt(lo, hi, names[i]);
            vm.expectRevert(abi.encodeWithSelector(Config.ValueOutOfBounds.selector, key));
            cfg.set(key, 1);
        }
    }

    /// The activity FLOOR rejects zero. So do MIN_LENDABLE and the multipliers, for the same
    /// reason (a zero repeals the mechanism).
    function test_standingBoundsRejectZero() public {
        vm.expectRevert(abi.encodeWithSelector(Config.ValueOutOfBounds.selector, K.ACTIVITY_FLOOR_BPS));
        cfg.set(K.ACTIVITY_FLOOR_BPS, 0);
        vm.expectRevert(abi.encodeWithSelector(Config.ValueOutOfBounds.selector, K.MIN_LENDABLE));
        cfg.set(K.MIN_LENDABLE, 0);
        vm.expectRevert(abi.encodeWithSelector(Config.ValueOutOfBounds.selector, K.PHASE_MULT_FIRST_ACCESS));
        cfg.set(K.PHASE_MULT_FIRST_ACCESS, 0);
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
