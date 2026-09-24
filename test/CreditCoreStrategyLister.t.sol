// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.30;

import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {Ownable} from "openzeppelin-contracts/contracts/access/Ownable.sol";
import {ICreditCore} from "../src/interfaces/ICreditCore.sol";
import {CreditFixture} from "./helpers/CreditFixture.sol";
import {MockStrategy} from "./mocks/MockStrategy.sol";

/// The pool holds community balances, so listing somewhere new it may invest is a path to member
/// money. Adding a pool strategy has its own role, held by the slower timelock, which the owner can
/// neither take nor give away. Removing one, which only brings money back, stays with the owner.
contract CreditCoreStrategyListerTest is CreditFixture {
    address lister = makeAddr("lister");

    function _handToLister() internal {
        core.setStrategyLister(lister);
    }

    function _strategy() internal returns (MockStrategy) {
        return new MockStrategy(IERC20(address(usdc)), address(core));
    }

    /// The deployer lists any first strategies before handing the role on, so it starts with the owner.
    function test_theListerStartsAsTheOwner() public view {
        assertEq(core.strategyLister(), address(this));
    }

    function test_onlyTheListerAddsAPoolStrategy() public {
        _handToLister();
        MockStrategy s = _strategy();
        vm.expectRevert(ICreditCore.NotStrategyLister.selector);
        core.addStrategy(address(s));
        vm.prank(stranger);
        vm.expectRevert(ICreditCore.NotStrategyLister.selector);
        core.addStrategy(address(s));

        vm.prank(lister);
        core.addStrategy(address(s));
        assertTrue(core.isStrategy(address(s)));
    }

    function test_onlyThePoolListerHandsTheRoleOn() public {
        _handToLister();
        address next = makeAddr("next");
        vm.expectRevert(ICreditCore.NotStrategyLister.selector);
        core.setStrategyLister(address(this));

        vm.expectEmit(true, true, false, false, address(core));
        emit ICreditCore.StrategyListerSet(lister, next);
        vm.prank(lister);
        core.setStrategyLister(next);
        assertEq(core.strategyLister(), next);

        vm.prank(next);
        vm.expectRevert(ICreditCore.ZeroAddress.selector);
        core.setStrategyLister(address(0));
    }

    /// Removal stays with the owner, and the lister cannot remove.
    function test_removalStaysWithTheOwner() public {
        MockStrategy s = _strategy();
        core.addStrategy(address(s));
        _handToLister();
        vm.prank(lister);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, lister));
        core.removeStrategy(address(s));
        core.removeStrategy(address(s));
        assertFalse(core.isStrategy(address(s)));
    }
}
