// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.30;

import {LedgerFixture} from "./helpers/LedgerFixture.sol";
import {VenueIds} from "./helpers/VenueIds.sol";

/// Impact: the credit share of the yield, split per vault by units, and within a shared vault by
/// what each depositor put in. It is the ledger's input to a member's credit line, so a member
/// must get exactly their part: no more for arriving late, no less for sharing a vault.
contract LedgerImpactTest is LedgerFixture {
    uint256 constant DUST = 10;

    function setUp() public {
        setUpLedger();
    }

    // ---- proof 5: personal ----

    /// Two personal vaults with equal units earn equal impact from the same gain.
    function test_proof5_equalUnitsEarnEqualImpact() public {
        uint256 a = _personal(ada, VenueIds.FLEX, 0);
        uint256 b = _personal(bea, VenueIds.FLEX, 0);
        _deposit(ada, a, 500e6);
        _deposit(bea, b, 500e6);
        assertEq(ledger.vaultUnits(a), ledger.vaultUnits(b));

        _gain(VenueIds.FLEX, 100e6);
        assertApproxEqAbs(ledger.impactOf(ada), 7_500_000, DUST, "pending impact is already visible");
        ledger.accrue();
        assertApproxEqAbs(ledger.impactOf(ada), 7_500_000, DUST);
        assertApproxEqAbs(ledger.impactOf(ada), ledger.impactOf(bea), 1, "equal units, equal impact");
        assertApproxEqAbs(ledger.impactOf(ada) + ledger.impactOf(bea), ledger.totalImpact(), DUST);
    }

    /// A vault deposited after the gain gets none of it: its deposit charges the gain first, at the
    /// units that earned it.
    function test_proof5_aVaultDepositedAfterTheGainGetsNoneOfIt() public {
        uint256 a = _personal(ada, VenueIds.FLEX, 0);
        _deposit(ada, a, 1_000e6);
        _gain(VenueIds.FLEX, 100e6);

        uint256 late = _personal(cid, VenueIds.FLEX, 0);
        _deposit(cid, late, 1_000e6);
        assertEq(ledger.impactOf(cid), 0, "the late vault earned nothing from the earlier gain");
        assertApproxEqAbs(ledger.impactOf(ada), 15e6, DUST, "the vault that held through it got all of it");

        // From here the two share the next gain by units.
        _gain(VenueIds.FLEX, 100e6);
        ledger.accrue();
        uint256 adaNext = ledger.impactOf(ada) - 15e6;
        uint256 cidNext = ledger.impactOf(cid);
        uint256 ua = ledger.vaultUnits(a);
        uint256 uc = ledger.vaultUnits(late);
        assertApproxEqRel(adaNext * uc, cidNext * ua, 1e12, "the next gain is shared by units");
    }

    /// Impact stays with the member who earned it: withdrawing everything and closing the vault
    /// keeps it.
    function test_impactSurvivesWithdrawalAndClose() public {
        uint256 a = _personal(ada, VenueIds.FLEX, 0);
        _deposit(ada, a, 1_000e6);
        _gain(VenueIds.FLEX, 100e6);
        uint256 earned = ledger.impactOf(ada);
        assertApproxEqAbs(earned, 15e6, DUST);

        _withdraw(ada, a, ledger.vaultValue(a));
        assertEq(ledger.vaultUnits(a), 0);
        vm.prank(ada);
        ledger.closeVault(a);
        assertEq(ledger.impactOf(ada), earned, "closing keeps what the vault earned");
    }

    // ---- proof 6: shared ----

    /// Depositors of $100 and $300 get impact 1:3. After a 50% payout their weights halve and the
    /// ratio holds.
    function test_proof6_sharedImpactFollowsWhatEachPutIn() public {
        uint256 pot = _shared(VenueIds.FLEX);
        _deposit(ada, pot, 100e6);
        _deposit(bea, pot, 300e6);
        (,, uint256 wa) = ledger.stakeOf(pot, ada);
        (,, uint256 wb) = ledger.stakeOf(pot, bea);
        assertEq(wa, 100e6);
        assertEq(wb, 300e6);

        _gain(VenueIds.FLEX, 40e6);
        ledger.accrue();
        uint256 ia = ledger.impactOf(ada);
        uint256 ib = ledger.impactOf(bea);
        assertApproxEqAbs(ia, 1_500_000, DUST, "a quarter of the 6 credit fee");
        assertApproxEqAbs(ib, 4_500_000, DUST, "three quarters");
        assertApproxEqAbs(ia * 3, ib, DUST);

        // Pay half the pot out. Headcount 2, both vote yes.
        uint256 id = _propose(pot, payee, ledger.vaultValue(pot) / 2);
        _vote(ada, id, true);
        _vote(bea, id, true);
        ledger.executeWithdrawal(id);

        (,, wa) = ledger.stakeOf(pot, ada);
        (,, wb) = ledger.stakeOf(pot, bea);
        assertApproxEqRel(wa, 50e6, 1e12, "ada's weight halves");
        assertApproxEqRel(wb, 150e6, 1e12, "bea's weight halves");
        (uint256 da,,) = ledger.stakeOf(pot, ada);
        assertEq(da, 100e6, "what was deposited is a record of the past and does not shrink");
        assertApproxEqAbs(ledger.impactOf(ada), ia, DUST, "a payout does not take impact already earned");

        // The next gain is still shared 1:3.
        _gain(VenueIds.FLEX, 20e6);
        ledger.accrue();
        uint256 na = ledger.impactOf(ada) - ia;
        uint256 nb = ledger.impactOf(bea) - ib;
        assertGt(na, 0);
        assertApproxEqRel(na * 3, nb, 1e12, "the ratio holds after the payout");
        assertApproxEqAbs(ledger.impactOf(ada) + ledger.impactOf(bea), ledger.totalImpact(), DUST);
    }

    /// A deposit after a payout buys weight equal to its amount, next to weights that have shrunk.
    function test_sharedWeight_aDepositAfterAPayoutWeighsItsAmount() public {
        uint256 pot = _shared(VenueIds.FLEX);
        _deposit(ada, pot, 100e6);
        _deposit(bea, pot, 100e6);
        vm.warp(block.timestamp + 15 days);
        uint256 id = _propose(pot, payee, 100e6);
        _vote(ada, id, true);
        _vote(bea, id, true);
        ledger.executeWithdrawal(id);

        _deposit(cid, pot, 50e6);
        (,, uint256 wa) = ledger.stakeOf(pot, ada);
        (,, uint256 wc) = ledger.stakeOf(pot, cid);
        assertApproxEqRel(wa, 50e6, 1e12);
        assertApproxEqRel(wc, 50e6, 1e12, "a new deposit weighs what it put in");
    }

    /// A payout that empties the vault leaves each depositor the impact they earned in it, and a
    /// later deposit starts from nothing: an empty vault's old weights are worth nothing and take
    /// nothing from the new depositors.
    function test_sharedWeight_anEmptiedVaultKeepsEarnedImpactAndStartsFresh() public {
        uint256 pot = _shared(VenueIds.FLEX);
        _deposit(ada, pot, 100e6);
        _deposit(bea, pot, 100e6);
        _gain(VenueIds.FLEX, 20e6);
        uint256 id = _propose(pot, payee, ledger.vaultValue(pot));
        _vote(ada, id, true);
        _vote(bea, id, true);
        ledger.executeWithdrawal(id);
        assertEq(ledger.vaultUnits(pot), 0);
        uint256 ia = ledger.impactOf(ada);
        assertApproxEqAbs(ia, 1_500_000, DUST);
        (,, uint256 wa) = ledger.stakeOf(pot, ada);
        assertEq(wa, 0, "an emptied vault's weights are gone");

        _deposit(cid, pot, 100e6);
        _gain(VenueIds.FLEX, 10e6);
        ledger.accrue();
        assertEq(ledger.impactOf(ada), ia, "the old depositor takes nothing from the new money");
        assertApproxEqAbs(ledger.impactOf(cid), 1_500_000, DUST, "the new depositor earns all of it");
        assertApproxEqAbs(
            ledger.impactOf(ada) + ledger.impactOf(bea) + ledger.impactOf(cid), ledger.totalImpact(), DUST
        );

        // A returning depositor starts fresh too.
        _deposit(ada, pot, 100e6);
        (,, wa) = ledger.stakeOf(pot, ada);
        assertEq(wa, 100e6);
    }

    /// Impact is shared by amount and gives no claim: a depositor with most of the weight still has
    /// no way to take money out of the pot.
    function test_sharedWeight_isNotAClaim() public {
        uint256 pot = _shared(VenueIds.FLEX);
        _deposit(ada, pot, 1_000e6);
        vm.expectRevert();
        vm.prank(ada);
        ledger.requestWithdraw(pot, 1e6);
    }
}
