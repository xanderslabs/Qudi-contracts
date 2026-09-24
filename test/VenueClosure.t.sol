// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {Venue} from "../src/Venue.sol";
import {IVenue} from "../src/interfaces/IVenue.sol";
import {Config} from "../src/Config.sol";
import {IConfig} from "../src/interfaces/IConfig.sol";
import {ConfigKeys as K} from "../src/ConfigKeys.sol";
import {ComplianceRegistry} from "../src/ComplianceRegistry.sol";
import {PoolTypes} from "../src/PoolTypes.sol";
import {MockUSDC} from "./mocks/MockUSDC.sol";
import {MockVenue} from "./mocks/MockVenue.sol";
import {CappedVenue} from "./mocks/CappedVenue.sol";

/// A stand-in factory: answers isCommunityContract for addresses we register.
contract ClosureFactoryStub {
    mapping(address => bool) public isCommunityContract;

    function register(address a) external {
        isCommunityContract[a] = true;
    }
}

/// The guards in `Venue`'s money closure that nothing could fail on.
///
/// The mutation sweep covers each contract family's own entry points, not only `CreditCore`'s.
/// Deriving `Venue`'s closure and mutating every bound inside it turned up thirty
/// survivors, almost all in paths that predate the yield engine: the redeem queue, the early
/// break, the withdrawal internals and `rebalance`. Every one of them is present and correct; what
/// was missing was a test that fails when it is removed. The code stays and the tests come to it.
///
/// The bounds that are genuinely unreachable carry recorded proofs in the mutation catalogue
/// instead of tests here.
contract VenueClosureTest is Test {
    MockUSDC usdc;
    Config config;
    ClosureFactoryStub factory;
    Venue vault;
    MockVenue fast;
    CappedVenue slow;

    address owner = address(0xA11CE);
    address treasury = address(0x7EA);
    address ledger = address(0x1ED);
    address ledger2 = address(0x2ED);
    address creditPool = address(0xC0DE);
    address stranger = address(0xBAD);

    uint64 maturity;

    function setUp() public {
        usdc = new MockUSDC();
        address screener = address(new ComplianceRegistry(address(this)));
        vm.prank(owner);
        config = new Config(address(usdc), treasury, screener);
        factory = new ClosureFactoryStub();
        factory.register(ledger);
        factory.register(ledger2);
        factory.register(creditPool);
        // The credit leg's destination is `Config.CREDIT_CORE` now, not any address the
        // factory registry vouches for (`CreditCore` is a singleton, never a community contract), so
        // the fixture's stand-in pool has to be the configured one.
        vm.prank(owner);
        config.setAddress(K.CREDIT_CORE, creditPool);
        vm.warp(365 days);
        maturity = uint64(block.timestamp + 180 days);

        vault = new Venue(usdc, IConfig(address(config)), address(factory), PoolTypes.CORE, owner, "Qudi Core", "qCORE");
        // The slow venue is added FIRST, so `_pullToIdle` and `rebalance` walk it before the fast
        // one. A bound that is supposed to skip it is then observable: code that does not skip it
        // takes from the venue at the head of the list.
        slow = new CappedVenue(usdc, "Slow", "S");
        slow.setRedeemDelay(2 days);
        fast = new MockVenue(usdc, "Fast", "F");
        vm.startPrank(owner);
        vault.addVenue(address(slow));
        vault.addVenue(address(fast));
        address[] memory vs = new address[](2);
        vs[0] = address(slow);
        vs[1] = address(fast);
        uint16[] memory w = new uint16[](2);
        w[0] = 2_500;
        w[1] = 7_500;
        vault.setWeights(vs, w);
        vm.stopPrank();

        usdc.mint(ledger, 1_000_000e6);
        usdc.mint(ledger2, 1_000_000e6);
        usdc.mint(address(this), 1_000_000e6);
        usdc.mint(owner, 1_000_000e6);
        vm.prank(ledger);
        usdc.approve(address(vault), type(uint256).max);
        vm.prank(ledger2);
        usdc.approve(address(vault), type(uint256).max);
        usdc.approve(address(fast), type(uint256).max);
        usdc.approve(address(slow), type(uint256).max);
    }

    function _staked(address who, uint256 assets) internal {
        vm.prank(who);
        vault.deposit(assets, who);
        vault.rebalance();
    }

    // ---------------------------------------------------------------------
    // The instant tier is real: a slow venue is not drained to serve an
    // instant exit, and its liquidity is not offered (QV-52).
    // ---------------------------------------------------------------------

    function test_closure_anInstantExitNeverTouchesTheSlowVenue() public {
        _staked(ledger, 10_000e6);
        uint256 slowBasis = vault.venueBasis(address(slow));
        uint256 fastBasis = vault.venueBasis(address(fast));
        assertGt(slowBasis, 0, "the slow venue holds a position to be tempted by");
        assertGt(fastBasis, 0);

        // Well inside what the fast venue alone can pay.
        vm.prank(ledger);
        vault.withdraw(1_000e6, ledger, ledger);

        assertEq(vault.venueBasis(address(slow)), slowBasis, "the slow venue was drained for an instant exit");
        assertLt(vault.venueBasis(address(fast)), fastBasis, "the fast venue should have paid");
    }

    /// And the slow venue's cash is not counted as instant liquidity, so an exit larger than the
    /// instant tier is refused rather than served out of the slow tier.
    function test_closure_slowLiquidityIsNotOfferedToAnInstantExit() public {
        _staked(ledger, 10_000e6);
        uint256 instant = vault.instantLiquidity();
        assertLt(instant, vault.liveAssets(), "the slow venue's position is outside instant liquidity");
        vm.prank(ledger);
        vm.expectRevert(IVenue.InsufficientInstantLiquidity.selector);
        vault.withdraw(instant + 1e6, ledger, ledger);
    }

    /// The share entry point says the same thing with its own error, which is the distinction the
    /// interface needs: "use the queue" rather than "you asked for more than you have" (QV-42).
    function test_closure_redeemPastInstantLiquiditySaysUseTheQueue() public {
        _staked(ledger, 10_000e6);
        uint256 tooMany = vault.convertToShares(vault.instantLiquidity()) + 1e6;
        vm.prank(ledger);
        vm.expectRevert(IVenue.InsufficientInstantLiquidity.selector);
        vault.redeem(tooMany, ledger, ledger);
    }

    // ---------------------------------------------------------------------
    // Withdrawal internals
    // ---------------------------------------------------------------------

    /// A third party withdrawing on an owner's behalf spends the allowance (QV-48).
    function test_closure_aThirdPartyWithdrawalSpendsTheAllowance() public {
        _staked(ledger, 10_000e6);
        vm.prank(ledger);
        vault.approve(ledger2, 5_000e6);

        vm.prank(ledger2);
        vault.withdraw(1_000e6, ledger2, ledger);
        assertEq(vault.allowance(ledger, ledger2), 4_000e6, "the allowance was not spent");

        // And an unapproved caller cannot take anything.
        vm.prank(stranger);
        vm.expectRevert();
        vault.withdraw(1_000e6, stranger, ledger);
    }

    // ---------------------------------------------------------------------
    // rebalance
    // ---------------------------------------------------------------------

    /// A FLEX vault keeps its buffer idle rather than allocating everything (QV-54, QV-60).
    function test_closure_flexKeepsItsBufferIdle() public {
        Venue flex =
            new Venue(usdc, IConfig(address(config)), address(factory), PoolTypes.FLEX, owner, "Qudi Flex", "qFLEX");
        MockVenue v = new MockVenue(usdc, "V", "V");
        vm.startPrank(owner);
        flex.addVenue(address(v));
        address[] memory vs = new address[](1);
        vs[0] = address(v);
        uint16[] memory w = new uint16[](1);
        w[0] = 10_000;
        flex.setWeights(vs, w);
        vm.stopPrank();
        vm.prank(ledger);
        usdc.approve(address(flex), type(uint256).max);
        vm.prank(ledger);
        flex.deposit(10_000e6, ledger);
        flex.rebalance();

        // `uint256` on the stake, not the bare literal: a rational literal multiplied by the
        // `uint16` the getter returns is evaluated in `uint16` and overflows.
        uint256 stake = 10_000e6;
        uint256 want = (stake * config.flexBufferTargetBps()) / 10_000;
        assertGt(want, 0, "the fixture needs a non-zero buffer to be worth asserting");
        assertApproxEqAbs(flex.idle(), want, 2, "FLEX must hold its buffer back from the venues");
        assertApproxEqAbs(flex.venueBasis(address(v)), stake - want, 2);
    }

    /// A venue that will not give back everything it is over its target by is asked for what it
    /// will give, and the rebalance completes rather than reverting (QV-57).
    function test_closure_rebalanceAsksAVenueOnlyForWhatItWillGive() public {
        _staked(ledger, 10_000e6);
        // Re-weight so the slow venue is far over target, then cap what it will pay.
        vm.startPrank(owner);
        address[] memory vs = new address[](2);
        vs[0] = address(slow);
        vs[1] = address(fast);
        uint16[] memory w = new uint16[](2);
        w[0] = 0;
        w[1] = 10_000;
        vault.setWeights(vs, w);
        vm.stopPrank();

        uint256 over = vault.venueBasis(address(slow));
        assertGt(over, 200e6, "the slow venue must be meaningfully over target");
        slow.setWithdrawCap(100e6);

        vault.rebalance();
        // It gave the capped amount and no more, and nothing reverted.
        assertApproxEqAbs(vault.venueBasis(address(slow)), over - 100e6, 2, "the clamp did not hold");
    }

    /// A venue already at or above its target is left alone on the second pass (QV-59).
    function test_closure_rebalanceDoesNotTopUpAVenueAlreadyAtItsTarget() public {
        _staked(ledger, 10_000e6);
        // Weight everything to the fast venue, so after this rebalance it is exactly at target and
        // the slow venue is at zero. A second rebalance must be a no-op on both.
        vm.startPrank(owner);
        address[] memory vs = new address[](2);
        vs[0] = address(slow);
        vs[1] = address(fast);
        uint16[] memory w = new uint16[](2);
        w[0] = 0;
        w[1] = 10_000;
        vault.setWeights(vs, w);
        vm.stopPrank();
        vault.rebalance();

        uint256 fastBasis = vault.venueBasis(address(fast));
        uint256 idleBefore = vault.idle();
        vault.rebalance();
        assertEq(vault.venueBasis(address(fast)), fastBasis, "a venue at its target must not be topped up");
        assertEq(vault.idle(), idleBefore);
    }

    /// The FLEX buffer is held back from allocation even when a venue's target is larger than the
    /// cash available beyond it (QV-60). With one venue at full weight the clamp coincides with the
    /// target arithmetic, so the construction needs a first pass that could not shed an overweight
    /// venue: the capped venue keeps its position, the other venue's target then exceeds what is
    /// spendable, and only the clamp stops the buffer being spent.
    function test_closure_flexKeepsItsBufferEvenWhenATargetOutrunsTheCash() public {
        Venue flex =
            new Venue(usdc, IConfig(address(config)), address(factory), PoolTypes.FLEX, owner, "Qudi Flex", "qFLEX");
        CappedVenue a = new CappedVenue(usdc, "A", "A");
        MockVenue b = new MockVenue(usdc, "B", "B");
        address[] memory vs = new address[](2);
        vs[0] = address(a);
        vs[1] = address(b);
        uint16[] memory w = new uint16[](2);
        w[0] = 5_000;
        w[1] = 5_000;
        vm.startPrank(owner);
        flex.addVenue(address(a));
        flex.addVenue(address(b));
        flex.setWeights(vs, w);
        vm.stopPrank();
        vm.prank(ledger);
        usdc.approve(address(flex), type(uint256).max);
        vm.prank(ledger);
        flex.deposit(10_000e6, ledger);
        flex.rebalance();

        uint256 buffer = flex.idle();
        assertGt(buffer, 0, "the fixture needs a buffer standing");

        // A will not give anything back, and all the weight moves to B, so B's target is far above
        // what is spendable once the buffer is set aside.
        a.setWithdrawCap(0);
        w[0] = 0;
        w[1] = 10_000;
        vm.prank(owner);
        flex.setWeights(vs, w);
        flex.rebalance();

        assertEq(flex.idle(), buffer, "the rebalance spent the FLEX buffer");
    }

    /// A rebalance allocates only what is idle, never more (QV-61).
    function test_closure_rebalanceAllocatesOnlyWhatIsIdle() public {
        _staked(ledger, 10_000e6);
        // A venue gain raises the targets above what the vault actually holds in cash, so the
        // second pass wants more than idle can fund.
        fast.fund(5_000e6);
        uint256 idleBefore = vault.idle();
        vault.rebalance();
        assertLe(vault.idle(), idleBefore, "a rebalance cannot conjure cash");
        // Nothing reverted and the basis never exceeds what was actually deposited plus the gain.
        assertLe(
            vault.venueBasis(address(fast)) + vault.venueBasis(address(slow)),
            vault.liveAssets() + 2,
            "the basis outran the money"
        );
    }

    // ---------------------------------------------------------------------
    // The redeem queue
    // ---------------------------------------------------------------------

    /// A zero-share request is refused rather than parked in the queue (QV-65).
    function test_closure_aZeroShareRequestIsRefused() public {
        _staked(ledger, 10_000e6);
        vm.prank(ledger);
        vm.expectRevert(IVenue.NothingToClaim.selector);
        vault.requestRedeem(0, ledger);
    }

    /// A request cannot be cancelled twice (QV-68).
    function test_closure_aRequestCannotBeCancelledTwice() public {
        _staked(ledger, 10_000e6);
        vm.prank(ledger);
        uint256 id = vault.requestRedeem(1_000e6, ledger);
        vm.prank(ledger);
        vault.cancelRedeem(id);
        vm.prank(ledger);
        vm.expectRevert(IVenue.NothingToClaim.selector);
        vault.cancelRedeem(id);
    }

    /// A cancelled request is skipped by the queue rather than paid (QV-69), and it stops
    /// reserving instant liquidity behind it (QV-73).
    function test_closure_aCancelledRequestIsNeitherPaidNorReserving() public {
        _staked(ledger, 10_000e6);
        vm.prank(ledger);
        uint256 id = vault.requestRedeem(4_000e6, ledger);
        uint256 reservedFor = vault.maxWithdraw(ledger);

        vm.prank(ledger);
        vault.cancelRedeem(id);
        assertGt(vault.maxWithdraw(ledger), reservedFor, "a cancelled head must stop reserving liquidity");

        uint256 before = usdc.balanceOf(ledger);
        // The event, not the balance: a cancelled entry carries zero shares, so processing it anyway
        // pays zero and moves no money. What it must not do is report itself as paid.
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
        assertEq(vault.queuedShares(ledger), 0);
    }

    /// A cancelled entry ahead of a live one does not hide it: the queue head is the first
    /// unresolved request, and its assets stay reserved out of the instant path (QV-73).
    function test_closure_aCancelledEntryDoesNotHideTheRealQueueHead() public {
        _staked(ledger, 10_000e6);
        vm.startPrank(ledger);
        uint256 first = vault.requestRedeem(1_000e6, ledger);
        vault.requestRedeem(3_000e6, ledger);
        vault.cancelRedeem(first);
        vm.stopPrank();

        // The live second request is now the head, so its assets are not on offer to anyone else.
        uint256 headAssets = vault.convertToAssets(3_000e6);
        assertGt(headAssets, 0);
        assertLe(
            vault.maxWithdraw(ledger) + headAssets,
            vault.instantLiquidity() + 2,
            "the cancelled entry hid the real head and released its reservation"
        );
    }

    /// Nothing is held for a receiver who has nothing held (QV-72 is killed; this pins the pair).
    function test_closure_releasingNothingReverts() public {
        vm.expectRevert(IVenue.NothingToClaim.selector);
        vault.releaseHeldPayout(stranger);
    }

    // ---------------------------------------------------------------------
    // The settled-supply preview (QV-92, QV-93)
    // ---------------------------------------------------------------------
    //
    // Both bounds were once reached through `quoteEarlyBreak`, which was the only caller
    // that took a price reading while a venue loss still stood unabsorbed. The break is gone with
    // the rest of the dead lock path, so these two go through `previewRedeem` against the `redeem`
    // it precedes, which is the same bound on the path that survived: `_previewSettleSupply` is
    // what makes a quote match the price the call it precedes strikes, and every conversion the
    // vault performs is struck over it.
    //
    // `redeem()` absorbs first, so the preview is taken BEFORE it. That is the whole point: after
    // an absorb `_previewSettleSupply()` is just `totalSupply()` and neither mutation shows.

    /// The exact assets the QV-92 fixture below previews. Pinned rather than derived: a derivation
    /// would repeat the preview's own arithmetic and pass under the mutation it exists to catch.
    uint256 internal constant QV92_PREVIEWED_ASSETS = 5_291_666_667;

    function _wreckedVault() internal returns (Venue lv, MockVenue v) {
        lv = new Venue(usdc, IConfig(address(config)), address(factory), PoolTypes.CORE, owner, "Second", "qL2");
        v = new MockVenue(usdc, "LV", "LV");
        vm.startPrank(owner);
        lv.addVenue(address(v));
        address[] memory vs = new address[](1);
        vs[0] = address(v);
        uint16[] memory w = new uint16[](1);
        w[0] = 10_000;
        lv.setWeights(vs, w);
        vm.stopPrank();
        vm.prank(ledger);
        usdc.approve(address(lv), type(uint256).max);
        usdc.approve(address(v), type(uint256).max);
    }

    /// A preview matches the redeem it precedes with both a loss and a promise outstanding, and
    /// the figure it previews is pinned, which is the preview charging the waterfall in the
    /// same order as `_absorb` (QV-92).
    ///
    /// Two things have to line up for the mutation to be visible at all. The loss must exceed the
    /// promise, or the correct and mutated remainders are both zero. And the reserve must be large
    /// enough that neither burn hits the cap, or the cap swallows the difference; that case is
    /// QV-93 below, and it needs its own fixture.
    ///
    /// A preview that charged the whole loss to the reserve would burn more, leave a smaller
    /// supply, and preview a higher figure than the redeem then pays.
    function test_closure_previewMatchesTheRedeemWithALossAndAPromiseOutstanding() public {
        (Venue lv, MockVenue v) = _wreckedVault();
        vm.prank(ledger);
        lv.deposit(100_000e6, ledger); // entry at 1.0
        lv.rebalance();

        // The wreck: an uncovered loss with no reserve to answer for it, written into storage.
        v.skim(90_000e6);
        lv.settle();
        emit log_named_decimal_uint("Q92: price after the uncovered loss", lv.convertToAssets(1e6), 6);

        // A large reserve, bought at the low price, and a fresh harvest inside the wreckage.
        vm.startPrank(owner);
        usdc.approve(address(lv), 50_000e6);
        lv.fundReserve(50_000e6); // large enough that neither burn caps against it
        vm.stopPrank();
        lv.rebalance();
        v.fund(10_000e6);
        lv.harvest(address(v));
        (uint64 unlockWindow,,) = config.yieldEngine();
        vm.warp(block.timestamp + unlockWindow / 2);

        uint256 promise_ = lv.unreleasedProfit();
        assertGt(promise_, 1_000e6, "there must be a promise for the waterfall to charge first");
        v.skim(1_000e6); // junior-covered, and left unabsorbed for the preview to reason about

        uint256 shares = lv.balanceOf(ledger) / 2;
        uint256 previewed = lv.previewRedeem(shares);
        emit log_named_decimal_uint("Q92: previewRedeem", previewed, 6);
        // Pinned. The mutant that charges the whole loss to the reserve previews above this.
        assertEq(previewed, QV92_PREVIEWED_ASSETS, "the preview burned for a junior-covered loss");

        vm.prank(ledger);
        uint256 paid = lv.redeem(shares, ledger, ledger);
        assertEq(paid, previewed, "the preview must strike the price the redeem strikes");
    }

    /// The same preview matches when the reserve is too small to cover the remainder, so the burn
    /// caps against it (QV-93). This is the case the previous test deliberately avoids: it funds a
    /// reserve large enough that neither burn caps, which is what makes the waterfall order visible
    /// there, and in doing so it stops exercising the cap. Both fixtures are needed.
    ///
    /// A preview that forgot the cap would predict a larger burn, a smaller supply and a higher
    /// figure than the redeem then pays.
    function test_closure_previewMatchesTheRedeemWhenTheReserveCapBinds() public {
        (Venue lv, MockVenue v) = _wreckedVault();
        vm.prank(ledger);
        lv.deposit(10_000e6, ledger);
        vm.startPrank(owner);
        usdc.approve(address(lv), 100e6);
        lv.fundReserve(100e6); // far too small for the loss below, so the burn caps
        vm.stopPrank();
        lv.rebalance();

        v.fund(1_000e6);
        lv.harvest(address(v));
        (uint64 unlockWindow,,) = config.yieldEngine();
        vm.warp(block.timestamp + unlockWindow / 2);
        v.skim(2_000e6);

        uint256 shares = lv.balanceOf(ledger) / 2;
        uint256 previewed = lv.previewRedeem(shares);
        vm.prank(ledger);
        uint256 paid = lv.redeem(shares, ledger, ledger);
        assertEq(paid, previewed, "the preview must strike the price the redeem strikes");
    }

    /// A partial loss mid-window leaves the reduced promise finishing when it always was going to,
    /// rather than restarting its clock (QV-89).
    function test_closure_aPartialLossDoesNotRestartTheUnlockClock() public {
        _staked(ledger, 100_000e6);
        fast.fund(10_000e6);
        vault.harvest(address(fast));
        (uint64 unlockWindow,,) = config.yieldEngine();
        uint256 endsAt = block.timestamp + unlockWindow;

        vm.warp(block.timestamp + unlockWindow / 4);
        fast.skim(500e6); // smaller than the promise
        vault.settle();
        assertGt(vault.unreleasedProfit(), 0, "there is still a promise to finish");

        // At the original end time the promise is spent, not stretched past it.
        vm.warp(endsAt);
        assertEq(vault.unreleasedProfit(), 0, "the loss restarted the unlock clock");
    }

    // ---------------------------------------------------------------------
    // The credit leg and the venue list
    // ---------------------------------------------------------------------

    /// A ledger cannot pay its credit leg anywhere but the configured `CreditCore` (QV-109).
    /// This guard reads config, not the factory registry: `CreditCore` is a singleton,
    /// not a community contract, so the registry could never have vouched for it, and a registry
    /// check would have let any registered community contract stand in as the destination.
    function test_closure_theCreditLegOnlyGoesToTheConfiguredCreditCore() public {
        _staked(ledger, 10_000e6);
        fast.fund(1_000e6);
        vault.harvest(address(fast));

        vm.prank(ledger);
        vm.expectRevert(IVenue.NotCreditCore.selector);
        vault.claimPoolLeg(stranger);

        // Not even a registered community contract will do, and neither will the zero address.
        vm.prank(ledger);
        vm.expectRevert(IVenue.NotCreditCore.selector);
        vault.claimPoolLeg(ledger);
        vm.prank(ledger);
        vm.expectRevert(IVenue.NotCreditCore.selector);
        vault.claimPoolLeg(address(0));
    }

    /// Removing a venue that was never listed reverts (QV-113).
    function test_closure_removingAnUnlistedVenueReverts() public {
        vm.prank(owner);
        vm.expectRevert(IVenue.UnknownVenue.selector);
        vault.removeVenue(stranger);
    }

    /// Removing a venue absorbs a standing loss before it liquidates the position (QV-24). After
    /// the liquidation there is no venue reading left for `min(basis, live)` to see, so a loss not
    /// written down first would land on the members in silence instead of on the promise and the
    /// reserve. The reserve burn is the observable.
    function test_closure_removingAVenueAbsorbsAStandingLossFirst() public {
        _staked(ledger, 10_000e6);
        usdc.mint(owner, 1_000e6);
        vm.startPrank(owner);
        usdc.approve(address(vault), 1_000e6);
        vault.fundReserve(1_000e6);
        vm.stopPrank();
        vault.rebalance();

        uint256 priceBefore = vault.convertToAssets(1e6);
        fast.skim(500e6); // a loss nothing has absorbed yet
        uint256 reserveBefore = vault.reserveShares();

        vm.prank(owner);
        vault.removeVenue(address(fast));

        assertLt(vault.reserveShares(), reserveBefore, "removal did not let the reserve take the loss");
        assertApproxEqAbs(
            vault.convertToAssets(1e6), priceBefore, 2, "the loss landed on the members instead of the reserve"
        );
    }

    /// A venue's basis leaves with its position, so re-listing it later starts from zero rather
    /// than from a stale figure that would report value the vault does not hold (QV-115).
    function test_closure_aRelistedVenueStartsFromZeroBasis() public {
        _staked(ledger, 10_000e6);
        assertGt(vault.venueBasis(address(fast)), 0);

        vm.startPrank(owner);
        vault.removeVenue(address(fast));
        assertEq(vault.venueBasis(address(fast)), 0, "the basis did not leave with the position");
        vault.addVenue(address(fast));
        vm.stopPrank();
        assertEq(vault.venueBasis(address(fast)), 0, "a re-listed venue must start from zero");
        // And the vault's reported value is still only what it actually holds.
        assertLe(vault.totalAssets(), vault.liveAssets());
    }

    /// The instant-tier floor binds, not only the slow-tier ceiling (QV-117). At the launch values
    /// the ceiling fires first for any breach, so the floor is only reachable once governance
    /// raises the ceiling, which this does through the ordinary setter.
    function test_closure_theInstantTierFloorBinds() public {
        vm.prank(owner);
        config.set(K.SLOW_TIER_CEILING_BPS, 10_000);

        address[] memory vs = new address[](2);
        vs[0] = address(slow);
        vs[1] = address(fast);
        uint16[] memory w = new uint16[](2);
        w[0] = 8_000; // inside the raised ceiling, outside the 2,500 instant floor
        w[1] = 2_000;
        vm.prank(owner);
        vm.expectRevert(IVenue.TierLimitBreached.selector);
        vault.setWeights(vs, w);

        // And a split that respects the floor is accepted.
        w[0] = 7_500;
        w[1] = 2_500;
        vm.prank(owner);
        vault.setWeights(vs, w);
        assertEq(vault.weightBps(address(slow)), 7_500);
    }
}
