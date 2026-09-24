// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.30;

import {Base64} from "openzeppelin-contracts/contracts/utils/Base64.sol";
import {Community} from "../src/Community.sol";
import {ICommunity} from "../src/interfaces/ICommunity.sol";
import {ISeats} from "../src/interfaces/ISeats.sol";
import {MembershipFixture} from "./helpers/MembershipFixture.sol";

/// Every community's seats live in one soulbound ERC-721, so the app lists a wallet's communities
/// from one address. A seat is minted only by its own community, changes state only by its own
/// community, never moves, and bars a second seat in the same community for good.
contract SeatsTest is MembershipFixture {
    function _state(uint256 tokenId) internal view returns (ICommunity.SeatState) {
        return seats.seatInfo(tokenId).state;
    }

    /// A wallet in three communities: one collection, three tokens, each naming its community,
    /// its number there and its state.
    function test_proof1_aWalletInThreeCommunitiesIsThreeSeatsOnOneContract() public {
        Community a = _create(host, PRICE);
        Community b = _create(host, PRICE);
        Community c = _create(host, 0);
        _join(a, bem); // seat 2 in A, so ada's numbers differ across communities
        _join(a, ada); // seat 3 in A
        _join(b, ada); // seat 2 in B
        _join(c, cy);
        _join(c, dee);
        _join(c, ada); // seat 4 in C
        vm.prank(ada);
        b.forfeit(); // Left in B

        assertEq(seats.balanceOf(ada), 3, "one token per community");
        Community[3] memory expected = [a, b, c];
        uint256[3] memory numbers = [uint256(3), 2, 4];
        ICommunity.SeatState[3] memory states =
            [ICommunity.SeatState.Active, ICommunity.SeatState.Left, ICommunity.SeatState.Active];
        for (uint256 i; i < 3; i++) {
            uint256 tokenId = seats.tokenOfOwnerByIndex(ada, i);
            ISeats.Seat memory s = seats.seatInfo(tokenId);
            assertEq(s.community, address(expected[i]), "the community");
            assertEq(s.communityId, i, "the community id");
            assertEq(s.seatNumber, numbers[i], "the seat number there");
            assertEq(uint8(s.state), uint8(states[i]), "the state");
            assertEq(s.mintedAt, block.timestamp, "the mint time");
            assertEq(seats.seatOf(address(expected[i]), ada), tokenId, "seatOf agrees");
            assertEq(expected[i].tokenOf(ada), tokenId, "the community reads the same token");
        }
        assertEq(seats.seatInfo(seats.seatOf(address(a), host)).seatNumber, 1, "the host's founding seat is 1");
        assertEq(seats.seatInfo(seats.seatOf(address(c), ada)).pricePaid, 0, "a free seat records 0");
        assertEq(seats.seatInfo(seats.seatOf(address(a), ada)).pricePaid, PRICE, "a paid seat records its price");
        assertEq(seats.name(), "Qudi Seats");
        assertEq(seats.symbol(), "QSEAT");
    }

    /// Every transfer and approval path reverts, for the owner and for anyone else.
    function test_proof2_everyTransferAndApprovalPathReverts() public {
        Community a = _create(host, PRICE);
        _join(a, ada);
        uint256 tokenId = seats.seatOf(address(a), ada);

        vm.startPrank(ada);
        vm.expectRevert(ISeats.Soulbound.selector);
        seats.transferFrom(ada, bem, tokenId);
        vm.expectRevert(ISeats.Soulbound.selector);
        seats.safeTransferFrom(ada, bem, tokenId);
        vm.expectRevert(ISeats.Soulbound.selector);
        seats.safeTransferFrom(ada, bem, tokenId, "");
        vm.expectRevert(ISeats.Soulbound.selector);
        seats.approve(bem, tokenId);
        vm.expectRevert(ISeats.Soulbound.selector);
        seats.setApprovalForAll(bem, true);
        vm.stopPrank();

        assertEq(seats.ownerOf(tokenId), ada, "the seat did not move");
        assertEq(seats.getApproved(tokenId), address(0));
        assertFalse(seats.isApprovedForAll(ada, bem));
    }

    /// A Left seat and a Suspended seat each refuse a second seat in the same community, and
    /// neither stops the wallet joining a different one.
    function test_proof3_aLeftOrSuspendedSeatBarsRejoining_butNotAnotherCommunity() public {
        Community a = _create(host, PRICE);
        Community b = _create(host, PRICE);
        _join(a, ada);
        _join(a, bem);
        _join(a, cy);
        _join(a, dee);
        _season();

        // dee is removed: host, ada and bem carry it, 3 of the 4 seasoned seats besides dee.
        vm.prank(host);
        a.proposeRemoval(dee);
        uint256 voteId = a.activeRemovalVoteId(dee);
        _vote(a, voteId, host, true);
        _vote(a, voteId, ada, true);
        _vote(a, voteId, bem, true);
        _pastWindow();
        a.executeRemoval(dee);
        // cy leaves.
        vm.prank(cy);
        a.forfeit();

        assertEq(uint8(_state(seats.seatOf(address(a), dee))), uint8(ICommunity.SeatState.Suspended));
        assertEq(uint8(_state(seats.seatOf(address(a), cy))), uint8(ICommunity.SeatState.Left));

        address[2] memory barred = [dee, cy];
        for (uint256 i; i < 2; i++) {
            address who = barred[i];
            usdc.mint(who, PRICE);
            vm.prank(who);
            usdc.approve(address(a), PRICE);
            (address inviteKey, bytes memory keySig) = _inviteFor(address(a), who);
            vm.prank(who);
            vm.expectRevert(ICommunity.AlreadyMember.selector);
            a.join(inviteKey, keySig);

            _join(b, who);
            assertTrue(b.isMember(who), "a kept seat elsewhere does not bar another community");
        }
        assertEq(seats.balanceOf(dee), 2, "the Suspended seat stays beside the new one");
        assertEq(seats.balanceOf(cy), 2, "the Left seat stays beside the new one");
    }

    /// The seat bar lives in `Seats`, not only in `Community.join`: a registered community that
    /// asks to mint a second seat for the same wallet is refused.
    function test_proof3_seatsItselfRefusesASecondSeatInTheSameCommunity() public {
        Community a = _create(host, PRICE);
        vm.prank(address(a));
        vm.expectRevert(ISeats.AlreadySeated.selector);
        seats.mint(host, 0);
    }

    /// Only a community the factory registered mints, always in itself, and a community changes
    /// the state of its own seats only.
    function test_proof4_onlyARegisteredCommunityMintsAndChangesOnlyItsOwnSeats() public {
        Community a = _create(host, PRICE);
        Community b = _create(host, PRICE);
        _join(b, ada);
        uint256 adaInB = seats.seatOf(address(b), ada);

        // Not registered: an outsider, and the community's own ledger.
        vm.prank(ada);
        vm.expectRevert(ISeats.NotCommunity.selector);
        seats.mint(ada, 0);
        vm.prank(factory.ledgerOf(address(a)));
        vm.expectRevert(ISeats.NotCommunity.selector);
        seats.mint(ada, 0);

        // Nobody but the factory registers.
        vm.prank(ada);
        vm.expectRevert(ISeats.NotFactory.selector);
        seats.registerCommunity(ada, 7);
        vm.prank(address(factory));
        vm.expectRevert(ISeats.AlreadyRegistered.selector);
        seats.registerCommunity(address(a), 7);

        // A mints only in A: the seat it mints for ada is A's, and B's seat is untouched.
        vm.prank(address(a));
        uint256 adaInA = seats.mint(ada, 0);
        assertEq(seats.seatInfo(adaInA).community, address(a));
        assertEq(seats.seatOf(address(b), ada), adaInB);

        // A cannot change B's seat, and nobody else can either.
        vm.prank(address(a));
        vm.expectRevert(ISeats.NotSeatCommunity.selector);
        seats.setState(adaInB, ICommunity.SeatState.Left);
        vm.prank(ada);
        vm.expectRevert(ISeats.NotSeatCommunity.selector);
        seats.setState(adaInB, ICommunity.SeatState.Left);
        assertEq(uint8(_state(adaInB)), uint8(ICommunity.SeatState.Active));
    }

    /// Active to Suspended and Active to Left are the only moves, and both are final.
    function test_stateChangesAreActiveToSuspendedOrLeftOnly() public {
        Community a = _create(host, PRICE);
        vm.startPrank(address(a));
        uint256 one = seats.mint(ada, 0);
        uint256 two = seats.mint(bem, 0);
        vm.expectRevert(ISeats.InvalidStateChange.selector);
        seats.setState(one, ICommunity.SeatState.Active);
        vm.expectRevert(ISeats.InvalidStateChange.selector);
        seats.setState(one, ICommunity.SeatState.None);
        seats.setState(one, ICommunity.SeatState.Suspended);
        seats.setState(two, ICommunity.SeatState.Left);
        vm.expectRevert(ISeats.InvalidStateChange.selector);
        seats.setState(one, ICommunity.SeatState.Left);
        vm.expectRevert(ISeats.InvalidStateChange.selector);
        seats.setState(two, ICommunity.SeatState.Suspended);
        vm.stopPrank();
        assertEq(seats.activeCount(address(a)), 1, "only the host's seat is Active");
    }

    /// The token URI is onchain JSON with the community's name, the seat number and the state,
    /// and a name with a quote in it cannot break out of its JSON string.
    function test_tokenURI_isOnchainJsonWithNameNumberAndState() public {
        _attest(host);
        vm.prank(host);
        Community a = Community(factory.createCommunity('The "Q" Club', PRICE));
        uint256 tokenId = seats.seatOf(address(a), host);
        string memory json = string(
            abi.encodePacked(
                '{"name":"The \\"Q\\" Club seat 1","attributes":[{"trait_type":"Community","value":"The \\"Q\\" Club"},',
                '{"trait_type":"Seat number","display_type":"number","value":1},{"trait_type":"State","value":"Active"}]}'
            )
        );
        assertEq(seats.tokenURI(tokenId), string.concat("data:application/json;base64,", Base64.encode(bytes(json))));
    }
}
