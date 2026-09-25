// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.30;

import {Community} from "../src/Community.sol";
import {Ledger} from "../src/Ledger.sol";
import {ICommunity} from "../src/interfaces/ICommunity.sol";
import {ILedger} from "../src/interfaces/ILedger.sol";
import {ConfigKeys as K} from "../src/ConfigKeys.sol";
import {VenueIds} from "./helpers/VenueIds.sol";
import {CreditFixture} from "./helpers/CreditFixture.sol";
import {IImpactSource} from "../src/interfaces/IImpactSource.sol";

/// Stands in for `CreditCore` at a join: it takes the seat leg, has no open tab to report, and
/// records activity slowly, as a busier credit book would. It marks that it ran in a slot of its
/// own, since it lives in the real `CreditCore`'s storage.
contract SlowActivityCore {
    bytes32 internal constant RAN = keccak256("slow activity ran");

    function hasOpenTab(address) external pure returns (bool) {
        return false;
    }

    function receiveCommunityLeg(uint256, uint256) external {}

    function noteActivity(uint256, address) external {
        uint256 x;
        for (uint256 i; i < 10_000; i++) {
            x = uint256(keccak256(abi.encode(x, i)));
        }
        bytes32 slot = RAN;
        assembly {
            sstore(slot, 1)
        }
    }
}

/// An impact source that needs a lot of gas to answer, as a product with a long book might.
contract SlowImpactSource is IImpactSource {
    uint256 public impact;

    function set(uint256 v) external {
        impact = v;
    }

    function impactOf(uint256, address) external view returns (uint256) {
        uint256 x;
        for (uint256 i; i < 10_000; i++) {
            x = uint256(keccak256(abi.encode(x, i)));
        }
        return impact | (x & 0);
    }
}

/// A best-effort call runs inside `try`, so a failure it is allowed to have (the credit account
/// refusing, a venue with no cash) never blocks the member's own action. Running out of gas is not
/// one of those failures. A wallet sends the gas `eth_estimateGas` returns, which is the least gas
/// at which the transaction does not revert. If a starved inner call were swallowed, that least gas
/// would be the amount at which the inner call fails, and the transaction would land without it:
/// an accrual that pays no fees, a deposit or a join that records no activity, a withdrawal that is
/// not paid, a default that disqualifies too little impact.
///
/// Each test finds the least gas the way the node does, by bisection over whether the call
/// reverts, then sends the call at exactly that gas and checks that the best-effort call ran. It
/// also checks that below that gas the call reverts rather than landing without it.
contract BestEffortGasTest is CreditFixture {
    Community c;
    uint256 id;
    address[] people;
    Ledger ledger;

    function setUp() public override {
        super.setUp();
        (c, id, people) = _community(100e6, 6);
        ledger = _ledger(id);
        _season();
    }

    // ---- the node's estimate, emulated ----

    function _lands(address from, address target, bytes memory data, uint256 gas) internal returns (bool ok) {
        uint256 snap = vm.snapshotState();
        vm.prank(from);
        (ok,) = target.call{gas: gas}(data);
        vm.revertToState(snap);
    }

    /// The least gas at which the call does not revert, as `eth_estimateGas` finds it.
    function _estimate(address from, address target, bytes memory data) internal returns (uint256) {
        uint256 lo = 0;
        uint256 hi = 20_000_000;
        assertTrue(_lands(from, target, data, hi), "the call lands with plenty of gas");
        while (hi - lo > 1) {
            uint256 mid = (lo + hi) / 2;
            if (_lands(from, target, data, mid)) hi = mid;
            else lo = mid;
        }
        return hi;
    }

    /// Below the estimate the call never lands: it reverts, instead of landing without its
    /// best-effort call.
    function _revertsBelow(address from, address target, bytes memory data, uint256 estimate) internal {
        for (uint256 g = estimate - 1; g > estimate / 2; g -= estimate / 97 + 1) {
            assertFalse(_lands(from, target, data, g), "landed below the estimate");
        }
    }

    function _send(address from, address target, bytes memory data, uint256 gas) internal {
        vm.prank(from);
        (bool ok,) = target.call{gas: gas}(data);
        assertTrue(ok, "lands at the estimate");
    }

    // ---- the ledger ----

    /// A strategy that takes a lot of gas to pay from: a withdrawal sent at its estimate is still
    /// paid in the same call, instead of landing unpaid in the queue.
    function test_aWithdrawalSentAtItsEstimateIsPaidEvenFromASlowStrategy() public {
        address m = people[1];
        uint256 vaultId = _save(id, m, 100e6);
        flex.rebalance();
        flexStrategy.setWithdrawWork(10_000);
        bytes memory data = abi.encodeCall(ILedger.requestWithdraw, (vaultId, 40e6));

        uint256 est = _estimate(m, address(ledger), data);
        _revertsBelow(m, address(ledger), data, est);
        uint256 before = usdc.balanceOf(m);
        _send(m, address(ledger), data, est);
        assertEq(usdc.balanceOf(m) - before, 40e6, "paid to the wallet in the same call");
    }

    function test_aDepositSentAtItsEstimateRecordsActivity() public {
        address m = people[1];
        uint256 vaultId = _save(id, m, 10e6);
        vm.warp(block.timestamp + 10 days);
        usdc.mint(m, 50e6);
        vm.prank(m);
        usdc.approve(address(ledger), 50e6);
        bytes memory data = abi.encodeCall(ILedger.deposit, (vaultId, 50e6));

        uint256 est = _estimate(m, address(ledger), data);
        _revertsBelow(m, address(ledger), data, est);
        _send(m, address(ledger), data, est);
        assertEq(ledger.vaultCapital(vaultId), 60e6, "the deposit landed");
        assertEq(_credit(id).lastActivityAt, block.timestamp, "and recorded the depositor's activity");
    }

    function test_anAccrualSentAtItsEstimateSettlesItsFees() public {
        _save(id, people[1], 1_000e6);
        _gain(100e6, 365 days);
        bytes memory data = abi.encodeCall(ILedger.accrue, ());

        uint256 est = _estimate(stranger, address(ledger), data);
        _revertsBelow(stranger, address(ledger), data, est);
        uint256 treasuryBefore = usdc.balanceOf(treasury);
        _send(stranger, address(ledger), data, est);
        (uint256 t, uint256 cr) = ledger.pendingFees(VenueIds.FLEX);
        assertEq(t + cr, 0, "nothing left pending");
        assertGt(usdc.balanceOf(treasury), treasuryBefore, "the treasury was paid in the same call");
    }

    function test_aWithdrawalSentAtItsEstimateIsPaid() public {
        address m = people[1];
        uint256 vaultId = _save(id, m, 100e6);
        vm.warp(block.timestamp + 1 days);
        bytes memory data = abi.encodeCall(ILedger.requestWithdraw, (vaultId, 40e6));

        uint256 est = _estimate(m, address(ledger), data);
        _revertsBelow(m, address(ledger), data, est);
        uint256 before = usdc.balanceOf(m);
        _send(m, address(ledger), data, est);
        assertEq(usdc.balanceOf(m) - before, 40e6, "paid to the wallet in the same call");
    }

    // ---- a refusal is still ignored ----

    /// A settlement that fails for its own reason (here the credit account refusing the leg) leaves
    /// the fees pending and blocks neither an accrual nor a deposit, however much gas they carry.
    function test_aRefusedSettlementBlocksNeitherAnAccrualNorADeposit() public {
        address m = people[1];
        uint256 vaultId = _save(id, m, 1_000e6);
        _gain(100e6, 365 days);
        vm.mockCallRevert(address(core), abi.encodeWithSelector(core.receiveCommunityLeg.selector), "refused");
        ledger.accrue();
        (uint256 t, uint256 cr) = ledger.pendingFees(VenueIds.FLEX);
        assertGt(t + cr, 0, "the fees wait");
        usdc.mint(m, 10e6);
        vm.startPrank(m);
        usdc.approve(address(ledger), 10e6);
        ledger.deposit(vaultId, 10e6);
        vm.stopPrank();
        assertEq(ledger.vaultCapital(vaultId), 1_010e6, "the deposit landed");
    }

    /// A queue step that fails for its own reason leaves the withdrawal queued, not refused.
    function test_aRefusedQueueStepStillQueuesTheWithdrawal() public {
        address m = people[1];
        uint256 vaultId = _save(id, m, 100e6);
        vm.mockCallRevert(address(flex), abi.encodeWithSelector(flex.processQueue.selector), "refused");
        uint256 before = usdc.balanceOf(m);
        vm.prank(m);
        uint256 requestId = ledger.requestWithdraw(vaultId, 40e6);
        assertGt(requestId, 0, "the request landed");
        assertEq(usdc.balanceOf(m), before, "and waits in the queue");
    }

    // ---- the join ----

    function test_aJoinSentAtItsEstimateRecordsActivity() public {
        address joiner = _person();
        _attest(joiner);
        usdc.mint(joiner, 100e6);
        vm.prank(joiner);
        usdc.approve(address(c), 100e6);
        vm.warp(block.timestamp + 5 days);
        (address inviteKey, bytes memory keySig) = _inviteFor(address(c), joiner);
        bytes memory data = abi.encodeCall(ICommunity.join, (inviteKey, keySig));

        uint256 est = _estimate(joiner, address(c), data);
        _revertsBelow(joiner, address(c), data, est);
        _send(joiner, address(c), data, est);
        assertTrue(c.isMember(joiner), "the join landed");
        assertEq(_credit(id).lastActivityAt, block.timestamp, "and recorded the joiner's activity");
    }

    /// The same with a slow activity record: a join at its estimate still records it.
    function test_aJoinSentAtItsEstimateRecordsActivityEvenWhenThatIsSlow() public {
        address joiner = _person();
        _attest(joiner);
        usdc.mint(joiner, 100e6);
        vm.prank(joiner);
        usdc.approve(address(c), 100e6);
        (address inviteKey, bytes memory keySig) = _inviteFor(address(c), joiner);
        vm.etch(address(core), address(new SlowActivityCore()).code);
        bytes memory data = abi.encodeCall(ICommunity.join, (inviteKey, keySig));

        uint256 est = _estimate(joiner, address(c), data);
        _revertsBelow(joiner, address(c), data, est);
        _send(joiner, address(c), data, est);
        assertEq(vm.load(address(core), keccak256("slow activity ran")), bytes32(uint256(1)), "activity recorded");
    }

    // ---- the default ----

    /// `materialize` is public, so a member in default could record their own formal default with
    /// the gas cut so fine that an impact source's answer is lost. The snapshot would then
    /// disqualify less than they hold, and they would keep the rest.
    function test_aFormalDefaultSentAtItsEstimateDisqualifiesAllTheImpact() public {
        address m = people[1];
        _grant(id, 10_000e6);
        config.set(K.COMMUNITY_DORMANCY_GRACE, 730 days);
        config.set(K.DORMANCY_GRACE, 365 days);
        _draw(m, id, 20e6);
        vm.warp(block.timestamp + 156 days);
        uint256 held = standing.impactOf(id, m);
        assertGt(held, 0);
        bytes memory data = abi.encodeCall(core.materialize, (m));

        uint256 est = _estimate(stranger, address(core), data);
        _revertsBelow(stranger, address(core), data, est);
        _send(stranger, address(core), data, est);
        assertTrue(standing.isAccountDefaulted(m), "the default landed");
        assertEq(standing.disqualifiedImpactOf(id, m), held, "and disqualified every source's impact");
    }

    /// With a slow source listed, the gas can be cut so that only that source's answer is lost.
    /// The default must then revert, never land with part of the impact left out.
    function test_aFormalDefaultWithASlowSourceDisqualifiesItsImpactAtAnyGasItLands() public {
        address m = people[1];
        SlowImpactSource slow = new SlowImpactSource();
        slow.set(7e6);
        standing.addImpactSource(address(slow));
        _grant(id, 10_000e6);
        config.set(K.COMMUNITY_DORMANCY_GRACE, 730 days);
        config.set(K.DORMANCY_GRACE, 365 days);
        _draw(m, id, 20e6);
        vm.warp(block.timestamp + 156 days);
        uint256 held = standing.impactOf(id, m);
        bytes memory data = abi.encodeCall(core.materialize, (m));

        uint256 est = _estimate(stranger, address(core), data);
        _revertsBelow(stranger, address(core), data, est);
        _send(stranger, address(core), data, est);
        assertEq(standing.disqualifiedImpactOf(id, m), held, "the slow source's impact is disqualified too");
    }
}
