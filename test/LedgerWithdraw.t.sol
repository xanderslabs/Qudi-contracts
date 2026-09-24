// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.30;

import {LedgerFixture} from "./helpers/LedgerFixture.sol";
import {ILedger} from "../src/interfaces/ILedger.sol";
import {IVenue} from "../src/interfaces/IVenue.sol";
import {VenueIds} from "./helpers/VenueIds.sol";

/// A personal withdrawal is one pushed payment. The owner requests; the venue pays the owner's
/// wallet as soon as it has the cash, in the same transaction when it can. There is no claim
/// step and no wait of the ledger's own.
contract LedgerWithdrawTest is LedgerFixture {
    function setUp() public {
        setUpLedger();
    }

    // ---- proof 8: personal withdrawal ----

    /// In a liquid venue, one call pays the owner.
    function test_proof8_aLiquidVenuePaysInOneCall() public {
        uint256 id = _personal(ada, VenueIds.FLEX, 0);
        _deposit(ada, id, 1_000e6);
        uint256 before = usdc.balanceOf(ada);

        _withdraw(ada, id, 400e6);
        assertEq(usdc.balanceOf(ada) - before, 400e6, "paid in the same transaction");
        assertEq(ledger.vaultUnits(id), 600e6);
        assertEq(ledger.vaultCapital(id), 600e6);
        assertEq(ledger.personalUnitsOf(ada), 600e6);
    }

    /// In an illiquid venue the units leave at once, and the payment arrives when anyone processes
    /// the queue, straight to the owner.
    function test_proof8_anIlliquidVenuePaysWhenAnyoneProcessesTheQueue() public {
        uint256 id = _personal(ada, VenueIds.CORE, 0);
        _deposit(ada, id, 1_000e6);
        _illiquid(VenueIds.CORE);
        uint256 before = usdc.balanceOf(ada);

        uint256 rid = _withdraw(ada, id, 400e6);
        assertEq(usdc.balanceOf(ada), before, "nothing paid yet");
        assertEq(ledger.vaultUnits(id), 600e6, "the units left at the request");
        (,,,,, uint256 venueRequestId) = ledger.withdrawRequests(rid);
        (address owner, address receiver, uint256 shares) = coreVault.redeemRequest(venueRequestId);
        assertEq(owner, address(ledger));
        assertEq(receiver, ada, "the venue pays the owner, not the ledger");
        assertEq(shares, 400e6);

        _liquid(VenueIds.CORE);
        vm.prank(stranger);
        coreVault.processQueue(10);
        assertEq(usdc.balanceOf(ada) - before, 400e6, "paid straight to the owner");
    }

    /// A cancel before payment puts the units, the shares behind them and the capital back.
    function test_proof8_aCancelBeforePaymentRestoresUnitsAndCapital() public {
        uint256 id = _personal(ada, VenueIds.CORE, 0);
        _deposit(ada, id, 1_000e6);
        _gain(VenueIds.CORE, 100e6);
        ledger.accrue();
        _illiquid(VenueIds.CORE);
        uint256 units = ledger.vaultUnits(id);
        uint256 capital = ledger.vaultCapital(id);
        uint256 venueShares = ledger.venueShares(VenueIds.CORE);

        uint256 rid = _withdraw(ada, id, 300e6);
        assertLt(ledger.vaultUnits(id), units);
        assertLt(ledger.vaultCapital(id), capital);

        vm.expectRevert(ILedger.NotRequester.selector);
        vm.prank(bea);
        ledger.cancelWithdraw(rid);

        vm.prank(ada);
        ledger.cancelWithdraw(rid);
        assertEq(ledger.vaultUnits(id), units, "units restored");
        assertEq(ledger.vaultCapital(id), capital, "capital restored");
        assertEq(ledger.personalUnitsOf(ada), units);
        assertEq(ledger.venueShares(VenueIds.CORE), venueShares);
        assertEq(ledger.venueShares(VenueIds.CORE), coreVault.balanceOf(address(ledger)));

        vm.expectRevert(ILedger.NotRequester.selector);
        vm.prank(ada);
        ledger.cancelWithdraw(rid);
    }

    /// A request the venue has paid cannot be cancelled.
    function test_cancelWithdraw_afterPaymentReverts() public {
        uint256 id = _personal(ada, VenueIds.FLEX, 0);
        _deposit(ada, id, 100e6);
        uint256 rid = _withdraw(ada, id, 50e6);
        vm.expectRevert(IVenue.NothingToClaim.selector);
        vm.prank(ada);
        ledger.cancelWithdraw(rid);
    }

    /// Capital leaves pro rata by units, so what is left is still what went in less its share of
    /// what came out, and a withdrawal of the whole value empties the vault.
    function test_withdraw_capitalLeavesProRataAndTheWholeValueComesOut() public {
        uint256 id = _personal(ada, VenueIds.FLEX, 0);
        _deposit(ada, id, 1_000e6);
        _gain(VenueIds.FLEX, 100e6);
        uint256 value = ledger.vaultValue(id);
        _withdraw(ada, id, value / 2);
        assertApproxEqAbs(ledger.vaultCapital(id), 500e6, 1);

        uint256 before = usdc.balanceOf(ada);
        _withdraw(ada, id, ledger.vaultValue(id));
        assertEq(ledger.vaultUnits(id), 0);
        assertEq(ledger.vaultCapital(id), 0);
        assertApproxEqAbs(usdc.balanceOf(ada) - before, value - value / 2, 2);
    }

    function test_withdraw_moreThanTheVaultHoldsReverts() public {
        uint256 id = _personal(ada, VenueIds.FLEX, 0);
        _deposit(ada, id, 100e6);
        vm.expectRevert(ILedger.ExceedsWithdrawable.selector);
        _withdraw(ada, id, 100e6 + 1);
    }

    // ---- proof 9: the lock ----

    /// A request before `lockedUntil` reverts; at it, the request goes through and is paid.
    function test_proof9_aRequestBeforeTheUnlockDateReverts() public {
        uint64 unlock = uint64(block.timestamp + 90 days);
        uint256 id = _personal(ada, VenueIds.TERM, unlock);
        _deposit(ada, id, 100e6);

        vm.warp(unlock - 1);
        vm.expectRevert(ILedger.VaultLocked.selector);
        _withdraw(ada, id, 1e6);

        vm.warp(unlock);
        uint256 before = usdc.balanceOf(ada);
        _withdraw(ada, id, 100e6);
        assertEq(usdc.balanceOf(ada) - before, 100e6);
    }

    // ---- proof 10: exit-only ----

    /// A frozen member can still take their own money out of their personal vault, and cannot put
    /// more in.
    function test_proof10_aFrozenMemberWithdrawsAndCannotDeposit() public {
        uint256 id = _personal(ada, VenueIds.FLEX, 0);
        _deposit(ada, id, 100e6);
        community.freeze(ada);

        vm.expectRevert(ILedger.NotMember.selector);
        _deposit(ada, id, 1e6);

        uint256 before = usdc.balanceOf(ada);
        _withdraw(ada, id, 100e6);
        assertEq(usdc.balanceOf(ada) - before, 100e6);
    }

    /// A departed member keeps their personal vaults: no withdrawal path reads membership.
    function test_proof10_aDepartedMemberWithdrawsAndCannotDeposit() public {
        uint256 id = _personal(bea, VenueIds.CORE, 0);
        _deposit(bea, id, 100e6);
        community.setMember(bea, false);
        community.setSeasoned(bea, false);

        vm.expectRevert(ILedger.NotMember.selector);
        _deposit(bea, id, 1e6);

        uint256 before = usdc.balanceOf(bea);
        _withdraw(bea, id, 100e6);
        assertEq(usdc.balanceOf(bea) - before, 100e6);
    }
}
