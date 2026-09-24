// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {Venue} from "../src/Venue.sol";
import {IVenue} from "../src/interfaces/IVenue.sol";
import {Config} from "../src/Config.sol";
import {IConfig} from "../src/interfaces/IConfig.sol";
import {ConfigKeys as K} from "../src/ConfigKeys.sol";
import {ComplianceRegistry} from "../src/ComplianceRegistry.sol";
import {PoolTypes} from "../src/PoolTypes.sol";
import {MockUSDC} from "./mocks/MockUSDC.sol";
import {MockVenue} from "./mocks/MockVenue.sol";

/// A stand-in factory: answers isCommunityContract for addresses we register.
contract HarvestFactoryStub {
    mapping(address => bool) public isCommunityContract;

    function register(address a) external {
        isCommunityContract[a] = true;
    }
}

/// The nine properties that specify the Yield Engine's vault half, plus three interactions
/// that have to be specified rather than assumed.
///
/// The model under test:
///
///   recognizedAssets = idle + sum over venues of min(recorded basis, live value)
///   totalAssets      = recognizedAssets - unreleasedProfit
///
/// A gain sits above the basis and is invisible to the price until a harvest realizes it. A
/// loss drops the live value below the basis and reaches the price at once. A harvest skims the
/// two 15% legs out as USDC and puts the member's 70% under a linear unlock.
contract VenueHarvestTest is Test {
    MockUSDC usdc;
    Config config;
    HarvestFactoryStub factory;
    Venue vault;
    MockVenue venue;

    address owner = address(0xA11CE);
    address treasury = address(0x7EA);
    address ledger = address(0x1ED);
    address visitor = address(0x71517);
    address creditPool = address(0xC0DE);

    uint256 constant STAKE = 100_000e6;
    uint256 constant GAIN = 10_000e6;
    uint64 constant UNLOCK = 1 days; // The testnet launch value, the 1-day floor
    uint256 constant BLOCK_TIME = 12;

    function setUp() public {
        usdc = new MockUSDC();
        address screener = address(new ComplianceRegistry(address(this)));
        vm.prank(owner);
        config = new Config(address(usdc), treasury, screener);
        factory = new HarvestFactoryStub();
        factory.register(ledger);
        factory.register(visitor);
        factory.register(creditPool);
        // The credit leg's destination is `Config.CREDIT_CORE` now, not any address the
        // factory registry vouches for (`CreditCore` is a singleton, never a community contract), so
        // the fixture's stand-in pool has to be the configured one.
        vm.prank(owner);
        config.setAddress(K.CREDIT_CORE, creditPool);
        vault = new Venue(usdc, IConfig(address(config)), address(factory), PoolTypes.CORE, owner, "Qudi Core", "qCORE");
        venue = new MockVenue(usdc, "Venue", "V");
        vm.startPrank(owner);
        vault.addVenue(address(venue));
        address[] memory vs = new address[](1);
        vs[0] = address(venue);
        uint16[] memory w = new uint16[](1);
        w[0] = 10_000;
        vault.setWeights(vs, w);
        vm.stopPrank();

        usdc.mint(ledger, 1_000_000e6);
        usdc.mint(visitor, 1_000_000e6);
        usdc.mint(address(this), 1_000_000e6);
        vm.prank(ledger);
        usdc.approve(address(vault), type(uint256).max);
        vm.prank(visitor);
        usdc.approve(address(vault), type(uint256).max);
        usdc.approve(address(venue), type(uint256).max);

        // Start well clear of timestamp 0 so period arithmetic is not run at the epoch boundary.
        vm.warp(365 days);
    }

    // ---- fixture helpers ----

    function _deposit(address who, uint256 assets) internal returns (uint256 shares) {
        vm.prank(who);
        shares = vault.deposit(assets, who);
    }

    /// Puts the whole stake to work in the venue, so the vault's position has a real basis.
    function _stake() internal {
        _deposit(ledger, STAKE);
        vault.rebalance();
    }

    /// Lifts the venue's share price by `assets` without minting: a venue gain.
    function _venueGain(uint256 assets) internal {
        venue.fund(assets);
    }

    /// Drops the venue's share price by `assets` without burning: a venue loss.
    function _venueLoss(uint256 assets) internal {
        venue.skim(assets);
    }

    function _nextBlock() internal {
        vm.roll(block.number + 1);
        vm.warp(block.timestamp + BLOCK_TIME);
    }

    /// Moves to the next harvest period so a second harvest of the same venue is permitted.
    function _nextPeriod() internal {
        vm.roll(block.number + 1);
        vm.warp(block.timestamp + _harvestWindow());
    }

    // -----------------------------------------------------------------------
    // Property 1: a one-block visitor spanning a harvest captures approximately
    // nothing (the whole purpose of the gradual release).
    // -----------------------------------------------------------------------

    function test_p1_oneBlockVisitorSpanningAHarvestCapturesNothing() public {
        _stake();
        _venueGain(GAIN);

        // The block before the harvest.
        uint256 stake = 10_000e6;
        uint256 shares = _deposit(visitor, stake);
        _nextBlock();

        vault.harvest(address(venue));
        _nextBlock();

        vm.prank(visitor);
        uint256 got = vault.redeem(shares, visitor, visitor);

        uint256 captured = got > stake ? got - stake : 0;
        // The figure: two 12-second blocks of a 1-day unlock, on the visitor's slice of the pool.
        emit log_named_decimal_uint("visitor profit captured (USDC)", captured, 6);
        // One basis point of the visitor's own stake. The arithmetic: the member leg is 7,000
        // USDC, 24 seconds of a 86,400-second unlock releases 1.944 of it, and the visitor holds
        // 10,000 of 110,000 shares, so 0.177 USDC is the ceiling on what presence for two blocks
        // can reach.
        assertLt(captured, stake / 10_000, "capture must be de minimis");
    }

    // -----------------------------------------------------------------------
    // Property 2: a member who held across the whole unlock period receives
    // their full share of the member leg.
    // -----------------------------------------------------------------------

    function test_p2_memberHeldAcrossTheUnlockReceivesTheFullMemberLeg() public {
        _stake();
        _venueGain(GAIN);
        vault.harvest(address(venue));

        (uint16 memberBps,,) = config.yieldSplit();
        uint256 memberLeg = (GAIN * memberBps) / 10_000;
        assertEq(memberLeg, 7_000e6, "the fixture's member leg");

        // At the harvest the price has not moved: the whole leg is still locked.
        assertApproxEqAbs(vault.totalAssets(), STAKE, 2, "harvest must not step the price");
        assertApproxEqAbs(vault.unreleasedProfit(), memberLeg, 2, "the whole member leg is locked");

        vm.warp(block.timestamp + UNLOCK);
        assertEq(vault.unreleasedProfit(), 0, "the unlock is over");
        assertApproxEqAbs(
            vault.convertToAssets(vault.balanceOf(ledger)), STAKE + memberLeg, 4, "full member leg, no dilution"
        );
    }

    /// Half the unlock releases half the leg: the release is linear, not a step at the end.
    function test_p2_releaseIsLinearAcrossTheWindow() public {
        _stake();
        _venueGain(GAIN);
        vault.harvest(address(venue));
        uint256 memberLeg = 7_000e6;

        vm.warp(block.timestamp + UNLOCK / 2);
        assertApproxEqAbs(vault.unreleasedProfit(), memberLeg / 2, 1e6, "half released at the halfway point");
        assertApproxEqAbs(vault.totalAssets(), STAKE + memberLeg / 2, 1e6, "and half is in the price");
    }

    // -----------------------------------------------------------------------
    // Property 3: a loss reduces reported totalAssets in full and immediately,
    // and is never smoothed. Including a loss during an unlock period.
    // -----------------------------------------------------------------------

    function test_p3_lossIsImmediateAndInFull() public {
        _stake();
        uint256 before = vault.totalAssets();
        _venueLoss(5_000e6);
        assertApproxEqAbs(vault.totalAssets(), before - 5_000e6, 2, "the whole loss, in the same block");
    }

    /// A loss during an unlock is still recognized in full and in the same block. What the waterfall
    /// changes is where it lands, not when: the junior claim takes it before the share price does.
    /// The teeth of "never smoothed" are the last assertion, that the two reductions add up to the
    /// whole loss in this block, with nothing deferred to a later one.
    function test_p3_lossDuringAnUnlockIsStillImmediateAndInFull() public {
        _stake();
        _venueGain(GAIN);
        vault.harvest(address(venue));
        vm.warp(block.timestamp + UNLOCK / 2); // mid-unlock, half the leg released

        uint256 recognizedBefore = vault.recognizedAssets();
        uint256 totalBefore = vault.totalAssets();
        uint256 heldBefore = vault.unreleasedProfit();

        uint256 loss = 5_000e6;
        _venueLoss(loss);

        // The recognized value carries the whole loss, in the block it happened.
        assertApproxEqAbs(
            vault.recognizedAssets(), recognizedBefore - loss, 2, "the full loss must reach recognized value at once"
        );
        // The promise absorbs what it can; the share price takes only the remainder.
        assertEq(vault.unreleasedProfit(), 0, "a loss larger than the promise consumes all of it");
        uint256 remainder = loss - heldBefore;
        assertApproxEqAbs(vault.totalAssets(), totalBefore - remainder, 2, "the price falls by the remainder");
        // Nothing was smoothed: the junior reduction plus the senior reduction is the whole loss,
        // settled in this block rather than spread over later ones.
        assertApproxEqAbs(
            heldBefore + (totalBefore - vault.totalAssets()), loss, 2, "the two reductions must add up to the loss"
        );
    }

    /// A gain is asymmetric to a loss: it does not reach the price without a harvest.
    function test_p3_gainIsInvisibleUntilHarvested() public {
        _stake();
        uint256 before = vault.totalAssets();
        _venueGain(GAIN);
        assertApproxEqAbs(vault.totalAssets(), before, 2, "an unharvested gain is not in the price");
        assertApproxEqAbs(vault.liveAssets(), before + GAIN, 2, "but the vault can see it");
    }

    // -----------------------------------------------------------------------
    // Property 4: unreleased gain is not withdrawable by anyone, including via
    // the queue, an early break, or a redeem of every share in existence.
    // -----------------------------------------------------------------------

    function test_p4_unreleasedGainIsNotWithdrawableByRedeemingEveryShare() public {
        _stake();
        _venueGain(GAIN);
        vault.harvest(address(venue));

        uint256 locked = vault.unreleasedProfit();
        assertGt(locked, 0, "there is something to try to take");

        uint256 paidOut;
        uint256 shares = vault.balanceOf(ledger);
        vm.prank(ledger);
        paidOut += vault.redeem(shares, ledger, ledger);

        assertEq(vault.totalSupply(), 0, "every share in existence is gone");
        assertLe(paidOut, STAKE + 2, "redeeming the whole supply reaches the stake and no unlocked profit");
        // The locked profit is still in the vault, in the venue, behind no shares at all.
        assertGe(vault.liveAssets(), locked, "the unreleased profit stayed put");
    }

    function test_p4_unreleasedGainIsNotWithdrawableViaTheQueue() public {
        _stake();
        _venueGain(GAIN);
        vault.harvest(address(venue));

        uint256 shares = vault.balanceOf(ledger);
        vm.prank(ledger);
        vault.requestRedeem(shares, ledger);
        vault.processQueue(1);

        assertLe(usdc.balanceOf(ledger), 1_000_000e6 + 2, "the queue paid principal, not the locked profit");
        assertGe(vault.liveAssets(), vault.unreleasedProfit(), "the unreleased profit stayed put");
    }

    /// Unharvested gain is not liquidity either, which is property 4 seen from the payout side.
    ///
    /// The shape that breaks without the cap needs two venues, because one venue holding
    /// everything can never be asked for more than its basis: the vault's whole reported value is
    /// that basis. Give the instant venue a small position with a large gain on it, and a payout
    /// that walks the venues in order will take the gain out of the first venue as cash and leave
    /// the second one's basis standing behind it. The cash is recognized the moment it lands in
    /// idle, so the gain reaches the price with no skim taken and no unlock applied, and the
    /// members who stayed are handed it.
    function test_p4_aPayoutCannotPullAVenueBelowItsBasis() public {
        MockVenue second = new MockVenue(usdc, "Second", "S2");
        usdc.approve(address(second), type(uint256).max);
        vm.startPrank(owner);
        vault.addVenue(address(second));
        address[] memory vs = new address[](2);
        vs[0] = address(venue);
        vs[1] = address(second);
        uint16[] memory w = new uint16[](2);
        w[0] = 1_000; // a small position in the venue the payout walks first
        w[1] = 9_000;
        vault.setWeights(vs, w);
        vm.stopPrank();

        _deposit(ledger, 1_000e6);
        vault.rebalance();
        assertApproxEqAbs(vault.venueBasis(address(venue)), 100e6, 2);
        _venueGain(500e6); // a large unharvested gain on that small position

        // Everything the member's shares are worth, which is the basis and nothing above it.
        uint256 shares = vault.balanceOf(ledger);
        assertApproxEqAbs(vault.convertToAssets(shares), 1_000e6, 2);
        vm.prank(ledger);
        uint256 got = vault.redeem(shares, ledger, ledger);
        assertApproxEqAbs(got, 1_000e6, 2, "the exit was paid what its shares were worth");

        // Nothing of the gain came out with it, and nothing of it is in the price behind it.
        assertLe(vault.recognizedAssets(), 2, "the payout recognized part of an unharvested gain");
        assertApproxEqAbs(vault.liveAssets(), 500e6, 10, "and the gain is still sitting in the venues");
    }

    // -----------------------------------------------------------------------
    // A loss is absorbed by unreleased profit first, and only the
    // remainder reduces the share price.
    //
    // Unreleased profit is the most junior money in the vault: credited to
    // nobody, claimable by no exit, and existing only as a promise to the
    // members who stay. Charging a loss against principal while protecting that
    // promise is backwards. This does not soften the gradual release: the loss is still
    // recognized in full and immediately, it just lands on the junior claim
    // before the senior one.
    // -----------------------------------------------------------------------

    /// A review's own figures, the floor case. A member leg
    /// of ~3,500 is still unreleased when a venue loss leaves ~1,000 recognized. Before the waterfall the
    /// held-back figure exceeded everything left, `totalAssets` floored at zero, redeeming every
    /// share paid zero, and the ~1,000 surfaced behind zero shares once the schedule decayed,
    /// owned by nobody. After it, the loss consumes the whole promise and every recognized unit is
    /// payable.
    function test_midUnlockWipePaysTheWholeRecognizedTotal() public {
        _stake();
        _venueGain(GAIN);
        vault.harvest(address(venue));
        vm.warp(block.timestamp + UNLOCK / 2);

        uint256 scheduled = vault.unreleasedProfit();
        assertApproxEqAbs(scheduled, 3_500e6, 1e6, "the review's held-back figure");

        _venueLoss(106_000e6); // a 106,000 skim on the 107,000 position, as the review ran it

        uint256 recognized = vault.recognizedAssets();
        emit log_named_decimal_uint("recognized after the wipe (USDC)", recognized, 6);
        assertApproxEqAbs(recognized, 1_000e6, 1e6, "the review's recognized figure");

        // The promise is gone, so nothing is held back and the price is the recognized total.
        assertEq(vault.unreleasedProfit(), 0, "the loss consumed the whole promise");
        assertEq(vault.totalAssets(), recognized, "totalAssets is the recognized total, not zero");
        assertGt(vault.totalAssets(), 0, "the vault holds assets it can pay and must say so");

        // Exiting pays the whole recognized total rather than zero. `maxRedeem` rather than the
        // raw balance because at a price this far below unity the two differ by a share or two of
        // rounding, and the claim here is about the money, not about that boundary.
        uint256 shares = vault.maxRedeem(ledger);
        // The gap is measured in assets, not shares: at a price this far below unity one unit of
        // USDC is about a hundred shares, so a share count tolerance would say nothing.
        assertLe(
            vault.convertToAssets(vault.balanceOf(ledger) - shares), 4, "essentially the whole holding is exitable"
        );
        vm.prank(ledger);
        uint256 got = vault.redeem(shares, ledger, ledger);
        emit log_named_decimal_uint("paid on exit (USDC)", got, 6);
        assertApproxEqAbs(got, recognized, 4, "the exit was paid the whole recognized total");

        // And nothing surfaces ownerless once the schedule would have decayed.
        vm.warp(block.timestamp + UNLOCK);
        emit log_named_decimal_uint("left behind after the exit (USDC)", vault.recognizedAssets(), 6);
        assertLe(vault.recognizedAssets(), 4, "value was left behind, owned by nobody");
    }

    /// A loss smaller than the unreleased profit consumes part of it and leaves the share price
    /// exactly where it was. The members who stayed lose part of a promise, not part of their
    /// principal, which is the waterfall running in the right order.
    function test_aLossSmallerThanTheProfitLeavesThePriceUntouched() public {
        _stake();
        _venueGain(GAIN);
        vault.harvest(address(venue));
        vm.warp(block.timestamp + UNLOCK / 2);

        uint256 scheduled = vault.unreleasedProfit();
        uint256 totalBefore = vault.totalAssets();
        uint256 priceBefore = vault.convertToAssets(1e6);
        assertGt(scheduled, 1_000e6, "the promise must be larger than the loss below");

        _venueLoss(1_000e6);

        assertApproxEqAbs(vault.totalAssets(), totalBefore, 2, "the share price must not move");
        assertEq(vault.convertToAssets(1e6), priceBefore, "not by a single unit");
        assertApproxEqAbs(vault.unreleasedProfit(), scheduled - 1_000e6, 2, "the junior claim absorbed the whole loss");
    }

    /// A loss larger than the unreleased profit consumes all of it, and the remainder reduces the
    /// price immediately and in full. The gradual release is not softened: the full loss is recognized in the
    /// block it happens, it is simply split between the junior claim and the senior one.
    function test_aLossLargerThanTheProfitReducesThePriceByTheRemainder() public {
        _stake();
        _venueGain(GAIN);
        vault.harvest(address(venue));
        vm.warp(block.timestamp + UNLOCK / 2);

        uint256 scheduled = vault.unreleasedProfit();
        uint256 totalBefore = vault.totalAssets();
        uint256 recognizedBefore = vault.recognizedAssets();

        uint256 loss = 6_000e6;
        assertGt(loss, scheduled, "the loss must exceed the promise");
        _venueLoss(loss);

        uint256 remainder = loss - scheduled;
        assertEq(vault.unreleasedProfit(), 0, "the promise is gone");
        assertApproxEqAbs(
            vault.totalAssets(), totalBefore - remainder, 2, "the price fell by the remainder, not the whole loss"
        );
        // The whole loss is still recognized, in the same block, with nothing smoothed.
        assertApproxEqAbs(
            vault.recognizedAssets(), recognizedBefore - loss, 2, "the full loss is recognized immediately"
        );
    }

    /// `totalAssets` never floors at zero while the vault holds assets it could pay, at any point
    /// in the window and for any size of loss. Stated as the identity rather than an inequality:
    /// what the vault reports plus what it holds back is exactly what it has recognized, with no
    /// saturating subtraction ever engaging, and a full exit is paid what was reported.
    function testFuzz_theReportedPriceNeverFloorsWhileAssetsRemain(uint32 waitSeed, uint96 lossSeed) public {
        _stake();
        _venueGain(GAIN);
        vault.harvest(address(venue));
        vm.warp(block.timestamp + bound(waitSeed, 0, 3 days));

        uint256 payable_ = vault.liveAssets();
        if (payable_ <= 1) return;
        uint256 loss = bound(lossSeed, 1, payable_ - 1);
        _venueLoss(loss);

        uint256 recognized = vault.recognizedAssets();
        assertEq(
            vault.totalAssets() + vault.unreleasedProfit(),
            recognized,
            "the reported total is not the recognized total less what is held back"
        );
        // Once the loss has eaten the whole promise there is nothing left to hold back, so every
        // recognized unit is reported and payable.
        if (vault.unreleasedProfit() == 0 && recognized > 0) {
            assertGt(vault.totalAssets(), 0, "the price floored at zero with payable assets in the vault");
            uint256 shares = vault.balanceOf(ledger);
            if (shares > 0 && shares <= vault.maxRedeem(ledger)) {
                uint256 quoted = vault.convertToAssets(shares);
                vm.prank(ledger);
                uint256 got = vault.redeem(shares, ledger, ledger);
                assertApproxEqAbs(got, quoted, 2, "the vault did not pay what it reported");
            }
        }
    }

    /// The `LossAbsorbed` figures, asserted directly. The invariant campaign decodes this event to
    /// drive `invariant_reserveBurnsBeforeMembers` and the waterfall ghosts, and a topic that
    /// stopped matching the signature once made that check vacuous without any
    /// test noticing. This pins the shape and the three figures together.
    function test_lossAbsorbedReportsTheWaterfall() public {
        _stake();
        _venueGain(GAIN);
        vault.harvest(address(venue));
        vm.warp(block.timestamp + UNLOCK / 2);
        uint256 scheduled = vault.unreleasedProfit();

        // A loss the promise covers outright: charged wholly to the promise, nothing burned. The
        // expectation goes immediately before `settle()`, which is what emits it; the skim itself
        // emits the venue's own event first.
        _venueLoss(1_000e6);
        vm.expectEmit(false, false, false, true, address(vault));
        emit IVenue.LossAbsorbed(1_000e6, 1_000e6, 0);
        vault.settle();
        assertApproxEqAbs(vault.unreleasedProfit(), scheduled - 1_000e6, 2);

        // A loss past what is left of the promise: the rest reaches the price, and with no reserve
        // funded nothing is burned against it either.
        uint256 left = vault.unreleasedProfit();
        _venueLoss(left + 500e6);
        vm.expectEmit(false, false, false, true, address(vault));
        emit IVenue.LossAbsorbed(left + 500e6, left, 0);
        vault.settle();
        assertEq(vault.unreleasedProfit(), 0, "the promise is spent");
    }

    // -----------------------------------------------------------------------
    // An absorb never raises the share price, and who bears a loss does
    // not depend on when someone touched the vault.
    //
    // Absorption is lazy. A venue loses value with no transaction, and the
    // vault only writes it down at the next touch, which can be a whole unlock
    // window later. Reading the promise's capacity at the touch rather than at
    // the loss let a junior-covered loss fall through to the reserve once the
    // schedule had decayed past it, and the burn that followed put the members
    // back at the no-loss price: a loss absorb that raised the share price.
    // -----------------------------------------------------------------------

    /// A reviewer's construction, figures and all. 100,000 staked, a 20,000 reserve, a
    /// 10,000 gain harvested with a 7,000 promise over one day. At half window the promise
    /// stands at 3,500.000001 and a 1,000 loss lands well inside it. Nobody touches the vault
    /// until the window has completed.
    ///
    /// Before this fix the first touch found `_scheduledProfit() == 0`, charged the whole 1,000 to
    /// the reserve, burned 944,881,889 reserve shares, and lifted the price from 1.050000 to
    /// 1.058333, the no-loss endpoint. About 992 USDC of reserve claim moved to the members for
    /// a loss the promise had covered the moment it landed.
    function test_theLateAbsorbDoesNotChargeTheReserve() public {
        _stake();
        usdc.approve(address(vault), type(uint256).max);
        vault.fundReserve(20_000e6);
        vault.rebalance();
        _venueGain(GAIN);
        vault.harvest(address(venue));

        vm.warp(block.timestamp + UNLOCK / 2);
        uint256 promiseAtTheLoss = vault.unreleasedProfit();
        emit log_named_decimal_uint("L6: promise standing at the loss", promiseAtTheLoss, 6);
        assertApproxEqAbs(promiseAtTheLoss, 3_500e6, 1e6, "the reviewer's promise figure");

        _venueLoss(1_000e6);
        emit log_named_decimal_uint("L6: price right after the loss", vault.convertToAssets(1e6), 6);

        // Nothing touches the vault for the rest of the window.
        vm.warp(block.timestamp + UNLOCK);
        uint256 reserveBefore = vault.reserveShares();
        uint256 priceBefore = vault.convertToAssets(1e6);
        emit log_named_decimal_uint("L6: price at window end, pre-touch", priceBefore, 6);
        assertEq(vault.unreleasedProfit(), 0, "the schedule has decayed");

        vault.settle();

        uint256 burned = reserveBefore - vault.reserveShares();
        uint256 priceAfter = vault.convertToAssets(1e6);
        emit log_named_uint("L6: reserve shares burned (raw)", burned);
        emit log_named_decimal_uint("L6: price after the late absorb", priceAfter, 6);

        assertEq(burned, 0, "the reserve was charged for a loss the promise should have absorbed");
        assertLe(priceAfter, priceBefore, "the absorb raised the share price");
        assertEq(priceAfter, priceBefore, "the absorb moved the price at all");
    }

    /// The same economic history twice, differing only in whether one transaction
    /// landed inside the unlock window, and who paid the loss compared between them.
    function test_whoBearsALossDoesNotDependOnTouchTiming() public {
        _stake();
        usdc.approve(address(vault), type(uint256).max);
        vault.fundReserve(20_000e6);
        vault.rebalance();
        _venueGain(GAIN);
        vault.harvest(address(venue));

        uint256 start = vm.snapshotState();

        // Ordering A: somebody touches the vault inside the window, right after the loss.
        vm.warp(block.timestamp + UNLOCK / 2);
        _venueLoss(1_000e6);
        uint256 reserveA0 = vault.reserveShares();
        vault.settle();
        uint256 burnedA = reserveA0 - vault.reserveShares();
        vm.warp(block.timestamp + UNLOCK);
        vault.settle();
        uint256 priceA = vault.convertToAssets(1e6);
        uint256 reserveA = vault.reserveShares();

        vm.revertToState(start);

        // Ordering B: nobody touches it until the window has completed.
        vm.warp(block.timestamp + UNLOCK / 2);
        _venueLoss(1_000e6);
        uint256 reserveB0 = vault.reserveShares();
        vm.warp(block.timestamp + UNLOCK);
        vault.settle();
        uint256 burnedB = reserveB0 - vault.reserveShares();
        uint256 priceB = vault.convertToAssets(1e6);
        uint256 reserveB = vault.reserveShares();

        emit log_named_uint("timing: reserve shares burned, touched inside the window", burnedA);
        emit log_named_uint("timing: reserve shares burned, untouched until after it", burnedB);
        emit log_named_decimal_uint("timing: member price, touched inside the window", priceA, 6);
        emit log_named_decimal_uint("timing: member price, untouched until after it", priceB, 6);

        assertEq(burnedA, burnedB, "the reserve paid a different amount for the same loss");
        assertEq(reserveA, reserveB, "the reserve ended in a different place");
        assertEq(priceA, priceB, "the members ended at a different price");
    }

    /// An absorb never raises the price, on the ordinary path, where the reserve genuinely does answer: a loss past
    /// anything the promise can cover. The reserve burn restores the members, and the price the
    /// absorb leaves behind is exactly the price the views were already quoting, because
    /// `_previewSettleSupply()` puts the pending burn into the price the moment the loss is
    /// observable rather than at the next touch.
    function test_aReserveBurnDoesNotRaiseThePriceEither() public {
        _stake();
        usdc.approve(address(vault), type(uint256).max);
        vault.fundReserve(20_000e6);
        vault.rebalance();
        _venueGain(GAIN);
        vault.harvest(address(venue));

        // Past the window, and touched there, so no promise stands and none stood at the last
        // touch either: the reserve is the only thing left to answer.
        vm.warp(block.timestamp + UNLOCK * 2);
        vault.settle();
        assertEq(vault.unreleasedProfit(), 0, "no promise stands");

        _venueLoss(5_000e6);
        uint256 priceBefore = vault.convertToAssets(1e6);
        uint256 reserveBefore = vault.reserveShares();
        vault.settle();
        uint256 priceAfter = vault.convertToAssets(1e6);

        assertGt(reserveBefore - vault.reserveShares(), 0, "the reserve must actually have answered here");
        assertLe(priceAfter, priceBefore, "the absorb raised the share price");
        assertEq(priceAfter, priceBefore, "the absorb moved the price at all");
    }

    /// The band between the two: a loss inside the promise the last touch saw, but past what the
    /// schedule still holds. The cover the promise gave it has already been released into the
    /// member price, so that is where it is borne, and the reserve is not touched. The property
    /// this has to keep is the one the reserve exists for: the members do not fall below the price
    /// the last touch left them at. They collect less of the promise, which is the junior claim
    /// paying, not principal.
    function test_aLossInsideTheLastTouchsPromiseNeverDropsThePriceBelowIt() public {
        _stake();
        usdc.approve(address(vault), type(uint256).max);
        vault.fundReserve(20_000e6);
        vault.rebalance();
        _venueGain(GAIN);
        vault.harvest(address(venue));

        uint256 priceAtTheTouch = vault.convertToAssets(1e6);
        uint256 promiseAtTheTouch = vault.unreleasedProfit();
        assertApproxEqAbs(promiseAtTheTouch, 7_000e6, 1e6, "the whole member leg stands");

        // Quiet for the whole window, then a loss that the standing schedule (zero) cannot reach
        // but the promise at the last touch covers comfortably.
        vm.warp(block.timestamp + UNLOCK * 2);
        uint256 reserveBefore = vault.reserveShares();
        _venueLoss(5_000e6);
        vault.settle();

        emit log_named_decimal_uint("band: price at the last touch", priceAtTheTouch, 6);
        emit log_named_decimal_uint("band: price after the absorb", vault.convertToAssets(1e6), 6);
        assertEq(reserveBefore - vault.reserveShares(), 0, "the reserve answered for a covered loss");
        assertGe(
            vault.convertToAssets(1e6), priceAtTheTouch, "the members fell below the price the last touch left them"
        );
    }

    /// The breaker's other answer. `resumeAttribution` says the Risk Committee looked at
    /// the outlier and it is real. Nothing said the opposite, and that left a dead end: the pause
    /// halts every venue's harvests, so it has to be cleared somehow, and the only way to clear it
    /// was to accept the reading. Removal was no escape either, because `removeVenue` reverts
    /// `UnharvestedGain` on the very outlier sitting above the basis.
    ///
    /// `refuseAttribution` clears the pause without arming anything, quarantines the venue so its
    /// reading is never attributed and it can never re-trip the global breaker, and lets
    /// `removeVenue` take the position out over the unharvested gain. The exit is refuse, then
    /// remove.
    function test_theCommitteeCanRefuseAnOutlierAndExitTheVenue() public {
        _stake();
        _venueGain(1_000e6);
        vault.harvest(address(venue));
        _nextPeriod();
        _venueGain(20_000e6);
        vault.harvest(address(venue));
        assertEq(vault.pausedVenue(), address(venue), "the outlier paused attribution");

        // Every venue's harvests are halted while it stands, which is why refusing has to be an
        // available answer rather than a matter of leaving the pause in place.
        vm.expectRevert(IVenue.AttributionIsPaused.selector);
        vault.harvest(address(venue));

        vm.prank(owner);
        vm.expectEmit(true, false, false, false, address(vault));
        emit IVenue.AttributionRefused(address(venue));
        vault.refuseAttribution(address(venue));

        assertEq(vault.pausedVenue(), address(0), "the pause is cleared");
        assertTrue(vault.refusedVenue(address(venue)), "the venue is quarantined");

        // The refused reading is never attributed, and the venue cannot re-trip the breaker to
        // halt everything again.
        _nextPeriod();
        vm.expectRevert(IVenue.VenueRefused.selector);
        vault.harvest(address(venue));
        assertEq(vault.pausedVenue(), address(0), "a refused venue re-paused the vault");

        // And the position comes out, over the gain that is still sitting above the basis.
        uint256 idleBefore = vault.idle();
        vm.prank(owner);
        vault.removeVenue(address(venue));
        assertFalse(vault.isVenue(address(venue)), "the venue was not removed");
        assertGt(vault.idle(), idleBefore, "the position did not come back");
    }

    /// Refusal is the same shape as acceptance everywhere it can be: owner only, and only on the
    /// venue that is actually paused. A refusal cannot be armed ahead of a pause and cannot be
    /// spent on a reading nobody looked at.
    function test_refusalIsScopedTheSameWayAcceptanceIs() public {
        _stake();

        vm.prank(owner);
        vm.expectRevert(IVenue.AttributionNotPaused.selector);
        vault.refuseAttribution(address(venue));

        vm.prank(owner);
        vm.expectRevert(IVenue.AttributionNotPaused.selector);
        vault.refuseAttribution(address(0));

        _venueGain(1_000e6);
        vault.harvest(address(venue));
        _nextPeriod();
        _venueGain(20_000e6);
        vault.harvest(address(venue));
        assertEq(vault.pausedVenue(), address(venue));

        vm.prank(owner);
        vm.expectRevert(IVenue.AttributionNotPaused.selector);
        vault.refuseAttribution(address(0xBEEF));

        vm.prank(visitor);
        vm.expectRevert();
        vault.refuseAttribution(address(venue));

        // Still paused: nothing above cleared it.
        assertEq(vault.pausedVenue(), address(venue), "a rejected refusal cleared the pause");
    }

    /// The quarantine only reaches the venue that was refused. Everything else harvests normally
    /// the moment the pause is cleared, which is the point of having a refusal at all.
    function test_aRefusalDoesNotQuarantineTheOtherVenues() public {
        MockVenue other = new MockVenue(usdc, "Other", "O");
        vm.startPrank(owner);
        vault.addVenue(address(other));
        address[] memory vs = new address[](2);
        vs[0] = address(venue);
        vs[1] = address(other);
        uint16[] memory w = new uint16[](2);
        w[0] = 5_000;
        w[1] = 5_000;
        vault.setWeights(vs, w);
        vm.stopPrank();
        _stake();

        _venueGain(1_000e6);
        vault.harvest(address(venue));
        _nextPeriod();
        _venueGain(20_000e6);
        vault.harvest(address(venue));
        assertEq(vault.pausedVenue(), address(venue));

        vm.prank(owner);
        vault.refuseAttribution(address(venue));

        usdc.mint(address(other), 500e6); // a gain in the venue nobody objected to
        uint256 gain = vault.harvest(address(other));
        assertGt(gain, 0, "an unrelated venue could not be harvested after a refusal");
    }

    // -----------------------------------------------------------------------
    // Property 5: totalAssets never reports a value the vault cannot honour.
    //
    // How this is tested, rather than asserted: the honourable ceiling is
    // `liveAssets()`, which is the vault's own USDC (net of money that already
    // belongs to someone else: held payouts, break escrow, and the two skimmed
    // legs) plus what the venues would pay today. The fuzz below drives a
    // random sequence of deposits, gains, losses, harvests, time and exits and
    // checks the ceiling after every step. `invariant_totalAssetsIsHonourable`
    // in test/invariant/VenueInvariants.t.sol checks the same ceiling across
    // the whole campaign, over sequences this fixture cannot reach.
    // -----------------------------------------------------------------------

    function testFuzz_p5_totalAssetsNeverExceedsWhatTheVaultCanHonour(
        uint96 depositA,
        uint96 gainA,
        uint96 lossA,
        uint32 wait1,
        uint96 depositB,
        uint96 gainB,
        uint32 wait2
    ) public {
        uint256 dA = bound(depositA, 1e6, 200_000e6);
        uint256 dB = bound(depositB, 1e6, 200_000e6);
        uint256 gA = bound(gainA, 0, 50_000e6);
        uint256 gB = bound(gainB, 0, 50_000e6);
        uint256 w1 = bound(wait1, 0, 40 days);
        uint256 w2 = bound(wait2, 0, 40 days);

        _deposit(ledger, dA);
        vault.rebalance();
        _honourable();

        if (gA > 0) _venueGain(gA);
        _honourable();
        _tryHarvest();
        _honourable();

        vm.warp(block.timestamp + w1);
        _honourable();

        uint256 lA = bound(lossA, 0, vault.liveAssets() / 2);
        if (lA > 0) _venueLoss(lA);
        _honourable();

        _deposit(visitor, dB);
        vault.rebalance();
        _honourable();

        if (gB > 0) _venueGain(gB);
        _nextPeriod();
        _tryHarvest();
        _honourable();

        vm.warp(block.timestamp + w2);
        _honourable();

        vault.settle();
        _honourable();

        // And the thing the ceiling exists for: every share can actually be paid.
        uint256 s = vault.balanceOf(ledger);
        if (s > 0 && s <= vault.maxRedeem(ledger)) {
            vm.prank(ledger);
            vault.redeem(s, ledger, ledger);
            _honourable();
        }
    }

    /// The case the ceiling exists for, and the one a naive implementation breaks: right after a
    /// harvest the vault holds a gain it has credited but not released, and every share in
    /// existence must still be payable at the reported price.
    function test_p5_totalAssetsIsHonourableAcrossAHarvestAndItsUnlock() public {
        _stake();
        _venueGain(GAIN);
        _honourable();
        vault.harvest(address(venue));
        _honourable();
        assertApproxEqAbs(
            vault.totalAssets() + vault.unreleasedProfit(), vault.recognizedAssets(), 2, "the unlock is the whole gap"
        );

        vm.warp(block.timestamp + UNLOCK / 3);
        _honourable();
        _venueLoss(3_000e6);
        _honourable();
        vm.warp(block.timestamp + UNLOCK);
        _honourable();

        // The reported price is payable: every share redeems for what it says it is worth.
        uint256 shares = vault.balanceOf(ledger);
        uint256 quoted = vault.convertToAssets(shares);
        vm.prank(ledger);
        uint256 got = vault.redeem(shares, ledger, ledger);
        assertApproxEqAbs(got, quoted, 2, "the price the vault reported is the price it paid");
    }

    /// The ceiling itself. `liveAssets()` already nets out held payouts, break escrow and the
    /// two skimmed legs, so it is exactly the money the vault could raise for its shareholders.
    function _honourable() internal view {
        assertLe(vault.totalAssets(), vault.liveAssets(), "totalAssets exceeds what the vault holds");
        assertLe(vault.totalAssets(), vault.recognizedAssets(), "totalAssets exceeds the recognized value");
    }

    function _tryHarvest() internal {
        try vault.harvest(address(venue)) {} catch {}
    }

    // -----------------------------------------------------------------------
    // Property 6: an exit during an unlock forfeits the unreleased portion of
    // that exit's share, and the forfeited amount stays with the
    // remaining members rather than going anywhere else.
    // -----------------------------------------------------------------------

    function test_p6_exitDuringUnlockForfeitsAndTheStayersKeepIt() public {
        // Two equal members, one exits at the harvest, one holds to the end.
        _deposit(ledger, STAKE);
        _deposit(visitor, STAKE);
        vault.rebalance();
        _venueGain(GAIN);
        vault.harvest(address(venue));

        uint256 memberLeg = 7_000e6;
        assertApproxEqAbs(vault.unreleasedProfit(), memberLeg, 2, "the whole leg is locked");

        // The exit, at the top of the unlock.
        uint256 exitShares = vault.balanceOf(visitor);
        vm.prank(visitor);
        uint256 exitGot = vault.redeem(exitShares, visitor, visitor);
        assertLe(exitGot, STAKE + 2, "the exit forfeits its half of the member leg");
        uint256 forfeited = memberLeg / 2;

        // The forfeited half did not go to the treasury, the credit pool, or the reserve.
        assertEq(usdc.balanceOf(treasury), 0, "nothing leaked to the treasury");
        assertEq(usdc.balanceOf(creditPool), 0, "nothing leaked to the credit pool");
        assertEq(vault.reserveShares(), 0, "nothing leaked to the reserve");

        // It stayed with the member who held: they now collect the whole leg, not half of it.
        vm.warp(block.timestamp + UNLOCK);
        assertApproxEqAbs(
            vault.convertToAssets(vault.balanceOf(ledger)),
            STAKE + memberLeg,
            8,
            "the stayer collects their half plus the half the exit forfeited"
        );
        emit log_named_decimal_uint("forfeited to the stayers (USDC)", forfeited, 6);
    }

    // -----------------------------------------------------------------------
    // Property 7: a double harvest of the same venue and period reverts.
    // -----------------------------------------------------------------------

    function test_p7_doubleHarvestOfTheSameVenueAndPeriodReverts() public {
        _stake();
        _venueGain(GAIN);
        vault.harvest(address(venue));

        _venueGain(GAIN); // a fresh gain: the revert is the period, not the absence of a gain
        vm.expectRevert(IVenue.AlreadyHarvested.selector);
        vault.harvest(address(venue));

        // The next period opens it again.
        _nextPeriod();
        vault.harvest(address(venue));
    }

    /// Idempotency is per venue, not global: a second venue is still harvestable in the period.
    function test_p7_idempotencyIsPerVenue() public {
        MockVenue second = new MockVenue(usdc, "Second", "S2");
        usdc.approve(address(second), type(uint256).max);
        vm.startPrank(owner);
        vault.addVenue(address(second));
        address[] memory vs = new address[](2);
        vs[0] = address(venue);
        vs[1] = address(second);
        uint16[] memory w = new uint16[](2);
        w[0] = 5_000;
        w[1] = 5_000;
        vault.setWeights(vs, w);
        vm.stopPrank();

        _deposit(ledger, STAKE);
        vault.rebalance();
        venue.fund(GAIN);
        second.fund(GAIN);

        vault.harvest(address(venue));
        vault.harvest(address(second)); // same period, different venue: permitted
        vm.expectRevert(IVenue.AlreadyHarvested.selector);
        vault.harvest(address(second));
    }

    /// A second harvest inside the first one's unlock window adds its member leg to whatever is
    /// left of the first and restarts the clock on the sum. Dropping the remainder would release
    /// it in the block the second harvest lands in, which is exactly the step the gradual release exists to
    /// prevent, just reached from a second harvest rather than from the first.
    ///
    /// The unlock is widened to ten days for this, because at the launch values the unlock window
    /// and the harvest period are both one day, so the earliest a venue can be harvested twice is
    /// the moment its first unlock has finished and there is no remainder left to carry.
    function test_p7_asecondHarvestCarriesTheUnreleasedRemainder() public {
        vm.prank(owner);
        config.set(K.UNLOCK_PERIOD, 10 days);
        _stake();
        _venueGain(GAIN);
        vault.harvest(address(venue));
        assertApproxEqAbs(vault.unreleasedProfit(), 7_000e6, 2);

        _nextPeriod(); // one day on, so the venue may be harvested again
        uint256 stillLocked = vault.unreleasedProfit();
        assertApproxEqAbs(stillLocked, 7_000e6 * 9 / 10, 1e6, "nine tenths of the first leg is still locked");

        _venueGain(GAIN);
        vault.harvest(address(venue));
        assertApproxEqAbs(
            vault.unreleasedProfit(), stillLocked + 7_000e6, 2, "the second harvest carried the first's remainder"
        );
    }

    /// Removing a venue liquidates its whole position, so a gain nobody has harvested would land
    /// in idle and reach the price with no skim taken and no unlock applied. Removal says so.
    function test_p7_removingAVenueWithAnUnharvestedGainReverts() public {
        _stake();
        _venueGain(GAIN);
        vm.prank(owner);
        vm.expectRevert(IVenue.UnharvestedGain.selector);
        vault.removeVenue(address(venue));

        vault.harvest(address(venue));
        vm.prank(owner);
        vault.removeVenue(address(venue)); // harvested, so there is nothing left above the basis
        assertEq(vault.venueCount(), 0);
    }

    // -----------------------------------------------------------------------
    // Property 8: an outlier harvest pauses attribution (the deviation
    // breaker), against a config parameter rather than a literal.
    // -----------------------------------------------------------------------

    function test_p8_anOutlierHarvestPausesAttribution() public {
        _stake();
        // Two ordinary harvests build the venue's history.
        _venueGain(1_000e6);
        vault.harvest(address(venue));
        _nextPeriod();
        _venueGain(1_000e6);
        vault.harvest(address(venue));
        _nextPeriod();

        uint256 lockedBefore = vault.unreleasedProfit();
        uint256 recognizedBefore = vault.recognizedAssets();
        uint256 skimmedBefore = vault.protocolHolding() + vault.poolHolding();

        // The outlier: 20x the average, well past HARVEST_DEVIATION_X100's 3x.
        _venueGain(20_000e6);
        vm.expectEmit(true, false, false, false, address(vault));
        emit IVenue.AttributionPaused(address(venue), 0, 0);
        uint256 gain = vault.harvest(address(venue));

        assertEq(gain, 0, "the outlier was not processed");
        assertTrue(vault.attributionPaused(), "attribution is paused");
        assertEq(vault.unreleasedProfit(), lockedBefore, "nothing was credited");
        assertEq(vault.recognizedAssets(), recognizedBefore, "nothing was recognized");
        assertEq(vault.protocolHolding() + vault.poolHolding(), skimmedBefore, "nothing was skimmed");

        // While it stands, no venue may be harvested at all.
        _nextPeriod();
        vm.expectRevert(IVenue.AttributionIsPaused.selector);
        vault.harvest(address(venue));

        // Only the owner clears it, and then the harvest goes through.
        assertEq(vault.pausedVenue(), address(venue), "the breaker records which venue was the outlier");
        vm.expectRevert();
        vault.resumeAttribution(address(venue));
        vm.prank(owner);
        vault.resumeAttribution(address(venue));
        assertFalse(vault.attributionPaused());
        assertEq(vault.pausedVenue(), address(0));
        // Clearing the pause accepts this one outlier: without that, the same gain measured
        // against the same average would simply pause again and could never be realized.
        assertGt(vault.harvest(address(venue)), 0, "the harvest runs once the breaker is cleared");
        assertFalse(vault.attributionPaused(), "and accepting one outlier did not turn the breaker off");

        // The acceptance was one harvest wide: the next outlier pauses again.
        _nextPeriod();
        _venueGain(60_000e6);
        vault.harvest(address(venue));
        assertTrue(vault.attributionPaused(), "the breaker is still armed");
    }

    /// The threshold is the config parameter, not a literal: lowering it makes a gain that was
    /// inside the breaker trip it, with nothing else about the fixture changed.
    function test_p8_theOutlierTestIsTheConfigParameter() public {
        _stake();
        _venueGain(1_000e6);
        vault.harvest(address(venue));
        _nextPeriod();

        vm.prank(owner);
        config.set(K.HARVEST_DEVIATION_X100, 150); // 1.5x
        _venueGain(2_000e6); // 2x the average: inside 3x, outside 1.5x
        vault.harvest(address(venue));
        assertTrue(vault.attributionPaused(), "the breaker follows the parameter");
    }

    /// An acceptance names the venue whose outlier was reviewed, and cannot be spent on a
    /// different venue's unreviewed reading. A global flag let an owner who reviewed venue A's
    /// outlier have the acceptance consumed by venue B's.
    function test_breakerAcceptanceIsScopedToTheReviewedVenue() public {
        MockVenue second = new MockVenue(usdc, "Second", "S2");
        usdc.approve(address(second), type(uint256).max);
        vm.startPrank(owner);
        vault.addVenue(address(second));
        address[] memory vs = new address[](2);
        vs[0] = address(venue);
        vs[1] = address(second);
        uint16[] memory w = new uint16[](2);
        w[0] = 5_000;
        w[1] = 5_000;
        vault.setWeights(vs, w);
        vm.stopPrank();
        _deposit(ledger, STAKE);
        vault.rebalance();

        // Give both venues an ordinary harvest so each has a history to deviate from.
        venue.fund(1_000e6);
        second.fund(1_000e6);
        vault.harvest(address(venue));
        vault.harvest(address(second));
        _nextPeriod();

        // Venue A throws the outlier, and that is the one reviewed and accepted.
        venue.fund(20_000e6);
        vault.harvest(address(venue));
        assertEq(vault.pausedVenue(), address(venue), "venue A is the paused one");
        vm.prank(owner);
        vault.resumeAttribution(address(venue));

        // Venue B now throws its own, unreviewed outlier. The acceptance must not cover it.
        second.fund(20_000e6);
        vault.harvest(address(second));
        assertEq(vault.pausedVenue(), address(second), "venue B's unreviewed outlier must still pause");

        // Accepting venue B supersedes venue A's acceptance: at most one stands at a time, and it
        // is always the most recently reviewed venue. So venue A's outlier pauses again rather than
        // slipping through on a stale acceptance, and the owner reviews it again. A delay, never a
        // movement of money.
        vm.prank(owner);
        vault.resumeAttribution(address(second));
        _nextPeriod();
        assertEq(vault.harvest(address(venue)), 0, "a superseded acceptance must not let the outlier through");
        assertEq(vault.pausedVenue(), address(venue));
        vm.prank(owner);
        vault.resumeAttribution(address(venue));
        _nextPeriod();
        assertGt(vault.harvest(address(venue)), 0, "the re-reviewed outlier goes through");
    }

    /// The acceptance is consumed by that venue's next harvest whether or not the breaker trips, so
    /// a review of today's outlier cannot auto-accept an unrelated one later.
    function test_anAcceptanceIsSpentByTheNextHarvestEitherWay() public {
        _stake();
        _venueGain(1_000e6);
        vault.harvest(address(venue));
        _nextPeriod();

        // Trip the breaker, review it, and accept.
        _venueGain(20_000e6);
        vault.harvest(address(venue));
        vm.prank(owner);
        vault.resumeAttribution(address(venue));
        _nextPeriod();
        assertGt(vault.harvest(address(venue)), 0, "the accepted outlier went through");

        // That harvest spent the acceptance. The next outlier pauses.
        _nextPeriod();
        _venueGain(200_000e6);
        vault.harvest(address(venue));
        assertEq(vault.pausedVenue(), address(venue), "the acceptance was spent, so this one pauses");
    }

    /// The acceptance reverts when nothing is paused, so there is no way to arm a standing
    /// auto-accept ahead of an outlier nobody has seen. Naming a venue other than the paused one
    /// reverts for the same reason.
    function test_breakerAcceptanceRevertsWhenNothingIsPaused() public {
        _stake();
        assertEq(vault.pausedVenue(), address(0));

        vm.prank(owner);
        vm.expectRevert(IVenue.AttributionNotPaused.selector);
        vault.resumeAttribution(address(venue));

        vm.prank(owner);
        vm.expectRevert(IVenue.AttributionNotPaused.selector);
        vault.resumeAttribution(address(0));

        // With a pause standing, naming the wrong venue still reverts.
        _venueGain(1_000e6);
        vault.harvest(address(venue));
        _nextPeriod();
        _venueGain(20_000e6);
        vault.harvest(address(venue));
        assertEq(vault.pausedVenue(), address(venue));
        vm.prank(owner);
        vm.expectRevert(IVenue.AttributionNotPaused.selector);
        vault.resumeAttribution(address(0xBEEF));
    }

    /// When an exit forfeits its unreleased portion and no member remains, the
    /// leftover sits behind a zero share supply. The composition that keeps it out of the next
    /// depositor's pocket is the ERC-4626 virtual share plus the `ZeroShares` guard, and it is
    /// load-bearing under "stays with the remaining members" in the case where none remain. The
    /// reviewer's attack file had this; nothing in the repository did.
    function test_aZeroSupplyVaultsForfeitIsNotAWindfall() public {
        _stake();
        _venueGain(GAIN);
        vault.harvest(address(venue));

        // The only member exits at the top of the unlock, forfeiting the whole member leg.
        uint256 shares = vault.maxRedeem(ledger);
        vm.prank(ledger);
        vault.redeem(shares, ledger, ledger);
        assertEq(vault.totalSupply(), 0, "no member remains");
        vm.warp(block.timestamp + UNLOCK); // let the schedule decay, so the leftover is recognized
        uint256 leftover = vault.totalAssets();
        assertGt(leftover, 0, "there is a forfeited leftover to try to capture");
        emit log_named_decimal_uint("forfeited leftover behind zero shares (USDC)", leftover, 6);

        // A dust deposit against it mints nothing and reverts rather than wiping the depositor.
        vm.prank(visitor);
        vm.expectRevert(IVenue.ZeroShares.selector);
        vault.deposit(1e6, visitor);

        // And a deposit large enough to mint captures nothing on an immediate full exit: the
        // virtual share prices the leftover against one ghost share, so the newcomer's fraction is
        // always s/(s+1) and the ghost's cut eats the forfeit.
        uint256[3] memory multiples = [uint256(2), 10, 100];
        for (uint256 i; i < multiples.length; i++) {
            uint256 stake = leftover * multiples[i];
            uint256 snap = vm.snapshotState();
            vm.prank(visitor);
            uint256 minted = vault.deposit(stake, visitor);
            assertGt(minted, 0, "this deposit is meant to mint");
            uint256 exitable = vault.maxRedeem(visitor);
            vm.prank(visitor);
            uint256 got = vault.redeem(exitable, visitor, visitor);
            assertLe(got, stake, "a newcomer captured part of the forfeited leftover");
            vm.revertToState(snap);
        }
    }

    // -----------------------------------------------------------------------
    // Property 9: the skimmed legs are USDC, not shares, and no share of them
    // remains in the member pool.
    // -----------------------------------------------------------------------

    function test_p9_theSkimmedLegsAreUsdcAndLeaveTheMemberPool() public {
        _stake();
        uint256 supplyBefore = vault.totalSupply();
        _venueGain(GAIN);
        vault.harvest(address(venue));

        (, uint16 poolBps, uint16 protocolBps) = config.yieldSplit();
        uint256 protocolLeg = (GAIN * protocolBps) / 10_000;
        uint256 poolLeg = (GAIN * poolBps) / 10_000;

        // Not shares: the harvest minted nothing at all.
        assertEq(vault.totalSupply(), supplyBefore, "a harvest mints no shares");
        assertEq(vault.balanceOf(treasury), 0, "the protocol leg is not a share position");
        assertEq(vault.reserveShares(), 0, "and it did not become reserve shares either");

        // USDC, held inside the vault until it is claimed.
        assertApproxEqAbs(vault.protocolHolding(), protocolLeg, 2, "the protocol leg is USDC");
        assertApproxEqAbs(vault.poolHolding(), poolLeg, 2, "the credit leg is USDC");

        // No share of either remains in the member pool: the member price is exactly what it
        // was, and the recognized total excludes both holdings.
        assertApproxEqAbs(vault.totalAssets(), STAKE, 2, "the member pool kept only its own leg");
        uint256 held = vault.protocolHolding() + vault.poolHolding();
        assertApproxEqAbs(held, protocolLeg + poolLeg, 2);
        // The vault is holding the USDC, and none of it is inside `idle()`, which is the base
        // every price, liquidity figure and deposit cap in the contract is built on.
        assertEq(
            usdc.balanceOf(address(vault)) - vault.idle(), held, "the skimmed legs sit outside every member figure"
        );

        // Both legs leave as USDC.
        uint256 quoted = vault.protocolHolding();
        vault.claimProtocolLeg();
        assertApproxEqAbs(usdc.balanceOf(treasury), protocolLeg, 2, "the treasury was paid in USDC");
        assertEq(quoted, usdc.balanceOf(treasury));
        assertEq(vault.protocolHolding(), 0);

        vm.prank(ledger);
        uint256 paidPool = vault.claimPoolLeg(creditPool);
        assertApproxEqAbs(usdc.balanceOf(creditPool), poolLeg, 4, "the credit pool was paid in USDC");
        assertEq(paidPool, usdc.balanceOf(creditPool));
        assertEq(vault.balanceOf(creditPool), 0, "and holds no shares of the savings vault");
    }

    /// The `totalLedgerShares == 0` fallback routes the credit leg to the protocol
    /// treasury, because there is no community to attribute it to. It survives in assets.
    function test_p9_creditLegFallsBackToTheTreasuryWithNoLedgerShares() public {
        // A reserve-only vault: value inside, no ledger shares to index against.
        usdc.approve(address(vault), type(uint256).max);
        vault.fundReserve(STAKE);
        vault.rebalance();
        assertEq(vault.totalLedgerShares(), 0);

        _venueGain(GAIN);
        vault.harvest(address(venue));
        assertEq(vault.poolHolding(), 0, "nothing was held for a community");
        vault.claimProtocolLeg();
        (, uint16 poolBps, uint16 protocolBps) = config.yieldSplit();
        assertApproxEqAbs(
            usdc.balanceOf(treasury), (GAIN * (poolBps + protocolBps)) / 10_000, 4, "both legs went to the treasury"
        );
    }

    // -----------------------------------------------------------------------
    // The interaction that must be specified, not assumed.
    // -----------------------------------------------------------------------

    /// (a) A queued withdrawal requested before a harvest and fulfilled during the unlock is
    /// priced at fulfillment, so it collects the portion of the member leg released by
    /// the time it is paid, and no more. It does not get the pre-harvest price, and it does not
    /// get the whole leg.
    function test_s4_queuedWithdrawalRequestedBeforeHarvestPricesAtFulfilment() public {
        _deposit(ledger, STAKE);
        _deposit(visitor, STAKE);
        vault.rebalance();

        uint256 shares = vault.balanceOf(visitor);
        vm.prank(visitor);
        vault.requestRedeem(shares, visitor);
        uint256 estimateAtRequest = vault.queuedRedeemEstimate(1);

        _venueGain(GAIN);
        vault.harvest(address(venue));
        vm.warp(block.timestamp + UNLOCK / 2); // fulfilled halfway through the unlock

        uint256 balBefore = usdc.balanceOf(visitor);
        vault.processQueue(1);
        uint256 paid = usdc.balanceOf(visitor) - balBefore;

        uint256 memberLeg = 7_000e6;
        assertGt(paid, estimateAtRequest, "the price is struck at fulfillment, not at request");
        assertApproxEqAbs(paid, STAKE + memberLeg / 4, 1e6, "it collects half of its half of the leg");
        assertLt(paid, STAKE + memberLeg / 2, "and never the whole of its share of the leg");
    }

    /// (c) An exit cannot be timed to capture more than its held share. The member who deposits
    /// just before the harvest and leaves just after collects strictly less per share than the
    /// member who was there throughout, and the gap is the whole point of the gradual release.
    function test_s4_anExitCannotBeTimedToCaptureMoreThanItsHeldShare() public {
        _stake(); // the holder, in from the start
        _venueGain(GAIN);

        uint256 timedStake = STAKE;
        uint256 timedShares = _deposit(visitor, timedStake);
        vault.rebalance();
        _nextBlock();
        vault.harvest(address(venue));
        _nextBlock();

        vm.prank(visitor);
        uint256 timedGot = vault.redeem(timedShares, visitor, visitor);
        uint256 timedProfitPerUnit = timedGot > timedStake ? ((timedGot - timedStake) * 1e18) / timedStake : 0;

        vm.warp(block.timestamp + UNLOCK);
        uint256 holderGot = vault.convertToAssets(vault.balanceOf(ledger));
        uint256 holderProfitPerUnit = ((holderGot - STAKE) * 1e18) / STAKE;

        assertLt(timedProfitPerUnit, holderProfitPerUnit, "timing the exit must never beat presence");
        emit log_named_decimal_uint("timed exit profit per unit (1e18)", timedProfitPerUnit, 18);
        emit log_named_decimal_uint("holder profit per unit (1e18)", holderProfitPerUnit, 18);
    }

    function _unlockWindow() internal view returns (uint64 w) {
        (w,,) = config.yieldEngine();
    }

    function _harvestWindow() internal view returns (uint64 w) {
        (, w,) = config.yieldEngine();
    }
}
