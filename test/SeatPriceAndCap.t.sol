// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.30;

import {stdStorage, StdStorage} from "forge-std/StdStorage.sol";
import {Community} from "../src/Community.sol";
import {ICommunity} from "../src/interfaces/ICommunity.sol";
import {ICommunityFactory} from "../src/interfaces/ICommunityFactory.sol";
import {ConfigKeys as K} from "../src/ConfigKeys.sol";
import {MembershipFixture} from "./helpers/MembershipFixture.sol";

/// A host prices seats from $0 to $100, at creation and by a price vote alike, and a $0 seat
/// moves no money at all. A community holds at most `MEMBER_CAP` Active seats.
contract SeatPriceAndCapTest is MembershipFixture {
    using stdStorage for StdStorage;

    uint256 constant CEILING = 100e6;

    // ---- proof 9: the price range ----

    function test_proof9_aFreeCommunityJoinMovesNoUsdcAndRecordsZero() public {
        Community c = _create(host, 0);
        _attest(ada);
        uint256 hostBefore = usdc.balanceOf(host);
        uint256 treasuryBefore = usdc.balanceOf(treasury);
        uint256 coreBefore = usdc.balanceOf(address(core));

        // No USDC and no approval: the join needs neither.
        _joinAs(address(c), ada);

        assertTrue(c.isMember(ada));
        assertEq(seats.seatInfo(c.tokenOf(ada)).pricePaid, 0, "pricePaid is 0");
        assertEq(usdc.balanceOf(ada), 0);
        assertEq(usdc.balanceOf(host), hostBefore, "no host leg");
        assertEq(usdc.balanceOf(treasury), treasuryBefore, "no protocol leg");
        assertEq(usdc.balanceOf(address(core)), coreBefore, "no community leg");
        assertEq(core.totalLegs(), 0, "no leg booked");
    }

    /// A free seat needs no `CreditCore` either: nothing is split, so nothing needs a destination.
    function test_proof9_aFreeJoinSplitsNothingEvenWithNoCreditCoreWired() public {
        Community c = _create(host, 0);
        // Config refuses a zero address, so the slot is cleared directly.
        stdstore.target(address(config)).sig(config.creditCore.selector).checked_write(address(0));
        assertEq(config.creditCore(), address(0));
        _attest(ada);
        _joinAs(address(c), ada);
        assertTrue(c.isMember(ada));
    }

    function test_proof9_aHundredDollarCommunityWorks() public {
        Community c = _create(host, CEILING);
        _join(c, ada);
        assertEq(seats.seatInfo(c.tokenOf(ada)).pricePaid, CEILING);
        assertEq(usdc.balanceOf(host), CEILING * 3000 / 10_000, "the host leg");
        assertEq(core.legOf(0), CEILING * 4000 / 10_000, "the community leg");
    }

    function test_proof9_aboveTheCeilingRevertsAtCreation() public {
        assertEq(config.seatPriceCeiling(), CEILING);
        assertEq(config.seatPriceFloor(), 0);
        vm.prank(host);
        vm.expectRevert(ICommunityFactory.SeatPriceAboveCeiling.selector);
        factory.createCommunity("Too Dear", CEILING + 1);
        vm.prank(host);
        vm.expectRevert(ICommunityFactory.SeatPriceAboveCeiling.selector);
        factory.createCommunity("Too Dear", 100_010_000); // $100.01
    }

    function test_proof9_aPriceVoteIsBoundedByTheSameRange() public {
        Community c = _create(host, PRICE);
        vm.prank(host);
        vm.expectRevert(ICommunity.AboveCeiling.selector);
        c.proposeSeatPrice(CEILING + 1);

        // $0 and $100 are both proposable, and a vote to $0 carries to a free seat.
        _join(c, ada);
        _join(c, bem);
        _season();
        vm.prank(host);
        c.proposeSeatPrice(0);
        uint256 voteId = c.activePriceVoteId();
        _vote(c, voteId, host, true);
        _vote(c, voteId, ada, true);
        _vote(c, voteId, bem, true);
        _pastWindow();
        c.executeSeatPriceVote();
        assertEq(c.seatPrice(), 0);
    }

    /// The range is re-checked when the vote executes: a ceiling lowered mid-vote is not
    /// undercut by a proposal made before it.
    function test_proof9_aPriceVoteRechecksTheCeilingAtExecution() public {
        Community c = _create(host, PRICE);
        _join(c, ada);
        _join(c, bem);
        _season();
        vm.prank(host);
        c.proposeSeatPrice(CEILING);
        uint256 voteId = c.activePriceVoteId();
        _vote(c, voteId, host, true);
        _vote(c, voteId, ada, true);
        _vote(c, voteId, bem, true);
        _pastWindow();
        config.set(K.SEAT_PRICE_CEILING, 80e6);
        vm.expectRevert(ICommunity.AboveCeiling.selector);
        c.executeSeatPriceVote();
    }

    // ---- proof 10: the member cap ----

    /// The 150th seat is taken and the 151st is refused. A seat that leaves frees a place.
    function test_proof10_theCapSeats150AndRefuses151_andALeaverFreesAPlace() public {
        assertEq(config.memberCap(), 150);
        Community c = _create(host, 0); // free, to keep 150 joins cheap; the cap ignores price
        for (uint256 i = 2; i <= 150; i++) {
            address who = makeAddr(string.concat("member", vm.toString(i)));
            _attest(who);
            _joinAs(address(c), who);
        }
        assertEq(c.memberCount(), 150, "the 150th seat is taken");

        address extra = makeAddr("extra");
        _attest(extra);
        (address inviteKey, bytes memory keySig) = _inviteFor(address(c), extra);
        vm.prank(extra);
        vm.expectRevert(ICommunity.CommunityFull.selector);
        c.join(inviteKey, keySig);

        vm.prank(makeAddr("member2"));
        c.forfeit();
        assertEq(c.memberCount(), 149);
        vm.prank(extra);
        c.join(inviteKey, keySig);
        assertEq(c.memberCount(), 150, "the place the leaver freed is taken");
    }
}
