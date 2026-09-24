// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.30;

import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {Community} from "../src/Community.sol";
import {Ledger} from "../src/Ledger.sol";
import {ILedger} from "../src/interfaces/ILedger.sol";
import {Config} from "../src/Config.sol";
import {IConfig} from "../src/interfaces/IConfig.sol";
import {IPauseGuard} from "../src/interfaces/IPauseGuard.sol";
import {ManualStrategy} from "../src/ManualStrategy.sol";
import {CreditFixture} from "./helpers/CreditFixture.sol";
import {VenueIds} from "./helpers/VenueIds.sol";
import {MockStrategy} from "./mocks/MockStrategy.sol";

/// The pause is an instant stop for money going in, and nothing else. Each flag stops exactly the
/// calls its row names. With every flag set, every path that brings money back to a member, repays
/// an advance, books a gain that already happened or brings money back from a strategy still works,
/// because a pause that could trap money would be worse than no pause.
///
/// This contract stands in for the Venue of `ms`, a `ManualStrategy`, so it can put principal in and
/// take it out directly.
contract PauseMatrixTest is CreditFixture {
    Community a;
    uint256 aId;
    address[] pa;
    Ledger ledger;
    MockStrategy poolStrategy;
    ManualStrategy ms;
    address destination = makeAddr("destination");

    uint256 saverVault;

    function setUp() public override {
        super.setUp();
        (a, aId, pa) = _community(100e6, 6);
        _season();
        _grant(aId, 100_000e6);
        ledger = _ledger(aId);
        saverVault = _save(aId, pa[2], 1_000e6);
        poolStrategy = _poolStrategy();

        ms = new ManualStrategy(IERC20(address(usdc)), IConfig(address(config)), address(this), address(this), operator);
        ms.addDestination(destination);
        usdc.mint(address(this), 1_000e6);
        usdc.approve(address(ms), type(uint256).max);
        ms.deposit(1_000e6);
    }

    function _pause(IPauseGuard.Flag flag) internal {
        vm.prank(pauser);
        guard.setPaused(flag, true);
    }

    function _pauseAll() internal {
        _pause(IPauseGuard.Flag.DEPOSITS);
        _pause(IPauseGuard.Flag.DRAWS);
        _pause(IPauseGuard.Flag.VENUES);
    }

    // ---- the calls each row stops ----

    function _deposit() internal {
        usdc.mint(pa[2], 10e6);
        vm.startPrank(pa[2]);
        usdc.approve(address(ledger), 10e6);
        ledger.deposit(saverVault, 10e6);
        vm.stopPrank();
    }

    function _drawOne() internal {
        _draw(pa[1], aId, 10e6);
    }

    /// The Venue holds idle money its strategy's weight wants, so a rebalance allocates.
    function _allocate() internal {
        assertGt(flex.idle(), 0, "there is idle money to allocate");
        flex.rebalance();
    }

    function _poolDeposit() internal {
        vm.prank(operator);
        core.depositToStrategy(address(poolStrategy), 1_000e6);
    }

    function _deploy() internal {
        vm.prank(operator);
        ms.deploy(100e6, destination, bytes32("ref"));
    }

    function _expectPaused() internal {
        vm.expectRevert(IPauseGuard.Paused.selector);
    }

    // ---- proof 1: each flag stops exactly its row ----

    function test_proof1_depositsStopsLedgerDepositAndNothingElse() public {
        _pause(IPauseGuard.Flag.DEPOSITS);
        _expectPaused();
        this.externalDeposit();

        _drawOne();
        _allocate();
        _poolDeposit();
        _deploy();
    }

    function test_proof1_drawsStopsCreditCoreDrawAndNothingElse() public {
        _pause(IPauseGuard.Flag.DRAWS);
        _expectPaused();
        _drawOne();

        _deposit();
        _allocate();
        _poolDeposit();
        _deploy();
    }

    function test_proof1_venuesStopsMoneyIntoAStrategyAndNothingElse() public {
        _pause(IPauseGuard.Flag.VENUES);
        _expectPaused();
        flex.rebalance();
        _expectPaused();
        _poolDeposit();
        _expectPaused();
        _deploy();

        _deposit();
        _drawOne();
    }

    /// Clearing a flag reopens exactly what it closed.
    function test_proof1_clearingEachFlagReopensItsRow() public {
        _pauseAll();
        vm.startPrank(pauser);
        guard.setPaused(IPauseGuard.Flag.DEPOSITS, false);
        guard.setPaused(IPauseGuard.Flag.DRAWS, false);
        guard.setPaused(IPauseGuard.Flag.VENUES, false);
        vm.stopPrank();
        _deposit();
        _drawOne();
        _allocate();
        _poolDeposit();
        _deploy();
    }

    /// Wraps the deposit in an external call so a single `expectRevert` covers its whole prank.
    function externalDeposit() external {
        _deposit();
    }

    /// A deployment that never wired a guard takes no money in. Failing open here would make a
    /// missed wiring step look like a working pause.
    function test_anUnwiredGuardStopsMoneyIn() public {
        Config bare = new Config(address(usdc), treasury, address(registry));
        ManualStrategy unwired =
            new ManualStrategy(IERC20(address(usdc)), IConfig(address(bare)), address(this), address(this), operator);
        unwired.addDestination(destination);
        usdc.mint(address(this), 100e6);
        usdc.approve(address(unwired), 100e6);
        unwired.deposit(100e6);
        vm.prank(operator);
        vm.expectRevert();
        unwired.deploy(100e6, destination, bytes32("ref"));
    }

    // ---- proof 2: with every flag set, nothing that brings money back is stopped ----

    /// A member takes money out: request, cancel, request again, and the Venue pays the queue,
    /// pulling from its strategy because the money sits there. The fee split and accrual run too.
    /// The strategy gives nothing back at first, so the first request waits and can be cancelled.
    function test_proof2_memberWithdrawalsAccrualAndTheQueue() public {
        flex.rebalance(); // the saver's money moves into the strategy
        _gain(20e6, 30 days);
        flexStrategy.setWithdrawCap(0);
        _pauseAll();

        vm.prank(pa[2]);
        uint256 id = ledger.requestWithdraw(saverVault, 100e6);
        vm.prank(pa[2]);
        ledger.cancelWithdraw(id);

        flexStrategy.setWithdrawCap(type(uint256).max);
        ledger.accrue();
        ledger.settleFees();
        flex.accrue();
        uint256 before = usdc.balanceOf(pa[2]);
        vm.prank(pa[2]);
        ledger.requestWithdraw(saverVault, 500e6);
        flex.processQueue(10);
        assertGt(usdc.balanceOf(pa[2]), before, "the member was paid from the strategy");
    }

    /// Every Venue withdrawal path, called by the ledger that holds the shares.
    function test_proof2_everyVenueWithdrawalPath() public {
        flex.rebalance();
        _pauseAll();
        address l = address(ledger);
        vm.startPrank(l);
        flex.withdraw(10e6, l, l);
        flex.redeem(flex.convertToShares(10e6), l, l);
        uint256 r = flex.requestRedeem(flex.convertToShares(10e6), l);
        flex.cancelRedeem(r);
        flex.requestRedeem(flex.convertToShares(10e6), l);
        vm.stopPrank();
        flex.processQueue(10);
    }

    /// A payout the queue could not deliver is released under every flag.
    function test_proof2_aHeldPayoutIsReleased() public {
        _pauseAll();
        address to = makeAddr("blocked receiver");
        usdc.setBlocked(to, true);
        uint256 shares = flex.convertToShares(10e6);
        vm.prank(address(ledger));
        flex.requestRedeem(shares, to);
        flex.processQueue(10);
        assertGt(flex.heldPayout(to), 0, "the payout was held");
        usdc.setBlocked(to, false);
        flex.releaseHeldPayout(to);
        assertEq(flex.heldPayout(to), 0);
    }

    /// A rebalance that only brings money back from a strategy is a strategy withdrawal, so it runs.
    function test_proof2_aRebalanceThatOnlyBringsMoneyBackRuns() public {
        flex.rebalance();
        address[] memory list = new address[](1);
        uint16[] memory bps = new uint16[](1);
        list[0] = address(flexStrategy);
        bps[0] = 5000;
        flex.setWeights(list, bps);
        _pauseAll();
        uint256 inStrategy = flexStrategy.totalAssets();
        flex.rebalance();
        assertLt(flexStrategy.totalAssets(), inStrategy, "money came back to idle");
    }

    /// A shared vault's passed payout executes and the queue pays the recipient.
    function test_proof2_aSharedPayoutExecutes() public {
        vm.prank(pa[0]);
        uint256 shared = ledger.createVault(
            ILedger.VaultParams({venueId: VenueIds.FLEX, shared: true, lockedUntil: 0, name: "pot"})
        );
        for (uint256 i = 1; i <= 4; i++) {
            usdc.mint(pa[i], 20e6);
            vm.startPrank(pa[i]);
            usdc.approve(address(ledger), 20e6);
            ledger.deposit(shared, 20e6);
            vm.stopPrank();
        }
        _season();
        address recipient = makeAddr("recipient");
        vm.prank(pa[0]);
        uint256 payout = ledger.proposeWithdrawal(shared, recipient, 30e6);
        for (uint256 i = 1; i <= 3; i++) {
            vm.prank(pa[i]);
            ledger.voteOnWithdrawal(payout, true);
        }
        _pauseAll();
        ledger.executeWithdrawal(payout);
        flex.processQueue(10);
        assertGt(usdc.balanceOf(recipient), 0, "the recipient was paid");
    }

    /// A borrower repays, anyone records a stage crossing, and the pool's operator brings money
    /// back from a pool strategy.
    function test_proof2_repaymentAndPoolReturns() public {
        _drawOne();
        _poolDeposit();
        _pauseAll();
        _settle(pa[1], 4e6);
        core.materialize(pa[1]);
        _repayAll(pa[1]);
        vm.prank(operator);
        core.withdrawFromStrategy(address(poolStrategy), 1_000e6);
    }

    function test_proof2_aWriteOffFinalizes() public {
        _drawOne();
        (,,,, uint64 wo) = config.stageBoundaries();
        vm.warp(block.timestamp + wo);
        _pauseAll();
        core.finalizeWriteOff(pa[1]);
        assertTrue(core.obligationOf(pa[1]).writtenOff);
    }

    function test_proof2_aDormantBalanceIsSwept() public {
        (uint64 grace, uint64 fade,, uint64 returnAfter) = config.communityDormancy();
        vm.warp(block.timestamp + grace + fade + returnAfter);
        _pauseAll();
        core.sweepDormant(aId);
        assertEq(_credit(aId).allocation, 0);
    }

    /// The strategy's own withdrawal, its operator's return, and a loss report.
    function test_proof2_manualStrategyReturns() public {
        _deploy();
        _pauseAll();
        ms.withdraw(100e6, address(this));
        usdc.mint(operator, 100e6);
        vm.startPrank(operator);
        usdc.approve(address(ms), 100e6);
        ms.returnFrom(100e6);
        vm.stopPrank();
        assertEq(ms.principalDeployed(), 0);
    }
}
