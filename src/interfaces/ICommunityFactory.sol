// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

/// Deploys communities as clone sets and answers which addresses are legitimate community
/// contracts. OpenTabs and Venue trust only addresses this registry vouches for.
interface ICommunityFactory {
    /// Clones both of a community's contracts, seats and its one ledger,
    /// and registers both. Returns the seats address; `ledgerOf` answers the other.
    function createCommunity(string calldata name, uint256 seatPrice) external returns (address community);
    /// The community's one ledger; 0 if `seats` is not one this factory minted.
    function ledgerOf(address community) external view returns (address);
    /// Qudi's shared `Venue` for a tier, indexed by the PoolTypes constant. This is the whole
    /// of what decides which tiers exist, and a ledger reads it to resolve the tier
    /// a vault record named. Panics above `PoolTypes.COUNT`; callers range-guard first.
    function pools(uint256 poolType) external view returns (address);
    // vaultOf/vaultsOf/isCommunity answer with the community's LEDGER address (the Venue a tier
    // shares across every community is `pools(poolType)`, not a per-community address). There
    // is one ledger and every tier is available to it, so every
    // tier below PoolTypes.COUNT answers with the same address.
    function vaultOf(address community, uint8 poolType) external view returns (address);
    function vaultsOf(address community) external view returns (address[3] memory);
    function isCommunity(address vault) external view returns (bool);
    function isCommunityContract(address any) external view returns (bool);
    /// The community a registered community contract belongs to, **plus one**; 0 means unregistered.
    /// Same 1-based convention as the internal `seatsIndex`, and for the same reason: community 0
    /// is a real community, so a plain id cannot double as "not found". `CreditCore`'s
    /// `receiveCommunityLeg` gate is the caller: the callee decides which community a
    /// caller may top up, never the caller.
    function communityIdOf(address any) external view returns (uint256);
    function communityCount() external view returns (uint256);
    function communityAt(uint256 i) external view returns (address community);

    event CommunityCreated(uint256 indexed communityId, address indexed creator, address community, address ledger);

    error SeatPriceBelowFloor();
}
