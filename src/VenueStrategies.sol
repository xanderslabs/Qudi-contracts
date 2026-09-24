// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.30;

import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {IERC4626} from "openzeppelin-contracts/contracts/interfaces/IERC4626.sol";
import {SafeERC20} from "openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import {IVenue} from "./interfaces/IVenue.sol";
import {IStrategyDelay} from "./interfaces/IStrategyDelay.sol";

/// `Venue`'s venue weighting and tier checks, held in a deployed library rather than inline.
///
/// Why it is here rather than in the vault: the yield engine grew `Venue` past the size gate's
/// 2,000-byte margin under EIP-170, and this is the largest block of the contract that is pure
/// allocation policy, owner-only, and touches no money. `public` library functions are reached by
/// DELEGATECALL, so the code lives at the library's own address and the vault carries only the
/// call. The storage it works on is the vault's, passed as storage pointers, so the accounting is
/// unchanged and nothing here can be called on its own.
///
/// `via_ir` is held in reserve, and `CreditCore` was split at a seam instead. This is the same
/// move at a much smaller scale. It adds a linked library to the deployment.
///
/// The tier rule: the instant tier, which idle counts toward, must stay at or
/// above its floor, and the slow tier at or below its ceiling.
library VenueStrategies {
    using SafeERC20 for IERC20;

    /// Lists a venue and tags its tier from its own declared redemption delay: zero is the instant
    /// tier, anything above it the slow tier. The vault approves the venue for its whole USDC
    /// balance once here rather than per deposit. Runs by DELEGATECALL, so `address(this)` is the
    /// vault and every approval and storage write lands on the vault.
    function addVenue(
        address[] storage venues,
        mapping(address => bool) storage isVenue,
        mapping(address => bool) storage isInstant,
        address venue,
        address asset,
        uint64 maxNoticePeriod
    ) public returns (bool instant) {
        if (isVenue[venue]) revert IVenue.DuplicateVenue();
        if (IERC4626(venue).asset() != asset) revert IVenue.UnknownVenue();
        uint64 d = IStrategyDelay(venue).redeemDelay();
        if (d > maxNoticePeriod) revert IVenue.NoticePeriodTooLong();
        instant = d == 0;
        isVenue[venue] = true;
        isInstant[venue] = instant;
        venues.push(venue);
        IERC20(asset).forceApprove(venue, type(uint256).max);
    }

    /// Delists a venue: liquidates the position, clears its record, drops the approval and swaps it
    /// out of the list. The caller absorbs any standing loss first, before this runs, so the
    /// write-down lands while `min(basis, live)` can still see the venue.
    ///
    /// Removal liquidates the whole position, so a gain still sitting above the basis would land in
    /// idle and reach the price with no skim taken and no unlock applied. Harvest it first; that is
    /// a step in the runbook rather than a restriction, since `harvest` is permissionless.
    function removeVenue(
        address[] storage venues,
        mapping(address => bool) storage isVenue,
        mapping(address => bool) storage isInstant,
        mapping(address => uint16) storage weightBps,
        mapping(address => uint256) storage venueBasis,
        address venue,
        address asset,
        uint16 instantFloorBps,
        uint16 slowCeilingBps,
        bool refused
    ) public {
        if (!isVenue[venue]) revert IVenue.UnknownVenue();
        uint256 held = IERC4626(venue).balanceOf(address(this));
        // A refused venue is exempt. Harvesting the outlier first is exactly what the Risk
        // Committee declined to do, so requiring it would leave the venue unexitable.
        if (!refused && IERC4626(venue).convertToAssets(held) > venueBasis[venue]) {
            revert IVenue.UnharvestedGain();
        }
        if (held > 0) IERC4626(venue).redeem(held, address(this), address(this));
        // The whole position came out, so its basis goes with it: whatever it fetched is idle now,
        // and there is no venue reading left for `min(basis, live)` to clamp.
        venueBasis[venue] = 0;
        isVenue[venue] = false;
        weightBps[venue] = 0;
        uint256 n = venues.length;
        for (uint256 i; i < n; i++) {
            if (venues[i] == venue) {
                venues[i] = venues[n - 1];
                venues.pop();
                break;
            }
        }
        IERC20(asset).forceApprove(venue, 0);
        checkTiers(venues, isInstant, weightBps, instantFloorBps, slowCeilingBps);
    }

    /// Rewrites every weight from scratch, so a venue left out of `venues_` goes to zero rather
    /// than keeping a stale weight. The tier check runs after the write, on the weights that would
    /// stand, so a set that would breach a tier reverts as a whole.
    function setWeights(
        address[] storage venues,
        mapping(address => bool) storage isVenue,
        mapping(address => bool) storage isInstant,
        mapping(address => uint16) storage weightBps,
        address[] calldata venues_,
        uint16[] calldata bps,
        uint16 instantFloorBps,
        uint16 slowCeilingBps
    ) public {
        if (venues_.length != bps.length) revert IVenue.WeightsMustSum();
        uint256 n = venues.length;
        for (uint256 i; i < n; i++) {
            weightBps[venues[i]] = 0;
        }
        uint256 sum;
        for (uint256 i; i < venues_.length; i++) {
            if (!isVenue[venues_[i]]) revert IVenue.UnknownVenue();
            weightBps[venues_[i]] = bps[i];
            sum += bps[i];
        }
        if (sum > 10_000) revert IVenue.WeightsMustSum();
        checkTiers(venues, isInstant, weightBps, instantFloorBps, slowCeilingBps);
    }

    /// Instant tier (idle counts as instant) at or above the floor; slow tier at or below the
    /// ceiling.
    function checkTiers(
        address[] storage venues,
        mapping(address => bool) storage isInstant,
        mapping(address => uint16) storage weightBps,
        uint16 instantFloorBps,
        uint16 slowCeilingBps
    ) public view {
        uint256 slowSum;
        uint256 n = venues.length;
        for (uint256 i; i < n; i++) {
            address a = venues[i];
            if (!isInstant[a]) slowSum += weightBps[a];
        }
        if (slowSum > slowCeilingBps) revert IVenue.TierLimitBreached();
        if (10_000 - slowSum < instantFloorBps) revert IVenue.TierLimitBreached();
    }
}
