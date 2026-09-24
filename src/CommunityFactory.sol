// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.30;

import {Clones} from "openzeppelin-contracts/contracts/proxy/Clones.sol";
import {IConfig} from "./interfaces/IConfig.sol";
import {ICommunityFactory} from "./interfaces/ICommunityFactory.sol";
import {ICommunityInit} from "./interfaces/ICommunityInit.sol";
import {PoolTypes} from "./PoolTypes.sol";

/// Anyone creates a community; the creator becomes founding steward and receives the founding
/// seat unpaid inside initialize() (the creator does not pay for their own founding mint;
/// every later seat is a paid mint splitting 40/30/30).
/// Clones are EIP-1167 minimal proxies over immutable implementations: a deployment cost
/// device, never an upgrade device.
///
/// `createCommunity` deploys **two** clones, seats and the ledger: a
/// community is `Community` and `Ledger`, however many vaults or tiers it opens. It used to
/// deploy seats alone and clone a further ledger per tier, and that was collapsed into one.
///
/// There is no tier opt-in. The host opt-in this factory used to carry is gone:
/// every tier Qudi has deployed in `pools` is available to every community, the host picks one
/// when creating a shared vault, and a member picks one for their own. The tier vault is the
/// strategy layer every community in that tier shares, and the ledger is the per-community book
/// that divides its own position in that tier between vault records; the ledger
/// reads `pools` here to resolve it.
contract CommunityFactory is ICommunityFactory {
    IConfig public immutable config;
    address public immutable seatsImplementation;
    address public immutable ledgerImplementation;
    /// One shared pool instance per pool type (PoolTypes.sol), indexed by the PoolTypes
    /// constant: a `Venue` in every slot, FLEX, CORE and TERM, since a community has
    /// exactly one custody layer per tier either way. This is the whole of what decides which
    /// tiers exist, and it is Qudi's: a ledger reads it to resolve the tier a vault
    /// record named, and no community has a say in it.
    address[3] public pools;

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
    /// `seatsIndex` below is 1-based.
    ///
    /// `CreditCore.receiveCommunityLeg` is what needs the id: a community contract paying a leg
    /// names its community, and the callee resolves the caller here rather than trusting the
    /// name. The alternative, having the caller pass its own seats address for the factory to
    /// resolve through `seatsIndex`, was rejected: it lets a
    /// registered community contract top up a community it does not belong to.
    mapping(address => uint256) internal contractRegistry;
    /// 1-based index into `communities` for a registered seats contract; 0 means unregistered.
    mapping(address => uint256) internal seatsIndex;

    error ZeroAddress();

    /// Parameter order is intentional, not incidental: the clone implementations
    /// (`seatsImpl_`/`ledgerImpl_`) are grouped contiguously, each a single address; `pools_`
    /// sits last since it is structurally different, a fixed-size array rather than a single
    /// address. There was a third implementation, for the per-community credit pool, until
    /// that contract was deleted.
    constructor(address config_, address seatsImpl_, address ledgerImpl_, address[3] memory pools_) {
        if (config_ == address(0) || seatsImpl_ == address(0) || ledgerImpl_ == address(0)) revert ZeroAddress();
        for (uint256 i; i < pools_.length; i++) {
            if (pools_[i] == address(0)) revert ZeroAddress();
        }
        config = IConfig(config_);
        seatsImplementation = seatsImpl_;
        ledgerImplementation = ledgerImpl_;
        pools = pools_;
    }

    function createCommunity(string calldata name, uint256 seatPrice) external returns (address community) {
        if (seatPrice < config.seatPriceFloor()) revert SeatPriceBelowFloor();

        community = Clones.clone(seatsImplementation);
        address ledger = Clones.clone(ledgerImplementation);

        uint256 communityId = communities.length;

        ICommunityInit.CommunityWiring memory w = ICommunityInit.CommunityWiring({
            config: address(config),
            factory: address(this),
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
        seatsIndex[community] = communityId + 1;
        contractRegistry[community] = communityId + 1;
        // Registered before either `initialize`, because the founding mint inside the seats one
        // pays no seat fee but a later `join()` resolves its own community through the registry,
        // and because `Venue` gates every entry point on
        // `factory.isCommunityContract(msg.sender)`: a ledger wired to a tier while still outside
        // the registry would be born unable to deposit into it.
        vaultRegistry[ledger] = true;
        contractRegistry[ledger] = communityId + 1;
        ICommunityInit(community).initialize(w);
        ICommunityInit(ledger).initialize(w);

        emit CommunityCreated(communityId, msg.sender, community, ledger);
    }

    /// The community's one ledger, or 0 if `seats` is not one this factory minted.
    function ledgerOf(address community) external view returns (address) {
        uint256 idxPlusOne = seatsIndex[community];
        if (idxPlusOne == 0) return address(0);
        return communities[idxPlusOne - 1].ledger;
    }

    /// The community's ledger, for any tier that exists. One ledger serves every tier
    /// and every tier is available to every community, so this answers the same
    /// address for every `poolType` below `PoolTypes.COUNT` and 0 above it.
    function vaultOf(address community, uint8 poolType) external view returns (address) {
        uint256 idxPlusOne = seatsIndex[community];
        if (idxPlusOne == 0 || poolType >= PoolTypes.COUNT) return address(0);
        return communities[idxPlusOne - 1].ledger;
    }

    function vaultsOf(address community) external view returns (address[3] memory out) {
        uint256 idxPlusOne = seatsIndex[community];
        if (idxPlusOne == 0) return out;
        address ledger = communities[idxPlusOne - 1].ledger;
        for (uint8 t = 0; t < PoolTypes.COUNT; t++) {
            out[t] = ledger;
        }
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
