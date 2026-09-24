// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.30;

import {Ownable} from "openzeppelin-contracts/contracts/access/Ownable.sol";
import {IVenue} from "../src/interfaces/IVenue.sol";
import {ConfigKeys as K} from "../src/ConfigKeys.sol";
import {MockStrategy} from "./mocks/MockStrategy.sol";
import {VenueFixture} from "./helpers/VenueFixture.sol";

/// The Venue reads its strategies' live value on every interaction and caps how fast the price
/// may rise. A gain above the cap is not lost, only paced; a loss is never paced.
contract VenueAccrualTest is VenueFixture {
    MockStrategy s;

    function setUp() public {
        setUpVenue();
        s = _addStrategy(0);
        _weigh(address(s), 10_000, address(0), 0);
        _deposit(1_000e6);
        vault.rebalance();
        assertEq(s.totalAssets(), 1_000e6, "the whole deposit is allocated");
    }

    /// The growth the cap allows over `elapsed` on a base of `base`, the way the Venue computes it.
    function _allowed(uint256 base, uint256 elapsed) internal pure returns (uint256) {
        return base * MAX_RATE_BPS * elapsed / (10_000 * 365 days);
    }

    // ---- 1. the growth cap ----

    /// A 10% jump in one block does not reach the price in that block, reaches it only at
    /// `maxRate`'s pace afterwards, and is caught up in full once the pace allows it.
    function test_proof1_aJumpIsPacedByMaxRateAndCaughtUpLater() public {
        uint256 before = vault.totalAssets();
        s.fund(100e6);
        assertEq(vault.realAssets(), 1_100e6, "the strategy really holds the gain");
        assertEq(vault.totalAssets(), before, "no time has passed, so no growth is allowed");

        vm.warp(block.timestamp + 1 days);
        assertEq(vault.totalAssets(), 1_000e6 + _allowed(1_000e6, 1 days), "one day at the cap, no more");
        assertLt(vault.totalAssets(), vault.realAssets(), "the rest is still waiting");

        // The same span with no accrual in between is exactly 10% at a 10% annual cap.
        vm.warp(block.timestamp + 364 days);
        assertEq(vault.totalAssets(), 1_100e6, "the whole gain is caught up");

        vm.warp(block.timestamp + 365 days);
        assertEq(vault.totalAssets(), 1_100e6, "never past what the strategies hold");
    }

    /// The cap is a ceiling, not a promise: a gain slower than the cap is recognised in full.
    function test_proof1_aGainBelowTheCapIsRecognisedInFull() public {
        // A day at 10% a year on 1,000 USDC allows about 0.27 USDC; this gain is 0.1 USDC.
        s.fund(0.1e6);
        vm.warp(block.timestamp + 1 days);
        assertLt(0.1e6, _allowed(1_000e6, 1 days));
        assertEq(vault.totalAssets(), 1_000e6 + 0.1e6, "all of it, since the cap did not bind");
    }

    /// Each accrual books what the cap allowed since the last one and measures the next stretch
    /// from there. So ten daily accruals land exactly on the cap compounded daily, never above it,
    /// and still below what the strategy holds.
    function test_proof1_eachAccrualBooksOnlyWhatTheCapAllowed() public {
        s.fund(100e6);
        uint256 expected = 1_000e6;
        for (uint256 i; i < 10; i++) {
            vm.warp(block.timestamp + 1 days);
            vault.accrue();
            expected += _allowed(expected, 1 days);
        }
        assertEq(vault.totalAssets(), expected);
        assertLt(vault.totalAssets(), vault.realAssets());
    }

    /// A deposit is not growth. The cap applies to what the Venue already held, and money that
    /// arrives is added to the base the moment it arrives, so a depositor buys at the price, not
    /// at a price the cap has dragged down.
    function test_proof1_aDepositIsNotCappedAsGrowth() public {
        uint256 priceBefore = _price();
        _deposit(5_000e6);
        assertEq(vault.totalAssets(), 6_000e6, "the deposit is in the total at once");
        assertEq(_price(), priceBefore, "and the price did not move");
    }

    /// Money donated to the Venue is paced like any other gain, so a donation cannot move the
    /// price in the block it lands in.
    function test_proof1_aDonationIsPacedToo() public {
        uint256 priceBefore = _price();
        usdc.transfer(address(vault), 500e6);
        assertEq(_price(), priceBefore, "a donation does not move the price in its block");
    }

    // ---- 2. a loss shows at once ----

    /// A strategy that loses value moves the price down in the same block, with no accrual.
    function test_proof2_aLossDropsThePriceInTheSameBlock() public {
        uint256 priceBefore = _price();
        s.skim(100e6);
        assertEq(vault.totalAssets(), 900e6, "the loss is in the total at once");
        assertLt(_price(), priceBefore, "and in the price");
        vault.accrue();
        assertEq(vault.totalAssets(), 900e6, "accruing does not undo it");
    }

    /// After a loss the base is the lower figure, so money that comes back later is a gain like
    /// any other and is paced by the cap.
    function test_proof2_aRecoveryAfterALossIsPacedLikeAGain() public {
        s.skim(100e6);
        vault.accrue();
        s.fund(100e6);
        assertEq(vault.totalAssets(), 900e6, "the recovery does not jump the price back");
        vm.warp(block.timestamp + 1 days);
        assertEq(vault.totalAssets(), 900e6 + _allowed(900e6, 1 days));
    }

    /// A redemption struck after a loss pays the post-loss price.
    function test_proof2_anExitAfterALossPaysItsShareOfIt() public {
        s.skim(200e6);
        uint256 shares = vault.balanceOf(ledger);
        uint256 half = shares / 2;
        vm.prank(ledger);
        uint256 paid = vault.redeem(half, ledger, ledger);
        assertApproxEqAbs(paid, 400e6, 1, "half the shares, half of what is left");
    }

    // ---- 12. labels ----

    function test_proof12_labelsAreOwnerOnlyAndReadInOneView() public {
        IVenue.Labels memory l = IVenue.Labels({
            name: "Term", kind: IVenue.Kind.Locked, riskKey: 3, estReturnBps: 450, exitSeconds: 0, maxRateBps: 660
        });
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger));
        vm.prank(stranger);
        vault.setLabels(l);

        vm.prank(owner);
        vault.setLabels(l);
        IVenue.Labels memory got = vault.labels();
        assertEq(got.name, "Term");
        assertEq(uint8(got.kind), uint8(IVenue.Kind.Locked));
        assertEq(got.riskKey, 3);
        assertEq(got.estReturnBps, 450);
        assertEq(got.exitSeconds, 0);
        assertEq(got.maxRateBps, 660);
    }

    function test_proof12_riskKeyOutsideOneToFiveReverts() public {
        IVenue.Labels memory l = _labels(MAX_RATE_BPS);
        l.riskKey = 0;
        vm.expectRevert(IVenue.RiskKeyOutOfRange.selector);
        vm.prank(owner);
        vault.setLabels(l);

        l.riskKey = 6;
        vm.expectRevert(IVenue.RiskKeyOutOfRange.selector);
        vm.prank(owner);
        vault.setLabels(l);

        l.riskKey = 1;
        vm.prank(owner);
        vault.setLabels(l);
        l.riskKey = 5;
        vm.prank(owner);
        vault.setLabels(l);
    }

    function test_proof12_maxRateAboveItsCeilingReverts() public {
        uint256 ceiling = config.maxRateCeilingBps();
        IVenue.Labels memory l = _labels(uint16(ceiling + 1));
        vm.expectRevert(IVenue.MaxRateAboveCeiling.selector);
        vm.prank(owner);
        vault.setLabels(l);

        l.maxRateBps = uint16(ceiling);
        vm.prank(owner);
        vault.setLabels(l);

        // The ceiling is the live config value, not a copy taken at deployment.
        vm.prank(owner);
        config.set(K.MAX_RATE_CEILING_BPS, 500);
        vm.expectRevert(IVenue.MaxRateAboveCeiling.selector);
        vm.prank(owner);
        vault.setLabels(_labels(501));
    }

    /// A new `maxRate` applies from the moment it is set: what the old rate allowed up to then is
    /// booked first, so a rate change never reprices the past.
    function test_proof12_aNewMaxRateAppliesFromNowOnly() public {
        s.fund(100e6);
        vm.warp(block.timestamp + 10 days);
        uint256 booked = 1_000e6 + _allowed(1_000e6, 10 days);
        _setMaxRate(0);
        assertEq(vault.totalAssets(), booked, "what the old rate allowed is kept");
        vm.warp(block.timestamp + 10 days);
        assertEq(vault.totalAssets(), booked, "and at zero nothing more is recognised");
    }

    // ---- 13. the strategy cap ----

    /// Allocating up to the cap works; allocating past it reverts, and the revert is the
    /// rebalance's, so nothing moves.
    function test_proof13_rebalancePastAStrategyCapReverts() public {
        MockStrategy t = _addStrategy(0);
        vm.prank(owner);
        vault.setCap(address(t), 300e6);
        _weigh(address(s), 7000, address(t), 3000);
        vault.rebalance();
        assertEq(t.totalAssets(), 300e6, "exactly the cap is allowed");

        _deposit(1_000e6);
        vm.expectRevert(IVenue.StrategyCapExceeded.selector);
        vault.rebalance();
        assertEq(t.totalAssets(), 300e6, "nothing moved");
    }

    /// A strategy nobody has sized takes nothing: the cap starts at zero.
    function test_proof13_anUnsizedStrategyTakesNothing() public {
        MockStrategy t = new MockStrategy(usdc, address(vault));
        vm.prank(owner);
        vault.addStrategy(address(t), 0);
        assertEq(vault.capOf(address(t)), 0);
        _weigh(address(s), 5000, address(t), 5000);
        _deposit(1_000e6);
        vm.expectRevert(IVenue.StrategyCapExceeded.selector);
        vault.rebalance();
    }

    function test_proof13_onlyTheOwnerSetsACap() public {
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger));
        vm.prank(stranger);
        vault.setCap(address(s), 1);

        vm.expectRevert(IVenue.UnknownStrategy.selector);
        vm.prank(owner);
        vault.setCap(address(0xDEAD), 1);
    }
}
