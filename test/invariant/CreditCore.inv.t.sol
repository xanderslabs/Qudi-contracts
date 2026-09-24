// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {CreditCore} from "../../src/CreditCore.sol";
import {ICreditCore} from "../../src/interfaces/ICreditCore.sol";
import {ICommunityFactory} from "../../src/interfaces/ICommunityFactory.sol";
import {MockUSDC} from "../mocks/MockUSDC.sol";
import {MockStrategy} from "../mocks/MockStrategy.sol";
import {MockImpactSource} from "../mocks/MockImpactSource.sol";
import {CreditFixture} from "../helpers/CreditFixture.sol";

/// Drives `CreditCore` through everything that moves money or paper: draws, settlements, stage
/// crossings, write-offs, seat and yield legs, grants, pool strategy moves, strategy gains and
/// losses, and Qudi's own withdrawals. It records any settlement that reverted for a member who had
/// something to repay and the USDC to pay it.
contract CreditCoreHandler is Test {
    CreditCore public core;
    MockUSDC public usdc;
    MockStrategy public strategy;
    MockImpactSource public extra;
    ICommunityFactory public factory;
    address public owner;
    address public operator;
    address public allocator;
    bytes32 public agreement;

    uint256[] internal _communities;
    address[] internal _members;

    /// Set when a settlement failed for a member with an advance to repay.
    bool public settleBlocked;

    mapping(bytes32 => uint256) public tries;
    mapping(bytes32 => uint256) public lands;
    /// Why draws were refused, by error selector.
    mapping(bytes4 => uint256) public drawRefusals;

    constructor(
        CreditCore core_,
        MockUSDC usdc_,
        MockStrategy strategy_,
        MockImpactSource extra_,
        ICommunityFactory factory_,
        address[3] memory roles,
        bytes32 agreement_,
        uint256[] memory communities,
        address[] memory members
    ) {
        core = core_;
        usdc = usdc_;
        strategy = strategy_;
        extra = extra_;
        factory = factory_;
        owner = roles[0];
        operator = roles[1];
        allocator = roles[2];
        agreement = agreement_;
        _communities = communities;
        _members = members;
    }

    function communityCount() external view returns (uint256) {
        return _communities.length;
    }

    function communityAt(uint256 i) external view returns (uint256) {
        return _communities[i];
    }

    function memberCount() external view returns (uint256) {
        return _members.length;
    }

    function memberAt(uint256 i) external view returns (address) {
        return _members[i];
    }

    function _community(uint256 seed) internal view returns (uint256) {
        return _communities[seed % _communities.length];
    }

    function _member(uint256 seed) internal view returns (address) {
        return _members[seed % _members.length];
    }

    function _land(bytes32 op, bool ok) internal {
        tries[op]++;
        if (ok) lands[op]++;
    }

    // ---- the member side ----

    function draw(uint256 who, uint256 which, uint256 amount) external {
        address m = _member(who);
        uint256 id = _community(which);
        uint256 line = core.standingOf(id, m).drawable;
        if (line < 10e6) line = 10e6;
        amount = bound(amount, 10e6, line);
        vm.prank(m);
        try core.draw(id, amount, agreement) {
            _land("draw", true);
        } catch (bytes memory reason) {
            drawRefusals[bytes4(reason)]++;
            _land("draw", false);
        }
    }

    /// Repayment must never fail for a member who has an advance and the USDC to pay it.
    function settle(uint256 who, uint256 amount) external {
        address m = _member(who);
        ICreditCore.ObligationView memory o = core.obligationOf(m);
        if (o.drawTimestamp == 0 || o.closed) return;
        amount = bound(amount, 1, o.principal + 5e6);
        usdc.mint(m, amount);
        vm.prank(m);
        usdc.approve(address(core), amount);
        vm.prank(m);
        try core.settle(amount) {
            _land("settle", true);
        } catch {
            settleBlocked = true;
            _land("settle", false);
        }
    }

    function materialize(uint256 who) external {
        core.materialize(_member(who));
        _land("materialize", true);
    }

    function finalizeWriteOff(uint256 who) external {
        try core.finalizeWriteOff(_member(who)) {
            _land("writeOff", true);
        } catch {
            _land("writeOff", false);
        }
    }

    function warp(uint256 secs) external {
        vm.warp(block.timestamp + bound(secs, 1 hours, 40 days));
        _land("warp", true);
    }

    function setImpact(uint256 who, uint256 which, uint256 amount) external {
        extra.setImpact(_community(which), _member(who), bound(amount, 0, 2_000e6));
        _land("impact", true);
    }

    // ---- money into a community ----

    /// A seat or yield leg: the community (a seat mint) or its ledger (fee settlement) pays in and
    /// books it. An odd amount is a seat leg, which is also community activity.
    function leg(uint256 which, uint256 amount) external {
        uint256 id = _community(which);
        amount = bound(amount, 1, 500e6);
        address payer = factory.communityAt(id);
        if (amount % 2 == 0) payer = factory.ledgerOf(payer);
        usdc.mint(payer, amount);
        vm.prank(payer);
        usdc.transfer(address(core), amount);
        vm.prank(payer);
        try core.receiveCommunityLeg(id, amount) {
            _land("leg", true);
        } catch {
            // A closed account refuses a leg; the ledger then sends it to the treasury instead.
            vm.prank(address(core));
            usdc.transfer(owner, amount);
            _land("leg", false);
        }
    }

    function grant(uint256 which, uint256 amount) external {
        uint256 id = _community(which);
        amount = bound(amount, 1, 2_000e6);
        usdc.mint(owner, amount);
        vm.prank(owner);
        usdc.approve(address(core), amount);
        vm.prank(owner);
        core.fund(amount);
        vm.prank(allocator);
        try core.allocate(id, amount, ICreditCore.AllocationType.Growth) {
            _land("grant", true);
        } catch {
            _land("grant", false);
        }
    }

    // ---- Qudi's side ----

    function depositToStrategy(uint256 amount) external {
        amount = bound(amount, 1, usdc.balanceOf(address(core)) + 1);
        vm.prank(operator);
        try core.depositToStrategy(address(strategy), amount) {
            _land("toStrategy", true);
        } catch {
            _land("toStrategy", false);
        }
    }

    function withdrawFromStrategy(uint256 amount) external {
        amount = bound(amount, 1, strategy.totalAssets() + 1);
        vm.prank(operator);
        try core.withdrawFromStrategy(address(strategy), amount) {
            _land("fromStrategy", true);
        } catch {
            _land("fromStrategy", false);
        }
    }

    function strategyGain(uint256 amount) external {
        amount = bound(amount, 1, 100e6);
        usdc.mint(address(this), amount);
        usdc.approve(address(strategy), amount);
        strategy.fund(amount);
        _land("gain", true);
    }

    /// A loss no larger than Qudi's own money. A loss past it would be Qudi's to cover from outside
    /// the pool, and no rule inside `CreditCore` can make up money that is gone.
    function strategyLoss(uint256 amount) external {
        uint256 cap = core.poolView().unallocated;
        uint256 held = strategy.totalAssets();
        if (held < cap) cap = held;
        if (cap == 0) return;
        strategy.skim(bound(amount, 1, cap));
        _land("loss", true);
    }

    function withdrawTreasury(uint256 amount) external {
        amount = bound(amount, 1, core.poolView().unallocated + 1);
        vm.prank(owner);
        try core.withdrawTreasury(owner, amount) {
            _land("treasury", true);
        } catch {
            _land("treasury", false);
        }
    }
}

/// The handler over two six-seat communities, four borrowers in each, and one pool strategy. Shared
/// by the invariant campaign and the fixed replay.
abstract contract CreditInvariantBase is CreditFixture {
    CreditCoreHandler handler;
    MockStrategy poolStrategy;

    function setUp() public virtual override {
        super.setUp();
        _useExtra();
        poolStrategy = _poolStrategy();

        uint256[] memory ids = new uint256[](2);
        address[] memory members = new address[](8);
        for (uint256 c; c < 2; c++) {
            (, uint256 id, address[] memory people) = _community(100e6, 6);
            ids[c] = id;
            for (uint256 i; i < 4; i++) {
                members[c * 4 + i] = people[i + 1];
                extra.setImpact(id, people[i + 1], 200e6);
            }
        }
        _season();

        handler = new CreditCoreHandler(
            core, usdc, poolStrategy, extra, factory, [address(this), operator, allocator], AGREEMENT, ids, members
        );
    }

    /// (a) Cash plus pool strategies always cover every unlent paper balance.
    function _backingHolds() internal view {
        ICreditCore.PoolView memory p = core.poolView();
        assertGe(p.cash + p.strategyValue + p.totalOutstanding, p.totalAllocated, "backing");
    }

    /// (b) No community has more out than its balance, and the totals are the sums of the records.
    function _noCommunityLendsPastItsBalance() internal view {
        uint256 allocated;
        uint256 outstanding;
        for (uint256 i; i < handler.communityCount(); i++) {
            ICreditCore.CommunityCredit memory c = core.communityCreditOf(handler.communityAt(i));
            assertLe(c.outstanding, c.allocation, "a community lent past its balance");
            allocated += c.allocation;
            outstanding += c.outstanding;
        }
        ICreditCore.PoolView memory p = core.poolView();
        assertEq(p.totalAllocated, allocated, "the total is the sum of the records");
        assertEq(p.totalOutstanding, outstanding);
    }

    /// (c) `CreditCore`'s booked cash is its USDC balance.
    function _bookedCashIsTheBalance() internal view {
        assertEq(core.expectedCash(), usdc.balanceOf(address(core)), "booked cash");
    }

    /// (d) Repayment is never blocked for a member with something to repay.
    function _repaymentNeverBlocked() internal view {
        assertFalse(handler.settleBlocked(), "a settlement was refused");
    }
}

/// Proof 16, as an invariant campaign over the handler.
contract CreditCoreInvariantTest is CreditInvariantBase {
    function setUp() public override {
        super.setUp();
        targetContract(address(handler));
    }

    function invariant_a_backingAlwaysHolds() public view {
        _backingHolds();
    }

    function invariant_b_noCommunityLendsPastItsBalance() public view {
        _noCommunityLendsPastItsBalance();
    }

    function invariant_c_bookedCashIsTheBalance() public view {
        _bookedCashIsTheBalance();
    }

    function invariant_d_repaymentIsNeverBlocked() public view {
        _repaymentNeverBlocked();
    }
}
