// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {TimelockController} from "openzeppelin-contracts/contracts/governance/TimelockController.sol";
import {Config} from "../src/Config.sol";
import {ConfigKeys as K} from "../src/ConfigKeys.sol";

/// The parameter setters are Risk-Committee-gated with a 48-hour delay. The delay and
/// the 3-of-5 threshold live in an external TimelockController that owns the config, not in
/// per-key queue state here (non-upgradeable posture, no proxy). This proves the
/// unchanged bytecode works behind that holder. On testnet the timelock's single
/// proposer/executor is the dev key; the threshold is a property of the multisig
/// wired later.
contract ConfigTimelockTest is Test {
    Config cfg;
    TimelockController lock;
    address riskCommittee;
    address guardian;

    uint256 constant DELAY = 48 hours;

    function setUp() public {
        riskCommittee = makeAddr("riskCommittee");
        guardian = makeAddr("guardian");
        address[] memory ops = new address[](1);
        ops[0] = riskCommittee;
        lock = new TimelockController(DELAY, ops, ops, address(0));
        vm.startPrank(riskCommittee);
        cfg = new Config(makeAddr("usdc"), makeAddr("treasury"), makeAddr("complianceRegistry"));
        cfg.transferOwnership(address(lock));
        vm.stopPrank();
        _viaLock(abi.encodeCall(cfg.acceptOwnership, ()));
        assertEq(cfg.owner(), address(lock));
    }

    function _viaLock(bytes memory data) internal {
        vm.prank(riskCommittee);
        lock.schedule(address(cfg), 0, data, bytes32(0), bytes32(0), DELAY);
        vm.warp(block.timestamp + DELAY);
        vm.prank(riskCommittee);
        lock.execute(address(cfg), 0, data, bytes32(0), bytes32(0));
    }

    /// Test 8: the 48-hour delay is enforced, not merely stored. A change applied
    /// before 48h reverts; after it, it succeeds.
    function test_parameterChangeWaits48Hours() public {
        bytes memory data = abi.encodeCall(cfg.set, (K.SEAT_PRICE_FLOOR, 60e6));
        vm.prank(riskCommittee);
        lock.schedule(address(cfg), 0, data, bytes32(0), bytes32(0), DELAY);

        vm.warp(block.timestamp + DELAY - 1);
        vm.prank(riskCommittee);
        vm.expectRevert(); // TimelockUnexpectedOperationState: not ready
        lock.execute(address(cfg), 0, data, bytes32(0), bytes32(0));
        assertEq(cfg.seatPriceFloor(), 50e6);

        vm.warp(block.timestamp + 1);
        vm.prank(riskCommittee);
        lock.execute(address(cfg), 0, data, bytes32(0), bytes32(0));
        assertEq(cfg.seatPriceFloor(), 60e6);
    }

    /// Test 7: no caller other than the Risk Committee (through the lock) can set a
    /// parameter. The Emergency Guardian in particular cannot: it holds no role on this
    /// contract at all.
    function test_onlyRiskCommitteeThroughLockCanSet() public {
        vm.prank(riskCommittee);
        vm.expectRevert();
        cfg.set(K.SEAT_PRICE_FLOOR, 60e6); // RC signer cannot bypass the lock

        vm.prank(guardian);
        vm.expectRevert();
        cfg.set(K.SEAT_PRICE_FLOOR, 60e6); // guardian has nothing

        vm.prank(guardian);
        vm.expectRevert();
        cfg.setStageBoundaries(60 days, 65 days, 95 days, 155 days, 365 days);
    }

    function test_lockCannotScheduleBelowDelay() public {
        bytes memory data = abi.encodeCall(cfg.set, (K.SEAT_PRICE_FLOOR, 60e6));
        vm.prank(riskCommittee);
        vm.expectRevert(); // TimelockInsufficientDelay
        lock.schedule(address(cfg), 0, data, bytes32(0), bytes32(0), 1 days);
    }

    /// The composite setters run through the same gate.
    function test_stageBoundariesThroughLock() public {
        _viaLock(abi.encodeCall(cfg.setStageBoundaries, (50 days, 55 days, 80 days, 140 days, 300 days)));
        (uint64 g,,,, uint64 wo) = cfg.stageBoundaries();
        assertEq(g, 50 days);
        assertEq(wo, 300 days);
    }
}
