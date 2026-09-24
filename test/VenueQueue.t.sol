// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {Venue} from "../src/Venue.sol";
import {IVenue} from "../src/interfaces/IVenue.sol";
import {Config} from "../src/Config.sol";
import {IConfig} from "../src/interfaces/IConfig.sol";
import {ComplianceRegistry} from "../src/ComplianceRegistry.sol";
import {ConfigKeys as K} from "../src/ConfigKeys.sol";
import {PoolTypes} from "../src/PoolTypes.sol";
import {MockUSDC} from "./mocks/MockUSDC.sol";
import {MockVenue} from "./mocks/MockVenue.sol";

/// A stand-in factory: answers isCommunityContract for addresses we register.
contract FactoryStub {
    mapping(address => bool) public isCommunityContract;

    function register(address a) external {
        isCommunityContract[a] = true;
    }
}

contract VenueQueueTest is Test {
    MockUSDC usdc;
    Config config;
    FactoryStub factory;
    Venue vault;
    MockVenue fast;
    MockVenue slow;
    address owner = address(0xA11CE);
    address treasury = address(0x7EA);
    address ledger = address(0x1ED);
    address stranger = address(0xBAD);

    function setUp() public {
        usdc = new MockUSDC();
        address screener = address(new ComplianceRegistry(address(this)));
        vm.prank(owner); // Config takes its owner from msg.sender
        config = new Config(address(usdc), treasury, screener);
        factory = new FactoryStub();
        factory.register(ledger);
        vault = new Venue(usdc, IConfig(address(config)), address(factory), PoolTypes.CORE, owner, "Qudi Core", "qCORE");
        fast = new MockVenue(usdc, "Fast", "F");
        slow = new MockVenue(usdc, "Slow", "S");
        slow.setRedeemDelay(2 days);
        usdc.mint(ledger, 1_000_000e6);
        vm.prank(ledger);
        usdc.approve(address(vault), type(uint256).max);
    }

    function _addBoth() internal {
        vm.startPrank(owner);
        vault.addVenue(address(fast));
        vault.addVenue(address(slow));
        address[] memory vs = new address[](2);
        vs[0] = address(fast);
        vs[1] = address(slow);
        uint16[] memory w = new uint16[](2);
        w[0] = 7500;
        w[1] = 2500;
        vault.setWeights(vs, w);
        vm.stopPrank();
    }

    /// A second registered ledger, funded and approved like `ledger`.
    function _secondLedger() internal returns (address l2) {
        l2 = address(0x2ED);
        factory.register(l2);
        usdc.mint(l2, 1_000e6);
        vm.prank(l2);
        usdc.approve(address(vault), type(uint256).max);
    }

    /// QV-33: `onlyLedger` on both doors it still guards.
    ///
    /// The modifier once guarded three entry points; the early-break arm went with the rest
    /// of the dead lock path, leaving the redeem queue and the credit-leg claim. Both are asserted
    /// here by selector, because the gate is the bound: what a caller who got past it would then
    /// hit is incidental, and an incidental revert is not coverage.
    function test_onlyLedger_guardsTheQueueAndTheCreditLegClaim() public {
        _addBoth();
        vm.prank(ledger);
        vault.deposit(1_000e6, ledger);

        vm.expectRevert(IVenue.NotLedger.selector);
        vm.prank(stranger);
        vault.requestRedeem(100e6, stranger);

        // The credit leg's destination has to be the configured one, or `claimPoolLeg` would be
        // refused by `NotCreditCore` whatever the caller was, and this would prove nothing about
        // the gate in front of it.
        address core = address(0xC0DE);
        vm.prank(owner);
        config.setAddress(K.CREDIT_CORE, core);

        vm.expectRevert(IVenue.NotLedger.selector);
        vm.prank(stranger);
        vault.claimPoolLeg(core);
    }

    function test_requestRedeem_locksSharesAndQueues() public {
        _addBoth();
        vm.prank(ledger);
        vault.deposit(1_000e6, ledger);
        vault.rebalance();
        vm.prank(ledger);
        uint256 id = vault.requestRedeem(900e6, ledger);
        assertEq(id, 1);
        assertEq(vault.balanceOf(ledger), 100e6);
        assertEq(vault.queuedShares(ledger), 900e6);
        assertEq(vault.nextToPay(), 1);
    }

    function test_processQueue_paysWhenLiquidityArrives() public {
        _addBoth();
        vm.prank(ledger);
        vault.deposit(1_000e6, ledger);
        vault.rebalance();
        vm.prank(ledger);
        vault.requestRedeem(900e6, ledger);
        vault.processQueue(10); // 750 instant < 900: not paid
        assertEq(vault.nextToPay(), 1);
        // the slow venue becomes liquid: simulate the keeper draining it
        vault.rebalance(); // queue blocked: rebalance drains the slow venue's maxWithdraw into idle
        vault.processQueue(10);
        assertEq(vault.nextToPay(), 2);
        assertEq(usdc.balanceOf(ledger), 1_000_000e6 - 1_000e6 + 900e6);
        assertEq(vault.queuedShares(ledger), 0);
    }

    function test_processQueue_isFIFO() public {
        _addBoth();
        address ledger2 = address(0x2ED);
        factory.register(ledger2);
        usdc.mint(ledger2, 1_000e6);
        vm.prank(ledger2);
        usdc.approve(address(vault), type(uint256).max);
        vm.prank(ledger);
        vault.deposit(1_000e6, ledger);
        vm.prank(ledger2);
        vault.deposit(1_000e6, ledger2);
        vault.rebalance();
        vm.prank(ledger);
        vault.requestRedeem(1_600e6 / 2, ledger); // 800 shares
        vm.prank(ledger2);
        vault.requestRedeem(100e6, ledger2);
        // instant liquidity is 1,500: request 1 (800) pays, request 2 (100) pays
        vault.processQueue(1);
        assertEq(vault.nextToPay(), 2);
        vault.processQueue(1);
        assertEq(vault.nextToPay(), 3);
    }

    function test_cancelRedeem_returnsShares() public {
        _addBoth();
        vm.prank(ledger);
        vault.deposit(1_000e6, ledger);
        vm.prank(ledger);
        uint256 id = vault.requestRedeem(500e6, ledger);
        vm.prank(ledger);
        vault.cancelRedeem(id);
        assertEq(vault.balanceOf(ledger), 1_000e6);
        assertEq(vault.queuedShares(ledger), 0);
    }

    function test_cancelRedeem_onlyOwner() public {
        _addBoth();
        vm.prank(ledger);
        vault.deposit(1_000e6, ledger);
        vm.prank(ledger);
        uint256 id = vault.requestRedeem(500e6, ledger);
        vm.expectRevert(IVenue.NotOwnerOfRequest.selector);
        vm.prank(stranger);
        vault.cancelRedeem(id);
    }

    /// FIFO is absolute: a head the vault cannot pay stops the requests behind it, even a small
    /// one the vault could cover on its own.
    function test_processQueue_stopsAtUnpayableHead() public {
        address ledger2 = _secondLedger();
        _addBoth();
        vm.prank(ledger);
        vault.deposit(1_000e6, ledger);
        vm.prank(ledger2);
        vault.deposit(300e6, ledger2);
        vault.rebalance(); // 975 instant, 325 slow
        vm.prank(ledger);
        vault.requestRedeem(1_000e6, ledger); // 1,000 > 975: unpayable
        vm.prank(ledger2);
        vault.requestRedeem(100e6, ledger2); // payable on its own, but behind the head
        vault.processQueue(10);
        assertEq(vault.nextToPay(), 1);
        assertEq(usdc.balanceOf(ledger2), 1_000e6 - 300e6);
        assertEq(vault.queuedShares(ledger2), 100e6);
    }

    function test_requestRedeem_rejectsZeroReceiver() public {
        _addBoth();
        vm.prank(ledger);
        vault.deposit(1_000e6, ledger);
        vm.expectRevert(IVenue.ZeroReceiver.selector);
        vm.prank(ledger);
        vault.requestRedeem(500e6, address(0));
    }

    /// A receiver that cannot take USDC must not freeze everyone behind it: the payout is held for
    /// that receiver, the request settles, and the queue keeps moving.
    function test_processQueue_holdsAPayoutTheReceiverCannotTake() public {
        address ledger2 = _secondLedger();
        address blockedReceiver = address(0xB10C);
        usdc.setBlocked(blockedReceiver, true);
        _addBoth();
        vm.prank(ledger);
        vault.deposit(1_000e6, ledger);
        vm.prank(ledger2);
        vault.deposit(1_000e6, ledger2);
        vm.prank(ledger);
        vault.requestRedeem(500e6, blockedReceiver);
        vm.prank(ledger2);
        vault.requestRedeem(100e6, ledger2);
        vault.processQueue(10);
        // both requests are settled; only the deliverable one moved USDC
        assertEq(vault.nextToPay(), 3);
        assertEq(vault.queuedShares(ledger), 0);
        assertEq(vault.queuedShares(ledger2), 0);
        assertEq(usdc.balanceOf(ledger2), 100e6);
        assertEq(vault.heldPayout(blockedReceiver), 500e6);
        assertEq(vault.totalHeld(), 500e6);
        // the held USDC is in the vault's balance but is not the vault's to lend out
        assertEq(usdc.balanceOf(address(vault)), 1_900e6);
        assertEq(vault.idle(), 1_400e6);
        // nothing to release for anyone else
        vm.expectRevert(IVenue.NothingToClaim.selector);
        vault.releaseHeldPayout(stranger);
        // once the receiver can take USDC again, anyone may push it out
        usdc.setBlocked(blockedReceiver, false);
        vault.releaseHeldPayout(blockedReceiver);
        assertEq(usdc.balanceOf(blockedReceiver), 500e6);
        assertEq(vault.heldPayout(blockedReceiver), 0);
        assertEq(vault.totalHeld(), 0);
        assertEq(vault.idle(), 1_400e6);
    }

    /// The instant path never spends what the queue head is owed. While the head is unpayable the
    /// path is shut; once a blocked rebalance has drained the venues the head's assets stay
    /// reserved, so a latecomer can take only the surplus and the head still gets paid.
    /// A loss between request and fulfillment is struck at the claim-time price and is
    /// shared pro-rata with the whole vault, not absorbed by the members who stayed. The
    /// requester is neither first-in-line to eat the loss alone nor able to escape it.
    function test_queue_lossBetweenRequestAndFulfillmentSharedProRata() public {
        address ledger2 = _secondLedger();
        usdc.mint(ledger2, 1_000e6);
        vm.prank(ledger);
        vault.deposit(1_000e6, ledger);
        vm.prank(ledger2);
        vault.deposit(1_000e6, ledger2);

        // ledger requests 1,000 shares. The estimate now is 1,000e6.
        vm.prank(ledger);
        uint256 id = vault.requestRedeem(1_000e6, ledger);
        assertEq(vault.queuedRedeemEstimate(id), 1_000e6);

        // a 20% loss lands while the request waits (idle only, no venues here)
        vm.prank(address(vault));
        usdc.transfer(address(0xDEAD), 400e6);

        // the estimate has moved with the vault: ~800e6 now
        assertApproxEqAbs(vault.queuedRedeemEstimate(id), 800e6, 2);

        uint256 before = usdc.balanceOf(ledger);
        vault.processQueue(10);
        // the requester is paid the struck price (~800e6), its own share of the loss
        assertApproxEqAbs(usdc.balanceOf(ledger) - before, 800e6, 2);
        // the stayer carries the same proportional loss, no worse and no better
        assertApproxEqAbs(vault.convertToAssets(vault.balanceOf(ledger2)), 800e6, 2);
    }

    /// `queuedRedeemEstimate` is an estimate, not a promise. The struck amount differs
    /// from the estimate at request when the vault moves in between.
    function test_queue_estimateIsNotAGuarantee() public {
        vm.prank(ledger);
        vault.deposit(1_000e6, ledger);
        vm.prank(ledger);
        uint256 id = vault.requestRedeem(1_000e6, ledger);
        uint256 estimateAtRequest = vault.queuedRedeemEstimate(id);
        assertEq(estimateAtRequest, 1_000e6);

        // a gain lands: the estimate rises with it
        usdc.mint(address(vault), 100e6);
        vault.settle();
        assertGt(vault.queuedRedeemEstimate(id), estimateAtRequest);

        uint256 before = usdc.balanceOf(ledger);
        vault.processQueue(10);
        assertGt(usdc.balanceOf(ledger) - before, estimateAtRequest); // struck above the estimate

        (address o, address r, uint256 s) = vault.redeemRequest(id);
        assertEq(o, ledger);
        assertEq(r, ledger);
        assertEq(s, 0); // paid
    }

    function test_instantPathReservesTheHeadRequest() public {
        address ledger2 = _secondLedger();
        _addBoth();
        vm.prank(ledger);
        vault.deposit(1_000e6, ledger);
        vm.prank(ledger2);
        vault.deposit(300e6, ledger2);
        vault.rebalance(); // 975 instant, 325 slow
        // a venue loses 200: the vault can no longer cover every share, which is what makes the
        // reserved amount smaller than ledger2's own balance and so visible in maxWithdraw
        fast.skim(200e6);
        vm.prank(ledger);
        vault.requestRedeem(1_000e6, ledger); // 1,000 owed against 775 instant: the queue is blocked
        assertEq(vault.instantLiquidity(), 775e6);
        assertEq(vault.maxWithdraw(ledger2), 0);
        vm.expectRevert(IVenue.InsufficientInstantLiquidity.selector);
        vm.prank(ledger2);
        vault.withdraw(100e6, ledger2, ledger2);

        // the blocked rebalance drains both venues into idle; that idle is the head's, not ledger2's
        vault.rebalance();
        assertEq(vault.instantLiquidity(), 1_100e6);
        // The loss is live, so every holder carries a share of it: the head's 1,000 shares are owed
        // ~846 of the 1,100, and the surplus left over is exactly what ledger2's 300 are now worth.
        uint256 worth = vault.convertToAssets(vault.balanceOf(ledger2));
        assertApproxEqAbs(worth, 253_846_153, 1);
        assertEq(vault.maxWithdraw(ledger2), worth);
        vm.expectRevert(IVenue.InsufficientInstantLiquidity.selector);
        vm.prank(ledger2);
        vault.withdraw(worth + 2, ledger2, ledger2); // one unit past the surplus the head leaves

        // ledger2 takes the whole surplus and the head is still payable, which is the point
        vm.prank(ledger2);
        vault.withdraw(worth, ledger2, ledger2);
        assertEq(usdc.balanceOf(ledger2), 1_000e6 - 300e6 + worth);
        vault.processQueue(1);
        assertEq(vault.nextToPay(), 2);
        // the head is paid its share of the vault as the loss left it, not the principal it put in
        assertApproxEqAbs(usdc.balanceOf(ledger), 1_000_000e6 - 1_000e6 + 846_153_846, 2);
    }
}
