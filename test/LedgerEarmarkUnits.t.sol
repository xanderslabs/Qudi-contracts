// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.30;

import {LedgerFixture} from "./helpers/LedgerFixture.sol";
import {ILedger} from "../src/interfaces/ILedger.sol";
import {PoolTypes} from "../src/PoolTypes.sol";
import {ProposalStatus} from "../src/VaultStatus.sol";

/// A shared withdrawal earmarks units, not dollars.
///
/// The funds are earmarked at proposal time and no parameter changes at
/// execution. Reserving units is what makes that literally true: the claim on the vault is fixed
/// when the proposal is made, so no price move can outrun it, there is nothing to clamp, and no
/// passed vote can be bricked. What the recipient receives in USDC floats with the price, which is
/// what a claim on a vault is.
contract LedgerEarmarkUnitsTest is LedgerFixture {
    uint256 pot;

    function setUp() public {
        setUpLedger();
        pot = _shared(PoolTypes.FLEX);
        _deposit(ada, pot, 400e6);
        _deposit(bea, pot, 300e6);
        _deposit(cid, pot, 200e6);
        _deposit(dan, pot, 100e6);
        // The electorate has to season before a proposal can see it.
        vm.warp(block.timestamp + 15 days);
        // Every unit is in the venue, so a skim there is a real loss and a fund is a real gain.
        flexVault.rebalance();
    }

    function _window() internal view returns (uint64 w) {
        (, w) = config.communityVote();
    }

    function _proposeAndPass(uint256 amount) internal returns (uint256 id) {
        vm.prank(host);
        id = ledger.proposeWithdrawal(pot, payee, amount);
        address[3] memory voters = [ada, bea, cid];
        for (uint256 i = 0; i < 3; i++) {
            vm.prank(voters[i]);
            ledger.voteOnWithdrawal(id, true);
        }
        vm.warp(block.timestamp + _window() + 1);
    }

    /// A loss in the venue, taken straight to the price because no reserve stands in front of it.
    function _priceFalls(uint256 loss) internal {
        flexVenue.skim(loss);
        flexVault.settle();
    }

    /// A gain, harvested and released, so the price is genuinely above where it was.
    function _priceRises(uint256 gain) internal {
        usdc.mint(address(this), gain);
        usdc.approve(address(flexVenue), gain);
        flexVenue.fund(gain);
        flexVault.harvest(address(flexVenue));
        (uint64 unlock,,) = config.yieldEngine();
        vm.warp(block.timestamp + unlock);
        flexVault.settle();
    }

    // ---- proof 1: the price falls ----

    /// The proposal reserved units. The price falls before execution, and execution burns exactly
    /// those units and delivers what they are now worth. No clamp, no revert.
    function test_priceFalls_burnsExactlyTheReservedUnits() public {
        uint256 id = _proposeAndPass(250e6);
        (,, uint256 reserved,,,,,,) = ledger.proposals(id);
        assertEq(reserved, 250e6, "the reservation is a unit count struck at proposal time");
        assertEq(ledger.earmarkedUnits(pot), 250e6);

        uint256 unitsBefore = ledger.vaultUnits(pot);
        _priceFalls(200e6); // a fifth of the pot's value, gone
        assertLt(flexVault.convertToAssets(1e6), 1e6, "fixture: the price really fell");

        uint256 payeeBefore = usdc.balanceOf(payee);
        vm.prank(dan);
        ledger.executeWithdrawal(id);

        assertEq(unitsBefore - ledger.vaultUnits(pot), reserved, "exactly the reserved units burned");
        assertEq(ledger.earmarkedUnits(pot), 0);
        (,,,,,,,, uint8 status) = ledger.proposals(id);
        assertEq(status, ProposalStatus.EXECUTED);

        // The dollar amount floated down with the price, which is what a claim on a vault is.
        uint256 paid = usdc.balanceOf(payee) - payeeBefore;
        assertLt(paid, 250e6, "the recipient's dollars followed the price");
        assertApproxEqAbs(paid, flexVault.convertToAssets(reserved), 2);
    }

    /// The whole pot can be reserved and a fall does not brick it. Under the dollar earmark this
    /// was the case that needed the clamp: 1,000 USDC converted to more units than the vault held.
    function test_priceFalls_awholePotReservationStillExecutes() public {
        uint256 id = _proposeAndPass(1_000e6);
        (,, uint256 reserved,,,,,,) = ledger.proposals(id);
        assertEq(reserved, ledger.vaultUnits(pot), "the whole position is reserved");

        _priceFalls(300e6);

        vm.prank(ada);
        ledger.executeWithdrawal(id);
        assertEq(ledger.vaultUnits(pot), 0, "the pot is empty, and nothing reverted");
        assertEq(ledger.earmarkedUnits(pot), 0);
    }

    // ---- proof 2: the price rises ----

    function test_priceRises_burnsExactlyTheReservedUnitsAndPaysMore() public {
        uint256 id = _proposeAndPass(250e6);
        (,, uint256 reserved,,,,,,) = ledger.proposals(id);
        uint256 unitsBefore = ledger.vaultUnits(pot);

        _priceRises(200e6);
        assertGt(flexVault.convertToAssets(1e6), 1e6, "fixture: the price really rose");

        uint256 payeeBefore = usdc.balanceOf(payee);
        vm.prank(dan);
        ledger.executeWithdrawal(id);

        assertEq(unitsBefore - ledger.vaultUnits(pot), reserved, "exactly the reserved units burned");
        uint256 paid = usdc.balanceOf(payee) - payeeBefore;
        assertGt(paid, 250e6, "the recipient got more, because the units are worth more");
        assertApproxEqAbs(paid, flexVault.convertToAssets(reserved), 2);
    }

    /// The reservation is struck once. A rise does not free units for a second proposal to take,
    /// which is the same statement as the fall case: the claim is on units and it is fixed.
    function test_priceRises_doesNotShrinkTheReservation() public {
        vm.prank(host);
        uint256 id = ledger.proposeWithdrawal(pot, payee, 1_000e6);
        assertEq(ledger.earmarkedUnits(pot), 1_000e6);

        _priceRises(500e6);
        assertEq(ledger.earmarkedUnits(pot), 1_000e6, "the reservation is a unit count, not a target");
        assertEq(ledger.availableUnits(pot), 0);

        // A whole dollar, so it converts to a non-zero unit count and the ceiling is what
        // refuses it rather than the zero-amount guard one line above it.
        vm.expectRevert(ILedger.ExceedsAvailable.selector);
        vm.prank(host);
        ledger.proposeWithdrawal(pot, payee, 1e6);
    }

    // ---- proof 3: reserved units are still reserved ----

    /// A second proposal cannot reach the reserved units, and the ceiling is now counted in units.
    function test_reservedUnits_cannotBeClaimedByASecondProposal() public {
        vm.prank(host);
        ledger.proposeWithdrawal(pot, payee, 800e6);
        assertEq(ledger.earmarkedUnits(pot), 800e6);
        assertEq(ledger.availableUnits(pot), 200e6);

        vm.expectRevert(ILedger.ExceedsAvailable.selector);
        vm.prank(host);
        ledger.proposeWithdrawal(pot, payee, 300e6);

        vm.prank(host);
        ledger.proposeWithdrawal(pot, payee, 200e6);
        assertEq(ledger.earmarkedUnits(pot), 1_000e6);
        assertEq(ledger.availableUnits(pot), 0);
    }

    /// And a member still cannot reach them directly: a shared vault has no member-initiated
    /// withdrawal path at all, which is what makes the reservation a reservation.
    function test_reservedUnits_cannotBeWithdrawnByAMember() public {
        vm.prank(host);
        ledger.proposeWithdrawal(pot, payee, 800e6);

        vm.expectRevert(ILedger.SharedVaultNeedsAProposal.selector);
        vm.prank(ada);
        ledger.withdrawInstant(pot, 100e6);

        vm.expectRevert(ILedger.SharedVaultNeedsAProposal.selector);
        vm.prank(ada);
        ledger.requestWithdraw(pot, 100e6);
    }

    /// Reverting returns the units, not a dollar figure, so a proposal that failed while the price
    /// moved gives back exactly what it took.
    function test_revert_returnsTheUnitsItReserved() public {
        vm.prank(host);
        uint256 id = ledger.proposeWithdrawal(pot, payee, 400e6);
        vm.warp(block.timestamp + _window() + 1);
        _priceFalls(200e6);

        vm.prank(cid);
        ledger.revertWithdrawal(id);
        assertEq(ledger.earmarkedUnits(pot), 0);
        assertEq(ledger.availableUnits(pot), ledger.vaultUnits(pot), "every unit is free again");
    }

    /// The proposal keeps the USDC value its voters saw, so the app can show what was approved
    /// beside what was delivered. It is a snapshot and no money path reads it.
    function test_proposal_carriesTheApprovedDollarValueAsASnapshot() public {
        vm.prank(host);
        uint256 id = ledger.proposeWithdrawal(pot, payee, 250e6);
        (,, uint256 units, uint256 approved,,,,,) = ledger.proposals(id);
        assertEq(units, 250e6);
        assertEq(approved, 250e6, "the dollar value when the vote was asked for");

        _priceFalls(200e6);
        (,, uint256 unitsAfter, uint256 approvedAfter,,,,,) = ledger.proposals(id);
        assertEq(unitsAfter, 250e6, "the claim did not move");
        assertEq(approvedAfter, 250e6, "and neither did the record of what was approved");
    }
}
