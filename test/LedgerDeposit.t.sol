// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.30;

import {LedgerFixture} from "./helpers/LedgerFixture.sol";
import {ILedger} from "../src/interfaces/ILedger.sol";
import {IConfig} from "../src/interfaces/IConfig.sol";
import {PoolTypes} from "../src/PoolTypes.sol";

/// The money-in half of the ledger's unit suite, carried forward from `Ledger.t.sol` onto
/// the vault record: the gates a deposit passes, that it is never a repayment, that a record's
/// balance tracks the tier vault's price, and that the credit leg reaches `CreditCore`.
contract LedgerDepositTest is LedgerFixture {
    uint256 mine;

    function setUp() public {
        setUpLedger();
        mine = _personal(ada, PoolTypes.CORE, 0);
    }

    function test_deposit_buysUnitsOneToOneWithShares() public {
        _deposit(ada, mine, 100e6);
        assertEq(ledger.vaultUnits(mine), 100e6);
        assertEq(ledger.vaultBalance(mine), 100e6);
        assertEq(ledger.vaultPrincipal(mine), 100e6);
        assertEq(coreVault.balanceOf(address(ledger)), 100e6);
        assertEq(ledger.tierUnits(PoolTypes.CORE), 100e6);
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
        assertEq(ledger.tierUnits(PoolTypes.FLEX), 0);
        vm.prank(ada);
        uint256 id = ledger.createVault(_params(PoolTypes.FLEX, false, 0, "untouched tier"));
        _deposit(ada, id, 100e6);
        assertEq(ledger.vaultUnits(id), 100e6);
        assertEq(ledger.tierVault(PoolTypes.FLEX), address(tierVaults[PoolTypes.FLEX]));
    }

    /// The range guard the opt-in's removal must not take with it.
    function test_createVault_outOfRangeTierReverts() public {
        vm.expectRevert(IConfig.UnknownPoolType.selector);
        vm.prank(ada);
        ledger.createVault(_params(PoolTypes.COUNT, false, 0, "not a tier"));
    }

    /// A shared vault is the host's to open: host-created and community-wide.
    function test_createVault_sharedIsTheHosts() public {
        vm.expectRevert(ILedger.NotHost.selector);
        vm.prank(ada);
        ledger.createVault(_params(PoolTypes.FLEX, true, 0, "not yours to open"));
    }

    /// A maturity already in the past is a lock that never locked, far more likely a mistyped
    /// date than an intention. The same refusal `Venue`'s constructor makes.
    function test_createVault_refusesAMaturityInThePast() public {
        vm.warp(block.timestamp + 10 days);
        vm.expectRevert(ILedger.VaultLocked.selector);
        vm.prank(ada);
        ledger.createVault(_params(PoolTypes.FLEX, false, uint64(block.timestamp - 1), "already matured"));
    }

    /// The record keeps every axis the member stated, including the ones the contract never
    /// reads: the app shows them back, and the struct is the design's.
    function test_createVault_storesTheWholeRecord() public {
        vm.prank(ada);
        uint256 id = ledger.createVault(
            ILedger.VaultParams({
                poolType: PoolTypes.FLEX,
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
        assertEq(poolType, PoolTypes.FLEX);
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
        uint256 hers = _personal(bea, PoolTypes.CORE, 0);
        _deposit(ada, mine, 100e6);
        _deposit(bea, hers, 300e6);
        coreVault.rebalance();
        usdc.mint(address(this), 40e6);
        usdc.approve(address(coreVenue), 40e6);
        coreVenue.fund(40e6); // +10% in the venue
        coreVault.harvest(address(coreVenue)); // 70/15/15: members get 28 of 40
        (uint64 unlock,,) = config.yieldEngine();
        vm.warp(block.timestamp + unlock);

        assertApproxEqAbs(ledger.vaultBalance(mine), 107e6, 2);
        assertApproxEqAbs(ledger.vaultBalance(hers), 321e6, 2);
        assertApproxEqAbs(ledger.vaultEarned(mine), 7e6, 2);
        assertEq(ledger.vaultPrincipal(mine), 100e6);
    }

    /// The destination is the singleton `CreditCore`, booked against this ledger's own
    /// community id, not a per-community credit pool clone.
    function test_claimPoolLeg_forwardsToCreditCore() public {
        _deposit(ada, mine, 1_000e6);
        coreVault.rebalance();
        usdc.mint(address(this), 100e6);
        usdc.approve(address(coreVenue), 100e6);
        coreVenue.fund(100e6);
        coreVault.harvest(address(coreVenue));

        uint256 assets = ledger.claimPoolLeg(PoolTypes.CORE);
        assertApproxEqAbs(assets, 15e6, 2);
        assertEq(usdc.balanceOf(address(creditCore)), assets);
        assertEq(creditCore.legOf(0), assets, "booked against the ledger's community");
        assertEq(coreVault.balanceOf(address(creditCore)), 0);
    }

    /// One leg per tier: claiming Flex's does not spend Core's, which is what a single ledger
    /// holding many tiers has to get right. An untouched tier has nothing to claim rather than
    /// being closed to the call, because no tier is closed.
    function test_claimPoolLeg_isPerTier() public {
        _deposit(ada, mine, 1_000e6);
        assertEq(ledger.claimPoolLeg(PoolTypes.FLEX), 0, "an untouched tier has no leg to claim");
        assertEq(ledger.claimPoolLeg(PoolTypes.TERM), 0);

        vm.expectRevert(IConfig.UnknownPoolType.selector);
        ledger.claimPoolLeg(PoolTypes.COUNT);
    }
}
