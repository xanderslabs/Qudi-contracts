// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.30;

/// The pure stage arithmetic for `CreditCore`'s debt half, split out as a
/// deployed library the same way `StandingMath` was: it keeps `CreditCore`
/// bytecode room free, reads no state and no config. Every boundary comes in as an
/// argument, and the intervals are half-open:
///
/// ```text
/// 0        <= t < 60 days    Tenor
/// 60 days  <= t < 65 days    Grace
/// 65 days  <= t < 95 days    Late
/// 95 days  <= t < 155 days   Final Cure
/// 155 days <= t < 365 days   Default Recovery
/// t >= 365 days              Written Off
/// ```
///
/// The boundary instant belongs to the LATER stage in every interval (`t < boundary` is
/// the earlier stage, `t == boundary` the later one), and the whole chain is derived
/// from elapsed seconds off the obligation's own `drawTimestamp`, the canonical time.
/// The boundaries arrive ordered from `Config.setStageBoundaries`, which enforces
/// `grace < late < finalCure < defaultRecovery < writtenOff` atomically; the `<`
/// comparisons themselves need no ordering assumption beyond that.
library DebtMath {
    /// The stages, in order. Values are fixed by position: `Late`, `FinalCure` and
    /// `DefaultRecovery` are exactly the delinquency stages the credit-loss reserve
    /// buckets are keyed on (`reserveIdx`).
    uint8 internal constant STAGE_TENOR = 0;
    uint8 internal constant STAGE_GRACE = 1;
    uint8 internal constant STAGE_LATE = 2;
    uint8 internal constant STAGE_FINAL_CURE = 3;
    uint8 internal constant STAGE_DEFAULT_RECOVERY = 4;
    uint8 internal constant STAGE_WRITTEN_OFF = 5;

    /// The reserve bucket for a stage: Current covers Tenor and Grace (both
    /// undelinquent), then one bucket per delinquency stage. Written Off is off the book.
    function reserveIdx(uint8 stage) internal pure returns (uint8) {
        if (stage <= STAGE_GRACE) return 0;
        return stage - 1; // Late -> 1, FinalCure -> 2, DefaultRecovery -> 3
    }

    /// The stage at `elapsed` seconds since the obligation's own drawTimestamp. Half-open
    /// intervals; the boundary instant belongs to the later stage. Total (always one of
    /// the six) and monotone in `elapsed`.
    function deriveStage(uint256 elapsed, uint64 grace, uint64 late, uint64 finalCure, uint64 dr, uint64 wo)
        external
        pure
        returns (uint8)
    {
        if (elapsed < grace) return STAGE_TENOR;
        if (elapsed < late) return STAGE_GRACE;
        if (elapsed < finalCure) return STAGE_LATE;
        if (elapsed < dr) return STAGE_FINAL_CURE;
        if (elapsed < wo) return STAGE_DEFAULT_RECOVERY;
        return STAGE_WRITTEN_OFF;
    }
}
