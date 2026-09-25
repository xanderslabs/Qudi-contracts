// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.30;

import {console} from "forge-std/console.sol";
import {LedgerFixture} from "./helpers/LedgerFixture.sol";
import {VenueIds} from "./helpers/VenueIds.sol";

/// A fee is charged only on gain above the previous peak, and gain means the venue's value grew.
///
/// Settling the fee shares redeems them from the Venue, and the redemption rounds in the Venue's
/// favour (a floor, and ERC-4626's one virtual share and asset). So the price the remaining shares
/// see ends a little above the peak the accrual just set. That rise is the ledger's own rounding,
/// not gain. If the peak stayed where the accrual left it, the next accrual would charge 30% of the
/// rise on every share, including shares a depositor bought after it.
///
/// With a Venue of any size the rise is dust. It becomes money when the settlement redeems nearly
/// the whole Venue: the leftover wei are then priced against almost no shares, and the next
/// depositor would pay a real fee on a gain that never happened. These tests build that case and
/// price it in dollars, and show that a real gain is still charged in full around a settlement.
contract LedgerPeakAfterSettlementTest is LedgerFixture {
    uint256 constant DEPOSIT = 5_000e6;
    uint256 constant DUST = 10;

    function setUp() public {
        setUpLedger();
    }

    /// Everything the ledger has charged so far: paid to the treasury and the credit account, plus
    /// the fee shares still pending, at the price now.
    function _charged(uint8 venueId) internal view returns (uint256) {
        (uint256 t, uint256 c) = ledger.pendingFees(venueId);
        return usdc.balanceOf(treasury) + creditCore.legOf(0) + tierVaults[venueId].convertToAssets(t + c);
    }

    function test_proof1_aDrainedVenueChargesTheNextDepositNothing() public {
        uint8 flex = VenueIds.FLEX;
        uint256 a = _personal(ada, flex, 0);
        uint256 b = _personal(bea, flex, 0);
        _deposit(ada, a, 1_000e6);
        _deposit(bea, b, 1_000e6);
        // A real gain, a year for the growth cap to pass it.
        _gain(flex, 100e6);

        // Every dollar sits in the strategy, which gives nothing back for now. Both members ask for
        // everything: the first request charges the gain, and the fee shares cannot be paid out,
        // so they wait as pending fees while both requests wait in the queue.
        _illiquid(flex);
        _withdraw(bea, b, ledger.vaultValue(b));
        _withdraw(ada, a, ledger.vaultValue(a));
        (uint256 t, uint256 c) = ledger.pendingFees(flex);
        assertGt(t + c, 0, "the fee shares are stuck");

        // The strategy pays again and the queue pays both members out. The Venue now holds only
        // this ledger's pending fee shares and the wei its roundings kept.
        _liquid(flex);
        flexVault.processQueue(10);
        assertEq(flexVault.totalSupply(), t + c, "only the fee shares are left");

        // A new member deposits. The deposit accrues (no units, so no fee), settles the fee shares,
        // which leaves the leftover wei priced against almost no shares, and only then buys in. The
        // settlement lifts the peak to the price it leaves, so the depositor buys at the peak.
        uint256 peakBefore = flexVault.convertToAssets(1e18);
        uint256 id = _personal(cid, flex, 0);
        _deposit(cid, id, DEPOSIT);
        uint256 peak = ledger.highWaterPrice(flex);
        (t, c) = ledger.pendingFees(flex);
        assertEq(t + c, 0, "the fee shares are paid out");
        assertGt(peak, peakBefore, "the settlement's rounding lifted the peak");
        console.log("peak price before, per 1e18:  ", peakBefore);
        console.log("peak price after settlement:  ", peak);
        console.log("price the depositor paid:     ", flexVault.convertToAssets(1e18));

        t = usdc.balanceOf(treasury);
        c = creditCore.legOf(0);
        ledger.accrue();
        t = usdc.balanceOf(treasury) - t;
        c = creditCore.legOf(0) - c;
        uint256 value = ledger.vaultValue(id);

        console.log("deposit, USDC wei:            ", DEPOSIT);
        console.log("value now, USDC wei:          ", value);
        console.log("value lost, USDC wei:         ", DEPOSIT > value ? DEPOSIT - value : 0);
        console.log("paid to the treasury:         ", t);
        console.log("paid to the credit account:   ", c);

        // Nothing is charged, and the fresh deposit is worth what it put in, to the wei the
        // Venue's own share rounding keeps.
        assertEq(t, 0, "no fee to the treasury");
        assertEq(c, 0, "no fee to the credit account");
        assertEq(ledger.highWaterPrice(flex), peak, "the accrual found no gain");
        assertEq(ledger.vaultCapital(id), DEPOSIT);
        assertApproxEqAbs(value, DEPOSIT, DUST, "a fresh deposit keeps its value");
    }

    /// `settleFees` is public and can run long after the last accrual. A real gain since then is
    /// charged before the settlement moves the peak, so lifting the peak for rounding never skips
    /// a gain.
    function test_proof2_aRealGainBeforeAStandaloneSettlementIsStillCharged() public {
        uint8 flex = VenueIds.FLEX;
        uint256 a = _personal(ada, flex, 0);
        _deposit(ada, a, 1_000e6);

        // The first gain is charged, and its fee shares wait: the venue pays nobody.
        _illiquid(flex);
        _gain(flex, 50e6);
        ledger.accrue();
        (uint256 t, uint256 c) = ledger.pendingFees(flex);
        assertGt(t + c, 0, "the first fees are pending");
        uint256 firstCharge = _charged(flex);
        assertApproxEqAbs(firstCharge, 15e6, DUST, "30% of the first gain");

        // A second real gain, then a standalone settlement with no accrual before it. The pending
        // fee shares are Venue shares, so they earn their part of it; the member's part is charged.
        _liquid(flex);
        uint256 memberBefore = ledger.vaultValue(a);
        uint256 venueBefore = flexVault.totalAssets();
        _gain(flex, 50e6);
        uint256 memberGain = 50e6 * memberBefore / venueBefore;
        ledger.settleFees();
        (t, c) = ledger.pendingFees(flex);
        assertEq(t + c, 0, "everything is paid out");
        uint256 paid = usdc.balanceOf(treasury) + creditCore.legOf(0);
        assertApproxEqAbs(ledger.vaultValue(a), memberBefore + memberGain * 7_000 / 10_000, DUST, "70% kept");
        assertApproxEqAbs(paid + ledger.vaultValue(a), 1_100e6, DUST, "every dollar is the member's or paid");

        // Nothing is left to charge afterwards, and nothing was skipped.
        ledger.accrue();
        assertEq(usdc.balanceOf(treasury) + creditCore.legOf(0), paid, "nothing more to charge");
        assertApproxEqAbs(usdc.balanceOf(treasury), creditCore.legOf(0), 2, "half each");
    }

    /// After a loss, a settlement below the old peak charges nothing and leaves the peak where it
    /// was, so nothing is charged until the price passes the peak again.
    function test_proof3_aLossThenRecoveryThenSettlementChargesNothingUntilThePeak() public {
        uint8 flex = VenueIds.FLEX;
        uint256 a = _personal(ada, flex, 0);
        _deposit(ada, a, 1_000e6);

        // A gain is charged, and its fees wait.
        _illiquid(flex);
        _gain(flex, 100e6);
        ledger.accrue();
        uint256 peak = ledger.highWaterPrice(flex);
        uint256 charged = _charged(flex);
        assertApproxEqAbs(charged, 30e6, DUST);

        // A loss, then a recovery that stays below the peak, then a standalone settlement.
        _loss(flex, 200e6);
        _liquid(flex);
        _gain(flex, 150e6);
        assertLt(flexVault.convertToAssets(1e18), peak, "still below the peak");
        uint256 paidBefore = usdc.balanceOf(treasury) + creditCore.legOf(0);
        ledger.settleFees();
        (uint256 t, uint256 c) = ledger.pendingFees(flex);
        assertEq(t + c, 0, "the old fees are paid out");
        assertEq(ledger.highWaterPrice(flex), peak, "the peak did not move");
        // The old fee shares are paid at today's lower price, and nothing new is charged.
        assertLe(usdc.balanceOf(treasury) + creditCore.legOf(0) - paidBefore, charged, "only the old fees");
        ledger.accrue();
        assertEq(ledger.highWaterPrice(flex), peak, "no charge below the peak");

        // Past the peak, only the part above it is charged.
        uint256 paid = usdc.balanceOf(treasury) + creditCore.legOf(0);
        _gain(flex, 200e6);
        uint256 price = flexVault.convertToAssets(1e18);
        assertGt(price, peak);
        uint256 shares = ledger.venueShares(flex);
        ledger.accrue();
        uint256 expected = shares * (price - peak) / 1e18 * 3_000 / 10_000;
        assertApproxEqAbs(usdc.balanceOf(treasury) + creditCore.legOf(0) - paid, expected, DUST, "30% above the peak");
    }
}
