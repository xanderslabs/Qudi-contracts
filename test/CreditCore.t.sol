// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {CreditCore} from "../src/CreditCore.sol";
import {CreditStanding} from "../src/CreditStanding.sol";
import {ICreditCore} from "../src/interfaces/ICreditCore.sol";
import {ICreditStanding} from "../src/interfaces/ICreditStanding.sol";
import {Config} from "../src/Config.sol";
import {ConfigKeys as K} from "../src/ConfigKeys.sol";
import {IConfig} from "../src/interfaces/IConfig.sol";
import {MockUSDC} from "./mocks/MockUSDC.sol";
import {MockVenue} from "./mocks/MockVenue.sol";
import {PredatoryVenue} from "./mocks/PredatoryVenue.sol";
import {CreditCoreHarness} from "./helpers/CreditCoreHarness.sol";
import {MockCommunityFactory} from "./helpers/MockCommunityFactory.sol";

/// The Treasury half of CreditCore. Conservation, the retained-capital gate on
/// every outflow, allocations, closure, and role separation.
contract CreditCoreTest is Test {
    MockUSDC usdc;
    Config config;
    MockCommunityFactory factory;
    CreditStanding standing;
    CreditCoreHarness cc;

    address governance = makeAddr("governance");
    address treasuryMgr = makeAddr("treasuryManager");
    address allocationMs = makeAddr("allocationMultisig");
    address member = makeAddr("member");

    // Empty book, 1 community: operating = max(1 * 2000e6, 10_000e6) = 10_000e6;
    // stress = max(0, 100_000e6) = 100_000e6; venue-loss = 0; credit-loss = 0; pending = 0.
    uint256 constant BASE_REQUIRED = 110_000e6;

    function setUp() public {
        usdc = new MockUSDC();
        config = new Config(address(usdc), makeAddr("treasury"), makeAddr("registry"));
        factory = new MockCommunityFactory();
        factory.setCommunityCount(1);
        // CreditStanding deploys first, CreditCore takes it as an immutable
        // constructor argument, then CreditStanding.setCreditCore wires the reverse direction.
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

    function _allocate(uint256 communityId, uint256 amount, ICreditCore.AllocationType kind) internal {
        vm.prank(allocationMs);
        cc.allocate(communityId, amount, kind);
    }

    // -----------------------------------------------------------------
    // Launch state
    // -----------------------------------------------------------------

    function test_launch() public view {
        assertEq(cc.treasuryManager(), treasuryMgr);
        assertEq(cc.allocationMultisig(), allocationMs);
        assertEq(cc.owner(), governance);
        assertEq(cc.totalAllocated(), 0);
        assertEq(cc.unallocated(), 0);
        assertEq(cc.requiredRetainedCapital(), BASE_REQUIRED);
        assertEq(cc.surplus(), -int256(BASE_REQUIRED));
    }

    function test_constructorRejectsZeroAddresses() public {
        vm.expectRevert(ICreditCore.ZeroAddress.selector);
        new CreditCore(
            IERC20(address(usdc)), IConfig(address(config)), address(0), governance, treasuryMgr, allocationMs, standing
        );
        vm.expectRevert(ICreditCore.ZeroAddress.selector);
        new CreditCore(
            IERC20(address(usdc)),
            IConfig(address(config)),
            address(factory),
            governance,
            address(0),
            allocationMs,
            standing
        );
        // The immutable `standing` argument is zero-checked too.
        vm.expectRevert(ICreditCore.ZeroAddress.selector);
        new CreditCore(
            IERC20(address(usdc)),
            IConfig(address(config)),
            address(factory),
            governance,
            treasuryMgr,
            allocationMs,
            ICreditStanding(address(0))
        );
    }

    // -----------------------------------------------------------------
    // Test 3: no member / non-role caller can move Treasury funds
    // -----------------------------------------------------------------

    function test_noMemberCanMoveFunds() public {
        _fund(BASE_REQUIRED + 100e6);
        factory.setCommunityCount(2);
        uint256 balBefore = usdc.balanceOf(address(cc));

        vm.startPrank(member);
        vm.expectRevert();
        cc.fund(1e6);
        vm.expectRevert(ICreditCore.NotAllocationMultisig.selector);
        cc.allocate(0, 1e6, ICreditCore.AllocationType.Growth);
        vm.expectRevert();
        cc.closeCommunity(0);
        vm.expectRevert();
        cc.setTreasuryManager(member);
        vm.expectRevert();
        cc.setAllocationMultisig(member);
        vm.expectRevert();
        cc.addVenue(address(1));
        vm.expectRevert();
        cc.removeVenue(address(1));
        vm.expectRevert(ICreditCore.NotTreasuryManager.selector);
        cc.depositToVenue(address(1), 1e6);
        vm.expectRevert(ICreditCore.NotTreasuryManager.selector);
        cc.withdrawFromVenue(address(1), 1e6);
        vm.expectRevert();
        cc.transferOwnership(member);
        vm.expectRevert();
        cc.acceptOwnership();
        vm.expectRevert();
        cc.renounceOwnership();
        vm.stopPrank();

        assertEq(usdc.balanceOf(address(cc)), balBefore); // nothing moved
    }

    // -----------------------------------------------------------------
    // Test 4: the retained-capital gate, at the boundary from both sides
    // -----------------------------------------------------------------

    function test_allocateBoundary() public {
        _fund(BASE_REQUIRED + 500e6); // 500e6 of headroom above the requirement

        // one unit outside: reverts
        vm.prank(allocationMs);
        vm.expectRevert(ICreditCore.BelowRetainedCapital.selector);
        cc.allocate(0, 500e6 + 1, ICreditCore.AllocationType.Growth);

        // exactly at the boundary: succeeds, leaving unallocated == the requirement
        _allocate(0, 500e6, ICreditCore.AllocationType.Growth);
        assertEq(cc.unallocated(), BASE_REQUIRED);
        assertEq(cc.totalAllocated(), 500e6);
        assertEq(cc.surplus(), 0);

        // one more unit now reverts
        vm.prank(allocationMs);
        vm.expectRevert(ICreditCore.BelowRetainedCapital.selector);
        cc.allocate(0, 1, ICreditCore.AllocationType.Growth);
    }

    function test_allocateUnknownOrClosedCommunity() public {
        _fund(BASE_REQUIRED + 100e6);
        vm.prank(allocationMs);
        vm.expectRevert(ICreditCore.UnknownCommunity.selector);
        cc.allocate(1, 1e6, ICreditCore.AllocationType.Growth); // communityCount is 1, so id 1 is out of range

        // Close community 0 while it holds no allocation (closure is permitted only then),
        // then a further allocation to it is rejected as closed.
        vm.prank(governance);
        cc.closeCommunity(0);
        vm.prank(allocationMs);
        vm.expectRevert(ICreditCore.CommunityIsClosed.selector);
        cc.allocate(0, 1e6, ICreditCore.AllocationType.Growth);
    }

    // -----------------------------------------------------------------
    // Test 6: venue positions and receivables do not count toward the requirement being met
    // -----------------------------------------------------------------

    function test_venuePositionsDoNotCountAsCash() public {
        _fund(BASE_REQUIRED + 300e6);
        _allocate(0, 100e6, ICreditCore.AllocationType.Growth);
        // headroom above the requirement is now 200e6

        MockVenue venue = new MockVenue(IERC20(address(usdc)), "V", "V");
        cc.addVenue(address(venue));

        // 100e6 into the venue: cash falls by 100e6, and the venue-loss reserve rises by
        // 20% of the 100e6 exposure = 20e6, so unallocated headroom falls by 120e6 total.
        vm.prank(treasuryMgr);
        cc.depositToVenue(address(venue), 100e6);

        assertEq(usdc.balanceOf(address(cc)), BASE_REQUIRED + 300e6 - 100e6); // cash, venue excluded
        assertEq(cc.largestVenueExposure(), 100e6);
        assertEq(cc.requiredRetainedCapital(), BASE_REQUIRED + 20e6); // venue-loss reserve added
        // unallocated is cash minus allocations; the venue position is not added back
        assertEq(cc.unallocated(), (BASE_REQUIRED + 300e6 - 100e6) - 100e6);

        // a further allocation is capped by cash, not by cash plus the venue position
        vm.prank(allocationMs);
        vm.expectRevert(ICreditCore.BelowRetainedCapital.selector);
        cc.allocate(0, 81e6, ICreditCore.AllocationType.Growth); // 80e6 headroom left (200 - 100 venue - 20 reserve)
        _allocate(0, 80e6, ICreditCore.AllocationType.Growth);
        assertEq(cc.surplus(), 0);
    }

    function test_venueDepositBlockedWhenItWouldBreach() public {
        _fund(BASE_REQUIRED + 100e6);
        _allocate(0, 90e6, ICreditCore.AllocationType.Growth); // 10e6 headroom

        MockVenue venue = new MockVenue(IERC20(address(usdc)), "V", "V");
        cc.addVenue(address(venue));
        vm.prank(treasuryMgr);
        vm.expectRevert(ICreditCore.BelowRetainedCapital.selector);
        cc.depositToVenue(address(venue), 100e6);
    }

    // -----------------------------------------------------------------
    // Test 7: the formula reads the outstanding book, not an empty constant
    // -----------------------------------------------------------------

    function test_formulaReadsTheBook() public {
        uint256 base = cc.requiredRetainedCapital();
        assertEq(base, BASE_REQUIRED);

        // 1,000,000e6 all at Current: credit-loss reserve = 5% = 50,000e6.
        // total outstanding 1,000,000e6: stress by-rate = 10% = 100,000e6 == the floor, unchanged.
        cc.setBook(1_000_000e6, 0, 0, 0);
        assertEq(cc.requiredRetainedCapital(), base + 50_000e6);

        // move the same book to Default Recovery: reserve = 100% = 1,000,000e6.
        cc.setBook(0, 0, 0, 1_000_000e6);
        assertEq(cc.requiredRetainedCapital(), base + 1_000_000e6);

        // 2,000,000e6 total: stress by-rate = 200,000e6 now exceeds the 100,000e6 floor.
        cc.setBook(500_000e6, 500_000e6, 500_000e6, 500_000e6);
        // credit-loss = 5% * 500k + 25% * 500k + 50% * 500k + 100% * 500k = (25+125+250+500)k = 900,000e6
        // stress = max(200,000e6, 100,000e6) = 200,000e6, so +100,000e6 over the floor
        assertEq(cc.requiredRetainedCapital(), BASE_REQUIRED + 900_000e6 + 100_000e6);

        cc.setBook(0, 0, 0, 0);
        assertEq(cc.requiredRetainedCapital(), base);
    }

    function test_creditLossReserveRoundsUp() public {
        // 1 unit at Current, 5% -> ceil(1 * 500 / 10000) = ceil(0.05) = 1, not 0.
        cc.setBook(1, 0, 0, 0);
        assertEq(cc.requiredRetainedCapital(), BASE_REQUIRED + 1);
        // 3 units at Late, 25% -> ceil(3 * 2500 / 10000) = ceil(0.75) = 1
        cc.setBook(0, 3, 0, 0);
        assertEq(cc.requiredRetainedCapital(), BASE_REQUIRED + 1);
    }

    function test_pendingObligationSeamAddsToRequirement() public {
        cc.setPendingObligationReserve(12_345e6);
        assertEq(cc.requiredRetainedCapital(), BASE_REQUIRED + 12_345e6);
    }

    function test_operatingRequirementScalesWithCommunities() public {
        assertEq(cc.requiredRetainedCapital(), BASE_REQUIRED);
        factory.setCommunityCount(6); // 6 * 2000e6 = 12_000e6 > 10_000e6 floor
        assertEq(cc.requiredRetainedCapital(), BASE_REQUIRED + 2_000e6);
    }

    // -----------------------------------------------------------------
    // Test 8: allocations record everything, both types
    // -----------------------------------------------------------------

    function test_allocationEventRecordsEverything() public {
        _fund(BASE_REQUIRED + 1_000e6);
        factory.setCommunityCount(3);

        vm.expectEmit(true, true, false, true);
        emit ICreditCore.AllocationAssigned(
            2, ICreditCore.AllocationType.Growth, 400e6, allocationMs, BASE_REQUIRED + 600e6, 400e6
        );
        _allocate(2, 400e6, ICreditCore.AllocationType.Growth);

        vm.expectEmit(true, true, false, true);
        emit ICreditCore.AllocationAssigned(
            1, ICreditCore.AllocationType.Stabilization, 300e6, allocationMs, BASE_REQUIRED + 300e6, 300e6
        );
        _allocate(1, 300e6, ICreditCore.AllocationType.Stabilization);

        assertEq(cc.allocationOf(2), 400e6);
        assertEq(cc.allocationOf(1), 300e6);
        assertEq(cc.totalAllocated(), 700e6);
    }

    // -----------------------------------------------------------------
    // Test 9: an allocation cannot be recalled before wind-down, by any caller
    // -----------------------------------------------------------------

    /// Closure is the only
    /// function that lowers an allocation, and it is still owner-only and still blocked by debt,
    /// so no role gets a recall path. What changed is that on a debt-free community the owner's
    /// closure now returns the balance instead of reverting; that is
    /// `test/CreditCoreCommunityLeg.t.sol`, and the durability the no-recall rule protects is what
    /// this test still holds: while an obligation is open, nobody can take the allocation back.
    function test_allocationNotRecallable() public {
        _fund(BASE_REQUIRED + 1_000e6);
        _allocate(0, 500e6, ICreditCore.AllocationType.Growth);

        cc.setCommunityDebt(0, true);
        address[3] memory callers = [governance, treasuryMgr, allocationMs];
        for (uint256 i; i < callers.length; i++) {
            vm.prank(callers[i]);
            vm.expectRevert();
            cc.closeCommunity(0);
        }
        assertEq(cc.allocationOf(0), 500e6); // untouched
        assertEq(cc.totalAllocated(), 500e6);
    }

    /// Debt-free, and still no recall path for anyone but the owner. The owner's path is
    /// closure, which is terminal: it is an accounting wind-up, not a
    /// withdrawal that leaves the community running with less capacity than it had.
    function test_allocationNotRecallableByAnyRoleButTheOwner() public {
        _fund(BASE_REQUIRED + 1_000e6);
        _allocate(0, 500e6, ICreditCore.AllocationType.Growth);
        assertFalse(cc.communityHasUnresolvedDebt(0));

        address[3] memory roles = [treasuryMgr, allocationMs, member];
        for (uint256 i; i < roles.length; i++) {
            vm.prank(roles[i]);
            vm.expectRevert(); // OwnableUnauthorizedAccount
            cc.closeCommunity(0);
        }
        assertEq(cc.allocationOf(0), 500e6);
        assertEq(cc.totalAllocated(), 500e6);
        assertFalse(cc.isCommunityClosed(0));

        // The owner's one path takes the community with it.
        vm.prank(governance);
        cc.closeCommunity(0);
        assertTrue(cc.isCommunityClosed(0));
        assertEq(cc.allocationOf(0), 0);
    }

    // -----------------------------------------------------------------
    // Test 10: closure is blocked by debt, and succeeds on a debt-free community
    // -----------------------------------------------------------------

    function test_closureBlockedByDebt() public {
        _fund(BASE_REQUIRED + 1_000e6);
        cc.setCommunityDebt(0, true);
        vm.prank(governance);
        vm.expectRevert(ICreditCore.CommunityHasDebt.selector);
        cc.closeCommunity(0);

        // debt clears: closure succeeds
        cc.setCommunityDebt(0, false);
        vm.prank(governance);
        cc.closeCommunity(0);
        assertTrue(cc.isCommunityClosed(0));
    }

    function test_closureSucceedsWithNoAllocationAndIsIdempotent() public {
        _fund(BASE_REQUIRED + 1_000e6);
        uint256 unallocBefore = cc.unallocated();

        vm.expectEmit(true, false, false, true);
        emit ICreditCore.CommunityClosed(0, 0);
        vm.prank(governance);
        cc.closeCommunity(0);

        assertEq(cc.allocationOf(0), 0);
        assertEq(cc.totalAllocated(), 0);
        assertEq(cc.unallocated(), unallocBefore); // no cash moved
        assertTrue(cc.isCommunityClosed(0));

        vm.prank(governance);
        vm.expectRevert(ICreditCore.AlreadyClosed.selector);
        cc.closeCommunity(0);
    }

    // -----------------------------------------------------------------
    // Test 11: the Treasury Manager cannot distribute surplus, transfer to the company,
    // or move member assets. One case each.
    // -----------------------------------------------------------------

    function test_treasuryManagerIsBoxedIn() public {
        _fund(BASE_REQUIRED + 1_000e6);

        vm.startPrank(treasuryMgr);
        // cannot allocate (that is the Allocation Multisig; a "distribution" of capital)
        vm.expectRevert(ICreditCore.NotAllocationMultisig.selector);
        cc.allocate(0, 1e6, ICreditCore.AllocationType.Growth);
        // cannot move funds to an arbitrary address (a "company wallet"): the only sink is an
        // owner-allowlisted ERC-4626 venue
        vm.expectRevert(ICreditCore.UnknownVenue.selector);
        cc.depositToVenue(treasuryMgr, 1e6);
        // cannot seed or close (owner only); there is no surplus or company-transfer function
        vm.expectRevert();
        cc.fund(1e6);
        vm.expectRevert();
        cc.closeCommunity(0);
        vm.stopPrank();

        assertEq(usdc.balanceOf(address(cc)), BASE_REQUIRED + 1_000e6);
    }

    // -----------------------------------------------------------------
    // Listing a venue grants no allowance; a malicious venue takes nothing
    // -----------------------------------------------------------------

    /// A review's proof of concept. A predatory venue passes `addVenue`'s `asset()`
    /// check, then tries to pull the whole Treasury through `transferFrom`. It must take
    /// nothing: before listing, after listing, and after a legitimate deposit/redeem cycle.
    /// The USDC allowance to any venue is zero at rest at every one of those points.
    ///
    /// Against the pre-fix code this test fails: `addVenue` did
    /// `usdc.forceApprove(venue, type(uint256).max)`, so `drain()` after listing emptied the
    /// Treasury, allocations and retained capital included, without a deposit ever landing.
    function test_maliciousVenueTakesNothing() public {
        _fund(1_000_000e6);
        _allocate(0, 400_000e6, ICreditCore.AllocationType.Growth);
        uint256 treasuryBal = usdc.balanceOf(address(cc));
        assertEq(treasuryBal, 1_000_000e6);

        PredatoryVenue predator = new PredatoryVenue(IERC20(address(usdc)), address(cc));

        // before listing: no allowance, drain reverts, nothing moves
        assertEq(usdc.allowance(address(cc), address(predator)), 0);
        vm.expectRevert();
        predator.drain();
        assertEq(usdc.balanceOf(address(cc)), treasuryBal);

        // owner lists it: still no allowance
        cc.addVenue(address(predator));
        assertEq(usdc.allowance(address(cc), address(predator)), 0);
        vm.expectRevert();
        predator.drain();
        assertEq(usdc.balanceOf(address(cc)), treasuryBal);
        assertEq(cc.totalAllocated(), 400_000e6);

        // a legitimate venue runs a full deposit/redeem cycle alongside it; the allowance to
        // both venues is zero at rest before, between, and after
        MockVenue good = new MockVenue(IERC20(address(usdc)), "G", "G");
        cc.addVenue(address(good));
        assertEq(usdc.allowance(address(cc), address(good)), 0);

        vm.prank(treasuryMgr);
        cc.depositToVenue(address(good), 50_000e6);
        assertEq(usdc.allowance(address(cc), address(good)), 0); // reset immediately after deposit

        uint256 goodShares = good.balanceOf(address(cc));
        vm.prank(treasuryMgr);
        cc.withdrawFromVenue(address(good), goodShares);
        assertEq(usdc.allowance(address(cc), address(good)), 0);

        // predator still takes nothing after all of that
        assertEq(usdc.allowance(address(cc), address(predator)), 0);
        vm.expectRevert();
        predator.drain();
        assertEq(usdc.balanceOf(address(cc)), treasuryBal);
        assertEq(cc.totalAllocated(), 400_000e6);
    }

    // -----------------------------------------------------------------
    // The venue-allocation cap bounds depositToVenue
    // -----------------------------------------------------------------

    function test_venueAllocationCapBoundsDeposits() public {
        _fund(1_000_000e6);

        // Two venues: the aggregate cap is the constraint under test here, so the deposits are
        // split to stay under the 25% per-venue cap. liquid above the operating buffer
        // is (cash + venues) - allocations - operating = 990_000e6; aggregate cap = 50% =
        // 495_000e6, split 247_500e6 per venue (< 250_000e6 per-venue cap).
        MockVenue v1 = new MockVenue(IERC20(address(usdc)), "V1", "V1");
        MockVenue v2 = new MockVenue(IERC20(address(usdc)), "V2", "V2");
        cc.addVenue(address(v1));
        cc.addVenue(address(v2));

        vm.prank(treasuryMgr);
        cc.depositToVenue(address(v1), 247_500e6);
        vm.prank(treasuryMgr);
        cc.depositToVenue(address(v2), 247_500e6); // total 495_000e6, exactly the aggregate cap

        // one more unit into either venue exceeds the aggregate cap
        vm.prank(treasuryMgr);
        vm.expectRevert(ICreditCore.VenueAllocationCapExceeded.selector);
        cc.depositToVenue(address(v1), 1e6);
    }

    // -----------------------------------------------------------------
    // removeVenue's revert-on-balance guard
    // -----------------------------------------------------------------

    function test_removeVenueBlockedWhileHoldingBalance() public {
        _fund(1_000_000e6);
        MockVenue venue = new MockVenue(IERC20(address(usdc)), "V", "V");
        cc.addVenue(address(venue));

        vm.prank(treasuryMgr);
        cc.depositToVenue(address(venue), 40_000e6);

        vm.prank(governance);
        vm.expectRevert(ICreditCore.VenueHoldsBalance.selector);
        cc.removeVenue(address(venue));

        uint256 shares = venue.balanceOf(address(cc));
        vm.prank(treasuryMgr);
        cc.withdrawFromVenue(address(venue), shares);

        vm.prank(governance);
        cc.removeVenue(address(venue));
        assertFalse(cc.isVenue(address(venue)));
    }

    // -----------------------------------------------------------------
    // Rounding: every division favors the Treasury (rounds the requirement up)
    // -----------------------------------------------------------------

    function testFuzz_reserveComponentsNeverUnderstate(uint256 c, uint256 l, uint256 fc, uint256 dr) public {
        c = bound(c, 0, 100_000_000e6);
        l = bound(l, 0, 100_000_000e6);
        fc = bound(fc, 0, 100_000_000e6);
        dr = bound(dr, 0, 100_000_000e6);
        cc.setBook(c, l, fc, dr);

        (uint256 floorValued, uint256 slack) = _expectedRequirement(c, l, fc, dr);
        uint256 required = cc.requiredRetainedCapital();
        assertGe(required, floorValued); // never below the unrounded reserves plus the operating floor
        assertLe(required, floorValued + slack); // ceil rounds up by at most one unit per slice
    }

    /// The requirement computed with floor rounding (`floorValued`) and the maximum total the
    /// contract's ceil rounding can add over it (`slack`): one unit per credit-loss slice plus
    /// one for the stress-rate slice.
    function _expectedRequirement(uint256 c, uint256 l, uint256 fc, uint256 dr)
        internal
        view
        returns (uint256 floorValued, uint256 slack)
    {
        (uint16 rateBps, uint256 stressFloor) = config.stressCapital();
        uint256 stress = ((c + l + fc + dr) * rateBps) / 10_000;
        if (stress < stressFloor) stress = stressFloor;
        floorValued = 10_000e6 + _floorCreditLoss(c, l, fc, dr) + stress; // operating floor (0 or 1 community here)
        slack = 5;
    }

    function _floorCreditLoss(uint256 c, uint256 l, uint256 fc, uint256 dr) internal view returns (uint256) {
        (uint16 cb, uint16 lb, uint16 fcb, uint16 drb) = config.creditLossReserveBps();
        return (c * cb) / 10_000 + (l * lb) / 10_000 + (fc * fcb) / 10_000 + (dr * drb) / 10_000;
    }
}
