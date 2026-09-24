// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {CreditCore} from "../src/CreditCore.sol";
import {CreditStanding} from "../src/CreditStanding.sol";
import {ICreditCore} from "../src/interfaces/ICreditCore.sol";
import {Config} from "../src/Config.sol";
import {ConfigKeys as K} from "../src/ConfigKeys.sol";
import {IConfig} from "../src/interfaces/IConfig.sol";
import {MockUSDC} from "./mocks/MockUSDC.sol";
import {MockVenue} from "./mocks/MockVenue.sol";
import {SlippingVenue} from "./mocks/SlippingVenue.sol";
import {NoDelayVenue} from "./mocks/NoDelayVenue.sol";
import {CreditCoreHarness} from "./helpers/CreditCoreHarness.sol";
import {MockCommunityFactory} from "./helpers/MockCommunityFactory.sol";

/// The Treasury Manager venue limits. Per-venue cap at 25% of total Treasury cash, the
/// 7-day redemption-delay limit checked at listing, the 50 bps slippage limit on both venue
/// paths, and venue listing behind the Risk Committee. This suite owns `Config` from the
/// test contract, so the test contract is the Risk Committee; the 48-hour delay itself is
/// exercised against a real `TimelockController` in `CreditCoreTimelock.t.sol`.
contract CreditCoreVenueLimitsTest is Test {
    MockUSDC usdc;
    Config config;
    MockCommunityFactory factory;
    CreditCoreHarness cc;

    address governance = makeAddr("governance");
    address treasuryMgr = makeAddr("treasuryManager");
    address allocationMs = makeAddr("allocationMultisig");

    uint256 constant BASE_REQUIRED = 110_000e6;
    uint64 constant DELAY_LIMIT = 7 days;

    function setUp() public {
        usdc = new MockUSDC();
        config = new Config(address(usdc), makeAddr("treasury"), makeAddr("registry"));
        factory = new MockCommunityFactory();
        factory.setCommunityCount(1);
        CreditStanding standing = new CreditStanding(IConfig(address(config)), address(factory), governance);
        cc = new CreditCoreHarness(
            IERC20(address(usdc)),
            IConfig(address(config)),
            address(factory),
            governance,
            treasuryMgr,
            allocationMs,
            standing
        );
        vm.prank(governance);
        standing.setCreditCore(address(cc));
    }

    function _fund(uint256 amount) internal {
        usdc.mint(governance, amount);
        vm.startPrank(governance);
        usdc.approve(address(cc), amount);
        cc.fund(amount);
        vm.stopPrank();
    }

    /// The test contract owns Config, so it is the Risk Committee for listing purposes.
    function _list(address venue) internal {
        cc.addVenue(venue);
    }

    function _mockVenue() internal returns (MockVenue v) {
        v = new MockVenue(IERC20(address(usdc)), "V", "V");
    }

    function _deposit(address venue, uint256 assets) internal {
        vm.prank(treasuryMgr);
        cc.depositToVenue(venue, assets);
    }

    // -----------------------------------------------------------------
    // 1. Per-venue cap: 25% of total Treasury cash, both sides
    // -----------------------------------------------------------------

    function test_perVenueCap_bothSidesOfBoundary() public {
        _fund(1_000_000e6); // base ~ 1,000,000e6, so the per-venue cap is ~250,000e6
        MockVenue v = _mockVenue();
        _list(address(v));

        // one unit past 25% reverts
        vm.prank(treasuryMgr);
        vm.expectRevert(ICreditCore.PerVenueCapExceeded.selector);
        cc.depositToVenue(address(v), 250_000e6 + 1);

        // exactly at 25% succeeds
        _deposit(address(v), 250_000e6);
        assertEq(cc.largestVenueExposure(), 250_000e6);

        // a further unit now exceeds it
        vm.prank(treasuryMgr);
        vm.expectRevert(ICreditCore.PerVenueCapExceeded.selector);
        cc.depositToVenue(address(v), 1);
    }

    /// `_largestVenueExposure`'s max-of-list selection sits inside `_venueLossReserve`
    /// (20% of the LARGEST single-venue exposure) and was untested by every existing
    /// multi-venue test, which either lists one venue (`test_perVenueCap_bothSidesOfBoundary`)
    /// or several venues at EQUAL exposure (`test_aggregateBindsWhilePerVenueHasRoom`), so a
    /// "return the first venue's exposure" mutation and a "return the maximum" implementation
    /// are indistinguishable to the prior suite. Three venues at different sizes, none tied,
    /// makes the selection itself the thing under test.
    function test_largestVenueExposure_isTheMaximumAcrossVenues() public {
        _fund(2_000_000e6);
        MockVenue a = _mockVenue();
        MockVenue b = _mockVenue();
        MockVenue c = _mockVenue();
        _list(address(a));
        _list(address(b));
        _list(address(c));

        _deposit(address(a), 100_000e6);
        _deposit(address(b), 300_000e6); // the true maximum
        _deposit(address(c), 200_000e6);

        assertEq(cc.largestVenueExposure(), 300_000e6, "the largest single-venue exposure, not the first or the sum");
    }

    // -----------------------------------------------------------------
    // 2. Per-venue cap binds independently of the aggregate cap
    // -----------------------------------------------------------------

    /// Aggregate satisfied, per-venue violated: one venue taking 30% of cash. The aggregate
    /// cap (~49.5% of liquid above buffer) is not reached; the per-venue cap is.
    function test_perVenueBindsWhileAggregateHasRoom() public {
        _fund(1_000_000e6);
        MockVenue v = _mockVenue();
        _list(address(v));
        vm.prank(treasuryMgr);
        vm.expectRevert(ICreditCore.PerVenueCapExceeded.selector);
        cc.depositToVenue(address(v), 300_000e6); // 30% > 25% per-venue, < 49.5% aggregate
    }

    /// Per-venue satisfied, aggregate violated: three venues at 10% each. An allocation pulls
    /// the aggregate cap down to 24.5% of cash, so the third 10% deposit trips the aggregate
    /// while every venue is still well under the 25% per-venue cap.
    function test_aggregateBindsWhilePerVenueHasRoom() public {
        _fund(1_000_000e6);
        vm.prank(allocationMs);
        cc.allocate(0, 500_000e6, ICreditCore.AllocationType.Growth);

        MockVenue a = _mockVenue();
        MockVenue b = _mockVenue();
        MockVenue c = _mockVenue();
        _list(address(a));
        _list(address(b));
        _list(address(c));

        _deposit(address(a), 100_000e6); // total 100k, aggregate cap ~245k
        _deposit(address(b), 100_000e6); // total 200k

        vm.prank(treasuryMgr);
        vm.expectRevert(ICreditCore.VenueAllocationCapExceeded.selector);
        cc.depositToVenue(address(c), 100_000e6); // venue c at 10% < 25%, but total 300k > 245k
    }

    // -----------------------------------------------------------------
    // 3. Duration limit: 7 days, checked at listing, half-open in seconds
    // -----------------------------------------------------------------

    function test_durationLimit_atExactlyTheLimitListsOverItDoesNot() public {
        MockVenue atLimit = _mockVenue();
        atLimit.setRedeemDelay(DELAY_LIMIT); // exactly 7 days
        _list(address(atLimit));
        assertTrue(cc.isVenue(address(atLimit)));

        MockVenue overLimit = _mockVenue();
        overLimit.setRedeemDelay(DELAY_LIMIT + 1); // one second over
        vm.expectRevert(ICreditCore.VenueRedeemDelayTooLong.selector);
        cc.addVenue(address(overLimit));
    }

    // -----------------------------------------------------------------
    // 4. A venue that does not implement IStrategyDelay cannot be listed
    // -----------------------------------------------------------------

    function test_venueWithoutRedeemDelayCannotBeListed() public {
        NoDelayVenue v = new NoDelayVenue(IERC20(address(usdc)), "N", "N");
        vm.expectRevert(ICreditCore.VenueRedeemDelayUnknown.selector);
        cc.addVenue(address(v));
    }

    // -----------------------------------------------------------------
    // 5. Slippage limit: 50 bps on preview deviation, both paths
    // -----------------------------------------------------------------

    function test_slippage_deposit_atLimitPassesOverReverts() public {
        _fund(5_000_000e6);
        SlippingVenue v = new SlippingVenue(IERC20(address(usdc)), "S", "S");
        _list(address(v));

        // exactly 50 bps shortfall: passes
        v.setDepositFactorBps(9950);
        _deposit(address(v), 1_000_000e6);

        // 51 bps shortfall: reverts
        SlippingVenue w = new SlippingVenue(IERC20(address(usdc)), "S2", "S2");
        _list(address(w));
        w.setDepositFactorBps(9949);
        vm.prank(treasuryMgr);
        vm.expectRevert(ICreditCore.VenueSlippageExceeded.selector);
        cc.depositToVenue(address(w), 1_000_000e6);
    }

    function test_slippage_redeem_atLimitPassesOverReverts() public {
        _fund(5_000_000e6);
        SlippingVenue v = new SlippingVenue(IERC20(address(usdc)), "S", "S");
        _list(address(v));
        _deposit(address(v), 1_000_000e6); // neutral deposit, venue holds 1,000,000e6
        uint256 shares = v.balanceOf(address(cc));

        v.setRedeemFactorBps(9950); // exactly 50 bps
        vm.prank(treasuryMgr);
        cc.withdrawFromVenue(address(v), shares / 2);

        v.setRedeemFactorBps(9949); // 51 bps
        vm.prank(treasuryMgr);
        vm.expectRevert(ICreditCore.VenueSlippageExceeded.selector);
        cc.withdrawFromVenue(address(v), shares / 2);
    }

    // -----------------------------------------------------------------
    // 6. A deviation in the Treasury's favour never reverts, on both paths
    // -----------------------------------------------------------------

    function test_slippage_favourableDirectionNeverReverts() public {
        _fund(5_000_000e6);
        SlippingVenue v = new SlippingVenue(IERC20(address(usdc)), "S", "S");
        _list(address(v));

        // deposit returns 1% MORE shares than previewed
        v.setDepositFactorBps(10_100);
        _deposit(address(v), 1_000_000e6);

        // redeem pays 1% MORE assets than previewed; pre-fund the venue so it can
        uint256 shares = v.balanceOf(address(cc));
        usdc.mint(address(v), 1_000_000e6);
        v.setRedeemFactorBps(10_100);
        vm.prank(treasuryMgr);
        cc.withdrawFromVenue(address(v), shares / 2);
    }

    // -----------------------------------------------------------------
    // 8. removeVenue stays immediate, by the owner (governance)
    // -----------------------------------------------------------------

    function test_removeVenueStillImmediate() public {
        MockVenue v = _mockVenue();
        _list(address(v));
        vm.prank(governance);
        cc.removeVenue(address(v)); // no delay
        assertFalse(cc.isVenue(address(v)));
    }

    function test_addVenueRejectsNonRiskCommittee() public {
        MockVenue v = _mockVenue();
        vm.prank(governance); // owner of CreditCore, but not owner of Config
        vm.expectRevert(ICreditCore.NotRiskCommittee.selector);
        cc.addVenue(address(v));
        vm.prank(treasuryMgr);
        vm.expectRevert(ICreditCore.NotRiskCommittee.selector);
        cc.addVenue(address(v));
    }

    // -----------------------------------------------------------------
    // The per-venue ceiling still binds
    // -----------------------------------------------------------------

    function test_perVenueCap_rejectsHundredPercentAndStillBindsAtCeiling() public {
        // 10_000 bps (100%) is out of range: at that value a venue's exposure, part of the
        // cap's base, could never exceed the cap.
        vm.expectRevert(abi.encodeWithSelector(Config.ValueOutOfBounds.selector, K.PER_VENUE_CAP_BPS));
        config.set(K.PER_VENUE_CAP_BPS, 10_000);

        // At the new ceiling, 5000 bps (50%), the check still fires.
        config.set(K.PER_VENUE_CAP_BPS, 5000);
        _fund(1_000_000e6);
        MockVenue v = _mockVenue();
        _list(address(v));
        // base ~ 1,000,000e6, so the cap is ~500,000e6; a deposit past it reverts.
        vm.prank(treasuryMgr);
        vm.expectRevert(ICreditCore.PerVenueCapExceeded.selector);
        cc.depositToVenue(address(v), 500_000e6 + 1);
    }

    // -----------------------------------------------------------------
    // The redemption delay is re-checked at deposit, not only at listing
    // -----------------------------------------------------------------

    function test_delayGrownAfterListingBlocksDepositsAndStillDelists() public {
        _fund(1_000_000e6);
        MockVenue v = _mockVenue(); // redeemDelay() == 0 at listing
        _list(address(v));
        _deposit(address(v), 100_000e6); // a deposit lands while the delay is within the limit

        v.setRedeemDelay(DELAY_LIMIT + 1); // the venue lengthens its delay past 7 days

        vm.prank(treasuryMgr);
        vm.expectRevert(ICreditCore.VenueRedeemDelayTooLong.selector);
        cc.depositToVenue(address(v), 1e6); // no further money enters

        // the position already there can still be redeemed (no delay check on withdraw)
        uint256 shares = v.balanceOf(address(cc));
        vm.prank(treasuryMgr);
        cc.withdrawFromVenue(address(v), shares);

        // and the listing can be killed immediately, no schedule
        vm.prank(governance);
        cc.removeVenue(address(v));
        assertFalse(cc.isVenue(address(v)));
    }
}
