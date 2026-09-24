// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";
import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {ICreditCore} from "../../src/interfaces/ICreditCore.sol";
import {CreditStanding} from "../../src/CreditStanding.sol";
import {Config} from "../../src/Config.sol";
import {IConfig} from "../../src/interfaces/IConfig.sol";
import {MockUSDC} from "../mocks/MockUSDC.sol";
import {MockVenue} from "../mocks/MockVenue.sol";
import {CreditCoreHarness} from "../helpers/CreditCoreHarness.sol";
import {MockCommunityFactory} from "../helpers/MockCommunityFactory.sol";

/// Drives every state-changing path on `CreditCore` from the roles that own them, with real
/// verbs (fund, allocate, close, add a community, move venue capital, move the venue price,
/// change the book) rather than a stub that calls one function. Tracks ghost state the
/// invariants check the contract against.
contract CreditCoreHandler is Test {
    CreditCoreHarness public cc;
    MockUSDC public usdc;
    MockVenue public venue;
    MockVenue public venue2; // A second venue so the aggregate and
    // per-venue caps are each exercised deliberately rather than one masking the other.
    MockCommunityFactory public factory;

    address public governance;
    address public treasuryMgr;
    address public allocationMs;

    uint256 public ghostFunded; // total USDC ever seeded
    uint256 public ghostToVenue; // total USDC moved from CreditCore into the venue
    uint256 public ghostFromVenue; // total USDC redeemed from the venue back to CreditCore
    mapping(uint256 => uint256) public ghostAllocation;
    uint256 public ghostSumAllocations;
    bool public everBreachedByOutflow; // set if a successful outflow left cash below the requirement

    // Coverage counters: every call to a venue verb and how many landed.
    uint256 public venueDepositTries;
    uint256 public venueDepositLands;
    uint256 public venueWithdrawTries;
    uint256 public venueWithdrawLands;

    uint256 internal constant MAX_ID = 8;

    constructor(
        CreditCoreHarness cc_,
        MockUSDC usdc_,
        MockVenue venue_,
        MockVenue venue2_,
        MockCommunityFactory factory_,
        address governance_,
        address treasuryMgr_,
        address allocationMs_
    ) {
        cc = cc_;
        usdc = usdc_;
        venue = venue_;
        venue2 = venue2_;
        factory = factory_;
        governance = governance_;
        treasuryMgr = treasuryMgr_;
        allocationMs = allocationMs_;
    }

    /// Alternate deterministically between the two venues so both are exercised.
    function _pickVenue(uint256 turn) internal view returns (MockVenue) {
        return turn % 2 == 0 ? venue : venue2;
    }

    /// Per-venue headroom for `v`: the per-venue cap minus what `v` already holds, floored at 0.
    function _perVenueHeadroom(MockVenue v) internal view returns (uint256) {
        uint256 cap = cc.perVenueCap();
        uint256 held = cc.venueExposure(address(v));
        return cap > held ? cap - held : 0;
    }

    function _checkOutflow() internal {
        if (usdc.balanceOf(address(cc)) < cc.totalAllocated() + cc.requiredRetainedCapital()) {
            everBreachedByOutflow = true;
        }
    }

    function fund(uint256 amount) external {
        amount = bound(amount, 1, 5_000_000e6);
        usdc.mint(governance, amount);
        vm.startPrank(governance);
        usdc.approve(address(cc), amount);
        cc.fund(amount);
        vm.stopPrank();
        ghostFunded += amount;
    }

    function addCommunity() external {
        if (factory.communityCount() >= MAX_ID) return;
        factory.addCommunity();
    }

    function allocate(uint256 id, uint256 amount, uint8 kind) external {
        if (factory.communityCount() == 0) return;
        id = bound(id, 0, factory.communityCount() - 1);
        amount = bound(amount, 1, 5_000_000e6);
        vm.prank(allocationMs);
        try cc.allocate(id, amount, ICreditCore.AllocationType(kind % 2)) {
            ghostAllocation[id] += amount;
            ghostSumAllocations += amount;
            _checkOutflow();
        } catch {}
    }

    function closeCommunity(uint256 id) external {
        id = bound(id, 0, MAX_ID - 1);
        uint256 before = cc.allocationOf(id);
        vm.prank(governance);
        try cc.closeCommunity(id) {
            ghostSumAllocations -= before;
            ghostAllocation[id] = 0;
        } catch {}
    }

    function depositToVenue(uint256 amount) external {
        // Two caps bound a deposit: the aggregate cap, ~50%
        // of liquid above the operating buffer, and the per-venue cap, 25% of total
        // Treasury cash. Bound by the tighter of a third of unallocated() (the aggregate
        // proxy) and this venue's per-venue headroom, so a deposit lands whichever cap is
        // closer instead of overshooting the per-venue one about half the time. The venue
        // alternates, so one venue filling toward 25% exercises the per-venue path and both
        // venues together toward 50% exercise the aggregate path.
        MockVenue v = _pickVenue(venueDepositTries);
        uint256 total = cc.totalVenueExposure();
        uint256 aggCap = cc.venueAllocationCap();
        uint256 aggRoom = aggCap > total ? aggCap - total : 0;
        uint256 perVenueRoom = _perVenueHeadroom(v);
        uint256 room = aggRoom < perVenueRoom ? aggRoom : perVenueRoom;
        amount = bound(amount, 1, room == 0 ? 1 : room);
        venueDepositTries++;
        vm.prank(treasuryMgr);
        try cc.depositToVenue(address(v), amount) {
            ghostToVenue += amount;
            venueDepositLands++;
            _checkOutflow();
        } catch {}
    }

    function withdrawFromVenue(uint256 shares) external {
        MockVenue v = _pickVenue(venueWithdrawTries);
        uint256 held = v.balanceOf(address(cc));
        if (held == 0) {
            v = _pickVenue(venueWithdrawTries + 1); // fall back to the other venue
            held = v.balanceOf(address(cc));
            if (held == 0) return;
        }
        shares = bound(shares, 1, held);
        uint256 balBefore = usdc.balanceOf(address(cc));
        venueWithdrawTries++;
        vm.prank(treasuryMgr);
        try cc.withdrawFromVenue(address(v), shares) {
            ghostFromVenue += usdc.balanceOf(address(cc)) - balBefore;
            venueWithdrawLands++;
        } catch {}
    }

    function venueGain(uint256 amount) external {
        MockVenue v = _pickVenue(amount);
        if (v.totalSupply() == 0) return;
        amount = bound(amount, 1, 1_000_000e6);
        usdc.mint(address(this), amount);
        usdc.approve(address(v), amount);
        v.fund(amount);
    }

    function venueLoss(uint256 amount) external {
        MockVenue v = _pickVenue(amount);
        uint256 venueBal = usdc.balanceOf(address(v));
        if (venueBal == 0) return;
        amount = bound(amount, 1, venueBal);
        v.skim(amount);
    }

    function setBook(uint256 c, uint256 l, uint256 fc, uint256 dr) external {
        cc.setBook(
            bound(c, 0, 20_000_000e6), bound(l, 0, 20_000_000e6), bound(fc, 0, 20_000_000e6), bound(dr, 0, 20_000_000e6)
        );
    }

    function setPending(uint256 v) external {
        cc.setPendingObligationReserve(bound(v, 0, 1_000_000e6));
    }

    function warp(uint256 s) external {
        vm.warp(block.timestamp + bound(s, 1, 30 days));
    }

    /// Sum of the contract's own allocation entries over the id space the handler touches.
    function contractSumAllocations() external view returns (uint256 s) {
        for (uint256 i; i < MAX_ID; i++) {
            s += cc.allocationOf(i);
        }
    }
}

contract CreditCoreInvariantTest is StdInvariant, Test {
    MockUSDC usdc;
    Config config;
    MockCommunityFactory factory;
    MockVenue venue;
    MockVenue venue2;
    CreditStanding standing;
    CreditCoreHarness cc;
    CreditCoreHandler handler;

    address governance = makeAddr("governance");
    address treasuryMgr = makeAddr("treasuryManager");
    address allocationMs = makeAddr("allocationMultisig");

    function setUp() public {
        usdc = new MockUSDC();
        config = new Config(address(usdc), makeAddr("treasury"), makeAddr("registry"));
        factory = new MockCommunityFactory();
        factory.addCommunity(); // start with one community so allocate is reachable
        venue = new MockVenue(IERC20(address(usdc)), "V", "V");
        venue2 = new MockVenue(IERC20(address(usdc)), "V2", "V2");
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
        cc.addVenue(address(venue));
        cc.addVenue(address(venue2));

        handler = new CreditCoreHandler(cc, usdc, venue, venue2, factory, governance, treasuryMgr, allocationMs);
        targetContract(address(handler));
    }

    /// Test 1: cash never falls below the sum of allocations. `unallocated()` is defined as
    /// `cash - totalAllocated` clamped at zero, so `cash == totalAllocated + unallocated()` is
    /// an identity whose only failing case is that clamp firing, i.e. cash below
    /// `totalAllocated`. That floor is the real property here (this is the
    /// clamp property, not a conservation result; `invariant_noValueCreated` is
    /// the conservation check).
    function invariant_cashEqualsAllocatedPlusUnallocated() public view {
        assertEq(usdc.balanceOf(address(cc)), cc.totalAllocated() + cc.unallocated());
    }

    /// Test 1 (continued): the running `totalAllocated` equals the sum of the per-community
    /// entries, and both track the handler's independent ghost.
    function invariant_allocationAccountingIsConsistent() public view {
        assertEq(cc.totalAllocated(), handler.contractSumAllocations());
        assertEq(cc.totalAllocated(), handler.ghostSumAllocations());
    }

    /// Test 2: no path mints, burns or creates value. CreditCore's USDC balance is exactly
    /// what was seeded, minus what went to the venue, plus what came back. It never fabricates
    /// or loses a unit; venue price moves land on the venue, not on the Treasury balance.
    function invariant_noValueCreated() public view {
        assertEq(usdc.balanceOf(address(cc)), handler.ghostFunded() + handler.ghostFromVenue() - handler.ghostToVenue());
    }

    /// The gate holds: no successful outflow (allocate or venue deposit) ever left cash below
    /// `totalAllocated + requiredRetainedCapital`. A later venue appreciation can push the
    /// requirement above cash, which pauses new allocations; that is not an
    /// outflow and not a breach.
    function invariant_noOutflowBreachedTheRequirement() public view {
        assertFalse(handler.everBreachedByOutflow());
    }
}
