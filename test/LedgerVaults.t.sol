// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.30;

import {LedgerFixture} from "./helpers/LedgerFixture.sol";
import {ILedger} from "../src/interfaces/ILedger.sol";
import {IConfig} from "../src/interfaces/IConfig.sol";
import {VenueIds} from "./helpers/VenueIds.sol";
import {VaultStatus} from "../src/VaultStatus.sol";

/// The vault record: its six shapes, who may open and use each, the member's list, and the venue
/// position that several records share without fragmenting it.
contract LedgerVaultsTest is LedgerFixture {
    function setUp() public {
        setUpLedger();
    }

    // ---- proof 1: shapes ----

    /// Personal or shared, times Flex, Core or Term. The two Open venues take no lock and Term
    /// takes one in the future. Each record keeps exactly what it was opened with.
    function test_proof1_allSixShapesCreate() public {
        uint64 lock = uint64(block.timestamp + 30 days);
        uint8[3] memory ids = [VenueIds.FLEX, VenueIds.CORE, VenueIds.TERM];
        for (uint256 i; i < 3; i++) {
            uint64 lockedUntil = ids[i] == VenueIds.TERM ? lock : 0;
            vm.prank(ada);
            uint256 mine = ledger.createVault(_params(ids[i], false, lockedUntil, "mine"));
            vm.prank(host);
            uint256 ours = ledger.createVault(_params(ids[i], true, lockedUntil, "ours"));

            (address owner, bool shared, uint8 venueId, uint64 lu, uint8 status) = ledger.vaults(mine);
            assertEq(owner, ada);
            assertFalse(shared);
            assertEq(venueId, ids[i]);
            assertEq(lu, lockedUntil);
            assertEq(status, VaultStatus.ACTIVE);

            (owner, shared, venueId, lu, status) = ledger.vaults(ours);
            assertEq(owner, address(0), "a shared vault has no owner");
            assertTrue(shared);
            assertEq(venueId, ids[i]);
            assertEq(lu, lockedUntil);
            assertEq(status, VaultStatus.ACTIVE);
        }
        assertEq(ledger.vaultCount(), 6);
    }

    /// An Open-kind venue's vaults are open by definition, so a lock there is refused, personal
    /// or shared.
    function test_proof1_anOpenKindVenueWithALockReverts() public {
        uint64 lock = uint64(block.timestamp + 30 days);
        vm.expectRevert(ILedger.LockNotAllowed.selector);
        vm.prank(ada);
        ledger.createVault(_params(VenueIds.FLEX, false, lock, "x"));
        vm.expectRevert(ILedger.LockNotAllowed.selector);
        vm.prank(host);
        ledger.createVault(_params(VenueIds.CORE, true, lock, "x"));
    }

    /// A Locked-kind venue may be illiquid, which is safe only for money committed for a known
    /// period: no date, or a date already past, is refused.
    function test_proof1_aLockedKindVenueWithoutALockReverts() public {
        vm.expectRevert(ILedger.LockRequired.selector);
        vm.prank(ada);
        ledger.createVault(_params(VenueIds.TERM, false, 0, "x"));
        vm.expectRevert(ILedger.LockRequired.selector);
        vm.prank(host);
        ledger.createVault(_params(VenueIds.TERM, true, uint64(block.timestamp), "x"));
    }

    function test_proof1_aMemberCannotCreateASharedVault() public {
        vm.expectRevert(ILedger.NotHost.selector);
        vm.prank(ada);
        ledger.createVault(_params(VenueIds.FLEX, true, 0, "x"));
    }

    function test_proof1_aNonMemberCannotCreateAPersonalVault() public {
        vm.expectRevert(ILedger.NotMember.selector);
        vm.prank(stranger);
        ledger.createVault(_params(VenueIds.FLEX, false, 0, "x"));
    }

    /// A retired venue takes no new vaults. A vault already in it still takes deposits.
    function test_proof1_aRetiredVenueRefusesNewVaults() public {
        uint256 before = _personal(ada, VenueIds.CORE, 0);
        factory.retireVenue(VenueIds.CORE);

        vm.expectRevert(ILedger.VenueRetired.selector);
        vm.prank(bea);
        ledger.createVault(_params(VenueIds.CORE, false, 0, "x"));

        _deposit(ada, before, 100e6);
        assertEq(ledger.vaultUnits(before), 100e6, "an existing vault in a retired venue still takes deposits");
    }

    function test_createVault_anIdTheRegistryNeverHandedOutReverts() public {
        vm.expectRevert(IConfig.UnknownPoolType.selector);
        vm.prank(ada);
        ledger.createVault(_params(VenueIds.COUNT, false, 0, "x"));
        vm.expectRevert(IConfig.UnknownPoolType.selector);
        ledger.tierVault(VenueIds.COUNT);
    }

    // ---- proof 15: vaultsOf and the member cap ----

    /// Exactly the vaults a member owns or has deposited into: not another member's, and not a
    /// shared vault they never paid into.
    function test_proof15_vaultsOfIsExactlyTheMembersVaults() public {
        uint256 a1 = _personal(ada, VenueIds.FLEX, 0);
        uint256 b1 = _personal(bea, VenueIds.FLEX, 0);
        uint256 a2 = _personal(ada, VenueIds.CORE, 0);
        uint256 pot = _shared(VenueIds.FLEX);
        uint256 other = _shared(VenueIds.CORE);
        _deposit(ada, pot, 20e6);
        _deposit(bea, other, 20e6);
        _deposit(ada, pot, 5e6); // a second deposit does not list the vault twice

        uint256[] memory mine = ledger.vaultsOf(ada);
        assertEq(mine.length, 3);
        assertEq(mine[0], a1);
        assertEq(mine[1], a2);
        assertEq(mine[2], pot);

        uint256[] memory hers = ledger.vaultsOf(bea);
        assertEq(hers.length, 2);
        assertEq(hers[0], b1);
        assertEq(hers[1], other);

        assertEq(ledger.vaultsOf(cid).length, 0);
    }

    /// The list is bounded by `MAX_VAULTS_PER_MEMBER`, so the impact views that walk it cannot run
    /// out of gas. The 33rd vault reverts, whether it is a new personal vault or a first deposit
    /// into a shared one.
    function test_proof15_theMemberCapRevertsAt33() public {
        assertEq(config.maxVaultsPerMember(), 32);
        for (uint256 i; i < 32; i++) {
            _personal(ada, VenueIds.FLEX, 0);
        }
        assertEq(ledger.vaultsOf(ada).length, 32);

        vm.expectRevert(ILedger.TooManyVaults.selector);
        vm.prank(ada);
        ledger.createVault(_params(VenueIds.FLEX, false, 0, "33rd"));

        uint256 pot = _shared(VenueIds.FLEX);
        vm.expectRevert(ILedger.TooManyVaults.selector);
        vm.prank(ada);
        ledger.deposit(pot, 20e6);
    }

    /// A closed personal vault leaves its owner's list, so closing frees a place under the cap.
    function test_closeVault_freesAPlaceInTheList() public {
        uint256 first;
        for (uint256 i; i < 32; i++) {
            uint256 id = _personal(ada, VenueIds.FLEX, 0);
            if (i == 0) first = id;
        }
        vm.prank(ada);
        ledger.closeVault(first);
        assertEq(ledger.vaultsOf(ada).length, 31);
        _personal(ada, VenueIds.FLEX, 0);
        assertEq(ledger.vaultsOf(ada).length, 32);
    }

    // ---- several records in one venue position ----

    /// Records divide a position, they do not fragment it. Two personal vaults in Core, funded and
    /// withdrawn independently, while the ledger holds exactly one position in the one Core venue.
    function test_twoVaultsOneVenue_positionStaysWhole() public {
        uint256 rent = _personal(ada, VenueIds.CORE, 0);
        uint256 school = _personal(ada, VenueIds.CORE, 0);

        _deposit(ada, rent, 300e6);
        _deposit(ada, school, 200e6);
        assertEq(ledger.vaultUnits(rent), 300e6);
        assertEq(ledger.vaultUnits(school), 200e6, "the second vault did not disturb the first");
        assertEq(ledger.venueUnits(VenueIds.CORE), 500e6);
        assertEq(coreVault.balanceOf(address(ledger)), 500e6, "the venue position is one position");

        _withdraw(ada, rent, 100e6);
        assertEq(ledger.vaultUnits(rent), 200e6);
        assertEq(ledger.vaultUnits(school), 200e6, "a withdrawal from one record did not touch the other");
        assertEq(ledger.venueUnits(VenueIds.CORE), 400e6);
        assertEq(ledger.venueShares(VenueIds.CORE), coreVault.balanceOf(address(ledger)));
    }

    // ---- who may use each kind ----

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
        ledger.requestWithdraw(id, 10e6);
    }

    function test_sharedVault_acceptsADepositFromAnyMember() public {
        uint256 id = _shared(VenueIds.FLEX);
        _deposit(ada, id, 100e6);
        _deposit(bea, id, 50e6);
        _deposit(cid, id, 25e6);
        assertEq(ledger.vaultUnits(id), 175e6);
        assertEq(ledger.depositorCount(id), 3);

        vm.expectRevert(ILedger.NotMember.selector);
        vm.prank(stranger);
        ledger.deposit(id, 1e6);
    }

    /// A shared vault has no member withdrawal path: the only way out is a payout the members vote
    /// through.
    function test_sharedVault_hasNoMemberWithdrawalPath() public {
        uint256 id = _shared(VenueIds.FLEX);
        _deposit(ada, id, 100e6);
        vm.expectRevert(ILedger.SharedVaultNeedsAProposal.selector);
        vm.prank(ada);
        ledger.requestWithdraw(id, 10e6);
    }

    /// A record holding units cannot be closed, which is what stops a close from stranding money.
    function test_closeVault_refusesWhileItHoldsABalance() public {
        uint256 id = _personal(ada, VenueIds.FLEX, 0);
        _deposit(ada, id, 100e6);
        vm.expectRevert(ILedger.VaultHoldsBalance.selector);
        vm.prank(ada);
        ledger.closeVault(id);

        _withdraw(ada, id, 100e6);
        vm.prank(ada);
        ledger.closeVault(id);
        (,,,, uint8 status) = ledger.vaults(id);
        assertEq(status, VaultStatus.CLOSED);

        vm.expectRevert(ILedger.VaultNotActive.selector);
        vm.prank(ada);
        ledger.deposit(id, 1e6);
    }
}
