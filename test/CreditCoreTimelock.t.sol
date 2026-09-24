// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.30;

import {TimelockController} from "openzeppelin-contracts/contracts/governance/TimelockController.sol";
import {Ownable} from "openzeppelin-contracts/contracts/access/Ownable.sol";
import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {ICreditCore} from "../src/interfaces/ICreditCore.sol";
import {CreditFixture} from "./helpers/CreditFixture.sol";
import {MockStrategy} from "./mocks/MockStrategy.sol";

/// On mainnet the owner, the strategy lister and the allocation multisig are `TimelockController`s.
/// Listing a pool strategy waits out the lister's delay, taking Qudi's money out waits out the
/// owner's, and a grant waits out its own, so a stolen key is seen before it can move anything.
contract CreditCoreTimelockTest is CreditFixture {
    TimelockController ownerLock;
    TimelockController allocationLock;
    address dev = makeAddr("dev");

    uint256 constant DELAY = 24 hours;

    function setUp() public override {
        super.setUp();
        address[] memory ops = new address[](1);
        ops[0] = dev;
        ownerLock = new TimelockController(DELAY, ops, ops, address(0));
        allocationLock = new TimelockController(DELAY, ops, ops, address(0));

        _community(0, 1);
        usdc.mint(address(this), 1_000e6);
        usdc.approve(address(core), 1_000e6);
        core.fund(1_000e6);
        core.setAllocationMultisig(address(allocationLock));
        core.transferOwnership(address(ownerLock));
        _viaLock(ownerLock, address(core), abi.encodeCall(Ownable2StepLike.acceptOwnership, ()));
    }

    function _devOnly() internal view returns (address[] memory ops) {
        ops = new address[](1);
        ops[0] = dev;
    }

    function _viaLock(TimelockController lock, address target, bytes memory data) internal {
        vm.prank(dev);
        lock.schedule(target, 0, data, bytes32(0), bytes32(0), DELAY);
        vm.warp(block.timestamp + DELAY);
        vm.prank(dev);
        lock.execute(target, 0, data, bytes32(0), bytes32(0));
    }

    function test_allocation24hDelayEnforced() public {
        bytes memory data = abi.encodeCall(core.allocate, (0, 100e6, ICreditCore.AllocationType.Growth));
        vm.prank(dev);
        allocationLock.schedule(address(core), 0, data, bytes32(0), bytes32(0), DELAY);

        vm.warp(block.timestamp + DELAY - 1);
        vm.prank(dev);
        vm.expectRevert();
        allocationLock.execute(address(core), 0, data, bytes32(0), bytes32(0));

        vm.warp(block.timestamp + 1);
        vm.prank(dev);
        allocationLock.execute(address(core), 0, data, bytes32(0), bytes32(0));
        assertEq(_credit(0).allocation, 100e6);
    }

    function test_directAllocateBypassingTheLockReverts() public {
        vm.prank(dev);
        vm.expectRevert(ICreditCore.NotAllocationMultisig.selector);
        core.allocate(0, 1e6, ICreditCore.AllocationType.Growth);
    }

    /// A pool strategy is listed only through the strategy lister, after its delay. Here the lister
    /// role is handed to a timelock the way a deployment hands it to the slower one.
    function test_addStrategyWaitsForTheListersDelay() public {
        TimelockController listerLock = new TimelockController(DELAY, _devOnly(), _devOnly(), address(0));
        core.setStrategyLister(address(listerLock));
        MockStrategy s = new MockStrategy(IERC20(address(usdc)), address(core));
        vm.prank(dev);
        vm.expectRevert(ICreditCore.NotStrategyLister.selector);
        core.addStrategy(address(s));

        _viaLock(listerLock, address(core), abi.encodeCall(core.addStrategy, (address(s))));
        assertTrue(core.isStrategy(address(s)));
    }

    /// Qudi's money leaves only through the owner's delay.
    function test_withdrawTreasuryWaitsForTheOwnersDelay() public {
        address to = makeAddr("coldTreasury");
        vm.prank(dev);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, dev));
        core.withdrawTreasury(to, 1e6);

        _viaLock(ownerLock, address(core), abi.encodeCall(core.withdrawTreasury, (to, 400e6)));
        assertEq(usdc.balanceOf(to), 400e6);
    }
}

interface Ownable2StepLike {
    function acceptOwnership() external;
}
