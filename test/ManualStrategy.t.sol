// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.30;

import {Ownable} from "openzeppelin-contracts/contracts/access/Ownable.sol";
import {ManualStrategy} from "../src/ManualStrategy.sol";
import {IStrategy} from "../src/interfaces/IStrategy.sol";
import {IConfig} from "../src/interfaces/IConfig.sol";
import {ConfigKeys as K} from "../src/ConfigKeys.sol";
import {VenueFixture} from "./helpers/VenueFixture.sol";

/// Qudi's own strategy. Its yield is paid in ahead of time and released by the second, so the
/// value it reports never rests on money that has not been paid in. Money sent out to a listed
/// destination keeps its value until a loss is reported.
///
/// Most proofs here stand the test contract in for the Venue, so the strategy is driven directly;
/// the last ones put it under a real `Venue` to show the price following it.
contract ManualStrategyTest is VenueFixture {
    ManualStrategy ms;
    address operator = address(0x0FE);
    address dest = address(0xDE57);
    address other = address(0x07E4);

    uint256 constant PRINCIPAL = 1_000e6;
    uint16 constant RATE = 1000; // 10% a year

    function setUp() public {
        setUpVenue();
        // The test contract is this strategy's Venue.
        ms = new ManualStrategy(usdc, IConfig(address(config)), address(this), owner, operator);
        usdc.approve(address(ms), type(uint256).max);
        usdc.mint(operator, 1_000_000e6);
        vm.prank(operator);
        usdc.approve(address(ms), type(uint256).max);
        vm.prank(owner);
        ms.addDestination(dest);
        ms.deposit(PRINCIPAL);
    }

    function _released(uint256 principal, uint16 rate, uint256 elapsed) internal pure returns (uint256) {
        return principal * rate * elapsed / (10_000 * 365 days);
    }

    function _fund(uint256 amount) internal {
        vm.prank(operator);
        ms.fundYield(amount);
    }

    function _rate(uint16 bps) internal {
        vm.prank(operator);
        ms.setRate(bps);
    }

    function _deploy(uint256 amount) internal {
        vm.prank(operator);
        ms.deploy(amount, dest, bytes32("invoice-1"));
    }

    // ---- 3. pre-funded yield ----

    /// Released yield grows as `rate * t * principal` until it reaches the buffer, then stops.
    function test_proof3_yieldIsReleasedByTheSecondUntilTheBufferRunsOut() public {
        uint256 buffer = 10e6;
        _fund(buffer);
        _rate(RATE);
        assertEq(ms.totalAssets(), PRINCIPAL, "funding the buffer adds nothing by itself");

        vm.warp(block.timestamp + 10 days);
        assertEq(ms.totalAssets(), PRINCIPAL + _released(PRINCIPAL, RATE, 10 days), "ten days' yield");

        // 10 USDC at 100 USDC a year runs out after 36.5 days.
        vm.warp(block.timestamp + 26.5 days);
        assertEq(ms.totalAssets(), PRINCIPAL + buffer, "the whole buffer, exactly");

        vm.warp(block.timestamp + 100 days);
        assertEq(ms.totalAssets(), PRINCIPAL + buffer, "and no more: yield pauses when the buffer is dry");
        assertEq(ms.buffer(), 0);
    }

    /// No rate, no yield; a rate with no buffer, no yield either. Value never rests on money that
    /// was not paid in.
    function test_proof3_aRateWithNoBufferReleasesNothing() public {
        _rate(RATE);
        vm.warp(block.timestamp + 365 days);
        assertEq(ms.totalAssets(), PRINCIPAL);
    }

    /// The Venue can take principal and released yield, never the buffer still waiting.
    function test_proof3_unreleasedBufferCannotBeWithdrawnByTheVenue() public {
        _fund(10e6);
        _rate(RATE);
        vm.warp(block.timestamp + 10 days);
        uint256 max = ms.maxWithdraw();
        assertEq(max, PRINCIPAL + _released(PRINCIPAL, RATE, 10 days));

        vm.expectRevert(ManualStrategy.ExceedsCash.selector);
        ms.withdraw(max + 1, address(this));

        ms.withdraw(max, address(this));
        assertEq(ms.totalAssets(), 0, "the Venue's whole position is out");
        assertEq(usdc.balanceOf(address(ms)), ms.buffer(), "what stays behind is the unreleased buffer");
        assertGt(ms.buffer(), 0);
    }

    function test_proof3_onlyTheVenueMovesMoneyInAndOut() public {
        vm.expectRevert(IStrategy.NotVenue.selector);
        vm.prank(stranger);
        ms.deposit(1);

        vm.expectRevert(IStrategy.NotVenue.selector);
        vm.prank(operator);
        ms.withdraw(1, operator);
    }

    function test_proof3_onlyTheOperatorFundsYield() public {
        vm.expectRevert(ManualStrategy.NotOperator.selector);
        vm.prank(stranger);
        ms.fundYield(1);
    }

    // ---- 4. setRate ----

    /// A rate change applies from the moment it is made. What was released before it is booked
    /// and does not change.
    function test_proof4_aRateChangeDoesNotRecomputeThePast() public {
        _fund(100e6);
        _rate(RATE);
        vm.warp(block.timestamp + 10 days);
        uint256 before = ms.totalAssets();
        assertEq(before, PRINCIPAL + _released(PRINCIPAL, RATE, 10 days));

        _rate(2 * RATE);
        assertEq(ms.totalAssets(), before, "setting the rate moves nothing");

        vm.warp(block.timestamp + 10 days);
        assertEq(
            ms.totalAssets(),
            before + _released(PRINCIPAL, 2 * RATE, 10 days),
            "the next ten days at the new rate, on principal only"
        );
    }

    function test_proof4_theRateIsBoundedByConfigAndOperatorOnly() public {
        uint256 ceiling = config.manualRateCeilingBps();
        vm.expectRevert(ManualStrategy.RateAboveCeiling.selector);
        vm.prank(operator);
        ms.setRate(uint16(ceiling + 1));

        _rate(uint16(ceiling));
        assertEq(ms.rateBps(), ceiling);

        vm.expectRevert(ManualStrategy.NotOperator.selector);
        vm.prank(owner);
        ms.setRate(1);

        vm.prank(owner);
        config.set(K.MANUAL_RATE_CEILING_BPS, 100);
        vm.expectRevert(ManualStrategy.RateAboveCeiling.selector);
        vm.prank(operator);
        ms.setRate(101);
    }

    // ---- 5. deploy and destinations ----

    function test_proof5_deployGoesToAListedDestinationAndKeepsTheValue() public {
        vm.expectEmit(true, false, false, true, address(ms));
        emit ManualStrategy.Deployed(dest, 400e6, bytes32("invoice-1"));
        _deploy(400e6);
        assertEq(usdc.balanceOf(dest), 400e6, "the money went to the destination");
        assertEq(ms.totalAssets(), PRINCIPAL, "and is still counted");
        assertEq(ms.principalDeployed(), 400e6);
        assertEq(ms.principalHeld(), 600e6);
        assertEq(ms.maxWithdraw(), 600e6, "deployed money is not withdrawable until it comes back");
    }

    function test_proof5_aNonOperatorCannotDeploy() public {
        vm.expectRevert(ManualStrategy.NotOperator.selector);
        vm.prank(owner);
        ms.deploy(1, dest, bytes32(0));
    }

    function test_proof5_anUnlistedDestinationReverts() public {
        vm.expectRevert(ManualStrategy.UnlistedDestination.selector);
        vm.prank(operator);
        ms.deploy(1, other, bytes32(0));

        vm.prank(owner);
        ms.removeDestination(dest);
        vm.expectRevert(ManualStrategy.UnlistedDestination.selector);
        _deploy(1);
    }

    /// Only principal cash goes out, never the yield buffer.
    function test_proof5_deployCannotSendTheBuffer() public {
        _fund(50e6);
        vm.expectRevert(ManualStrategy.ExceedsCash.selector);
        _deploy(PRINCIPAL + 1);
    }

    function test_proof5_onlyTheOwnerListsDestinationsAndSetsTheOperator() public {
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, operator));
        vm.prank(operator);
        ms.addDestination(other);

        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, operator));
        vm.prank(operator);
        ms.removeDestination(dest);

        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, operator));
        vm.prank(operator);
        ms.setOperator(operator);

        vm.prank(owner);
        ms.setOperator(other);
        vm.expectRevert(ManualStrategy.NotOperator.selector);
        _deploy(1);
    }

    // ---- 6. returnFrom ----

    /// Up to what is deployed, returned money is principal coming home. Above it, it is yield,
    /// and it goes into the buffer to be released at the rate like any other.
    function test_proof6_returnFromLowersDeployedAndTheExcessGoesToTheBuffer() public {
        _deploy(400e6);
        vm.prank(operator);
        ms.returnFrom(300e6);
        assertEq(ms.principalDeployed(), 100e6);
        assertEq(ms.principalHeld(), 900e6);
        assertEq(ms.buffer(), 0);
        assertEq(ms.totalAssets(), PRINCIPAL, "principal coming home changes no value");

        vm.prank(operator);
        ms.returnFrom(150e6);
        assertEq(ms.principalDeployed(), 0);
        assertEq(ms.principalHeld(), PRINCIPAL);
        assertEq(ms.buffer(), 50e6, "the 50 above what was deployed is yield");
        assertEq(ms.totalAssets(), PRINCIPAL, "and it is not value until it is released");
    }

    function test_proof6_onlyTheOperatorReturnsMoney() public {
        vm.expectRevert(ManualStrategy.NotOperator.selector);
        vm.prank(stranger);
        ms.returnFrom(1);
    }

    // ---- 7. reportLoss ----

    function test_proof7_reportLossLowersValueByExactlyTheAmount() public {
        _deploy(400e6);
        vm.expectEmit(false, false, false, true, address(ms));
        emit ManualStrategy.LossReported(150e6, "borrower default");
        vm.prank(operator);
        ms.reportLoss(150e6, "borrower default");
        assertEq(ms.totalAssets(), PRINCIPAL - 150e6);
        assertEq(ms.principalDeployed(), 250e6);
        assertEq(ms.principalHeld(), 600e6, "cash held is untouched");
    }

    function test_proof7_aLossCannotExceedWhatIsDeployed() public {
        _deploy(400e6);
        vm.expectRevert(ManualStrategy.ExceedsDeployed.selector);
        vm.prank(operator);
        ms.reportLoss(400e6 + 1, "");
    }

    function test_proof7_onlyTheOperatorReportsALoss() public {
        _deploy(400e6);
        vm.expectRevert(ManualStrategy.NotOperator.selector);
        vm.prank(owner);
        ms.reportLoss(1, "");
    }
}

/// `ManualStrategy` under a real `Venue`: the Venue's price follows it.
contract ManualStrategyUnderVenueTest is VenueFixture {
    ManualStrategy ms;
    address operator = address(0x0FE);
    address dest = address(0xDE57);

    function setUp() public {
        setUpVenue();
        ms = new ManualStrategy(usdc, IConfig(address(config)), address(vault), owner, operator);
        vm.startPrank(owner);
        vault.addStrategy(address(ms), 0);
        vault.setCap(address(ms), type(uint256).max);
        ms.addDestination(dest);
        vm.stopPrank();
        _weigh(address(ms), 10_000, address(0), 0);
        usdc.mint(operator, 1_000_000e6);
        vm.prank(operator);
        usdc.approve(address(ms), type(uint256).max);
        _deposit(1_000e6);
        vault.rebalance();
    }

    /// A reported loss reaches the Venue's price in the same block.
    function test_proof7_theVenuePriceReflectsAReportedLossAtOnce() public {
        vm.prank(operator);
        ms.deploy(500e6, dest, bytes32(0));
        assertEq(vault.totalAssets(), 1_000e6, "deploying moves no value");

        uint256 priceBefore = _price();
        vm.prank(operator);
        ms.reportLoss(100e6, "write-off");
        assertEq(vault.totalAssets(), 900e6, "the loss is in the Venue's total in the same block");
        assertLt(_price(), priceBefore);
    }

    /// The strategy's rate is capped again by the Venue's `maxRate`.
    function test_proof4_theVenueMaxRateCapsTheStrategyRate() public {
        _setMaxRate(300);
        vm.startPrank(operator);
        ms.fundYield(100e6);
        ms.setRate(2000);
        vm.stopPrank();
        vm.warp(block.timestamp + 30 days);
        uint256 principal = 1_000e6;
        assertEq(ms.totalAssets(), principal + principal * 2000 * 30 days / (10_000 * 365 days));
        assertEq(vault.totalAssets(), principal + principal * 300 * 30 days / (10_000 * 365 days));
    }
}
