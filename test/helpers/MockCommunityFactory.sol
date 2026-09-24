// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.30;

/// Stands in for a community's `Community` where `CreditStanding` only needs the **token id** of
/// the member's Active seat, the seat-generation stamp its seat-side state is keyed against
/// (read through `activeTokenOf`). Every address reads as
/// holding seat 1 until a test says otherwise, so a suite that never thinks about seats sees one
/// unchanging seat per member. `forfeit` reads as no Active seat (the real `forfeit` sets Left,
/// and `activeTokenOf` is 0 for a Left seat), and `join` mints the next id.
///
/// `join` after `forfeit` is something the real `Community` refuses (a kept seat
/// bars a second mint). The mock still allows it, so the seat-stamp suites can keep proving that the
/// stamp tells two seats apart.
///
/// **Ids, not timestamps.** The real `Community` assigns from `nextTokenId++`, so every seat ever
/// minted has its own. A timestamp could not distinguish a forfeit and a rejoin landing in the
/// same block, and EIP-7702 batching makes that something a member can arrange deliberately.
/// `mintedAt` is kept because `CreditCore.draw` reads it for seasoning.
contract MockSeatStamps {
    uint256 internal _nextTokenId = 2; // 1 is the implicit seat every unset member reads as
    mapping(address => uint256) internal _tokenOf;
    mapping(address => uint64) internal _mintedAt;
    mapping(address => bool) internal _set;

    function activeTokenOf(address member) external view returns (uint256) {
        return _set[member] ? _tokenOf[member] : 1;
    }

    function mintedAt(address member) external view returns (uint64) {
        return _set[member] ? _mintedAt[member] : 1;
    }

    function join(address member) external {
        _set[member] = true;
        _tokenOf[member] = _nextTokenId++;
        _mintedAt[member] = uint64(block.timestamp);
    }

    function forfeit(address member) external {
        _set[member] = true;
        _tokenOf[member] = 0;
        _mintedAt[member] = 0;
    }
}

/// Stands in for `CommunityFactory` where `CreditCore` only needs the community count, the id
/// range, and the contract registry `receiveCommunityLeg` resolves a caller through.
/// `communityCount` is settable so a test can add communities.
contract MockCommunityFactory {
    uint256 public communityCount;

    /// Mirrors `CommunityFactory.contractRegistry`: the community id plus one for a registered
    /// community contract, 0 for anything else.
    mapping(address => uint256) internal _communityIdPlusOne;

    function addCommunity() external returns (uint256 id) {
        id = communityCount;
        communityCount = id + 1;
    }

    function setCommunityCount(uint256 n) external {
        communityCount = n;
    }

    /// Registers `who` as a community contract belonging to `communityId`, the way `createCommunity`
    /// and `openPool` register a real seats or ledger clone.
    function register(address who, uint256 communityId) external {
        _communityIdPlusOne[who] = communityId + 1;
    }

    /// Mirrors `CommunityFactory.communityAt`: a community's seats address. `CreditCore` compares the
    /// caller against it to derive a leg's kind, so a test that cares which kind is emitted must
    /// set this. Unset reads as `defaultSeats`, a `MockSeatStamps` no caller is, so every leg
    /// is still a Yield leg, and `CreditStanding`'s seat stamp has a `mintedAt` to read.
    mapping(uint256 => address) internal _communityOf;
    address public immutable defaultCommunity = address(new MockSeatStamps());

    function setSeats(uint256 communityId, address community) external {
        _communityOf[communityId] = community;
    }

    function communityAt(uint256 communityId) external view returns (address) {
        address community = _communityOf[communityId];
        return community == address(0) ? defaultCommunity : community;
    }

    function communityIdOf(address any) external view returns (uint256) {
        return _communityIdPlusOne[any];
    }

    function isCommunityContract(address any) external view returns (bool) {
        return _communityIdPlusOne[any] != 0;
    }
}
