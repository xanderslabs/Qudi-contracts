// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {ICommunity} from "../../src/interfaces/ICommunity.sol";

/// Signs invites the way the host's app and the joiner's app do, from the typed data alone, so a
/// test proves the scheme rather than reading hashes back out of the contract.
///
/// A host must be an address this helper holds a key for: `_keyed(name)` gives the same address
/// `makeAddr(name)` does and remembers its key, so a fixture swaps one for the other with no
/// address changing.
abstract contract InviteSigner is Test {
    bytes32 internal constant DOMAIN_TYPEHASH =
        keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)");
    bytes32 internal constant INVITE_TYPEHASH = keccak256(
        "Invite(address community,address inviteKey,uint64 issuedAt,uint64 expiry,uint32 maxUses,uint256 hostNonce)"
    );
    bytes32 internal constant JOIN_TYPEHASH = keccak256("Join(address community,address joiner)");

    mapping(address => uint256) internal _keyOf;
    uint256 internal _inviteSalt;

    function _keyed(string memory name) internal returns (address who) {
        uint256 pk;
        (who, pk) = makeAddrAndKey(name);
        _keyOf[who] = pk;
    }

    function _keyedFromSeed(uint256 seed) internal returns (address who) {
        who = vm.addr(seed);
        _keyOf[who] = seed;
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

    function _invite(address community, address inviteKey, uint32 maxUses, uint64 ttl)
        internal
        view
        returns (ICommunity.Invite memory)
    {
        return ICommunity.Invite({
            community: community,
            inviteKey: inviteKey,
            issuedAt: uint64(block.timestamp),
            expiry: uint64(block.timestamp) + ttl,
            maxUses: maxUses,
            hostNonce: ICommunity(community).hostNonce()
        });
    }

    function _hostSign(uint256 hostPk, ICommunity.Invite memory inv) internal view returns (bytes memory) {
        bytes32 structHash = keccak256(
            abi.encode(
                INVITE_TYPEHASH, inv.community, inv.inviteKey, inv.issuedAt, inv.expiry, inv.maxUses, inv.hostNonce
            )
        );
        return _sign(hostPk, _digest(inv.community, structHash));
    }

    function _keySign(uint256 inviteKeyPk, address community, address joiner) internal view returns (bytes memory) {
        return _sign(inviteKeyPk, _digest(community, keccak256(abi.encode(JOIN_TYPEHASH, community, joiner))));
    }

    /// A fresh single-use invite from the community's current host, bound to `joiner`.
    function _inviteFor(address community, address joiner)
        internal
        returns (ICommunity.Invite memory inv, bytes memory hostSig, bytes memory keySig)
    {
        uint256 hostPk = _keyOf[ICommunity(community).steward()];
        require(hostPk != 0, "InviteSigner: no key for the host");
        uint256 keyPk = uint256(keccak256(abi.encode("invite key", community, joiner, ++_inviteSalt)));
        inv = _invite(community, vm.addr(keyPk), 1, 7 days);
        hostSig = _hostSign(hostPk, inv);
        keySig = _keySign(keyPk, community, joiner);
    }

    /// Joins `community` through a fresh invite bound to `joiner`, inside a `vm.startPrank(joiner)`
    /// the caller already opened.
    function _invitedJoin(address community, address joiner) internal {
        (ICommunity.Invite memory inv, bytes memory hostSig, bytes memory keySig) = _inviteFor(community, joiner);
        ICommunity(community).join(inv, hostSig, keySig);
    }

    /// `joiner` joins `community` through a fresh invite. The caller has funded and approved.
    function _joinAs(address community, address joiner) internal {
        (ICommunity.Invite memory inv, bytes memory hostSig, bytes memory keySig) = _inviteFor(community, joiner);
        vm.prank(joiner);
        ICommunity(community).join(inv, hostSig, keySig);
    }
}
