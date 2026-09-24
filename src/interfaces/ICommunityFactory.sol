// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

/// Deploys communities as clone sets and answers which addresses are legitimate community
/// contracts. OpenTabs and Venue trust only addresses this registry vouches for.
interface ICommunityFactory {
    /// Clones both of a community's contracts, the community and its one ledger, registers both,
    /// and registers the community with `Seats`. Returns the community's address; `ledgerOf`
    /// answers the other. The seat price must be from `SEAT_PRICE_FLOOR` to `SEAT_PRICE_CEILING`.
    function createCommunity(string calldata name, uint256 seatPrice) external returns (address community);
    /// The community's one ledger; 0 if `community` is not one this factory created.
    function ledgerOf(address community) external view returns (address);
    /// Lists `venue` under the next id, from zero, and makes it active. Owner only.
    function addVenue(address venue) external returns (uint256 id);
    /// No new vault may choose venue `id`. Its money is untouched and nothing is removed. Owner
    /// only.
    function retireVenue(uint256 id) external;
    /// The venue listed under `id`. Reverts `UnknownVenue` for an id never handed out.
    function venueAt(uint256 id) external view returns (address);
    function venueCount() external view returns (uint256);
    /// Listed and not retired: the venues a new vault may choose.
    function isActiveVenue(uint256 id) external view returns (bool);
    // vaultOf/isCommunity answer with the community's LEDGER address (the Venue a vault record
    // names is `venueAt(id)`, shared by every community). There is one ledger and every venue is
    // available to it, so every listed id answers with the same address.
    function vaultOf(address community, uint8 poolType) external view returns (address);
    function isCommunity(address vault) external view returns (bool);
    function isCommunityContract(address any) external view returns (bool);
    /// The community a registered community contract belongs to, **plus one**; 0 means unregistered.
    /// Same 1-based convention as the internal `communityIndex`, and for the same reason: community 0
    /// is a real community, so a plain id cannot double as "not found". `CreditCore`'s
    /// `receiveCommunityLeg` gate is the caller: the callee decides which community a
    /// caller may top up, never the caller.
    function communityIdOf(address any) external view returns (uint256);
    function communityCount() external view returns (uint256);
    function communityAt(uint256 i) external view returns (address community);

    event CommunityCreated(uint256 indexed communityId, address indexed creator, address community, address ledger);
    event VenueAdded(uint256 indexed id, address venue);
    event VenueRetired(uint256 indexed id);

    error SeatPriceBelowFloor();
    error SeatPriceAboveCeiling();
    /// A venue id that was never handed out.
    error UnknownVenue();
}
