// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.30;

import {Clones} from "openzeppelin-contracts/contracts/proxy/Clones.sol";
import {IConfig} from "./interfaces/IConfig.sol";
import {ICommunityFactory} from "./interfaces/ICommunityFactory.sol";
import {ICommunityInit} from "./interfaces/ICommunityInit.sol";
import {ISeats} from "./interfaces/ISeats.sol";
import {Ownable2Step, Ownable} from "openzeppelin-contracts/contracts/access/Ownable2Step.sol";

/// Anyone creates a community; the creator becomes founding steward and receives the founding
/// seat unpaid inside initialize() (the creator does not pay for their own founding mint;
/// every later seat is a paid mint splitting 40/30/30).
/// Clones are EIP-1167 minimal proxies over immutable implementations: a deployment cost
/// device, never an upgrade device.
///
/// `createCommunity` deploys **two** clones, the community and the ledger: a
/// community is `Community` and `Ledger`, however many vaults or tiers it opens. Its seats are
/// tokens in the one `Seats` contract, which this factory registers each community with. It used to
/// deploy the community contract alone and clone a further ledger per tier, and that was collapsed into one.
///
/// It also holds the venue registry: the list of Qudi's `Venue`s, each known by an id handed out in
/// order from zero. Qudi's owner adds venues and retires them; a retired venue takes no new vaults
/// but keeps the money already in it, and nothing is ever removed, so an id means the same venue
/// for as long as the chain exists. There is no host opt-in: every active venue is available to
/// every community, the host picks one when creating a shared vault, and a member picks one for
/// their own. The ledger resolves a vault record's venue id here.
contract CommunityFactory is ICommunityFactory, Ownable2Step {
    IConfig public immutable config;
    /// The one contract holding every community's seats. It trusts this factory alone to say
    /// which addresses are communities.
    ISeats public immutable seats;
    address public immutable communityImplementation;
    address public immutable ledgerImplementation;
    /// Every venue ever listed, indexed by its id. This is the whole of what decides which venues
    /// exist, and it is Qudi's: no community has a say in it.
    address[] internal _venues;
    /// Set by `retireVenue`. A retired venue takes no new vaults and is never removed.
    mapping(uint256 => bool) internal _retired;

    struct CommunityEntry {
        address community;
        address ledger; // one per community, holding every tier
    }

    CommunityEntry[] internal communities;
    mapping(address => bool) internal vaultRegistry;
    /// Every contract this factory created for a community, holding its community id **plus one**;
    /// 0 means unregistered. It used to be a `mapping(address => bool)`. Same writes at the
    /// same sites and the same one slot per entry, because the id was already known at every
    /// write; `isCommunityContract` reads it as `!= 0` and `communityIdOf` reads the id back out.
    /// The plus-one is what makes community 0 distinguishable from "not found", the same reason
    /// `communityIndex` below is 1-based.
    ///
    /// `CreditCore.receiveCommunityLeg` is what needs the id: a community contract paying a leg
    /// names its community, and the callee resolves the caller here rather than trusting the
    /// name. The alternative, having the caller pass its own community address for the factory to
    /// resolve through `communityIndex`, was rejected: it lets a
    /// registered community contract top up a community it does not belong to.
    mapping(address => uint256) internal contractRegistry;
    /// 1-based index into `communities` for a registered `Community` clone; 0 means unregistered.
    mapping(address => uint256) internal communityIndex;

    error ZeroAddress();
    error SeatsNotWiredToThisFactory();

    /// `owner_` is the timelock, the only address that may list or retire a venue.
    ///
    /// `Seats` is deployed first, naming this factory's address, and is refused here unless it
    /// does: a `Seats` that trusted another factory would refuse every community this one creates.
    constructor(address config_, address seats_, address communityImpl_, address ledgerImpl_, address owner_)
        Ownable(owner_)
    {
        if (config_ == address(0) || seats_ == address(0) || communityImpl_ == address(0) || ledgerImpl_ == address(0)) revert ZeroAddress();
        if (ISeats(seats_).factory() != address(this)) revert SeatsNotWiredToThisFactory();
        config = IConfig(config_);
        seats = ISeats(seats_);
        communityImplementation = communityImpl_;
        ledgerImplementation = ledgerImpl_;
    }

    // ---- the venue registry ----

    /// Lists a venue under the next id and makes it active.
    function addVenue(address venue) external onlyOwner returns (uint256 id) {
        if (venue == address(0)) revert ZeroAddress();
        id = _venues.length;
        _venues.push(venue);
        emit VenueAdded(id, venue);
    }

    /// No new vault may choose this venue. The money already in it is untouched and the venue
    /// still pays out; its id keeps resolving.
    function retireVenue(uint256 id) external onlyOwner {
        if (id >= _venues.length) revert UnknownVenue();
        _retired[id] = true;
        emit VenueRetired(id);
    }

    function venueAt(uint256 id) external view returns (address) {
        if (id >= _venues.length) revert UnknownVenue();
        return _venues[id];
    }

    function venueCount() external view returns (uint256) {
        return _venues.length;
    }

    function isActiveVenue(uint256 id) external view returns (bool) {
        return id < _venues.length && !_retired[id];
    }

    function createCommunity(string calldata name, uint256 seatPrice) external returns (address community) {
        if (seatPrice < config.seatPriceFloor()) revert SeatPriceBelowFloor();
        if (seatPrice > config.seatPriceCeiling()) revert SeatPriceAboveCeiling();

        community = Clones.clone(communityImplementation);
        address ledger = Clones.clone(ledgerImplementation);

        uint256 communityId = communities.length;

        ICommunityInit.CommunityWiring memory w = ICommunityInit.CommunityWiring({
            config: address(config),
            factory: address(this),
            seats: address(seats),
            community: community,
            vault: ledger,
            creator: msg.sender,
            seatPrice: seatPrice,
            name: name,
            poolType: 0 // unused by both inits; a tier is named per vault record now
        });

        communities.push();
        CommunityEntry storage r = communities[communityId];
        r.community = community;
        r.ledger = ledger;
        communityIndex[community] = communityId + 1;
        contractRegistry[community] = communityId + 1;
        // Registered with `Seats` before `initialize`, because the founding seat is minted there.
        seats.registerCommunity(community, communityId);
        // Registered here before either `initialize`, because a later `join()` resolves its own
        // community through the registry, and because `Venue` gates every entry point on
        // `factory.isCommunityContract(msg.sender)`: a ledger wired to a tier while still outside
        // the registry would be born unable to deposit into it.
        vaultRegistry[ledger] = true;
        contractRegistry[ledger] = communityId + 1;
        ICommunityInit(community).initialize(w);
        ICommunityInit(ledger).initialize(w);

        emit CommunityCreated(communityId, msg.sender, community, ledger);
    }

    /// The community's one ledger, or 0 if `community` is not one this factory created.
    function ledgerOf(address community) external view returns (address) {
        uint256 idxPlusOne = communityIndex[community];
        if (idxPlusOne == 0) return address(0);
        return communities[idxPlusOne - 1].ledger;
    }

    /// The community's ledger, for any venue id that has been listed. One ledger serves every
    /// venue, so this answers the same address for every listed id and 0 for any other.
    function vaultOf(address community, uint8 poolType) external view returns (address) {
        uint256 idxPlusOne = communityIndex[community];
        if (idxPlusOne == 0 || poolType >= _venues.length) return address(0);
        return communities[idxPlusOne - 1].ledger;
    }

    function isCommunity(address vault) external view returns (bool) {
        return vaultRegistry[vault];
    }

    function isCommunityContract(address any) external view returns (bool) {
        return contractRegistry[any] != 0;
    }

    /// The community a registered community contract belongs to, plus one; 0 if unregistered. See
    /// `contractRegistry` for why it is plus one.
    function communityIdOf(address any) external view returns (uint256) {
        return contractRegistry[any];
    }

    function communityCount() external view returns (uint256) {
        return communities.length;
    }

    function communityAt(uint256 i) external view returns (address community) {
        return communities[i].community;
    }
}
