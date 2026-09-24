// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.30;

import {Vm} from "forge-std/Vm.sol";
import {IVenue} from "../src/interfaces/IVenue.sol";
import {IConfig} from "../src/interfaces/IConfig.sol";
import {ManualStrategy} from "../src/ManualStrategy.sol";
import {MockStrategy} from "./mocks/MockStrategy.sol";
import {VenueFixture} from "./helpers/VenueFixture.sol";

/// The redeem queue. A request locks shares; `processQueue`, which anyone may call, pays the
/// receiver directly at the price when it is processed, first from idle cash and then from what
/// each strategy can give now, in list order. There is no claim step.
contract VenueQueueTest is VenueFixture {
    MockStrategy fast;
    MockStrategy slow;

    function setUp() public {
        setUpVenue();
        fast = _addStrategy(0);
        slow = _addStrategy(2 days);
        _weigh(address(fast), 7500, address(slow), 2500);
    }

    /// A second registered ledger, funded and approved like `ledger`.
    function _secondLedger() internal returns (address l2) {
        l2 = address(0x2ED);
        factory.register(l2);
        usdc.mint(l2, 1_000e6);
        vm.prank(l2);
        usdc.approve(address(vault), type(uint256).max);
    }

    function _request(address who, uint256 shares, address receiver) internal returns (uint256 id) {
        vm.prank(who);
        id = vault.requestRedeem(shares, receiver);
    }

    // ---- 8. push withdrawal ----

    /// A queued request is paid straight to its receiver by whoever calls `processQueue`, at the
    /// price when it is processed rather than when it was made.
    function test_proof8_anyoneProcessesAndTheReceiverIsPaidAtTheProcessingPrice() public {
        address receiver = address(0x2EC);
        _deposit(1_000e6);
        vault.rebalance();
        uint256 id = _request(ledger, 500e6, receiver);
        assertEq(vault.queuedRedeemEstimate(id), 500e6);

        // The strategies gain 10% and a year passes, so the cap lets all of it through.
        fast.fund(75e6);
        slow.fund(25e6);
        vm.warp(block.timestamp + 365 days);

        vm.prank(stranger);
        vault.processQueue(10);
        assertApproxEqAbs(usdc.balanceOf(receiver), 550e6, 1, "paid at the price when processed");
        assertEq(usdc.balanceOf(stranger), 0, "the caller is paid nothing");
        assertEq(vault.queuedShares(ledger), 0);
        assertEq(vault.nextToPay(), 2);
        (,, uint256 left) = vault.redeemRequest(id);
        assertEq(left, 0, "settled, and nothing waits to be claimed");
    }

    /// A receiver that refuses the transfer must not freeze everyone behind it: the payout is held
    /// for that receiver, the request settles, and the queue moves on.
    function test_proof8_aRefusingReceiverGetsAHeldPayoutAndTheQueueMovesOn() public {
        address ledger2 = _secondLedger();
        address blockedReceiver = address(0xB10C);
        usdc.setBlocked(blockedReceiver, true);
        _deposit(1_000e6);
        vm.prank(ledger2);
        vault.deposit(1_000e6, ledger2);
        _request(ledger, 500e6, blockedReceiver);
        _request(ledger2, 100e6, ledger2);
        vault.processQueue(10);

        assertEq(vault.nextToPay(), 3, "both requests are settled");
        assertEq(vault.queuedShares(ledger), 0);
        assertEq(vault.queuedShares(ledger2), 0);
        assertEq(usdc.balanceOf(ledger2), 100e6, "the one behind was paid");
        assertEq(vault.heldPayout(blockedReceiver), 500e6);
        assertEq(vault.totalHeld(), 500e6);
        // The held USDC is in the Venue's balance but is not the Venue's to lend out or to price.
        assertEq(usdc.balanceOf(address(vault)), 1_900e6);
        assertEq(vault.idle(), 1_400e6);
        assertEq(vault.totalAssets(), 1_400e6);

        vm.expectRevert(IVenue.NothingToClaim.selector);
        vault.releaseHeldPayout(stranger);

        // Once the receiver can take USDC again, anyone may push it out.
        usdc.setBlocked(blockedReceiver, false);
        vault.releaseHeldPayout(blockedReceiver);
        assertEq(usdc.balanceOf(blockedReceiver), 500e6);
        assertEq(vault.heldPayout(blockedReceiver), 0);
        assertEq(vault.totalHeld(), 0);
        assertEq(vault.idle(), 1_400e6);
    }

    // ---- 9. processing order ----

    /// Idle cash pays first, then what the strategies can give now, in list order. The slow
    /// strategy's delay is the most a member should wait, not a floor: once it can pay, the queue
    /// takes from it.
    function test_proof9_idlePaysFirstThenStrategiesInOrder() public {
        _deposit(1_000e6);
        vault.rebalance(); // 750 fast, 250 slow, 0 idle
        _deposit(100e6); // 100 idle

        _request(ledger, 900e6, ledger);
        uint256 before = usdc.balanceOf(ledger);
        vault.processQueue(1);
        assertEq(usdc.balanceOf(ledger) - before, 900e6);
        assertEq(vault.idle(), 0, "idle went first");
        assertEq(fast.totalAssets(), 0, "then the first strategy");
        assertEq(slow.totalAssets(), 200e6, "then the second, only for what was left");
    }

    /// A strategy pays only what it can give now. A request larger than that waits, and is paid
    /// by the first processing after the money becomes available.
    function test_proof9_aRequestWaitsForWhatTheStrategiesCannotYetGive() public {
        _deposit(1_000e6);
        vault.rebalance();
        slow.setWithdrawCap(0);
        _request(ledger, 900e6, ledger);
        vault.processQueue(10);
        assertEq(vault.nextToPay(), 1, "750 on hand is not 900");

        slow.setWithdrawCap(type(uint256).max);
        vault.processQueue(10);
        assertEq(vault.nextToPay(), 2);
        assertEq(usdc.balanceOf(ledger), 1_000_000e6 - 1_000e6 + 900e6);
    }

    /// With `ManualStrategy`, deployed principal is not withdrawable. A request that needs it
    /// waits for the operator's `returnFrom`, and is then paid.
    function test_proof9_deployedPrincipalWaitsForReturnFrom() public {
        address operator = address(0x0FE);
        address dest = address(0xDE57);
        ManualStrategy ms = new ManualStrategy(usdc, IConfig(address(config)), address(vault), owner, operator);
        vm.startPrank(owner);
        vault.addStrategy(address(ms), 0);
        vault.setCap(address(ms), type(uint256).max);
        ms.addDestination(dest);
        vm.stopPrank();
        _weigh(address(ms), 10_000, address(0), 0);
        _deposit(1_000e6);
        vault.rebalance();

        vm.prank(operator);
        ms.deploy(600e6, dest, bytes32(0));
        _request(ledger, 700e6, ledger);
        vault.processQueue(10);
        assertEq(vault.nextToPay(), 1, "only 400 is cash; the rest is out");

        usdc.mint(operator, 600e6);
        vm.startPrank(operator);
        usdc.approve(address(ms), 600e6);
        ms.returnFrom(600e6);
        vm.stopPrank();

        vault.processQueue(10);
        assertEq(vault.nextToPay(), 2);
        assertEq(usdc.balanceOf(ledger), 1_000_000e6 - 1_000e6 + 700e6);
    }

    // ---- the queue itself ----

    function test_onlyLedger_guardsTheQueue() public {
        _deposit(1_000e6);
        vm.expectRevert(IVenue.NotLedger.selector);
        vm.prank(stranger);
        vault.requestRedeem(100e6, stranger);
    }

    function test_requestRedeem_locksSharesAndQueues() public {
        _deposit(1_000e6);
        vault.rebalance();
        uint256 id = _request(ledger, 900e6, ledger);
        assertEq(id, 1);
        assertEq(vault.balanceOf(ledger), 100e6);
        assertEq(vault.queuedShares(ledger), 900e6);
        assertEq(vault.nextToPay(), 1);
    }

    function test_processQueue_isFIFO() public {
        address ledger2 = _secondLedger();
        _deposit(1_000e6);
        vm.prank(ledger2);
        vault.deposit(1_000e6, ledger2);
        vault.rebalance();
        _request(ledger, 800e6, ledger);
        _request(ledger2, 100e6, ledger2);
        vault.processQueue(1);
        assertEq(vault.nextToPay(), 2);
        assertEq(vault.queuedShares(ledger), 0, "the first request was paid first");
        assertEq(vault.queuedShares(ledger2), 100e6);
        vault.processQueue(1);
        assertEq(vault.nextToPay(), 3);
    }

    /// FIFO is absolute: a head the Venue cannot pay stops the requests behind it, even a small
    /// one the Venue could cover on its own.
    function test_processQueue_stopsAtUnpayableHead() public {
        address ledger2 = _secondLedger();
        _deposit(1_000e6);
        vm.prank(ledger2);
        vault.deposit(300e6, ledger2);
        vault.rebalance(); // 975 fast, 325 slow
        slow.setWithdrawCap(0);
        _request(ledger, 1_000e6, ledger); // 1,000 > 975: unpayable
        _request(ledger2, 100e6, ledger2); // payable on its own, but behind the head
        vault.processQueue(10);
        assertEq(vault.nextToPay(), 1);
        assertEq(usdc.balanceOf(ledger2), 1_000e6 - 300e6);
        assertEq(vault.queuedShares(ledger2), 100e6);
    }

    function test_cancelRedeem_returnsShares() public {
        _deposit(1_000e6);
        uint256 id = _request(ledger, 500e6, ledger);
        vm.prank(ledger);
        vault.cancelRedeem(id);
        assertEq(vault.balanceOf(ledger), 1_000e6);
        assertEq(vault.queuedShares(ledger), 0);
    }

    function test_cancelRedeem_onlyOwner() public {
        _deposit(1_000e6);
        uint256 id = _request(ledger, 500e6, ledger);
        vm.expectRevert(IVenue.NotOwnerOfRequest.selector);
        vm.prank(stranger);
        vault.cancelRedeem(id);
    }

    function test_requestRedeem_rejectsZeroReceiver() public {
        _deposit(1_000e6);
        vm.expectRevert(IVenue.ZeroReceiver.selector);
        vm.prank(ledger);
        vault.requestRedeem(500e6, address(0));
    }

    /// A zero-share request is refused rather than parked in the queue.
    function test_requestRedeem_aZeroShareRequestIsRefused() public {
        _deposit(1_000e6);
        vm.expectRevert(IVenue.NothingToClaim.selector);
        vm.prank(ledger);
        vault.requestRedeem(0, ledger);
    }

    function test_cancelRedeem_aRequestCannotBeCancelledTwice() public {
        _deposit(1_000e6);
        uint256 id = _request(ledger, 500e6, ledger);
        vm.prank(ledger);
        vault.cancelRedeem(id);
        vm.expectRevert(IVenue.NothingToClaim.selector);
        vm.prank(ledger);
        vault.cancelRedeem(id);
    }

    /// A cancelled request is skipped by the queue rather than paid, and stops reserving instant
    /// liquidity behind it.
    function test_processQueue_aCancelledRequestIsNeitherPaidNorReserving() public {
        _deposit(10_000e6);
        vault.rebalance();
        uint256 id = _request(ledger, 4_000e6, ledger);
        uint256 reservedFor = vault.maxWithdraw(ledger);

        vm.prank(ledger);
        vault.cancelRedeem(id);
        assertGt(vault.maxWithdraw(ledger), reservedFor, "a cancelled head must stop reserving liquidity");

        uint256 before = usdc.balanceOf(ledger);
        vm.recordLogs();
        vault.processQueue(5);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 paidTopic = keccak256("RedeemPaid(uint256,uint256)");
        for (uint256 i; i < logs.length; i++) {
            if (logs[i].emitter == address(vault) && logs[i].topics.length > 0 && logs[i].topics[0] == paidTopic) {
                revert("a cancelled request was reported as paid");
            }
        }
        assertEq(usdc.balanceOf(ledger), before, "a cancelled request must not be paid");
    }

    /// A cancelled entry ahead of a live one does not hide it: the head is the first unresolved
    /// request, and its assets stay reserved out of the instant path.
    function test_processQueue_aCancelledEntryDoesNotHideTheRealHead() public {
        _deposit(10_000e6);
        vault.rebalance();
        vm.startPrank(ledger);
        uint256 first = vault.requestRedeem(1_000e6, ledger);
        vault.requestRedeem(3_000e6, ledger);
        vault.cancelRedeem(first);
        vm.stopPrank();

        uint256 headAssets = vault.convertToAssets(3_000e6);
        assertLe(
            vault.maxWithdraw(ledger) + headAssets,
            vault.instantLiquidity() + 2,
            "the cancelled entry hid the real head and released its reservation"
        );
    }

    /// A loss between request and processing is struck at the processing price and shared
    /// pro-rata with everyone: the requester neither eats it alone nor escapes it.
    function test_queue_lossBetweenRequestAndProcessingIsSharedProRata() public {
        address ledger2 = _secondLedger();
        usdc.mint(ledger2, 1_000e6);
        _deposit(1_000e6);
        vm.prank(ledger2);
        vault.deposit(1_000e6, ledger2);

        uint256 id = _request(ledger, 1_000e6, ledger);
        assertEq(vault.queuedRedeemEstimate(id), 1_000e6);

        // A 20% loss lands while the request waits (idle only).
        vm.prank(address(vault));
        usdc.transfer(address(0xDEAD), 400e6);
        assertApproxEqAbs(vault.queuedRedeemEstimate(id), 800e6, 2, "the estimate moved with the Venue");

        uint256 before = usdc.balanceOf(ledger);
        vault.processQueue(10);
        assertApproxEqAbs(usdc.balanceOf(ledger) - before, 800e6, 2);
        assertApproxEqAbs(vault.convertToAssets(vault.balanceOf(ledger2)), 800e6, 2);
    }

    /// The instant path never spends what the queue head is owed.
    function test_instantPathReservesTheHeadRequest() public {
        address ledger2 = _secondLedger();
        _deposit(1_000e6);
        vm.prank(ledger2);
        vault.deposit(300e6, ledger2);
        vault.rebalance(); // 975 fast, 325 slow
        slow.setWithdrawCap(0);
        _request(ledger, 1_000e6, ledger); // 1,000 owed against 975 instant: unpayable
        assertEq(vault.instantLiquidity(), 975e6);
        assertEq(vault.maxWithdraw(ledger2), 0, "the head's claim covers everything instant");
        vm.expectRevert(IVenue.InsufficientInstantLiquidity.selector);
        vm.prank(ledger2);
        vault.withdraw(100e6, ledger2, ledger2);
    }

    /// While the head is unpayable, `rebalance` feeds no strategy and brings home what the
    /// strategies will give: idle belongs to the queue until it clears.
    function test_rebalance_feedsNothingWhileTheHeadIsUnpayable() public {
        _deposit(1_000e6);
        vault.rebalance(); // 750 fast, 250 slow
        slow.setWithdrawCap(0);
        _request(ledger, 1_000e6, ledger);
        _deposit(200e6); // new idle cash arrives
        vault.rebalance();
        assertEq(vault.idle(), 950e6, "the fast strategy came home and nothing was pushed out");
        assertEq(fast.totalAssets(), 0);
        slow.setWithdrawCap(type(uint256).max);
        vault.processQueue(1);
        assertEq(vault.nextToPay(), 2);
    }
}
