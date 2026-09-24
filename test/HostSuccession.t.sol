// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.30;

import {Community} from "../src/Community.sol";
import {ICommunity} from "../src/interfaces/ICommunity.sol";
import {MembershipFixture} from "./helpers/MembershipFixture.sol";

/// The host role changes four ways, each with the bar its risk deserves. A handover the host
/// starts and the members can block by a majority. A resignation the host alone decides, which
/// only empties the seat. A removal, which needs more than two thirds. An election into an empty
/// seat, which needs more than half, so that a small group is not left without a host.
contract HostSuccessionTest is MembershipFixture {
    Community c;
    address eve = makeAddr("eve");
    address fay = makeAddr("fay");
    address gus = makeAddr("gus");

    /// The host and seven members, all seasoned. With ada nominated, the objection denominator
    /// is the six others.
    function setUp() public override {
        super.setUp();
        c = _create(host, PRICE);
        address[7] memory m = [ada, bem, cy, dee, eve, fay, gus];
        for (uint256 i; i < m.length; i++) {
            _join(c, m[i]);
        }
        _season();
    }

    function _nominate(address nominee) internal {
        vm.prank(c.host());
        c.nominateSuccessor(nominee);
    }

    function _accept(address nominee) internal {
        vm.prank(nominee);
        c.acceptNomination();
    }

    function _object(address who) internal {
        vm.prank(who);
        c.objectToHandover();
    }

    function _noPending() internal view {
        ICommunity.PendingHandover memory p = c.pendingHandover();
        assertEq(p.nominee, address(0), "no nomination is pending");
        assertEq(p.voteId, 0);
    }

    // ---- proof 1: the happy path ----

    function test_proof1_aHandoverNobodyBlocksCompletes() public {
        _nominate(ada);
        ICommunity.PendingHandover memory p = c.pendingHandover();
        assertEq(p.nominee, ada);
        assertEq(p.nominatedAt, block.timestamp);
        assertEq(p.acceptedAt, 0, "not accepted yet");

        vm.warp(block.timestamp + 1 days);
        _accept(ada);
        p = c.pendingHandover();
        assertEq(p.acceptedAt, block.timestamp);
        assertEq(p.objectionDeadline, block.timestamp + 7 days);
        assertEq(p.denominator, 6, "the eight seasoned seats less the host and the nominee");
        assertEq(p.objections, 0);
        ICommunity.VoteTally memory t = c.voteTally(p.voteId);
        assertEq(uint8(t.kind), uint8(ICommunity.VoteKind.Handover));
        assertEq(t.target, ada);
        assertEq(t.denominator, 6);

        // Not before the objection period ends.
        vm.warp(p.objectionDeadline);
        vm.expectRevert(ICommunity.VoteWindowOpen.selector);
        c.completeHandover();

        vm.warp(p.objectionDeadline + 1);
        vm.expectEmit(true, true, false, false);
        emit ICommunity.HostChanged(host, ada, uint8(ICommunity.HostChange.Handover));
        vm.prank(makeAddr("anyone"));
        c.completeHandover();

        assertEq(c.host(), ada);
        assertTrue(c.isMember(host), "the old host is an ordinary Active member");
        assertEq(uint8(c.seatStateOf(host)), uint8(ICommunity.SeatState.Active));
        _noPending();
        vm.expectRevert(ICommunity.NoActiveVote.selector);
        c.completeHandover();
    }

    /// While a handover is pending the host keeps every power.
    function test_theHostKeepsEveryPowerWhileAHandoverIsPending() public {
        _nominate(ada);
        _accept(ada);
        vm.startPrank(host);
        c.createInvite(makeAddr("key"), 1, uint64(block.timestamp + 1 days));
        c.proposeSeatPrice(60e6);
        c.proposeRemoval(bem);
        vm.stopPrank();
    }

    // ---- proof 2: who can be nominated ----

    function test_proof2_onlyASeasonedActiveUnfrozenMemberOtherThanTheHostCanBeNominated() public {
        address fresh = makeAddr("fresh");
        _join(c, fresh); // Active, not yet seasoned
        vm.prank(host);
        c.proposeRemoval(bem); // bem is frozen

        address[4] memory refused = [fresh, bem, makeAddr("stranger"), host];
        for (uint256 i; i < refused.length; i++) {
            vm.prank(host);
            vm.expectRevert(ICommunity.NomineeIneligible.selector);
            c.nominateSuccessor(refused[i]);
        }

        vm.prank(ada);
        vm.expectRevert(ICommunity.NotHost.selector);
        c.nominateSuccessor(cy);

        // The same nomination of a qualifying member goes through.
        _nominate(cy);
        assertEq(c.pendingHandover().nominee, cy);
    }

    // ---- proof 3: the acceptance window ----

    function test_proof3_aNominationLapsesAfterSevenDaysWithNoCooldown() public {
        _nominate(ada);
        vm.prank(bem);
        vm.expectRevert(ICommunity.NotNominee.selector);
        c.acceptNomination();

        // A second nomination waits for the first to resolve.
        vm.prank(host);
        vm.expectRevert(ICommunity.NominationPending.selector);
        c.nominateSuccessor(bem);

        vm.warp(block.timestamp + 7 days + 1);
        vm.prank(ada);
        vm.expectRevert(ICommunity.NominationLapsed.selector);
        c.acceptNomination();
        _noPending();

        // Lapsing starts no cooldown.
        _nominate(bem);
        assertEq(c.pendingHandover().nominee, bem);
    }

    function test_proof3_theLastSecondOfTheWindowStillAccepts() public {
        _nominate(ada);
        vm.warp(block.timestamp + 7 days);
        _accept(ada);
        assertGt(c.pendingHandover().acceptedAt, 0);

        // Accepting twice is refused.
        vm.prank(ada);
        vm.expectRevert(ICommunity.NominationPending.selector);
        c.acceptNomination();
    }

    // ---- proof 4: objections ----

    function test_proof4_threeObjectionsOfSixDoNotBlock() public {
        _nominate(ada);
        _accept(ada);
        _object(bem);
        _object(cy);
        _object(dee);
        ICommunity.PendingHandover memory p = c.pendingHandover();
        assertEq(p.objections, 3);
        assertEq(c.voteTally(p.voteId).no, 3, "the tally view shows the objections");

        _pastWindow();
        c.completeHandover();
        assertEq(c.host(), ada, "half is not more than half");
    }

    function test_proof4_fourObjectionsOfSixBlockAndStartTheCooldown() public {
        _nominate(ada);
        _accept(ada);
        _object(bem);
        _object(cy);
        _object(dee);
        vm.expectEmit(true, false, false, false);
        emit ICommunity.HandoverFailed(ada);
        _object(eve);
        uint256 failedAt = block.timestamp;

        _noPending();
        assertEq(c.host(), host);
        vm.expectRevert(ICommunity.NoActiveVote.selector);
        c.completeHandover();
        vm.expectRevert(ICommunity.NoNomination.selector);
        vm.prank(host);
        c.cancelNomination();

        vm.warp(failedAt + 30 days - 1);
        vm.prank(host);
        vm.expectRevert(ICommunity.HandoverCooldown.selector);
        c.nominateSuccessor(bem);
        vm.warp(failedAt + 30 days);
        _nominate(bem);
    }

    function test_proof4_eachCountedMemberObjectsOnceAndNoOneElse() public {
        address late = makeAddr("late");
        _join(c, late); // joins before acceptance, but is not seasoned at it

        _nominate(ada);
        vm.prank(bem);
        vm.expectRevert(ICommunity.NoActiveVote.selector);
        c.objectToHandover(); // nothing to object to before acceptance
        _accept(ada);

        _object(bem);
        vm.prank(bem);
        vm.expectRevert(ICommunity.AlreadyVoted.selector);
        c.objectToHandover();

        vm.prank(host);
        vm.expectRevert(ICommunity.VoteIneligible.selector);
        c.objectToHandover();
        vm.prank(ada);
        vm.expectRevert(ICommunity.VoteIneligible.selector);
        c.objectToHandover();
        vm.prank(late);
        vm.expectRevert(ICommunity.VoteIneligible.selector);
        c.objectToHandover();
        vm.prank(makeAddr("stranger"));
        vm.expectRevert(ICommunity.NotMember.selector);
        c.objectToHandover();

        // The objection period is not an ordinary vote: nobody votes yes on it.
        uint256 voteId = c.pendingHandover().voteId;
        vm.prank(cy);
        vm.expectRevert(ICommunity.NoActiveVote.selector);
        c.castVote(voteId, false);

        vm.warp(c.pendingHandover().objectionDeadline + 1);
        vm.prank(cy);
        vm.expectRevert(ICommunity.VoteWindowClosed.selector);
        c.objectToHandover();
        assertEq(c.pendingHandover().objections, 1);
    }

    // ---- proof 5: a host cannot escape a removal by handing the seat on ----

    function test_proof5_proposingARemovalCancelsAnAcceptedHandover() public {
        _nominate(ada);
        _accept(ada);
        vm.expectEmit(true, false, false, false);
        emit ICommunity.NominationCancelled(ada);
        vm.prank(bem);
        c.proposeRemoveHost();
        _noPending();
        vm.expectRevert(ICommunity.NoActiveVote.selector);
        c.completeHandover();
    }

    function test_proof5_proposingARemovalCancelsANominationNotYetAccepted() public {
        _nominate(ada);
        vm.prank(bem);
        c.proposeRemoveHost();
        _noPending();
        vm.prank(ada);
        vm.expectRevert(ICommunity.NoNomination.selector);
        c.acceptNomination();
    }

    function test_proof5_noNominationOrResignationWhileARemovalVoteIsOpen() public {
        vm.prank(bem);
        c.proposeRemoveHost();

        vm.startPrank(host);
        vm.expectRevert(ICommunity.HostVoteOpen.selector);
        c.nominateSuccessor(ada);
        vm.expectRevert(ICommunity.HostVoteOpen.selector);
        c.resignHost();
        vm.stopPrank();

        // Once the vote has failed, both are open again.
        _pastWindow();
        _nominate(ada);
    }

    // ---- proof 6: the nominee is checked again at completion ----

    function test_proof6_aNomineeFrozenBeforeCompletionFailsTheHandover() public {
        _nominate(ada);
        _accept(ada);
        // Proposed partway through, so the removal vote is still open when the period ends.
        vm.warp(block.timestamp + 3 days);
        vm.prank(host);
        c.proposeRemoval(ada);
        vm.warp(c.pendingHandover().objectionDeadline + 1);
        assertTrue(c.isFrozen(ada));

        vm.expectEmit(true, false, false, false);
        emit ICommunity.HandoverFailed(ada);
        c.completeHandover();
        assertEq(c.host(), host);
        _noPending();
        vm.prank(host);
        vm.expectRevert(ICommunity.HandoverCooldown.selector);
        c.nominateSuccessor(bem);
    }

    function test_proof6_aNomineeWhoLeftBeforeCompletionFailsTheHandover() public {
        _nominate(ada);
        _accept(ada);
        vm.prank(ada);
        c.forfeit();
        _pastWindow();

        c.completeHandover();
        assertEq(c.host(), host);
        _noPending();
        vm.prank(host);
        vm.expectRevert(ICommunity.HandoverCooldown.selector);
        c.nominateSuccessor(bem);
    }

    // ---- cancelling ----

    function test_theHostCancelsWithNoCooldown() public {
        _nominate(ada);
        _accept(ada);
        vm.prank(bem);
        vm.expectRevert(ICommunity.NotHost.selector);
        c.cancelNomination();

        vm.expectEmit(true, false, false, false);
        emit ICommunity.NominationCancelled(ada);
        vm.prank(host);
        c.cancelNomination();
        _noPending();

        _nominate(bem);
        assertEq(c.pendingHandover().nominee, bem);
    }

    // ---- proof 7: resignation ----

    function test_proof7_theHostResignsAndStaysAMember() public {
        address key = makeAddr("old key");
        vm.prank(host);
        c.createInvite(key, 5, uint64(block.timestamp + 30 days));

        vm.prank(ada);
        vm.expectRevert(ICommunity.NotHost.selector);
        c.resignHost();

        vm.expectEmit(true, true, false, false);
        emit ICommunity.HostChanged(host, address(0), uint8(ICommunity.HostChange.Resignation));
        _resign(c);
        assertTrue(c.hostVacant());
        assertTrue(c.isMember(host), "the old host keeps their seat");

        // The old host's invites fail at join: first on the empty seat, then as the old term's.
        address joiner = _keyed("joiner");
        _attest(joiner);
        bytes memory keySig = _keySign(uint256(keccak256("unused")), address(c), joiner);
        vm.prank(joiner);
        vm.expectRevert(ICommunity.HostVacant.selector);
        c.join(key, keySig);

        // An election follows: five of the eight seasoned members is more than half.
        _elect(c, bem, _five(ada, bem, cy, dee, eve));
        assertEq(c.host(), bem);
        vm.prank(joiner);
        vm.expectRevert(ICommunity.InviteStale.selector);
        c.join(key, keySig);

        // Now an ordinary member, the old host can leave.
        vm.prank(host);
        c.forfeit();
    }

    function test_proof7_noResignationWhileANominationIsPending() public {
        _nominate(ada);
        vm.prank(host);
        vm.expectRevert(ICommunity.NominationPending.selector);
        c.resignHost();

        vm.prank(host);
        c.cancelNomination();
        _resign(c);
        assertTrue(c.hostVacant());
    }

    // ---- proof 8: the election threshold ----

    /// A community of the host and five members, all seasoned.
    function _six() internal returns (Community s) {
        s = _create(host, PRICE);
        address[5] memory m = [ada, bem, cy, dee, eve];
        for (uint256 i; i < m.length; i++) {
            _join(s, m[i]);
        }
        _season();
    }

    function test_proof8_sixVotersElectWithFourYesVotesAndNotThree() public {
        Community s = _six();
        _resign(s);

        vm.prank(ada);
        s.electHost(ada);
        uint256 voteId = s.activeHostVoteId();
        ICommunity.VoteTally memory t = s.voteTally(voteId);
        (uint16 communityBps,) = config.communityVote();
        assertEq(t.denominator, 6);
        assertEq(t.thresholdBps, communityBps, "an election is a community vote");
        _vote(s, voteId, ada, true);
        _vote(s, voteId, bem, true);
        _vote(s, voteId, cy, true);
        _pastWindow();
        vm.expectRevert(ICommunity.NotPassed.selector);
        s.executeRemoveHost();

        _elect(s, ada, _four(ada, bem, cy, dee));
        assertEq(s.host(), ada, "four of six is more than half");
    }

    function test_proof8_twoVotersElectWithTwoYesVotes() public {
        Community s = _create(host, PRICE);
        _join(s, ada);
        _season();
        _resign(s);

        vm.prank(ada);
        s.electHost(ada);
        uint256 voteId = s.activeHostVoteId();
        _vote(s, voteId, ada, true);
        _pastWindow();
        vm.expectRevert(ICommunity.NotPassed.selector);
        s.executeRemoveHost();

        vm.prank(ada);
        s.electHost(ada);
        voteId = s.activeHostVoteId();
        _vote(s, voteId, ada, true);
        _vote(s, voteId, host, true);
        _pastWindow();
        s.executeRemoveHost();
        assertEq(s.host(), ada);
    }

    function test_proof8_removingTheHostOfSixStillNeedsFive() public {
        Community s = _six();
        vm.prank(ada);
        s.proposeRemoveHost();
        uint256 voteId = s.activeHostVoteId();
        ICommunity.VoteTally memory t = s.voteTally(voteId);
        (uint16 hostBps,) = config.hostVote();
        assertEq(t.denominator, 6);
        assertEq(t.thresholdBps, hostBps, "a removal keeps the host-vote threshold");
        assertEq(t.minYes, 3);
        address[4] memory yes = [ada, bem, cy, dee];
        for (uint256 i; i < yes.length; i++) {
            _vote(s, voteId, yes[i], true);
        }
        _pastWindow();
        vm.expectRevert(ICommunity.NotPassed.selector);
        s.executeRemoveHost();

        // The failed vote's cooldown passes, and five of six carry the next one.
        vm.warp(block.timestamp + 30 days);
        _removeHost(s, _five(ada, bem, cy, dee, eve));
        assertTrue(s.hostVacant());
    }

    function _four(address a, address b, address d, address e) internal pure returns (address[] memory m) {
        m = new address[](4);
        (m[0], m[1], m[2], m[3]) = (a, b, d, e);
    }

    function _five(address a, address b, address d, address e, address f) internal pure returns (address[] memory m) {
        m = new address[](5);
        (m[0], m[1], m[2], m[3], m[4]) = (a, b, d, e, f);
    }
}
