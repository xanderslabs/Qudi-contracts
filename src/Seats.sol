// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.30;

import {ERC721} from "openzeppelin-contracts/contracts/token/ERC721/ERC721.sol";
import {IERC721} from "openzeppelin-contracts/contracts/token/ERC721/IERC721.sol";
import {ERC721Enumerable} from "openzeppelin-contracts/contracts/token/ERC721/extensions/ERC721Enumerable.sol";
import {Base64} from "openzeppelin-contracts/contracts/utils/Base64.sol";
import {Strings} from "openzeppelin-contracts/contracts/utils/Strings.sol";
import {ICommunity} from "./interfaces/ICommunity.sol";
import {ISeats} from "./interfaces/ISeats.sol";
import {IConfig} from "./interfaces/IConfig.sol";

/// Every community's seats, in one soulbound ERC-721 Enumerable. A wallet in five communities
/// holds five tokens here, so the app lists a member's communities from this one address.
///
/// A seat is never transferred, approved or burned. Its community mints it, and its community
/// alone moves it from Active to Suspended (an executed removal vote) or from Active to Left
/// (`forfeit`). Both are final. The seat stays in the wallet in every state: that keeps the
/// community in the member's list, so they can still reach their personal vaults and repay a
/// tab, and it is the bar on joining the same community twice.
///
/// This contract is the one record of a seat's state, mint time and number. `Community` reads
/// them from here and keeps no copy of its own.
contract Seats is ERC721Enumerable, ISeats {
    using Strings for uint256;

    address public immutable factory;
    /// Read for `MAX_SEATS_PER_WALLET` at every mint.
    IConfig public immutable config;

    uint256 internal _nextTokenId = 1;
    mapping(uint256 => Seat) internal _seats;
    /// The community id plus one, for a community the factory registered; 0 for anything else.
    mapping(address => uint256) internal _communityIdPlusOne;
    mapping(address => mapping(address => uint256)) internal _seatOf;
    mapping(address => mapping(uint256 => uint256)) internal _seatAt;
    mapping(address => uint256) internal _seatCount;
    mapping(address => uint256) internal _activeCount;

    constructor(address factory_, IConfig config_) ERC721("Qudi Seats", "QSEAT") {
        if (factory_ == address(0) || address(config_) == address(0)) revert ZeroAddress();
        factory = factory_;
        config = config_;
    }

    function registerCommunity(address community, uint256 communityId) external {
        if (msg.sender != factory) revert NotFactory();
        if (_communityIdPlusOne[community] != 0) revert AlreadyRegistered();
        _communityIdPlusOne[community] = communityId + 1;
        emit CommunityRegistered(community, communityId);
    }

    /// Only a registered community mints, and only in itself: the seat's community is always the
    /// caller. One seat per wallet per community, for good. A kept Suspended or Left seat refuses
    /// a second one. A wallet holds at most `MAX_SEATS_PER_WALLET` seats across every community,
    /// founding seats included.
    function mint(address to, uint256 pricePaid) external returns (uint256 tokenId) {
        uint256 idPlusOne = _communityIdPlusOne[msg.sender];
        if (idPlusOne == 0) revert NotCommunity();
        if (_seatOf[msg.sender][to] != 0) revert AlreadySeated();
        // Every seat counts, Active, Suspended or Left: a formal default walks every seat the wallet
        // holds, inside the repayment that crosses it, so the walk must stay short enough to fit.
        if (balanceOf(to) >= config.maxSeatsPerWallet()) revert TooManySeats();

        tokenId = _nextTokenId++;
        uint256 seatNumber = ++_seatCount[msg.sender];
        _seats[tokenId] = Seat({
            community: msg.sender,
            seatNumber: uint32(seatNumber),
            mintedAt: uint64(block.timestamp),
            communityId: uint64(idPlusOne - 1),
            state: ICommunity.SeatState.Active,
            pricePaid: uint128(pricePaid)
        });
        _seatOf[msg.sender][to] = tokenId;
        _seatAt[msg.sender][seatNumber] = tokenId;
        _activeCount[msg.sender]++;
        _mint(to, tokenId);
    }

    /// Active to Suspended or Active to Left, by the seat's own community. Nothing leads out of
    /// Suspended or Left, and nothing leads back to Active.
    function setState(uint256 tokenId, ICommunity.SeatState state) external {
        Seat storage s = _seats[tokenId];
        if (s.community != msg.sender) revert NotSeatCommunity();
        if (s.state != ICommunity.SeatState.Active) revert InvalidStateChange();
        if (state != ICommunity.SeatState.Suspended && state != ICommunity.SeatState.Left) {
            revert InvalidStateChange();
        }
        s.state = state;
        _activeCount[msg.sender]--;
        emit SeatStateChanged(tokenId, msg.sender, state);
    }

    // ---- views ----

    function seatInfo(uint256 tokenId) external view returns (Seat memory) {
        _requireOwned(tokenId);
        return _seats[tokenId];
    }

    function seatOf(address community, address wallet) external view returns (uint256) {
        return _seatOf[community][wallet];
    }

    function seatAt(address community, uint256 seatNumber) external view returns (uint256) {
        return _seatAt[community][seatNumber];
    }

    function seatCount(address community) external view returns (uint256) {
        return _seatCount[community];
    }

    function activeCount(address community) external view returns (uint256) {
        return _activeCount[community];
    }

    function isRegistered(address community) external view returns (bool) {
        return _communityIdPlusOne[community] != 0;
    }

    /// Onchain JSON: the community's name, the seat number and the state. No image.
    function tokenURI(uint256 tokenId) public view override returns (string memory) {
        _requireOwned(tokenId);
        Seat memory s = _seats[tokenId];
        string memory name_ = _escape(ICommunity(s.community).communityName());
        string memory number = uint256(s.seatNumber).toString();
        string memory json = string.concat(
            '{"name":"',
            name_,
            " seat ",
            number,
            '","attributes":[{"trait_type":"Community","value":"',
            name_,
            '"},{"trait_type":"Seat number","display_type":"number","value":',
            number,
            '},{"trait_type":"State","value":"',
            _stateName(s.state),
            '"}]}'
        );
        return string.concat("data:application/json;base64,", Base64.encode(bytes(json)));
    }

    function _stateName(ICommunity.SeatState state) internal pure returns (string memory) {
        if (state == ICommunity.SeatState.Active) return "Active";
        if (state == ICommunity.SeatState.Suspended) return "Suspended";
        return "Left";
    }

    /// A host names their community freely, so the name is escaped before it goes inside a JSON
    /// string: a quote or a backslash gets a backslash, and a control character becomes a space.
    function _escape(string memory raw) internal pure returns (string memory) {
        bytes memory b = bytes(raw);
        uint256 extra;
        for (uint256 i; i < b.length; i++) {
            if (b[i] == '"' || b[i] == "\\") extra++;
        }
        bytes memory out = new bytes(b.length + extra);
        uint256 j;
        for (uint256 i; i < b.length; i++) {
            bytes1 c = b[i];
            if (c == '"' || c == "\\") out[j++] = "\\";
            out[j++] = uint8(c) < 0x20 ? bytes1(" ") : c;
        }
        return string(out);
    }

    // ---- soulbound: every transfer and approval path reverts, and nothing burns a seat ----

    /// Every transfer path, `transferFrom` and both `safeTransferFrom`s, ends here, and so would a
    /// burn. Only a mint, a token with no owner yet, gets through.
    function _update(address to, uint256 tokenId, address auth) internal override returns (address) {
        if (_ownerOf(tokenId) != address(0)) revert Soulbound();
        return super._update(to, tokenId, auth);
    }

    /// Approvals never reach `_update`, so they are refused here: an approval could only ever
    /// be for a transfer that cannot happen.
    function approve(address, uint256) public pure override(ERC721, IERC721) {
        revert Soulbound();
    }

    function setApprovalForAll(address, bool) public pure override(ERC721, IERC721) {
        revert Soulbound();
    }
}
