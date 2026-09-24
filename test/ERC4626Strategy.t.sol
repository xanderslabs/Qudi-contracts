// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {IERC4626} from "openzeppelin-contracts/contracts/interfaces/IERC4626.sol";
import {ERC4626Strategy} from "../src/ERC4626Strategy.sol";
import {IStrategy} from "../src/interfaces/IStrategy.sol";
import {MockUSDC} from "./mocks/MockUSDC.sol";
import {MockVenue} from "./mocks/MockVenue.sol";

/// The generic adapter proves the strategy interface: any ERC-4626 vault on the same asset plugs
/// in with no code of its own. The test contract stands in for the Venue.
contract ERC4626StrategyTest is Test {
    MockUSDC usdc;
    MockVenue target;
    ERC4626Strategy strat;
    address stranger = address(0xBAD);
    address receiver = address(0x2EC);

    function setUp() public {
        usdc = new MockUSDC();
        target = new MockVenue(usdc, "Target", "T");
        strat = new ERC4626Strategy(IERC4626(address(target)), address(this));
        usdc.mint(address(this), 1_000_000e6);
        usdc.approve(address(strat), type(uint256).max);
        usdc.approve(address(target), type(uint256).max);
    }

    function test_proof10_depositAndWithdrawRoundTrip() public {
        assertEq(strat.asset(), address(usdc));
        strat.deposit(1_000e6);
        assertEq(usdc.balanceOf(address(target)), 1_000e6, "the money went straight to the target");
        assertEq(usdc.balanceOf(address(strat)), 0, "and the adapter holds none of it");
        assertEq(strat.totalAssets(), 1_000e6);
        assertEq(strat.maxWithdraw(), 1_000e6);

        strat.withdraw(400e6, receiver);
        assertEq(usdc.balanceOf(receiver), 400e6);
        assertEq(strat.totalAssets(), 600e6);

        strat.withdraw(strat.maxWithdraw(), receiver);
        assertEq(usdc.balanceOf(receiver), 1_000e6, "everything that went in came back");
    }

    /// The adapter's value is its shares at the target's own share price, up and down.
    function test_proof10_valueFollowsTheTargetSharePrice() public {
        strat.deposit(1_000e6);
        target.fund(100e6); // the target's price rises 10%
        assertApproxEqAbs(strat.totalAssets(), 1_100e6, 1);
        assertEq(strat.totalAssets(), target.convertToAssets(target.balanceOf(address(strat))));
        assertEq(strat.maxWithdraw(), target.maxWithdraw(address(strat)));

        target.skim(550e6); // and halves
        assertApproxEqAbs(strat.totalAssets(), 550e6, 1);
    }

    function test_proof10_onlyTheVenueMovesMoney() public {
        vm.expectRevert(IStrategy.NotVenue.selector);
        vm.prank(stranger);
        strat.deposit(1);

        strat.deposit(10e6);
        vm.expectRevert(IStrategy.NotVenue.selector);
        vm.prank(stranger);
        strat.withdraw(1, stranger);
    }

    function test_proof10_aZeroVenueIsRefused() public {
        vm.expectRevert(ERC4626Strategy.ZeroAddress.selector);
        new ERC4626Strategy(IERC4626(address(target)), address(0));
    }
}
