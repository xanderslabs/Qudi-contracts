// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.30;

import {LedgerFixture} from "./helpers/LedgerFixture.sol";
import {ILedger} from "../src/interfaces/ILedger.sol";
import {VenueIds} from "./helpers/VenueIds.sol";

/// Every shared-vault vote threshold is "20% of qualifying contributors", and a qualifying
/// contributor is someone who deposited at least $10 at least 14 days
/// before the proposal. `isDepositor` was `_depositorSince[vaultId][member] != 0`: anyone who
/// ever put anything in, at any moment. Quorum therefore sat on a wider base than the design
/// gives, and every shared withdrawal was easier to pass than it reads.
///
/// The seasoning is measured against the proposal's own creation time, never against
/// `block.timestamp`. A member who qualifies today must not thereby qualify for a vote that
/// opened last week.
contract LedgerQualifyingContributorsTest is LedgerFixture {
    uint256 pot;

    function setUp() public {
        setUpLedger();
        pot = _shared(VenueIds.FLEX);
    }

    function _window() internal view returns (uint64 w) {
        (, w) = config.communityVote();
    }

    function _propose(uint256 amount) internal returns (uint256 id) {
        vm.prank(host);
        id = ledger.proposeWithdrawal(pot, payee, amount);
    }

    function _denominator(uint256 proposalId) internal view returns (uint256 n) {
        (,,,,,,, n,) = ledger.proposals(proposalId);
    }

    /// Three contributors over the amount bar and seasoned; one who put in $5 and is not.
    function _threeQualifyingPlusOneDust() internal {
        _deposit(ada, pot, 400e6);
        _deposit(bea, pot, 300e6);
        _deposit(cid, pot, 200e6);
        _deposit(dan, pot, 5e6);
        vm.warp(block.timestamp + 15 days);
    }

    // ---- the amount bar ----

    /// Below $10 is not a qualifying contributor, however long ago the money went in.
    function test_belowTheAmountBar_cannotVote() public {
        _threeQualifyingPlusOneDust();
        uint256 id = _propose(100e6);
        vm.expectRevert(ILedger.NotDepositor.selector);
        vm.prank(dan);
        ledger.voteOnWithdrawal(id, true);
    }

    function test_belowTheAmountBar_isNotCountedInQuorum() public {
        _threeQualifyingPlusOneDust();
        uint256 id = _propose(100e6);
        assertEq(_denominator(id), 3, "the $5 depositor is not part of the electorate");
    }

    /// The bar is cumulative, not per deposit: four dollars and then six is ten.
    function test_theAmountBarIsCumulative() public {
        _deposit(dan, pot, 4e6);
        _deposit(dan, pot, 6e6);
        vm.warp(block.timestamp + 15 days);
        assertTrue(ledger.isDepositor(pot, dan), "$4 plus $6 crosses the $10 bar");
    }

    /// And the clock starts at the crossing, not at the first dollar. dan's first deposit is
    /// 20 days before the proposal, but the one that took him over the bar is 1 day before it.
    function test_theSeasoningClockStartsAtTheCrossing() public {
        _deposit(dan, pot, 4e6);
        vm.warp(block.timestamp + 19 days);
        _deposit(dan, pot, 6e6);
        vm.warp(block.timestamp + 1 days);
        assertFalse(ledger.isDepositor(pot, dan), "seasoning runs from the crossing, not the first dollar");
    }

    // ---- the seasoning bar ----

    /// Over the amount bar but inside the 14 days: still not a qualifying contributor.
    function test_insideTheSeasoningWindow_cannotVote() public {
        _deposit(ada, pot, 400e6);
        _deposit(bea, pot, 300e6);
        _deposit(cid, pot, 200e6);
        vm.warp(block.timestamp + 15 days);
        _deposit(dan, pot, 500e6); // a big deposit, yesterday
        vm.warp(block.timestamp + 1 days);

        uint256 id = _propose(100e6);
        vm.expectRevert(ILedger.NotDepositor.selector);
        vm.prank(dan);
        ledger.voteOnWithdrawal(id, true);
    }

    function test_insideTheSeasoningWindow_isNotCountedInQuorum() public {
        _deposit(ada, pot, 400e6);
        _deposit(bea, pot, 300e6);
        _deposit(cid, pot, 200e6);
        vm.warp(block.timestamp + 15 days);
        _deposit(dan, pot, 500e6);
        vm.warp(block.timestamp + 1 days);

        uint256 id = _propose(100e6);
        assertEq(_denominator(id), 3, "yesterday's $500 buys no vote on today's proposal");
    }

    /// The boundary is half-open, the same shape as the seat seasoning window: the instant the
    /// 14 days elapse, the contributor counts.
    function test_theSeasoningBoundaryIsHalfOpen() public {
        _deposit(dan, pot, 100e6);
        vm.warp(block.timestamp + 14 days - 1);
        assertFalse(ledger.isDepositor(pot, dan), "one second short");
        vm.warp(block.timestamp + 1);
        assertTrue(ledger.isDepositor(pot, dan), "exactly 14 days qualifies");
    }

    /// The bars are measured against the proposal's creation time, not the current block. dan
    /// crosses both bars after the proposal opened; he must not gain a vote on it, and the
    /// denominator it was opened with must not move under it either.
    function test_qualifyingLaterBuysNoVoteOnAnOlderProposal() public {
        _deposit(ada, pot, 400e6);
        _deposit(bea, pot, 300e6);
        _deposit(cid, pot, 200e6);
        vm.warp(block.timestamp + 15 days);
        _deposit(dan, pot, 500e6); // over the amount bar, ten days before the proposal
        vm.warp(block.timestamp + 10 days);

        uint256 id = _propose(100e6);
        assertFalse(ledger.isDepositor(pot, dan), "dan is four days short when the proposal opens");
        assertEq(_denominator(id), 3, "the electorate the proposal opened with");

        // Five more days, so dan is past the 14 and the vote window is still open.
        vm.warp(block.timestamp + 5 days);
        assertTrue(ledger.isDepositor(pot, dan), "qualifying as of today");
        assertEq(_denominator(id), 3, "and the frozen denominator does not move under him");
        vm.expectRevert(ILedger.NotDepositor.selector);
        vm.prank(dan);
        ledger.voteOnWithdrawal(id, true);
    }

    // ---- what the narrower base is for ----

    /// The whole point, end to end. Thirteen members put in $5 each and three put in real
    /// money. On the qualifying electorate the three carry a 20% quorum comfortably. On the old
    /// "anyone who ever deposited" base the denominator is sixteen, 20% of which is 3.2, and
    /// the same three votes fall short: the vote the design passes was failing.
    function test_theDustDepositorsDoNotRaiseTheQuorum() public {
        _deposit(ada, pot, 400e6);
        _deposit(bea, pot, 300e6);
        _deposit(cid, pot, 200e6);
        for (uint256 i; i < 13; i++) {
            address who = makeAddr(string.concat("dust", vm.toString(i)));
            community.setMember(who, true);
            usdc.mint(who, 100e6);
            vm.startPrank(who);
            usdc.approve(address(ledger), type(uint256).max);
            ledger.deposit(pot, 5e6);
            vm.stopPrank();
        }
        vm.warp(block.timestamp + 15 days);

        uint256 id = _propose(100e6);
        assertEq(_denominator(id), 3, "sixteen depositors, three of them qualifying");

        address[3] memory yes = [ada, bea, cid];
        for (uint256 i; i < 3; i++) {
            vm.prank(yes[i]);
            ledger.voteOnWithdrawal(id, true);
        }
        vm.warp(block.timestamp + _window() + 1);
        vm.prank(ada);
        ledger.executeWithdrawal(id);
        assertEq(usdc.balanceOf(payee), 1_000_000e6 + 100e6, "the vote the design passes, passes");
    }
}
