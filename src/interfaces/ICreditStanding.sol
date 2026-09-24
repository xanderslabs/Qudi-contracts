// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {ICreditCore} from "./ICreditCore.sol";

/// Read, write and event surface of `CreditStanding`: Impact Units,
/// conduct decay and scars, activity decay, phases, Trust Extension, and the Line.
///
/// `Phase` and `ImpactSource` are declared on `ICreditCore` rather than here (the
/// nine call sites run CreditCore -> CreditStanding; `draw`/`settle`/the composed views are
/// `ICreditCore`'s own external surface and already reference these enums, so keeping them there
/// and having `ICreditStanding` import `ICreditCore` is a one-directional dependency, not a
/// cycle. `ICreditCore` never imports `ICreditStanding`).
///
/// `CreditStanding` never calls `CreditCore`. Every place a Standing
/// calculation needs Treasury or debt-ledger state, `CreditCore` composes a snapshot from its
/// own storage and passes it as an argument here. `CommunityLedgerSnapshot` and
/// `MemberTabSnapshot` are those snapshots.
interface ICreditStanding {
    /// `CreditCore._allocationOf[communityId]` and `._outstandingPrincipalOf[communityId]`,
    /// snapshotted for `communityImpactBudget`'s liquid-cash calculation.
    struct CommunityLedgerSnapshot {
        uint256 allocation;
        uint256 outstandingPrincipal;
    }

    /// The member's obligation as `CreditCore` currently sees it, restricted to exactly the
    /// fields the delinquency/exposure seams need.
    ///
    /// `openInCommunity` and `elapsedSinceDraw` answer the per-community delinquency questions
    /// (`_openDelinquencyConduct`, `_hasOpenDelinquency` in the pre-split code): open, not
    /// closed, not written off, AND drawn against the community being asked about.
    ///
    /// `openAnywhere` and `principal` answer the account-wide exposure question
    /// (`_memberCurrentExposure` in the pre-split code always ignored `communityId`: one open
    /// tab per account, not per community), so they are computed without a community match.
    struct MemberTabSnapshot {
        bool openInCommunity;
        uint64 elapsedSinceDraw;
        bool openAnywhere;
        uint256 principal;
    }

    event ImpactAttributorSet(address indexed previous, address indexed current);
    /// `obligationLedger` becomes the `CreditCore` address after the split:
    /// this replaces `ObligationLedgerSet`. One-way; see `setCreditCore`.
    event CreditCoreSet(address indexed creditCore);
    event ImpactAccrued(
        uint256 indexed communityId,
        address indexed member,
        ICreditCore.ImpactSource source,
        bytes32 indexed sourceEventId,
        uint256 pending,
        uint256 minted
    );
    event ImpactSeasoned(uint256 indexed communityId, address indexed member, uint256 amount);
    event ScarRecorded(uint256 indexed communityId, address indexed member, uint256 frozenConductWad);
    event TrustExtensionEarned(
        uint256 indexed communityId, address indexed member, uint256 amount, uint256 totalEarned
    );
    event ObligationCompleted(uint256 indexed communityId, address indexed member, uint256 completedCount);
    /// Fired from `_recordFormalDefault`'s internal call into `_disqualifyPreDefaultUnits`. The
    /// external `disqualifyPreDefaultUnits` entry point that could otherwise fire this
    /// independently is retired.
    event PreDefaultUnitsDisqualified(uint256 indexed communityId, address indexed member);
    event CommunityAttributedYieldCredited(uint256 indexed communityId, uint256 amount, uint256 cumulative);
    event AccountDefaulted(address indexed member);
    event ScarDropped(uint256 indexed communityId, address indexed member, uint256 attemptedConductWad);

    error NotImpactAttributor();
    /// The caller is not the wired `CreditCore` address (replaces `NotObligationLedger`).
    error NotCreditCore();
    error QueueFull();
    error ScarValueOutOfRange();
    error ZeroAddress();
    error UnknownCommunity();
    /// `setCreditCore` called a second time (wiring is one-way).
    error CreditCoreAlreadySet();
    /// `setCreditCore` called with a `CreditCore` wired to a different `factory` or `config`
    /// than this `CreditStanding`.
    error CreditCoreMismatch();
    /// `setCreditCore` called with a `CreditCore` whose own `standing()` does not point back at
    /// this `CreditStanding`.
    error CreditCoreStandingMismatch();

    function setImpactAttributor(address next) external;
    /// Owner-only, and only once: wires the immutable-in-effect `CreditCore`
    /// address that `onlyCreditCore` gates against. No address is mutable after wiring.
    function setCreditCore(address creditCore_) external;

    function creditCore() external view returns (address);
    function impactAttributor() external view returns (address);

    // ---- Impact Units ----

    function accrueImpact(
        uint256 communityId,
        address member,
        uint256 attributedUsdc,
        ICreditCore.ImpactSource source,
        bytes32 sourceEventId,
        uint64 sourceTimestamp
    ) external;
    function pokeSeasoning(uint256 communityId, address member) external;
    function creditCommunityAttributedYield(uint256 communityId, uint256 amount) external;

    // ---- the nine call sites CreditCore makes into Standing ----

    /// `CommunityImpactBudget = liquid_cash - OPERATIONAL_BUFFER - MIN_LENDABLE`, floored at
    /// zero. `snap` is CreditCore's community-allocation/outstanding-principal pair:
    /// Standing never reads `CreditCore` storage itself.
    function communityImpactBudget(uint256 communityId, CommunityLedgerSnapshot calldata snap)
        external
        view
        returns (uint256);
    /// Cumulative attributed funding yield for the community. A plain getter: CreditCore's
    /// own `_communityTeBudget` reads this directly rather than Standing recomputing that
    /// formula for a caller outside itself.
    function communityAttributedYield(uint256 communityId) external view returns (uint256);
    /// Reverts `UnknownCommunity` unless `communityId < ICommunityFactory(factory).communityCount()`.
    /// Exposed so CreditCore's debt half and Standing's own external entry points share the
    /// exact same check and error selector rather than drifting apart after the split.
    function requireCommunity(uint256 communityId) external view;
    /// The Line: `(drawable, eligible)`. `communitySnap`/`tabSnap` are the
    /// snapshots the four reverse seams (`_communityLiquidCash`,
    /// `_openDelinquencyConduct`, `_hasOpenDelinquency`, `_memberCurrentExposure`) used to read
    /// directly out of `CreditCore` storage.
    function line(
        uint256 communityId,
        address member,
        CommunityLedgerSnapshot calldata communitySnap,
        MemberTabSnapshot calldata tabSnap
    ) external view returns (uint256 drawable, bool eligible);
    /// `ImpactBase_i = CommunityImpactBudget x share_i x activity_factor x conduct_factor`
    /// with snapshots as `line` above.
    function impactBase(
        uint256 communityId,
        address member,
        CommunityLedgerSnapshot calldata communitySnap,
        MemberTabSnapshot calldata tabSnap
    ) external view returns (uint256);

    /// `recordScar`/`creditObligationCompletion`/`recordFormalDefault`: role-gated to
    /// `onlyCreditCore`. `settle` and `finalizeWriteOff` are the entry points to
    /// be careful about: they must call these AFTER mutating
    /// `_tab`/`_stageBucket`/`_outstandingPrincipalOf` for the same obligation, so the conduct
    /// value handed to `recordScar` and the exposure a subsequent read sees are already
    /// post-mutation. `disqualifyPreDefaultUnits` is retired
    /// as an external entry point: `CreditCore` never called it, so it was
    /// operator-callable dead capability with no appeal path. Formal Default still reaches the
    /// internal `_disqualifyPreDefaultUnits` through `recordFormalDefault`, unchanged.
    function recordScar(uint256 communityId, address member, uint256 frozenConductWad) external;
    function creditObligationCompletion(uint256 communityId, address member, uint256 teEarnIncrement) external;
    /// Formal Default's permanent, account-wide consequences. Idempotent.
    function recordFormalDefault(uint256 communityId, address member) external;

    /// Conduct decay at `elapsed` seconds past draw. A pure read of `config`, so it needs
    /// no role gate; grouped with the "writes" because its only caller,
    /// `CreditCore._closeTab`, uses it to compute the value passed into `recordScar` immediately
    /// after.
    function conductDecayAt(uint256 elapsed) external view returns (uint256);

    // ---- reads used by the composed public views CreditCore hosts ----

    /// The account-wide conduct floor and Line disqualification `standingOf` (hosted on
    /// `CreditCore`) reports.
    function isAccountDefaulted(address member) external view returns (bool);
}
