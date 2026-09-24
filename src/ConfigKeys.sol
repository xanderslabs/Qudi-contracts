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
    // Standing. Line-sizing dollar figures are USDC 6-decimal; time windows are seconds.
    bytes32 constant MIN_LENDABLE = keccak256("qudi.MIN_LENDABLE"); // $10
    bytes32 constant GLOBAL_MEMBER_CAP = keccak256("qudi.GLOBAL_MEMBER_CAP"); // $5,000
    // `activity_factor`: W (decay length), FLOOR (>0), and the 90-day heal window shared
    // with the conduct scar.
    bytes32 constant ACTIVITY_DECAY_LENGTH = keccak256("qudi.ACTIVITY_DECAY_LENGTH"); // W: 180 days
    bytes32 constant ACTIVITY_FLOOR_BPS = keccak256("qudi.ACTIVITY_FLOOR_BPS"); // 0.25
    bytes32 constant STANDING_HEAL_WINDOW = keccak256("qudi.STANDING_HEAL_WINDOW"); // 90 days
    // Phase caps.
    bytes32 constant PHASE_CAP_FIRST_ACCESS = keccak256("qudi.PHASE_CAP_FIRST_ACCESS"); // $100
    bytes32 constant PHASE_CAP_PROVEN_ONCE = keccak256("qudi.PHASE_CAP_PROVEN_ONCE"); // $300
    bytes32 constant PHASE_CAP_DEVELOPING = keccak256("qudi.PHASE_CAP_DEVELOPING"); // $1,000
    bytes32 constant PHASE_CAP_ESTABLISHED = keccak256("qudi.PHASE_CAP_ESTABLISHED"); // $5,000
    // Phase multipliers on impact, in hundredths: 100 is 1x.
    bytes32 constant PHASE_MULT_FIRST_ACCESS = keccak256("qudi.PHASE_MULT_FIRST_ACCESS"); // 1x
    bytes32 constant PHASE_MULT_PROVEN_ONCE = keccak256("qudi.PHASE_MULT_PROVEN_ONCE"); // 2x
    bytes32 constant PHASE_MULT_DEVELOPING = keccak256("qudi.PHASE_MULT_DEVELOPING"); // 3x
    bytes32 constant PHASE_MULT_ESTABLISHED = keccak256("qudi.PHASE_MULT_ESTABLISHED"); // 4x
    // The most one member's line may be, as a share of what the community can lend now.
    bytes32 constant CONCENTRATION_BPS = keccak256("qudi.CONCENTRATION_BPS"); // 20%
    // Phase minimum times (First Access and Developing have none).
    bytes32 constant PHASE_MIN_TIME_PROVEN_ONCE = keccak256("qudi.PHASE_MIN_TIME_PROVEN_ONCE"); // +30 days
    bytes32 constant PHASE_MIN_TIME_ESTABLISHED = keccak256("qudi.PHASE_MIN_TIME_ESTABLISHED"); // +180 days
    // The debt half. CREDIT_CORE points `Community` at the singleton CreditCore, whose
    // `hasOpenTab` gates a seat forfeit. It is zero until a deployment sets it, which leaves
    // that gate open with no other change. No payout path reads it.
    bytes32 constant CREDIT_CORE = keccak256("qudi.CREDIT_CORE");
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
    // Pool liquidity: a pool strategy deposit must leave at least this share of every unlent
    // paper balance as cash. It limits what the operator sends out, never a draw.
    bytes32 constant POOL_LIQUID_FLOOR_BPS = keccak256("qudi.POOL_LIQUID_FLOOR_BPS"); // 30%
    // Community dormancy: after the grace with no seat mint, deposit or draw, the share of the
    // balance that can be lent fades to zero over the fade length. Activity heals it over the heal
    // length. After the return period fully faded, the balance may go back to Qudi.
    bytes32 constant COMMUNITY_DORMANCY_GRACE = keccak256("qudi.COMMUNITY_DORMANCY_GRACE"); // 90 days
    bytes32 constant COMMUNITY_FADE_LENGTH = keccak256("qudi.COMMUNITY_FADE_LENGTH"); // 180 days
    bytes32 constant COMMUNITY_HEAL_LENGTH = keccak256("qudi.COMMUNITY_HEAL_LENGTH"); // 90 days
    bytes32 constant COMMUNITY_RETURN_AFTER = keccak256("qudi.COMMUNITY_RETURN_AFTER"); // 365 days
    // No new draw while late plus defaulted principal is above this share of what is out.
    bytes32 constant PORTFOLIO_QUALITY_BPS = keccak256("qudi.PORTFOLIO_QUALITY_BPS"); // 25%
    // The Active seasoned seats a community needs before anyone in it may draw.
    bytes32 constant COMMUNITY_MIN_MEMBERS = keccak256("qudi.COMMUNITY_MIN_MEMBERS"); // 5
    // How long after a defaulted advance is repaid in full before the default heals.
    bytes32 constant DEFAULT_HEAL_COOLING = keccak256("qudi.DEFAULT_HEAL_COOLING"); // 180 days
    // The hash of the current Credit Agreement. A member's first draw must carry it.
    bytes32 constant CREDIT_AGREEMENT_HASH = keccak256("qudi.CREDIT_AGREEMENT_HASH");
    // The most seats one wallet may hold across every community, in any state. A formal default
    // walks all of them inside the repayment that crosses it, so this bounds that walk's gas.
    bytes32 constant MAX_SEATS_PER_WALLET = keccak256("qudi.MAX_SEATS_PER_WALLET"); // 10
}
