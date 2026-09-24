// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {Ownable} from "openzeppelin-contracts/contracts/access/Ownable.sol";
import {TimelockController} from "openzeppelin-contracts/contracts/governance/TimelockController.sol";
import {PauseGuard} from "../src/PauseGuard.sol";
import {IPauseGuard} from "../src/interfaces/IPauseGuard.sol";

/// The pause key stops things with no delay, because a pause that waits a day is not a pause. The
/// timelock owns the guard and alone decides who holds that key, so a stolen pause key can stop
/// deposits but can never hand the power on, and a stolen owner key still waits out the delay.
contract PauseGuardTest is Test {
    PauseGuard guard;
    TimelockController lock;
    address owner = makeAddr("owner");
    address pauser = makeAddr("pauser");
    address stranger = makeAddr("stranger");

    uint256 constant DELAY = 24 hours;

    function setUp() public {
        address[] memory ops = new address[](1);
        ops[0] = owner;
        lock = new TimelockController(DELAY, ops, ops, address(0));
        guard = new PauseGuard(address(this), pauser);
        guard.transferOwnership(address(lock));
        _viaLock(abi.encodeCall(guard.acceptOwnership, ()));
        assertEq(guard.owner(), address(lock));
    }

    function _viaLock(bytes memory data) internal {
        vm.prank(owner);
        lock.schedule(address(guard), 0, data, bytes32(0), bytes32(0), DELAY);
        vm.warp(block.timestamp + DELAY);
        vm.prank(owner);
        lock.execute(address(guard), 0, data, bytes32(0), bytes32(0));
    }

    function _flags() internal pure returns (IPauseGuard.Flag[3] memory) {
        return [IPauseGuard.Flag.DEPOSITS, IPauseGuard.Flag.DRAWS, IPauseGuard.Flag.VENUES];
    }

    // ---- proof 3: only the pauser pauses ----

    /// Every flag starts off, so a fresh deployment takes money until someone decides otherwise.
    function test_everyFlagStartsOff() public view {
        IPauseGuard.Flag[3] memory f = _flags();
        for (uint256 i; i < f.length; i++) {
            assertFalse(guard.paused(f[i]));
        }
        assertEq(guard.pauser(), pauser);
    }

    /// The pauser sets and clears each flag in the same block, with no delay, and each flag moves
    /// alone.
    function test_proof3_thePauserSetsAndClearsEachFlagAtOnce() public {
        IPauseGuard.Flag[3] memory f = _flags();
        for (uint256 i; i < f.length; i++) {
            vm.expectEmit(true, false, false, true, address(guard));
            emit IPauseGuard.PauseSet(f[i], true);
            vm.prank(pauser);
            guard.setPaused(f[i], true);
            for (uint256 j; j < f.length; j++) {
                assertEq(guard.paused(f[j]), i == j, "only the flag set is on");
            }
            vm.prank(pauser);
            guard.setPaused(f[i], false);
            assertFalse(guard.paused(f[i]));
        }
    }

    /// Nobody else pauses: not a stranger, not the timelock that owns the guard, and not the
    /// owner key acting directly.
    function test_proof3_anyoneElseReverts() public {
        address[3] memory others = [stranger, address(lock), owner];
        IPauseGuard.Flag[3] memory f = _flags();
        for (uint256 i; i < others.length; i++) {
            for (uint256 j; j < f.length; j++) {
                vm.prank(others[i]);
                vm.expectRevert(IPauseGuard.NotPauser.selector);
                guard.setPaused(f[j], true);
                vm.prank(others[i]);
                vm.expectRevert(IPauseGuard.NotPauser.selector);
                guard.setPaused(f[j], false);
            }
        }
    }

    /// The pauser cannot name a successor, and neither can anyone but the timelock.
    function test_proof3_onlyTheTimelockRotatesThePauser() public {
        address[3] memory others = [pauser, stranger, owner];
        for (uint256 i; i < others.length; i++) {
            vm.prank(others[i]);
            vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, others[i]));
            guard.setPauser(stranger);
        }
        assertEq(guard.pauser(), pauser);
    }

    /// A rotation proposed through the timelock is refused a second before the delay and works at
    /// it. The old key loses the power and the new one has it.
    function test_proof3_aRotationWorksAfterTheDelayAndIsRefusedBefore() public {
        address next = makeAddr("next pauser");
        bytes memory data = abi.encodeCall(guard.setPauser, (next));
        vm.prank(owner);
        lock.schedule(address(guard), 0, data, bytes32(0), bytes32(0), DELAY);

        vm.warp(block.timestamp + DELAY - 1);
        vm.prank(owner);
        vm.expectRevert(); // not ready
        lock.execute(address(guard), 0, data, bytes32(0), bytes32(0));
        assertEq(guard.pauser(), pauser);

        vm.warp(block.timestamp + 1);
        vm.expectEmit(true, true, false, false, address(guard));
        emit IPauseGuard.PauserSet(pauser, next);
        vm.prank(owner);
        lock.execute(address(guard), 0, data, bytes32(0), bytes32(0));
        assertEq(guard.pauser(), next);

        vm.prank(pauser);
        vm.expectRevert(IPauseGuard.NotPauser.selector);
        guard.setPaused(IPauseGuard.Flag.DEPOSITS, true);
        vm.prank(next);
        guard.setPaused(IPauseGuard.Flag.DEPOSITS, true);
        assertTrue(guard.paused(IPauseGuard.Flag.DEPOSITS));
    }

    /// A zero pauser would leave nobody able to pause, so both doors refuse it.
    function test_aZeroPauserIsRefusedAtConstruction() public {
        vm.expectRevert(IPauseGuard.ZeroAddress.selector);
        new PauseGuard(address(this), address(0));
    }

    function test_aZeroPauserIsRefusedAtRotation() public {
        bytes memory data = abi.encodeCall(guard.setPauser, (address(0)));
        vm.prank(owner);
        lock.schedule(address(guard), 0, data, bytes32(0), bytes32(0), DELAY);
        vm.warp(block.timestamp + DELAY);
        vm.prank(owner);
        vm.expectRevert(IPauseGuard.ZeroAddress.selector);
        lock.execute(address(guard), 0, data, bytes32(0), bytes32(0));
    }
}
