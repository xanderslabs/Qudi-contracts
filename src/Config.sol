// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.30;

import {Ownable2Step, Ownable} from "openzeppelin-contracts/contracts/access/Ownable2Step.sol";
import {ConfigKeys as K} from "./ConfigKeys.sol";

/// Keyed parameter store. Every value is bounded, every change is evented, and consumers
/// read live at each use so a change binds future actions only.
///
/// Access: the owner is a 48-hour TimelockController whose proposers and executors
/// are the Risk Committee multisig (dev key on testnet). The contract stays
/// Ownable2Step and the setters stay `onlyOwner`; the delay and the 3-of-5 threshold live in
/// the external holder rather than in per-key queue state here, matching the non-upgradeable
/// posture and reusing OpenZeppelin's audited TimelockController. `bounds()` is
/// `pure`: the encode-time limits are not settable by any path.
contract Config is Ownable2Step {
    mapping(bytes32 => uint256) internal values;
    address public immutable usdc;

    event ParameterChanged(bytes32 indexed key, bytes32 oldValue, bytes32 newValue);

    error ValueOutOfBounds(bytes32 key);
    error SplitMismatch();
    error ZeroAddress();
    error UnknownAddressKey();
    error TimelineOutOfOrder();

    /// Absolute sanity ceiling for the last stage boundary, not a design value: the
    /// canonical write-off is 365 days, and any timeline that runs past this is a fat-finger.
    uint64 internal constant _STAGE_MAX = 1000 days;

    constructor(address usdc_, address treasury_, address complianceRegistry_) Ownable(msg.sender) {
        if (usdc_ == address(0) || treasury_ == address(0) || complianceRegistry_ == address(0)) {
            revert ZeroAddress();
        }
        usdc = usdc_;
        // A host prices seats from $0 to $100. A $0 seat moves no money.
        _init(K.SEAT_PRICE_FLOOR, 0);
        _init(K.SEAT_PRICE_CEILING, 100e6);
        // Around 150 is the size at which a group stops being people who all know each other,
        // and credit here rests on standing among people who do.
        _init(K.MEMBER_CAP, 150);
        // The group link's shape. A single-use link (1 use, 7 days) is an invite inside it.
        _init(K.INVITE_MAX_USES, 25);
        _init(K.INVITE_MAX_TTL, 30 days);
        // Seat-fee split: 40% Community Credit Account / 30% host / 30% protocol.
        _init(K.MINT_SPLIT_HOST, 3000);
        _init(K.MINT_SPLIT_POOL, 4000);
        _init(K.MINT_SPLIT_PROTOCOL, 3000);
        _init(K.EPOCH_LENGTH, 30 days);
        _init(K.HOST_VOTE_THRESHOLD_BPS, 6667);
        _init(K.HOST_VOTE_WINDOW, 7 days);
        _init(K.COMMUNITY_VOTE_THRESHOLD_BPS, 5001);
        _init(K.COMMUNITY_VOTE_WINDOW, 7 days);
        // The shared-vault withdrawal.
        // Quorum 20% of the vault's qualifying contributors, approval two thirds of the votes
        // cast. The three-vote floor is not a parameter: it is a hard
        // constant in Ledger, because no configured percentage should be able to let a
        // community of two pass anything.
        _init(K.SHARED_WITHDRAWAL_QUORUM_BPS, 2000);
        _init(K.SHARED_WITHDRAWAL_APPROVAL_BPS, 6667);
        // A qualifying contributor: at least $10, at least 14 days
        // before the proposal. The seasoning matches the seat one because it answers the
        // same question, whether a stake is old enough to be real.
        _init(K.QUALIFYING_CONTRIBUTOR_MIN_DEPOSIT, 10e6);
        _init(K.QUALIFYING_CONTRIBUTOR_SEASONING, 14 days);
        // Long enough that a host who is slow, travelling or waiting on
        // the recipient does not lose a passed vote, short enough that money is not frozen for
        // a month.
        _init(K.SHARED_PROPOSAL_REVERT_DELAY, 14 days);
        // After a failed removal vote the steward waits
        // this long to propose removing the same member again, so a member is frozen at most one
        // week in a month.
        _init(K.REMOVAL_REPROPOSE_COOLDOWN, 30 days);
        // A nominee has a week to take up the host role, the same length as a vote.
        _init(K.HANDOVER_ACCEPT_WINDOW, 7 days);
        // Canonical stages, elapsed seconds from drawTimestamp.
        _init(K.STAGE_GRACE_START, 60 days);
        _init(K.STAGE_LATE_START, 65 days);
        _init(K.STAGE_FINAL_CURE_START, 95 days);
        _init(K.STAGE_DEFAULT_RECOVERY_START, 155 days);
        _init(K.STAGE_WRITTEN_OFF_AT, 365 days);
        _init(K.DORMANCY_GRACE, 90 days);
        _init(K.ELIG_MIN_MEMBERS, 5);
        _init(K.ELIG_CLEAN_EPOCHS, 1);
        _init(K.ELIG_MEMBER_MONTHS, 3);
        _init(K.ELIG_MAX_GAP_MONTHS, 1);
        _init(K.YIELD_SPLIT_MEMBER, 7000);
        _init(K.YIELD_SPLIT_POOL, 1500);
        _init(K.YIELD_SPLIT_PROTOCOL, 1500);
        _init(K.INSTANT_TIER_FLOOR_BPS, 2500);
        _init(K.SLOW_TIER_CEILING_BPS, 2500);
        _init(K.MAX_NOTICE_PERIOD, 30 days);
        _init(K.GLOBAL_DEPOSIT_CAP, 1_000_000e6);
        _init(K.PROTOCOL_TREASURY, uint160(treasury_));
        _init(K.COMPLIANCE_REGISTRY, uint160(complianceRegistry_));
        _init(K.MEMBER_SEASONING_WINDOW, 14 days);
        // Retained-capital launch values. USDC 6-decimal amounts; bps for percentages.
        _init(K.OPERATING_BUFFER_PER_COMMUNITY, 2000e6);
        _init(K.OPERATING_FLOOR_GLOBAL, 10_000e6);
        _init(K.CREDIT_LOSS_RESERVE_CURRENT_BPS, 500);
        _init(K.CREDIT_LOSS_RESERVE_LATE_BPS, 2500);
        _init(K.CREDIT_LOSS_RESERVE_FINAL_CURE_BPS, 5000);
        _init(K.CREDIT_LOSS_RESERVE_DEFAULT_RECOVERY_BPS, 10_000);
        _init(K.VENUE_LOSS_RESERVE_BPS, 2000);
        _init(K.VENUE_ALLOCATION_MAX_BPS, 5000); // 50% of liquid above buffer
        _init(K.STRESS_CAPITAL_RATE_BPS, 1000);
        _init(K.STRESS_CAPITAL_FLOOR, 100_000e6);
        // Treasury Manager venue limits. Values are calibrated later.
        _init(K.PER_VENUE_CAP_BPS, 2500); // 25% of total Treasury cash
        // The redemption-delay limit is the pending-obligation window. That window
        // had its own key until it was retired as unread, so the 7 days is written here
        // directly. The number is unchanged and so is its reason; what is gone is a second
        // parameter nothing consumed.
        _init(K.MAX_VENUE_REDEMPTION_DELAY, 7 days);
        _init(K.MAX_VENUE_SLIPPAGE_BPS, 50); // max negative deviation from an ERC-4626 preview
        // Standing, the CreditCore half. Sanity ranges follow the contract's existing precedent.
        _init(K.MIN_LENDABLE, 50e6);
        _init(K.GLOBAL_MEMBER_CAP, 5000e6);
        _init(K.EXPOSURE_IMPACT_MULT_X100, 300); // 3x realized attributable impact
        _init(K.ACTIVITY_DECAY_LENGTH, 180 days); // W
        _init(K.ACTIVITY_FLOOR_BPS, 2500); // FLOOR 0.25
        _init(K.STANDING_HEAL_WINDOW, 90 days); // heal window
        _init(K.PHASE_CAP_FIRST_ACCESS, 100e6);
        _init(K.PHASE_CAP_PROVEN_ONCE, 300e6);
        _init(K.PHASE_CAP_DEVELOPING, 1000e6);
        _init(K.CONCENTRATION_FIRST_ACCESS_BPS, 500);
        _init(K.CONCENTRATION_PROVEN_ONCE_BPS, 800);
        _init(K.CONCENTRATION_DEVELOPING_BPS, 1000);
        _init(K.CONCENTRATION_ESTABLISHED_BPS, 1200);
        _init(K.TE_BUDGET_PROVEN_ONCE, 200e6);
        _init(K.TE_BUDGET_DEVELOPING, 700e6);
        _init(K.TE_BUDGET_ESTABLISHED, 4000e6);
        _init(K.TE_COMMUNITY_CAP_BPS, 2000); // 20% of cumulative attributed funding yield
        _init(K.PHASE_MIN_TIME_PROVEN_ONCE, 30 days);
        _init(K.PHASE_MIN_TIME_ESTABLISHED, 180 days);
        // The debt half. CREDIT_CORE stays zero until the deployment that owns the
        // CreditCore singleton sets it; te earn increment launch value pending calibration.
        _init(K.TE_EARN_INCREMENT, 100e6);
        // 20% a year, well above every venue's gross return, so each venue's own `maxRate` is
        // what binds and this only stops a fat-fingered one.
        _init(K.MAX_RATE_CEILING_BPS, 2000);
        _init(K.MANUAL_RATE_CEILING_BPS, 2000);
    }

    function _init(bytes32 key, uint256 v) internal {
        values[key] = v;
        emit ParameterChanged(key, bytes32(0), bytes32(v));
    }

    // ---- setters ----

    /// Scalar keys only. Composite keys (splits, stage boundaries, addresses) go through their
    /// composite setter so group consistency can never break transiently; their bounds are
    /// (1, 0) here, which rejects every scalar write.
    function set(bytes32 key, uint256 value) external onlyOwner {
        (uint256 lo, uint256 hi) = bounds(key);
        if (value < lo || value > hi) revert ValueOutOfBounds(key);
        _write(key, value);
    }

    function setMintSplit(uint16 host, uint16 pool, uint16 protocol) external onlyOwner {
        if (uint256(host) + pool + protocol != 10_000) revert SplitMismatch();
        _write(K.MINT_SPLIT_HOST, host);
        _write(K.MINT_SPLIT_POOL, pool);
        _write(K.MINT_SPLIT_PROTOCOL, protocol);
    }

    /// The five stage boundaries, written atomically. The ordering check is what makes
    /// an out-of-order timeline unreachable rather than merely discouraged: each boundary's
    /// effective lower bound is the one before it.
    function setStageBoundaries(
        uint64 graceStart,
        uint64 lateStart,
        uint64 finalCureStart,
        uint64 defaultRecoveryStart,
        uint64 writtenOffAt
    ) external onlyOwner {
        if (
            graceStart == 0 || graceStart >= lateStart || lateStart >= finalCureStart
                || finalCureStart >= defaultRecoveryStart || defaultRecoveryStart >= writtenOffAt
                || writtenOffAt > _STAGE_MAX
        ) revert TimelineOutOfOrder();
        _write(K.STAGE_GRACE_START, graceStart);
        _write(K.STAGE_LATE_START, lateStart);
        _write(K.STAGE_FINAL_CURE_START, finalCureStart);
        _write(K.STAGE_DEFAULT_RECOVERY_START, defaultRecoveryStart);
        _write(K.STAGE_WRITTEN_OFF_AT, writtenOffAt);
    }

    function setYieldSplit(uint16 memberBps, uint16 poolBps, uint16 protocolBps) external onlyOwner {
        if (uint256(memberBps) + poolBps + protocolBps != 10_000) revert SplitMismatch();
        _write(K.YIELD_SPLIT_MEMBER, memberBps);
        _write(K.YIELD_SPLIT_POOL, poolBps);
        _write(K.YIELD_SPLIT_PROTOCOL, protocolBps);
    }

    function setAddress(bytes32 key, address value) external onlyOwner {
        if (key != K.PROTOCOL_TREASURY && key != K.COMPLIANCE_REGISTRY && key != K.CREDIT_CORE) {
            revert UnknownAddressKey();
        }
        if (value == address(0)) revert ZeroAddress();
        _write(key, uint160(value));
    }

    function _write(bytes32 key, uint256 v) internal {
        bytes32 old = bytes32(values[key]);
        values[key] = v;
        emit ParameterChanged(key, old, bytes32(v));
    }

    /// Hard sanity ranges per scalar key: a fat-fingered owner transaction cannot set an
    /// absurd value. Composite, address, and unknown keys return (1, 0) so `set` always reverts.
    function bounds(bytes32 key) public pure returns (uint256 lo, uint256 hi) {
        // The floor may be zero, since a free seat is allowed, and neither end goes past $1,000.
        // A ceiling below the floor would stop every community being created and every price
        // vote passing; Config does not tie two keys together, so that is the owner's to avoid.
        if (key == K.SEAT_PRICE_FLOOR) return (0, 1000e6);
        if (key == K.SEAT_PRICE_CEILING) return (0, 1000e6);
        // At least 10, the members a community needs holding impact before credit opens.
        if (key == K.MEMBER_CAP) return (10, 1000);
        // At least 1 use and 1 day, or no invite could seat anyone.
        if (key == K.INVITE_MAX_USES) return (1, 150);
        if (key == K.INVITE_MAX_TTL) return (1 days, 90 days);
        if (key == K.EPOCH_LENGTH) return (1 days, 90 days);
        if (key == K.HOST_VOTE_THRESHOLD_BPS) return (5001, 10_000);
        if (key == K.HOST_VOTE_WINDOW) return (1 days, 30 days);
        if (key == K.COMMUNITY_VOTE_THRESHOLD_BPS) return (5001, 10_000);
        if (key == K.COMMUNITY_VOTE_WINDOW) return (1 days, 30 days);
        // The quorum is a floor on participation, so it may be raised but never removed: 500 bps
        // keeps a governed change from setting it to zero and letting one voter carry a pot.
        // The approval bar keeps the same lower bound as every other vote in the
        // contract, a simple majority. The upper bounds are sanity ranges, not design values.
        if (key == K.SHARED_WITHDRAWAL_QUORUM_BPS) return (500, 10_000);
        if (key == K.SHARED_WITHDRAWAL_APPROVAL_BPS) return (5001, 10_000);
        // A revert delay of zero would make a passed proposal revertible the instant its window
        // closed, which is a race against the execution it is meant to wait for; 30 days is the
        // "frozen for a month" the launch value was chosen against.
        if (key == K.SHARED_PROPOSAL_REVERT_DELAY) return (1 days, 30 days);
        // Both ends are set: at least 7 days so a timelocked change cannot make
        // it zero and let a steward re-freeze a member the moment a vote fails, at most 180.
        if (key == K.REMOVAL_REPROPOSE_COOLDOWN) return (7 days, 180 days);
        // At least a day, so a nominee has time to see the nomination; at most the 30 days
        // every other window in this contract gets.
        if (key == K.HANDOVER_ACCEPT_WINDOW) return (1 days, 30 days);
        // The launch values are $10 and 14 days; these sanity ranges are not design
        // values. Both floors sit above zero because a floor must never repeal the mechanism: at zero either bar disappears
        // and a dust deposit made a second before the proposal would carry a vote, which is the
        // exact thing this pair exists to stop. The ceilings follow the contract's other dollar
        // and time-window bounds.
        if (key == K.QUALIFYING_CONTRIBUTOR_MIN_DEPOSIT) return (1e6, 10_000e6);
        if (key == K.QUALIFYING_CONTRIBUTOR_SEASONING) return (1 days, 90 days);
        if (key == K.DORMANCY_GRACE) return (0, 365 days);
        if (key == K.ELIG_MIN_MEMBERS) return (2, 100);
        if (key == K.ELIG_CLEAN_EPOCHS) return (0, 12);
        if (key == K.ELIG_MEMBER_MONTHS) return (0, 24);
        if (key == K.ELIG_MAX_GAP_MONTHS) return (0, 12);
        if (key == K.INSTANT_TIER_FLOOR_BPS) return (0, 10_000);
        if (key == K.SLOW_TIER_CEILING_BPS) return (0, 10_000);
        if (key == K.MAX_NOTICE_PERIOD) return (0, 30 days);
        // The launch value is 14 days; this sanity range is not a design value. It follows
        // the contract's other time-window bounds.
        if (key == K.MEMBER_SEASONING_WINDOW) return (1 days, 90 days);
        // The launch values are 0.5% and 3 days. The lower bounds keep a governed change
        // from repealing the cost entirely (a bound that permits removing a set value
        // is the wrong bound): 25 bps is half the set fee, 1 day a third of the set delay.
        // The upper bounds are sanity ranges, not design values.
        if (key == K.GLOBAL_DEPOSIT_CAP) return (0, type(uint256).max);
        // Retained-capital bounds. These are sanity ranges, not design values; they follow
        // the contract's existing bps and dollar-amount precedent.
        if (key == K.OPERATING_BUFFER_PER_COMMUNITY) return (0, 1_000_000e6);
        if (key == K.OPERATING_FLOOR_GLOBAL) return (0, 100_000_000e6);
        if (key == K.CREDIT_LOSS_RESERVE_CURRENT_BPS) return (0, 10_000);
        if (key == K.CREDIT_LOSS_RESERVE_LATE_BPS) return (0, 10_000);
        if (key == K.CREDIT_LOSS_RESERVE_FINAL_CURE_BPS) return (0, 10_000);
        if (key == K.CREDIT_LOSS_RESERVE_DEFAULT_RECOVERY_BPS) return (0, 10_000);
        if (key == K.VENUE_LOSS_RESERVE_BPS) return (0, 10_000);
        // The launch value is 50%. The sanity range is not a design value; it
        // follows the contract's other bps parameters.
        if (key == K.VENUE_ALLOCATION_MAX_BPS) return (0, 10_000);
        // Venue limits. These are sanity ranges, not design values. Both
        // ends of each range matter: a floor of zero
        // repeals the mechanism, and a ceiling at which the check can never fire does the same
        // from the other end. The per-venue ceiling is 5000 (50%), not 10_000: at 10_000 a
        // venue's own exposure, which is part of the cap's base, can never exceed the cap, so
        // the concentration check would be dead while formally in range. The redemption-delay
        // ceiling is the 30 days every other window in this contract gets; it used to be read
        // off the pending-obligation window's ceiling, which was the same 30 days, before
        // that key was retired. The slippage ceiling stays well under a level that would make the
        // check meaningless.
        if (key == K.PER_VENUE_CAP_BPS) return (1, 5000);
        if (key == K.MAX_VENUE_REDEMPTION_DELAY) return (1, 30 days);
        if (key == K.MAX_VENUE_SLIPPAGE_BPS) return (1, 1000);
        if (key == K.STRESS_CAPITAL_RATE_BPS) return (0, 10_000);
        if (key == K.STRESS_CAPITAL_FLOOR) return (0, 100_000_000e6);
        // Standing bounds. These are sanity ranges, not design values. Floors above zero
        // where a zero repeals the mechanism (ACTIVITY_FLOOR_BPS, and the same shape for
        // MIN_LENDABLE and the multiplier). ACTIVITY_FLOOR_BPS also has a ceiling below 10_000: at exactly 1.0 a
        // fully dormant member keeps a full Line and the decay is dead.
        if (key == K.MIN_LENDABLE) return (1e6, 10_000e6);
        if (key == K.GLOBAL_MEMBER_CAP) return (1e6, 1_000_000e6);
        if (key == K.EXPOSURE_IMPACT_MULT_X100) return (100, 1000);
        if (key == K.ACTIVITY_DECAY_LENGTH) return (1 days, 730 days);
        if (key == K.ACTIVITY_FLOOR_BPS) return (1, 9999);
        if (key == K.STANDING_HEAL_WINDOW) return (1 days, 365 days);
        if (key == K.PHASE_CAP_FIRST_ACCESS) return (1e6, 1_000_000e6);
        if (key == K.PHASE_CAP_PROVEN_ONCE) return (1e6, 1_000_000e6);
        if (key == K.PHASE_CAP_DEVELOPING) return (1e6, 1_000_000e6);
        if (key == K.CONCENTRATION_FIRST_ACCESS_BPS) return (1, 10_000);
        if (key == K.CONCENTRATION_PROVEN_ONCE_BPS) return (1, 10_000);
        if (key == K.CONCENTRATION_DEVELOPING_BPS) return (1, 10_000);
        if (key == K.CONCENTRATION_ESTABLISHED_BPS) return (1, 10_000);
        if (key == K.TE_BUDGET_PROVEN_ONCE) return (0, 1_000_000e6);
        if (key == K.TE_BUDGET_DEVELOPING) return (0, 1_000_000e6);
        if (key == K.TE_BUDGET_ESTABLISHED) return (0, 1_000_000e6);
        if (key == K.TE_COMMUNITY_CAP_BPS) return (0, 10_000);
        if (key == K.PHASE_MIN_TIME_PROVEN_ONCE) return (0, 730 days);
        if (key == K.PHASE_MIN_TIME_ESTABLISHED) return (0, 730 days);
        // The calibrated value comes later; this sanity range follows the other
        // Standing dollar-amount parameters.
        if (key == K.TE_EARN_INCREMENT) return (0, 1_000_000e6);
        // Sanity ranges, not design values. The floor keeps a governed change from setting the
        // ceiling to zero, which would freeze every venue's price and every strategy's yield; the
        // ceiling is 100% a year, past which no savings rate is plausible.
        if (key == K.MAX_RATE_CEILING_BPS) return (1, 10_000);
        if (key == K.MANUAL_RATE_CEILING_BPS) return (1, 10_000);
        return (1, 0); // composite, address, or unknown: scalar set always reverts
    }

    // ---- typed getters (surface mirrored in interfaces/IConfig.sol) ----

    /// The ceiling on any Venue's `maxRate`, in annual bps.
    function maxRateCeilingBps() external view returns (uint16) {
        return uint16(values[K.MAX_RATE_CEILING_BPS]);
    }

    /// The ceiling on `ManualStrategy.setRate`, in annual bps.
    function manualRateCeilingBps() external view returns (uint16) {
        return uint16(values[K.MANUAL_RATE_CEILING_BPS]);
    }

    function seatPriceFloor() external view returns (uint256) {
        return values[K.SEAT_PRICE_FLOOR];
    }

    function seatPriceCeiling() external view returns (uint256) {
        return values[K.SEAT_PRICE_CEILING];
    }

    function memberCap() external view returns (uint256) {
        return values[K.MEMBER_CAP];
    }

    function inviteLimits() external view returns (uint32 maxUses, uint64 maxTtl) {
        return (uint32(values[K.INVITE_MAX_USES]), uint64(values[K.INVITE_MAX_TTL]));
    }

    function mintSplit() external view returns (uint16 host, uint16 pool, uint16 protocol) {
        return
            (
                uint16(values[K.MINT_SPLIT_HOST]),
                uint16(values[K.MINT_SPLIT_POOL]),
                uint16(values[K.MINT_SPLIT_PROTOCOL])
            );
    }

    function epochLength() external view returns (uint64) {
        return uint64(values[K.EPOCH_LENGTH]);
    }

    function hostVote() external view returns (uint16 thresholdBps, uint64 window) {
        return (uint16(values[K.HOST_VOTE_THRESHOLD_BPS]), uint64(values[K.HOST_VOTE_WINDOW]));
    }

    /// Threshold and window for the community vote types (card-price approval, member removal,
    /// host election, and the handover's objection period). Simple-majority default; the host
    /// removal vote keeps its own higher two-thirds threshold in hostVote().
    function communityVote() external view returns (uint16 thresholdBps, uint64 window) {
        return (uint16(values[K.COMMUNITY_VOTE_THRESHOLD_BPS]), uint64(values[K.COMMUNITY_VOTE_WINDOW]));
    }

    /// The two bars a shared-vault withdrawal must clear. Both are
    /// counts of people: `quorumBps` of the vault's qualifying contributors must vote, and
    /// `approvalBps` of the votes cast must say yes. The vote window is `communityVote`'s, and
    /// the three-vote floor is Ledger's constant.
    function sharedWithdrawalVote() external view returns (uint16 quorumBps, uint16 approvalBps) {
        return (uint16(values[K.SHARED_WITHDRAWAL_QUORUM_BPS]), uint16(values[K.SHARED_WITHDRAWAL_APPROVAL_BPS]));
    }

    /// The two bars a qualifying contributor clears: at least
    /// `minDeposit` into the shared vault, at least `seasoning` before the proposal. The ledger
    /// measures the seasoning against the proposal's own creation time, not the current block.
    function qualifyingContributor() external view returns (uint256 minDeposit, uint64 seasoning) {
        return (values[K.QUALIFYING_CONTRIBUTOR_MIN_DEPOSIT], uint64(values[K.QUALIFYING_CONTRIBUTOR_SEASONING]));
    }

    /// How long after a passed proposal's window closes before anyone may revert it and return
    /// the earmark to the vault (a revert, never an expiry).
    function sharedProposalRevertDelay() external view returns (uint64) {
        return uint64(values[K.SHARED_PROPOSAL_REVERT_DELAY]);
    }

    /// Seconds after a failed removal vote's deadline before the same member may be proposed
    /// for removal again.
    function removalReproposeCooldown() external view returns (uint64) {
        return uint64(values[K.REMOVAL_REPROPOSE_COOLDOWN]);
    }

    /// Seconds a nominated successor has to accept the host role.
    function handoverAcceptWindow() external view returns (uint64) {
        return uint64(values[K.HANDOVER_ACCEPT_WINDOW]);
    }

    /// The five canonical stage boundaries, elapsed seconds from drawTimestamp.
    function stageBoundaries()
        external
        view
        returns (
            uint64 graceStart,
            uint64 lateStart,
            uint64 finalCureStart,
            uint64 defaultRecoveryStart,
            uint64 writtenOffAt
        )
    {
        return (
            uint64(values[K.STAGE_GRACE_START]),
            uint64(values[K.STAGE_LATE_START]),
            uint64(values[K.STAGE_FINAL_CURE_START]),
            uint64(values[K.STAGE_DEFAULT_RECOVERY_START]),
            uint64(values[K.STAGE_WRITTEN_OFF_AT])
        );
    }

    function dormancyGrace() external view returns (uint64) {
        return uint64(values[K.DORMANCY_GRACE]);
    }

    function eligibility()
        external
        view
        returns (uint8 minMembers, uint8 cleanEpochs, uint8 memberMonths, uint8 maxGapMonths)
    {
        return (
            uint8(values[K.ELIG_MIN_MEMBERS]),
            uint8(values[K.ELIG_CLEAN_EPOCHS]),
            uint8(values[K.ELIG_MEMBER_MONTHS]),
            uint8(values[K.ELIG_MAX_GAP_MONTHS])
        );
    }

    function yieldSplit() external view returns (uint16 memberBps, uint16 poolBps, uint16 protocolBps) {
        return (
            uint16(values[K.YIELD_SPLIT_MEMBER]),
            uint16(values[K.YIELD_SPLIT_POOL]),
            uint16(values[K.YIELD_SPLIT_PROTOCOL])
        );
    }

    function instantTierFloorBps() external view returns (uint16) {
        return uint16(values[K.INSTANT_TIER_FLOOR_BPS]);
    }

    function slowTierCeilingBps() external view returns (uint16) {
        return uint16(values[K.SLOW_TIER_CEILING_BPS]);
    }

    function maxNoticePeriod() external view returns (uint64) {
        return uint64(values[K.MAX_NOTICE_PERIOD]);
    }

    function globalDepositCap() external view returns (uint256) {
        return values[K.GLOBAL_DEPOSIT_CAP];
    }

    function protocolTreasury() external view returns (address) {
        return address(uint160(values[K.PROTOCOL_TREASURY]));
    }

    function complianceRegistry() external view returns (address) {
        return address(uint160(values[K.COMPLIANCE_REGISTRY]));
    }

    function memberSeasoningWindow() external view returns (uint64) {
        return uint64(values[K.MEMBER_SEASONING_WINDOW]);
    }

    // ---- retained-capital getters ----

    function operatingRequirement() external view returns (uint256 perCommunityBuffer, uint256 globalFloor) {
        return (values[K.OPERATING_BUFFER_PER_COMMUNITY], values[K.OPERATING_FLOOR_GLOBAL]);
    }

    function creditLossReserveBps()
        external
        view
        returns (uint16 current, uint16 late, uint16 finalCure, uint16 defaultRecovery)
    {
        return (
            uint16(values[K.CREDIT_LOSS_RESERVE_CURRENT_BPS]),
            uint16(values[K.CREDIT_LOSS_RESERVE_LATE_BPS]),
            uint16(values[K.CREDIT_LOSS_RESERVE_FINAL_CURE_BPS]),
            uint16(values[K.CREDIT_LOSS_RESERVE_DEFAULT_RECOVERY_BPS])
        );
    }

    function venueLossReserveBps() external view returns (uint16) {
        return uint16(values[K.VENUE_LOSS_RESERVE_BPS]);
    }

    function venueAllocationMaxBps() external view returns (uint16) {
        return uint16(values[K.VENUE_ALLOCATION_MAX_BPS]);
    }

    // ---- Treasury Manager venue limits ----

    function perVenueCapBps() external view returns (uint16) {
        return uint16(values[K.PER_VENUE_CAP_BPS]);
    }

    // ---- Standing ----

    function minLendable() external view returns (uint256) {
        return values[K.MIN_LENDABLE];
    }

    function globalMemberCap() external view returns (uint256) {
        return values[K.GLOBAL_MEMBER_CAP];
    }

    function exposureImpactMultX100() external view returns (uint256) {
        return values[K.EXPOSURE_IMPACT_MULT_X100];
    }

    function activityDecayLength() external view returns (uint64) {
        return uint64(values[K.ACTIVITY_DECAY_LENGTH]);
    }

    function activityFloorBps() external view returns (uint16) {
        return uint16(values[K.ACTIVITY_FLOOR_BPS]);
    }

    function standingHealWindow() external view returns (uint64) {
        return uint64(values[K.STANDING_HEAL_WINDOW]);
    }

    function teCommunityCapBps() external view returns (uint16) {
        return uint16(values[K.TE_COMMUNITY_CAP_BPS]);
    }

    /// Per-phase caps: `(lineCap, concentrationBps, trustExtensionBudget,
    /// minTimeInPreviousPhase)`. `phase` is the `CreditCore.Phase` enum value (0..3).
    /// Established's line cap is the Global Member Cap, and First Access / Developing
    /// have no minimum time.
    function phaseCaps(uint8 phase)
        external
        view
        returns (uint256 lineCap, uint16 concentrationBps, uint256 trustExtensionBudget, uint64 minTime)
    {
        if (phase == 0) {
            return (values[K.PHASE_CAP_FIRST_ACCESS], uint16(values[K.CONCENTRATION_FIRST_ACCESS_BPS]), 0, 0);
        }
        if (phase == 1) {
            return (
                values[K.PHASE_CAP_PROVEN_ONCE],
                uint16(values[K.CONCENTRATION_PROVEN_ONCE_BPS]),
                values[K.TE_BUDGET_PROVEN_ONCE],
                uint64(values[K.PHASE_MIN_TIME_PROVEN_ONCE])
            );
        }
        if (phase == 2) {
            return (
                values[K.PHASE_CAP_DEVELOPING],
                uint16(values[K.CONCENTRATION_DEVELOPING_BPS]),
                values[K.TE_BUDGET_DEVELOPING],
                0
            );
        }
        return (
            values[K.GLOBAL_MEMBER_CAP],
            uint16(values[K.CONCENTRATION_ESTABLISHED_BPS]),
            values[K.TE_BUDGET_ESTABLISHED],
            uint64(values[K.PHASE_MIN_TIME_ESTABLISHED])
        );
    }

    function maxVenueRedemptionDelay() external view returns (uint64) {
        return uint64(values[K.MAX_VENUE_REDEMPTION_DELAY]);
    }

    function maxVenueSlippageBps() external view returns (uint16) {
        return uint16(values[K.MAX_VENUE_SLIPPAGE_BPS]);
    }

    function stressCapital() external view returns (uint16 rateBps, uint256 floor) {
        return (uint16(values[K.STRESS_CAPITAL_RATE_BPS]), values[K.STRESS_CAPITAL_FLOOR]);
    }

    // ---- the debt half ----

    function creditCore() external view returns (address) {
        return address(uint160(values[K.CREDIT_CORE]));
    }

    function teEarnIncrement() external view returns (uint256) {
        return values[K.TE_EARN_INCREMENT];
    }
}
