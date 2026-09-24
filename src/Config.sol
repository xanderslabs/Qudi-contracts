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
    error CreditCoreAlreadySet();
    error TimelineOutOfOrder();
    error ZeroAgreementHash();

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
        _init(K.HOST_VOTE_THRESHOLD_BPS, 6667);
        _init(K.HOST_VOTE_WINDOW, 7 days);
        _init(K.COMMUNITY_VOTE_THRESHOLD_BPS, 5001);
        _init(K.COMMUNITY_VOTE_WINDOW, 7 days);
        // A shared vault payout counts a member who deposited at least $10, first at least 14 days
        // before the request. The seasoning matches the seat one because it answers the same
        // question, whether a stake is old enough to be real.
        _init(K.QUALIFYING_CONTRIBUTOR_MIN_DEPOSIT, 10e6);
        _init(K.QUALIFYING_CONTRIBUTOR_SEASONING, 14 days);
        // After a failed removal vote the host waits
        // this long to propose removing the same member again, so a member is frozen at most one
        // week in a month.
        _init(K.REMOVAL_REPROPOSE_COOLDOWN, 30 days);
        // A nominee has a week to take up the host role, the same length as a vote.
        _init(K.HANDOVER_ACCEPT_WINDOW, 7 days);
        // Enough for every venue in personal and shared form many times over, and small enough
        // that the ledger's impact views, which walk a member's list, stay cheap.
        _init(K.MAX_VAULTS_PER_MEMBER, 32);
        // Canonical stages, elapsed seconds from drawTimestamp.
        _init(K.STAGE_GRACE_START, 60 days);
        _init(K.STAGE_LATE_START, 65 days);
        _init(K.STAGE_FINAL_CURE_START, 95 days);
        _init(K.STAGE_DEFAULT_RECOVERY_START, 155 days);
        _init(K.STAGE_WRITTEN_OFF_AT, 365 days);
        _init(K.DORMANCY_GRACE, 90 days);
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
        // Standing. A line is the member's impact times the phase multiplier, capped by the phase
        // cap, 20% of what the community can lend now, and the member cap.
        _init(K.MIN_LENDABLE, 10e6);
        _init(K.GLOBAL_MEMBER_CAP, 5000e6);
        _init(K.ACTIVITY_DECAY_LENGTH, 180 days); // W
        _init(K.ACTIVITY_FLOOR_BPS, 2500); // FLOOR 0.25
        _init(K.STANDING_HEAL_WINDOW, 90 days); // heal window
        _init(K.PHASE_CAP_FIRST_ACCESS, 100e6);
        _init(K.PHASE_CAP_PROVEN_ONCE, 300e6);
        _init(K.PHASE_CAP_DEVELOPING, 1000e6);
        _init(K.PHASE_CAP_ESTABLISHED, 5000e6);
        // First Access is 1x because at 2x a host with fake members nets a tenth of the seat price
        // per fake seat from honest members' balance, and at 1x loses three tenths.
        _init(K.PHASE_MULT_FIRST_ACCESS, 100);
        _init(K.PHASE_MULT_PROVEN_ONCE, 200);
        _init(K.PHASE_MULT_DEVELOPING, 300);
        _init(K.PHASE_MULT_ESTABLISHED, 400);
        _init(K.CONCENTRATION_BPS, 2000);
        _init(K.PHASE_MIN_TIME_PROVEN_ONCE, 30 days);
        _init(K.PHASE_MIN_TIME_ESTABLISHED, 180 days);
        // The pool keeps 30% of unlent balances as cash; the operator's own policy runs inside it.
        _init(K.POOL_LIQUID_FLOOR_BPS, 3000);
        _init(K.COMMUNITY_DORMANCY_GRACE, 90 days);
        _init(K.COMMUNITY_FADE_LENGTH, 180 days);
        _init(K.COMMUNITY_HEAL_LENGTH, 90 days);
        _init(K.COMMUNITY_RETURN_AFTER, 365 days);
        _init(K.PORTFOLIO_QUALITY_BPS, 2500);
        _init(K.COMMUNITY_MIN_MEMBERS, 5);
        _init(K.DEFAULT_HEAL_COOLING, 180 days);
        // A formal default walks every seat the wallet holds, inside the repayment that crosses it.
        // At 10 seats, each with a full list of shared vaults, that repayment was measured at under
        // 9M gas. Raising this needs a cheaper walk and a new measurement first.
        _init(K.MAX_SEATS_PER_WALLET, 10);
        // CREDIT_AGREEMENT_HASH starts at zero, which no draw can match: credit stays shut until
        // the owner sets the agreement members sign.
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
        if (key != K.PROTOCOL_TREASURY && key != K.COMPLIANCE_REGISTRY && key != K.CREDIT_CORE && key != K.PAUSE_GUARD)
        {
            revert UnknownAddressKey();
        }
        if (value == address(0)) revert ZeroAddress();
        // Every community's seat leg and yield leg are paid to CREDIT_CORE. Set once, so no owner
        // key can ever redirect them.
        if (key == K.CREDIT_CORE && values[key] != 0) revert CreditCoreAlreadySet();
        _write(key, uint160(value));
    }

    /// The Credit Agreement members sign. A hash, not a number, so it has its own setter; zero is
    /// refused because no draw could ever match it.
    function setCreditAgreementHash(bytes32 agreementHash) external onlyOwner {
        if (agreementHash == bytes32(0)) revert ZeroAgreementHash();
        _write(K.CREDIT_AGREEMENT_HASH, uint256(agreementHash));
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
        if (key == K.HOST_VOTE_THRESHOLD_BPS) return (5001, 10_000);
        if (key == K.HOST_VOTE_WINDOW) return (1 days, 30 days);
        if (key == K.COMMUNITY_VOTE_THRESHOLD_BPS) return (5001, 10_000);
        if (key == K.COMMUNITY_VOTE_WINDOW) return (1 days, 30 days);
        // Both ends are set: at least 7 days so a timelocked change cannot make
        // it zero and let a host re-freeze a member the moment a vote fails, at most 180.
        if (key == K.REMOVAL_REPROPOSE_COOLDOWN) return (7 days, 180 days);
        // At least a day, so a nominee has time to see the nomination; at most the 30 days
        // every other window in this contract gets.
        if (key == K.HANDOVER_ACCEPT_WINDOW) return (1 days, 30 days);
        // At least 1, or no member could open a vault. At most 64, so a member's impact read
        // walks a bounded list.
        if (key == K.MAX_VAULTS_PER_MEMBER) return (1, 64);
        // The launch values are $10 and 14 days; these sanity ranges are not design
        // values. Both floors sit above zero because a floor must never repeal the mechanism: at zero either bar disappears
        // and a dust deposit made a second before the proposal would carry a vote, which is the
        // exact thing this pair exists to stop. The ceilings follow the contract's other dollar
        // and time-window bounds.
        if (key == K.QUALIFYING_CONTRIBUTOR_MIN_DEPOSIT) return (1e6, 10_000e6);
        if (key == K.QUALIFYING_CONTRIBUTOR_SEASONING) return (1 days, 90 days);
        if (key == K.DORMANCY_GRACE) return (0, 365 days);
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
        // Standing bounds. These are sanity ranges, not design values. Floors above zero
        // where a zero repeals the mechanism (ACTIVITY_FLOOR_BPS, and the same shape for
        // MIN_LENDABLE and the multipliers). ACTIVITY_FLOOR_BPS also has a ceiling below 10_000: at exactly 1.0 a
        // fully dormant member keeps a full Line and the decay is dead.
        if (key == K.MIN_LENDABLE) return (1e6, 10_000e6);
        if (key == K.GLOBAL_MEMBER_CAP) return (1e6, 1_000_000e6);
        if (key == K.ACTIVITY_DECAY_LENGTH) return (1 days, 730 days);
        if (key == K.ACTIVITY_FLOOR_BPS) return (1, 9999);
        if (key == K.STANDING_HEAL_WINDOW) return (1 days, 365 days);
        if (key == K.PHASE_CAP_FIRST_ACCESS) return (1e6, 1_000_000e6);
        if (key == K.PHASE_CAP_PROVEN_ONCE) return (1e6, 1_000_000e6);
        if (key == K.PHASE_CAP_DEVELOPING) return (1e6, 1_000_000e6);
        if (key == K.PHASE_CAP_ESTABLISHED) return (1e6, 1_000_000e6);
        // From a hundredth of impact to 10x. A zero multiplier would shut every line in its phase.
        if (key == K.PHASE_MULT_FIRST_ACCESS) return (1, 1000);
        if (key == K.PHASE_MULT_PROVEN_ONCE) return (1, 1000);
        if (key == K.PHASE_MULT_DEVELOPING) return (1, 1000);
        if (key == K.PHASE_MULT_ESTABLISHED) return (1, 1000);
        // A zero share would shut every line; the whole of what a community can lend is the most.
        if (key == K.CONCENTRATION_BPS) return (1, 10_000);
        if (key == K.PHASE_MIN_TIME_PROVEN_ONCE) return (0, 730 days);
        if (key == K.PHASE_MIN_TIME_ESTABLISHED) return (0, 730 days);
        // Above zero, so the pool always keeps some cash for draws; at most all of it.
        if (key == K.POOL_LIQUID_FLOOR_BPS) return (1, 10_000);
        // Every dormancy window is at least a day, so no change can make a community fade, heal or
        // lose its balance at once, and at most two years.
        if (key == K.COMMUNITY_DORMANCY_GRACE) return (1 days, 730 days);
        if (key == K.COMMUNITY_FADE_LENGTH) return (1 days, 730 days);
        if (key == K.COMMUNITY_HEAL_LENGTH) return (1 days, 730 days);
        if (key == K.COMMUNITY_RETURN_AFTER) return (1 days, 730 days);
        // Above zero, or one late dollar would stop every draw; at most the whole book.
        if (key == K.PORTFOLIO_QUALITY_BPS) return (1, 10_000);
        // At least 2, so no one-person community can lend to itself; at most the member cap's floor.
        if (key == K.COMMUNITY_MIN_MEMBERS) return (2, 10);
        // At least a day, so repaying cannot clear a default in the same breath; at most two years.
        if (key == K.DEFAULT_HEAL_COOLING) return (1 days, 730 days);
        // At least one seat, or nobody could join anything. The ceiling of 50 is room for a later,
        // cheaper default walk, not a proven bound: today's walk is measured only at the launch value.
        if (key == K.MAX_SEATS_PER_WALLET) return (1, 50);
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

    function hostVote() external view returns (uint16 thresholdBps, uint64 window) {
        return (uint16(values[K.HOST_VOTE_THRESHOLD_BPS]), uint64(values[K.HOST_VOTE_WINDOW]));
    }

    /// Threshold and window for the community vote types (card-price approval, member removal,
    /// host election, and the handover's objection period). Simple-majority default; the host
    /// removal vote keeps its own higher two-thirds threshold in hostVote().
    function communityVote() external view returns (uint16 thresholdBps, uint64 window) {
        return (uint16(values[K.COMMUNITY_VOTE_THRESHOLD_BPS]), uint64(values[K.COMMUNITY_VOTE_WINDOW]));
    }

    /// Who a shared vault payout counts: at least `minDeposit` into the vault, with a first deposit at
    /// least `seasoning` before the request.
    function qualifyingContributor() external view returns (uint256 minDeposit, uint64 seasoning) {
        return (values[K.QUALIFYING_CONTRIBUTOR_MIN_DEPOSIT], uint64(values[K.QUALIFYING_CONTRIBUTOR_SEASONING]));
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

    /// The most vaults one member's list in one community may hold.
    function maxVaultsPerMember() external view returns (uint256) {
        return values[K.MAX_VAULTS_PER_MEMBER];
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

    // ---- Standing ----

    function minLendable() external view returns (uint256) {
        return values[K.MIN_LENDABLE];
    }

    function globalMemberCap() external view returns (uint256) {
        return values[K.GLOBAL_MEMBER_CAP];
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

    /// Per phase: the multiplier on impact in hundredths, the line cap, and the time since the
    /// first repaid advance the phase needs. `phase` is the `ICreditCore.Phase` value (0 to 3).
    /// First Access and Developing need no time.
    function phaseTerms(uint8 phase) external view returns (uint256 multiplierX100, uint256 cap, uint64 minTime) {
        if (phase == 0) return (values[K.PHASE_MULT_FIRST_ACCESS], values[K.PHASE_CAP_FIRST_ACCESS], 0);
        if (phase == 1) {
            return (
                values[K.PHASE_MULT_PROVEN_ONCE],
                values[K.PHASE_CAP_PROVEN_ONCE],
                uint64(values[K.PHASE_MIN_TIME_PROVEN_ONCE])
            );
        }
        if (phase == 2) return (values[K.PHASE_MULT_DEVELOPING], values[K.PHASE_CAP_DEVELOPING], 0);
        return (
            values[K.PHASE_MULT_ESTABLISHED],
            values[K.PHASE_CAP_ESTABLISHED],
            uint64(values[K.PHASE_MIN_TIME_ESTABLISHED])
        );
    }

    function concentrationBps() external view returns (uint16) {
        return uint16(values[K.CONCENTRATION_BPS]);
    }

    function defaultHealCooling() external view returns (uint64) {
        return uint64(values[K.DEFAULT_HEAL_COOLING]);
    }

    // ---- the pool ----

    function creditCore() external view returns (address) {
        return address(uint160(values[K.CREDIT_CORE]));
    }

    function pauseGuard() external view returns (address) {
        return address(uint160(values[K.PAUSE_GUARD]));
    }

    function poolLiquidFloorBps() external view returns (uint16) {
        return uint16(values[K.POOL_LIQUID_FLOOR_BPS]);
    }

    /// The four community dormancy windows, in seconds.
    function communityDormancy()
        external
        view
        returns (uint64 grace, uint64 fadeLength, uint64 healLength, uint64 returnAfter)
    {
        return (
            uint64(values[K.COMMUNITY_DORMANCY_GRACE]),
            uint64(values[K.COMMUNITY_FADE_LENGTH]),
            uint64(values[K.COMMUNITY_HEAL_LENGTH]),
            uint64(values[K.COMMUNITY_RETURN_AFTER])
        );
    }

    function portfolioQualityBps() external view returns (uint16) {
        return uint16(values[K.PORTFOLIO_QUALITY_BPS]);
    }

    function communityMinMembers() external view returns (uint256) {
        return values[K.COMMUNITY_MIN_MEMBERS];
    }

    function maxSeatsPerWallet() external view returns (uint256) {
        return values[K.MAX_SEATS_PER_WALLET];
    }

    function creditAgreementHash() external view returns (bytes32) {
        return bytes32(values[K.CREDIT_AGREEMENT_HASH]);
    }
}
