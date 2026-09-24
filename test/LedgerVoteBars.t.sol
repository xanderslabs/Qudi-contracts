// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.30;

import {LedgerFixture} from "./helpers/LedgerFixture.sol";
import {ILedger} from "../src/interfaces/ILedger.sol";
import {VenueIds} from "./helpers/VenueIds.sol";

/// The two vote bars on a shared withdrawal. Quorum is a share of the vault's qualifying contributors at
/// proposal time; approval is a share of the votes actually cast; both are counts of people.
///
/// **Why this fixture is twenty depositors and not four.** `LedgerSharedWithdrawal.t.sol` runs on
/// four, where 20% of the electorate is 0.8 votes and the three-vote floor is the only
/// bar that ever binds. Every proposal there is decided by the floor, so the quorum line could be
/// deleted outright and nothing would notice. At twenty depositors a 20% quorum is four votes and
/// the floor is three, which is the first electorate size where the two come apart. That gap is
/// the whole reason this file exists.
contract LedgerVoteBarsTest is LedgerFixture {
    uint256 pot;

    /// Enough that 20% of them is above the three-vote floor.
    uint256 internal constant ELECTORATE = 20;
    address[ELECTORATE] internal voters;

    /// What everyone but the whale puts in: over the amount bar and otherwise unremarkable.
    uint256 internal constant STAKE = 100e6;
    /// voters[0] holds five hundred times what anyone else holds. Nothing reads it.
    uint256 internal constant WHALE_STAKE = 50_000e6;

    function setUp() public {
        setUpLedger();
        pot = _shared(VenueIds.FLEX);

        for (uint256 i; i < ELECTORATE; i++) {
            address who = makeAddr(string.concat("voter", vm.toString(i)));
            voters[i] = who;
            community.setMember(who, true);
            uint256 amount = i == 0 ? WHALE_STAKE : STAKE;
            usdc.mint(who, amount);
            vm.startPrank(who);
            usdc.approve(address(ledger), type(uint256).max);
            ledger.deposit(pot, amount);
            vm.stopPrank();
        }

        // The amount bar is met on deposit; the seasoning bar runs from the crossing,
        // so the electorate is not real until the window has elapsed.
        vm.warp(block.timestamp + 15 days);
        assertEq(ledger.depositorCount(pot), ELECTORATE, "fixture: twenty qualifying contributors");
    }

    function _window() internal view returns (uint64 w) {
        (, w) = config.communityVote();
    }

    function _propose(uint256 amount) internal returns (uint256 id) {
        vm.prank(host);
        id = ledger.proposeWithdrawal(pot, payee, amount);
    }

    /// Casts `yes` yes-votes and `no` no-votes, taking voters from the front of the list.
    function _vote(uint256 id, uint256 yes, uint256 no) internal {
        for (uint256 i; i < yes + no; i++) {
            vm.prank(voters[i]);
            ledger.voteOnWithdrawal(id, i < yes);
        }
    }

    function _closeWindow() internal {
        vm.warp(block.timestamp + _window() + 1);
    }

    // ---- proof 2: the quorum (UL-08) ----

    /// Three votes clear the floor and still miss the quorum. 20% of twenty is four, so
    /// this is the case the floor does not cover, and it is the case that fails without the
    /// quorum line at all.
    function test_quorum_threeVotesOfTwentyDepositorsDoesNotPass() public {
        uint256 id = _propose(250e6);
        _vote(id, 3, 0);

        (,,,,, uint32 forVotes, uint32 againstVotes, uint256 electorate,) = ledger.proposals(id);
        assertEq(forVotes, 3, "three votes cast, so the three-vote floor is cleared");
        assertEq(againstVotes, 0);
        assertEq(electorate, ELECTORATE, "the denominator is frozen at proposal time");

        _closeWindow();
        vm.expectRevert(ILedger.NotPassed.selector);
        vm.prank(voters[0]);
        ledger.executeWithdrawal(id);
    }

    /// Four of twenty is exactly the 20% bar, and the bar is met rather than merely approached:
    /// the comparison is `cast * 10_000 < quorumBps * electorate`, so equality passes.
    function test_quorum_fourVotesOfTwentyDepositorsIsExactlyTheBarAndPasses() public {
        (uint16 quorumBps,) = config.sharedWithdrawalVote();
        assertEq(4 * 10_000, uint256(quorumBps) * ELECTORATE, "fixture: four votes is the bar exactly");

        uint256 id = _propose(250e6);
        _vote(id, 4, 0);
        _closeWindow();

        uint256 before = usdc.balanceOf(payee);
        vm.prank(voters[0]);
        ledger.executeWithdrawal(id);
        assertEq(usdc.balanceOf(payee) - before, 250e6, "the quorum was met, so the money moved");
    }

    // ---- proof 3: the approval bar (UL-09) ----

    /// Four yes and two no is a clear majority, is over quorum, and does not pass. The bar is a
    /// share of the votes cast, not a comparison between the two sides.
    ///
    /// Four of six is **exactly** two thirds, and it still fails, because the configured bar is
    /// 6,667 basis points and two thirds is 6,666.67. The design says "at least two thirds"; the
    /// parameter rounds that up to the next basis point rather than down, which is the strict
    /// reading. Asserted below so the rounding is recorded rather than discovered.
    function test_approval_aMajorityBelowTheBarDoesNotPass() public {
        (, uint16 approvalBps) = config.sharedWithdrawalVote();
        assertGt(uint256(approvalBps) * 6, 4 * 10_000, "fixture: four of six sits below the configured bar");

        uint256 id = _propose(250e6);
        _vote(id, 4, 2);

        (,,,,, uint32 forVotes, uint32 againstVotes,,) = ledger.proposals(id);
        assertEq(forVotes, 4);
        assertEq(againstVotes, 2);

        _closeWindow();
        vm.expectRevert(ILedger.NotPassed.selector);
        vm.prank(voters[0]);
        ledger.executeWithdrawal(id);
    }

    /// Five of six clears the bar, and the money moves. The same six voters, one of them changed
    /// sides, which is the whole difference between this test and the one above.
    function test_approval_atTheBarItPasses() public {
        uint256 id = _propose(250e6);
        _vote(id, 5, 1);
        _closeWindow();

        uint256 before = usdc.balanceOf(payee);
        vm.prank(voters[0]);
        ledger.executeWithdrawal(id);
        assertEq(usdc.balanceOf(payee) - before, 250e6);
    }

    // ---- proof 4: the approval bar counts people (UL-09) ----

    /// voters[0] put in five hundred times what voters[1] put in, and holds one vote. A proposal
    /// the whale votes against passes on four small yes-votes against its one no.
    function test_approval_countsPeopleNotBalances() public {
        assertEq(WHALE_STAKE, STAKE * 500, "fixture: the two balances are nothing alike");

        uint256 id = _propose(250e6);
        vm.prank(voters[0]); // the whale
        ledger.voteOnWithdrawal(id, false);
        for (uint256 i = 1; i < 5; i++) {
            vm.prank(voters[i]);
            ledger.voteOnWithdrawal(id, true);
        }

        (,,,,, uint32 forVotes, uint32 againstVotes,,) = ledger.proposals(id);
        assertEq(forVotes, 4, "four people, not four hundred dollars");
        assertEq(againstVotes, 1, "one person, not fifty thousand dollars");

        _closeWindow();
        uint256 before = usdc.balanceOf(payee);
        vm.prank(voters[9]);
        ledger.executeWithdrawal(id);
        assertEq(usdc.balanceOf(payee) - before, 250e6, "the largest depositor did not outweigh four small ones");
    }

    /// The mirror, which is where a balance-weighted count would actually show: the whale and one
    /// small depositor vote yes against three small no-votes. Two of five is below the approval
    /// bar and the proposal fails, though the yes side holds 50,100 of the 50,300 that voted.
    function test_approval_theLargestDepositorOnTheWinningSideChangesNothing() public {
        uint256 id = _propose(250e6);
        vm.prank(voters[0]); // the whale, voting yes this time
        ledger.voteOnWithdrawal(id, true);
        vm.prank(voters[1]);
        ledger.voteOnWithdrawal(id, true);
        for (uint256 i = 2; i < 5; i++) {
            vm.prank(voters[i]);
            ledger.voteOnWithdrawal(id, false);
        }

        (,,,,, uint32 forVotes, uint32 againstVotes,,) = ledger.proposals(id);
        assertEq(forVotes, 2);
        assertEq(againstVotes, 3);

        _closeWindow();
        vm.expectRevert(ILedger.NotPassed.selector);
        vm.prank(voters[9]);
        ledger.executeWithdrawal(id);
    }
}
