// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.30;

import {Community} from "../src/Community.sol";
import {ICreditCore} from "../src/interfaces/ICreditCore.sol";
import {CreditFixture} from "./helpers/CreditFixture.sol";

/// A community that goes quiet slowly loses what it can lend, never all at once. After 90 days with
/// no seat mint, deposit or draw, the lendable share fades to zero over 180 days. Activity heals it
/// over 90 days from wherever it had reached. After a further 365 days fully faded, anyone may return
/// the balance to Qudi, but only once nothing is out on loan.
contract CreditDormancyTest is CreditFixture {
    Community a;
    uint256 aId;
    address[] pa;
    uint256 lastActive;

    uint256 constant WAD = 1e18;

    function setUp() public override {
        super.setUp();
        (a, aId, pa) = _community(100e6, 6);
        lastActive = block.timestamp; // the last seat leg
        _season();
    }

    function _share() internal view returns (uint256) {
        return _credit(aId).lendableShareWad;
    }

    // ---- proof 8: the fade ----

    function test_proof8_insideTheGraceTheWholeBalanceCanBeLent() public {
        vm.warp(lastActive + 90 days);
        assertEq(_share(), WAD);
        assertEq(_credit(aId).lendable, 200e6);
    }

    /// Ninety days of grace plus half the fade leaves half the balance lendable.
    function test_proof8_halfwayThroughTheFadeHalfTheBalanceCanBeLent() public {
        vm.warp(lastActive + 90 days + 90 days);
        assertEq(_share(), WAD / 2);
        assertEq(_credit(aId).lendable, 100e6);
        assertEq(_credit(aId).allocation, 200e6, "the balance itself is untouched");
    }

    /// The line's concentration term follows the faded amount: 20% of $100, not of $200.
    function test_proof8_theLineFollowsTheFadedAmount() public {
        _useExtra();
        extra.setImpact(aId, pa[1], 1_000e6);
        assertEq(_line(aId, pa[1]), 40e6, "20% of $200");
        vm.warp(lastActive + 180 days);
        assertEq(_line(aId, pa[1]), 20e6, "20% of the $100 still lendable");
    }

    function test_proof8_fullyFadedNothingCanBeLent() public {
        vm.warp(lastActive + 270 days);
        assertEq(_share(), 0);
        vm.prank(pa[1]);
        vm.expectRevert(ICreditCore.ExceedsAvailable.selector);
        core.draw(aId, 10e6, AGREEMENT);
    }

    // ---- proof 8: the heal ----

    /// A deposit is activity. The share climbs back linearly over 90 days from the 50% it had
    /// faded to, never jumping.
    function test_proof8_activityHealsOverNinetyDays() public {
        vm.warp(lastActive + 180 days);
        _save(aId, pa[1], 50e6);
        assertEq(_share(), WAD / 2, "no jump at the moment of activity");

        vm.warp(block.timestamp + 45 days);
        assertEq(_share(), WAD * 3 / 4, "halfway back after 45 days");

        vm.warp(block.timestamp + 45 days);
        assertEq(_share(), WAD, "whole again after 90 days");
    }

    /// A paid seat mint is activity too: its leg arrives in `CreditCore`.
    function test_proof8_aSeatMintIsActivity() public {
        vm.warp(lastActive + 180 days);
        _join(a, _person());
        vm.warp(block.timestamp + 90 days);
        assertEq(_share(), WAD);
    }

    /// So is a draw.
    function test_proof8_aDrawIsActivity() public {
        _useExtra();
        extra.setImpact(aId, pa[1], 1_000e6);
        vm.warp(lastActive + 170 days);
        _draw(pa[1], aId, 10e6);
        vm.warp(block.timestamp + 90 days);
        assertEq(_share(), WAD);
    }

    /// Only the community's own `Ledger` and `Community` may report activity for it.
    function test_proof8_onlyTheCommunitysOwnContractsReportActivity() public {
        (Community b, uint256 bId,) = _community(0, 2);
        vm.prank(stranger);
        vm.expectRevert(ICreditCore.NotCommunityOwnContract.selector);
        core.noteActivity(aId, pa[1]);

        vm.prank(address(_ledger(bId)));
        vm.expectRevert(ICreditCore.NotCommunityOwnContract.selector);
        core.noteActivity(aId, pa[1]);

        vm.prank(address(b));
        vm.expectRevert(ICreditCore.NotCommunityOwnContract.selector);
        core.noteActivity(aId, pa[1]);

        vm.prank(address(a));
        core.noteActivity(aId, pa[1]);
        vm.prank(address(_ledger(aId)));
        core.noteActivity(aId, pa[1]);
    }

    /// A community whose balance only ever came from grants still fades: the first grant starts its
    /// clock.
    function test_proof8_aGrantOnlyCommunityStartsItsClockAtTheFirstGrant() public {
        (, uint256 gId,) = _community(0, 1);
        assertEq(_credit(gId).lastActivityAt, 0, "a free founding seat is no activity");
        _grant(gId, 100e6);
        uint256 granted = block.timestamp;
        assertEq(_credit(gId).lastActivityAt, granted);

        vm.warp(granted + 180 days);
        assertEq(_credit(gId).lendableShareWad, WAD / 2);
        vm.warp(granted + 90 days + 180 days + 365 days);
        core.sweepDormant(gId);
        assertEq(_credit(gId).allocation, 0);
    }

    /// A later grant is not activity: it does not restart a clock that is already running.
    function test_proof8_aLaterGrantIsNotActivity() public {
        vm.warp(lastActive + 180 days);
        _grant(aId, 100e6);
        assertEq(_credit(aId).lastActivityAt, lastActive);
        assertEq(_credit(aId).lendableShareWad, WAD / 2);
    }

    // ---- proof 8: the sweep ----

    /// After 90 + 180 days of fade and 365 more fully faded, anyone may return the balance to Qudi.
    /// Not a second earlier.
    function test_proof8_sweepDormantReturnsTheBalanceAfterTheFullPeriod() public {
        uint256 end = lastActive + 90 days + 180 days + 365 days;
        vm.warp(end - 1);
        vm.prank(stranger);
        vm.expectRevert(ICreditCore.NotDormant.selector);
        core.sweepDormant(aId);

        vm.warp(end);
        uint256 before = _unallocated();
        vm.prank(stranger);
        core.sweepDormant(aId);
        assertEq(_credit(aId).allocation, 0);
        assertEq(_unallocated(), before + 200e6, "the balance is Qudi's unallocated money");
    }

    /// Nothing is swept while an advance in the community is still out.
    function test_proof8_sweepDormantWaitsForEveryAdvance() public {
        _useExtra();
        extra.setImpact(aId, pa[1], 1_000e6);
        _draw(pa[1], aId, 30e6);
        uint256 end = block.timestamp + 90 days + 180 days + 365 days;
        vm.warp(end);

        vm.expectRevert(ICreditCore.CommunityHasDebt.selector);
        core.sweepDormant(aId);

        core.finalizeWriteOff(pa[1]);
        core.sweepDormant(aId);
        assertEq(_credit(aId).allocation, 0, "the loss came out first, then the rest went back");
        assertEq(_unallocated(), 170e6);
    }

    /// A swept community is not closed. New activity starts it again from zero.
    function test_proof8_aSweptCommunityCanStartAgain() public {
        vm.warp(lastActive + 90 days + 180 days + 365 days);
        core.sweepDormant(aId);
        _join(a, _person());
        assertEq(_credit(aId).allocation, 40e6);
        assertEq(_share(), 0, "healing starts from where it was");
        vm.warp(block.timestamp + 90 days);
        assertEq(_share(), WAD);
    }
}
