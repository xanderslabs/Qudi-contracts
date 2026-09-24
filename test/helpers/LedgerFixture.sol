// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {Clones} from "openzeppelin-contracts/contracts/proxy/Clones.sol";
import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {Ledger} from "../../src/Ledger.sol";
import {ILedger} from "../../src/interfaces/ILedger.sol";
import {ICommunityInit} from "../../src/interfaces/ICommunityInit.sol";
import {Venue} from "../../src/Venue.sol";
import {Config} from "../../src/Config.sol";
import {PauseGuard} from "../../src/PauseGuard.sol";
import {IConfig} from "../../src/interfaces/IConfig.sol";
import {ComplianceRegistry} from "../../src/ComplianceRegistry.sol";
import {ConfigKeys as K} from "../../src/ConfigKeys.sol";
import {VenueIds} from "./VenueIds.sol";
import {MockUSDC} from "../mocks/MockUSDC.sol";
import {IVenue} from "../../src/interfaces/IVenue.sol";
import {MockStrategy} from "../mocks/MockStrategy.sol";
import {ICreditCore} from "../../src/interfaces/ICreditCore.sol";

/// A stand-in factory: answers isCommunityContract for addresses we register, hands the ledger the
/// community id, and holds Qudi's venues in a registry, which is what the ledger resolves a venue
/// id from.
contract LedgerFactoryStub {
    mapping(address => bool) public isCommunityContract;
    mapping(address => uint256) public communityIdOf;
    mapping(uint256 => bool) public retired;
    address[] internal _venues;

    function register(address a) external {
        isCommunityContract[a] = true;
        communityIdOf[a] = 1;
    }

    /// Lists `vault` under the next id, as the real registry's `addVenue` does.
    function addVenue(address vault) external {
        _venues.push(vault);
    }

    function venueAt(uint256 id) external view returns (address) {
        return _venues[id];
    }

    function venueCount() external view returns (uint256) {
        return _venues.length;
    }

    function retireVenue(uint256 id) external {
        retired[id] = true;
    }

    function isActiveVenue(uint256 id) external view returns (bool) {
        return id < _venues.length && !retired[id];
    }
}

/// Membership, seasoning, freezing and the host, set directly by the test. The real `Community`
/// answers the same four questions and nothing else the ledger asks. A frozen member is not a
/// member (`isMember` false) and is also frozen; `freeze` sets both, as the real one does.
contract LedgerCommunityStub {
    mapping(address => bool) public isMember;
    mapping(address => bool) public isSeasoned;
    mapping(address => bool) public isFrozen;
    address public host;

    function setMember(address a, bool v) external {
        isMember[a] = v;
    }

    function setSeasoned(address a, bool v) external {
        isSeasoned[a] = v;
    }

    function freeze(address a) external {
        isFrozen[a] = true;
        isMember[a] = false;
    }

    function setHost(address a) external {
        host = a;
    }
}

/// The singleton CreditCore's community leg door. Checks the USDC arrived, exactly as the
/// real one does with `LegNotFunded`, so a leg nobody paid cannot pass here either, and refuses a
/// closed credit account, as the real one does with `CommunityIsClosed`.
contract LedgerCreditCoreStub {
    IERC20 public immutable usdc;
    mapping(uint256 => uint256) public legOf;
    mapping(uint256 => bool) public closed;
    uint256 internal _booked;

    error LegNotFunded();
    error CommunityIsClosed();

    constructor(IERC20 usdc_) {
        usdc = usdc_;
    }

    function close(uint256 communityId) external {
        closed[communityId] = true;
    }

    function communityCreditOf(uint256 communityId) external view returns (ICreditCore.CommunityCredit memory v) {
        v.closed = closed[communityId];
    }

    function receiveCommunityLeg(uint256 communityId, uint256 amount) external {
        if (closed[communityId]) revert CommunityIsClosed();
        if (usdc.balanceOf(address(this)) < _booked + amount) revert LegNotFunded();
        _booked += amount;
        legOf[communityId] += amount;
    }
}

/// One community's ledger over real `Venue` instances, wired the way `CommunityFactory` wires it.
/// Every venue carries one `MockStrategy` at full weight, and the labels a deployment gives it:
/// Flex Open with no exit time, Core Open with a one-day exit, Term Locked. A test makes a venue
/// illiquid by rebalancing its money into the strategy and capping what the strategy gives back.
abstract contract LedgerFixture is Test {
    MockUSDC usdc;
    Config config;
    ComplianceRegistry registry;
    LedgerFactoryStub factory;
    LedgerCommunityStub community;
    LedgerCreditCoreStub creditCore;
    Ledger ledger;

    Venue flexVault;
    Venue coreVault;
    Venue termVault;
    Venue[3] tierVaults;
    MockStrategy[3] strategies;
    MockStrategy flexVenue;
    MockStrategy coreVenue;

    address owner = makeAddr("vaultOwner");
    address treasury = makeAddr("treasury");
    address host = makeAddr("host");
    address ada = makeAddr("ada");
    address bea = makeAddr("bea");
    address cid = makeAddr("cid");
    address dan = makeAddr("dan");
    address eve = makeAddr("eve");
    address fay = makeAddr("fay");
    address stranger = makeAddr("stranger");
    address payee = makeAddr("payee");

    function setUpLedger() internal {
        usdc = new MockUSDC();
        registry = new ComplianceRegistry(address(this));
        vm.prank(owner);
        config = new Config(address(usdc), treasury, address(registry));

        factory = new LedgerFactoryStub();

        for (uint8 t = 0; t < VenueIds.COUNT; t++) {
            tierVaults[t] = _tierVault(t, "Qudi Tier", "qT");
            factory.addVenue(address(tierVaults[t]));
        }
        flexVault = tierVaults[VenueIds.FLEX];
        coreVault = tierVaults[VenueIds.CORE];
        termVault = tierVaults[VenueIds.TERM];
        for (uint8 t = 0; t < VenueIds.COUNT; t++) {
            strategies[t] = _venue(tierVaults[t], "", "");
        }
        flexVenue = strategies[VenueIds.FLEX];
        coreVenue = strategies[VenueIds.CORE];

        community = new LedgerCommunityStub();
        creditCore = new LedgerCreditCoreStub(IERC20(address(usdc)));
        vm.prank(owner);
        config.setAddress(K.CREDIT_CORE, address(creditCore));
        // Every flag off: the money paths ask the guard before money moves in.
        PauseGuard pauseGuard = new PauseGuard(address(this), address(this));
        vm.prank(owner);
        config.setAddress(K.PAUSE_GUARD, address(pauseGuard));

        ledger = Ledger(Clones.clone(address(new Ledger())));
        ledger.initialize(
            ICommunityInit.CommunityWiring({
                config: address(config),
                factory: address(factory),
                seats: address(0), // the ledger reads no seat
                community: address(community),
                vault: address(0),
                creator: host,
                seatPrice: 10e6,
                name: "Test Community",
                poolType: 0
            })
        );
        factory.register(address(ledger));

        community.setHost(host);
        address[8] memory people = [host, ada, bea, cid, dan, eve, fay, payee];
        for (uint256 i = 0; i < 7; i++) {
            community.setMember(people[i], true);
            community.setSeasoned(people[i], true);
        }
        for (uint256 i = 0; i < 8; i++) {
            usdc.mint(people[i], 1_000_000e6);
            vm.prank(people[i]);
            usdc.approve(address(ledger), type(uint256).max);
        }
    }

    function _tierVault(uint8 poolType, string memory n, string memory s) internal returns (Venue v) {
        v = new Venue(usdc, IConfig(address(config)), address(factory), owner, n, s);
        vm.prank(owner);
        v.setLabels(VenueIds.labels(poolType));
    }

    // ---- moving a venue's value ----

    /// A strategy gain of `amount` in `venueId`, then a year, which is long enough for the Venue's
    /// growth cap to let the whole of a gain up to a fifth of the Venue through.
    function _gain(uint8 venueId, uint256 amount) internal {
        usdc.mint(address(this), amount);
        usdc.approve(address(strategies[venueId]), amount);
        strategies[venueId].fund(amount);
        vm.warp(block.timestamp + 365 days);
    }

    /// A strategy loss of `amount`. A loss reaches the Venue's price at once. The venue's money is
    /// moved into the strategy first so there is something there to lose.
    function _loss(uint8 venueId, uint256 amount) internal {
        tierVaults[venueId].rebalance();
        strategies[venueId].skim(amount);
    }

    /// Moves every idle dollar into the strategy and lets it give nothing back, so the venue can pay
    /// nobody until `_liquid` is called.
    function _illiquid(uint8 venueId) internal {
        tierVaults[venueId].rebalance();
        strategies[venueId].setWithdrawCap(0);
    }

    function _liquid(uint8 venueId) internal {
        strategies[venueId].setWithdrawCap(type(uint256).max);
    }

    function _venue(Venue v, string memory, string memory) internal returns (MockStrategy m) {
        m = new MockStrategy(usdc, address(v));
        address[] memory vs = new address[](1);
        vs[0] = address(m);
        uint16[] memory bps = new uint16[](1);
        bps[0] = 10_000;
        vm.startPrank(owner);
        v.addStrategy(address(m), 0);
        v.setCap(address(m), type(uint256).max);
        v.setWeights(vs, bps);
        vm.stopPrank();
    }

    // ---- shorthands the proofs read better with ----

    function _personal(address who, uint8 venueId, uint64 lockedUntil) internal returns (uint256 id) {
        vm.prank(who);
        id = ledger.createVault(_params(venueId, false, lockedUntil, "personal"));
    }

    function _shared(uint8 venueId) internal returns (uint256 id) {
        vm.prank(host);
        id = ledger.createVault(_params(venueId, true, 0, "shared"));
    }

    function _params(uint8 venueId, bool shared, uint64 lockedUntil, string memory n)
        internal
        pure
        returns (ILedger.VaultParams memory)
    {
        return ILedger.VaultParams({venueId: venueId, shared: shared, lockedUntil: lockedUntil, name: n});
    }

    function _withdraw(address who, uint256 vaultId, uint256 amount) internal returns (uint256 id) {
        vm.prank(who);
        id = ledger.requestWithdraw(vaultId, amount);
    }

    /// The host asks for `amount` from `vaultId` to `to`.
    function _propose(uint256 vaultId, address to, uint256 amount) internal returns (uint256 id) {
        vm.prank(host);
        id = ledger.proposeWithdrawal(vaultId, to, amount);
    }

    function _vote(address who, uint256 payoutId, bool support) internal {
        vm.prank(who);
        ledger.voteOnWithdrawal(payoutId, support);
    }

    /// The vault's community closes it, as `Community.executeClosure` does.
    function _closeCommunity() internal {
        vm.prank(address(community));
        ledger.closeCommunity();
    }

    function _deposit(address who, uint256 vaultId, uint256 amount) internal {
        vm.prank(who);
        ledger.deposit(vaultId, amount);
    }
}
