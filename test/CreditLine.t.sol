// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.30;

import {Ownable} from "openzeppelin-contracts/contracts/access/Ownable.sol";
import {Community} from "../src/Community.sol";
import {ICreditCore} from "../src/interfaces/ICreditCore.sol";
import {ICreditStanding} from "../src/interfaces/ICreditStanding.sol";
import {ILedger} from "../src/interfaces/ILedger.sol";
import {Ledger} from "../src/Ledger.sol";
import {ConfigKeys as K} from "../src/ConfigKeys.sol";
import {CreditFixture} from "./helpers/CreditFixture.sol";
import {VenueIds} from "./helpers/VenueIds.sol";
import {MockImpactSource, RevertingImpactSource} from "./mocks/MockImpactSource.sol";

/// The line is the smallest of four limits: the member's impact in this community times the phase
/// multiplier, activity and conduct; the phase cap; 20% of what the community can lend now; and
/// $5,000. Impact comes only from registered sources, and only while the member's seat is Active.
contract CreditLineTest is CreditFixture {
    Community a;
    uint256 aId;
    address[] pa;

    function setUp() public override {
        super.setUp();
        (a, aId, pa) = _community(100e6, 6);
        _season();
        // A large balance, so the 20% term binds only where a test makes it.
        _grant(aId, 100_000e6);
    }

    // ---- proof 11: the registry ----

    /// A third source registered through the owner adds to the line with no change to either
    /// credit contract, and removing it takes it away.
    function test_proof11_aThirdSourceAddsToTheLineAndRemovingItTakesItAway() public {
        address m = pa[1];
        assertEq(_line(aId, m), 40e6, "the seat leg alone");

        MockImpactSource third = new MockImpactSource();
        third.setImpact(aId, m, 25e6);
        standing.addImpactSource(address(third));
        assertEq(standing.impactOf(aId, m), 65e6);
        assertEq(_line(aId, m), 65e6, "the third source counts");

        standing.removeImpactSource(address(third));
        assertEq(_line(aId, m), 40e6, "and stops counting once removed");
        assertEq(standing.impactSources().length, 2);
    }

    function test_proof11_onlyTheOwnerChangesTheRegistry() public {
        MockImpactSource third = new MockImpactSource();
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger));
        standing.addImpactSource(address(third));
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger));
        standing.removeImpactSource(address(seatSource));

        vm.expectRevert(ICreditStanding.DuplicateImpactSource.selector);
        standing.addImpactSource(address(seatSource));
        vm.expectRevert(ICreditStanding.UnknownImpactSource.selector);
        standing.removeImpactSource(address(third));
        vm.expectRevert(ICreditStanding.ZeroAddress.selector);
        standing.addImpactSource(address(0));
    }

    /// A source that reverts counts for nothing and blocks nothing.
    function test_proof11_aBrokenSourceCountsZero() public {
        standing.addImpactSource(address(new RevertingImpactSource()));
        assertEq(_line(aId, pa[1]), 40e6);
        _draw(pa[1], aId, 40e6);
    }

    /// A Suspended seat counts 0 in every source: the seat leg, the yield leg and a third source.
    function test_proof11_aSuspendedSeatCountsZeroInEverySource() public {
        address m = pa[1];
        _save(aId, m, 1_000e6);
        _gain(20e6, 60 days);
        _useExtra();
        extra.setImpact(aId, m, 25e6);
        assertEq(seatSource.impactOf(aId, m), 40e6);
        assertGt(yieldSource.impactOf(aId, m), 0);
        assertGt(standing.impactOf(aId, m), 65e6);

        vm.prank(pa[0]);
        a.proposeRemoval(m);
        uint256 voteId = a.activeRemovalVoteId(m);
        for (uint256 i = 2; i < pa.length; i++) {
            vm.prank(pa[i]);
            a.castVote(voteId, true);
        }
        vm.warp(block.timestamp + 7 days + 1);
        a.executeRemoval(m);

        assertEq(seatSource.impactOf(aId, m), 0, "seat leg");
        assertEq(yieldSource.impactOf(aId, m), 0, "yield leg");
        assertEq(standing.impactOf(aId, m), 0, "every source, the third included");
        assertEq(_line(aId, m), 0);
    }

    /// A Left seat counts 0 in every source too. A leaver's yield impact comes from a shared vault
    /// here, because a member cannot leave while holding a personal one.
    function test_proof11_aLeftSeatCountsZeroInEverySource() public {
        address m = pa[1];
        Ledger l = _ledger(aId);
        vm.prank(pa[0]);
        uint256 shared =
            l.createVault(ILedger.VaultParams({venueId: VenueIds.FLEX, shared: true, lockedUntil: 0, name: "pot"}));
        usdc.mint(m, 1_000e6);
        vm.startPrank(m);
        usdc.approve(address(l), 1_000e6);
        l.deposit(shared, 1_000e6);
        vm.stopPrank();
        _gain(20e6, 60 days);
        _useExtra();
        extra.setImpact(aId, m, 25e6);
        assertGt(yieldSource.impactOf(aId, m), 0);

        vm.prank(m);
        a.forfeit();

        assertEq(seatSource.impactOf(aId, m), 0, "seat leg");
        assertEq(yieldSource.impactOf(aId, m), 0, "yield leg");
        assertEq(standing.impactOf(aId, m), 0, "every source");
    }

    /// Impact counts only in the community it was earned in.
    function test_proof11_impactCountsOnlyInItsOwnCommunity() public {
        (, uint256 bId,) = _community(50e6, 5);
        _join(Community(factory.communityAt(bId)), pa[1]);
        assertEq(seatSource.impactOf(bId, pa[1]), 20e6, "B's seat, B's impact");
        assertEq(seatSource.impactOf(aId, pa[1]), 40e6);
        assertEq(Community(factory.communityAt(bId)).impactOf(aId, pa[1]), 0, "B does not answer for A");
    }

    // ---- proof 12: the line ----

    /// First Access is 1x: $30 of impact is a $30 line.
    function test_proof12_firstAccessIsOneTimesImpact() public {
        (, uint256 bId, address[] memory pb) = _community(75e6, 6);
        _season();
        _grant(bId, 10_000e6);
        assertEq(standing.impactOf(bId, pb[1]), 30e6, "40% of a $75 seat");
        assertEq(_line(bId, pb[1]), 30e6);
        assertEq(uint8(standing.phaseOf(pb[1])), uint8(ICreditCore.Phase.FirstAccess));
    }

    /// One advance repaid and 30 days since it doubles the line. Before the 30 days it does not.
    function test_proof12_oneRepaidAndThirtyDaysIsTwoTimes() public {
        (, uint256 bId, address[] memory pb) = _community(75e6, 6);
        _season();
        _grant(bId, 10_000e6);
        address m = pb[1];
        _draw(m, bId, 10e6);
        _repayAll(m);

        vm.warp(block.timestamp + 30 days - 1);
        assertEq(_line(bId, m), 30e6, "still First Access a second early");
        vm.warp(block.timestamp + 1);
        assertEq(uint8(standing.phaseOf(m)), uint8(ICreditCore.Phase.ProvenOnce));
        assertEq(_line(bId, m), 60e6);
        assertTrue(_eligible(bId, m), "a repaid advance is no longer open");
    }

    /// The phase cap binds: $1,000 of impact at First Access is still a $100 line.
    function test_proof12_thePhaseCapBinds() public {
        _useExtra();
        extra.setImpact(aId, pa[1], 1_000e6);
        assertEq(_line(aId, pa[1]), 100e6);
    }

    /// 20% of what the community can lend now binds.
    function test_proof12_twentyPercentOfTheAvailableBalanceBinds() public {
        (, uint256 bId, address[] memory pb) = _community(100e6, 6);
        _season();
        _useExtra();
        extra.setImpact(bId, pb[1], 1_000e6);
        assertEq(_line(bId, pb[1]), 40e6, "20% of $200");
        _draw(pb[2], bId, 40e6);
        assertEq(_line(bId, pb[1]), 32e6, "20% of the $160 left");
    }

    /// The $5,000 member cap binds when it is the smallest term.
    function test_proof12_theGlobalMemberCapBinds() public {
        _useExtra();
        extra.setImpact(aId, pa[1], 1_000e6);
        config.set(K.GLOBAL_MEMBER_CAP, 70e6);
        assertEq(_line(aId, pa[1]), 70e6);
    }

    /// Six repaid advances make a member Established only once 180 days have passed since the
    /// first, not the latest: 4x, with a $5,000 cap.
    function test_proof12_establishedIsFourTimesUpToFiveThousand() public {
        _useExtra();
        // Keep the member's own activity whole, so only the phase moves.
        config.set(K.DORMANCY_GRACE, 365 days);
        address m = pa[1];
        extra.setImpact(aId, m, 1e6);
        _repayTimes(m, 5);
        _keepActive(100 days);
        _repayTimes(m, 1);
        extra.setImpact(aId, m, 250e6);
        assertEq(_line(aId, m), 870e6, "Developing: 3x $290");

        _keepActive(80 days - 1);
        assertEq(uint8(standing.phaseOf(m)), uint8(ICreditCore.Phase.Developing), "a second early");
        _keepActive(1);
        assertEq(uint8(standing.phaseOf(m)), uint8(ICreditCore.Phase.Established), "180 days after the first");
        assertEq(_line(aId, m), 1_160e6, "4x $290");

        extra.setImpact(aId, m, 2_000e6);
        assertEq(_line(aId, m), 5_000e6, "the Established cap");
    }

    /// Five repaid is not six, however long ago the first was.
    function test_proof12_fiveRepaidIsStillDeveloping() public {
        _useExtra();
        config.set(K.DORMANCY_GRACE, 365 days);
        address m = pa[1];
        extra.setImpact(aId, m, 1e6);
        _repayTimes(m, 5);
        _keepActive(365 days);
        assertEq(uint8(standing.phaseOf(m)), uint8(ICreditCore.Phase.Developing));
    }

    /// Developing starts at two repaid advances, with no wait, at 3x.
    function test_proof12_developingAtTwoRepaid() public {
        _useExtra();
        address m = pa[1];
        extra.setImpact(aId, m, 1e6);
        _draw(m, aId, 10e6);
        _repayAll(m);
        _draw(m, aId, 10e6);
        _repayAll(m);
        extra.setImpact(aId, m, 60e6);
        assertEq(uint8(standing.phaseOf(m)), uint8(ICreditCore.Phase.Developing));
        assertEq(_line(aId, m), 300e6, "3x $100, under the $1,000 cap");
    }

    /// $9.99 is not eligible. $10 is.
    function test_proof12_tenDollarsIsTheMinimum() public {
        (Community b, uint256 bId, address[] memory pb) = _community(24_975_000, 6);
        _season();
        _grant(bId, 10_000e6);
        assertEq(_line(bId, pb[1]), 9_990_000);
        assertFalse(_eligible(bId, pb[1]));

        vm.prank(pb[0]);
        b.proposeSeatPrice(25e6);
        _passPriceVote(b, pb);
        address n = _person();
        _join(b, n);
        _season();
        assertEq(_line(bId, n), 10e6);
        assertTrue(_eligible(bId, n));
        _draw(n, bId, 10e6);
    }

    // ---- proof 15: the draw accrues ----

    /// A yield gain since the last accrual is in the line at the moment of the draw, and the draw
    /// itself brings the ledger up to date.
    function test_proof15_aDrawSeesTheYieldGainedSinceTheLastAccrual() public {
        address m = pa[1];
        Ledger l = _ledger(aId);
        _save(aId, m, 1_000e6);
        uint256 peak = l.highWaterPrice(VenueIds.FLEX);
        _gain(20e6, 60 days);

        uint256 yieldImpact = yieldSource.impactOf(aId, m);
        assertApproxEqAbs(yieldImpact, 3e6, 10, "15% of the $20 gain");
        uint256 line = 40e6 + yieldImpact;
        assertEq(_line(aId, m), line);

        _draw(m, aId, line);
        assertGt(l.highWaterPrice(VenueIds.FLEX), peak, "the draw accrued the ledger");
        assertEq(core.obligationOf(m).principal, line);
    }

    // ---- conduct: scars ----

    /// Repaying after the advance went Late leaves a scar at the conduct value of that moment. It
    /// heals back over 90 days, and it follows the member into every community.
    function test_conduct_aLateRepaymentScarsEveryCommunityAndHeals() public {
        _holdMemberActivity();
        address m = pa[1];
        (, uint256 bId,) = _community(100e6, 6);
        _join(Community(factory.communityAt(bId)), m);
        _grant(bId, 10_000e6);
        _season();
        _useExtra();
        extra.setImpact(aId, m, 50e6);
        extra.setImpact(bId, m, 50e6);

        _draw(m, aId, 10e6);
        // Late starts at 65 days and conduct reaches 0 at 155: at 110 days it is exactly half.
        vm.warp(block.timestamp + 110 days);
        _repayAll(m);

        assertEq(_line(aId, m), 45e6, "half of $90 (1x: one repaid, not yet 30 days)");
        assertEq(_line(bId, m), 45e6, "the same scar in B");

        _keepActive(45 days);
        // The scar has healed to 0.75, and 45 days after the first repayment it is Proven Once.
        assertEq(_line(aId, m), 135e6, "0.75 of 2x $90");
    }

    /// Repaying before Late leaves no scar.
    function test_conduct_aPunctualRepaymentLeavesNoScar() public {
        address m = pa[1];
        _useExtra();
        extra.setImpact(aId, m, 20e6);
        _draw(m, aId, 10e6);
        vm.warp(block.timestamp + 65 days - 1);
        _repayAll(m);
        assertEq(_line(aId, m), 60e6);
    }

    /// An open late advance lowers conduct only in the community it was drawn in. Elsewhere the
    /// member is simply not eligible while it is open.
    function test_conduct_anOpenLateAdvanceLowersOnlyItsOwnCommunity() public {
        _holdMemberActivity();
        address m = pa[1];
        (, uint256 bId,) = _community(100e6, 6);
        _join(Community(factory.communityAt(bId)), m);
        _grant(bId, 10_000e6);
        _season();
        _draw(m, aId, 10e6);
        vm.warp(block.timestamp + 110 days);
        assertEq(_line(aId, m), 20e6, "half in A");
        assertEq(_line(bId, m), 40e6, "whole in B");
        assertFalse(_eligible(bId, m));
    }

    /// The yield leg answers only for its own community.
    function test_proof11_theYieldLegAnswersOnlyForItsOwnCommunity() public {
        address m = pa[1];
        _save(aId, m, 1_000e6);
        _gain(20e6, 60 days);
        Ledger l = _ledger(aId);
        assertGt(l.impactOf(aId, m), 0);
        (, uint256 bId,) = _community(0, 1);
        assertEq(l.impactOf(bId, m), 0);
    }

    /// An open advance in Late pulls conduct down while it is still open.
    function test_conduct_anOpenLateAdvanceLowersTheLineShown() public {
        _holdMemberActivity();
        address m = pa[1];
        _draw(m, aId, 10e6);
        assertEq(_line(aId, m), 40e6);
        vm.warp(block.timestamp + 110 days);
        assertEq(_line(aId, m), 20e6, "half conduct at 110 days");
        assertFalse(_eligible(aId, m), "and not eligible with an advance open");
    }

    // ---- activity ----

    /// A member's own activity fades after 90 quiet days, over 180 days down to a quarter, and a
    /// repayment heals it back over 90 days. The fade never cuts to zero.
    function test_activity_fadesAfterAQuietGraceAndHealsOnRepayment() public {
        address m = pa[1];
        _useExtra();
        extra.setImpact(aId, m, 40e6);
        _draw(m, aId, 10e6);
        _repayAll(m);
        assertEq(_line(aId, m), 80e6, "$80 at 1x");

        _keepActive(90 days);
        assertEq(_line(aId, m), 160e6, "Proven Once, and no fade inside the grace");

        _keepActive(90 days);
        assertEq(_line(aId, m), 100e6, "halfway through the fade: 1 - 0.75 x 0.5 = 0.625");

        _keepActive(180 days);
        assertEq(_line(aId, m), 40e6, "floored at a quarter");

        _draw(m, aId, 10e6);
        _repayAll(m);
        _keepActive(45 days);
        assertEq(_line(aId, m), 150e6, "Developing, halfway healed from 0.25: 3x $80 x 0.625");
    }

    // ---- activity from saving and seats ----

    /// A paid seat mint is the member's own activity: 90 quiet days later their line starts to fade,
    /// halfway through the fade it is 0.625 of whole.
    function test_activity_aPaidSeatMintStartsTheMembersClock() public {
        _useExtra();
        extra.setImpact(aId, pa[1], 40e6);
        uint256 whole = _line(aId, pa[1]);
        assertEq(whole, 80e6);
        // The seat was minted before the 14-day seasoning; bring it to 180 days quiet.
        _keepActive(180 days - config.memberSeasoningWindow());
        assertEq(_line(aId, pa[1]), whole * 625 / 1000);
    }

    /// A deposit keeps the member's own activity fresh, and after a quiet spell it heals the fade
    /// over 90 days rather than jumping.
    function test_activity_aDepositIsTheMembersOwnActivity() public {
        _useExtra();
        extra.setImpact(aId, pa[1], 40e6);
        _keepActive(180 days - config.memberSeasoningWindow());
        assertEq(_line(aId, pa[1]), 50e6, "0.625 of $80");

        _save(aId, pa[1], 1e6);
        assertEq(_line(aId, pa[1]), 50e6, "no jump at the deposit");
        _keepActive(45 days);
        assertEq(_line(aId, pa[1]), 65e6, "halfway healed from 0.625: 0.8125 of $80");
    }

    /// Member activity is reported best-effort. A refused report never blocks a deposit or a join.
    function test_activity_aRefusedReportBlocksNeitherADepositNorAJoin() public {
        vm.mockCallRevert(address(core), abi.encodeWithSelector(core.noteActivity.selector), "refused");
        uint256 v = _save(aId, pa[1], 10e6);
        assertEq(_ledger(aId).vaultCapital(v), 10e6, "the deposit landed");
        address n = _person();
        _join(a, n);
        assertTrue(a.isMember(n), "the join landed");
    }

    // ---- helpers ----

    /// Conduct and default tests wait out months with the member idle. Stretch the member's own
    /// activity grace so only the rule under test moves the line.
    function _holdMemberActivity() internal {
        config.set(K.DORMANCY_GRACE, 365 days);
    }

    uint256 internal _keeperVault;

    /// Deposits by a member who is not under test, every 60 days over `time`, so the community
    /// never fades while a test watches one member's own figures.
    function _keepActive(uint256 time) internal {
        if (_keeperVault == 0) _keeperVault = _save(aId, pa[5], 1e6) + 1;
        uint256 end = block.timestamp + time;
        while (block.timestamp + 60 days < end) {
            vm.warp(block.timestamp + 60 days);
            _topUp();
        }
        vm.warp(end);
        _topUp();
    }

    function _topUp() internal {
        Ledger l = _ledger(aId);
        usdc.mint(pa[5], 1e6);
        vm.startPrank(pa[5]);
        usdc.approve(address(l), 1e6);
        l.deposit(_keeperVault - 1, 1e6);
        vm.stopPrank();
    }

    function _repayTimes(address m, uint256 n) internal {
        for (uint256 i; i < n; i++) {
            _draw(m, aId, 10e6);
            _repayAll(m);
        }
    }

    function _passPriceVote(Community b, address[] memory voters) internal {
        uint256 voteId = b.activePriceVoteId();
        for (uint256 i; i < voters.length; i++) {
            vm.prank(voters[i]);
            b.castVote(voteId, true);
        }
        vm.warp(block.timestamp + 7 days + 1);
        b.executeSeatPriceVote();
    }
}
