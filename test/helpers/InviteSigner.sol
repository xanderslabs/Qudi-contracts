// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {ICommunity} from "../../src/interfaces/ICommunity.sol";

/// Makes invites the way the host's app and the joiner's app do. The host registers the invite
/// key onchain; the joiner's app signs `Join(community, joiner)` with the key, from the typed data
/// alone, so a test proves the scheme rather than reading hashes back out of the contract.
///
/// `_keyed` and `_keyedFromSeed` name people. A host no longer signs anything, so neither keeps a
/// key; they give the same addresses `makeAddr(name)` and `vm.addr(seed)` do.
abstract contract InviteSigner is Test {
    bytes32 internal constant DOMAIN_TYPEHASH =
        keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)");
    bytes32 internal constant JOIN_TYPEHASH = keccak256("Join(address community,address joiner)");

    uint256 internal _inviteSalt;

    function _keyed(string memory name) internal returns (address) {
        return makeAddr(name);
    }

    function _keyedFromSeed(uint256 seed) internal pure returns (address) {
        return vm.addr(seed);
    }

    function _digest(address community, bytes32 structHash) internal view returns (bytes32) {
        bytes32 domain = keccak256(
            abi.encode(DOMAIN_TYPEHASH, keccak256("Qudi Community"), keccak256("1"), block.chainid, community)
        );
        return keccak256(abi.encodePacked("\x19\x01", domain, structHash));
    }

    function _sign(uint256 pk, bytes32 digest) internal pure returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, digest);
        return abi.encodePacked(r, s, v);
    }

    function _keySign(uint256 inviteKeyPk, address community, address joiner) internal view returns (bytes memory) {
        return _sign(inviteKeyPk, _digest(community, keccak256(abi.encode(JOIN_TYPEHASH, community, joiner))));
    }

    /// The community's current host registers `inviteKey`.
    function _createInvite(address community, address inviteKey, uint16 maxUses, uint64 expiry) internal {
        vm.prank(ICommunity(community).host());
        ICommunity(community).createInvite(inviteKey, maxUses, expiry);
    }

    /// A fresh single-use, seven-day invite from the community's current host, and the key's
    /// signature for `joiner`.
    function _inviteFor(address community, address joiner) internal returns (address inviteKey, bytes memory keySig) {
        uint256 keyPk = uint256(keccak256(abi.encode("invite key", community, joiner, ++_inviteSalt)));
        inviteKey = vm.addr(keyPk);
        _createInvite(community, inviteKey, 1, uint64(block.timestamp + 7 days));
        keySig = _keySign(keyPk, community, joiner);
    }

    /// Joins `community` through a fresh invite bound to `joiner`, inside a `vm.startPrank(joiner)`
    /// the caller already opened. The prank is paused while the host registers the invite.
    function _invitedJoin(address community, address joiner) internal {
        vm.stopPrank();
        (address inviteKey, bytes memory keySig) = _inviteFor(community, joiner);
        vm.startPrank(joiner);
        ICommunity(community).join(inviteKey, keySig);
    }

    /// `joiner` joins `community` through a fresh invite. The caller has funded and approved.
    function _joinAs(address community, address joiner) internal {
        (address inviteKey, bytes memory keySig) = _inviteFor(community, joiner);
        vm.prank(joiner);
        ICommunity(community).join(inviteKey, keySig);
    }
}
