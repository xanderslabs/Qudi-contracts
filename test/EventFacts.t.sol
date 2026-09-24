// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.30;

import {Vm} from "forge-std/Vm.sol";
import {Community} from "../src/Community.sol";
import {ICommunity} from "../src/interfaces/ICommunity.sol";
import {ICommunityFactory} from "../src/interfaces/ICommunityFactory.sol";
import {MembershipFixture} from "./helpers/MembershipFixture.sol";

/// The indexer builds its tables from events alone. A fact it has to read back from contract
/// state is read at a later block than the one it happened in, and can be wrong by then: a seat
/// price changed since, an invite revoked since, a host who left since. So each fact below travels
/// on the event that records it, and each test checks the full event data, not only its topics.
contract EventFactsTest is MembershipFixture {
    /// The name and starting seat price are what the community list shows. Without them on the
    /// event the indexer reads `communityName` and `seatPrice` later, and a price vote that has
    /// passed by then gives the wrong starting price.
    function test_communityCreated_carriesTheNameAndStartingPrice() public {
        address predictedCommunity = vm.computeCreateAddress(address(factory), vm.getNonce(address(factory)));
        address predictedLedger = vm.computeCreateAddress(address(factory), vm.getNonce(address(factory)) + 1);
        vm.expectEmit(true, true, false, true, address(factory));
        emit ICommunityFactory.CommunityCreated(0, host, predictedCommunity, predictedLedger, "Lagos Circle", PRICE);
        _create(host, PRICE, "Lagos Circle");
    }

    /// The indexer counts each invite's uses to show the host which links are still live. The
    /// invite key is only in `join`'s calldata, which an event reader never sees.
    function test_seatMinted_carriesTheInviteKeyUsed() public {
        Community c = _create(host, PRICE, "Test Community");
        _attest(ada);
        usdc.mint(ada, PRICE);
        vm.prank(ada);
        usdc.approve(address(c), PRICE);
        (address inviteKey, bytes memory keySig) = _inviteFor(address(c), ada);
        (uint16 hostBps, uint16 poolBps,) = config.mintSplit();
        uint256 toHost = PRICE * hostBps / 10_000;
        uint256 toPool = PRICE * poolBps / 10_000;

        vm.expectEmit(true, true, false, true, address(c));
        emit ICommunity.SeatMinted(ada, inviteKey, PRICE, toHost, toPool, PRICE - toHost - toPool);
        vm.prank(ada);
        c.join(inviteKey, keySig);
    }

    /// A free seat moves no money but still spends an invite, so it names the key too.
    function test_seatMinted_aFreeSeatStillCarriesTheInviteKey() public {
        Community c = _create(host, 0, "Free Community");
        _attest(ada);
        (address inviteKey, bytes memory keySig) = _inviteFor(address(c), ada);
        vm.expectEmit(true, true, false, true, address(c));
        emit ICommunity.SeatMinted(ada, inviteKey, 0, 0, 0, 0);
        vm.prank(ada);
        c.join(inviteKey, keySig);
    }

    /// The founding seat needs no invite, and says so with the zero address.
    function test_seatMinted_theFoundingSeatNamesNoInvite() public {
        _attest(host);
        vm.recordLogs();
        vm.prank(host);
        address c = factory.createCommunity("Test Community", PRICE);
        bytes32 topic = ICommunity.SeatMinted.selector;
        bool seen;
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i; i < logs.length; i++) {
            if (logs[i].emitter != c || logs[i].topics[0] != topic) continue;
            seen = true;
            assertEq(logs[i].topics[1], bytes32(uint256(uint160(host))), "the host's founding seat");
            assertEq(logs[i].topics[2], bytes32(0), "no invite key");
            assertEq(logs[i].data, abi.encode(uint256(0), uint256(0), uint256(0), uint256(0)), "an unpaid seat");
        }
        assertTrue(seen, "the founding seat was minted with an event");
    }

    /// Members vote on a price they can see. The indexer shows the proposed price on the open
    /// vote, and reading it from `votes(voteId)` later would miss nothing today but costs a call
    /// per vote per refresh.
    function test_voteStarted_carriesTheProposedPrice() public {
        Community c = _create(host, PRICE, "Test Community");
        uint256 newPrice = 70e6;
        vm.expectEmit(true, true, true, true, address(c));
        emit ICommunity.VoteStarted(1, uint8(ICommunity.VoteKind.Price), address(0), newPrice);
        vm.prank(host);
        c.proposeSeatPrice(newPrice);
    }

    /// Every other kind of vote carries a zero price, so the field is never ambiguous.
    function test_voteStarted_carriesZeroForEveryOtherKind() public {
        Community c = _seasonedCommunity();
        vm.expectEmit(true, true, true, true, address(c));
        emit ICommunity.VoteStarted(1, uint8(ICommunity.VoteKind.Removal), ada, 0);
        vm.prank(host);
        c.proposeRemoval(ada);
    }

    // ---- why the host changed ----

    /// The indexer used to infer the reason from the events around the change, and got an
    /// election after a resignation wrong. Each of the four paths now names itself.

    function test_hostChanged_handover() public {
        Community c = _seasonedCommunity();
        vm.prank(host);
        c.nominateSuccessor(ada);
        vm.prank(ada);
        c.acceptNomination();
        _pastWindow();
        vm.expectEmit(true, true, false, true, address(c));
        emit ICommunity.HostChanged(host, ada, uint8(ICommunity.HostChange.Handover));
        c.completeHandover();
    }

    function test_hostChanged_resignation() public {
        Community c = _seasonedCommunity();
        vm.expectEmit(true, true, false, true, address(c));
        emit ICommunity.HostChanged(host, address(0), uint8(ICommunity.HostChange.Resignation));
        _resign(c);
    }

    function test_hostChanged_removal() public {
        Community c = _seasonedCommunity();
        vm.prank(ada);
        c.proposeRemoveHost();
        uint256 voteId = c.activeHostVoteId();
        _vote(c, voteId, ada, true);
        _vote(c, voteId, bem, true);
        _vote(c, voteId, cy, true);
        _vote(c, voteId, dee, true);
        _pastWindow();
        vm.expectEmit(true, true, false, true, address(c));
        emit ICommunity.HostChanged(host, address(0), uint8(ICommunity.HostChange.Removal));
        c.executeRemoveHost();
    }

    function test_hostChanged_election() public {
        Community c = _seasonedCommunity();
        _resign(c);
        vm.prank(ada);
        c.electHost(bem);
        uint256 voteId = c.activeHostVoteId();
        _vote(c, voteId, ada, true);
        _vote(c, voteId, bem, true);
        _vote(c, voteId, cy, true);
        _pastWindow();
        vm.expectEmit(true, true, false, true, address(c));
        emit ICommunity.HostChanged(address(0), bem, uint8(ICommunity.HostChange.Election));
        c.executeRemoveHost();
    }

    /// The reasons are numbered in the order the indexer's decoder expects.
    function test_hostChange_numbering() public pure {
        assertEq(uint8(ICommunity.HostChange.Handover), 0);
        assertEq(uint8(ICommunity.HostChange.Election), 1);
        assertEq(uint8(ICommunity.HostChange.Removal), 2);
        assertEq(uint8(ICommunity.HostChange.Resignation), 3);
    }

    // ---- helpers ----

    function _create(address by, uint256 price, string memory name) internal returns (Community c) {
        _attest(by);
        vm.prank(by);
        c = Community(factory.createCommunity(name, price));
    }

    /// The host and four members, all seasoned.
    function _seasonedCommunity() internal returns (Community c) {
        c = _create(host, PRICE, "Test Community");
        _join(c, ada);
        _join(c, bem);
        _join(c, cy);
        _join(c, dee);
        _season();
    }
}
