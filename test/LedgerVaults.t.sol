// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.30;

import {LedgerFixture} from "./helpers/LedgerFixture.sol";
import {ILedger} from "../src/interfaces/ILedger.sol";
import {VenueIds} from "./helpers/VenueIds.sol";
import {VaultStatus} from "../src/VaultStatus.sol";

/// The vault record divides a tier position without fragmenting it,
/// access control is real on both kinds of vault, and the lock moved from the tier vault to the
/// record.
contract LedgerVaultsTest is LedgerFixture {
    function setUp() public {
        setUpLedger();
    }

    // ---- proof 1: two vaults in the same tier, and the tier position stays whole ----

    /// Records divide a position, they do not fragment it. Two personal vaults in
    /// CORE, funded and withdrawn independently, while the ledger holds exactly one position
    /// in the one CORE tier vault throughout.
    function test_twoVaultsOneTier_positionStaysWhole() public {
        uint256 rent = _personal(ada, VenueIds.CORE, 0);
        uint256 school = _personal(ada, VenueIds.CORE, 0);
        assertTrue(rent != school, "two records, two ids");

        _deposit(ada, rent, 300e6);
        assertEq(ledger.vaultUnits(rent), 300e6);
        assertEq(ledger.vaultUnits(school), 0);
        assertEq(ledger.tierUnits(VenueIds.CORE), 300e6);

        _deposit(ada, school, 200e6);
        assertEq(ledger.vaultUnits(rent), 300e6, "the second vault did not disturb the first");
        assertEq(ledger.vaultUnits(school), 200e6);
        assertEq(ledger.tierUnits(VenueIds.CORE), 500e6);

        // One depositor of the tier vault, holding the whole position: not two.
        assertEq(coreVault.balanceOf(address(ledger)), 500e6, "the tier position is one position");

        // Withdraw from one and the other is untouched.
        vm.prank(ada);
        uint256 id = ledger.requestWithdraw(rent, 100e6);
        vm.warp(block.timestamp + exitOf(VenueIds.CORE));
        vm.prank(ada);
        ledger.executeWithdraw(id);

        assertEq(ledger.vaultUnits(rent), 200e6);
        assertEq(ledger.vaultUnits(school), 200e6, "a withdrawal from one record did not touch the other");
        assertEq(ledger.tierUnits(VenueIds.CORE), 400e6);
        assertEq(coreVault.balanceOf(address(ledger)), 400e6);
    }

    // ---- proof 2: both tierUnits equalities hold after every operation in proof 1 ----

    function _assertTierReconciles(uint8 poolType, uint256[] memory ids) internal view {
        uint256 sum;
        for (uint256 i = 0; i < ids.length; i++) {
            (,,,,, uint8 status,,,) = ledger.vaults(ids[i]);
            if (status == VaultStatus.ACTIVE) sum += ledger.vaultUnits(ids[i]);
        }
        assertEq(ledger.tierUnits(poolType), sum, "tierUnits is not the sum of its active vaults");
        assertEq(
            ledger.tierUnits(poolType),
            ledger.tierVault(poolType) == address(0) ? 0 : coreVault.balanceOf(address(ledger)),
            "tierUnits is not the ledger's own unit balance in the tier vault"
        );
    }

    function test_bothTierUnitsEqualitiesHoldThroughout() public {
        uint256[] memory ids = new uint256[](2);
        ids[0] = _personal(ada, VenueIds.CORE, 0);
        ids[1] = _personal(ada, VenueIds.CORE, 0);
        _assertTierReconciles(VenueIds.CORE, ids);

        _deposit(ada, ids[0], 300e6);
        _assertTierReconciles(VenueIds.CORE, ids);

        _deposit(ada, ids[1], 200e6);
        _assertTierReconciles(VenueIds.CORE, ids);

        vm.prank(ada);
        uint256 id = ledger.requestWithdraw(ids[0], 100e6);
        _assertTierReconciles(VenueIds.CORE, ids);

        vm.warp(block.timestamp + exitOf(VenueIds.CORE));
        vm.prank(ada);
        ledger.executeWithdraw(id);
        _assertTierReconciles(VenueIds.CORE, ids);
    }

    // ---- proof 3: a personal vault refuses everyone but its owner ----

    function test_personalVault_refusesADepositFromAnyoneButItsOwner() public {
        uint256 id = _personal(ada, VenueIds.FLEX, 0);
        vm.expectRevert(ILedger.NotVaultOwner.selector);
        vm.prank(bea);
        ledger.deposit(id, 10e6);
    }

    function test_personalVault_refusesAWithdrawalFromAnyoneButItsOwner() public {
        uint256 id = _personal(ada, VenueIds.FLEX, 0);
        _deposit(ada, id, 100e6);
        vm.expectRevert(ILedger.NotVaultOwner.selector);
        vm.prank(bea);
        ledger.withdrawInstant(id, 10e6);

        vm.expectRevert(ILedger.NotVaultOwner.selector);
        vm.prank(bea);
        ledger.requestWithdraw(id, 10e6);
    }

    // ---- proof 4: a shared vault accepts a deposit from any member ----

    function test_sharedVault_acceptsADepositFromAnyMember() public {
        uint256 id = _shared(VenueIds.FLEX);
        _deposit(ada, id, 100e6);
        _deposit(bea, id, 50e6);
        _deposit(cid, id, 25e6);
        assertEq(ledger.vaultUnits(id), 175e6);
        // A qualifying contributor is seasoned, so the clock runs before
        // anything reads the electorate.
        vm.warp(block.timestamp + 15 days);
        assertTrue(ledger.isDepositor(id, ada));
        assertTrue(ledger.isDepositor(id, bea));
        assertTrue(ledger.isDepositor(id, cid));
        assertEq(ledger.depositorCount(id), 3);

        // A non-member still cannot: shared means every member, not everyone.
        vm.expectRevert(ILedger.NotMember.selector);
        vm.prank(stranger);
        ledger.deposit(id, 1e6);
    }

    // ---- proof 5: the lock moved to the record ----

    /// `lockedUntil` refuses a withdrawal before its date and allows it after. That is the proof
    /// the lock lives in the ledger: there is nothing in `Venue` that could enforce
    /// one, because the vault-level lock the Term collapse stranded was deleted outright.
    function test_lockedUntil_isTheLedgersLockAndTheTierVaultsIsZero() public {
        uint64 maturity = uint64(block.timestamp + 90 days);
        uint256 id = _personal(ada, VenueIds.FLEX, maturity);
        _deposit(ada, id, 100e6);

        vm.expectRevert(ILedger.VaultLocked.selector);
        vm.prank(ada);
        ledger.withdrawInstant(id, 10e6);

        vm.expectRevert(ILedger.VaultLocked.selector);
        vm.prank(ada);
        ledger.requestWithdraw(id, 10e6);

        vm.warp(maturity);
        vm.prank(ada);
        ledger.withdrawInstant(id, 10e6);
        assertEq(ledger.vaultUnits(id), 90e6);
    }

    /// An open record in the same tier is unaffected by a locked one beside it. The lock is per
    /// record, which is the whole reason it could not stay on the tier vault.
    function test_lockedAndOpenVaultsShareOneTierVault() public {
        uint64 maturity = uint64(block.timestamp + 90 days);
        uint256 locked = _personal(ada, VenueIds.FLEX, maturity);
        uint256 open = _personal(bea, VenueIds.FLEX, 0);
        _deposit(ada, locked, 100e6);
        _deposit(bea, open, 100e6);

        vm.prank(bea);
        ledger.withdrawInstant(open, 100e6);

        vm.expectRevert(ILedger.VaultLocked.selector);
        vm.prank(ada);
        ledger.withdrawInstant(locked, 1e6);
    }

    // ---- proof 7: a vault holding a balance cannot be closed ----

    function test_closeVault_refusesWhileItHoldsABalance() public {
        uint256 id = _personal(ada, VenueIds.FLEX, 0);
        _deposit(ada, id, 100e6);

        vm.expectRevert(ILedger.VaultHoldsBalance.selector);
        vm.prank(ada);
        ledger.closeVault(id);

        vm.prank(ada);
        ledger.withdrawInstant(id, 100e6);
        vm.prank(ada);
        ledger.closeVault(id);

        (,,,,, uint8 status,,,) = ledger.vaults(id);
        assertEq(status, VaultStatus.CLOSED);
    }

    /// The lock on the queued path, end to end.
    ///
    /// The lock lives in this contract, and `executeWithdraw` asks a second
    /// time, where the units leave and the USDC moves. That re-check is **unreachable as the code
    /// stands**, and this test is what pins the reason: `_requirePersonalWithdrawer` refuses the
    /// request first, `lockedUntil` is written once in `createVault` and never again, and
    /// execution is always later than the request it settles. So a request that got through
    /// proves `block.timestamp >= lockedUntil`, and the later execution cannot see a standing
    /// lock. Recorded against UL-02 in the mutation catalogue, which is marked redundant with
    /// that proof; UL-01 is the live bound.
    ///
    /// If the lock is ever taken off the request path so a member may queue before maturity, this
    /// test starts failing at its first line, which is where the work would restart.
    function test_lockedVault_refusesTheRequestAndPaysOutOnlyAfterMaturity() public {
        uint64 maturity = uint64(block.timestamp + 90 days);
        uint256 id = _personal(ada, VenueIds.CORE, maturity);
        _deposit(ada, id, 100e6);

        // The lock binds the paperwork as well as the money, because it binds it first.
        vm.expectRevert(ILedger.VaultLocked.selector);
        vm.prank(ada);
        ledger.requestWithdraw(id, 10e6);

        vm.warp(maturity);
        vm.prank(ada);
        uint256 req = ledger.requestWithdraw(id, 10e6);
        assertEq(ledger.vaultUnits(id), 100e6, "the request freezes units, it does not move them");

        // The cooldown is the only thing left between the request and the money.
        vm.expectRevert(ILedger.CooldownActive.selector);
        vm.prank(ada);
        ledger.executeWithdraw(req);

        vm.warp(block.timestamp + exitOf(VenueIds.CORE));
        vm.prank(ada);
        ledger.executeWithdraw(req);
        assertEq(ledger.vaultUnits(id), 90e6, "the money left once the lock had matured");
    }

    /// A TERM record must carry a lock. Term is the profile for a venue that does
    /// not anticipate withdrawals and may therefore be illiquid, and the only thing making that
    /// safe is that the money is committed for a known period. Term's
    /// withdrawal term is zero on exactly that reasoning, so an unlocked TERM record would be
    /// the one combination the profile cannot carry: no lock, no cooldown, slowest venues.
    function test_termRecordMustCarryALock() public {
        vm.prank(ada);
        vm.expectRevert(ILedger.TermRecordMustBeLocked.selector);
        ledger.createVault(_params(VenueIds.TERM, false, 0, "unlocked term"));

        vm.prank(host);
        vm.expectRevert(ILedger.TermRecordMustBeLocked.selector);
        ledger.createVault(_params(VenueIds.TERM, true, 0, "unlocked shared term"));
    }

    /// The other side of 1.25: a locked TERM record is still ordinary, and every other tier may
    /// still be opened without a lock. The rule is about Term, not about locking generally.
    function test_termWithALockIsFine_andOtherTiersNeedNone() public {
        uint64 maturity = uint64(block.timestamp + 180 days);
        vm.prank(ada);
        uint256 term = ledger.createVault(_params(VenueIds.TERM, false, maturity, "locked term"));
        assertGt(term, 0, "a locked TERM record is created normally");

        vm.prank(ada);
        uint256 flex = ledger.createVault(_params(VenueIds.FLEX, false, 0, "open flex"));
        assertGt(flex, 0, "FLEX still needs no lock");
    }
}
