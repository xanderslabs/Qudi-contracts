// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.30;

import {LedgerFixture} from "./helpers/LedgerFixture.sol";
import {ILedger} from "../src/interfaces/ILedger.sol";
import {VenueIds} from "./helpers/VenueIds.sol";
import {VaultStatus} from "../src/VaultStatus.sol";

/// What a closed community's ledger does: nothing goes in, and what is in can come out. Only the
/// community's own `Community` closes it, when a closure vote passes; `CommunityClosure.t.sol`
/// proves the vote over the real contracts.
contract LedgerClosureTest is LedgerFixture {
    function setUp() public {
        setUpLedger();
    }

    function test_active_acceptsDeposits() public {
        uint256 id = _personal(ada, VenueIds.FLEX, 0);
        _deposit(ada, id, 100e6);
        assertEq(ledger.vaultUnits(id), 100e6);
    }

    function test_closed_refusesDeposits() public {
        uint256 id = _personal(ada, VenueIds.FLEX, 0);
        _deposit(ada, id, 100e6);
        _closeCommunity();
        vm.expectRevert(ILedger.CommunityIsClosed.selector);
        _deposit(ada, id, 1e6);
    }

    function test_closed_refusesNewVaults() public {
        _closeCommunity();
        vm.expectRevert(ILedger.CommunityIsClosed.selector);
        vm.prank(ada);
        ledger.createVault(_params(VenueIds.FLEX, false, 0, "too late"));
    }

    function test_closed_stillPaysWithdrawals() public {
        uint256 id = _personal(ada, VenueIds.FLEX, 0);
        _deposit(ada, id, 100e6);
        _closeCommunity();
        uint256 before = usdc.balanceOf(ada);
        _withdraw(ada, id, 100e6);
        assertEq(usdc.balanceOf(ada) - before, 100e6);
    }

    function test_closed_stillPaysAQueuedWithdrawal() public {
        uint256 id = _personal(bea, VenueIds.CORE, 0);
        _deposit(bea, id, 100e6);
        _illiquid(VenueIds.CORE);
        _withdraw(bea, id, 100e6);
        _closeCommunity();
        uint256 before = usdc.balanceOf(bea);
        _liquid(VenueIds.CORE);
        coreVault.processQueue(10);
        assertEq(usdc.balanceOf(bea) - before, 100e6);
    }

    /// A closed community's personal vaults keep earning and keep their fee split until their
    /// owners withdraw.
    function test_closed_personalVaultsKeepEarningAndPayingTheSplit() public {
        uint256 id = _personal(ada, VenueIds.FLEX, 0);
        _deposit(ada, id, 1_000e6);
        _closeCommunity();
        _gain(VenueIds.FLEX, 100e6);
        ledger.accrue();
        assertApproxEqAbs(ledger.vaultValue(id), 1_070e6, 10, "it earned");
        assertApproxEqAbs(usdc.balanceOf(treasury), 15e6, 10, "and paid the split");
        assertApproxEqAbs(ledger.impactOf(ada), 15e6, 10);
    }

    /// Nobody holds a claim on a shared vault, so a community cannot close while one holds money:
    /// there would be no path left to pay it out.
    function test_communityCannotCloseWhileASharedVaultHoldsABalance() public {
        uint256 pot = _shared(VenueIds.FLEX);
        _deposit(ada, pot, 100e6);
        assertTrue(ledger.sharedVaultsHoldMoney());
        vm.expectRevert(ILedger.SharedVaultHoldsBalance.selector);
        _closeCommunity();
    }

    function test_communityCanCloseWhileAPersonalVaultHoldsABalance() public {
        uint256 mine = _personal(ada, VenueIds.FLEX, 0);
        _deposit(ada, mine, 100e6);
        assertFalse(ledger.sharedVaultsHoldMoney());
        _closeCommunity();
        assertTrue(ledger.communityClosed());
    }

    /// The host can no longer close alone: only the community contract, when its closure vote
    /// executes, and only once.
    function test_closeCommunity_isTheCommunitysAndHappensOnce() public {
        vm.expectRevert(ILedger.NotCommunity.selector);
        vm.prank(host);
        ledger.closeCommunity();

        _closeCommunity();
        vm.expectRevert(ILedger.CommunityIsClosed.selector);
        _closeCommunity();
    }

    /// A shared vault paid out to zero no longer blocks closure: the guard is about money, not
    /// records.
    function test_communityClosesOnceEverySharedVaultIsEmptied() public {
        uint256 pot = _shared(VenueIds.FLEX);
        _deposit(ada, pot, 100e6);
        _deposit(bea, pot, 10e6);
        _deposit(cid, pot, 10e6);
        vm.warp(block.timestamp + 15 days);
        uint256 id = _propose(pot, payee, 120e6);
        _vote(ada, id, true);
        _vote(bea, id, true);
        _vote(cid, id, true);
        ledger.executeWithdrawal(id);
        assertFalse(ledger.sharedVaultsHoldMoney());

        vm.prank(host);
        ledger.closeVault(pot);
        (,,,, uint8 status) = ledger.vaults(pot);
        assertEq(status, VaultStatus.CLOSED);
        _closeCommunity();
        assertTrue(ledger.communityClosed());
    }

    /// A locked shared vault holding money blocks closure until its date, because no payout can
    /// be requested before it. That is what the lock meaning something costs.
    function test_lockedSharedVault_blocksClosureUntilItsDate() public {
        uint64 unlock = uint64(block.timestamp + 30 days);
        vm.prank(host);
        uint256 pot = ledger.createVault(_params(VenueIds.TERM, true, unlock, "locked pot"));
        _deposit(ada, pot, 100e6);
        _deposit(bea, pot, 10e6);
        _deposit(cid, pot, 10e6);
        vm.expectRevert(ILedger.VaultLocked.selector);
        _propose(pot, payee, 120e6);
        vm.expectRevert(ILedger.SharedVaultHoldsBalance.selector);
        _closeCommunity();

        vm.warp(unlock);
        uint256 id = _propose(pot, payee, 120e6);
        _vote(ada, id, true);
        _vote(bea, id, true);
        _vote(cid, id, true);
        ledger.executeWithdrawal(id);
        _closeCommunity();
        assertTrue(ledger.communityClosed());
    }

    function test_closed_refusesANewPayoutRequest() public {
        uint256 pot = _shared(VenueIds.FLEX);
        _closeCommunity();
        vm.expectRevert(ILedger.CommunityIsClosed.selector);
        _propose(pot, payee, 1e6);
    }
}
