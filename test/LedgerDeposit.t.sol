// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.30;

import {LedgerFixture} from "./helpers/LedgerFixture.sol";
import {ILedger} from "../src/interfaces/ILedger.sol";
import {IConfig} from "../src/interfaces/IConfig.sol";
import {VenueIds} from "./helpers/VenueIds.sol";

/// The money-in half of the ledger's unit suite, carried forward from `Ledger.t.sol` onto
/// the vault record: the gates a deposit passes, that it is never a repayment, that a record's
/// balance tracks the tier vault's price, and that the credit leg reaches `CreditCore`.
contract LedgerDepositTest is LedgerFixture {
    uint256 mine;

    function setUp() public {
        setUpLedger();
        mine = _personal(ada, VenueIds.CORE, 0);
    }

    function test_deposit_buysUnitsOneToOneWithShares() public {
        _deposit(ada, mine, 100e6);
        assertEq(ledger.vaultUnits(mine), 100e6);
        assertEq(ledger.vaultBalance(mine), 100e6);
        assertEq(ledger.vaultPrincipal(mine), 100e6);
        assertEq(coreVault.balanceOf(address(ledger)), 100e6);
        assertEq(ledger.tierUnits(VenueIds.CORE), 100e6);
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
        assertGt(ledger.vaultBalance(mine), 0);
    }

    function test_deposit_unknownVaultReverts() public {
        vm.expectRevert(ILedger.UnknownVault.selector);
        vm.prank(ada);
        ledger.deposit(999, 1e6);
    }

    function test_deposit_closedVaultReverts() public {
        vm.prank(ada);
        ledger.closeVault(mine);
        vm.expectRevert(ILedger.VaultNotActive.selector);
        vm.prank(ada);
        ledger.deposit(mine, 1e6);
    }

    /// The tier opt-in this test used to pin is deleted. A tier nothing has touched
    /// works the moment a member names it, and the ledger resolves Qudi's vault for it itself.
    /// The full statement, over the real factory, is `test/LedgerNoTierGate.t.sol`.
    function test_createVault_reachesATierNothingHasTouched() public {
        assertEq(ledger.tierUnits(VenueIds.FLEX), 0);
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

    /// A shared vault is the host's to open: host-created and community-wide.
    function test_createVault_sharedIsTheHosts() public {
        vm.expectRevert(ILedger.NotHost.selector);
        vm.prank(ada);
        ledger.createVault(_params(VenueIds.FLEX, true, 0, "not yours to open"));
    }

    /// A maturity already in the past is a lock that never locked, far more likely a mistyped
    /// date than an intention. The same refusal `Venue`'s constructor makes.
    function test_createVault_refusesAMaturityInThePast() public {
        vm.warp(block.timestamp + 10 days);
        vm.expectRevert(ILedger.VaultLocked.selector);
        vm.prank(ada);
        ledger.createVault(_params(VenueIds.FLEX, false, uint64(block.timestamp - 1), "already matured"));
    }

    /// The record keeps every axis the member stated, including the ones the contract never
    /// reads: the app shows them back, and the struct is the design's.
    function test_createVault_storesTheWholeRecord() public {
        vm.prank(ada);
        uint256 id = ledger.createVault(
            ILedger.VaultParams({
                poolType: VenueIds.FLEX,
                shared: false,
                lockedUntil: uint64(block.timestamp + 90 days),
                contribution: 1, // Scheduled
                name: "School fees",
                target: 5_000e6,
                targetDate: uint64(block.timestamp + 180 days)
            })
        );
        (
            uint8 poolType,
            bool shared,
            address vaultOwner,
            uint64 lockedUntil,
            uint8 contribution,
            uint8 status,
            string memory name,
            uint256 target,
            uint64 targetDate
        ) = ledger.vaults(id);
        assertEq(poolType, VenueIds.FLEX);
        assertFalse(shared);
        assertEq(vaultOwner, ada);
        assertEq(lockedUntil, uint64(block.timestamp + 90 days));
        assertEq(contribution, 1);
        assertEq(status, 1); // Active
        assertEq(name, "School fees");
        assertEq(target, 5_000e6);
        assertEq(targetDate, uint64(block.timestamp + 180 days));
    }

    /// A record's balance tracks its tier vault's price, and `vaultEarned` is the gain above
    /// what was put in.
    function test_balance_tracksTheTierPrice_earnedIsTheGain() public {
        uint256 hers = _personal(bea, VenueIds.CORE, 0);
        _deposit(ada, mine, 100e6);
        _deposit(bea, hers, 300e6);
        coreVault.rebalance();
        usdc.mint(address(this), 40e6);
        usdc.approve(address(coreVenue), 40e6);
        coreVenue.fund(40e6); // +10% in the strategy
        // A year lets the Venue's growth cap through the whole gain. The Venue takes no fee, so
        // the tier price rises the full 10%.
        vm.warp(block.timestamp + 365 days);

        assertApproxEqAbs(ledger.vaultBalance(mine), 110e6, 2);
        assertApproxEqAbs(ledger.vaultBalance(hers), 330e6, 2);
        assertApproxEqAbs(ledger.vaultEarned(mine), 10e6, 2);
        assertEq(ledger.vaultPrincipal(mine), 100e6);
    }
}
