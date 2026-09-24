// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {Venue} from "../src/Venue.sol";
import {IVenue} from "../src/interfaces/IVenue.sol";
import {Config} from "../src/Config.sol";
import {IConfig} from "../src/interfaces/IConfig.sol";
import {ComplianceRegistry} from "../src/ComplianceRegistry.sol";
import {PoolTypes} from "../src/PoolTypes.sol";
import {MockUSDC} from "./mocks/MockUSDC.sol";
import {MockVenue} from "./mocks/MockVenue.sol";
import {FactoryStub} from "./Venue.t.sol";

/// Asymmetric recognition from the members' side: what a newcomer buys at, what
/// an exit is paid, and who carries a loss. The rule under all of it is
/// `totalAssets = idle + sum min(basis, live) - unreleased`, so a venue gain is outside the price
/// until a harvest realizes it and a venue loss is inside it in the block it happens.
///
/// The nine properties themselves are in VenueHarvest.t.sol; this file is the surrounding
/// behaviour the rewrite had to keep working.
contract VenueLiveTest is Test {
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

    function _staked(address who, uint256 assets) internal returns (uint256 shares) {
        vm.prank(who);
        shares = vault.deposit(assets, who);
        vault.rebalance();
    }

    /// A venue gain does not reach the price on its own. `liveAssets()` sees it; `totalAssets()`
    /// does not, because it is above the recorded basis and no harvest has realized it.
    function test_price_doesNotMoveOnAnUnharvestedGain() public {
        _staked(ledger, 1_000e6);
        venue.fund(100e6); // +10%
        assertApproxEqAbs(vault.liveAssets(), 1_100e6, 2);
        assertApproxEqAbs(vault.totalAssets(), 1_000e6, 2);
        assertApproxEqAbs(vault.convertToAssets(1_000e6), 1_000e6, 2);
    }

    /// A venue loss reaches it at once, with no harvest and no touch of any kind.
    function test_price_dropsOnALossWithNoTouch() public {
        _staked(ledger, 1_000e6);
        venue.skim(100e6); // -10%
        assertApproxEqAbs(vault.totalAssets(), 900e6, 2);
        assertApproxEqAbs(vault.convertToAssets(1_000e6), 900e6, 2);
    }

    /// An exit between harvests takes its share of a live loss on the way out, and leaves the
    /// stayer no worse off.
    function test_exitBetweenHarvests_paysItsShareOfALiveLoss() public {
        _staked(ledger, 1_000e6);
        _staked(ledger2, 1_000e6);
        venue.skim(200e6); // -10%, no reserve
        uint256 before = usdc.balanceOf(ledger);
        vm.prank(ledger);
        vault.redeem(1_000e6, ledger, ledger); // the first to leave
        assertApproxEqAbs(usdc.balanceOf(ledger) - before, 900e6, 3);
        assertApproxEqAbs(vault.convertToAssets(1_000e6), 900e6, 3);
    }

    /// A newcomer arriving on top of an unharvested gain neither buys into it nor is charged for
    /// it: the price is the same for both of them, and the gain is still whole afterwards.
    function test_depositOnTopOfAnUnharvestedGain_buysAtTheUnmovedPrice() public {
        _staked(ledger, 1_000e6);
        venue.fund(100e6); // earned while ledger alone was in
        vm.prank(ledger2);
        uint256 s2 = vault.deposit(1_000e6, ledger2);
        assertApproxEqAbs(s2, 1_000e6, 2, "the price did not step for the newcomer");
        vault.rebalance();
        vault.harvest(address(venue));
        vm.warp(block.timestamp + _unlockWindow());
        // The 70 member leg is then shared by the two equal holders, which is the price of
        // recognizing at harvest rather than continuously. Attribution is time-weighted,
        // which is what actually decides who earned it; the share price is not that mechanism.
        assertApproxEqAbs(vault.convertToAssets(s2), 1_035e6, 3);
        assertApproxEqAbs(vault.convertToAssets(1_000e6), 1_035e6, 3);
    }

    /// The reserve absorbs a venue loss at the first touch, keeping the members whole up to the
    /// reserve's own size. `totalAssets()` still falls by the whole loss: burning shares moves
    /// the price, never the assets.
    function test_lossWithReserve_reserveBurnsOnFirstTouch() public {
        _staked(ledger, 1_000e6);
        usdc.mint(owner, 50e6);
        vm.startPrank(owner);
        usdc.approve(address(vault), 50e6);
        vault.fundReserve(50e6);
        vm.stopPrank();
        vault.rebalance();

        uint256 totalBefore = vault.totalAssets();
        venue.skim(30e6);
        assertApproxEqAbs(vault.totalAssets(), totalBefore - 30e6, 3, "the whole loss, immediately");

        vault.settle();
        assertApproxEqAbs(vault.convertToAssets(1_000e6), 1_000e6, 3, "members whole");
        assertApproxEqAbs(vault.convertToAssets(vault.reserveShares()), 20e6, 3, "the reserve took it");
        assertApproxEqAbs(vault.venueBasis(address(venue)), 1_020e6, 3, "and the venue is written down");
    }

    /// A loss is written down rather than left as a mark, so a later recovery in the same venue
    /// cannot hand the price back what the reserve already paid for.
    function test_lossIsWrittenDownNotMarked() public {
        _staked(ledger, 1_000e6);
        venue.skim(100e6);
        vault.settle();
        assertApproxEqAbs(vault.venueBasis(address(venue)), 900e6, 2);
        venue.fund(100e6); // back to where it started
        assertApproxEqAbs(vault.totalAssets(), 900e6, 2, "a recovery is an unharvested gain like any other");
    }

    /// report() is the absorb plus the keeper's event; it never moves the price by itself.
    function test_report_isAbsorbPlusEvent_noPriceStep() public {
        _staked(ledger, 1_000e6);
        venue.fund(100e6);
        uint256 pBefore = vault.convertToAssets(1e6);
        vault.report();
        assertEq(vault.convertToAssets(1e6), pBefore);
        uint256 supply = vault.totalSupply();
        vault.report();
        assertEq(vault.totalSupply(), supply, "and it is idempotent");
    }

    /// A donated-up empty vault would mint the first depositor zero shares and lose them the lot.
    /// The deposit reverts instead, and one large enough to be worth a share still goes through.
    function test_deposit_zeroShares_reverts() public {
        usdc.mint(address(vault), 1_000e6); // donated into the empty vault
        vm.prank(ledger);
        vm.expectRevert(IVenue.ZeroShares.selector);
        vault.deposit(100e6, ledger);
        vm.prank(ledger);
        uint256 shares = vault.deposit(2_000e6, ledger);
        assertGt(shares, 0);
        assertEq(vault.balanceOf(ledger), shares);
    }

    /// `fundReserve` mints straight through `_mint`, so it needs the guard `_deposit` has: it is
    /// the path a deployment seeds through, and a seed that bought nothing would hand the vault
    /// free USDC and leave the price exactly as unbuyable as it was.
    function test_fundReserve_zeroShares_reverts() public {
        usdc.mint(address(vault), 1_000e6); // donated into the empty vault
        usdc.mint(owner, 2_000e6);
        vm.startPrank(owner);
        usdc.approve(address(vault), type(uint256).max);
        vm.expectRevert(IVenue.ZeroShares.selector);
        vault.fundReserve(1e6);
        vault.fundReserve(2_000e6);
        vm.stopPrank();
        assertGt(vault.reserveShares(), 0);
    }

    /// The queue prices at fulfillment. A request standing across a harvest collects what
    /// the unlock has released by the time it is paid, not the pre-harvest price.
    function test_processQueue_pricesAtFulfilment() public {
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
