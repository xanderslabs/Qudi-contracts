// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.30;

import {Math} from "openzeppelin-contracts/contracts/utils/math/Math.sol";

/// The pure Line-sizing arithmetic for `CreditCore`'s Standing half. Every value is
/// passed in; this library reads no state and no config. Split out as a deployed library so
/// `CreditCore` keeps bytecode room. Every division rounds DOWN: a member is never
/// shown more than the exact figure.
///
/// `WAD` (1e18) is the fixed-point scale for `share_i`, `activity_factor` and `conduct_factor`.
library StandingMath {
    uint256 internal constant WAD = 1e18;

    /// `1 - (t - lateStart) / (defaultRecoveryStart - lateStart)` between Late entry and formal
    /// Default, then 0. Elapsed time only.
    function conductDecay(uint256 elapsed, uint256 lateStart, uint256 defaultRecoveryStart)
        external
        pure
        returns (uint256)
    {
        if (elapsed < lateStart) return WAD;
        if (elapsed >= defaultRecoveryStart) return 0;
        // Floor the multiplier itself: `(span - dt) / span` where `dt = elapsed -
        // lateStart`. Equal to `1 - dt / span` in exact arithmetic; computed this way so the
        // rounding direction is a decision, not a residue of flooring the subtrahend.
        return Math.mulDiv(defaultRecoveryStart - elapsed, WAD, defaultRecoveryStart - lateStart);
    }

    /// `d <= grace -> 1`, `grace < d < grace + w -> linear to floorWad`, `d >= grace + w ->
    /// floorWad`. `floorWad` is above zero by config bound.
    function dormancyDecay(uint256 d, uint256 grace, uint256 w, uint256 floorWad) external pure returns (uint256) {
        if (d <= grace) return WAD;
        if (d >= grace + w) return floorWad;
        // Floor the multiplier itself, same as `conductDecay`: linear from just below
        // WAD down to `floorWad` as `d` runs from `grace` to `grace + w`.
        return floorWad + Math.mulDiv(WAD - floorWad, grace + w - d, w);
    }

    /// A scar (or a re-engaged activity value) heals linearly from `frozenWad` to 1.0 over
    /// `window`.
    function healRamp(uint256 frozenWad, uint256 elapsed, uint256 window) external pure returns (uint256) {
        if (elapsed >= window) return WAD;
        return frozenWad + Math.mulDiv(WAD - frozenWad, elapsed, window);
    }
}
