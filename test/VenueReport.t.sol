// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {Venue} from "../src/Venue.sol";
import {IVenue} from "../src/interfaces/IVenue.sol";
import {Config} from "../src/Config.sol";
import {ConfigKeys} from "../src/ConfigKeys.sol";
import {IConfig} from "../src/interfaces/IConfig.sol";
import {ComplianceRegistry} from "../src/ComplianceRegistry.sol";
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

/// The 70/15/15 split at a harvest, the per-community credit-leg index that survives it,
/// and the reserve's loss-burn. The split is now an asset skim rather than a fee-share mint, so
/// every figure here is USDC.
contract VenueReportTest is Test {
    MockUSDC usdc;
    Config config;
    FactoryStub factory;
    Venue vault;
    MockVenue venue;
    address owner = address(0xA11CE);
    address treasury = address(0x7EA);
    address ledger = address(0x1ED);
    address ledger2 = address(0x2ED);
    address creditPool = address(0xC0DE);

    function setUp() public {
        usdc = new MockUSDC();
        address screener = address(new ComplianceRegistry(address(this)));
        vm.prank(owner); // Config takes its owner from msg.sender
        config = new Config(address(usdc), treasury, screener);
        factory = new FactoryStub();
        factory.register(ledger);
        factory.register(ledger2);
        factory.register(creditPool);
        // The credit leg's destination is `Config.CREDIT_CORE` now, not any address the
        // factory registry vouches for (`CreditCore` is a singleton, never a community contract), so
        // the fixture's stand-in pool has to be the configured one.
        vm.prank(owner);
        config.setAddress(ConfigKeys.CREDIT_CORE, creditPool);
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
        usdc.mint(ledger2, 1_000_000e6);
        usdc.mint(address(this), 1_000_000e6);
        vm.prank(ledger);
        usdc.approve(address(vault), type(uint256).max);
        vm.prank(ledger2);
        usdc.approve(address(vault), type(uint256).max);
        usdc.approve(address(venue), type(uint256).max);
        vm.warp(365 days);
    }

    function _staked(address who, uint256 assets) internal {
        vm.prank(who);
        vault.deposit(assets, who);
        vault.rebalance();
    }

    function test_harvest_splitsGain_70_15_15_inUsdc() public {
        _staked(ledger, 1_000e6);
        venue.fund(100e6); // +10%
        vault.harvest(address(venue));

        // Members keep 70 of 100, released over the unlock rather than in this block.
        assertApproxEqAbs(vault.unreleasedProfit(), 70e6, 2);
        vm.warp(block.timestamp + _unlockWindow());
        assertApproxEqAbs(vault.convertToAssets(1_000e6), 1_070e6, 3);

        // Protocol leg 15 and credit leg 15, both USDC, neither a share position.
        assertApproxEqAbs(vault.protocolHolding(), 15e6, 2);
        assertApproxEqAbs(vault.poolHolding(), 15e6, 2);
        assertEq(vault.balanceOf(treasury), 0);
        assertEq(vault.reserveShares(), 0);

        vault.claimProtocolLeg();
        assertApproxEqAbs(usdc.balanceOf(treasury), 15e6, 2);
        vm.prank(ledger);
        uint256 poolAssets = vault.claimPoolLeg(creditPool);
        assertApproxEqAbs(poolAssets, 15e6, 3);
        assertEq(usdc.balanceOf(creditPool), poolAssets);
    }

    function test_harvest_noGain_reverts() public {
        _staked(ledger, 1_000e6);
        vm.expectRevert(IVenue.NothingToHarvest.selector);
        vault.harvest(address(venue));
    }

    function test_harvest_unknownVenueReverts() public {
        vm.expectRevert(IVenue.UnknownVenue.selector);
        vault.harvest(address(0xDEAD));
    }

    function test_claimProtocolLeg_nothingToClaimReverts() public {
        vm.expectRevert(IVenue.NothingToClaim.selector);
        vault.claimProtocolLeg();
    }

    function test_lossBurnsReserveFirst() public {
        _staked(ledger, 1_000e6);
        usdc.mint(owner, 50e6);
        vm.startPrank(owner);
        usdc.approve(address(vault), 50e6);
        vault.fundReserve(50e6);
        vm.stopPrank();
        vault.rebalance();

        venue.skim(30e6);
        vault.report();
        assertApproxEqAbs(vault.convertToAssets(1_000e6), 1_000e6, 3);
        assertApproxEqAbs(vault.convertToAssets(vault.reserveShares()), 20e6, 3);
    }

    /// QV-94: the reserve burn is valued at the PRE-loss price, and that only shows when the
    /// price is not 1:1. `test_lossBurnsReserveFirst` stakes 1,000 against a 50 reserve, so
    /// supply and total assets are both 1,050 and `loss.mulDiv(supply, preTotal)` equals `loss`:
    /// a mutant returning the loss unchanged is indistinguishable there. Harvesting a gain first
    /// moves the price off 1, and then the two differ.
    ///
    /// The property asserted is the one the function exists for: a loss the reserve can absorb
    /// leaves the member price exactly where it stood. Valuing the burn at the post-loss price
    /// would burn too few shares and leave members short.
    ///
    /// Its coverage went with the deleted early-break tests, and it carried no `test` field,
    /// so nothing pointed at the gap until the gate did.
    function test_lossInsideTheReserveIsBurnedAtThePreLossPrice() public {
        _staked(ledger, 1_000e6);
        usdc.mint(owner, 50e6);
        vm.startPrank(owner);
        usdc.approve(address(vault), 50e6);
        vault.fundReserve(50e6);
        vm.stopPrank();

        // Move the price off 1:1 before the loss lands.
        venue.fund(100e6);
        vault.harvest(address(venue));
        vm.warp(block.timestamp + _unlockWindow());
        vault.rebalance();

        uint256 priceBefore = vault.convertToAssets(1_000e6);
        uint256 reserveBefore = vault.reserveShares();
        assertGt(priceBefore, 1_000e6, "the gain must have moved the price, or this proves nothing");

        // Smaller than the reserve, so the burn is the figure under test rather than the clamp.
        venue.skim(20e6);
        vault.report();

        assertApproxEqAbs(vault.convertToAssets(1_000e6), priceBefore, 3, "members were made whole");
        assertLt(vault.reserveShares(), reserveBefore, "the reserve paid for it");
    }

    function test_lossBeyondReserveHitsEveryone() public {
        _staked(ledger, 1_000e6);
        venue.skim(100e6);
        vault.report();
        assertApproxEqAbs(vault.convertToAssets(1_000e6), 900e6, 3);
        assertEq(vault.reserveShares(), 0);
    }

    /// The per-community index survives the move to assets. A ledger claims its own
    /// accrual, sized by its share of the ledger book when the harvest landed.
    function test_poolLegIndex_isPerLedgerShare() public {
        _staked(ledger, 1_000e6);
        _staked(ledger2, 3_000e6);
        venue.fund(400e6); // +10%
        vault.harvest(address(venue));

        vm.prank(ledger);
        uint256 a = vault.claimPoolLeg(creditPool);
        vm.prank(ledger2);
        uint256 b = vault.claimPoolLeg(creditPool);
        assertApproxEqAbs(b, a * 3, 4); // the credit leg splits 1:3 by ledger shares
        assertApproxEqAbs(a + b, 60e6, 4); // 15% of the 400 gain
    }

    /// An empty vault has no price to move and nothing to harvest; the first deposit still has
    /// to be worth a share against whatever is sitting there.
    function test_emptyVault_marksValueAndMintsNothing() public {
        usdc.mint(address(vault), 100e6);
        vault.report();
        assertEq(vault.totalAssets(), 100e6);
        assertEq(vault.totalSupply(), 0);
        vm.prank(ledger);
        vm.expectRevert(IVenue.ZeroShares.selector);
        vault.deposit(100e6, ledger);
    }

    /// A holder already queued when a harvest lands collects the member leg through the
    /// price at fulfillment, and nothing of the two skimmed legs.
    function test_queuedRequest_paysAtTheFulfilmentPrice() public {
        _staked(ledger, 1_000e6);
        vm.prank(ledger);
        vault.requestRedeem(1_000e6, ledger);
        venue.fund(100e6);
        vault.harvest(address(venue));
        vm.warp(block.timestamp + _unlockWindow());
        vault.processQueue(1);
        assertApproxEqAbs(usdc.balanceOf(ledger), 1_000_000e6 - 1_000e6 + 1_070e6, 3);
    }

    function _unlockWindow() internal view returns (uint64 w) {
        (w,,) = config.yieldEngine();
    }

    function _harvestWindow() internal view returns (uint64 w) {
        (, w,) = config.yieldEngine();
    }
}
