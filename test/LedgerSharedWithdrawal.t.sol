// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.30;

import {LedgerFixture} from "./helpers/LedgerFixture.sol";
import {ILedger} from "../src/interfaces/ILedger.sol";
import {PoolTypes} from "../src/PoolTypes.sol";
import {ProposalStatus} from "../src/VaultStatus.sol";

/// The shared withdrawal: a queued transfer rather than a governed decision, and a
/// proposal that is reverted, never expired.
contract LedgerSharedWithdrawalTest is LedgerFixture {
    uint256 pot;

    function setUp() public {
        setUpLedger();
        pot = _shared(PoolTypes.FLEX);
        // Four depositors, so a 20% quorum and a three-vote floor are both real bars rather than
        // arithmetic that passes by being trivial.
        _deposit(ada, pot, 400e6);
        _deposit(bea, pot, 300e6);
        _deposit(cid, pot, 200e6);
        _deposit(dan, pot, 100e6);
        // Every threshold here is 20% of the vault's QUALIFYING contributors,
        // so the electorate has to season before a proposal can see it.
        // `LedgerQualifyingContributors.t.sol` is where the two bars are pulled apart.
        vm.warp(block.timestamp + 15 days);
    }

    function _window() internal view returns (uint64 w) {
        (, w) = config.communityVote();
    }

    function _propose(uint256 amount) internal returns (uint256 id) {
        vm.prank(host);
        id = ledger.proposeWithdrawal(pot, payee, amount);
    }

    function _voteYes(uint256 id, address[3] memory who) internal {
        for (uint256 i = 0; i < 3; i++) {
            vm.prank(who[i]);
            ledger.voteOnWithdrawal(id, true);
        }
    }

    // ---- proof 9 ----

    /// Proposed with a fixed recipient and amount, earmarked, voted through, and executed by a
    /// member who is not the host. Execution changes no parameter: the recipient and the amount
    /// are the ones the vote saw.
    function test_sharedWithdrawal_proposedEarmarkedVotedExecuted() public {
        uint256 id = _propose(250e6);

        (uint256 vaultId, address recipient, uint256 units, uint256 approved,,,,,) = ledger.proposals(id);
        assertEq(vaultId, pot);
        assertEq(recipient, payee);
        // The reservation is a unit count. At the unit price this fixture runs at it
        // is numerically the same as the dollars asked for, and `LedgerEarmarkUnits.t.sol` is
        // where the two are pulled apart by moving the price.
        assertEq(units, 250e6);
        assertEq(approved, 250e6, "the dollar value the voters were shown");
        assertEq(ledger.earmarkedUnits(pot), 250e6, "reserved from the vault's units at proposal time");
        assertEq(ledger.availableUnits(pot), 750e6);
        assertEq(ledger.availableBalance(pot), 750e6);

        _voteYes(id, [ada, bea, cid]);
        vm.warp(block.timestamp + _window() + 1);

        uint256 before = usdc.balanceOf(payee);
        // dan is a member and a depositor, and is not the host. Anyone in the community may
        // execute; there is no timelock between passing and executing.
        vm.prank(dan);
        ledger.executeWithdrawal(id);

        assertEq(usdc.balanceOf(payee) - before, 250e6, "the recipient and amount the vote saw");
        assertEq(ledger.earmarkedUnits(pot), 0);
        assertEq(ledger.vaultBalance(pot), 750e6);
        (,,,,,,,, uint8 status) = ledger.proposals(id);
        assertEq(status, ProposalStatus.EXECUTED);
    }

    /// The vote is counts of people, never of money. dan put in 100 and ada 400, and each has one
    /// vote: a proposal carried by the three smallest depositors passes over the largest one's no.
    function test_sharedWithdrawal_oneDepositorOneVote() public {
        uint256 id = _propose(100e6);
        vm.prank(ada);
        ledger.voteOnWithdrawal(id, false);
        _voteYes(id, [bea, cid, dan]);
        vm.warp(block.timestamp + _window() + 1);
        vm.prank(bea);
        ledger.executeWithdrawal(id);
        assertEq(usdc.balanceOf(payee), 1_000_000e6 + 100e6);
    }

    /// No vote passes on fewer than three votes, whatever the percentage. Two of
    /// four is 50% of the electorate and clears a 20% quorum on the arithmetic alone.
    function test_sharedWithdrawal_twoVotesNeverPasses() public {
        uint256 id = _propose(100e6);
        vm.prank(ada);
        ledger.voteOnWithdrawal(id, true);
        vm.prank(bea);
        ledger.voteOnWithdrawal(id, true);
        vm.warp(block.timestamp + _window() + 1);
        vm.expectRevert(ILedger.NotPassed.selector);
        vm.prank(ada);
        ledger.executeWithdrawal(id);
    }

    /// A non-depositor holds no vote in this vault, however long they have held a seat.
    function test_sharedWithdrawal_onlyDepositorsVote() public {
        uint256 id = _propose(100e6);
        vm.expectRevert(ILedger.NotDepositor.selector);
        vm.prank(host);
        ledger.voteOnWithdrawal(id, true);
    }

    /// The electorate is frozen at proposal time. A member who deposits after the proposal opened
    /// does not gain a vote on it, which is what keeps the frozen denominator honest.
    function test_sharedWithdrawal_electorateIsFrozenAtProposal() public {
        uint256 id = _propose(100e6);
        vm.warp(block.timestamp + 1);
        _deposit(host, pot, 10e6);
        vm.expectRevert(ILedger.NotDepositor.selector);
        vm.prank(host);
        ledger.voteOnWithdrawal(id, true);
    }

    /// Only the host proposes.
    function test_sharedWithdrawal_onlyTheHostProposes() public {
        vm.expectRevert(ILedger.NotHost.selector);
        vm.prank(ada);
        ledger.proposeWithdrawal(pot, payee, 100e6);
    }

    // ---- the lock reaches the shared path too ----

    /// A locked shared vault refuses a proposal until its date, and runs the ordinary path once
    /// the date passes. The gate sits at proposal rather than at execution because a vote that
    /// cannot legally execute should never start: a community that spent its voting window on a
    /// withdrawal the contract then refuses has been told the lock is advisory.
    function test_lockedSharedVault_refusesAProposalUntilMaturity() public {
        uint64 maturity = uint64(block.timestamp + 30 days);
        vm.prank(host);
        uint256 locked = ledger.createVault(_params(PoolTypes.FLEX, true, maturity, "locked pot"));
        _deposit(ada, locked, 100e6);
        _deposit(bea, locked, 100e6);
        _deposit(cid, locked, 100e6);

        vm.expectRevert(ILedger.VaultLocked.selector);
        vm.prank(host);
        ledger.proposeWithdrawal(locked, payee, 50e6);
        assertEq(ledger.earmarkedUnits(locked), 0, "a refused proposal reserves nothing");

        vm.warp(maturity);
        vm.prank(host);
        uint256 id = ledger.proposeWithdrawal(locked, payee, 50e6);
        _voteYes(id, [ada, bea, cid]);
        vm.warp(block.timestamp + _window() + 1);

        uint256 before = usdc.balanceOf(payee);
        vm.prank(dan);
        ledger.executeWithdrawal(id);
        assertEq(usdc.balanceOf(payee) - before, 50e6, "the date passed, and the ordinary path ran");
    }

    // ---- proof 10 ----

    /// Reserved units cannot be withdrawn or spent by a second proposal while the first is live.
    /// The vault holds 1,000 units and 800 of them are spoken for, so a second proposal for 300
    /// cannot be opened.
    function test_earmark_cannotBeSpentTwice() public {
        _propose(800e6);
        assertEq(ledger.availableUnits(pot), 200e6);
        assertEq(ledger.availableBalance(pot), 200e6);

        vm.expectRevert(ILedger.ExceedsAvailable.selector);
        vm.prank(host);
        ledger.proposeWithdrawal(pot, payee, 300e6);

        // 200 is still proposable: the earmark reserves its own amount and nothing more.
        vm.prank(host);
        ledger.proposeWithdrawal(pot, payee, 200e6);
        assertEq(ledger.earmarkedUnits(pot), 1_000e6);
    }

    /// The same reservation holds against the whole vault, not only against other proposals: a
    /// shared vault has no member-initiated withdrawal path at all, so there is nothing else that
    /// could reach the earmark.
    function test_earmark_sharedVaultHasNoMemberWithdrawalPath() public {
        _propose(800e6);
        vm.expectRevert(ILedger.SharedVaultNeedsAProposal.selector);
        vm.prank(ada);
        ledger.withdrawInstant(pot, 100e6);

        vm.expectRevert(ILedger.SharedVaultNeedsAProposal.selector);
        vm.prank(ada);
        ledger.requestWithdraw(pot, 100e6);
    }

    // ---- proof 11 ----

    /// A failed proposal, reverted by a member who is not the host, with the earmark returning to
    /// the balance.
    function test_failedProposal_isRevertedByAnyMember_andTheEarmarkReturns() public {
        uint256 id = _propose(400e6);
        vm.prank(ada);
        ledger.voteOnWithdrawal(id, true);
        vm.warp(block.timestamp + _window() + 1);

        assertEq(ledger.availableBalance(pot), 600e6);
        vm.prank(cid); // not the host
        ledger.revertWithdrawal(id);

        assertEq(ledger.earmarkedUnits(pot), 0);
        assertEq(ledger.availableUnits(pot), 1_000e6, "the reserved units returned to the vault");
        (,,,,,,,, uint8 status) = ledger.proposals(id);
        assertEq(status, ProposalStatus.REVERTED);
    }

    /// A live proposal inside its own window cannot be reverted out from under the vote.
    function test_liveProposal_cannotBeRevertedMidWindow() public {
        uint256 id = _propose(400e6);
        vm.expectRevert(ILedger.VoteWindowOpen.selector);
        vm.prank(ada);
        ledger.revertWithdrawal(id);
    }

    // ---- proof 12 ----

    /// A passed proposal sits unexecuted and then executes correctly later. Nothing
    /// dies on a timer.
    function test_passedProposal_sitsThenExecutes() public {
        uint256 id = _propose(250e6);
        _voteYes(id, [ada, bea, cid]);
        vm.warp(block.timestamp + _window() + 1);

        vm.warp(block.timestamp + 365 days);
        vm.prank(dan);
        ledger.executeWithdrawal(id);
        assertEq(usdc.balanceOf(payee), 1_000_000e6 + 250e6, "no expiry, and the amount is unchanged");
    }

    /// A passed proposal becomes revertible after the configured delay, and not before. That is
    /// the only thing standing between a passed vote and an earmark frozen forever, and it is a
    /// revert rather than an expiry: someone has to act.
    function test_passedProposal_becomesRevertibleAfterTheDelay() public {
        uint256 id = _propose(250e6);
        _voteYes(id, [ada, bea, cid]);
        vm.warp(block.timestamp + _window() + 1);

        vm.expectRevert(ILedger.RevertDelayNotElapsed.selector);
        vm.prank(ada);
        ledger.revertWithdrawal(id);

        vm.warp(block.timestamp + config.sharedProposalRevertDelay());
        vm.prank(ada);
        ledger.revertWithdrawal(id);
        assertEq(ledger.earmarkedUnits(pot), 0);
        assertEq(ledger.availableUnits(pot), 1_000e6);
    }

    /// Reverted is terminal on both sides: a reverted proposal cannot then be executed, and an
    /// executed one cannot then be reverted.
    function test_proposalStatus_isTerminalBothWays() public {
        uint256 id = _propose(250e6);
        _voteYes(id, [ada, bea, cid]);
        vm.warp(block.timestamp + _window() + 1);
        vm.prank(dan);
        ledger.executeWithdrawal(id);

        vm.warp(block.timestamp + config.sharedProposalRevertDelay());
        vm.expectRevert(ILedger.ProposalNotLive.selector);
        vm.prank(ada);
        ledger.revertWithdrawal(id);

        uint256 second = _propose(100e6);
        vm.warp(block.timestamp + _window() + 1);
        vm.prank(ada);
        ledger.revertWithdrawal(second);
        vm.expectRevert(ILedger.ProposalNotLive.selector);
        vm.prank(ada);
        ledger.executeWithdrawal(second);
    }
}
