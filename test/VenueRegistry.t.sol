// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {Ownable} from "openzeppelin-contracts/contracts/access/Ownable.sol";
import {Config} from "../src/Config.sol";
import {IConfig} from "../src/interfaces/IConfig.sol";
import {CommunityFactory} from "../src/CommunityFactory.sol";
import {ICommunityFactory} from "../src/interfaces/ICommunityFactory.sol";
import {Seats} from "../src/Seats.sol";
import {Venue} from "../src/Venue.sol";
import {ComplianceRegistry} from "../src/ComplianceRegistry.sol";
import {MockUSDC} from "./mocks/MockUSDC.sol";
import {MockCommunityModule} from "./mocks/MockCommunityModule.sol";

/// The venue registry in `CommunityFactory`. Qudi's owner lists venues and retires them; nothing
/// is ever removed, so a venue id means the same venue for as long as the chain exists.
contract VenueRegistryTest is Test {
    MockUSDC usdc;
    Config cfg;
    CommunityFactory factory;
    address owner = address(0xA11CE);
    address stranger = address(0xBAD);

    function setUp() public {
        usdc = new MockUSDC();
        cfg = new Config(address(usdc), makeAddr("treasury"), address(new ComplianceRegistry(address(this))));
        address communityImpl = address(new MockCommunityModule());
        address ledgerImpl = address(new MockCommunityModule());
        Seats seats = new Seats(vm.computeCreateAddress(address(this), vm.getNonce(address(this)) + 1));
        factory = new CommunityFactory(address(cfg), address(seats), communityImpl, ledgerImpl, owner);
    }

    function _venue(string memory n) internal returns (Venue v) {
        v = new Venue(usdc, IConfig(address(cfg)), address(factory), owner, n, n);
    }

    function test_proof11_onlyTheOwnerAddsAVenue() public {
        Venue v = _venue("Flex");
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger));
        vm.prank(stranger);
        factory.addVenue(address(v));

        vm.expectRevert(CommunityFactory.ZeroAddress.selector);
        vm.prank(owner);
        factory.addVenue(address(0));
    }

    /// Ids are handed out in order from zero, and each resolves to the venue it was given to.
    function test_proof11_idsAreSequential() public {
        Venue flex = _venue("Flex");
        Venue core = _venue("Core");
        Venue term = _venue("Term");
        vm.startPrank(owner);
        vm.expectEmit(true, false, false, true, address(factory));
        emit ICommunityFactory.VenueAdded(0, address(flex));
        assertEq(factory.addVenue(address(flex)), 0);
        assertEq(factory.addVenue(address(core)), 1);
        assertEq(factory.addVenue(address(term)), 2);
        vm.stopPrank();

        assertEq(factory.venueCount(), 3);
        assertEq(factory.venueAt(0), address(flex));
        assertEq(factory.venueAt(1), address(core));
        assertEq(factory.venueAt(2), address(term));
        for (uint256 i; i < 3; i++) {
            assertTrue(factory.isActiveVenue(i), "a new venue is active");
        }
        assertFalse(factory.isActiveVenue(3), "an id never handed out is not a venue");
        vm.expectRevert(ICommunityFactory.UnknownVenue.selector);
        factory.venueAt(3);
    }

    /// A retired venue takes no new vaults, which the registry view answers. It is not removed:
    /// its id still resolves, and the money in it is untouched.
    function test_proof11_aRetiredVenueRejectsNewVaultsAndKeepsItsMoney() public {
        Venue core = _venue("Core");
        vm.prank(owner);
        uint256 id = factory.addVenue(address(core));

        // A registered ledger puts money in, the way a community's ledger would.
        address community = factory.createCommunity("Circle", 0);
        address ledger = factory.ledgerOf(community);
        usdc.mint(ledger, 1_000e6);
        vm.startPrank(ledger);
        usdc.approve(address(core), type(uint256).max);
        core.deposit(1_000e6, ledger);
        vm.stopPrank();

        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger));
        vm.prank(stranger);
        factory.retireVenue(id);

        vm.expectEmit(true, false, false, true, address(factory));
        emit ICommunityFactory.VenueRetired(id);
        vm.prank(owner);
        factory.retireVenue(id);

        assertFalse(factory.isActiveVenue(id), "no new vault may choose it");
        assertEq(factory.venueAt(id), address(core), "the id still resolves");
        assertEq(factory.venueCount(), 1, "nothing was removed");
        assertEq(core.totalAssets(), 1_000e6, "the money in it is untouched");

        // And it still pays out.
        vm.prank(ledger);
        core.withdraw(400e6, ledger, ledger);
        assertEq(usdc.balanceOf(ledger), 400e6);

        vm.expectRevert(ICommunityFactory.UnknownVenue.selector);
        vm.prank(owner);
        factory.retireVenue(7);
    }
}
