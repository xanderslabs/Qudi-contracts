// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {ManualStrategy} from "../src/ManualStrategy.sol";
import {MockUSDC} from "./mocks/MockUSDC.sol";

contract ManualStrategyTest is Test {
    MockUSDC usdc;
    ManualStrategy venue;
    address owner = address(0xA11CE);
    address depositor = address(0xD0);

    function setUp() public {
        usdc = new MockUSDC();
        venue = new ManualStrategy(usdc, owner, "Manual USDC", "mUSDC");
        usdc.mint(depositor, 1_000e6);
        usdc.mint(owner, 1_000e6);
        vm.prank(depositor);
        usdc.approve(address(venue), type(uint256).max);
        vm.prank(owner);
        usdc.approve(address(venue), type(uint256).max);
    }

    function test_fund_raisesSharePrice() public {
        vm.prank(depositor);
        uint256 shares = venue.deposit(1_000e6, depositor);
        vm.prank(owner);
        venue.fund(100e6);
        assertApproxEqAbs(venue.convertToAssets(shares), 1_100e6, 1);
    }

    function test_skim_lowersSharePrice() public {
        vm.prank(depositor);
        uint256 shares = venue.deposit(1_000e6, depositor);
        vm.prank(owner);
        venue.skim(50e6);
        assertEq(venue.convertToAssets(shares), 950e6);
    }

    function test_fund_onlyOwner() public {
        vm.expectRevert();
        vm.prank(depositor);
        venue.fund(1e6);
    }

    function test_redeemDelay_default0() public view {
        assertEq(venue.redeemDelay(), 0);
    }
}
