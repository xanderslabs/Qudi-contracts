// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.30;

import {Ownable} from "openzeppelin-contracts/contracts/access/Ownable.sol";
import {IVenue} from "../src/interfaces/IVenue.sol";
import {VenueFixture} from "./helpers/VenueFixture.sol";
import {MockStrategy} from "./mocks/MockStrategy.sol";

/// Adding a strategy to a Venue is a path to member money: a new strategy is somewhere new the
/// Venue's money can go. So it has its own role, held by the slower timelock, and the owner, the
/// faster one, cannot take it. Everything that only reshapes money among strategies already listed,
/// or brings it back, stays with the owner.
contract VenueStrategyListerTest is VenueFixture {
    address lister = makeAddr("lister");

    function setUp() public {
        setUpVenue();
    }

    function _handToLister() internal {
        vm.prank(owner);
        vault.setStrategyLister(lister);
    }

    /// The deployer lists the first strategies before handing the role on, so it starts with the
    /// owner.
    function test_theListerStartsAsTheOwner() public view {
        assertEq(vault.strategyLister(), owner);
    }

    function test_onlyTheListerAddsAStrategy() public {
        _handToLister();
        MockStrategy s = new MockStrategy(usdc, address(vault));

        vm.prank(owner);
        vm.expectRevert(IVenue.NotStrategyLister.selector);
        vault.addStrategy(address(s), 0);
        vm.prank(stranger);
        vm.expectRevert(IVenue.NotStrategyLister.selector);
        vault.addStrategy(address(s), 0);

        vm.prank(lister);
        vault.addStrategy(address(s), 0);
        assertTrue(vault.isStrategy(address(s)));
    }

    /// The owner cannot take the role back or give it away: only the lister names its successor.
    function test_onlyTheListerHandsTheRoleOn() public {
        _handToLister();
        address next = makeAddr("next");
        vm.prank(owner);
        vm.expectRevert(IVenue.NotStrategyLister.selector);
        vault.setStrategyLister(owner);

        vm.expectEmit(true, true, false, false, address(vault));
        emit IVenue.StrategyListerSet(lister, next);
        vm.prank(lister);
        vault.setStrategyLister(next);
        assertEq(vault.strategyLister(), next);

        vm.prank(next);
        vm.expectRevert(IVenue.ZeroAddress.selector);
        vault.setStrategyLister(address(0));
    }

    /// Removal, weights, caps and labels stay with the owner, and the lister has none of them.
    function test_theListerHasNoOtherPower() public {
        MockStrategy s = new MockStrategy(usdc, address(vault));
        vm.prank(owner);
        vault.addStrategy(address(s), 0);
        _handToLister();

        address[] memory list = new address[](1);
        uint16[] memory bps = new uint16[](1);
        list[0] = address(s);
        bps[0] = 5000;
        bytes memory unauthorized = abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, lister);

        vm.startPrank(lister);
        vm.expectRevert(unauthorized);
        vault.setWeights(list, bps);
        vm.expectRevert(unauthorized);
        vault.setCap(address(s), 1);
        vm.expectRevert(unauthorized);
        vault.removeStrategy(address(s));
        vm.expectRevert(unauthorized);
        vault.setLabels(_labels(MAX_RATE_BPS));
        vm.stopPrank();

        vm.startPrank(owner);
        vault.setWeights(list, bps);
        vault.setCap(address(s), 1);
        bps[0] = 0;
        vault.setWeights(list, bps);
        vault.removeStrategy(address(s));
        vm.stopPrank();
        assertFalse(vault.isStrategy(address(s)));
    }
}
