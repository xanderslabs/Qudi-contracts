// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.30;

import {CommunityTest} from "./Community.t.sol";
import {ICommunity} from "../src/interfaces/ICommunity.sol";
import {ConfigKeys} from "../src/ConfigKeys.sol";

/// Host removal vote, election-when-vacant, and host-default auto-removal.
contract CommunityVotesTest is CommunityTest {
    address cy = _keyed("cy");
    address dara = _keyed("dara");
    address efe = _keyed("efe");

    function test_hostVoteThreshold() public {
        _join(ada); // 6 members with host
        _join(bem);
        _join(cy);
        _join(dara);
        _join(efe);
        _season();
        vm.prank(ada);
        community.proposeRemoveHost();
        uint256 voteId = community.activeHostVoteId();
        vm.prank(ada);
        community.castVote(voteId, true);
        vm.prank(bem);
        community.castVote(voteId, true);
        vm.prank(cy);
        community.castVote(voteId, true);
        vm.prank(dara);
        community.castVote(voteId, false);
        vm.warp(block.timestamp + 7 days + 1);
        vm.expectRevert(ICommunity.NotPassed.selector);
        community.executeRemoveHost(); // 4 of 6 = 66.7% >= 6667 bps? 4/6=6666 -> fails
    }

    function test_thresholdRounding_fourOfSixFails() public {
        _join(ada);
        _join(bem);
        _join(cy);
        _join(dara);
        _join(efe);
        _season();
        vm.prank(ada);
        community.proposeRemoveHost();
        uint256 voteId = community.activeHostVoteId();
        vm.prank(ada);
        community.castVote(voteId, true);
        vm.prank(bem);
        community.castVote(voteId, true);
        vm.prank(cy);
        community.castVote(voteId, true);
        vm.prank(dara);
        community.castVote(voteId, false);
        vm.warp(block.timestamp + 7 days + 1);
        vm.expectRevert(ICommunity.NotPassed.selector);
        community.executeRemoveHost();
    }

    function test_thresholdRounding_fiveOfSixPasses() public {
        _join(ada);
        _join(bem);
        _join(cy);
        _join(dara);
        _join(efe);
        _season();
        vm.prank(ada);
        community.proposeRemoveHost();
        uint256 voteId = community.activeHostVoteId();
        vm.prank(ada);
        community.castVote(voteId, true);
        vm.prank(bem);
        community.castVote(voteId, true);
        vm.prank(cy);
        community.castVote(voteId, true);
        vm.prank(dara);
        community.castVote(voteId, true);
        vm.prank(efe);
        community.castVote(voteId, true);
        vm.warp(block.timestamp + 7 days + 1);
        community.executeRemoveHost();
        assertTrue(community.hostVacant());
    }

    function test_voteWindowEnforced() public {
        // NOTE: deviates from the brief's literal 2-joiner setup. With the host's own seat
        // counted in memberCount() (host+ada+bem = 3), 2 yes-votes is the same 2/3 ratio the
        // brief's own pinned rounding rule (see fourOfSixFails) says must fail. Added a third
        // joiner (cy) so the vote clearly clears the threshold, preserving the test's intent
        // (window gate, then a passing execution) without contradicting the pinned formula.
        _join(ada);
        _join(bem);
        _join(cy);
        _season();
        vm.prank(ada);
        community.proposeRemoveHost();
        uint256 voteId = community.activeHostVoteId();
        vm.prank(ada);
        community.castVote(voteId, true);
        vm.prank(bem);
        community.castVote(voteId, true);
        vm.prank(cy);
        community.castVote(voteId, true);
        vm.expectRevert(ICommunity.VoteWindowOpen.selector);
        community.executeRemoveHost(); // early execution reverts
        vm.warp(block.timestamp + 7 days + 1);
        community.executeRemoveHost();
        assertTrue(community.hostVacant());
    }

    // onHostDefault() is deleted (the credit pool no longer vacates the
    // role; a defaulting host faces the same consequences as any member). Vacating the
    // host in the tests below now goes through the same removal vote a live host faces.

    function test_electHostWhenVacant() public {
        // NOTE: same 2/3-ratio issue as test_voteWindowEnforced above; added a third joiner
        // (cy) so the election vote clears the pinned threshold instead of falling just short
        // of it.
        _join(ada);
        _join(bem);
        _join(cy);
        _season();
        vm.prank(ada);
        community.proposeRemoveHost();
        uint256 voteId = community.activeHostVoteId();
        vm.prank(ada);
        community.castVote(voteId, true);
        vm.prank(bem);
        community.castVote(voteId, true);
        vm.prank(cy);
        community.castVote(voteId, true);
        vm.warp(block.timestamp + 7 days + 1);
        community.executeRemoveHost();
        assertTrue(community.hostVacant());

        vm.prank(ada);
        community.electHost(ada); // proposes ada, same vote shape
        uint256 voteId2 = community.activeHostVoteId();
        vm.prank(ada);
        community.castVote(voteId2, true);
        vm.prank(bem);
        community.castVote(voteId2, true);
        vm.prank(cy);
        community.castVote(voteId2, true);
        vm.warp(block.timestamp + 7 days + 1);
        community.executeRemoveHost();
        assertEq(community.host(), ada);
        assertFalse(community.hostVacant());
    }

    function test_electBlockedWhileHostSeated() public {
        _join(ada);
        _season(); // a candidate must be seasoned, so the seat is what refuses here
        vm.prank(ada);
        vm.expectRevert(ICommunity.HostNotVacant.selector);
        community.electHost(ada);
    }

    /// Regression for the fix-round-1 follow-up finding: a vote that PASSED but was never
    /// executed must not be silently clobbered by a fresh proposal. Unlike a failed vote (which
    /// can never still apply, so it's safe to discard), a passing-but-unexecuted vote is a
    /// pending action; re-proposing on top of it would discard the community's winning decision
    /// with no revert and no event. VoteActive must still block here.
    function test_passedButUnexecutedVoteBlocksReproposal() public {
        _join(ada);
        _join(bem);
        _join(cy);
        _join(dara);
        _join(efe);
        _season();
        vm.prank(ada);
        community.proposeRemoveHost();
        uint256 voteId = community.activeHostVoteId();
        vm.prank(ada);
        community.castVote(voteId, true);
        vm.prank(bem);
        community.castVote(voteId, true);
        vm.prank(cy);
        community.castVote(voteId, true);
        vm.prank(dara);
        community.castVote(voteId, true);
        vm.prank(efe); // 5 of 6: passes
        community.castVote(voteId, true);
        vm.warp(block.timestamp + 7 days + 1);

        // deadline has passed and nobody executed yet: a fresh proposal must not clobber it
        vm.prank(ada);
        vm.expectRevert(ICommunity.VoteActive.selector);
        community.proposeRemoveHost();

        // the original passing vote must still execute correctly afterward
        community.executeRemoveHost();
        assertTrue(community.hostVacant());
    }

    /// C1: the 7-day window gates voting, not only execution. Without the deadline check in
    /// castVote(), a vote that closed short of the threshold sits in activeHostVoteId
    /// forever and one late yes-vote revives it into a passing vote nobody expected.
    function test_voteAfterWindowCloseReverts() public {
        _join(ada); // 6 members with host
        _join(bem);
        _join(cy);
        _join(dara);
        _join(efe);
        _season();
        vm.prank(ada);
        community.proposeRemoveHost();
        uint256 voteId = community.activeHostVoteId();
        vm.prank(ada);
        community.castVote(voteId, true);
        vm.prank(bem);
        community.castVote(voteId, true);
        vm.prank(cy); // 3 of 6: short
        community.castVote(voteId, true);

        vm.warp(block.timestamp + 7 days + 1);
        vm.prank(dara);
        vm.expectRevert(ICommunity.VoteWindowClosed.selector);
        community.castVote(voteId, true);

        // and 100 days later it is still closed, not merely "not yet"
        vm.warp(block.timestamp + 100 days);
        vm.prank(efe);
        vm.expectRevert(ICommunity.VoteWindowClosed.selector);
        community.castVote(voteId, true);
    }

    /// The snapshot rule, exploit direction 2: a minority must not be able
    /// to inflate its own share by shrinking the electorate after the fact. 3 of 6 fails at
    /// proposal time and must still fail after two members forfeit, even though 3 of 4 would
    /// clear the threshold against a live memberCount().
    function test_denominatorSnapshotSurvivesForfeits() public {
        _join(ada); // 6 members with host
        _join(bem);
        _join(cy);
        _join(dara);
        _join(efe);
        _season();
        vm.prank(ada);
        community.proposeRemoveHost();
        uint256 voteId = community.activeHostVoteId();
        vm.prank(ada);
        community.castVote(voteId, true);
        vm.prank(bem);
        community.castVote(voteId, true);
        vm.prank(cy); // 3 of 6
        community.castVote(voteId, true);

        vm.prank(dara);
        community.forfeit();
        vm.prank(efe);
        community.forfeit();
        assertEq(community.memberCount(), 4); // live count now flatters 3

        vm.warp(block.timestamp + 7 days + 1);
        vm.expectRevert(ICommunity.NotPassed.selector);
        community.executeRemoveHost(); // judged against the 6
    }

    /// The other direction the snapshot closes: the host cannot dilute a passing vote by
    /// admitting fresh members before someone executes it.
    function test_denominatorSnapshotSurvivesLateJoins() public {
        _join(ada); // 4 members with host
        _join(bem);
        _join(cy);
        _season();
        vm.prank(ada);
        community.proposeRemoveHost();
        uint256 voteId = community.activeHostVoteId();
        vm.prank(ada);
        community.castVote(voteId, true);
        vm.prank(bem);
        community.castVote(voteId, true);
        vm.prank(cy); // 3 of 4: passes
        community.castVote(voteId, true);

        _join(dara); // host dilutes to 6
        _join(efe);
        vm.warp(block.timestamp + 7 days + 1);
        community.executeRemoveHost();
        assertTrue(community.hostVacant());
    }

    /// C3: an elected host must already hold a seat, or executeRemoveHost() seats a
    /// non-member and hostIsMemberOrVacant no longer holds.
    function test_electNonMemberCandidateReverts() public {
        _join(ada);
        _join(bem);
        _season();
        vm.prank(ada);
        community.proposeRemoveHost();
        uint256 voteId = community.activeHostVoteId();
        vm.prank(host); // unanimous (3 of 3), and three is the floor
        community.castVote(voteId, true);
        vm.prank(ada);
        community.castVote(voteId, true);
        vm.prank(bem);
        community.castVote(voteId, true);
        vm.warp(block.timestamp + 7 days + 1);
        community.executeRemoveHost();

        vm.prank(ada);
        vm.expectRevert(ICommunity.CandidateIneligible.selector);
        community.electHost(dara); // dara never joined
    }

    /// I2: a removal vote against nobody is not a vote, and allowing it would let one member
    /// park activeHostVoteId for the whole window on repeat, blocking every election.
    function test_proposeRemoveBlockedWhileVacant() public {
        _join(ada);
        _join(bem);
        _season();
        vm.prank(ada);
        community.proposeRemoveHost();
        uint256 voteId = community.activeHostVoteId();
        vm.prank(host); // unanimous (3 of 3) always passes
        community.castVote(voteId, true);
        vm.prank(ada);
        community.castVote(voteId, true);
        vm.prank(bem);
        community.castVote(voteId, true);
        vm.warp(block.timestamp + 7 days + 1);
        community.executeRemoveHost();

        vm.prank(ada);
        vm.expectRevert(ICommunity.HostVacant.selector);
        community.proposeRemoveHost();

        // the election path is still open, which is the point of the guard
        vm.prank(ada);
        community.electHost(ada);
        assertEq(community.activeHostVoteId(), 2); // vote 1 was the removal that vacated the role
    }

    function test_oneVotePerMember() public {
        _join(ada);
        _season();
        vm.prank(ada);
        community.proposeRemoveHost();
        uint256 voteId = community.activeHostVoteId();
        vm.startPrank(ada);
        community.castVote(voteId, true);
        vm.expectRevert(ICommunity.AlreadyVoted.selector);
        community.castVote(voteId, true);
        vm.stopPrank();
    }

    /// Review fix 1: a passed election must not seat a candidate who forfeited their seat
    /// after the vote closed. Execution re-checks membership, and the dead election resolves
    /// as failed so a fresh election can start instead of activeHostVoteId blocking forever.
    function test_electionCandidateForfeitedCannotBeSeated() public {
        _join(ada);
        _join(bem);
        _join(cy); // a fourth seat, so the last election still has three yes votes
        _season();
        vm.prank(ada);
        community.proposeRemoveHost();
        uint256 voteId = community.activeHostVoteId();
        vm.prank(host); // unanimous (4 of 4) always passes
        community.castVote(voteId, true);
        vm.prank(ada);
        community.castVote(voteId, true);
        vm.prank(bem);
        community.castVote(voteId, true);
        vm.prank(cy);
        community.castVote(voteId, true);
        vm.warp(block.timestamp + 7 days + 1);
        community.executeRemoveHost();

        vm.prank(ada);
        community.electHost(ada);
        uint256 voteId2 = community.activeHostVoteId();
        // the ex-host keeps their seat after the removal vote, so the electorate is 4
        vm.prank(host);
        community.castVote(voteId2, true);
        vm.prank(ada);
        community.castVote(voteId2, true);
        vm.prank(bem);
        community.castVote(voteId2, true);
        vm.prank(cy);
        community.castVote(voteId2, true);
        vm.warp(block.timestamp + 7 days + 1);

        vm.prank(ada);
        community.forfeit(); // candidate walks before execution

        vm.expectRevert(ICommunity.CandidateNotMember.selector);
        community.executeRemoveHost();
        assertTrue(community.hostVacant()); // nobody was seated

        vm.prank(bem);
        community.electHost(bem); // dead election does not block a new one
        uint256 voteId3 = community.activeHostVoteId();
        vm.prank(host); // electorate is now {ex-host, bem, cy}
        community.castVote(voteId3, true);
        vm.prank(bem);
        community.castVote(voteId3, true);
        vm.prank(cy);
        community.castVote(voteId3, true);
        vm.warp(block.timestamp + 7 days + 1);
        community.executeRemoveHost();
        assertEq(community.host(), bem);
    }

    /// Review fix 2: only seats minted before the proposal may vote. Without this, the frozen
    /// denominator is exploitable: in an open-join community of 4 (3 yes needed), an attacker
    /// minting 3 seats during the window passes a removal every original member voted against.
    function test_joinersAfterProposalCannotVote() public {
        _join(ada); // 4 members with host
        _join(bem);
        _join(cy);
        _season();
        vm.prank(ada);
        community.proposeRemoveHost();
        uint256 voteId = community.activeHostVoteId();
        vm.prank(ada);
        community.castVote(voteId, true);
        vm.prank(bem);
        community.castVote(voteId, false);
        vm.prank(cy);
        community.castVote(voteId, false);

        // join is open by default; no setOpenJoin needed.
        address a1 = makeAddr("a1");
        address a2 = makeAddr("a2");
        _joinOpen(a1);
        _joinOpen(a2);
        vm.prank(a1);
        vm.expectRevert(ICommunity.VoteIneligible.selector);
        community.castVote(voteId, true);
        vm.prank(a2);
        vm.expectRevert(ICommunity.VoteIneligible.selector);
        community.castVote(voteId, true);

        vm.warp(block.timestamp + 7 days + 1);
        vm.expectRevert(ICommunity.NotPassed.selector); // 1 of 4 for: fails as it should
        community.executeRemoveHost();
    }

    // ---- card-price approval vote ----

    function voteYes(uint256 voteId, address[] memory voters) internal {
        for (uint256 i = 0; i < voters.length; i++) {
            vm.prank(voters[i]);
            community.castVote(voteId, true);
        }
    }

    function test_priceChangeNeedsMemberApproval() public {
        // The host proposes; the members approve; future mints pay it. Three seasoned seats,
        // because a vote needs at least three yes votes.
        _join(ada);
        _join(bem);
        _season();
        vm.prank(host);
        community.proposeSeatPrice(80e6);
        assertEq(community.seatPrice(), 50e6); // nothing moves at proposal
        voteYes(community.activePriceVoteId(), _electorate(host, ada, bem));
        vm.warp(block.timestamp + 7 days + 1);
        community.executeSeatPriceVote();
        assertEq(community.seatPrice(), 80e6);
    }

    function test_priceVoteBelowFloorRevertsAtProposal() public {
        vm.prank(owner);
        config.set(ConfigKeys.SEAT_PRICE_FLOOR, 5e6); // the launch floor is 0
        vm.prank(host);
        vm.expectRevert(ICommunity.BelowFloor.selector);
        community.proposeSeatPrice(1e6);
    }

    function test_failedPriceVoteChangesNothing() public {
        _season();
        vm.prank(host);
        community.proposeSeatPrice(80e6);
        // nobody votes yes
        vm.warp(block.timestamp + 7 days + 1);
        vm.expectRevert(ICommunity.NotPassed.selector);
        community.executeSeatPriceVote();
        assertEq(community.seatPrice(), 50e6);
    }

    function test_setSeatPriceIsGone() public {
        // Direct repricing no longer exists; only the vote path moves the price.
        // (Compile-time property: this test just documents it. Call via low-level to prove no selector.)
        (bool ok,) = address(community).call(abi.encodeWithSignature("setSeatPrice(uint256)", 80e6));
        assertFalse(ok);
    }

    function _joinOpen(address who) internal {
        _attest(who);
        uint256 price = community.seatPrice();
        usdc.mint(who, price);
        vm.prank(who);
        usdc.approve(address(community), price);
        _joinAs(address(community), who);
    }

    /// Regression: a superseded vote id must never accept a late ballot, even after a
    /// fresh vote has started and freed the slot for reuse.
    function test_castVoteOnStaleVoteIdReverts() public {
        // A superseded vote id is always past its deadline (slots only free after resolution),
        // so a late ballot on it must land VoteWindowClosed, never count toward anything.
        uint256 staleId = startAndFailARemovalVote(); // propose, vote it down, warp past deadline
        // A failed host vote waits the cooldown before another.
        vm.warp(block.timestamp + config.removalReproposeCooldown());
        vm.prank(ada);
        community.proposeRemoveHost(); // slot frees because the old vote resolved as failed
        vm.prank(ada);
        vm.expectRevert(ICommunity.VoteWindowClosed.selector);
        community.castVote(staleId, true);
    }

    function startAndFailARemovalVote() internal returns (uint256 voteId) {
        _join(ada);
        _season();
        vm.prank(ada);
        community.proposeRemoveHost();
        voteId = community.activeHostVoteId();
        vm.prank(ada);
        community.castVote(voteId, false); // 0 of 2 for: fails the threshold
        vm.warp(block.timestamp + 7 days + 1);
    }

    // ---- member removal vote ----
    // The suspension vote these replace is retired. The removal behaviour
    // is proved end to end in `test/Removal.t.sol`; what stays here are the
    // vote slot's own properties, over the same mock-sibling fixture as the host votes.

    function test_concurrentRemovalAndPriceVotes() public {
        // V3: per-kind slots. A live price vote must not block a removal vote, and two
        // different targets may have live removal votes at once.
        _join(ada);
        _join(bem);
        _join(cy);
        _season();
        vm.startPrank(host);
        community.proposeSeatPrice(80e6);
        community.proposeRemoval(bem);
        community.proposeRemoval(cy);
        vm.stopPrank();
        assertTrue(community.activePriceVoteId() != 0);
        assertTrue(community.activeRemovalVoteId(bem) != 0);
        assertTrue(community.activeRemovalVoteId(cy) != 0);
    }

    /// Each refusal `proposeRemoval` owes, other than the host-only gate (proof 1) and the
    /// cooldown (proof 7): the host as target, a target that is not an Active seat, and a
    /// live vote against the same member.
    function test_proposeRemoval_refusesTheHostANonMemberAndALiveVote() public {
        _join(ada);
        _join(bem);
        vm.startPrank(host);
        vm.expectRevert(ICommunity.CannotRemoveHost.selector);
        community.proposeRemoval(host);
        vm.expectRevert(ICommunity.TargetNotMember.selector);
        community.proposeRemoval(cy); // never joined
        community.proposeRemoval(ada);
        vm.expectRevert(ICommunity.VoteActive.selector);
        community.proposeRemoval(ada);
        vm.stopPrank();

        vm.prank(bem);
        community.forfeit();
        vm.prank(host);
        vm.expectRevert(ICommunity.TargetNotMember.selector);
        community.proposeRemoval(bem); // Left is final
    }

    /// A vacant role has nobody to propose. The first check in `proposeRemoval`, so a vacancy
    /// reads as what it is rather than as `NotHost` from address zero.
    function test_proposeRemoval_refusedWhileTheHostIsVacant() public {
        _join(ada);
        _join(bem);
        _join(cy);
        _season();
        vm.prank(ada);
        community.proposeRemoveHost();
        voteYes(community.activeHostVoteId(), _electorate(ada, bem, cy));
        vm.warp(block.timestamp + 7 days + 1);
        community.executeRemoveHost();
        assertTrue(community.hostVacant());

        vm.expectRevert(ICommunity.HostVacant.selector);
        community.proposeRemoval(ada);
    }

    /// Execution waits for the window, needs the threshold, and runs once.
    function test_executeRemoval_waitsNeedsThePassAndRunsOnce() public {
        _join(ada);
        _join(bem);
        _join(cy);
        _season();
        vm.expectRevert(ICommunity.NoActiveVote.selector);
        community.executeRemoval(bem);

        vm.prank(host);
        community.proposeRemoval(bem);
        voteYes(community.activeRemovalVoteId(bem), _electorate(host, ada, cy)); // 3 of 4
        vm.expectRevert(ICommunity.VoteWindowOpen.selector);
        community.executeRemoval(bem);

        vm.warp(block.timestamp + 7 days + 1);
        community.executeRemoval(bem);
        assertEq(community.memberCount(), 3);
        vm.expectRevert(ICommunity.NoActiveVote.selector); // the slot cleared: no second decrement
        community.executeRemoval(bem);

        // 1 of the 3 left is not more than half.
        vm.prank(host);
        community.proposeRemoval(cy);
        uint256 cyVote = community.activeRemovalVoteId(cy);
        vm.prank(host);
        community.castVote(cyVote, true);
        vm.warp(block.timestamp + 7 days + 1);
        vm.expectRevert(ICommunity.NotPassed.selector);
        community.executeRemoval(cy);
    }

    function _electorate(address a, address b, address c) internal pure returns (address[] memory v) {
        v = new address[](3);
        v[0] = a;
        v[1] = b;
        v[2] = c;
    }
}
