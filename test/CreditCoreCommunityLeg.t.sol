// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.30;

import {Community} from "../src/Community.sol";
import {ICreditCore} from "../src/interfaces/ICreditCore.sol";
import {CreditFixture} from "./helpers/CreditFixture.sol";

/// The door a community's own contracts pay through. A seat mint's 40% and the ledger's 15% yield
/// share land in one balance with Qudi's grants. The callee decides which community a caller may
/// top up and what kind of leg it is, and the USDC must be in `CreditCore` before it is booked.
contract CreditCoreCommunityLegTest is CreditFixture {
    Community a;
    uint256 aId;
    address ledgerA;
    Community b;
    uint256 bId;

    uint256 constant LEG = 500e6;

    function setUp() public override {
        super.setUp();
        (a, aId,) = _community(0, 1);
        (b, bId,) = _community(0, 1);
        ledgerA = address(_ledger(aId));
    }

    function _payLeg(address caller, uint256 id, uint256 amount) internal {
        usdc.mint(caller, amount);
        vm.startPrank(caller);
        usdc.transfer(address(core), amount);
        core.receiveCommunityLeg(id, amount);
        vm.stopPrank();
    }

    function test_leg_registeredContractToItsOwnCommunity() public {
        _payLeg(address(a), aId, LEG);
        _payLeg(ledgerA, aId, LEG);
        assertEq(_credit(aId).allocation, 2 * LEG);
        assertEq(core.poolView().totalAllocated, 2 * LEG);
        assertEq(core.expectedCash(), usdc.balanceOf(address(core)));
    }

    /// A leg brings its own cash, so it needs none of Qudi's and leaves Qudi's money where it was.
    function test_leg_movesNoQudiMoney() public {
        _payLeg(address(a), aId, LEG);
        assertEq(_unallocated(), 0);
    }

    /// A registered contract cannot name another community.
    function test_leg_registeredContractCannotNameAnotherCommunity() public {
        usdc.mint(address(a), LEG);
        vm.startPrank(address(a));
        usdc.transfer(address(core), LEG);
        vm.expectRevert(ICreditCore.CommunityMismatch.selector);
        core.receiveCommunityLeg(bId, LEG);
        vm.stopPrank();
        assertEq(_credit(bId).allocation, 0, "the named community got nothing");
        assertEq(_credit(aId).allocation, 0, "and neither did the caller's own");
    }

    function test_leg_unregisteredCallerIsRefused() public {
        usdc.mint(stranger, LEG);
        vm.startPrank(stranger);
        usdc.transfer(address(core), LEG);
        vm.expectRevert(ICreditCore.NotCommunityContract.selector);
        core.receiveCommunityLeg(aId, LEG);
        vm.stopPrank();
        assertEq(_credit(aId).allocation, 0);
    }

    /// Being registered is not enough: the USDC has to have arrived.
    function test_leg_unfundedLegIsRefused() public {
        vm.prank(address(a));
        vm.expectRevert(ICreditCore.LegNotFunded.selector);
        core.receiveCommunityLeg(aId, LEG);
        assertEq(_credit(aId).allocation, 0);
        assertEq(core.expectedCash(), usdc.balanceOf(address(core)));
    }

    /// The community clone pays the seat leg and its ledger pays the yield leg. The kind comes from
    /// the caller, never from an argument, so no caller can label its own leg.
    function test_leg_kindIsDerivedFromTheCaller() public {
        usdc.mint(address(a), LEG);
        vm.startPrank(address(a));
        usdc.transfer(address(core), LEG);
        vm.expectEmit(true, true, true, true, address(core));
        emit ICreditCore.AllocationAssigned(aId, ICreditCore.AllocationType.SeatMint, LEG, address(a), 0, LEG);
        core.receiveCommunityLeg(aId, LEG);
        vm.stopPrank();

        usdc.mint(ledgerA, LEG);
        vm.startPrank(ledgerA);
        usdc.transfer(address(core), LEG);
        vm.expectEmit(true, true, true, true, address(core));
        emit ICreditCore.AllocationAssigned(aId, ICreditCore.AllocationType.Yield, LEG, ledgerA, 0, 2 * LEG);
        core.receiveCommunityLeg(aId, LEG);
        vm.stopPrank();
    }

    /// A seat leg is community activity. A yield leg is not: yield arrives whether or not anyone
    /// does anything.
    function test_leg_aSeatLegIsActivityAndAYieldLegIsNot() public {
        uint64 start = _credit(aId).lastActivityAt;
        vm.warp(block.timestamp + 10 days);
        _payLeg(ledgerA, aId, LEG);
        assertEq(_credit(aId).lastActivityAt, start);
        _payLeg(address(a), aId, LEG);
        assertEq(_credit(aId).lastActivityAt, block.timestamp);
    }

    function test_leg_zeroAmountIsRefused() public {
        vm.prank(address(a));
        vm.expectRevert(ICreditCore.ZeroAmount.selector);
        core.receiveCommunityLeg(aId, 0);
    }

    // ---- closure ----

    /// Closing returns the balance, however it was built, to Qudi's unallocated money.
    function test_closure_returnsANonZeroBalanceToTheTreasury() public {
        _payLeg(address(a), aId, LEG);
        _grant(aId, LEG);
        uint256 cashBefore = usdc.balanceOf(address(core));

        vm.expectEmit(true, false, false, true, address(core));
        emit ICreditCore.CommunityClosed(aId, 2 * LEG);
        core.closeCommunity(aId);

        assertEq(_credit(aId).allocation, 0);
        assertTrue(_credit(aId).closed);
        assertEq(core.poolView().totalAllocated, 0);
        assertEq(usdc.balanceOf(address(core)), cashBefore, "no USDC left the contract");
        assertEq(_unallocated(), 2 * LEG, "it became Qudi's unallocated money");
    }

    /// Closure waits for every advance in the community.
    function test_closure_stillBlockedByUnresolvedDebt() public {
        (, uint256 cId, address[] memory pc) = _community(100e6, 6);
        _season();
        _draw(pc[1], cId, 20e6);
        vm.expectRevert(ICreditCore.CommunityHasDebt.selector);
        core.closeCommunity(cId);
        _repayAll(pc[1]);
        core.closeCommunity(cId);
    }

    /// A closed account closes no second time and takes nothing through either door.
    function test_closure_isTerminalForBothDoors() public {
        core.closeCommunity(aId);
        vm.expectRevert(ICreditCore.AlreadyClosed.selector);
        core.closeCommunity(aId);

        usdc.mint(address(a), LEG);
        vm.startPrank(address(a));
        usdc.transfer(address(core), LEG);
        vm.expectRevert(ICreditCore.CommunityIsClosed.selector);
        core.receiveCommunityLeg(aId, LEG);
        vm.stopPrank();
    }

    function test_closure_onlyTheOwner() public {
        vm.prank(stranger);
        vm.expectRevert();
        core.closeCommunity(aId);
    }
}
