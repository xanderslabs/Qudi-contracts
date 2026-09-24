// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {Config} from "../src/Config.sol";
import {ConfigKeys as K} from "../src/ConfigKeys.sol";
import {CommunityFactory} from "../src/CommunityFactory.sol";
import {Seats} from "../src/Seats.sol";
import {Ledger} from "../src/Ledger.sol";
import {ILedger} from "../src/interfaces/ILedger.sol";
import {Venue} from "../src/Venue.sol";
import {VenueIds} from "./helpers/VenueIds.sol";
import {ICommunityInit} from "../src/interfaces/ICommunityInit.sol";
import {ICommunityFactory} from "../src/interfaces/ICommunityFactory.sol";
import {IConfig} from "../src/interfaces/IConfig.sol";
import {MockCommunityModule} from "./mocks/MockCommunityModule.sol";
import {ComplianceRegistry} from "../src/ComplianceRegistry.sol";
import {Community} from "../src/Community.sol";
import {ICommunity} from "../src/interfaces/ICommunity.sol";
import {MockUSDC} from "./mocks/MockUSDC.sol";
import {MockVault, MockCreditPool} from "./mocks/MockSeatSiblings.sol";

/// Deploys `Seats` naming the factory's address, then the factory, as a deployment must: `Seats`
/// trusts one factory, fixed at its construction. The deployer owns the factory and lists `pools`
/// in the venue registry in order, so venue id `t` is `pools[t]`.
function deployFactory(
    Vm vm_,
    address deployer,
    address cfg,
    address communityImpl,
    address ledgerImpl,
    address[3] memory pools
) returns (CommunityFactory factory) {
    Seats seats = new Seats(vm_.computeCreateAddress(deployer, vm_.getNonce(deployer) + 1), IConfig(cfg));
    factory = new CommunityFactory(cfg, address(seats), communityImpl, ledgerImpl, deployer);
    for (uint256 t; t < 3; t++) {
        factory.addVenue(pools[t]);
    }
}

contract FactoryTest is Test {
    Config cfg;
    CommunityFactory factory;
    MockUSDC usdc; // real ERC20 so createCommunity's founding-mint transferFrom has code to call

    // Distinct dummy addresses, one per venue id. MockCommunityModule.setVault only records
    // what it was handed, so these never need to answer real Venue calls; only their
    // identity is asserted.
    address[3] poolAddrs;

    function setUp() public {
        usdc = new MockUSDC();
        cfg = new Config(address(usdc), makeAddr("treasury"), makeAddr("complianceRegistry"));
        poolAddrs = [makeAddr("vaultFlex"), makeAddr("vaultCoreL1"), makeAddr("vaultTerm")];
        factory = deployFactory(
            vm,
            address(this),
            address(cfg),
            address(new MockCommunityModule()),
            address(new MockCommunityModule()),
            poolAddrs
        );
    }

    function test_createCommunityClonesAndWires() public {
        address creator = makeAddr("creator");
        vm.prank(creator);
        address community = factory.createCommunity("Lagos Circle", 50e6);

        ICommunityInit.CommunityWiring memory ws = MockCommunityModule(community).wiring();
        assertEq(ws.creator, creator);
        assertEq(ws.community, community);
        assertEq(ws.config, address(cfg));
        assertEq(ws.factory, address(factory));
        assertEq(ws.seats, address(factory.seats()), "the community is told the one Seats contract");
        assertTrue(factory.seats().isRegistered(community), "and Seats knows it as a community");
        assertEq(ws.seatPrice, 50e6);
        assertEq(ws.name, "Lagos Circle");

        // A community is two clones from the start, the community and its one ledger.
        address ledger = factory.ledgerOf(community);
        assertTrue(ledger != address(0) && ledger != community);
        assertEq(ws.vault, ledger, "the community is told its ledger");
        assertFalse(factory.seats().isRegistered(ledger), "a ledger is not a community to Seats");

        assertFalse(factory.isCommunity(community)); // isCommunity is keyed on the ledger
        assertTrue(factory.isCommunity(ledger));
        assertTrue(factory.isCommunityContract(community));
        assertTrue(factory.isCommunityContract(ledger));
        assertEq(factory.communityCount(), 1);
        assertEq(factory.communityAt(0), community);

        ICommunityInit.CommunityWiring memory wv = MockCommunityModule(ledger).wiring();
        assertEq(wv.community, community);
        assertEq(wv.vault, ledger);
        assertEq(wv.config, address(cfg));
        assertEq(wv.factory, address(factory));

        // Every tier is available from the moment the community exists, so every
        // one of them answers with the ledger and nothing has to be opened first.
        for (uint8 t = 0; t < VenueIds.COUNT; t++) {
            assertEq(factory.vaultOf(community, t), ledger);
            assertEq(factory.venueAt(t), poolAddrs[t], "and Qudi's own vault sits behind it");
        }
        assertEq(factory.vaultOf(community, VenueIds.COUNT), address(0), "no tier above the range");
    }

    /// `contractRegistry` carries the community id plus one, written at both registration
    /// sites. `isCommunityContract` is the `!= 0` read and `communityIdOf` is the id read, so a
    /// community contract of community 1 can never resolve to community 0.
    function test_registryCarriesTheCommunityIdAtBothSites() public {
        address community0 = factory.createCommunity("Zero", 50e6);
        address community1 = factory.createCommunity("One", 50e6);

        assertEq(factory.communityIdOf(community0), 1, "community 0, plus one");
        assertEq(factory.communityIdOf(community1), 2, "community 1, plus one");

        address ledger0 = factory.ledgerOf(community0);
        address ledger1 = factory.ledgerOf(community1);

        assertEq(factory.communityIdOf(ledger0), 1, "a ledger resolves to its own community");
        assertEq(factory.communityIdOf(ledger1), 2);

        // Unregistered reads as zero, which is what makes the plus-one necessary: community 0
        // is a real community.
        assertEq(factory.communityIdOf(makeAddr("stranger")), 0);
        assertFalse(factory.isCommunityContract(makeAddr("stranger")));
        assertTrue(factory.isCommunityContract(community0));
        assertTrue(factory.isCommunityContract(ledger1));
    }

    function test_floorEnforced() public {
        cfg.set(K.SEAT_PRICE_FLOOR, 50e6);
        vm.expectRevert(ICommunityFactory.SeatPriceBelowFloor.selector);
        factory.createCommunity("Cheap", 49e6);
        cfg.set(K.SEAT_PRICE_FLOOR, 100e6);
        vm.expectRevert(ICommunityFactory.SeatPriceBelowFloor.selector);
        factory.createCommunity("NowTooCheap", 50e6); // floor read live at use
    }

    /// A `Seats` that trusts another factory would refuse every community this one creates, so
    /// the factory refuses it at construction.
    function test_refusesASeatsWiredToAnotherFactory() public {
        Seats wrong = new Seats(makeAddr("anotherFactory"), IConfig(address(cfg)));
        address communityImpl = address(new MockCommunityModule());
        address ledgerImpl = address(new MockCommunityModule());
        vm.expectRevert(CommunityFactory.SeatsNotWiredToThisFactory.selector);
        new CommunityFactory(address(cfg), address(wrong), communityImpl, ledgerImpl, address(this));
    }

    function test_strangerCannotSpoofRegistry() public {
        assertFalse(factory.isCommunity(makeAddr("attacker")));
        assertFalse(factory.isCommunityContract(makeAddr("attacker")));
    }

    function testFuzz_manyCommunitiesDistinct(uint8 n) public {
        n = uint8(bound(n, 2, 20));
        for (uint256 i; i < n; i++) {
            factory.createCommunity("U", 50e6);
        }
        assertEq(factory.communityCount(), n);
        address sA = factory.communityAt(0);
        address sB = factory.communityAt(n - 1);
        assertTrue(sA != sB);
    }
}

/// The real Ledger as the ledger implementation and a real `Venue` per tier, TERM
/// included, so `createCommunity`'s clone-init and the ledger's own tier resolution are exercised end
/// to end rather than just recorded by a mock. The community stays MockCommunityModule: nothing here
/// drives a community function.
contract FactoryTierResolutionTest is Test {
    MockUSDC usdc;
    Config cfg;
    CommunityFactory factory;
    Venue[3] vaults; // one per venue id. 3 is VenueIds.COUNT, spelled out because a library
    // constant is not a valid array length.
    Venue coreVault; // vaults[VenueIds.CORE]

    address owner = makeAddr("owner");

    function setUp() public {
        usdc = new MockUSDC();
        cfg = new Config(address(usdc), makeAddr("treasury"), address(new ComplianceRegistry(address(this))));
        address[3] memory poolAddrs;
        for (uint8 i; i < VenueIds.COUNT; i++) {
            // `factory_` is not exercised by these tests (no deposit/redeem flows), so the
            // placeholder avoids the vault/factory circular-constructor dance real deployments
            // need (see script/Deploy.s.sol).
            vaults[i] = new Venue(usdc, IConfig(address(cfg)), address(this), owner, "Qudi Pool", "qP");
            vm.prank(owner);
            vaults[i].setLabels(VenueIds.labels(i));
            poolAddrs[i] = address(vaults[i]);
        }
        coreVault = vaults[VenueIds.CORE];
        factory = deployFactory(
            vm, address(this), address(cfg), address(new MockCommunityModule()), address(new Ledger()), poolAddrs
        );
    }

    /// The venue registry is the whole of what decides which venues exist, and it is Qudi's. A
    /// ledger reads it to resolve the venue a vault record named; no community has a say in it.
    function test_poolsIsQudisAndAnswersEveryTier() public view {
        for (uint8 t = 0; t < VenueIds.COUNT; t++) {
            assertEq(factory.venueAt(t), address(vaults[t]));
        }
    }

    /// One ledger, every tier, from creation. No opening, no per-tier bookkeeping.
    function test_createCommunity_givesOneLedgerThatReachesEveryTier() public {
        address community = factory.createCommunity("Ada's", 50e6);
        address ledger = factory.ledgerOf(community);
        assertTrue(ledger != address(0));
        assertTrue(factory.isCommunity(ledger));
        assertTrue(factory.isCommunityContract(ledger));

        for (uint8 t = 0; t < VenueIds.COUNT; t++) {
            assertEq(factory.vaultOf(community, t), ledger);
            assertEq(ILedger(ledger).tierVault(t), address(vaults[t]));
        }
    }

    /// TERM resolves like any other tier since 2026-09-21: the same ledger
    /// over the same Venue machinery. It used to clone a LockedVault and wire it to a
    /// LockedQAMO instead.
    function test_termIsAnOrdinaryTier() public {
        address community = factory.createCommunity("u", 50e6);
        address ledger = factory.ledgerOf(community);
        Ledger l = Ledger(ledger);
        assertEq(address(l.community()), community);
        assertEq(l.tierVault(VenueIds.TERM), address(vaults[VenueIds.TERM]));
        assertEq(factory.vaultOf(community, VenueIds.TERM), ledger);
    }

    /// A tier above the range is not a tier. `vaultOf` answers 0 rather than panicking on the
    /// array, and the ledger's own view refuses with the config's typed error.
    function test_outOfRangeTier() public {
        address community = factory.createCommunity("u", 50e6);
        assertEq(factory.vaultOf(community, VenueIds.COUNT), address(0));
        assertEq(factory.vaultOf(community, 200), address(0));

        // Resolved before the arm: an argument that is itself a call would consume it.
        address ledger = factory.ledgerOf(community);
        vm.expectRevert(IConfig.UnknownPoolType.selector);
        ILedger(ledger).tierVault(VenueIds.COUNT);
    }

    function test_unregisteredCommunityResolvesToNothing() public {
        assertEq(factory.ledgerOf(makeAddr("stranger")), address(0));
        assertEq(factory.vaultOf(makeAddr("stranger"), VenueIds.FLEX), address(0));
    }
}

/// Founding seat wiring: real Community as the community implementation, mock vault/credit
/// pool siblings. Separate fixture from FactoryTest because it needs a real ERC20 USDC
/// and real Community, not the MockCommunityModule stand-in for all three clones.
contract FactoryFoundingMintTest is Test {
    MockUSDC usdc;
    Config cfg;
    CommunityFactory factory;
    ComplianceRegistry registry;
    address treasury = makeAddr("treasury");
    address creator = makeAddr("creator");

    function setUp() public {
        usdc = new MockUSDC();
        registry = new ComplianceRegistry(address(this));
        vm.prank(creator);
        registry.attest(1);
        cfg = new Config(address(usdc), treasury, address(registry));
        address[3] memory poolAddrs = [makeAddr("vaultFlex"), makeAddr("vaultCoreL1"), makeAddr("vaultTerm")];
        factory = deployFactory(
            vm, address(this), address(cfg), address(new Community()), address(new MockVault()), poolAddrs
        );
    }

    /// The creator does not pay for their own founding seat.
    /// A creator holding zero USDC can found a community; no split runs and no USDC moves.
    function test_createCommunityFoundingSeatUnpaid() public {
        assertEq(usdc.balanceOf(creator), 0);
        vm.prank(creator);
        address communityAddr = factory.createCommunity("Lagos Circle", 100e6);
        ICommunity s = ICommunity(communityAddr);
        assertEq(s.host(), creator);
        assertTrue(s.isMember(creator));
        assertEq(s.memberCount(), 1);
        assertEq(usdc.balanceOf(creator), 0); // nothing pulled
        assertEq(usdc.balanceOf(communityAddr), 0); // nothing held
        assertEq(usdc.balanceOf(treasury), 0); // no protocol leg from the founding seat
    }

    /// I1: the founding seat is a mint like any other, so the creator passes the same
    /// gates every join() caller passes: attested for themselves, and not screener-blocked.
    /// Without this a blocked wallet could found a community and take the host role, and the
    /// 30% host leg of every later mint would flow to it.
    function test_createCommunityGatesCreator() public {
        address elsa = makeAddr("elsa");

        // Unattested creator cannot found a community.
        vm.prank(elsa);
        vm.expectRevert(ICommunity.NotAttested.selector);
        factory.createCommunity("Lagos Circle", 100e6);
        assertEq(factory.communityCount(), 0);

        // Attested but blocked: still cannot.
        vm.prank(elsa);
        registry.attest(1);
        registry.setBlocked(elsa, true); // test contract holds the screener role
        vm.prank(elsa);
        vm.expectRevert(ICommunity.AccountBlocked.selector);
        factory.createCommunity("Lagos Circle", 100e6);
        assertEq(factory.communityCount(), 0);

        // Unblocked: founds it.
        registry.setBlocked(elsa, false);
        vm.prank(elsa);
        factory.createCommunity("Lagos Circle", 100e6);
        assertEq(factory.communityCount(), 1);
    }
}
