// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.30;

import {Community} from "../src/Community.sol";
import {ICommunity} from "../src/interfaces/ICommunity.sol";
import {ConfigKeys as K} from "../src/ConfigKeys.sol";
import {MembershipFixture} from "./helpers/MembershipFixture.sol";

/// An election needs `min(3, voters)` yes votes and never fewer than 1, so a community that lost
/// its host with one or two seasoned members left can still elect one of them: they are the
/// community, and with no host nobody can join and no shared-vault withdrawal can be proposed.
/// Every other vote keeps the floor of 3, so a host still cannot remove anyone alone.
contract ElectionFloorTest is MembershipFixture {
    /// A community of the host and `members`, all seasoned, whose host ada, bem and cy then vote
    /// out. The host keeps an Active seat and a vote.
    function _vacated(address[] memory members) internal returns (Community c) {
        c = _create(host, PRICE);
        for (uint256 i; i < members.length; i++) {
            _join(c, members[i]);
        }
        _season();
        vm.prank(ada);
        c.proposeRemoveSteward();
        uint256 voteId = c.activeStewardVoteId();
        _vote(c, voteId, ada, true);
        _vote(c, voteId, bem, true);
        _vote(c, voteId, cy, true);
        _pastWindow();
        c.executeRemoveSteward();
        assertTrue(c.stewardVacant());
    }

    function _four() internal view returns (address[] memory m) {
        m = new address[](3);
        m[0] = ada;
        m[1] = bem;
        m[2] = cy;
    }

    function _leave(Community c, address who) internal {
        vm.prank(who);
        c.forfeit();
    }

    function _elect(Community c, address candidate) internal returns (uint256 voteId) {
        vm.prank(candidate);
        c.electSteward(candidate);
        voteId = c.activeStewardVoteId();
    }

    /// What the tally view says a vote needs: the bars `_passed` applies.
    function _tallyPasses(Community c, uint256 voteId) internal view returns (bool) {
        ICommunity.VoteTally memory t = c.voteTally(voteId);
        return t.yes >= t.minYes && uint256(t.yes) * 10_000 >= uint256(t.thresholdBps) * t.denominator;
    }

    /// Executes the vote in the steward slot after its window, and checks the outcome is exactly
    /// what the tally view predicted.
    function _execute(Community c, uint256 voteId) internal returns (bool passed) {
        _pastWindow();
        bool predicted = _tallyPasses(c, voteId);
        try c.executeRemoveSteward() {
            passed = true;
        } catch (bytes memory reason) {
            assertEq(bytes4(reason), ICommunity.NotPassed.selector, "only the tally refuses");
        }
        assertEq(passed, predicted, "the tally view matches what execution used");
    }

    function test_proof11_twoSeasonedVotersElectWithTwoYesVotes() public {
        Community c = _vacated(_four());
        _leave(c, bem);
        _leave(c, cy);

        uint256 voteId = _elect(c, ada);
        ICommunity.VoteTally memory t = c.voteTally(voteId);
        assertEq(t.denominator, 2, "the host and ada");
        assertEq(t.minYes, 2);
        _vote(c, voteId, ada, true);
        assertFalse(_execute(c, voteId), "one yes of two voters is not enough");

        voteId = _elect(c, ada);
        _vote(c, voteId, ada, true);
        _vote(c, voteId, host, true);
        assertTrue(_execute(c, voteId), "two yes votes elect");
        assertEq(c.steward(), ada);
    }

    function test_proof11_aLoneSeasonedVoterElectsThemselves() public {
        Community c = _vacated(_four());
        _leave(c, bem);
        _leave(c, cy);
        _leave(c, host);

        uint256 voteId = _elect(c, ada);
        ICommunity.VoteTally memory t = c.voteTally(voteId);
        assertEq(t.denominator, 1);
        assertEq(t.minYes, 1);
        _vote(c, voteId, ada, true);
        assertTrue(_execute(c, voteId));
        assertEq(c.steward(), ada);
    }

    /// With no seasoned voter the floor is still 1, so no election can pass on no votes at all.
    function test_proof11_noSeasonedVoterCanNeverElect() public {
        Community c = _create(host, PRICE);
        _join(c, ada);
        _join(c, bem);
        _join(c, cy);
        _season();
        _join(c, dee); // joins as the host vote opens, so is unseasoned at the election
        vm.prank(ada);
        c.proposeRemoveSteward();
        uint256 voteId = c.activeStewardVoteId();
        _vote(c, voteId, ada, true);
        _vote(c, voteId, bem, true);
        _vote(c, voteId, cy, true);
        _pastWindow();
        c.executeRemoveSteward();
        _leave(c, host);
        _leave(c, ada);
        _leave(c, bem);
        _leave(c, cy);

        voteId = _elect(c, dee);
        ICommunity.VoteTally memory t = c.voteTally(voteId);
        assertEq(t.denominator, 0, "dee is not seasoned when the vote starts");
        assertEq(t.minYes, 1, "the floor never drops below 1");
        vm.prank(dee);
        vm.expectRevert(ICommunity.VoteIneligible.selector);
        c.castVote(voteId, true);
        assertFalse(_execute(c, voteId), "no votes elect nobody");
        assertTrue(c.stewardVacant());
    }

    /// Four voters: the floor is 3, not 4 and not 2.
    function test_proof11_fourVotersStillNeedThreeYesVotes() public {
        Community c = _vacated(_four());
        uint256 voteId = _elect(c, ada);
        assertEq(c.voteTally(voteId).denominator, 4);
        assertEq(c.voteTally(voteId).minYes, 3);
        _vote(c, voteId, ada, true);
        _vote(c, voteId, bem, true);
        assertFalse(_execute(c, voteId));

        voteId = _elect(c, ada);
        _vote(c, voteId, ada, true);
        _vote(c, voteId, bem, true);
        _vote(c, voteId, cy, true);
        assertTrue(_execute(c, voteId), "three of four elect");
    }

    /// Three voters under the lowest threshold config allows, which an election uses: two yes
    /// votes clear the threshold, and only the floor of 3 refuses them.
    function test_proof11_threeVotersNeedThreeEvenWhenTheThresholdWouldTakeTwo() public {
        Community c = _vacated(_four());
        _leave(c, cy);
        config.set(K.COMMUNITY_VOTE_THRESHOLD_BPS, 5001);

        uint256 voteId = _elect(c, ada);
        assertEq(c.voteTally(voteId).minYes, 3);
        _vote(c, voteId, ada, true);
        _vote(c, voteId, bem, true);
        assertFalse(_execute(c, voteId), "2 * 10_000 >= 5001 * 3, and still refused");

        voteId = _elect(c, ada);
        _vote(c, voteId, ada, true);
        _vote(c, voteId, bem, true);
        _vote(c, voteId, host, true);
        assertTrue(_execute(c, voteId));
    }

    /// Removal, host removal and price votes keep the full floor of 3: two voters who clear the
    /// threshold between them still cannot pass one.
    function test_proof11_everyOtherVoteKindStillNeedsThree() public {
        // A price vote with the host and ada as the only seasoned voters.
        Community p = _create(host, PRICE);
        _join(p, ada);
        // A host removal with the same two.
        Community h = _create(host, PRICE);
        _join(h, ada);
        // A removal of bem, where the host and ada are the voters.
        Community r = _create(host, PRICE);
        _join(r, ada);
        _join(r, bem);
        _season();

        vm.prank(host);
        p.proposeSeatPrice(60e6);
        uint256 priceVote = p.activePriceVoteId();
        vm.prank(ada);
        h.proposeRemoveSteward();
        uint256 hostVote = h.activeStewardVoteId();
        vm.prank(host);
        r.proposeRemoval(bem);
        uint256 removalVote = r.activeRemovalVoteId(bem);

        _vote(p, priceVote, host, true);
        _vote(p, priceVote, ada, true);
        _vote(h, hostVote, host, true);
        _vote(h, hostVote, ada, true);
        _vote(r, removalVote, host, true);
        _vote(r, removalVote, ada, true);
        assertEq(p.voteTally(priceVote).minYes, 3);
        assertEq(h.voteTally(hostVote).minYes, 3);
        assertEq(r.voteTally(removalVote).minYes, 3);
        assertEq(r.voteTally(removalVote).denominator, 2);
        _pastWindow();

        vm.expectRevert(ICommunity.NotPassed.selector);
        p.executeSeatPriceVote();
        vm.expectRevert(ICommunity.NotPassed.selector);
        h.executeRemoveSteward();
        vm.expectRevert(ICommunity.NotPassed.selector);
        r.executeRemoval(bem);
        assertFalse(_tallyPasses(p, priceVote));
        assertFalse(_tallyPasses(h, hostVote));
        assertFalse(_tallyPasses(r, removalVote));
    }

    /// The tally view reports every field of the vote as stored, and the threshold as `_passed`
    /// reads it.
    function test_proof11_theTallyViewReportsTheVote() public {
        Community c = _vacated(_four());
        uint256 voteId = _elect(c, ada);
        _vote(c, voteId, ada, true);
        _vote(c, voteId, bem, false);
        ICommunity.VoteTally memory t = c.voteTally(voteId);
        (uint16 thresholdBps, uint64 window) = config.communityVote();
        assertEq(uint8(t.kind), uint8(ICommunity.VoteKind.Election));
        assertEq(t.target, ada);
        assertEq(t.deadline, block.timestamp + window);
        assertEq(t.denominator, 4);
        assertEq(t.yes, 1);
        assertEq(t.no, 1);
        assertEq(t.thresholdBps, thresholdBps);
        assertEq(t.minYes, 3);
    }
}
