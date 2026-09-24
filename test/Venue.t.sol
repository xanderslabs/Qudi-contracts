// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.30;

import {Ownable} from "openzeppelin-contracts/contracts/access/Ownable.sol";
import {IVenue} from "../src/interfaces/IVenue.sol";
import {ConfigKeys as K} from "../src/ConfigKeys.sol";
import {MockUSDC} from "./mocks/MockUSDC.sol";
import {MockStrategy} from "./mocks/MockStrategy.sol";
import {VenueFixture} from "./helpers/VenueFixture.sol";

/// The parts of the Venue that did not change with the move to live value: who may deposit, the
/// deposit cap, the strategy list and weights, the instant and slow groups, `rebalance`, the
/// transfer restriction, and the guard against a price nobody can buy at.
contract VenueTest is VenueFixture {
    MockStrategy fast;
    MockStrategy slow;
    address ledger2 = address(0x2ED);

    function setUp() public {
        setUpVenue();
        factory.register(ledger2);
        fast = _addStrategy(0);
        slow = _addStrategy(2 days);
        _weigh(address(fast), 7500, address(slow), 2500);
        usdc.approve(address(vault), type(uint256).max);
    }

    // ---- deposits ----

    function test_deposit_onlyLedger() public {
        vm.expectRevert(IVenue.NotLedger.selector);
        vm.prank(stranger);
        vault.deposit(1e6, stranger);
    }

    function test_deposit_mintsSharesOneToOneIntoAnEmptyVenue() public {
        uint256 shares = _deposit(100e6);
        assertEq(shares, 100e6);
        assertEq(vault.balanceOf(ledger), 100e6);
        assertEq(vault.idle(), 100e6);
        assertEq(vault.totalAssets(), 100e6);
    }

    function test_deposit_capEnforced() public {
        vm.prank(owner);
        config.set(K.GLOBAL_DEPOSIT_CAP, 50e6);
        vm.expectRevert(IVenue.DepositCapExceeded.selector);
        vm.prank(ledger);
        vault.deposit(51e6, ledger);
    }

    /// A deposit that would mint no shares at the current price reverts rather than taking the
    /// depositor's money for nothing.
    function test_deposit_zeroShares_reverts() public {
        _deposit(1_000e6);
        vault.rebalance();
        fast.fund(100e6);
        vm.warp(block.timestamp + 365 days); // the price is now 1.1
        vm.expectRevert(IVenue.ZeroShares.selector);
        vm.prank(ledger);
        vault.deposit(1, ledger);
    }

    /// Money donated to an empty Venue is not in its price, so it cannot set a price the first
    /// depositor cannot buy at. The growth cap starts from zero and a zero base allows no growth.
    function test_deposit_aDonationToAnEmptyVenueCannotPriceOutTheFirstDepositor() public {
        usdc.transfer(address(vault), 1_000e6);
        assertEq(vault.totalAssets(), 0);
        vm.warp(block.timestamp + 365 days);
        assertEq(vault.totalAssets(), 0, "nothing grows from a zero base");
        uint256 shares = _deposit(100e6);
        assertEq(shares, 100e6, "the first depositor buys at one to one");
    }

    /// `fundReserve` mints straight through `_mint`, so it needs the guard `_deposit` has: it is
    /// the path a deployment seeds through, and a seed that bought nothing would hand the Venue
    /// free USDC.
    function test_fundReserve_zeroShares_reverts() public {
        _deposit(1_000e6);
        vault.rebalance();
        fast.fund(100e6);
        vm.warp(block.timestamp + 365 days);
        vm.expectRevert(IVenue.ZeroShares.selector);
        vault.fundReserve(1);
        vault.fundReserve(1_000e6);
        assertGt(vault.reserveShares(), 0);
    }

    /// Seeding the reserve buys shares at the price like any holder, so it moves no price.
    function test_fundReserve_movesNoPrice() public {
        _deposit(1_000e6);
        uint256 priceBefore = _price();
        vault.fundReserve(500e6);
        assertEq(_price(), priceBefore);
        assertEq(vault.totalAssets(), 1_500e6);
    }

    // ---- listing ----

    function test_addStrategy_filesTheGroupFromTheStatedDelay() public view {
        assertTrue(vault.isInstant(address(fast)));
        assertFalse(vault.isInstant(address(slow)));
        assertEq(vault.delayOf(address(slow)), 2 days);
        assertEq(vault.strategyCount(), 2);
        assertEq(vault.strategies(0), address(fast));
    }

    function test_addStrategy_ownerOnly() public {
        MockStrategy s = new MockStrategy(usdc, address(vault));
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger));
        vm.prank(stranger);
        vault.addStrategy(address(s), 0);
    }

    function test_addStrategy_refusesADuplicateAWrongAssetAndALongDelay() public {
        vm.expectRevert(IVenue.DuplicateStrategy.selector);
        vm.prank(owner);
        vault.addStrategy(address(fast), 0);

        MockStrategy wrong = new MockStrategy(new MockUSDC(), address(vault));
        vm.expectRevert(IVenue.UnknownStrategy.selector);
        vm.prank(owner);
        vault.addStrategy(address(wrong), 0);

        MockStrategy late = new MockStrategy(usdc, address(vault));
        uint64 max = config.maxNoticePeriod();
        vm.expectRevert(IVenue.NoticePeriodTooLong.selector);
        vm.prank(owner);
        vault.addStrategy(address(late), max + 1);
    }

    function test_removeStrategy_bringsTheMoneyHomeAndDelists() public {
        _deposit(1_000e6);
        vault.rebalance();
        vm.prank(owner);
        vault.removeStrategy(address(slow));
        assertFalse(vault.isStrategy(address(slow)));
        assertEq(vault.strategyCount(), 1);
        assertEq(vault.weightBps(address(slow)), 0);
        assertEq(vault.capOf(address(slow)), 0);
        assertEq(slow.totalAssets(), 0);
        assertEq(vault.idle(), 250e6);
        assertEq(vault.totalAssets(), 1_000e6, "removal moves no value");
    }

    /// A strategy still holding money the Venue cannot take out now is not removed, because
    /// removing it would drop that money out of the Venue's value.
    function test_removeStrategy_refusesAStrategyThatCannotEmpty() public {
        _deposit(1_000e6);
        vault.rebalance();
        slow.setWithdrawCap(100e6);
        vm.expectRevert(IVenue.StrategyNotEmpty.selector);
        vm.prank(owner);
        vault.removeStrategy(address(slow));
    }

    function test_removeStrategy_unlistedReverts() public {
        vm.expectRevert(IVenue.UnknownStrategy.selector);
        vm.prank(owner);
        vault.removeStrategy(stranger);
    }

    // ---- weights and groups ----

    function test_setWeights_rejectsSlowAboveCeiling() public {
        vm.expectRevert(IVenue.TierLimitBreached.selector);
        _weigh(address(fast), 5000, address(slow), 5000);
    }

    /// The instant-group floor binds, not only the slow-group ceiling. At the launch values the
    /// ceiling fires first for any breach, so the floor is reached by raising the ceiling.
    function test_setWeights_theInstantFloorBinds() public {
        vm.prank(owner);
        config.set(K.SLOW_TIER_CEILING_BPS, 10_000);
        vm.expectRevert(IVenue.TierLimitBreached.selector);
        _weigh(address(slow), 8000, address(fast), 2000);
        _weigh(address(slow), 7500, address(fast), 2500);
        assertEq(vault.weightBps(address(slow)), 7500);
    }

    function test_setWeights_mustNotSumAboveTheWhole() public {
        vm.expectRevert(IVenue.WeightsMustSum.selector);
        _weigh(address(fast), 9000, address(slow), 2000);
    }

    // ---- rebalance ----

    function test_rebalance_movesTowardWeights() public {
        _deposit(1_000e6);
        vault.rebalance();
        assertEq(fast.totalAssets(), 750e6);
        assertEq(slow.totalAssets(), 250e6);
        assertEq(vault.idle(), 0);
        assertEq(vault.totalAssets(), 1_000e6);
    }

    /// A strategy that will not give back everything it is over target by is asked for what it
    /// will give, and the rebalance completes.
    function test_rebalance_asksAStrategyOnlyForWhatItWillGive() public {
        _deposit(10_000e6);
        vault.rebalance();
        _weigh(address(fast), 10_000, address(slow), 0);
        slow.setWithdrawCap(100e6);
        vault.rebalance();
        assertEq(slow.totalAssets(), 2_500e6 - 100e6);
    }

    /// A strategy still above its target, because it will not give money back, is left alone by
    /// the allocation pass rather than being topped up toward a target it already exceeds.
    function test_rebalance_leavesAStrategyAboveItsTargetAlone() public {
        _weigh(address(fast), 7500, address(slow), 0);
        _deposit(10_000e6);
        vault.rebalance();
        assertEq(fast.totalAssets(), 7_500e6);
        fast.setWithdrawCap(0);
        _weigh(address(fast), 5000, address(slow), 2500);
        vault.rebalance();
        assertEq(fast.totalAssets(), 7_500e6, "it could not shed, and nothing was added");
        assertEq(slow.totalAssets(), 2_500e6);
    }

    /// A rebalance allocates only what is idle. Here the slow strategy will not shed its
    /// position, so the fast one's new target is more than the cash there is.
    function test_rebalance_allocatesOnlyWhatIsIdle() public {
        _deposit(10_000e6);
        vault.rebalance();
        slow.setWithdrawCap(0);
        _weigh(address(fast), 10_000, address(slow), 0);
        vault.rebalance();
        assertEq(vault.idle(), 0);
        assertEq(fast.totalAssets(), 7_500e6, "nothing was conjured for the fast strategy");
        assertEq(slow.totalAssets(), 2_500e6);
    }

    /// Weights under the whole leave the rest idle, which is how a venue keeps a cash buffer.
    function test_rebalance_weightsUnderTheWholeLeaveCashIdle() public {
        _weigh(address(fast), 6000, address(slow), 2500);
        _deposit(1_000e6);
        vault.rebalance();
        assertEq(vault.idle(), 150e6);
    }

    // ---- the instant path ----

    function test_instantLiquidity_isIdlePlusInstantStrategies() public {
        _deposit(1_000e6);
        vault.rebalance();
        assertEq(vault.instantLiquidity(), 750e6);
        assertEq(vault.maxWithdraw(ledger), 750e6);
    }

    function test_withdraw_pullsFromIdleThenInstantAndNeverTheSlowGroup() public {
        _deposit(1_000e6);
        vault.rebalance();
        vm.prank(ledger);
        vault.withdraw(700e6, ledger, ledger);
        assertEq(usdc.balanceOf(ledger), 1_000_000e6 - 300e6);
        assertEq(vault.totalAssets(), 300e6);
        assertEq(fast.totalAssets(), 50e6);
        assertEq(slow.totalAssets(), 250e6, "the slow strategy is not drained for an instant exit");
    }

    /// With the slow strategy first in the list, an instant exit still walks past it. Code that
    /// did not skip the slow group would take from the head of the list first.
    function test_withdraw_skipsASlowStrategyListedFirst() public {
        // Delisting `fast` swaps `slow` into the first slot; listing `fast` again puts it last.
        vm.startPrank(owner);
        vault.removeStrategy(address(fast));
        vault.addStrategy(address(fast), 0);
        vault.setCap(address(fast), type(uint256).max);
        vm.stopPrank();
        assertEq(vault.strategies(0), address(slow));
        _weigh(address(fast), 7500, address(slow), 2500);
        _deposit(1_000e6);
        vault.rebalance();

        vm.prank(ledger);
        vault.withdraw(700e6, ledger, ledger);
        assertEq(slow.totalAssets(), 250e6, "the slow strategy was drained for an instant exit");
        assertEq(fast.totalAssets(), 50e6);
    }

    function test_withdraw_beyondInstantReverts() public {
        _deposit(1_000e6);
        vault.rebalance();
        vm.expectRevert(IVenue.InsufficientInstantLiquidity.selector);
        vm.prank(ledger);
        vault.withdraw(800e6, ledger, ledger);
    }

    /// The share entry point says "use the queue" with the same error.
    function test_redeem_pastInstantLiquiditySaysUseTheQueue() public {
        _deposit(1_000e6);
        vault.rebalance();
        uint256 tooMany = vault.convertToShares(vault.instantLiquidity()) + 1e6;
        vm.expectRevert(IVenue.InsufficientInstantLiquidity.selector);
        vm.prank(ledger);
        vault.redeem(tooMany, ledger, ledger);
    }

    /// A third party withdrawing on an owner's behalf spends the allowance.
    function test_withdraw_aThirdPartySpendsTheAllowance() public {
        _deposit(1_000e6);
        vm.prank(ledger);
        vault.approve(ledger2, 500e6);
        vm.prank(ledger2);
        vault.withdraw(100e6, ledger2, ledger);
        assertEq(vault.allowance(ledger, ledger2), 400e6);

        vm.expectRevert();
        vm.prank(stranger);
        vault.withdraw(100e6, stranger, ledger);
    }

    // ---- transfer restriction ----

    function test_shares_notTransferableToStrangers() public {
        _deposit(100e6);
        vm.expectRevert(IVenue.TransferRestricted.selector);
        vm.prank(ledger);
        vault.transfer(stranger, 1);
    }

    /// Shares move only by mint, burn, or the Venue's own queue bookkeeping. Being a registered
    /// ledger is not enough for a holder-initiated transfer.
    function test_shares_notTransferableToOtherLedgers() public {
        _deposit(100e6);
        vm.expectRevert(IVenue.TransferRestricted.selector);
        vm.prank(ledger);
        vault.transfer(ledger2, 1);
    }
}
