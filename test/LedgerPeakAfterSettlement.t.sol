// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.30;

import {console} from "forge-std/console.sol";
import {LedgerFixture} from "./helpers/LedgerFixture.sol";
import {VenueIds} from "./helpers/VenueIds.sol";

/// A known defect, accepted for the Arc testnet beta only and to be fixed before mainnet.
///
/// `Ledger._touch` sets the venue's peak price when it accrues and only then settles the pending
/// fee shares. Redeeming those shares rounds in the Venue's favour (a floor, and ERC-4626's one
/// virtual share and asset), so the price the remaining shares see ends a little above the peak
/// just set. A deposit in the same call buys at that higher price, and the next accrual charges
/// 30% of the difference as a gain on every share, the new depositor's included. The new money is
/// charged a fee on a gain made before it arrived.
///
/// With a Venue of any size the difference is rounding dust: about 0.3 x deposit / Venue supply,
/// in wei. It becomes money when the settlement redeems nearly the whole Venue: a venue that
/// members have emptied while this ledger's fees were stuck behind an illiquid queue. Then the
/// leftover wei are priced against no shares at all, and the price the next depositor pays can be
/// far above the peak. This test builds that case and prices it in dollars. When the defect is
/// fixed, its last assertion fails and the test should become the proof that nothing is charged.
contract LedgerPeakAfterSettlementTest is LedgerFixture {
    uint256 constant DEPOSIT = 5_000e6;

    function setUp() public {
        setUpLedger();
    }

    function test_knownDefect_aDrainedVenueChargesTheNextDepositForARoundingGain() public {
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

        // A new member deposits. The deposit accrues (no units, so no fee, and the peak is set at
        // the price now), then settles the fee shares, which leaves the leftover wei priced
        // against almost no shares, and only then buys in.
        uint256 peak = flexVault.convertToAssets(1e18);
        uint256 id = _personal(cid, flex, 0);
        _deposit(cid, id, DEPOSIT);
        uint256 bought = flexVault.convertToAssets(1e18);
        assertEq(ledger.highWaterPrice(flex), peak, "the peak was set before the settlement");
        assertGt(bought, peak, "the depositor bought above the peak");

        // The value view already includes what an accrual now would charge, so the loss shows at
        // once, against a capital that is exactly the deposit.
        uint256 lost = DEPOSIT - ledger.vaultValue(id);
        uint256 treasuryBefore = usdc.balanceOf(treasury);
        uint256 creditBefore = creditCore.legOf(0);
        ledger.accrue();
        uint256 toTreasury = usdc.balanceOf(treasury) - treasuryBefore;
        uint256 toCredit = creditCore.legOf(0) - creditBefore;

        console.log("peak price, per 1e18 shares: ", peak);
        console.log("price the depositor paid:    ", bought);
        console.log("deposit, USDC wei:            ", DEPOSIT);
        console.log("value lost, USDC wei:         ", lost);
        console.log("paid to the treasury:         ", toTreasury);
        console.log("paid to the credit account:   ", toCredit);

        // Today's behaviour, which the fix must remove: a fresh deposit in a venue with no loss
        // and no gain since it arrived is worth less than it put in. Here it is about a seventh of
        // the deposit, and the two fees account for it.
        assertEq(ledger.vaultCapital(id), DEPOSIT);
        assertGt(lost, DEPOSIT / 10, "the known defect: a fresh deposit is charged for a rounding gain");
        assertApproxEqAbs(toTreasury + toCredit, lost, 10, "the fees are the loss");
    }
}
