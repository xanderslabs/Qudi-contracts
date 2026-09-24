// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.30;

import {Community} from "../src/Community.sol";
import {ICommunity} from "../src/interfaces/ICommunity.sol";
import {MembershipFixture} from "./helpers/MembershipFixture.sol";

/// Joining is gated by an invite the host registered onchain, spent by a caller the invite key
/// signed for. An invite lives only in the host term it was made in: every host change ends it,
/// so whoever holds the role answers for every open invite. Expiry, the use count, a single
/// revocation and a revocation of everything are enforced here, and an invite can be no longer and
/// no larger than the config allows when it is made.
contract InvitesTest is MembershipFixture {
    Community c;
    uint256 constant KEY = 0xC0FFEE;
    address inviteKey;

    function setUp() public override {
        super.setUp();
        c = _create(host, PRICE);
        inviteKey = vm.addr(KEY);
        address[4] memory people = [ada, bem, cy, dee];
        for (uint256 i; i < 4; i++) {
            _fund(people[i]);
        }
    }

    function _fund(address who) internal {
        _attest(who);
        usdc.mint(who, 10 * PRICE);
        vm.prank(who);
        usdc.approve(address(c), type(uint256).max);
    }

    /// The host registers `inviteKey` for `maxUses` joins over `ttl` seconds.
    function _group(uint16 maxUses, uint64 ttl) internal {
        _createInvite(address(c), inviteKey, maxUses, uint64(block.timestamp) + ttl);
    }

    function _try(address who, bytes4 err) internal {
        bytes memory keySig = _keySign(KEY, address(c), who);
        vm.prank(who);
        if (err != bytes4(0)) vm.expectRevert(err);
        c.join(inviteKey, keySig);
    }

    /// ada, bem and cy join and season, so they can carry a host vote.
    function _threeSeasoned() internal {
        _join(c, ada);
        _join(c, bem);
        _join(c, cy);
        _season();
    }

    // ---- a registered invite seats up to its uses ----

    function test_invite_aGroupInviteSeatsExactlyMaxUsesMembers() public {
        uint16 uses = 25;
        _group(uses, 30 days);
        ICommunity.InviteRecord memory r = c.inviteOf(inviteKey);
        assertEq(r.term, c.hostTerm());
        assertEq(r.epoch, c.inviteEpoch());
        assertEq(r.expiry, block.timestamp + 30 days);
        assertEq(r.maxUses, uses);
        assertEq(r.uses, 0);
        assertFalse(r.revoked);

        for (uint256 i; i < uses; i++) {
            address who = makeAddr(string.concat("group", vm.toString(i)));
            _fund(who);
            _try(who, bytes4(0));
        }
        assertEq(c.memberCount(), 1 + uses);
        assertEq(c.inviteOf(inviteKey).uses, uses);

        address late = makeAddr("late");
        _fund(late);
        _try(late, ICommunity.InviteUsedUp.selector);
    }

    function test_invite_anUnregisteredKeySeatsNobody() public {
        _try(ada, ICommunity.InviteNotRegistered.selector);
        // A key registered in another community is not an invite here.
        Community other = _create(host, PRICE);
        _createInvite(address(other), inviteKey, 5, uint64(block.timestamp + 7 days));
        _try(ada, ICommunity.InviteNotRegistered.selector);
    }

    // ---- expiry and revocation ----

    function test_invite_anExpiredInviteReverts() public {
        _group(5, 7 days);
        uint64 expiry = c.inviteOf(inviteKey).expiry;
        vm.warp(expiry - 1);
        _try(ada, bytes4(0)); // the last second it is valid
        vm.warp(expiry);
        _try(bem, ICommunity.InviteExpired.selector);
    }

    function test_invite_aRevokedInviteReverts() public {
        _group(5, 7 days);
        _try(ada, bytes4(0));

        vm.prank(host);
        vm.expectEmit(true, false, false, false);
        emit ICommunity.InviteRevoked(inviteKey);
        c.revokeInvite(inviteKey);
        assertTrue(c.inviteOf(inviteKey).revoked);
        _try(bem, ICommunity.InviteWasRevoked.selector);
    }

    function test_invite_revokeAllEndsEveryInviteSoFar() public {
        _group(5, 7 days);
        _try(ada, bytes4(0));

        vm.prank(host);
        c.revokeAllInvites();
        assertEq(c.inviteEpoch(), 1);
        _try(bem, ICommunity.InviteStale.selector);

        // An invite made after it works.
        (address fresh, bytes memory keySig) = _inviteFor(address(c), bem);
        vm.prank(bem);
        c.join(fresh, keySig);
        assertTrue(c.isMember(bem));
    }

    // ---- every host change ends the old term's invites ----

    function test_invite_aHandoverEndsTheOldTermsInvites() public {
        _threeSeasoned();
        _group(5, 30 days);
        uint64 term = c.hostTerm();

        _handOver(c, ada);
        assertEq(c.steward(), ada);
        assertEq(c.hostTerm(), term + 1);
        _try(dee, ICommunity.InviteStale.selector);

        // The new host's invites work.
        (address fresh, bytes memory keySig) = _inviteFor(address(c), dee);
        vm.prank(dee);
        c.join(fresh, keySig);
        assertTrue(c.isMember(dee));
    }

    function test_invite_aResignationEndsTheOldTermsInvites() public {
        _threeSeasoned();
        _group(5, 30 days);
        uint64 term = c.hostTerm();

        _resign(c);
        assertEq(c.hostTerm(), term + 1, "the resignation ends the term");
        _elect(c, ada, _people(ada, bem, cy));
        assertEq(c.hostTerm(), term + 2, "and the election starts another");
        _try(dee, ICommunity.InviteStale.selector);
    }

    function test_invite_aRemovalAndAnElectionEachEndTheOldTermsInvites() public {
        _threeSeasoned();
        _group(5, 30 days);
        uint64 term = c.hostTerm();

        _removeHost(c, _people(ada, bem, cy));
        assertEq(c.hostTerm(), term + 1, "the removal ends the term");
        _elect(c, ada, _people(ada, bem, cy));
        assertEq(c.hostTerm(), term + 2, "and the election starts another");
        _try(dee, ICommunity.InviteStale.selector);
    }

    /// The invite belongs to the term, not the address: a host voted out and elected again
    /// starts with no open invites.
    function test_invite_reElectingTheSameHostStillEndsTheOldTermsInvites() public {
        _threeSeasoned();
        _group(5, 30 days);

        _removeHost(c, _people(ada, bem, cy));
        _elect(c, host, _people(ada, bem, cy));
        assertEq(c.steward(), host);
        _try(dee, ICommunity.InviteStale.selector);
    }

    // ---- the joiner binding ----

    /// A watcher who sees a join in the mempool and sends the same calldata from their own
    /// address is refused, because the invite key signed the original caller, not them.
    function test_invite_aKeySignatureForAnotherJoinerReverts() public {
        _group(1, 7 days);
        bytes memory adasKeySig = _keySign(KEY, address(c), ada);

        vm.prank(bem);
        vm.expectRevert(ICommunity.BadKeySignature.selector);
        c.join(inviteKey, adasKeySig);

        // A key signature for the right joiner but in another community's domain fails too.
        Community other = _create(host, PRICE);
        vm.prank(ada);
        vm.expectRevert(ICommunity.BadKeySignature.selector);
        c.join(inviteKey, _keySign(KEY, address(other), ada));

        // Not a signature at all.
        vm.prank(ada);
        vm.expectRevert(ICommunity.BadKeySignature.selector);
        c.join(inviteKey, hex"1234");

        // The single use is still there for the joiner it was bound to.
        vm.prank(ada);
        c.join(inviteKey, adasKeySig);
        assertTrue(c.isMember(ada));
        assertFalse(c.isMember(bem));
    }

    // ---- who creates and revokes, and the bounds ----

    function test_invite_onlyTheHostCreatesAndRevokes() public {
        _join(c, ada);
        vm.startPrank(ada);
        vm.expectRevert(ICommunity.NotSteward.selector);
        c.createInvite(inviteKey, 5, uint64(block.timestamp + 7 days));
        vm.stopPrank();

        _group(5, 7 days);
        vm.startPrank(ada);
        vm.expectRevert(ICommunity.NotSteward.selector);
        c.revokeInvite(inviteKey);
        vm.expectRevert(ICommunity.NotSteward.selector);
        c.revokeAllInvites();
        vm.stopPrank();
        assertFalse(c.inviteOf(inviteKey).revoked);
        assertEq(c.inviteEpoch(), 0);

        // There is nothing to revoke under a key that was never registered.
        vm.prank(host);
        vm.expectRevert(ICommunity.InviteNotRegistered.selector);
        c.revokeInvite(makeAddr("never registered"));
    }

    function test_invite_noHostMeansNoNewInvites() public {
        _join(c, ada);
        _resign(c);
        vm.prank(host);
        vm.expectRevert(ICommunity.NotSteward.selector);
        c.createInvite(inviteKey, 5, uint64(block.timestamp + 7 days));
    }

    function test_invite_creatingOutsideTheBoundsReverts() public {
        (uint32 maxUses, uint64 maxTtl) = config.inviteLimits();
        assertEq(maxUses, 25);
        assertEq(maxTtl, 30 days);
        uint64 nowTs = uint64(block.timestamp);

        vm.startPrank(host);
        vm.expectRevert(ICommunity.InviteOutOfBounds.selector);
        c.createInvite(inviteKey, uint16(maxUses) + 1, nowTs + 7 days);
        vm.expectRevert(ICommunity.InviteOutOfBounds.selector);
        c.createInvite(inviteKey, 5, nowTs + maxTtl + 1);
        vm.expectRevert(ICommunity.InviteExpired.selector);
        c.createInvite(inviteKey, 5, nowTs);

        // Exactly at both bounds is allowed.
        vm.expectEmit(true, false, false, true);
        emit ICommunity.InviteCreated(inviteKey, c.hostTerm(), uint16(maxUses), nowTs + maxTtl);
        c.createInvite(inviteKey, uint16(maxUses), nowTs + maxTtl);

        // A key is registered once, even after it is revoked.
        vm.expectRevert(ICommunity.InviteAlreadyRegistered.selector);
        c.createInvite(inviteKey, 1, nowTs + 7 days);
        c.revokeInvite(inviteKey);
        vm.expectRevert(ICommunity.InviteAlreadyRegistered.selector);
        c.createInvite(inviteKey, 1, nowTs + 7 days);
        vm.stopPrank();
    }
}
