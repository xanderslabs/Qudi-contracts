// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.30;

import {LedgerFixture} from "./helpers/LedgerFixture.sol";
import {ILedger} from "../src/interfaces/ILedger.sol";
import {VenueIds} from "./helpers/VenueIds.sol";
import {VaultStatus} from "../src/VaultStatus.sol";

/// Every cell of the closure table, one test per cell, plus the two community-closure guards.
///
/// The table's "State" is the community's, which is the intended reading: a closed
/// community still lets personal balances out, so "withdrawals: yes" has something to be true
/// about. One invariant: nothing goes in, and what is in can come out.
contract LedgerClosureTest is LedgerFixture {
    function setUp() public {
        setUpLedger();
    }

    function _closeCommunity() internal {
        vm.prank(host);
        ledger.closeCommunity();
    }

    function _gain(uint256 amount) internal {
        flexVault.rebalance();
        usdc.mint(address(this), amount);
        usdc.approve(address(flexVenue), amount);
        flexVenue.fund(amount);
        // A year is long enough for the Venue's growth cap to let the whole gain through.
        vm.warp(block.timestamp + 365 days);
    }

    // ---- row Active ----

    /// Active / Deposits: yes.
    function test_active_acceptsDeposits() public {
        uint256 id = _personal(ada, VenueIds.FLEX, 0);
        _deposit(ada, id, 100e6);
        assertEq(ledger.vaultUnits(id), 100e6);
    }

    /// Active / Withdrawals: per the vault's rules. The open record pays, the locked one refuses,
    /// and "per the vault's rules" is exactly that difference.
    function test_active_withdrawalsFollowTheVaultsOwnRules() public {
        uint256 open = _personal(ada, VenueIds.FLEX, 0);
        uint256 locked = _personal(bea, VenueIds.FLEX, uint64(block.timestamp + 30 days));
        _deposit(ada, open, 100e6);
        _deposit(bea, locked, 100e6);

        vm.prank(ada);
        ledger.withdrawInstant(open, 100e6);
        assertEq(ledger.vaultUnits(open), 0);

        vm.expectRevert(ILedger.VaultLocked.selector);
        vm.prank(bea);
        ledger.withdrawInstant(locked, 1e6);
    }

    /// Active / Yield: yes. A strategy gain reaches the record's balance.
    function test_active_earnsYield() public {
        uint256 id = _personal(ada, VenueIds.FLEX, 0);
        _deposit(ada, id, 1_000e6);
        uint256 before = ledger.vaultBalance(id);
        _gain(100e6);
        assertGt(ledger.vaultBalance(id), before, "an active vault earns");
    }

    // ---- row Closed ----

    /// Closed / Deposits: no. Nothing in, which is the first half of the invariant.
    function test_closed_refusesDeposits() public {
        uint256 id = _personal(ada, VenueIds.FLEX, 0);
        _deposit(ada, id, 100e6);
        _closeCommunity();

        vm.expectRevert(ILedger.CommunityIsClosed.selector);
        vm.prank(ada);
        ledger.deposit(id, 1e6);
    }

    /// Closed / Deposits: no, including through a brand new record. A closed community opens no
    /// new doors either.
    function test_closed_refusesNewVaults() public {
        _closeCommunity();
        vm.expectRevert(ILedger.CommunityIsClosed.selector);
        vm.prank(ada);
        ledger.createVault(_params(VenueIds.FLEX, false, 0, "too late"));
    }

    /// Closed / Withdrawals: yes. What is in comes out, which is the second half.
    function test_closed_stillPaysWithdrawals() public {
        uint256 id = _personal(ada, VenueIds.FLEX, 0);
        _deposit(ada, id, 100e6);
        _closeCommunity();

        vm.prank(ada);
        ledger.withdrawInstant(id, 100e6);
        assertEq(ledger.vaultUnits(id), 0);
    }

    /// Closed / Withdrawals: yes on the queued path as well.
    function test_closed_stillPaysAQueuedWithdrawal() public {
        uint256 core = _personal(bea, VenueIds.CORE, 0);
        _deposit(bea, core, 100e6);
        _closeCommunity();

        vm.prank(bea);
        uint256 id = ledger.requestWithdraw(core, 100e6);
        vm.warp(block.timestamp + exitOf(VenueIds.CORE));
        vm.prank(bea);
        ledger.executeWithdraw(id);
        assertEq(ledger.vaultUnits(core), 0);
    }

    /// Closed / Yield: no, at the seam the ledger owns. No further principal can be put to work.
    /// What the ledger cannot do on its own is stop the tier vault's share price moving under a
    /// personal balance that has not been withdrawn yet: taking that position out at closure is a
    /// liquidation mechanism nothing specifies, and it is an open question rather than something
    /// decided here. This test pins the enforced half and states the other.
    function test_closed_putsNoFurtherPrincipalToWork() public {
        uint256 id = _personal(ada, VenueIds.FLEX, 0);
        _deposit(ada, id, 1_000e6);
        _closeCommunity();

        vm.expectRevert(ILedger.CommunityIsClosed.selector);
        vm.prank(ada);
        ledger.deposit(id, 1_000e6);
    }

    // ---- proof 8: the two community-closure guards ----

    function test_communityCannotCloseWhileASharedVaultHoldsABalance() public {
        uint256 pot = _shared(VenueIds.FLEX);
        _deposit(ada, pot, 100e6);

        vm.expectRevert(ILedger.SharedVaultHoldsBalance.selector);
        vm.prank(host);
        ledger.closeCommunity();
    }

    function test_communityCanCloseWhileAPersonalVaultHoldsABalance() public {
        uint256 mine = _personal(ada, VenueIds.FLEX, 0);
        _deposit(ada, mine, 100e6);

        vm.prank(host);
        ledger.closeCommunity();
        assertTrue(ledger.communityClosed());

        // And the owner withdraws afterwards, which is what makes the asymmetry coherent.
        vm.prank(ada);
        ledger.withdrawInstant(mine, 100e6);
        assertEq(ledger.vaultUnits(mine), 0);
    }

    /// Closing is the host's, and it is terminal: nothing is deleted, only marked.
    function test_closeCommunity_isTheHostsAndHappensOnce() public {
        vm.expectRevert(ILedger.NotHost.selector);
        vm.prank(ada);
        ledger.closeCommunity();

        vm.prank(host);
        ledger.closeCommunity();
        vm.expectRevert(ILedger.CommunityIsClosed.selector);
        vm.prank(host);
        ledger.closeCommunity();
    }

    /// A closed shared vault at zero does not block the community, which is the other side of
    /// the shared-balance guard: the guard is about money, not about records.
    function test_communityClosesOnceEverySharedVaultIsEmptied() public {
        uint256 pot = _shared(VenueIds.FLEX);
        _deposit(ada, pot, 100e6);
        _passAndExecuteDrain(pot, 100e6);

        vm.prank(host);
        ledger.closeVault(pot);
        (,,,,, uint8 status,,,) = ledger.vaults(pot);
        assertEq(status, VaultStatus.CLOSED);

        vm.prank(host);
        ledger.closeCommunity();
        assertTrue(ledger.communityClosed());
    }

    /// An accepted cost of locked shared vaults, pinned so a later reader sees it was chosen rather than
    /// overlooked. A locked shared vault holding a balance cannot be emptied before its date,
    /// because the only way out of a shared vault is a proposal and none is allowed while
    /// the lock stands. Closure is then refused while a shared vault holds a balance. So
    /// the community cannot close until the date passes and the money leaves.
    function test_lockedSharedVault_blocksClosureUntilItsDateAndThenReleasesIt() public {
        uint64 maturity = uint64(block.timestamp + 30 days);
        vm.prank(host);
        uint256 pot = ledger.createVault(_params(VenueIds.FLEX, true, maturity, "locked pot"));
        _deposit(ada, pot, 100e6);
        _deposit(bea, pot, 10e6);
        _deposit(cid, pot, 10e6);

        // The lock refuses the only path that could empty it.
        vm.expectRevert(ILedger.VaultLocked.selector);
        vm.prank(host);
        ledger.proposeWithdrawal(pot, payee, 120e6);

        // And the balance it therefore keeps refuses the close.
        vm.expectRevert(ILedger.SharedVaultHoldsBalance.selector);
        vm.prank(host);
        ledger.closeCommunity();

        vm.warp(maturity);
        vm.prank(host);
        uint256 p = ledger.proposeWithdrawal(pot, payee, 120e6);
        vm.prank(ada);
        ledger.voteOnWithdrawal(p, true);
        vm.prank(bea);
        ledger.voteOnWithdrawal(p, true);
        vm.prank(cid);
        ledger.voteOnWithdrawal(p, true);
        (, uint64 window) = config.communityVote();
        vm.warp(block.timestamp + window + 1);
        vm.prank(ada);
        ledger.executeWithdrawal(p);
        assertEq(ledger.vaultUnits(pot), 0, "the money left once the date had passed");

        vm.prank(host);
        ledger.closeCommunity();
        assertTrue(ledger.communityClosed(), "and the close it was blocking goes through");
    }

    /// Emptying a shared vault is a proposal, a vote and an execution: there is no other way out
    /// of one. Kept here rather than in the withdrawal suite because closure needs it.
    function _passAndExecuteDrain(uint256 vaultId, uint256 amount) internal {
        // The two extra voters must clear the qualifying-contributor bars, so a token wei each is no
        // longer enough. Ten dollars is the bar, and the electorate seasons before the proposal.
        _deposit(bea, vaultId, 10e6);
        _deposit(cid, vaultId, 10e6);
        vm.warp(block.timestamp + 15 days);
        vm.prank(host);
        uint256 p = ledger.proposeWithdrawal(vaultId, payee, amount + 20e6);
        vm.prank(ada);
        ledger.voteOnWithdrawal(p, true);
        vm.prank(bea);
        ledger.voteOnWithdrawal(p, true);
        vm.prank(cid);
        ledger.voteOnWithdrawal(p, true);
        (, uint64 window) = config.communityVote();
        vm.warp(block.timestamp + window + 1);
        vm.prank(ada);
        ledger.executeWithdrawal(p);
    }
}
