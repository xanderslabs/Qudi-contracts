// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.30;

import {LedgerFixture} from "./helpers/LedgerFixture.sol";
import {ILedger} from "../src/interfaces/ILedger.sol";
import {VenueIds} from "./helpers/VenueIds.sol";
import {ProposalStatus} from "../src/VaultStatus.sol";

/// A shared vault pays out only by a headcount vote. The host asks for a fixed amount to a fixed
/// recipient; the members counted at the request decide; a passed request pays the recipient
/// directly.
contract LedgerSharedPayoutTest is LedgerFixture {
    uint256 pot;
    uint64 window;

    function setUp() public {
        setUpLedger();
        (, window) = config.communityVote();
        pot = _shared(VenueIds.FLEX);
    }

    /// Each of `who` puts `amount` in, then the deposits season.
    function _fund(address[] memory who, uint256 amount) internal {
        for (uint256 i; i < who.length; i++) {
            _deposit(who[i], pot, amount);
        }
        vm.warp(block.timestamp + 15 days);
    }

    function _people(uint256 n) internal view returns (address[] memory p) {
        address[6] memory all = [ada, bea, cid, dan, eve, fay];
        p = new address[](n);
        for (uint256 i; i < n; i++) {
            p[i] = all[i];
        }
    }

    function _status(uint256 id) internal view returns (uint8) {
        return ledger.payoutStatus(id);
    }

    // ---- proof 11: the headcount ----

    /// Excluded: a depositor under $10, one whose first deposit was 13 days before the request, the
    /// recipient, and a frozen member. Counted: a member who clears every bar.
    function test_proof11_theHeadcountCountsOnlyQualifyingMembers() public {
        _deposit(ada, pot, 9_999_999); // one cent-fraction under $10
        _deposit(cid, pot, 50e6); // will be the recipient
        _deposit(dan, pot, 50e6); // will be frozen
        _deposit(eve, pot, 50e6); // qualifies
        vm.warp(block.timestamp + 1 days);
        _deposit(bea, pot, 50e6); // first deposit 13 days before the request
        vm.warp(block.timestamp + 13 days);
        community.freeze(dan);

        uint256 id = _propose(pot, cid, 10e6);
        ILedger.Payout memory p = ledger.payouts(id);
        assertEq(p.headcount, 1, "only eve counts");
        assertTrue(ledger.isCounted(id, eve));
        assertFalse(ledger.isCounted(id, ada), "under $10");
        assertFalse(ledger.isCounted(id, bea), "first deposit 13 days before");
        assertFalse(ledger.isCounted(id, cid), "the recipient");
        assertFalse(ledger.isCounted(id, dan), "frozen");

        for (uint256 i; i < 4; i++) {
            address who = [ada, bea, cid, dan][i];
            vm.expectRevert(ILedger.NotCounted.selector);
            vm.prank(who);
            ledger.voteOnWithdrawal(id, true);
        }
    }

    /// The bars are on the total put in and on the first deposit: two deposits that together reach
    /// $10 count, and so does a member whose first deposit is exactly 14 days before.
    function test_proof11_theAmountIsCumulativeAndFourteenDaysIsEnough() public {
        _deposit(ada, pot, 6e6);
        _deposit(bea, pot, 20e6);
        vm.warp(block.timestamp + 10 days);
        _deposit(ada, pot, 4e6);
        vm.warp(block.timestamp + 4 days);
        uint256 id = _propose(pot, payee, 1e6);
        assertTrue(ledger.isCounted(id, ada), "$6 then $4 is $10");
        assertTrue(ledger.isCounted(id, bea), "first deposit exactly 14 days before");
    }

    /// A member who is not seasoned, or not an Active seat, is not counted.
    function test_proof11_anUnseasonedOrDepartedDepositorIsNotCounted() public {
        _fund(_people(3), 50e6);
        community.setSeasoned(ada, false);
        community.setMember(bea, false);
        community.setSeasoned(bea, false);
        uint256 id = _propose(pot, payee, 1e6);
        assertEq(ledger.payouts(id).headcount, 1);
        assertTrue(ledger.isCounted(id, cid));
    }

    /// The headcount is fixed at the request. Someone who qualifies later has no vote on it.
    function test_proof11_theHeadcountIsASnapshot() public {
        _fund(_people(3), 50e6);
        uint256 id = _propose(pot, payee, 10e6);
        _deposit(dan, pot, 50e6);
        vm.warp(block.timestamp + 5 days);
        assertEq(ledger.payouts(id).headcount, 3);
        vm.expectRevert(ILedger.NotCounted.selector);
        _vote(dan, id, true);
    }

    // ---- proof 12: the bar ----

    function test_proof12_headcountFive_threeYesPasses() public {
        _fund(_people(5), 20e6);
        uint256 id = _propose(pot, payee, 10e6);
        assertEq(ledger.payouts(id).headcount, 5);
        _vote(ada, id, true);
        _vote(bea, id, true);
        _vote(cid, id, false);
        assertEq(_status(id), ProposalStatus.LIVE);
        _vote(dan, id, true);
        assertEq(_status(id), ProposalStatus.PASSED, "three yes of five passes");
    }

    function test_proof12_headcountFive_twoYesFails() public {
        _fund(_people(5), 20e6);
        uint256 id = _propose(pot, payee, 10e6);
        _vote(ada, id, true);
        _vote(bea, id, true);
        vm.warp(block.timestamp + window + 1);
        assertEq(_status(id), ProposalStatus.FAILED, "two yes of five fails; non-voters count as no");
        vm.expectRevert(ILedger.NotPassed.selector);
        ledger.executeWithdrawal(id);
        assertEq(ledger.earmarkedUnits(pot), 0, "a failed request releases the earmark");
    }

    /// Two yes of three is over half, and still short of the floor of three yes votes.
    function test_proof12_headcountThree_twoYesIsNotEnough() public {
        _fund(_people(3), 20e6);
        uint256 id = _propose(pot, payee, 10e6);
        _vote(ada, id, true);
        _vote(bea, id, true);
        assertEq(_status(id), ProposalStatus.LIVE, "over half, but under three yes votes");
        _vote(cid, id, true);
        assertEq(_status(id), ProposalStatus.PASSED);
    }

    function test_proof12_headcountTwo_twoYesPasses() public {
        _fund(_people(2), 20e6);
        uint256 id = _propose(pot, payee, 10e6);
        assertEq(ledger.payouts(id).headcount, 2);
        _vote(ada, id, true);
        assertEq(_status(id), ProposalStatus.LIVE);
        _vote(bea, id, true);
        assertEq(_status(id), ProposalStatus.PASSED, "under 3 counted needs all of them");
    }

    function test_proof12_headcountTwo_oneYesFails() public {
        _fund(_people(2), 20e6);
        uint256 id = _propose(pot, payee, 10e6);
        _vote(ada, id, true);
        _vote(bea, id, false);
        vm.warp(block.timestamp + window + 1);
        assertEq(_status(id), ProposalStatus.FAILED);
    }

    /// With nobody counted, nobody could vote, so the request is refused outright. It earmarks
    /// nothing and starts no cooldown: once a depositor qualifies, the host may ask at once.
    function test_proof12_headcountZeroIsRefused() public {
        _deposit(ada, pot, 20e6); // not yet seasoned as a depositor
        vm.expectRevert(ILedger.NoHeadcount.selector);
        _propose(pot, payee, 10e6);
        assertEq(ledger.earmarkedUnits(pot), 0, "nothing earmarked");

        vm.warp(block.timestamp + 14 days);
        uint256 id = _propose(pot, payee, 10e6);
        assertEq(ledger.payouts(id).headcount, 1, "no cooldown held the vault");
    }

    /// One counted member: the bar is all of them, so one yes passes.
    function test_proof12_headcountOne_oneYesPasses() public {
        _fund(_people(1), 20e6);
        uint256 id = _propose(pot, payee, 10e6);
        assertEq(ledger.payouts(id).headcount, 1);
        _vote(ada, id, true);
        assertEq(_status(id), ProposalStatus.PASSED);
    }

    /// The request passes the moment the bar is met, before the window closes, and executes at once.
    function test_proof12_itPassesEarlyTheMomentTheBarIsMet() public {
        _fund(_people(6), 20e6);
        uint256 id = _propose(pot, payee, 10e6);
        assertEq(ledger.payouts(id).headcount, 6);
        _vote(ada, id, true);
        _vote(bea, id, true);
        _vote(cid, id, true);
        assertEq(_status(id), ProposalStatus.LIVE, "three of six is not over half");
        _vote(dan, id, true);
        assertEq(_status(id), ProposalStatus.PASSED, "four of six passes at once");
        assertLt(block.timestamp, ledger.payouts(id).deadline);

        vm.expectRevert(ILedger.ProposalNotLive.selector);
        _vote(eve, id, false);

        uint256 before = usdc.balanceOf(payee);
        ledger.executeWithdrawal(id);
        assertEq(usdc.balanceOf(payee) - before, 10e6);
    }

    function test_vote_eachCountedMemberVotesOnceInsideTheWindow() public {
        _fund(_people(4), 20e6);
        uint256 id = _propose(pot, payee, 10e6);
        _vote(ada, id, false);
        vm.expectRevert(ILedger.AlreadyVoted.selector);
        _vote(ada, id, true);
        vm.warp(block.timestamp + window + 1);
        vm.expectRevert(ILedger.VoteWindowClosed.selector);
        _vote(bea, id, true);
    }

    // ---- proof 13: the cooldown ----

    /// After a failed request, a new one on that vault reverts for 30 days, then works.
    function test_proof13_aFailedRequestCoolsTheVaultDown() public {
        _fund(_people(3), 20e6);
        uint256 id = _propose(pot, payee, 10e6);
        uint64 deadline = ledger.payouts(id).deadline;
        vm.warp(deadline + 1);
        assertEq(_status(id), ProposalStatus.FAILED);

        uint64 cooldown = config.removalReproposeCooldown();
        vm.warp(deadline + cooldown - 1);
        vm.expectRevert(ILedger.CooldownActive.selector);
        _propose(pot, payee, 10e6);

        vm.warp(deadline + cooldown);
        uint256 next = _propose(pot, payee, 10e6);
        assertEq(_status(next), ProposalStatus.LIVE);
    }

    /// An executed request starts no cooldown.
    function test_proof13_anExecutedRequestStartsNoCooldown() public {
        _fund(_people(3), 20e6);
        uint256 id = _propose(pot, payee, 10e6);
        _vote(ada, id, true);
        _vote(bea, id, true);
        _vote(cid, id, true);
        ledger.executeWithdrawal(id);
        _propose(pot, payee, 10e6);
    }

    /// One open request per vault: a live one, or a passed one nobody has executed yet.
    function test_oneOpenRequestPerVault() public {
        _fund(_people(3), 20e6);
        uint256 id = _propose(pot, payee, 10e6);
        vm.expectRevert(ILedger.PayoutOpen.selector);
        _propose(pot, payee, 1e6);
        _vote(ada, id, true);
        _vote(bea, id, true);
        _vote(cid, id, true);
        vm.warp(block.timestamp + 60 days);
        vm.expectRevert(ILedger.PayoutOpen.selector);
        _propose(pot, payee, 1e6);
    }

    function test_onlyTheHostRequests_onAnUnlockedSharedVault() public {
        _fund(_people(3), 20e6);
        vm.expectRevert(ILedger.NotHost.selector);
        vm.prank(ada);
        ledger.proposeWithdrawal(pot, payee, 10e6);

        uint256 mine = _personal(ada, VenueIds.FLEX, 0);
        vm.expectRevert(ILedger.PersonalVaultHasNoProposals.selector);
        _propose(mine, payee, 1e6);

        uint64 unlock = uint64(block.timestamp + 30 days);
        vm.prank(host);
        uint256 locked = ledger.createVault(_params(VenueIds.TERM, true, unlock, "locked pot"));
        _deposit(ada, locked, 20e6);
        vm.expectRevert(ILedger.VaultLocked.selector);
        _propose(locked, payee, 1e6);
        vm.warp(unlock);
        _propose(locked, payee, 1e6);
    }

    // ---- the earmark ----

    /// The requested units are reserved: a second request cannot take them, and they leave exactly
    /// as reserved whatever the price did meanwhile.
    function test_earmark_isInUnitsAndLeavesExactlyAsReserved() public {
        _fund(_people(3), 100e6);
        uint256 id = _propose(pot, payee, 150e6);
        uint256 reserved = ledger.payouts(id).units;
        assertEq(ledger.earmarkedUnits(pot), reserved);
        assertEq(ledger.availableUnits(pot), ledger.vaultUnits(pot) - reserved);

        _vote(ada, id, true);
        _vote(bea, id, true);
        _vote(cid, id, true);
        uint256 before = ledger.vaultUnits(pot);
        ledger.executeWithdrawal(id);
        assertEq(before - ledger.vaultUnits(pot), reserved, "exactly the reserved units left");
        assertEq(ledger.earmarkedUnits(pot), 0);
    }

    function test_request_cannotAskForMoreThanTheVaultHolds() public {
        _fund(_people(3), 100e6);
        vm.expectRevert(ILedger.ExceedsWithdrawable.selector);
        _propose(pot, payee, 300e6 + 1);
    }

    // ---- proof 14: the push payout ----

    /// A passed payout pays the recipient directly when the queue is processed.
    function test_proof14_aPassedPayoutPaysTheRecipientWhenTheQueueIsProcessed() public {
        _fund(_people(3), 100e6);
        uint256 id = _propose(pot, payee, 120e6);
        _vote(ada, id, true);
        _vote(bea, id, true);
        _vote(cid, id, true);

        _illiquid(VenueIds.FLEX);
        uint256 before = usdc.balanceOf(payee);
        vm.prank(stranger);
        ledger.executeWithdrawal(id);
        assertEq(usdc.balanceOf(payee), before, "the venue has no cash yet");
        assertEq(ledger.payoutStatus(id), ProposalStatus.EXECUTED);

        _liquid(VenueIds.FLEX);
        vm.prank(stranger);
        flexVault.processQueue(10);
        assertEq(usdc.balanceOf(payee) - before, 120e6, "paid straight to the recipient");
        assertEq(usdc.balanceOf(address(ledger)), 0, "nothing passed through the ledger");

        vm.expectRevert(ILedger.NotPassed.selector);
        ledger.executeWithdrawal(id);
    }

    /// In a liquid venue the recipient is paid in the execution itself.
    function test_proof14_aLiquidVenuePaysAtExecution() public {
        _fund(_people(3), 100e6);
        uint256 id = _propose(pot, payee, 120e6);
        _vote(ada, id, true);
        _vote(bea, id, true);
        _vote(cid, id, true);
        uint256 before = usdc.balanceOf(payee);
        ledger.executeWithdrawal(id);
        assertEq(usdc.balanceOf(payee) - before, 120e6);
    }

    // ---- gas: the headcount snapshot ----

    /// The headcount walks the vault's depositors once. This measures a request over 150
    /// depositors, the most Active seats a community holds, every one of them counted, which is
    /// the dearest case: each costs its stake read, two calls to `Community` and a stamp.
    function test_gas_headcountOverOneHundredFiftyDepositors() public {
        for (uint256 i; i < 150; i++) {
            address m = address(uint160(0x10000 + i));
            community.setMember(m, true);
            community.setSeasoned(m, true);
            usdc.mint(m, 20e6);
            vm.startPrank(m);
            usdc.approve(address(ledger), 20e6);
            ledger.deposit(pot, 20e6);
            vm.stopPrank();
        }
        vm.warp(block.timestamp + 15 days);
        vm.prank(host);
        uint256 g = gasleft();
        uint256 id = ledger.proposeWithdrawal(pot, payee, 10e6);
        g -= gasleft();
        assertEq(ledger.payouts(id).headcount, 150);
        emit log_named_uint("proposeWithdrawal gas, 150 counted depositors", g);
        assertLt(g, 6_000_000);
    }
}
