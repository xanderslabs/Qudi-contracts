// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.30;

import {Community} from "../src/Community.sol";
import {ICreditCore} from "../src/interfaces/ICreditCore.sol";
import {ICreditStanding} from "../src/interfaces/ICreditStanding.sol";
import {DebtMath} from "../src/DebtMath.sol";
import {ConfigKeys as K} from "../src/ConfigKeys.sol";
import {CreditFixture} from "./helpers/CreditFixture.sol";

/// An advance runs a fixed timeline from its draw: Tenor to 60 days, Grace to 65, Late to 95, Final
/// Cure to 155, Default Recovery to 365, then Written Off. The price is 0% throughout. A default is
/// account-wide and disqualifies the impact held at that moment. Repaid in full, it heals after a
/// cooling period and the member starts again at First Access. Unrepaid, it never heals.
contract CreditDefaultTest is CreditFixture {
    Community a;
    uint256 aId;
    address[] pa;
    Community b;
    uint256 bId;
    address m;

    function setUp() public override {
        super.setUp();
        (a, aId, pa) = _community(100e6, 6);
        (b, bId,) = _community(100e6, 6);
        m = pa[1];
        _join(b, m);
        _season();
        _grant(aId, 10_000e6);
        _grant(bId, 10_000e6);
        // These tests wait out long stretches with nobody saving. Keep both communities and the
        // member's own activity from fading, so that only the default moves the line.
        config.set(K.COMMUNITY_DORMANCY_GRACE, 730 days);
        config.set(K.DORMANCY_GRACE, 365 days);
    }

    // ---- the timeline ----

    /// Each boundary instant belongs to the later stage, in seconds.
    function test_stageBoundaries_bothSidesInSeconds() public pure {
        uint64[5] memory bounds = [uint64(60 days), 65 days, 95 days, 155 days, 365 days];
        for (uint8 i; i < 5; i++) {
            assertEq(_stage(bounds[i] - 1), i, "one second before the boundary");
            assertEq(_stage(bounds[i]), i + 1, "at the boundary");
        }
    }

    /// The derived stage matches an independent reading of the timeline at any elapsed time.
    function testFuzz_stageDeriveMatchesIndependentComputation(uint256 elapsed) public pure {
        elapsed = bound(elapsed, 0, 2000 days);
        uint8 expected = elapsed < 60 days
            ? 0
            : elapsed < 65 days ? 1 : elapsed < 95 days ? 2 : elapsed < 155 days ? 3 : elapsed < 365 days ? 4 : 5;
        assertEq(_stage(elapsed), expected);
    }

    /// Credit carries no charge: at any stage, before or after write-off, clearing an advance costs
    /// exactly its principal, and the pool keeps exactly that.
    function testFuzz_settle_repaysExactlyThePrincipalAtEveryStage(uint256 amount, uint256 elapsed) public {
        amount = bound(amount, 1e6, 40e6); // the seat leg alone is a $40 line
        elapsed = bound(elapsed, 0, 800 days);
        _draw(m, aId, amount);
        vm.warp(block.timestamp + elapsed);
        uint256 cashBefore = usdc.balanceOf(address(core));
        usdc.mint(m, amount + 7e6);
        uint256 walletBefore = usdc.balanceOf(m);
        vm.startPrank(m);
        usdc.approve(address(core), amount + 7e6);
        core.settle(amount + 7e6);
        vm.stopPrank();
        assertEq(walletBefore - usdc.balanceOf(m), amount, "the member paid the principal and nothing else");
        assertEq(usdc.balanceOf(address(core)) - cashBefore, amount);
        assertTrue(core.obligationOf(m).closed);
    }

    function test_stageTimeline_followsTheDrawTimestamp() public {
        _draw(m, aId, 20e6);
        uint64 t = core.obligationOf(m).drawTimestamp;
        ICreditCore.ObligationView memory o = core.obligationOf(m);
        assertEq(o.graceAt, t + 60 days);
        assertEq(o.lateAt, t + 65 days);
        assertEq(o.finalCureAt, t + 95 days);
        assertEq(o.defaultRecoveryAt, t + 155 days);
        assertEq(o.writeOffAt, t + 365 days);
        vm.warp(t + 95 days);
        assertEq(uint8(core.obligationOf(m).stage), uint8(ICreditCore.Stage.FinalCure));
    }

    // ---- proof 14: default ----

    /// At day 156 the member is defaulted in every community, and the impact they held at that
    /// moment is disqualified wherever they are seated.
    function test_proof14_atDay156TheMemberIsDefaultedEverywhereWithImpactDisqualified() public {
        _draw(m, aId, 20e6);
        vm.warp(block.timestamp + 156 days);
        assertFalse(standing.isAccountDefaulted(m), "nothing recorded until the stage is touched");
        core.materialize(m);

        assertTrue(standing.isAccountDefaulted(m));
        assertEq(standing.disqualifiedImpactOf(aId, m), 40e6, "A: the seat leg held at default");
        assertEq(standing.disqualifiedImpactOf(bId, m), 40e6, "B too, though nothing happened there");
        assertEq(standing.impactOf(aId, m), 0);
        assertEq(standing.impactOf(bId, m), 0);
        assertEq(_line(aId, m), 0);
        assertEq(_line(bId, m), 0);
        assertFalse(_eligible(bId, m));
    }

    /// Repaid in full, a default heals after 180 days. The member starts again at First Access, and
    /// the impact disqualified at the default stays disqualified.
    function test_proof14_aRepaidDefaultHealsAfterTheCoolingAtFirstAccess() public {
        _repeatRepayments(3);
        assertEq(uint8(standing.phaseOf(m)), uint8(ICreditCore.Phase.Developing));

        _draw(m, aId, 20e6);
        vm.warp(block.timestamp + 156 days);
        core.materialize(m);
        _repayAll(m);
        uint256 healsAt = standing.defaultHealsAt(m);
        assertEq(healsAt, block.timestamp + 180 days);
        assertEq(uint8(standing.phaseOf(m)), uint8(ICreditCore.Phase.FirstAccess), "the repaid count restarts");

        // New impact earned after the default counts; the old does not.
        _useExtra();
        extra.setImpact(bId, m, 25e6);

        vm.warp(healsAt - 1);
        assertTrue(standing.isAccountDefaulted(m), "still cooling a second early");
        assertEq(_line(bId, m), 0);

        vm.warp(healsAt);
        assertFalse(standing.isAccountDefaulted(m));
        assertEq(standing.impactOf(bId, m), 25e6, "only what came after the default");
        assertEq(_line(bId, m), 25e6, "1x at First Access");
        assertTrue(_eligible(bId, m));
        _draw(m, bId, 25e6);

        // The phase clock restarted too: one repayment now is First Access for 30 days, not
        // Proven Once from the old first repayment.
        _repayAll(m);
        assertEq(uint8(standing.phaseOf(m)), uint8(ICreditCore.Phase.FirstAccess));
    }

    /// A written-off advance repaid in full heals the same way.
    function test_proof14_repayingAfterWriteOffAlsoHeals() public {
        _draw(m, aId, 20e6);
        vm.warp(block.timestamp + 365 days);
        core.finalizeWriteOff(m);
        vm.warp(block.timestamp + 400 days);
        _repayAll(m);
        vm.warp(block.timestamp + 180 days);
        assertFalse(standing.isAccountDefaulted(m));
    }

    /// Unrepaid, a default never heals, however long it waits. A part payment does not start the
    /// cooling either.
    function test_proof14_anUnrepaidDefaultNeverHeals() public {
        _draw(m, aId, 20e6);
        vm.warp(block.timestamp + 156 days);
        core.materialize(m);
        _settle(m, 19e6);
        vm.warp(block.timestamp + 365 days);
        core.finalizeWriteOff(m);
        vm.warp(block.timestamp + 10 * 365 days);
        assertTrue(standing.isAccountDefaulted(m));
        assertEq(standing.defaultHealsAt(m), 0);
        assertEq(_line(aId, m), 0);
    }

    /// A write-off that skipped the default crossing still records the default.
    function test_default_aWriteOffRecordsTheDefaultItSkipped() public {
        _draw(m, aId, 20e6);
        vm.warp(block.timestamp + 365 days);
        core.finalizeWriteOff(m);
        assertTrue(standing.isAccountDefaulted(m));
        assertEq(standing.disqualifiedImpactOf(bId, m), 40e6);
    }

    /// Only `CreditCore` records a default, a repayment or a scar.
    function test_default_onlyCreditCoreWritesStanding() public {
        vm.startPrank(stranger);
        vm.expectRevert(ICreditStanding.NotCreditCore.selector);
        standing.recordFormalDefault(aId, m);
        vm.expectRevert(ICreditStanding.NotCreditCore.selector);
        standing.recordDefaultRepaid(m);
        vm.expectRevert(ICreditStanding.NotCreditCore.selector);
        standing.recordRepaid(aId, m);
        vm.expectRevert(ICreditStanding.NotCreditCore.selector);
        standing.recordScar(aId, m, 0);
        vm.stopPrank();
    }

    // ---- settlement ----

    /// Settlement retires principal one to one, and anything paid over the principal comes back.
    function test_settle_overpaymentIsRefundedExactly() public {
        _draw(m, aId, 20e6);
        usdc.mint(m, 30e6);
        uint256 before = usdc.balanceOf(m);
        vm.startPrank(m);
        usdc.approve(address(core), 30e6);
        core.settle(30e6);
        vm.stopPrank();
        assertEq(before - usdc.balanceOf(m), 20e6, "exactly the principal was kept");
        assertTrue(core.obligationOf(m).closed);
        assertEq(_credit(aId).outstanding, 0);
    }

    /// A member who can no longer draw can still repay: settling never checks the seat.
    function test_settle_aMemberWhoLeftCanStillRepay() public {
        _draw(m, bId, 20e6);
        vm.warp(block.timestamp + 365 days);
        core.finalizeWriteOff(m);
        vm.prank(m);
        b.forfeit();
        _repayAll(m);
        assertTrue(core.obligationOf(m).closed);
    }

    function test_settle_noAdvanceReverts() public {
        vm.prank(m);
        vm.expectRevert(ICreditCore.NoOpenTab.selector);
        core.settle(1e6);
        _draw(m, aId, 20e6);
        _repayAll(m);
        vm.prank(m);
        vm.expectRevert(ICreditCore.NoOpenTab.selector);
        core.settle(1e6);
    }

    // ---- write-off ----

    /// Anyone may finalize a write-off, from day 365 and not before, and only once.
    function test_writeOff_exactly365AnyoneCanFinalize() public {
        _draw(m, aId, 20e6);
        vm.warp(block.timestamp + 365 days - 1);
        vm.prank(stranger);
        vm.expectRevert(ICreditCore.NotYetWrittenOff.selector);
        core.finalizeWriteOff(m);

        vm.warp(block.timestamp + 1);
        assertFalse(core.hasOpenTab(m), "past the boundary it is no longer open, recorded or not");
        vm.prank(stranger);
        core.finalizeWriteOff(m);
        assertTrue(core.obligationOf(m).writtenOff);
        vm.expectRevert(ICreditCore.AlreadyWrittenOff.selector);
        core.finalizeWriteOff(m);
    }

    // ---- materialize ----

    /// `materialize` records only the stage the timestamp has already reached. It is a no-op with
    /// nothing open.
    function test_materialize_recordsOnlyWhatTimeHasReached() public {
        core.materialize(m);
        _draw(m, aId, 20e6);
        vm.warp(block.timestamp + 155 days - 1);
        core.materialize(m);
        assertFalse(standing.isAccountDefaulted(m), "one second early");
        vm.warp(block.timestamp + 1);
        core.materialize(m);
        assertTrue(standing.isAccountDefaulted(m));
    }

    /// A repaid advance never moves again: not a stage, not a default, not a write-off.
    function test_materialize_ignoresARepaidAdvance() public {
        _draw(m, aId, 20e6);
        _repayAll(m);
        vm.warp(block.timestamp + 400 days);
        core.materialize(m);
        assertFalse(standing.isAccountDefaulted(m));
        assertFalse(core.obligationOf(m).writtenOff);
        assertEq(_credit(aId).writtenOff, 0);
    }

    // ---- scars, recorded by CreditCore ----

    /// Scar bookkeeping never fails a repayment. With the list full of unhealed scars, a new one is
    /// dropped with an event.
    function test_scarQueueFull_unhealedStaysFullEmitsDroppedNotRevert() public {
        vm.startPrank(address(core));
        for (uint256 i; i < 64; i++) {
            standing.recordScar(aId, m, 5e17);
        }
        vm.expectEmit(true, true, false, true, address(standing));
        emit ICreditStanding.ScarDropped(aId, m, 4e17);
        standing.recordScar(aId, m, 4e17);
        vm.stopPrank();
        assertEq(_line(aId, m), 20e6, "the dropped deeper scar did not apply: half of $40");
    }

    /// Fully healed scars are pruned before the length check, so a new scar still lands.
    function test_scarQueueFull_healedScarsArePrunedSoSettleCloses() public {
        vm.startPrank(address(core));
        for (uint256 i; i < 64; i++) {
            standing.recordScar(aId, m, 5e17);
        }
        vm.warp(block.timestamp + 90 days);
        vm.expectEmit(true, true, false, true, address(standing));
        emit ICreditStanding.ScarRecorded(aId, m, 0);
        standing.recordScar(aId, m, 0);
        vm.stopPrank();
        assertEq(_line(aId, m), 0, "the new scar applies");
    }

    /// The deepest scar wins, whichever came last.
    function test_scars_deepestWinsNotLastWins() public {
        vm.startPrank(address(core));
        standing.recordScar(aId, m, 5e17);
        standing.recordScar(aId, m, 8e17);
        vm.stopPrank();
        assertEq(_line(aId, m), 20e6, "0.5 of $40, not 0.8");
    }

    // ---- helpers ----

    function _stage(uint256 elapsed) internal pure returns (uint8) {
        return DebtMath.deriveStage(elapsed, 60 days, 65 days, 95 days, 155 days, 365 days);
    }

    function _repeatRepayments(uint256 n) internal {
        for (uint256 i; i < n; i++) {
            _draw(m, aId, 10e6);
            _repayAll(m);
        }
    }
}
