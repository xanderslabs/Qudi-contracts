// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.30;

import {LedgerFixture} from "./helpers/LedgerFixture.sol";
import {ILedger} from "../src/interfaces/ILedger.sol";
import {PoolTypes} from "../src/PoolTypes.sol";
import {MockVenue} from "./mocks/MockVenue.sol";
import {ConfigKeys as K} from "../src/ConfigKeys.sol";

/// The money-out half, carried forward onto the vault record. Every property here was proved
/// against the old per-member ledger and holds unchanged against the per-record one:
/// the request queue, the Flex-only instant path, both withdrawal ceilings, and the settle-first
/// ordering that decides instant against queued.
contract LedgerWithdrawTest is LedgerFixture {
    uint256 core; // ada's CORE record, the queued path
    uint256 flex; // ada's FLEX record, the instant path

    uint256 constant START = 1_000_000e6;

    function setUp() public {
        setUpLedger();
        core = _personal(ada, PoolTypes.CORE, 0);
        flex = _personal(ada, PoolTypes.FLEX, 0);
    }

    function _coreTerm() internal view returns (uint64) {
        return config.withdrawTerm(PoolTypes.CORE);
    }

    function test_requestWithdraw_freezesUnitsAndRecordsRelease() public {
        _deposit(ada, core, 100e6);
        vm.prank(ada);
        uint256 id = ledger.requestWithdraw(core, 40e6);

        // The units are reserved, not moved: they have not left the tier vault, so the record's
        // balance and the tier position both still count them.
        assertEq(ledger.vaultBalance(core), 100e6);
        assertEq(ledger.tierUnits(PoolTypes.CORE), 100e6);

        vm.expectRevert(ILedger.CooldownActive.selector);
        vm.prank(ada);
        ledger.executeWithdraw(id);

        vm.warp(block.timestamp + _coreTerm());
        vm.prank(ada);
        ledger.executeWithdraw(id);
        assertEq(usdc.balanceOf(ada), START - 100e6 + 40e6);
        assertEq(ledger.vaultBalance(core), 60e6);
        assertEq(ledger.tierUnits(PoolTypes.CORE), 60e6);
        assertEq(ledger.lastWithdrawalAt(ada), uint64(block.timestamp));
    }

    /// One pending request per record at a time.
    function test_requestWithdraw_oneAtATime() public {
        _deposit(ada, core, 100e6);
        vm.startPrank(ada);
        ledger.requestWithdraw(core, 40e6);
        vm.expectRevert(ILedger.CooldownActive.selector);
        ledger.requestWithdraw(core, 10e6);
        vm.stopPrank();
    }

    /// The ceiling is the record's own balance, whatever the member owes,
    /// and the frozen part of it is already spoken for.
    function test_requestWithdraw_ceilingIsTheWholeBalance() public {
        _deposit(ada, core, 100e6);
        vm.expectRevert(ILedger.ExceedsWithdrawable.selector);
        vm.prank(ada);
        ledger.requestWithdraw(core, 100e6 + 1);
        vm.prank(ada);
        ledger.requestWithdraw(core, 100e6);
    }

    function test_cancelWithdraw_releasesTheReservation() public {
        _deposit(ada, core, 100e6);
        vm.prank(ada);
        uint256 id = ledger.requestWithdraw(core, 40e6);
        vm.prank(ada);
        ledger.cancelWithdraw(id);
        assertEq(ledger.vaultUnits(core), 100e6);

        // And the full balance is requestable again, which is what the release means.
        vm.prank(ada);
        ledger.requestWithdraw(core, 100e6);
    }

    /// A withdrawal is the record owner's. Nobody else executes or cancels their request.
    function test_requestLifecycle_isTheOwners() public {
        _deposit(ada, core, 100e6);
        vm.prank(ada);
        uint256 id = ledger.requestWithdraw(core, 40e6);
        vm.warp(block.timestamp + _coreTerm());

        vm.expectRevert(ILedger.NotRequester.selector);
        vm.prank(bea);
        ledger.executeWithdraw(id);
        vm.expectRevert(ILedger.NotRequester.selector);
        vm.prank(bea);
        ledger.cancelWithdraw(id);
    }

    function test_withdrawInstant_flexOnly() public {
        _deposit(ada, core, 100e6);
        vm.expectRevert(ILedger.InstantPathBlocked.selector);
        vm.prank(ada);
        ledger.withdrawInstant(core, 10e6);

        _deposit(ada, flex, 100e6);
        vm.prank(ada);
        ledger.withdrawInstant(flex, 10e6);
        assertEq(ledger.vaultBalance(flex), 90e6);
    }

    /// The same ceiling the queued path has, on the route that skips the queue. Mutation entry
    /// UL-04 survived without this: deleting the guard does not let anyone overdraw, because
    /// `vaultUnits -= units` underflows one line later and the call still reverts. That
    /// arithmetic backstop is exactly what hid the missing coverage.
    function test_withdrawInstant_ceilingIsTheWholeBalance() public {
        _deposit(ada, flex, 100e6);
        vm.expectRevert(ILedger.ExceedsWithdrawable.selector);
        vm.prank(ada);
        ledger.withdrawInstant(flex, 100e6 + 1);
        vm.prank(ada);
        ledger.withdrawInstant(flex, 100e6);
        assertEq(ledger.vaultBalance(flex), 0);
    }

    /// R15: the instant path must burn exactly the units it debits, or the tier position drifts
    /// above the shares the ledger holds every time the price is above 1.
    function test_withdrawInstant_conservesUnitsAboveUnitPrice() public {
        uint256 hers = _personal(bea, PoolTypes.FLEX, 0);
        _deposit(ada, flex, 100e6);
        _deposit(bea, hers, 300e6);
        usdc.mint(address(flexVault), 40e6); // +10%
        flexVault.report(); // 70/15/15: members get 28 of 40, so about 1.07 per unit
        uint256 adaBefore = usdc.balanceOf(ada);

        vm.prank(ada);
        ledger.withdrawInstant(flex, 50e6);

        assertEq(ledger.tierUnits(PoolTypes.FLEX), flexVault.balanceOf(address(ledger)));
        assertEq(ledger.vaultUnits(flex) + ledger.vaultUnits(hers), ledger.tierUnits(PoolTypes.FLEX));
        assertApproxEqAbs(usdc.balanceOf(ada) - adaBefore, 50e6, 2);
    }

    /// R16: an execution the tier vault cannot pay instantly goes to its FIFO queue and says so
    /// with its own event; nobody has been paid at that point.
    function test_executeWithdraw_queuesWhenNotInstantlyLiquid() public {
        _slowVenue(2_500);
        _deposit(ada, core, 1_000e6);
        coreVault.rebalance(); // 250e6 into the slow venue, 750e6 idle
        vm.prank(ada);
        uint256 id = ledger.requestWithdraw(core, 900e6);
        vm.warp(block.timestamp + _coreTerm());

        vm.expectEmit(true, true, false, true, address(ledger));
        emit ILedger.WithdrawQueued(id, core, 900e6, 1);
        vm.prank(ada);
        ledger.executeWithdraw(id);

        assertEq(coreVault.queuedShares(address(ledger)), 900e6);
        assertEq(usdc.balanceOf(ada), START - 1_000e6, "not paid yet");
        assertEq(ledger.vaultBalance(core), 100e6);

        coreVault.rebalance(); // a blocked queue drains the slow venue back to idle
        coreVault.processQueue(1);
        assertApproxEqAbs(usdc.balanceOf(ada), START - 1_000e6 + 900e6, 2);
    }

    /// R16 boundary: the instant-branch check compares `units` against `maxRedeem`, not `assets`
    /// against `maxWithdraw`. At a non-unit price a request one asset unit above `maxWithdraw`
    /// converts to one share above `maxRedeem`, but converting those units back to assets floors
    /// down to exactly `maxWithdraw` again. An assets-domain check lets that through to
    /// `vault.redeem`, which reverts `InsufficientInstantLiquidity` on its own stricter guard.
    function test_executeWithdraw_atMaxWithdrawBoundary_nonUnitPrice_doesNotRevert() public {
        _slowVenue(2_500);
        _deposit(ada, core, 1_000e6);
        coreVault.rebalance();
        usdc.mint(address(coreVault), 100e6); // price above 1
        coreVault.report();

        uint256 avail = coreVault.maxWithdraw(address(ledger));
        assertGt(avail, 0);
        vm.prank(ada);
        uint256 id = ledger.requestWithdraw(core, avail + 1);
        vm.warp(block.timestamp + _coreTerm());

        uint256 balBefore = ledger.vaultBalance(core);
        vm.prank(ada);
        ledger.executeWithdraw(id); // must not revert InsufficientInstantLiquidity
        assertLt(ledger.vaultBalance(core), balBefore);
    }

    /// The instant-vs-queue decision is made on post-settle numbers. A venue loss the
    /// reserve absorbs used to make the pre-settle price low, so a stale view overstated how many
    /// shares the instant tier could cover; the settle inside `redeem` then burned the reserve,
    /// put the price back up, and the same request no longer fit.
    ///
    /// The vault closes the same hazard from its own side, so both halves are asserted here in
    /// order: the view already refuses the instant tier before anything settles, and the ledger's
    /// own settle-first ordering still routes the request to the queue. The ordering stays
    /// because it is what makes the ledger correct on its own terms rather than by the vault's
    /// grace.
    function test_executeWithdraw_settlesBeforeChoosingInstantOrQueue() public {
        MockVenue slow = _slowVenue(2_500);
        _deposit(ada, core, 1_000e6);
        usdc.mint(owner, 200e6);
        vm.startPrank(owner);
        usdc.approve(address(coreVault), 200e6);
        coreVault.fundReserve(200e6); // the reserve that will absorb the loss
        vm.stopPrank();
        coreVault.rebalance(); // 300e6 into the slow venue, 900e6 idle and instant

        // 950 asked against 900 of instant liquidity: payable only if the price says so.
        vm.prank(ada);
        uint256 id = ledger.requestWithdraw(core, 950e6);
        (,, uint256 units,) = ledger.requests(id);
        vm.warp(block.timestamp + _coreTerm());

        slow.skim(200e6); // venue loss, live and unsettled

        // The view is no longer stale. The reserve's answer to the loss is already in the
        // price, so the instant tier is refused here, before any settle, rather than after one.
        assertGt(units, coreVault.maxRedeem(address(ledger)), "the pre-settle view still overstates it");

        uint256 balBefore = ledger.vaultBalance(core);
        vm.prank(ada);
        ledger.executeWithdraw(id); // must not revert

        assertEq(coreVault.reserveShares(), 0);
        assertEq(coreVault.queuedShares(address(ledger)), units);
        assertLt(ledger.vaultBalance(core), balBefore);
    }

    /// Term's withdrawal term is 0, so a matured Term record's request and its
    /// execution land in the same block. Term is the tier whose venue has had the whole lock
    /// period to arrange the liquidity, so there is nothing left to wait for. The one-request-
    /// per-record rule is unaffected by the zero: it is a pending-slot rule, not a cooldown.
    function test_termVault_requestsAndExecutesInTheSameBlock() public {
        uint64 maturity = uint64(block.timestamp + 90 days);
        uint256 term = _personal(ada, PoolTypes.TERM, maturity);
        _deposit(ada, term, 100e6);
        vm.warp(maturity);
        uint256 at = block.timestamp;

        vm.prank(ada);
        uint256 id = ledger.requestWithdraw(term, 40e6);
        assertEq(ledger.releaseAfter(id), at, "nothing left to wait for");

        // Still one pending request per record: the slot is taken until this one is settled.
        vm.expectRevert(ILedger.CooldownActive.selector);
        vm.prank(ada);
        ledger.requestWithdraw(term, 10e6);

        vm.prank(ada);
        ledger.executeWithdraw(id);
        assertEq(block.timestamp, at, "requested and paid without the clock moving");

        // And the slot is free again immediately, in that same block.
        vm.prank(ada);
        uint256 second = ledger.requestWithdraw(term, 60e6);
        vm.prank(ada);
        ledger.executeWithdraw(second);
        assertEq(ledger.vaultUnits(term), 0);
        assertEq(usdc.balanceOf(ada), START, "the whole record came back out");
    }

    /// A slow venue holding the slow tier's ceiling, so a large enough request cannot be paid
    /// instantly and the ledger hands it to the tier vault's FIFO queue. It replaces the fixture's
    /// own instant venue, whose weight would otherwise leave nothing for this one.
    function _slowVenue(uint16 bps) internal returns (MockVenue slow) {
        slow = new MockVenue(usdc, "Slow", "S");
        slow.setRedeemDelay(2 days);
        vm.startPrank(owner);
        coreVault.addVenue(address(slow));
        address[] memory vs = new address[](2);
        vs[0] = address(coreVenue);
        vs[1] = address(slow);
        uint16[] memory w = new uint16[](2);
        w[0] = 0;
        w[1] = bps; // the rest stays idle, which counts as instant
        coreVault.setWeights(vs, w);
        vm.stopPrank();
    }
}
