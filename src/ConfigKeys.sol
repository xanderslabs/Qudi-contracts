// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.30;

/// Key constants for every parameter held by Config.
/// USDC has no key: it is a constructor immutable with no setter.
library ConfigKeys {
    bytes32 constant SEAT_PRICE_FLOOR = keccak256("qudi.SEAT_PRICE_FLOOR");
    bytes32 constant SEAT_PRICE_CEILING = keccak256("qudi.SEAT_PRICE_CEILING");
    // The most Active seats a community holds. One cap for every community, set by Qudi.
    bytes32 constant MEMBER_CAP = keccak256("qudi.MEMBER_CAP");
    // The largest invite a host can sign: its uses, and its lifetime from issue to expiry.
    bytes32 constant INVITE_MAX_USES = keccak256("qudi.INVITE_MAX_USES");
    bytes32 constant INVITE_MAX_TTL = keccak256("qudi.INVITE_MAX_TTL");
    // Seat-fee split: 40% Community Credit Account / 30% host / 30% protocol.
    bytes32 constant MINT_SPLIT_HOST = keccak256("qudi.MINT_SPLIT_HOST");
    bytes32 constant MINT_SPLIT_POOL = keccak256("qudi.MINT_SPLIT_POOL");
    bytes32 constant MINT_SPLIT_PROTOCOL = keccak256("qudi.MINT_SPLIT_PROTOCOL");
    bytes32 constant EPOCH_LENGTH = keccak256("qudi.EPOCH_LENGTH");
    // The host removal vote (was STEWARD_VOTE_*). An election uses the community vote.
    bytes32 constant HOST_VOTE_THRESHOLD_BPS = keccak256("qudi.HOST_VOTE_THRESHOLD_BPS");
    bytes32 constant HOST_VOTE_WINDOW = keccak256("qudi.HOST_VOTE_WINDOW");
    bytes32 constant COMMUNITY_VOTE_THRESHOLD_BPS = keccak256("qudi.COMMUNITY_VOTE_THRESHOLD_BPS");
    bytes32 constant COMMUNITY_VOTE_WINDOW = keccak256("qudi.COMMUNITY_VOTE_WINDOW");
    // Canonical obligation stages, elapsed seconds from drawTimestamp. The price is
    // zero at every stage; the boundaries survive as conduct and enforcement gates.
    // Each is the half-open start of its stage: [0, grace) Tenor, [grace, late) Grace,
    // [late, finalCure) Late, [finalCure, defaultRecovery) Final Cure,
    // [defaultRecovery, writtenOff) Default Recovery, [writtenOff, ...) Written Off.
    bytes32 constant STAGE_GRACE_START = keccak256("qudi.STAGE_GRACE_START");
    bytes32 constant STAGE_LATE_START = keccak256("qudi.STAGE_LATE_START");
    bytes32 constant STAGE_FINAL_CURE_START = keccak256("qudi.STAGE_FINAL_CURE_START");
    bytes32 constant STAGE_DEFAULT_RECOVERY_START = keccak256("qudi.STAGE_DEFAULT_RECOVERY_START");
    bytes32 constant STAGE_WRITTEN_OFF_AT = keccak256("qudi.STAGE_WRITTEN_OFF_AT");
    // Reused as `activity_factor`'s grace window (90 days). The old-model decay
    // rates DORMANCY_DECAY_PPM / DORMANCY_DECAY_ZERO_PPM are gone: the activity decay replaces them.
    bytes32 constant DORMANCY_GRACE = keccak256("qudi.DORMANCY_GRACE");
    bytes32 constant ELIG_MIN_MEMBERS = keccak256("qudi.ELIG_MIN_MEMBERS");
    bytes32 constant ELIG_CLEAN_EPOCHS = keccak256("qudi.ELIG_CLEAN_EPOCHS");
    bytes32 constant ELIG_MEMBER_MONTHS = keccak256("qudi.ELIG_MEMBER_MONTHS");
    bytes32 constant ELIG_MAX_GAP_MONTHS = keccak256("qudi.ELIG_MAX_GAP_MONTHS");
    bytes32 constant YIELD_SPLIT_MEMBER = keccak256("qudi.YIELD_SPLIT_MEMBER");
    bytes32 constant YIELD_SPLIT_POOL = keccak256("qudi.YIELD_SPLIT_POOL");
    bytes32 constant YIELD_SPLIT_PROTOCOL = keccak256("qudi.YIELD_SPLIT_PROTOCOL");
    bytes32 constant INSTANT_TIER_FLOOR_BPS = keccak256("qudi.INSTANT_TIER_FLOOR_BPS");
    bytes32 constant SLOW_TIER_CEILING_BPS = keccak256("qudi.SLOW_TIER_CEILING_BPS");
    bytes32 constant MAX_NOTICE_PERIOD = keccak256("qudi.MAX_NOTICE_PERIOD");
    bytes32 constant GLOBAL_DEPOSIT_CAP = keccak256("qudi.GLOBAL_DEPOSIT_CAP");
    bytes32 constant PROTOCOL_TREASURY = keccak256("qudi.PROTOCOL_TREASURY");
    bytes32 constant COMPLIANCE_REGISTRY = keccak256("qudi.COMPLIANCE_REGISTRY");
    // Member seasoning window: measured from the seat mint timestamp. Credit is
    // gated on it.
    bytes32 constant MEMBER_SEASONING_WINDOW = keccak256("qudi.MEMBER_SEASONING_WINDOW");
    // Standing, the CreditCore half. Line-sizing dollar figures are USDC 6-decimal;
    // the two multipliers are basis points; time windows are seconds.
    bytes32 constant MIN_LENDABLE = keccak256("qudi.MIN_LENDABLE"); // $50
    bytes32 constant GLOBAL_MEMBER_CAP = keccak256("qudi.GLOBAL_MEMBER_CAP"); // $5,000
    bytes32 constant EXPOSURE_IMPACT_MULT_X100 = keccak256("qudi.EXPOSURE_IMPACT_MULT_X100"); // 3x
    // `activity_factor`: W (decay length), FLOOR (>0), and the 90-day heal window shared
    // with the conduct scar.
    bytes32 constant ACTIVITY_DECAY_LENGTH = keccak256("qudi.ACTIVITY_DECAY_LENGTH"); // W: 180 days
    bytes32 constant ACTIVITY_FLOOR_BPS = keccak256("qudi.ACTIVITY_FLOOR_BPS"); // 0.25
    bytes32 constant STANDING_HEAL_WINDOW = keccak256("qudi.STANDING_HEAL_WINDOW"); // 90 days
    // Phase caps (Established caps at GLOBAL_MEMBER_CAP, so no key of its own).
    bytes32 constant PHASE_CAP_FIRST_ACCESS = keccak256("qudi.PHASE_CAP_FIRST_ACCESS"); // $100
    bytes32 constant PHASE_CAP_PROVEN_ONCE = keccak256("qudi.PHASE_CAP_PROVEN_ONCE"); // $300
    bytes32 constant PHASE_CAP_DEVELOPING = keccak256("qudi.PHASE_CAP_DEVELOPING"); // $1,000
    // Per-phase community concentration.
    bytes32 constant CONCENTRATION_FIRST_ACCESS_BPS = keccak256("qudi.CONCENTRATION_FIRST_ACCESS_BPS"); // 5%
    bytes32 constant CONCENTRATION_PROVEN_ONCE_BPS = keccak256("qudi.CONCENTRATION_PROVEN_ONCE_BPS"); // 8%
    bytes32 constant CONCENTRATION_DEVELOPING_BPS = keccak256("qudi.CONCENTRATION_DEVELOPING_BPS"); // 10%
    bytes32 constant CONCENTRATION_ESTABLISHED_BPS = keccak256("qudi.CONCENTRATION_ESTABLISHED_BPS"); // 12%
    // Per-phase Trust Extension budget (First Access is $0, no key).
    bytes32 constant TE_BUDGET_PROVEN_ONCE = keccak256("qudi.TE_BUDGET_PROVEN_ONCE"); // $200
    bytes32 constant TE_BUDGET_DEVELOPING = keccak256("qudi.TE_BUDGET_DEVELOPING"); // $700
    bytes32 constant TE_BUDGET_ESTABLISHED = keccak256("qudi.TE_BUDGET_ESTABLISHED"); // $4,000
    // The community's live Trust Extension exposure caps at 20% of cumulative
    // attributed funding yield (also bounded by the sum of phase budgets).
    bytes32 constant TE_COMMUNITY_CAP_BPS = keccak256("qudi.TE_COMMUNITY_CAP_BPS"); // 20%
    // Phase minimum times (First Access and Developing have none).
    bytes32 constant PHASE_MIN_TIME_PROVEN_ONCE = keccak256("qudi.PHASE_MIN_TIME_PROVEN_ONCE"); // +30 days
    bytes32 constant PHASE_MIN_TIME_ESTABLISHED = keccak256("qudi.PHASE_MIN_TIME_ESTABLISHED"); // +180 days
    // Retained-capital parameters. Launch values; the formula lives in CreditCore.
    // Dollar amounts are USDC 6-decimal; percentages are basis points.
    bytes32 constant OPERATING_BUFFER_PER_COMMUNITY = keccak256("qudi.OPERATING_BUFFER_PER_COMMUNITY");
    bytes32 constant OPERATING_FLOOR_GLOBAL = keccak256("qudi.OPERATING_FLOOR_GLOBAL");
    bytes32 constant CREDIT_LOSS_RESERVE_CURRENT_BPS = keccak256("qudi.CREDIT_LOSS_RESERVE_CURRENT_BPS");
    bytes32 constant CREDIT_LOSS_RESERVE_LATE_BPS = keccak256("qudi.CREDIT_LOSS_RESERVE_LATE_BPS");
    bytes32 constant CREDIT_LOSS_RESERVE_FINAL_CURE_BPS = keccak256("qudi.CREDIT_LOSS_RESERVE_FINAL_CURE_BPS");
    bytes32 constant CREDIT_LOSS_RESERVE_DEFAULT_RECOVERY_BPS =
        keccak256("qudi.CREDIT_LOSS_RESERVE_DEFAULT_RECOVERY_BPS");
    bytes32 constant VENUE_LOSS_RESERVE_BPS = keccak256("qudi.VENUE_LOSS_RESERVE_BPS");
    // The share of liquid capital above the operating buffer that may sit in
    // venues at once. 50% at launch; the other 50% stays instantly liquid.
    bytes32 constant VENUE_ALLOCATION_MAX_BPS = keccak256("qudi.VENUE_ALLOCATION_MAX_BPS");
    // Treasury Manager venue limits. Per-venue exposure cap as a share of total
    // Treasury cash; maximum venue redemption delay checked at listing (launch value tracks
    // the pending-obligation window); maximum negative deviation of a venue's realised
    // amount from its ERC-4626 preview.
    bytes32 constant PER_VENUE_CAP_BPS = keccak256("qudi.PER_VENUE_CAP_BPS");
    bytes32 constant MAX_VENUE_REDEMPTION_DELAY = keccak256("qudi.MAX_VENUE_REDEMPTION_DELAY");
    bytes32 constant MAX_VENUE_SLIPPAGE_BPS = keccak256("qudi.MAX_VENUE_SLIPPAGE_BPS");
    bytes32 constant STRESS_CAPITAL_RATE_BPS = keccak256("qudi.STRESS_CAPITAL_RATE_BPS");
    bytes32 constant STRESS_CAPITAL_FLOOR = keccak256("qudi.STRESS_CAPITAL_FLOOR");
    // The debt half. CREDIT_CORE points `Community` at the singleton CreditCore, whose
    // `hasOpenTab` gates a seat forfeit. It is zero until a deployment sets it, which leaves
    // that gate open with no other change. No payout path reads it.
    bytes32 constant CREDIT_CORE = keccak256("qudi.CREDIT_CORE");
    // Trust Extension is earned per completed obligation through its own counter.
    // The calibrated value comes later; the launch value is a bounded starting
    // point, like the activity decay constants. Not
    // a charge on an obligation: it sizes what a member can be lent, never what
    // they owe.
    bytes32 constant TE_EARN_INCREMENT = keccak256("qudi.TE_EARN_INCREMENT");
    // The ceiling on any Venue's `maxRate`, the fastest its share price may rise, in annual bps.
    // Not a charge on an obligation: it bounds how fast savings value is recognised, and a member
    // still repays exactly the principal drawn.
    bytes32 constant MAX_RATE_CEILING_BPS = keccak256("qudi.MAX_RATE_CEILING_BPS");
    // The ceiling on `ManualStrategy.setRate`, the annual rate its pre-funded yield is released at.
    // Not a charge on an obligation, for the same reason.
    bytes32 constant MANUAL_RATE_CEILING_BPS = keccak256("qudi.MANUAL_RATE_CEILING_BPS");
    // Who counts in a shared vault payout's headcount: someone who has deposited at least $10
    // into the shared vault, with a first deposit at least 14 days before the request. Neither is a
    // charge on an obligation: they decide who may vote on a community's own pot, and a member
    // still repays exactly the principal drawn.
    bytes32 constant QUALIFYING_CONTRIBUTOR_MIN_DEPOSIT = keccak256("qudi.QUALIFYING_CONTRIBUTOR_MIN_DEPOSIT");
    bytes32 constant QUALIFYING_CONTRIBUTOR_SEASONING = keccak256("qudi.QUALIFYING_CONTRIBUTOR_SEASONING");
    // How long after a failed removal vote's deadline before the steward may propose removing the
    // same member again. Without it a steward could
    // re-propose each time a vote fails and keep a member frozen indefinitely.
    // The same cooldown also follows a failed shared vault payout request on that vault, and a failed
    // closure vote.
    bytes32 constant REMOVAL_REPROPOSE_COOLDOWN = keccak256("qudi.REMOVAL_REPROPOSE_COOLDOWN");
    // How long a nominated successor has to accept the host role before the nomination lapses.
    bytes32 constant HANDOVER_ACCEPT_WINDOW = keccak256("qudi.HANDOVER_ACCEPT_WINDOW");
    // The most vaults one member's list in one community may hold: personal vaults they own and
    // shared vaults they deposited into. The ledger's impact views walk the list, so the bound is
    // what keeps them within gas. Not a charge on an obligation.
    bytes32 constant MAX_VAULTS_PER_MEMBER = keccak256("qudi.MAX_VAULTS_PER_MEMBER");
}
