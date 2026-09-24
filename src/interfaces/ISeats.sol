// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IERC721Enumerable} from "openzeppelin-contracts/contracts/token/ERC721/extensions/IERC721Enumerable.sol";
import {ICommunity} from "./ICommunity.sol";

/// One soulbound ERC-721 holding every community's seats. A wallet's communities are
/// `balanceOf`, `tokenOfOwnerByIndex` and `seatInfo` on this one address. A seat is minted by
/// its community, changes state only by its community, and is never transferred or burned.
interface ISeats is IERC721Enumerable {
    /// What a token records. `seatNumber` counts per community from 1, the host's founding seat,
    /// and never repeats. `state` is the only field that changes after mint, and only from
    /// Active to Suspended or from Active to Left.
    struct Seat {
        address community;
        uint32 seatNumber;
        uint64 mintedAt;
        uint64 communityId;
        ICommunity.SeatState state;
        uint128 pricePaid;
    }

    /// The factory, the only address that registers a community.
    function factory() external view returns (address);

    /// Factory only, once per community, before the community's founding seat is minted.
    function registerCommunity(address community, uint256 communityId) external;

    /// A registered community mints a seat in itself. Reverts if `to` already holds a seat in the
    /// calling community, in any state.
    function mint(address to, uint256 pricePaid) external returns (uint256 tokenId);

    /// The seat's own community moves it from Active to Suspended or from Active to Left.
    function setState(uint256 tokenId, ICommunity.SeatState state) external;

    function seatInfo(uint256 tokenId) external view returns (Seat memory);
    /// The wallet's token id in `community`, or 0 if it never held a seat there.
    function seatOf(address community, address wallet) external view returns (uint256);
    /// The token id of `community`'s seat number `seatNumber`, or 0 past the last one.
    function seatAt(address community, uint256 seatNumber) external view returns (uint256);
    /// How many seats `community` has ever minted, which is also its highest seat number.
    function seatCount(address community) external view returns (uint256);
    /// How many of `community`'s seats are Active.
    function activeCount(address community) external view returns (uint256);
    function isRegistered(address community) external view returns (bool);

    event CommunityRegistered(address indexed community, uint256 indexed communityId);
    event SeatStateChanged(uint256 indexed tokenId, address indexed community, ICommunity.SeatState state);

    error NotFactory();
    error NotCommunity();
    error AlreadyRegistered();
    error AlreadySeated();
    error NotSeatCommunity();
    error InvalidStateChange();
    error Soulbound();
    error ZeroAddress();
}
