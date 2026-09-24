// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.30;

import {ICreditCore} from "../src/interfaces/ICreditCore.sol";
import {CreditInvariantBase} from "./invariant/CreditCore.inv.t.sol";

/// A fixed sequence through the credit handler, seeded from a constant, checking all four pool
/// invariants after every step. The fuzzer can wander into corners that never draw or never
/// write off; this run shows each path landing at least once, so a green invariant campaign
/// cannot be green only because nothing happened.
contract CreditCoreHandlerReplayTest is CreditInvariantBase {
    bytes32 constant SEED = keccak256("qudi.credit-replay.v1");
    uint256 constant STEPS = 600;

    function _arg(uint256 step, uint256 i) internal pure returns (uint256) {
        return uint256(keccak256(abi.encode(SEED, step, i)));
    }

    function test_replay_everyPathLandsAndEveryInvariantHolds() public {
        for (uint256 step; step < STEPS; step++) {
            _dispatch(_arg(step, 0) % 18, step);
            _backingHolds();
            _noCommunityLendsPastItsBalance();
            _bookedCashIsTheBalance();
            _repaymentNeverBlocked();
        }

        bytes32[10] memory ops = [
            bytes32("draw"),
            "settle",
            "writeOff",
            "leg",
            "grant",
            "toStrategy",
            "fromStrategy",
            "gain",
            "loss",
            "treasury"
        ];
        bytes4[7] memory why = [
            ICreditCore.TabAlreadyOpen.selector,
            ICreditCore.PortfolioQualityBreached.selector,
            ICreditCore.ExceedsAvailable.selector,
            ICreditCore.NotEligible.selector,
            ICreditCore.ExceedsLine.selector,
            ICreditCore.PoolIlliquid.selector,
            ICreditCore.CommunityIsClosed.selector
        ];
        for (uint256 i; i < why.length; i++) {
            emit log_named_uint(vm.toString(abi.encodePacked(why[i])), handler.drawRefusals(why[i]));
        }
        for (uint256 i; i < ops.length; i++) {
            emit log_named_uint(string(abi.encodePacked(ops[i])), handler.lands(ops[i]));
            assertGt(handler.lands(ops[i]), 0, "a path never landed");
        }
        assertGt(core.poolView().totalOutstanding + _writtenOff(), 0);
    }

    function _writtenOff() internal view returns (uint256 total) {
        for (uint256 i; i < handler.communityCount(); i++) {
            ICreditCore.CommunityCredit memory c = core.communityCreditOf(handler.communityAt(i));
            total += c.writtenOff;
        }
    }

    function _dispatch(uint256 pick, uint256 step) internal {
        uint256 x = _arg(step, 1);
        uint256 y = _arg(step, 2);
        uint256 z = _arg(step, 3);
        // Two borrowers (the last of the eight) never repay, so write-offs happen.
        if (pick < 4) handler.draw(x, y, z);
        else if (pick < 8) handler.settle(x % 6, y);
        else if (pick == 8) handler.warp(x);
        else if (pick == 9) handler.finalizeWriteOff(x);
        else if (pick == 10) handler.materialize(x);
        else if (pick == 11) handler.leg(x, y);
        else if (pick == 12) handler.grant(x, y);
        else if (pick == 13) handler.depositToStrategy(x);
        else if (pick == 14) handler.withdrawFromStrategy(x);
        else if (pick == 15) handler.strategyGain(x);
        else if (pick == 16) handler.strategyLoss(x);
        else handler.withdrawTreasury(x);
    }
}
