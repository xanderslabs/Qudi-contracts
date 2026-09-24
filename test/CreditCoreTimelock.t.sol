// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {TimelockController} from "openzeppelin-contracts/contracts/governance/TimelockController.sol";
import {CreditCore} from "../src/CreditCore.sol";
import {CreditStanding} from "../src/CreditStanding.sol";
import {ICreditCore} from "../src/interfaces/ICreditCore.sol";
import {Config} from "../src/Config.sol";
import {ConfigKeys as K} from "../src/ConfigKeys.sol";
import {IConfig} from "../src/interfaces/IConfig.sol";
import {MockUSDC} from "./mocks/MockUSDC.sol";
import {MockVenue} from "./mocks/MockVenue.sol";
import {CreditCoreHarness} from "./helpers/CreditCoreHarness.sol";
import {MockCommunityFactory} from "./helpers/MockCommunityFactory.sol";

/// The Community Allocation Multisig carries a 24-hour delay and the Risk Committee a
/// 48-hour delay. Both live in external TimelockControllers, matching the config pattern.
/// On testnet the single proposer/executor is the dev key.
contract CreditCoreTimelockTest is Test {
    MockUSDC usdc;
    Config config;
    MockCommunityFactory factory;
    CreditCoreHarness cc;
    TimelockController allocationLock; // 24h, is the allocationMultisig
    TimelockController riskCommittee; // 48h, owns Config

    address dev = makeAddr("dev");
    address governance = makeAddr("governance");
    address treasuryMgr = makeAddr("treasuryManager");

    uint256 constant ALLOC_DELAY = 24 hours;
    uint256 constant RC_DELAY = 48 hours;
    uint256 constant BASE_REQUIRED = 110_000e6;

    function setUp() public {
        usdc = new MockUSDC();
        factory = new MockCommunityFactory();
        factory.setCommunityCount(1);

        address[] memory ops = new address[](1);
        ops[0] = dev;
        allocationLock = new TimelockController(ALLOC_DELAY, ops, ops, address(0));
        riskCommittee = new TimelockController(RC_DELAY, ops, ops, address(0));

        vm.prank(dev);
        config = new Config(address(usdc), makeAddr("treasury"), makeAddr("registry"));
        vm.prank(dev);
        config.transferOwnership(address(riskCommittee));
        _viaLock(riskCommittee, RC_DELAY, address(config), abi.encodeCall(config.acceptOwnership, ()));

        CreditStanding standing = new CreditStanding(IConfig(address(config)), address(factory), governance);
        cc = new CreditCoreHarness(
            IERC20(address(usdc)),
            IConfig(address(config)),
            address(factory),
            governance,
            treasuryMgr,
            address(allocationLock),
            standing
        );
        vm.prank(governance);
        standing.setCreditCore(address(cc));

        usdc.mint(governance, BASE_REQUIRED + 100_000e6);
        vm.startPrank(governance);
        usdc.approve(address(cc), type(uint256).max);
        cc.fund(BASE_REQUIRED + 100_000e6);
        vm.stopPrank();
    }

    function _viaLock(TimelockController lock, uint256 delay, address target, bytes memory data) internal {
        vm.prank(dev);
        lock.schedule(target, 0, data, bytes32(0), bytes32(0), delay);
        vm.warp(block.timestamp + delay);
        vm.prank(dev);
        lock.execute(target, 0, data, bytes32(0), bytes32(0));
    }

    // -----------------------------------------------------------------
    // Test 12: the Allocation Multisig's 24-hour delay is enforced, not merely stored
    // -----------------------------------------------------------------

    function test_allocation24hDelayEnforced() public {
        bytes memory data = abi.encodeCall(cc.allocate, (0, 10_000e6, ICreditCore.AllocationType.Growth));

        vm.prank(dev);
        allocationLock.schedule(address(cc), 0, data, bytes32(0), bytes32(0), ALLOC_DELAY);

        // one second short of 24h: not executable
        vm.warp(block.timestamp + ALLOC_DELAY - 1);
        vm.prank(dev);
        vm.expectRevert();
        allocationLock.execute(address(cc), 0, data, bytes32(0), bytes32(0));
        assertEq(cc.totalAllocated(), 0);

        // at 24h: executes
        vm.warp(block.timestamp + 1);
        vm.prank(dev);
        allocationLock.execute(address(cc), 0, data, bytes32(0), bytes32(0));
        assertEq(cc.allocationOf(0), 10_000e6);
    }

    function test_allocationLockCannotScheduleBelowDelay() public {
        bytes memory data = abi.encodeCall(cc.allocate, (0, 1e6, ICreditCore.AllocationType.Growth));
        vm.prank(dev);
        vm.expectRevert(); // TimelockInsufficientDelay
        allocationLock.schedule(address(cc), 0, data, bytes32(0), bytes32(0), 1 hours);
    }

    function test_directAllocateBypassingTheLockReverts() public {
        vm.prank(dev); // a lock signer, but not the lock itself
        vm.expectRevert(ICreditCore.NotAllocationMultisig.selector);
        cc.allocate(0, 1e6, ICreditCore.AllocationType.Growth);
    }

    // -----------------------------------------------------------------
    // Venue listing carries the Risk Committee's 48-hour delay; removal is immediate
    // -----------------------------------------------------------------

    function test_addVenueEnforcesThe48hDelay() public {
        MockVenue venue = new MockVenue(IERC20(address(usdc)), "V", "V"); // redeemDelay() == 0
        bytes memory data = abi.encodeCall(cc.addVenue, (address(venue)));

        // a direct call, even by a lock signer, is not the Risk Committee
        vm.prank(dev);
        vm.expectRevert(ICreditCore.NotRiskCommittee.selector);
        cc.addVenue(address(venue));

        vm.prank(dev);
        riskCommittee.schedule(address(cc), 0, data, bytes32(0), bytes32(0), RC_DELAY);

        // one second short of 48h: not executable
        vm.warp(block.timestamp + RC_DELAY - 1);
        vm.prank(dev);
        vm.expectRevert();
        riskCommittee.execute(address(cc), 0, data, bytes32(0), bytes32(0));
        assertFalse(cc.isVenue(address(venue)));

        // at 48h: lists
        vm.warp(block.timestamp + 1);
        vm.prank(dev);
        riskCommittee.execute(address(cc), 0, data, bytes32(0), bytes32(0));
        assertTrue(cc.isVenue(address(venue)));

        // removal is immediate, by the CreditCore owner (governance), no schedule
        vm.prank(governance);
        cc.removeVenue(address(venue));
        assertFalse(cc.isVenue(address(venue)));
    }

    function test_riskCommitteeCannotScheduleAddVenueBelowDelay() public {
        MockVenue venue = new MockVenue(IERC20(address(usdc)), "V", "V");
        bytes memory data = abi.encodeCall(cc.addVenue, (address(venue)));
        vm.prank(dev);
        vm.expectRevert(); // TimelockInsufficientDelay
        riskCommittee.schedule(address(cc), 0, data, bytes32(0), bytes32(0), 1 hours);
    }

    // -----------------------------------------------------------------
    // Test 5: the requirement recomputes when a Config parameter changes, and the
    // allocation gate moves with it
    // -----------------------------------------------------------------

    function test_requirementTracksAConfigChangeThroughTheTimelock() public {
        assertEq(cc.requiredRetainedCapital(), BASE_REQUIRED);

        // raise the global operating floor from $10,000 to $30,000 through the 48h timelock
        _viaLock(
            riskCommittee, RC_DELAY, address(config), abi.encodeCall(config.set, (K.OPERATING_FLOOR_GLOBAL, 30_000e6))
        );

        assertEq(cc.requiredRetainedCapital(), BASE_REQUIRED + 20_000e6);

        // the allocate boundary has moved by the same 20,000e6
        uint256 headroom = cc.unallocated() - cc.requiredRetainedCapital();
        vm.prank(dev);
        bytes memory over = abi.encodeCall(cc.allocate, (0, headroom + 1, ICreditCore.AllocationType.Growth));
        allocationLock.schedule(address(cc), 0, over, bytes32(0), bytes32(0), ALLOC_DELAY);
        vm.warp(block.timestamp + ALLOC_DELAY);
        vm.prank(dev);
        vm.expectRevert(); // TimelockController wraps the BelowRetainedCapital revert
        allocationLock.execute(address(cc), 0, over, bytes32(0), bytes32(0));

        bytes memory exact = abi.encodeCall(cc.allocate, (0, headroom, ICreditCore.AllocationType.Growth));
        vm.prank(dev);
        allocationLock.schedule(address(cc), 0, exact, bytes32(0), bytes32(0), ALLOC_DELAY);
        vm.warp(block.timestamp + ALLOC_DELAY);
        vm.prank(dev);
        allocationLock.execute(address(cc), 0, exact, bytes32(0), bytes32(0));
        assertEq(cc.surplus(), 0);
    }
}
