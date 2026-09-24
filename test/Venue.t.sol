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

/// A stand-in factory: answers isCommunityContract for addresses we register.
contract FactoryStub {
    mapping(address => bool) public isCommunityContract;

    function register(address a) external {
        isCommunityContract[a] = true;
    }
}

contract VenueTest is Test {
    MockUSDC usdc;
    Config config;
    FactoryStub factory;
    Venue vault;
    MockVenue fast;
    MockVenue slow;
    address owner = address(0xA11CE);
    address treasury = address(0x7EA);
    address ledger = address(0x1ED);
    address ledger2 = address(0x1ED2);
    address stranger = address(0xBAD);

    function setUp() public {
        usdc = new MockUSDC();
        address screener = address(new ComplianceRegistry(address(this)));
        vm.prank(owner); // Config takes its owner from msg.sender
        config = new Config(address(usdc), treasury, screener);
        factory = new FactoryStub();
        factory.register(ledger);
        factory.register(ledger2);
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

    function test_deposit_onlyLedger() public {
        vm.expectRevert(IVenue.NotLedger.selector);
        vm.prank(stranger);
        vault.deposit(1e6, stranger);
    }

    function test_deposit_mintsSharesAndTracksLedgerShares() public {
        vm.prank(ledger);
        uint256 shares = vault.deposit(100e6, ledger);
        assertEq(shares, 100e6);
        assertEq(vault.balanceOf(ledger), 100e6);
        assertEq(vault.ledgerShares(ledger), 100e6);
        assertEq(vault.idle(), 100e6);
        assertEq(vault.recognizedAssets(), 100e6);
        assertEq(vault.totalAssets(), 100e6);
    }

    function test_deposit_capEnforced() public {
        vm.prank(owner);
        config.set(keccak256("qudi.GLOBAL_DEPOSIT_CAP"), 50e6);
        vm.expectRevert(IVenue.DepositCapExceeded.selector);
        vm.prank(ledger);
        vault.deposit(51e6, ledger);
    }

    function test_addVenue_tagsTierFromRedeemDelay() public {
        _addBoth();
        assertTrue(vault.isInstant(address(fast)));
        assertFalse(vault.isInstant(address(slow)));
        assertEq(vault.venueCount(), 2);
    }

    function test_setWeights_rejectsSlowAboveCeiling() public {
        vm.startPrank(owner);
        vault.addVenue(address(fast));
        vault.addVenue(address(slow));
        address[] memory vs = new address[](2);
        vs[0] = address(fast);
        vs[1] = address(slow);
        uint16[] memory w = new uint16[](2);
        w[0] = 5000;
        w[1] = 5000; // slow 50% > ceiling 25%
        vm.expectRevert(IVenue.TierLimitBreached.selector);
        vault.setWeights(vs, w);
        vm.stopPrank();
    }

    function test_rebalance_movesTowardWeights() public {
        _addBoth();
        vm.prank(ledger);
        vault.deposit(1_000e6, ledger);
        vault.rebalance();
        assertEq(fast.convertToAssets(fast.balanceOf(address(vault))), 750e6);
        assertEq(slow.convertToAssets(slow.balanceOf(address(vault))), 250e6);
        assertEq(vault.idle(), 0);
        assertEq(vault.totalAssets(), 1_000e6);
    }

    function test_instantLiquidity_isIdlePlusInstantVenues() public {
        _addBoth();
        vm.prank(ledger);
        vault.deposit(1_000e6, ledger);
        vault.rebalance();
        assertEq(vault.instantLiquidity(), 750e6);
        assertEq(vault.maxWithdraw(ledger), 750e6);
    }

    function test_withdraw_pullsFromIdleThenInstant() public {
        _addBoth();
        vm.prank(ledger);
        vault.deposit(1_000e6, ledger);
        vault.rebalance();
        vm.prank(ledger);
        vault.withdraw(700e6, ledger, ledger);
        assertEq(usdc.balanceOf(ledger), 1_000_000e6 - 300e6);
        assertEq(vault.totalAssets(), 300e6);
        assertEq(vault.recognizedAssets(), 300e6);
        // The basis came down with the withdrawal: 50 left in the fast venue, 250 in the slow.
        assertEq(vault.venueBasis(address(fast)), 50e6);
        assertEq(vault.venueBasis(address(slow)), 250e6);
        assertEq(vault.ledgerShares(ledger), 300e6);
        assertEq(vault.totalLedgerShares(), 300e6);
        // idle was 0, so the whole 700e6 came out of the instant venue and the slow one is untouched.
        assertEq(fast.convertToAssets(fast.balanceOf(address(vault))), 50e6);
        assertEq(slow.convertToAssets(slow.balanceOf(address(vault))), 250e6);
    }

    function test_withdraw_beyondInstantReverts() public {
        _addBoth();
        vm.prank(ledger);
        vault.deposit(1_000e6, ledger);
        vault.rebalance();
        vm.expectRevert(IVenue.InsufficientInstantLiquidity.selector);
        vm.prank(ledger);
        vault.withdraw(800e6, ledger, ledger);
    }

    function test_shares_notTransferableToStrangers() public {
        vm.prank(ledger);
        vault.deposit(100e6, ledger);
        vm.expectRevert(IVenue.TransferRestricted.selector);
        vm.prank(ledger);
        vault.transfer(stranger, 1);
    }

    /// Shares move only by mint, burn, or the vault's own bookkeeping. Being on the allowlist is
    /// not enough: a holder-initiated transfer would desync ledgerShares, so it reverts too.
    function test_shares_notTransferableToOtherLedgers() public {
        vm.prank(ledger);
        vault.deposit(100e6, ledger);
        vm.expectRevert(IVenue.TransferRestricted.selector);
        vm.prank(ledger);
        vault.transfer(ledger2, 1);
    }

    /// A venue gain reaches the share price the moment it happens: `totalAssets()` is the live
    /// value: `liveAssets()` marks the venues to what they would pay today, and
    /// `totalAssets()` clamps each venue at its recorded basis, so an unharvested gain is the
    /// gap between the two and is nobody's until a harvest realizes it.
    function test_totalAssets_clampsAnUnharvestedGainAtTheBasis() public {
        _addBoth();
        vm.prank(ledger);
        vault.deposit(1_000e6, ledger);
        vault.rebalance(); // 750e6 into fast, so the gain below lands on shares the vault holds
        usdc.mint(address(fast), 100e6); // venue gain, not yet harvested
        assertApproxEqAbs(vault.liveAssets(), 1_100e6, 1); // OZ 4626 virtual offset rounds down by 1
        assertApproxEqAbs(vault.totalAssets(), 1_000e6, 1);
        assertApproxEqAbs(vault.convertToAssets(1_000e6), 1_000e6, 2);
        assertEq(vault.venueBasis(address(fast)), 750e6);
    }
}
