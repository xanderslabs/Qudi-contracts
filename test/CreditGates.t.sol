// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.30;

import {Community} from "../src/Community.sol";
import {ICreditCore} from "../src/interfaces/ICreditCore.sol";
import {ConfigKeys as K} from "../src/ConfigKeys.sol";
import {CreditFixture} from "./helpers/CreditFixture.sol";

/// What must be true before anyone draws: the community has enough members to be real, its book is
/// not already going bad, it has not closed, and the member has accepted the current Credit
/// Agreement, holds a seasoned Active seat, is not blocked, and has nothing else open.
contract CreditGatesTest is CreditFixture {
    Community a;
    uint256 aId;
    address[] pa;

    function setUp() public override {
        super.setUp();
        (a, aId, pa) = _community(100e6, 6);
        _season();
        _useExtra();
        for (uint256 i = 1; i < pa.length; i++) {
            extra.setImpact(aId, pa[i], 1_000e6);
        }
    }

    // ---- proof 9: gate 8, portfolio quality ----

    /// No new draw while late plus defaulted principal is above 25% of what the community has out.
    /// At exactly 25% the draw goes through.
    function test_proof9_atExactlyTwentyFivePercentLateADrawWorks() public {
        _grant(aId, 10_000e6);
        _draw(pa[1], aId, 25e6);
        vm.warp(block.timestamp + 30 days);
        _draw(pa[2], aId, 75e6);
        vm.warp(block.timestamp + 35 days); // pa[1] is Late, pa[2] is not

        _draw(pa[3], aId, 10e6);
        assertEq(_credit(aId).outstanding, 110e6);
    }

    function test_proof9_justAboveTwentyFivePercentLateADrawReverts() public {
        _grant(aId, 10_000e6);
        _draw(pa[1], aId, 25e6);
        vm.warp(block.timestamp + 30 days);
        _draw(pa[2], aId, 75e6 - 1);
        vm.warp(block.timestamp + 35 days);

        vm.prank(pa[3]);
        vm.expectRevert(ICreditCore.PortfolioQualityBreached.selector);
        core.draw(aId, 10e6, AGREEMENT);
    }

    /// Grace is not late: an advance 60 to 65 days old does not count against the book.
    function test_proof9_graceIsNotLate() public {
        _grant(aId, 10_000e6);
        _draw(pa[1], aId, 50e6);
        vm.warp(block.timestamp + 65 days - 1);
        _draw(pa[2], aId, 10e6);
    }

    /// A defaulted advance counts as well as a late one, whether or not anyone has recorded its
    /// stage yet: the gate reads each stage from its timestamp.
    function test_proof9_defaultCountsWithoutBeingMaterialized() public {
        _grant(aId, 10_000e6);
        _draw(pa[1], aId, 30e6);
        vm.warp(block.timestamp + 155 days);
        // Let pa[2] draw past the gate, so the only bad advance is the defaulted one.
        config.set(K.PORTFOLIO_QUALITY_BPS, 10_000);
        _draw(pa[2], aId, 60e6);
        config.set(K.PORTFOLIO_QUALITY_BPS, 2500);
        assertEq(uint8(core.obligationOf(pa[1]).stage), uint8(ICreditCore.Stage.DefaultRecovery));
        vm.prank(pa[3]);
        vm.expectRevert(ICreditCore.PortfolioQualityBreached.selector);
        core.draw(aId, 10e6, AGREEMENT);
    }

    /// Repaying the late advance clears the gate.
    function test_proof9_repayingTheLateAdvanceClearsTheGate() public {
        _grant(aId, 10_000e6);
        _draw(pa[1], aId, 50e6);
        vm.warp(block.timestamp + 30 days);
        _draw(pa[2], aId, 50e6);
        vm.warp(block.timestamp + 35 days);
        vm.prank(pa[3]);
        vm.expectRevert(ICreditCore.PortfolioQualityBreached.selector);
        core.draw(aId, 10e6, AGREEMENT);

        _repayAll(pa[1]);
        _draw(pa[3], aId, 10e6);
    }

    /// An empty book passes: the first draw in a community has nothing to compare against.
    function test_proof9_anEmptyBookPasses() public {
        assertEq(_credit(aId).outstanding, 0);
        _draw(pa[1], aId, 10e6);
    }

    // ---- proof 10: gate 4, community size ----

    /// Credit opens at five Active seasoned seats. Four is not enough.
    function test_proof10_fourSeasonedMembersCannotDrawFiveCan() public {
        (Community b, uint256 bId, address[] memory pb) = _community(100e6, 4);
        _season();
        extra.setImpact(bId, pb[1], 1_000e6);
        assertEq(b.seasonedCount(), 4);

        vm.prank(pb[1]);
        vm.expectRevert(ICreditCore.TooFewMembers.selector);
        core.draw(bId, 10e6, AGREEMENT);

        _join(b, _person());
        _season();
        assertEq(b.seasonedCount(), 5);
        _draw(pb[1], bId, 10e6);
    }

    /// A seat counts only once it is seasoned, and stops counting when it leaves.
    function test_proof10_unseasonedAndDepartedSeatsDoNotCount() public {
        (Community b, uint256 bId, address[] memory pb) = _community(100e6, 5);
        _season();
        extra.setImpact(bId, pb[1], 1_000e6);
        vm.prank(pb[4]);
        b.forfeit();
        assertEq(b.seasonedCount(), 4);
        _join(b, _person());
        assertEq(b.seasonedCount(), 4, "the new seat is not seasoned yet");

        vm.prank(pb[1]);
        vm.expectRevert(ICreditCore.TooFewMembers.selector);
        core.draw(bId, 10e6, AGREEMENT);
    }

    // ---- proof 13: the Credit Agreement ----

    /// The first draw must carry exactly the hash `Config` holds. A later draw needs no hash.
    function test_proof13_theFirstDrawMustCarryTheCurrentAgreementHash() public {
        address m = pa[1];
        vm.prank(m);
        vm.expectRevert(ICreditCore.WrongAgreement.selector);
        core.draw(aId, 10e6, keccak256("an older agreement"));

        vm.prank(m);
        vm.expectRevert(ICreditCore.WrongAgreement.selector);
        core.draw(aId, 10e6, bytes32(0));

        vm.expectEmit(true, true, false, true, address(core));
        emit ICreditCore.Drawn(aId, m, 10e6, uint64(block.timestamp), AGREEMENT);
        _draw(m, aId, 10e6);
        assertTrue(core.standingOf(aId, m).agreementAccepted);

        _repayAll(m);
        vm.prank(m);
        core.draw(aId, 10e6, bytes32(0));
    }

    /// Changing the agreement binds members who have not yet drawn.
    function test_proof13_aNewAgreementBindsTheNextFirstDraw() public {
        bytes32 next = keccak256("qudi credit agreement v2");
        config.setCreditAgreementHash(next);
        vm.prank(pa[1]);
        vm.expectRevert(ICreditCore.WrongAgreement.selector);
        core.draw(aId, 10e6, AGREEMENT);
        vm.prank(pa[1]);
        core.draw(aId, 10e6, next);
    }

    // ---- a closed community ----

    /// Once the members vote to close, nobody can draw there. Repayment stays open.
    function test_aClosedLedgerRefusesDrawsAndStillTakesRepayment() public {
        _draw(pa[1], aId, 20e6);
        _closeByVote();
        assertTrue(_ledger(aId).communityClosed());
        assertFalse(_credit(aId).closed, "the credit account itself is still open");

        vm.prank(pa[2]);
        vm.expectRevert(ICreditCore.CommunityIsClosed.selector);
        core.draw(aId, 10e6, AGREEMENT);

        _repayAll(pa[1]);
        assertFalse(core.hasOpenTab(pa[1]));
    }

    function test_aClosedCreditAccountRefusesDraws() public {
        core.closeCommunity(aId);
        vm.prank(pa[1]);
        vm.expectRevert(ICreditCore.CommunityIsClosed.selector);
        core.draw(aId, 10e6, AGREEMENT);
    }

    // ---- the member's own gates ----

    function test_drawGate_notAMember() public {
        vm.prank(stranger);
        vm.expectRevert(ICreditCore.NotAMember.selector);
        core.draw(aId, 10e6, AGREEMENT);
    }

    function test_drawGate_blocked() public {
        registry.setBlocked(pa[1], true);
        vm.prank(pa[1]);
        vm.expectRevert(ICreditCore.AccountBlocked.selector);
        core.draw(aId, 10e6, AGREEMENT);
    }

    /// A seat must be 14 days old before it draws.
    function test_drawGate_notSeasoned() public {
        address late = _person();
        _join(a, late);
        extra.setImpact(aId, late, 1_000e6);
        vm.warp(block.timestamp + config.memberSeasoningWindow() - 1);
        vm.prank(late);
        vm.expectRevert(ICreditCore.NotSeasoned.selector);
        core.draw(aId, 10e6, AGREEMENT);
        vm.warp(block.timestamp + 1);
        _draw(late, aId, 10e6);
    }

    /// One advance at a time, across every community.
    function test_drawGate_oneOpenAdvanceAccountWide() public {
        (Community b, uint256 bId,) = _community(100e6, 6);
        _join(b, pa[1]);
        _season();
        extra.setImpact(bId, pa[1], 1_000e6);
        _draw(pa[1], aId, 10e6);
        vm.prank(pa[1]);
        vm.expectRevert(ICreditCore.TabAlreadyOpen.selector);
        core.draw(bId, 10e6, AGREEMENT);
    }

    /// A written-off advance that is still unpaid is still open for this purpose: it is owed.
    function test_drawGate_anUnpaidWriteOffIsStillOpen() public {
        _draw(pa[1], aId, 10e6);
        vm.warp(block.timestamp + 365 days);
        core.finalizeWriteOff(pa[1]);
        assertFalse(core.hasOpenTab(pa[1]));
        vm.prank(pa[1]);
        vm.expectRevert(ICreditCore.TabAlreadyOpen.selector);
        core.draw(aId, 10e6, AGREEMENT);
    }

    function test_drawGate_zeroAmountAndUnknownCommunity() public {
        vm.prank(pa[1]);
        vm.expectRevert(ICreditCore.ZeroAmount.selector);
        core.draw(aId, 0, AGREEMENT);
        vm.prank(pa[1]);
        vm.expectRevert(ICreditCore.UnknownCommunity.selector);
        core.draw(aId + 1, 10e6, AGREEMENT);
    }

    function test_drawGate_notEligibleAndExceedsLine() public {
        extra.setImpact(aId, pa[1], 0);
        // The seat leg alone is $40: 1x at First Access.
        assertEq(_line(aId, pa[1]), 40e6);
        vm.prank(pa[1]);
        vm.expectRevert(ICreditCore.ExceedsLine.selector);
        core.draw(aId, 40e6 + 1, AGREEMENT);

        (, uint256 bId, address[] memory pb) = _community(20e6, 6);
        _season();
        assertEq(_line(bId, pb[1]), 8e6, "a $20 seat gives $8");
        vm.prank(pb[1]);
        vm.expectRevert(ICreditCore.NotEligible.selector);
        core.draw(bId, 8e6, AGREEMENT);
    }

    // ---- helpers ----

    function _closeByVote() internal {
        vm.prank(pa[0]);
        a.proposeClosure();
        uint256 voteId = a.closureVoteId();
        for (uint256 i; i < pa.length; i++) {
            vm.prank(pa[i]);
            a.castVote(voteId, true);
        }
        vm.warp(block.timestamp + 7 days + 1);
        a.executeClosure();
    }
}
