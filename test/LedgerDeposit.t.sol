// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.30;

import {LedgerFixture} from "./helpers/LedgerFixture.sol";
import {ILedger} from "../src/interfaces/ILedger.sol";
import {IConfig} from "../src/interfaces/IConfig.sol";
import {VenueIds} from "./helpers/VenueIds.sol";

/// The money-in half of the ledger's unit suite: the gates a deposit passes, and that a record's
/// value tracks the venue's price after the split.
contract LedgerDepositTest is LedgerFixture {
    uint256 mine;

    function setUp() public {
        setUpLedger();
        mine = _personal(ada, VenueIds.CORE, 0);
    }

    function test_deposit_buysUnitsOneToOneWithShares() public {
        _deposit(ada, mine, 100e6);
        assertEq(ledger.vaultUnits(mine), 100e6);
        assertEq(ledger.vaultValue(mine), 100e6);
        assertEq(ledger.vaultCapital(mine), 100e6);
        assertEq(coreVault.balanceOf(address(ledger)), 100e6);
        assertEq(ledger.venueUnits(VenueIds.CORE), 100e6);
        assertEq(ledger.venueShares(VenueIds.CORE), 100e6);
        assertEq(ledger.personalUnitsOf(ada), 100e6);
    }

    function test_deposit_nonMemberReverts() public {
        vm.expectRevert(ILedger.NotMember.selector);
        vm.prank(stranger);
        ledger.deposit(mine, 1e6);
    }

    /// `blocked` covers money going INTO the protocol. A blocked member cannot deposit;
    /// unblocking restores it.
    function test_deposit_blockedReverts() public {
        registry.setBlocked(ada, true); // the test contract holds the screener role
        vm.expectRevert(ILedger.AccountBlocked.selector);
        vm.prank(ada);
        ledger.deposit(mine, 1e6);

        registry.setBlocked(ada, false);
        _deposit(ada, mine, 1e6);
        assertGt(ledger.vaultValue(mine), 0);
    }

    function test_deposit_unknownVaultReverts() public {
        vm.expectRevert(ILedger.UnknownVault.selector);
        vm.prank(ada);
        ledger.deposit(999, 1e6);
    }

    function test_deposit_zeroReverts() public {
        vm.expectRevert(ILedger.ZeroAmount.selector);
        _deposit(ada, mine, 0);
    }

    function test_deposit_closedVaultReverts() public {
        vm.prank(ada);
        ledger.closeVault(mine);
        vm.expectRevert(ILedger.VaultNotActive.selector);
        vm.prank(ada);
        ledger.deposit(mine, 1e6);
    }

    /// A venue nothing has touched works the moment a member names it, and the ledger resolves
    /// Qudi's venue for it itself.
    function test_createVault_reachesATierNothingHasTouched() public {
        assertEq(ledger.venueUnits(VenueIds.FLEX), 0);
        vm.prank(ada);
        uint256 id = ledger.createVault(_params(VenueIds.FLEX, false, 0, "untouched tier"));
        _deposit(ada, id, 100e6);
        assertEq(ledger.vaultUnits(id), 100e6);
        assertEq(ledger.tierVault(VenueIds.FLEX), address(tierVaults[VenueIds.FLEX]));
    }

    /// The range guard the opt-in's removal must not take with it.
    function test_createVault_outOfRangeTierReverts() public {
        vm.expectRevert(IConfig.UnknownPoolType.selector);
        vm.prank(ada);
        ledger.createVault(_params(VenueIds.COUNT, false, 0, "not a tier"));
    }

    /// The record stores the owner, kind, venue, lock and status. The name is emitted and not
    /// stored.
    function test_createVault_storesTheRecordAndEmitsTheName() public {
        uint64 lock = uint64(block.timestamp + 90 days);
        vm.expectEmit(true, true, true, true, address(ledger));
        emit ILedger.VaultCreated(ledger.vaultCount() + 1, VenueIds.TERM, ada, false, lock, "School fees");
        vm.prank(ada);
        uint256 id = ledger.createVault(
            ILedger.VaultParams({venueId: VenueIds.TERM, shared: false, lockedUntil: lock, name: "School fees"})
        );
        (address vaultOwner, bool shared, uint8 venueId, uint64 lockedUntil, uint8 status) = ledger.vaults(id);
        assertEq(vaultOwner, ada);
        assertFalse(shared);
        assertEq(venueId, VenueIds.TERM);
        assertEq(lockedUntil, lock);
        assertEq(status, 1); // Active
    }

    /// A record's value tracks its venue's price less the 30% the split takes, and `vaultEarned`
    /// is the value above what was put in.
    function test_balance_tracksTheTierPrice_earnedIsTheGain() public {
        uint256 hers = _personal(bea, VenueIds.CORE, 0);
        _deposit(ada, mine, 100e6);
        _deposit(bea, hers, 300e6);
        coreVault.rebalance();
        usdc.mint(address(this), 40e6);
        usdc.approve(address(coreVenue), 40e6);
        coreVenue.fund(40e6); // +10% in the strategy
        // A year lets the Venue's growth cap through the whole gain. The venue price rises the
        // full 10%, and the ledger keeps 70% of it for the vaults.
        vm.warp(block.timestamp + 365 days);

        assertApproxEqAbs(ledger.vaultValue(mine), 107e6, 2);
        assertApproxEqAbs(ledger.vaultValue(hers), 321e6, 2);
        assertApproxEqAbs(ledger.vaultEarned(mine), 7e6, 2);
        assertEq(ledger.vaultCapital(mine), 100e6);
    }
}
