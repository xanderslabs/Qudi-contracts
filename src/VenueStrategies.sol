// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.30;

import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import {IVenue} from "./interfaces/IVenue.sol";
import {IStrategy} from "./interfaces/IStrategy.sol";

/// `Venue`'s strategy listing, weights and group checks, held in a deployed library rather than
/// inline.
///
/// This is the largest block of the Venue that is pure allocation policy, owner-only, and touches
/// no money beyond bringing a delisted strategy's position home. `public` library functions are
/// reached by DELEGATECALL, so the code lives at the library's own address and the Venue carries
/// only the call. The storage it works on is the Venue's, passed as storage pointers, and nothing
/// here can be called on its own. It adds a linked library to the deployment.
///
/// The group rule: the instant group, which idle counts toward, must stay at or above its floor,
/// and the slow group at or below its ceiling.
library VenueStrategies {
    using SafeERC20 for IERC20;

    /// Lists a strategy with the exit delay the owner states for it: zero is the instant group,
    /// anything above it the slow group. The Venue approves the strategy for its whole USDC balance
    /// once here rather than per allocation. Runs by DELEGATECALL, so `address(this)` is the Venue
    /// and every approval and storage write lands on the Venue.
    function addStrategy(
        address[] storage strategies,
        mapping(address => bool) storage isStrategy,
        mapping(address => bool) storage isInstant,
        mapping(address => uint64) storage delayOf,
        address strategy,
        uint64 delaySeconds,
        address asset,
        uint64 maxNoticePeriod
    ) public returns (bool instant) {
        if (isStrategy[strategy]) revert IVenue.DuplicateStrategy();
        if (IStrategy(strategy).asset() != asset) revert IVenue.UnknownStrategy();
        if (delaySeconds > maxNoticePeriod) revert IVenue.NoticePeriodTooLong();
        instant = delaySeconds == 0;
        isStrategy[strategy] = true;
        isInstant[strategy] = instant;
        delayOf[strategy] = delaySeconds;
        strategies.push(strategy);
        IERC20(asset).forceApprove(strategy, type(uint256).max);
    }

    /// Delists a strategy: brings its whole position home to idle, clears its record, drops the
    /// approval and swaps it out of the list. A strategy that cannot give everything back now is
    /// refused, because delisting it would drop what it still holds out of the Venue's value.
    function removeStrategy(
        address[] storage strategies,
        mapping(address => bool) storage isStrategy,
        mapping(address => bool) storage isInstant,
        mapping(address => uint16) storage weightBps,
        mapping(address => uint64) storage delayOf,
        mapping(address => uint256) storage capOf,
        address strategy,
        address asset,
        uint16 instantFloorBps,
        uint16 slowCeilingBps
    ) public {
        if (!isStrategy[strategy]) revert IVenue.UnknownStrategy();
        IStrategy s = IStrategy(strategy);
        uint256 out = s.maxWithdraw();
        if (out > 0) s.withdraw(out, address(this));
        if (s.totalAssets() != 0) revert IVenue.StrategyNotEmpty();
        isStrategy[strategy] = false;
        isInstant[strategy] = false;
        weightBps[strategy] = 0;
        delayOf[strategy] = 0;
        capOf[strategy] = 0;
        uint256 n = strategies.length;
        for (uint256 i; i < n; i++) {
            if (strategies[i] == strategy) {
                strategies[i] = strategies[n - 1];
                strategies.pop();
                break;
            }
        }
        IERC20(asset).forceApprove(strategy, 0);
        checkTiers(strategies, isInstant, weightBps, instantFloorBps, slowCeilingBps);
    }

    /// Rewrites every weight from scratch, so a strategy left out of `strategies_` goes to zero
    /// rather than keeping a stale weight. The group check runs after the write, on the weights
    /// that would stand, so a set that would breach a group limit reverts as a whole.
    function setWeights(
        address[] storage strategies,
        mapping(address => bool) storage isStrategy,
        mapping(address => bool) storage isInstant,
        mapping(address => uint16) storage weightBps,
        address[] calldata strategies_,
        uint16[] calldata bps,
        uint16 instantFloorBps,
        uint16 slowCeilingBps
    ) public {
        if (strategies_.length != bps.length) revert IVenue.WeightsMustSum();
        uint256 n = strategies.length;
        for (uint256 i; i < n; i++) {
            weightBps[strategies[i]] = 0;
        }
        uint256 sum;
        for (uint256 i; i < strategies_.length; i++) {
            if (!isStrategy[strategies_[i]]) revert IVenue.UnknownStrategy();
            weightBps[strategies_[i]] = bps[i];
            sum += bps[i];
        }
        if (sum > 10_000) revert IVenue.WeightsMustSum();
        checkTiers(strategies, isInstant, weightBps, instantFloorBps, slowCeilingBps);
    }

    /// Instant group (idle counts as instant) at or above the floor; slow group at or below the
    /// ceiling.
    function checkTiers(
        address[] storage strategies,
        mapping(address => bool) storage isInstant,
        mapping(address => uint16) storage weightBps,
        uint16 instantFloorBps,
        uint16 slowCeilingBps
    ) public view {
        uint256 slowSum;
        uint256 n = strategies.length;
        for (uint256 i; i < n; i++) {
            address a = strategies[i];
            if (!isInstant[a]) slowSum += weightBps[a];
        }
        if (slowSum > slowCeilingBps) revert IVenue.TierLimitBreached();
        if (10_000 - slowSum < instantFloorBps) revert IVenue.TierLimitBreached();
    }
}
