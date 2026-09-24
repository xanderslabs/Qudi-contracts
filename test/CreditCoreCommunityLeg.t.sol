// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {CreditStanding} from "../src/CreditStanding.sol";
import {ICreditCore} from "../src/interfaces/ICreditCore.sol";
import {IConfig} from "../src/interfaces/IConfig.sol";
import {Config} from "../src/Config.sol";
import {MockUSDC} from "./mocks/MockUSDC.sol";
import {CreditCoreHarness} from "./helpers/CreditCoreHarness.sol";
import {MockCommunityFactory} from "./helpers/MockCommunityFactory.sol";

/// `NullCreditPool` is deleted and the three legs pay `CreditCore` directly,
/// through a second door: one balance,
/// `_allocationOf[communityId]`, topped up either by the Allocation Multisig's `allocate` or by
/// a registered community contract's `receiveCommunityLeg`.
///
/// Proofs 1 to 4 are the new door and its caller gate. Proofs 5 to 7 are closure, which is
/// narrowed: the balance returns to Qudi and the community enters a closed state, with the
/// debt gate untouched.
contract CreditCoreCommunityLegTest is Test {
    MockUSDC usdc;
    Config config;
    MockCommunityFactory factory;
    CreditStanding standing;
    CreditCoreHarness cc;

    address governance = makeAddr("governance");
    address treasuryMgr = makeAddr("treasuryManager");
    address allocationMs = makeAddr("allocationMultisig");

    /// A registered community contract of community 0, standing in for a seats or ledger clone.
    address communityZero = makeAddr("seatsOfCommunityZero");
    /// A registered community contract of community 1.
    address communityOne = makeAddr("seatsOfCommunityOne");
    /// A registered community contract of community 0 that is NOT its seats: a ledger clone. The leg
    /// kind is derived by comparing the caller against the seats address, so this is what a
    /// Yield leg looks like.
    address ledgerOfZero = makeAddr("ledgerOfCommunityZero");
    address stranger = makeAddr("stranger");

    /// Empty book, 2 communities: operating = max(2 * 2000e6, 10_000e6) = 10_000e6;
    /// stress = max(0, 100_000e6) = 100_000e6; the other three components are 0.
    uint256 constant BASE_REQUIRED = 110_000e6;
    uint256 constant LEG = 500e6;

    function setUp() public {
        usdc = new MockUSDC();
        config = new Config(address(usdc), makeAddr("treasury"), makeAddr("registry"));
        factory = new MockCommunityFactory();
        factory.setCommunityCount(2);
        factory.register(communityZero, 0);
        factory.register(communityOne, 1);
        factory.register(ledgerOfZero, 0);
        factory.setSeats(0, communityZero);
        factory.setSeats(1, communityOne);
        standing = new CreditStanding(IConfig(address(config)), address(factory), governance);
        cc = new CreditCoreHarness(
            IERC20(address(usdc)),
            IConfig(address(config)),
            address(factory),
            governance,
            treasuryMgr,
            allocationMs,
            standing
        );
        vm.prank(governance);
        standing.setCreditCore(address(cc));
    }

    function _fund(uint256 amount) internal {
        usdc.mint(governance, amount);
        vm.startPrank(governance);
        usdc.approve(address(cc), amount);
        cc.fund(amount);
        vm.stopPrank();
    }

    /// What a leg actually is: the caller has already moved the USDC in, exactly as
    /// `Community._split` and `Venue.claimPoolLeg` do, and then names the community.
    function _payLeg(address caller, uint256 communityId, uint256 amount) internal {
        usdc.mint(caller, amount);
        vm.startPrank(caller);
        usdc.transfer(address(cc), amount);
        cc.receiveCommunityLeg(communityId, amount);
        vm.stopPrank();
    }

    // -----------------------------------------------------------------
    // Proof 1: a registered community contract tops up its own community
    // -----------------------------------------------------------------

    function test_leg_registeredContractToItsOwnCommunity() public {
        uint256 before = cc.allocationOf(0);
        uint256 totalBefore = cc.totalAllocated();

        usdc.mint(communityZero, LEG);
        vm.startPrank(communityZero);
        usdc.transfer(address(cc), LEG);
        // `unallocated` is 0 in the event because nothing funded this Treasury: the leg raised
        // cash and allocation by the same amount, which is proof 4's point seen from here.
        vm.expectEmit(true, true, false, true);
        emit ICreditCore.AllocationAssigned(0, ICreditCore.AllocationType.SeatMint, LEG, communityZero, 0, before + LEG);
        cc.receiveCommunityLeg(0, LEG);
        vm.stopPrank();

        assertEq(cc.allocationOf(0), before + LEG, "the community balance rose by the leg");
        assertEq(cc.totalAllocated(), totalBefore + LEG, "and so did the global total");
        assertEq(cc.expectedCash(), usdc.balanceOf(address(cc)), "the booked-cash mirror still matches");
    }

    /// Both doors reach one balance and emit one event: provenance is the event's
    /// `kind`, not a second mapping.
    function test_leg_andAllocateShareOneBalance() public {
        _fund(BASE_REQUIRED + 1_000e6);
        vm.prank(allocationMs);
        cc.allocate(0, 300e6, ICreditCore.AllocationType.Growth);
        _payLeg(communityZero, 0, LEG);
        assertEq(cc.allocationOf(0), 300e6 + LEG);
        assertEq(cc.totalAllocated(), 300e6 + LEG);
    }

    // -----------------------------------------------------------------
    // Proof 2: a registered community contract cannot name a different community
    // -----------------------------------------------------------------

    /// The rejected alternative is the one where the caller passes its own seats address for
    /// the factory to resolve. This is that rejection made explicit: the callee decides which
    /// community a caller belongs to, so naming another one reverts.
    function test_leg_registeredContractCannotNameAnotherCommunity() public {
        usdc.mint(communityZero, LEG);
        vm.startPrank(communityZero);
        usdc.transfer(address(cc), LEG);
        vm.expectRevert(ICreditCore.CommunityMismatch.selector);
        cc.receiveCommunityLeg(1, LEG);
        vm.stopPrank();

        assertEq(cc.allocationOf(1), 0, "the named community got nothing");
        assertEq(cc.allocationOf(0), 0, "and neither did the caller's own");
    }

    // -----------------------------------------------------------------
    // Proof 3: an unregistered address cannot call it at all
    // -----------------------------------------------------------------

    function test_leg_unregisteredCallerIsRefused() public {
        usdc.mint(stranger, LEG);
        vm.startPrank(stranger);
        usdc.transfer(address(cc), LEG);
        vm.expectRevert(ICreditCore.NotCommunityContract.selector);
        cc.receiveCommunityLeg(0, LEG);
        vm.stopPrank();

        assertEq(cc.allocationOf(0), 0);
        assertEq(cc.totalAllocated(), 0);
    }

    /// The other half of the caller gate: being registered is not enough, the USDC has to have
    /// arrived. A registered contract that books a leg it never paid is refused, which is what
    /// keeps `expectedCash()` equal to the real balance.
    function test_leg_unfundedLegIsRefused() public {
        vm.prank(communityZero);
        vm.expectRevert(ICreditCore.LegNotFunded.selector);
        cc.receiveCommunityLeg(0, LEG);

        assertEq(cc.allocationOf(0), 0);
        assertEq(cc.expectedCash(), usdc.balanceOf(address(cc)));
    }

    /// The kind is derived from the caller, never supplied (2026-09-21). The seats clone pays
    /// the mint leg and any other registered contract of that community pays a yield leg, so
    /// `AllocationAssigned` carries real provenance without a caller labelling itself. This is
    /// also what makes `Growth` and `Stabilization` unreachable here: no argument can name them.
    function test_leg_kindIsDerivedFromTheCaller() public {
        usdc.mint(communityZero, LEG);
        vm.startPrank(communityZero);
        usdc.transfer(address(cc), LEG);
        vm.expectEmit(true, true, true, true, address(cc));
        emit ICreditCore.AllocationAssigned(
            0, ICreditCore.AllocationType.SeatMint, LEG, communityZero, 0, cc.allocationOf(0) + LEG
        );
        cc.receiveCommunityLeg(0, LEG);
        vm.stopPrank();

        // A ledger of the same community is not the seats address, so its leg is Yield.
        usdc.mint(ledgerOfZero, LEG);
        vm.startPrank(ledgerOfZero);
        usdc.transfer(address(cc), LEG);
        vm.expectEmit(true, true, true, true, address(cc));
        emit ICreditCore.AllocationAssigned(
            0, ICreditCore.AllocationType.Yield, LEG, ledgerOfZero, 0, cc.allocationOf(0) + LEG
        );
        cc.receiveCommunityLeg(0, LEG);
        vm.stopPrank();
    }

    function test_leg_zeroAmountIsRefused() public {
        vm.prank(communityZero);
        vm.expectRevert(ICreditCore.ZeroAmount.selector);
        cc.receiveCommunityLeg(0, 0);
    }

    // -----------------------------------------------------------------
    // Proof 4: a leg does not breach the retained-capital gate, where an `allocate` of
    // the same size would
    // -----------------------------------------------------------------

    /// Tested rather than argued. A leg raises cash
    /// and allocation together, so unallocated cash does not move and the gate is not a path it
    /// belongs on; `allocate` moves existing cash from unallocated to allocated, which is.
    function test_leg_doesNotBreachRetainedCapitalWhereAllocateWould() public {
        _fund(BASE_REQUIRED); // exactly the requirement: no unallocated headroom at all
        assertEq(cc.requiredRetainedCapital(), BASE_REQUIRED);

        vm.prank(allocationMs);
        vm.expectRevert(ICreditCore.BelowRetainedCapital.selector);
        cc.allocate(0, LEG, ICreditCore.AllocationType.Growth);

        _payLeg(communityZero, 0, LEG);
        assertEq(cc.allocationOf(0), LEG, "the leg of the same size landed");

        // And the gate it skipped would have passed anyway: both sides rose by `LEG`.
        assertGe(
            usdc.balanceOf(address(cc)),
            cc.totalAllocated() + cc.requiredRetainedCapital(),
            "a leg leaves the treasury no worse against the retained-capital gate than it found it"
        );
    }

    // -----------------------------------------------------------------
    // Proof 5: closure returns a non-zero balance to Qudi
    // -----------------------------------------------------------------

    /// Winding up a dead community's books is terminal, not a
    /// recall at will, so the balance returns to the global Treasury and the community closes.
    function test_closure_returnsANonZeroBalanceToTheTreasury() public {
        _fund(BASE_REQUIRED + 1_000e6);
        vm.prank(allocationMs);
        cc.allocate(0, LEG, ICreditCore.AllocationType.Growth);
        assertEq(cc.allocationOf(0), LEG);

        uint256 cashBefore = usdc.balanceOf(address(cc));
        uint256 unallocatedBefore = cc.unallocated();

        vm.expectEmit(true, false, false, true);
        emit ICreditCore.CommunityClosed(0, LEG);
        vm.prank(governance);
        cc.closeCommunity(0);

        assertEq(cc.allocationOf(0), 0, "the balance is zeroed");
        assertEq(cc.totalAllocated(), 0, "and _totalAllocated is decremented by it");
        assertTrue(cc.isCommunityClosed(0));
        assertEq(usdc.balanceOf(address(cc)), cashBefore, "no USDC left the contract");
        assertEq(cc.unallocated(), unallocatedBefore + LEG, "it became unallocated Treasury cash");
        assertEq(cc.expectedCash(), usdc.balanceOf(address(cc)));
    }

    /// The same, for a balance built by legs rather than by a grant: one balance means closure
    /// does not care which door the money came through.
    function test_closure_returnsALegBuiltBalance() public {
        _payLeg(communityZero, 0, LEG);
        vm.expectEmit(true, false, false, true);
        emit ICreditCore.CommunityClosed(0, LEG);
        vm.prank(governance);
        cc.closeCommunity(0);
        assertEq(cc.allocationOf(0), 0);
        assertEq(cc.totalAllocated(), 0);
    }

    // -----------------------------------------------------------------
    // Proof 6: the debt gate survived the narrowing
    // -----------------------------------------------------------------

    /// The no-recall rule was narrowed, not removed. `_communityHasUnresolvedDebt` reads
    /// `_openObligationCount[communityId] > 0`, and closure still reverts while it is true, even
    /// with a balance the new rule would otherwise return.
    function test_closure_stillBlockedByUnresolvedDebt() public {
        _payLeg(communityZero, 0, LEG);
        cc.setCommunityDebt(0, true);

        vm.prank(governance);
        vm.expectRevert(ICreditCore.CommunityHasDebt.selector);
        cc.closeCommunity(0);

        assertEq(cc.allocationOf(0), LEG, "the balance is untouched");
        assertEq(cc.totalAllocated(), LEG);
        assertFalse(cc.isCommunityClosed(0));

        // It clears, and only then does closure return the balance.
        cc.setCommunityDebt(0, false);
        vm.prank(governance);
        cc.closeCommunity(0);
        assertEq(cc.allocationOf(0), 0);
    }

    // -----------------------------------------------------------------
    // Proof 7: a closed community closes no second time and takes no more money
    // -----------------------------------------------------------------

    function test_closure_isTerminalForBothDoors() public {
        _fund(BASE_REQUIRED + 1_000e6);
        _payLeg(communityZero, 0, LEG);
        vm.prank(governance);
        cc.closeCommunity(0);

        vm.prank(governance);
        vm.expectRevert(ICreditCore.AlreadyClosed.selector);
        cc.closeCommunity(0);

        vm.prank(allocationMs);
        vm.expectRevert(ICreditCore.CommunityIsClosed.selector);
        cc.allocate(0, LEG, ICreditCore.AllocationType.Growth);

        usdc.mint(communityZero, LEG);
        vm.startPrank(communityZero);
        usdc.transfer(address(cc), LEG);
        vm.expectRevert(ICreditCore.CommunityIsClosed.selector);
        cc.receiveCommunityLeg(0, LEG);
        vm.stopPrank();

        assertEq(cc.allocationOf(0), 0, "a closed community's balance stays at zero");
    }

    /// An id past the factory's community count is not a community, through either door.
    function test_leg_unknownCommunityIsRefused() public {
        factory.register(stranger, 7);
        usdc.mint(stranger, LEG);
        vm.startPrank(stranger);
        usdc.transfer(address(cc), LEG);
        vm.expectRevert(ICreditCore.UnknownCommunity.selector);
        cc.receiveCommunityLeg(7, LEG);
        vm.stopPrank();
    }
}
