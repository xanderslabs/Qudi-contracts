// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.30;

import {Community} from "../src/Community.sol";
import {ICommunity} from "../src/interfaces/ICommunity.sol";
import {ConfigKeys as K} from "../src/ConfigKeys.sol";
import {MembershipFixture} from "./helpers/MembershipFixture.sol";

/// Joining is gated by an invite the current host signed off chain, spent by a caller the invite
/// key signed for. Expiry, the use count, a single revocation and a revocation of everything are
/// all enforced here, and an invite can be no longer and no larger than the config allows.
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

    function _groupInvite(uint32 maxUses, uint64 ttl) internal view returns (ICommunity.Invite memory) {
        return _invite(address(c), inviteKey, maxUses, ttl);
    }

    function _try(address who, ICommunity.Invite memory inv, bytes memory hostSig, bytes4 err) internal {
        bytes memory keySig = _keySign(KEY, address(c), who);
        vm.prank(who);
        if (err != bytes4(0)) vm.expectRevert(err);
        c.join(inv, hostSig, keySig);
    }

    function _hostSig(ICommunity.Invite memory inv) internal view returns (bytes memory) {
        return _hostSign(_keyOf[host], inv);
    }

    // ---- proof 5: the host's signature ----

    function test_proof5_joinWithoutAValidHostSignatureReverts() public {
        ICommunity.Invite memory inv = _groupInvite(5, 7 days);
        // Signed by someone who is not the host.
        _try(ada, inv, _hostSign(_keyOf[bem], inv), ICommunity.BadHostSignature.selector);
        // Signed by the host, over a different invite than the one presented.
        ICommunity.Invite memory other = _groupInvite(6, 7 days);
        _try(ada, inv, _hostSig(other), ICommunity.BadHostSignature.selector);
        // Not a signature at all.
        _try(ada, inv, hex"1234", ICommunity.BadHostSignature.selector);
        // The same invite, signed by the host, seats.
        _try(ada, inv, _hostSig(inv), bytes4(0));
        assertTrue(c.isMember(ada));
    }

    /// An invite is only as good as its signer's hold on the role: after a handover, an invite
    /// the old host signed is dead, and the new host's invites work.
    function test_proof5_anInviteSignedByTheOldHostDiesAtTheHandover() public {
        _join(c, ada);
        _join(c, bem);
        _join(c, cy);
        ICommunity.Invite memory inv = _groupInvite(5, 30 days);
        bytes memory oldHostSig = _hostSig(inv);
        _season();

        // ada, bem and cy vote the host out, then elect ada.
        vm.prank(ada);
        c.proposeRemoveSteward();
        uint256 voteId = c.activeStewardVoteId();
        _vote(c, voteId, ada, true);
        _vote(c, voteId, bem, true);
        _vote(c, voteId, cy, true);
        _pastWindow();
        c.executeRemoveSteward();
        vm.prank(ada);
        c.electSteward(ada);
        voteId = c.activeStewardVoteId();
        _vote(c, voteId, ada, true);
        _vote(c, voteId, bem, true);
        _vote(c, voteId, cy, true);
        _pastWindow();
        c.executeRemoveSteward();
        assertEq(c.steward(), ada);

        // The old host's invite is unexpired, unused and unrevoked, and still refused.
        _try(dee, inv, oldHostSig, ICommunity.BadHostSignature.selector);
        // The new host's signature over the same invite seats.
        _try(dee, inv, _hostSign(_keyOf[ada], inv), bytes4(0));
        assertTrue(c.isMember(dee));
    }

    // ---- proof 6: the joiner binding ----

    /// A watcher who sees a join in the mempool and sends the same calldata from their own
    /// address is refused, because the invite key signed the original caller, not them.
    function test_proof6_aKeySignatureForAnotherJoinerReverts() public {
        ICommunity.Invite memory inv = _groupInvite(1, 7 days);
        bytes memory hostSig = _hostSig(inv);
        bytes memory adasKeySig = _keySign(KEY, address(c), ada);

        vm.prank(bem);
        vm.expectRevert(ICommunity.BadKeySignature.selector);
        c.join(inv, hostSig, adasKeySig);

        // A key signature for the right joiner but in another community's domain fails too.
        Community other = _create(host, PRICE);
        vm.prank(ada);
        vm.expectRevert(ICommunity.BadKeySignature.selector);
        c.join(inv, hostSig, _keySign(KEY, address(other), ada));

        // The single use is still there for the joiner it was bound to.
        vm.prank(ada);
        c.join(inv, hostSig, adasKeySig);
        assertTrue(c.isMember(ada));
        assertFalse(c.isMember(bem));
    }

    // ---- proof 7: expiry, uses, revocation, nonce and the config bounds ----

    function test_proof7_anExpiredInviteReverts() public {
        ICommunity.Invite memory inv = _groupInvite(5, 7 days);
        bytes memory hostSig = _hostSig(inv);
        vm.warp(inv.expiry - 1);
        _try(ada, inv, hostSig, bytes4(0)); // the last second it is valid
        vm.warp(inv.expiry);
        _try(bem, inv, hostSig, ICommunity.InviteExpired.selector);
    }

    function test_proof7_anInviteIssuedInTheFutureReverts() public {
        ICommunity.Invite memory inv = _groupInvite(5, 7 days);
        inv.issuedAt += 1 hours;
        inv.expiry += 1 hours;
        bytes memory hostSig = _hostSig(inv);
        _try(ada, inv, hostSig, ICommunity.InviteNotYetValid.selector);
        vm.warp(inv.issuedAt);
        _try(ada, inv, hostSig, bytes4(0));
    }

    function test_proof7_anOverUsedInviteReverts() public {
        ICommunity.Invite memory inv = _groupInvite(2, 7 days);
        bytes memory hostSig = _hostSig(inv);
        _try(ada, inv, hostSig, bytes4(0));
        _try(bem, inv, hostSig, bytes4(0));
        assertEq(c.inviteUses(inviteKey), 2);
        _try(cy, inv, hostSig, ICommunity.InviteUsedUp.selector);
    }

    function test_proof7_aRevokedInviteReverts() public {
        ICommunity.Invite memory inv = _groupInvite(5, 7 days);
        bytes memory hostSig = _hostSig(inv);
        _try(ada, inv, hostSig, bytes4(0));

        vm.prank(ada);
        vm.expectRevert(ICommunity.NotSteward.selector);
        c.revokeInvite(inviteKey);

        vm.prank(host);
        c.revokeInvite(inviteKey);
        assertTrue(c.inviteRevoked(inviteKey));
        _try(bem, inv, hostSig, ICommunity.InviteWasRevoked.selector);
    }

    function test_proof7_everyInviteSignedBeforeANonceBumpReverts() public {
        ICommunity.Invite memory inv = _groupInvite(5, 7 days);
        bytes memory hostSig = _hostSig(inv);
        _try(ada, inv, hostSig, bytes4(0));

        vm.prank(ada);
        vm.expectRevert(ICommunity.NotSteward.selector);
        c.revokeAllInvites();

        vm.prank(host);
        c.revokeAllInvites();
        assertEq(c.hostNonce(), 1);
        _try(bem, inv, hostSig, ICommunity.InviteStaleNonce.selector);

        // An invite signed under the new nonce works.
        ICommunity.Invite memory fresh = _groupInvite(5, 7 days);
        _try(bem, fresh, _hostSig(fresh), bytes4(0));
    }

    /// The config bounds hold even over the host's own signature.
    function test_proof7_anInviteLongerOrLargerThanTheConfigAllowsReverts() public {
        (uint32 maxUses, uint64 maxTtl) = config.inviteLimits();
        assertEq(maxUses, 25);
        assertEq(maxTtl, 30 days);

        ICommunity.Invite memory tooLong = _groupInvite(5, maxTtl + 1);
        _try(ada, tooLong, _hostSig(tooLong), ICommunity.InviteOutOfBounds.selector);
        ICommunity.Invite memory tooLarge = _groupInvite(maxUses + 1, 7 days);
        _try(ada, tooLarge, _hostSig(tooLarge), ICommunity.InviteOutOfBounds.selector);

        // Exactly at both bounds is allowed.
        ICommunity.Invite memory atBounds = _groupInvite(maxUses, maxTtl);
        _try(ada, atBounds, _hostSig(atBounds), bytes4(0));

        // The bounds are read live: tightened by config, the same signed invite stops working.
        config.set(K.INVITE_MAX_USES, maxUses - 1);
        _try(bem, atBounds, _hostSig(atBounds), ICommunity.InviteOutOfBounds.selector);
    }

    function test_anInviteForAnotherCommunityReverts() public {
        Community other = _create(host, PRICE);
        ICommunity.Invite memory inv = _invite(address(other), inviteKey, 5, 7 days);
        _try(ada, inv, _hostSig(inv), ICommunity.InviteWrongCommunity.selector);
    }

    // ---- proof 8: a group invite ----

    function test_proof8_aGroupInviteSeatsExactlyMaxUsesMembers() public {
        uint32 uses = 25;
        ICommunity.Invite memory inv = _groupInvite(uses, 30 days);
        bytes memory hostSig = _hostSig(inv);
        for (uint256 i; i < uses; i++) {
            address who = makeAddr(string.concat("group", vm.toString(i)));
            _fund(who);
            _try(who, inv, hostSig, bytes4(0));
        }
        assertEq(c.memberCount(), 1 + uses);
        assertEq(c.inviteUses(inviteKey), uses);

        address late = makeAddr("late");
        _fund(late);
        _try(late, inv, hostSig, ICommunity.InviteUsedUp.selector);
    }
}
