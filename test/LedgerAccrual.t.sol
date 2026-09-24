// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.30;

import {LedgerFixture} from "./helpers/LedgerFixture.sol";
import {VenueIds} from "./helpers/VenueIds.sol";

/// The split: 30% of every gain above the peak is taken, half for the treasury and half for this
/// community's credit account, and the rest stays with the vaults. The credit half becomes impact
/// the moment it is taken, whether or not its cash has been paid out yet.
///
/// Integer division floors at each step (the gain, each fee, the conversion to shares and back),
/// so each figure below is checked to within `DUST` wei of the exact one: a few millionths of a
/// cent.
contract LedgerAccrualTest is LedgerFixture {
    uint256 constant DUST = 10;
    uint256 vaultId;

    function setUp() public {
        setUpLedger();
        vaultId = _personal(ada, VenueIds.FLEX, 0);
        _deposit(ada, vaultId, 1_000e6);
    }

    // ---- proof 2: the split ----

    /// A gain G above the peak sends 0.15 G to the treasury and 0.15 G to `CreditCore` for this
    /// community, through settlement, and leaves 0.70 G with the vault.
    function test_proof2_aGainIsSplit15To15To70() public {
        uint256 g = 100e6;
        _gain(VenueIds.FLEX, g);
        ledger.accrue();

        assertApproxEqAbs(usdc.balanceOf(treasury), g * 15 / 100, DUST, "treasury gets 15%");
        assertApproxEqAbs(creditCore.legOf(0), g * 15 / 100, DUST, "the credit account gets 15%");
        assertApproxEqAbs(usdc.balanceOf(address(creditCore)), g * 15 / 100, DUST, "and its USDC arrived");
        assertApproxEqAbs(ledger.vaultValue(vaultId), 1_000e6 + g * 70 / 100, DUST, "70% stays with the vault");
        assertApproxEqAbs(ledger.vaultEarned(vaultId), g * 70 / 100, DUST);
        assertEq(ledger.vaultCapital(vaultId), 1_000e6, "capital is what went in");

        (uint256 t, uint256 c) = ledger.pendingFees(VenueIds.FLEX);
        assertEq(t + c, 0, "a liquid venue pays the fees in the same call");
        assertEq(ledger.venueShares(VenueIds.FLEX), flexVault.balanceOf(address(ledger)));
    }

    /// The split is charged on any interaction, not only `accrue`: a deposit charges the gain made
    /// before it, so the depositor's new money is not charged for it.
    function test_proof2_aDepositChargesTheGainBeforeIt() public {
        _gain(VenueIds.FLEX, 100e6);
        _deposit(ada, vaultId, 500e6);
        assertApproxEqAbs(usdc.balanceOf(treasury), 15e6, DUST);
        assertApproxEqAbs(ledger.vaultValue(vaultId), 1_570e6, DUST);
    }

    /// With nothing gained, nothing is charged, however often it accrues.
    function test_proof2_noGainNoFee() public {
        ledger.accrue();
        vm.warp(block.timestamp + 30 days);
        ledger.accrue();
        assertEq(usdc.balanceOf(treasury), 0);
        assertEq(ledger.totalImpact(), 0);
    }

    // ---- proof 3: the high-water mark ----

    /// After a loss, the recovery back to the old peak is charged nothing. Only the gain above the
    /// peak is charged.
    function test_proof3_aRecoveryToThePeakIsNotCharged() public {
        _gain(VenueIds.FLEX, 100e6);
        ledger.accrue();
        uint256 peak = ledger.highWaterPrice(VenueIds.FLEX);
        uint256 treasuryAtPeak = usdc.balanceOf(treasury);
        uint256 impactAtPeak = ledger.totalImpact();
        assertApproxEqAbs(impactAtPeak, 15e6, DUST);

        // Lose 200 of the 1,070 the vault holds.
        _loss(VenueIds.FLEX, 200e6);
        ledger.accrue();
        assertLt(flexVault.convertToAssets(1e18), peak, "the loss is in the price");
        assertEq(ledger.highWaterPrice(VenueIds.FLEX), peak, "a loss never lowers the peak");
        assertEq(ledger.totalImpact(), impactAtPeak, "a loss is not charged");

        // Win the 200 back. The price returns to the peak and nothing is charged.
        usdc.mint(address(this), 200e6);
        usdc.approve(address(flexVenue), 200e6);
        flexVenue.fund(200e6);
        ledger.accrue();
        assertApproxEqAbs(flexVault.convertToAssets(1e18), peak, 1e9, "back at the peak");
        assertApproxEqAbs(ledger.totalImpact(), impactAtPeak, DUST, "the recovery is charged nothing");
        assertApproxEqAbs(usdc.balanceOf(treasury), treasuryAtPeak, DUST);

        // Gain 107 above the peak, 10% of the 1,070 held. Only that is charged.
        _gain(VenueIds.FLEX, 107e6);
        ledger.accrue();
        assertApproxEqAbs(ledger.totalImpact() - impactAtPeak, 16_050_000, DUST, "15% of the gain above the peak");
        assertApproxEqAbs(usdc.balanceOf(treasury) - treasuryAtPeak, 16_050_000, DUST);
        assertApproxEqAbs(ledger.vaultValue(vaultId), 1_070e6 + 74_900_000, DUST);
    }

    /// A gain made before the community held anything in a venue is not charged: the peak starts
    /// at the price when the community first uses the venue.
    function test_proof3_aGainBeforeTheCommunityArrivedIsNotCharged() public {
        // Other money in Core gains 10% before this community opens a Core vault.
        usdc.mint(address(this), 1_000e6);
        usdc.approve(address(coreVault), 1_000e6);
        coreVault.fundReserve(1_000e6);
        _gain(VenueIds.CORE, 100e6);

        uint256 id = _personal(bea, VenueIds.CORE, 0);
        _deposit(bea, id, 1_000e6);
        ledger.accrue();
        assertEq(ledger.totalImpact(), 0, "the gain before arrival is not charged");
        assertEq(usdc.balanceOf(treasury), 0);
        assertApproxEqAbs(ledger.vaultValue(id), 1_000e6, DUST);
    }

    // ---- a closed credit account ----

    /// Once `CreditCore` has closed this community's credit account, the credit share of the fee
    /// goes to the treasury with the treasury's own share, the way a closed community's balance
    /// returns to it. Nothing waits in the pending bucket for an account that will never take it.
    function test_settlement_aClosedCreditAccountsShareGoesToTheTreasury() public {
        creditCore.close(0);
        _gain(VenueIds.FLEX, 100e6);
        ledger.accrue();

        assertApproxEqAbs(usdc.balanceOf(treasury), 30e6, DUST, "both 15% shares reach the treasury");
        assertEq(creditCore.legOf(0), 0, "the closed account is not booked");
        assertEq(usdc.balanceOf(address(creditCore)), 0, "and no USDC is sent to it");
        (uint256 t, uint256 c) = ledger.pendingFees(VenueIds.FLEX);
        assertEq(t + c, 0, "nothing is left pending");
        assertApproxEqAbs(ledger.vaultValue(vaultId), 1_070e6, DUST, "the vault's 70% is unchanged");
    }

    /// A credit share that was waiting when the account closed goes to the treasury too.
    function test_settlement_aShareWaitingWhenTheAccountClosesGoesToTheTreasury() public {
        _illiquid(VenueIds.FLEX);
        _gain(VenueIds.FLEX, 100e6);
        ledger.accrue();
        (, uint256 c) = ledger.pendingFees(VenueIds.FLEX);
        assertGt(c, 0, "the credit share is waiting");

        creditCore.close(0);
        _liquid(VenueIds.FLEX);
        ledger.settleFees();
        assertApproxEqAbs(usdc.balanceOf(treasury), 30e6, DUST);
        assertEq(creditCore.legOf(0), 0);
    }

    // ---- proof 4: fee settlement can wait ----

    /// When the venue cannot pay, the fee waits in the pending bucket and settles later. The impact
    /// was recorded at accrual either way, and the member's own actions never wait on it.
    function test_proof4_aFeeWaitsForTheVenueAndImpactDoesNot() public {
        _illiquid(VenueIds.FLEX);
        _gain(VenueIds.FLEX, 100e6);
        ledger.accrue();

        (uint256 t, uint256 c) = ledger.pendingFees(VenueIds.FLEX);
        assertGt(t, 0, "the treasury's fee waits");
        assertGt(c, 0, "the credit fee waits");
        assertEq(usdc.balanceOf(treasury), 0, "nothing paid yet");
        assertEq(creditCore.legOf(0), 0);
        assertApproxEqAbs(ledger.totalImpact(), 15e6, DUST, "impact was recorded at accrual");
        assertApproxEqAbs(ledger.impactOf(ada), 15e6, DUST, "and it is already the owner's");
        assertApproxEqAbs(ledger.vaultValue(vaultId), 1_070e6, DUST, "the vault already paid its share");

        // Settling now pays nothing, and fails nobody.
        ledger.settleFees();
        assertEq(usdc.balanceOf(treasury), 0, "still nothing the venue could pay");

        // A member's own action goes through while the fee waits. Its cash lands idle in the
        // venue, so settlement pays what that cash allows and leaves the rest pending.
        _deposit(ada, vaultId, 10e6);
        assertLe(usdc.balanceOf(treasury), 5e6, "no more than the new cash could pay");

        _liquid(VenueIds.FLEX);
        ledger.settleFees();
        assertApproxEqAbs(usdc.balanceOf(treasury), 15e6, DUST, "the treasury is paid later");
        assertApproxEqAbs(creditCore.legOf(0), 15e6, DUST, "and so is the credit account");
        (t, c) = ledger.pendingFees(VenueIds.FLEX);
        assertEq(t + c, 0, "nothing is lost");
        assertApproxEqAbs(ledger.totalImpact(), 15e6, DUST, "settling does not change impact");
    }
}
