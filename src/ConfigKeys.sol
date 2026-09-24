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
    bytes32 constant WITHDRAW_TERM_CORE = keccak256("qudi.WITHDRAW_TERM_CORE");
    // The host removal/election vote (was STEWARD_VOTE_*).
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
    bytes32 constant NAV_PAUSE_BPS = keccak256("qudi.NAV_PAUSE_BPS");
    bytes32 constant INSTANT_TIER_FLOOR_BPS = keccak256("qudi.INSTANT_TIER_FLOOR_BPS");
    bytes32 constant SLOW_TIER_CEILING_BPS = keccak256("qudi.SLOW_TIER_CEILING_BPS");
    bytes32 constant MAX_NOTICE_PERIOD = keccak256("qudi.MAX_NOTICE_PERIOD");
    bytes32 constant GLOBAL_DEPOSIT_CAP = keccak256("qudi.GLOBAL_DEPOSIT_CAP");
    bytes32 constant PROTOCOL_TREASURY = keccak256("qudi.PROTOCOL_TREASURY");
    bytes32 constant COMPLIANCE_REGISTRY = keccak256("qudi.COMPLIANCE_REGISTRY");
    // Member seasoning window: measured from the seat mint timestamp. Credit is
    // gated on it.
    bytes32 constant MEMBER_SEASONING_WINDOW = keccak256("qudi.MEMBER_SEASONING_WINDOW");
    bytes32 constant WITHDRAW_TERM_FLEX = keccak256("qudi.WITHDRAW_TERM_FLEX");
    bytes32 constant FLEX_BUFFER_TARGET_BPS = keccak256("qudi.FLEX_BUFFER_TARGET_BPS");
    /// The Term tier's withdrawal waiting period. Awkwardly named because "term" means two things
    /// here: the WITHDRAW_TERM_* family is the waiting period before a queued withdrawal releases,
    /// and TERM is the tier. This is the waiting period for the Term tier, and it is 0:
    /// a Term vault is locked until its date, so its venue has had the whole lock
    /// period to arrange the liquidity and there is nothing left to wait for at the end of it.
    bytes32 constant WITHDRAW_TERM_TERM = keccak256("qudi.WITHDRAW_TERM_TERM");
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
    // point, like the unlock period and the activity decay constants. Not
    // a charge on an obligation: it sizes what a member can be lent, never what
    // they owe.
    bytes32 constant TE_EARN_INCREMENT = keccak256("qudi.TE_EARN_INCREMENT");
    // The Yield Engine, vault half. None of the three puts a charge on an obligation:
    // they time and bound how the vault recognizes its own venue yield, and a member
    // still repays exactly the principal drawn.
    // The member leg's linear release window, a Risk Committee parameter bounded
    // [1 day, 30 days], launching at the 1-day floor on testnet.
    bytes32 constant UNLOCK_PERIOD = keccak256("qudi.UNLOCK_PERIOD");
    // Harvests are idempotent by venue and period. This is the period's length, so the
    // index a harvest is recorded against is block.timestamp / HARVEST_PERIOD.
    bytes32 constant HARVEST_PERIOD = keccak256("qudi.HARVEST_PERIOD");
    // The deviation breaker: attribution pauses when one harvest's gain exceeds this
    // multiple of that venue's historical average gain. Hundredths, so 300 is 3x.
    bytes32 constant HARVEST_DEVIATION_X100 = keccak256("qudi.HARVEST_DEVIATION_X100");
    // The shared-vault withdrawal. None of the three puts a charge on an obligation: they decide when a
    // community's own pot may pay a recipient it voted for, and a member still repays exactly
    // the principal drawn.
    // Quorum: the share of a vault's qualifying contributors that must vote for the count to
    // stand. Counts of people, never of money.
    bytes32 constant SHARED_WITHDRAWAL_QUORUM_BPS = keccak256("qudi.SHARED_WITHDRAWAL_QUORUM_BPS");
    // Approval: the share of the votes cast that must say yes. Two thirds.
    bytes32 constant SHARED_WITHDRAWAL_APPROVAL_BPS = keccak256("qudi.SHARED_WITHDRAWAL_APPROVAL_BPS");
    // Who counts as a qualifying contributor: someone who has
    // deposited at least $10 into the shared vault at least 14 days before the proposal. Both
    // are the electorate's shape and neither is a charge on an obligation: they decide
    // who may vote on a community's own pot, and a member still repays exactly the principal
    // drawn. Deliberately narrow, because there is no per-member claim
    // on a shared vault's money: eligibility to vote is not a claim, and no money path reads
    // the per-member figures these two bars are checked against.
    bytes32 constant QUALIFYING_CONTRIBUTOR_MIN_DEPOSIT = keccak256("qudi.QUALIFYING_CONTRIBUTOR_MIN_DEPOSIT");
    bytes32 constant QUALIFYING_CONTRIBUTOR_SEASONING = keccak256("qudi.QUALIFYING_CONTRIBUTOR_SEASONING");
    // How long after a PASSED proposal's window closes before anyone may revert it and return
    // the earmark to the vault. The release is a revert and never an expiry.
    bytes32 constant SHARED_PROPOSAL_REVERT_DELAY = keccak256("qudi.SHARED_PROPOSAL_REVERT_DELAY");
    // How long after a failed removal vote's deadline before the steward may propose removing the
    // same member again. Without it a steward could
    // re-propose each time a vote fails and keep a member frozen indefinitely.
    bytes32 constant REMOVAL_REPROPOSE_COOLDOWN = keccak256("qudi.REMOVAL_REPROPOSE_COOLDOWN");
}
