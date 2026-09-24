// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

/// Read and event surface of the singleton `CreditCore`, Treasury half.
///
/// The Treasury holds Qudi-owned credit capital only: no member savings, no public
/// deposits, no share or redemption token. A Community Credit Account is a restricted internal
/// accounting allocation keyed by community id, not a balance a community owns.
interface ICreditCore {
    /// Where a top-up of a community's credit balance came from. A community has
    /// one balance, `allocationOf[communityId]`, and every avenue tops up the same number, so
    /// provenance is this event field and not a second mapping.
    ///
    /// `Growth` and `Stabilization` are the Allocation Multisig's two purposes: reward
    /// sustained activity, or restore health after a loss. Both create zero Impact Units and no
    /// member-attributable value. The other three are the `receiveCommunityLeg` avenues:
    /// `SeatMint` is the seat fee's 40% community share, `Yield` is the vault yield's 15% pool
    /// leg, and `Campaign` is campaign proceeds, for when campaigns exist.
    ///
    /// Appended, never reordered: the indexer reads these ordinals off the log.
    enum AllocationType {
        Growth,
        Stabilization,
        SeatMint,
        Yield,
        Campaign
    }

    /// Member phases, ordered by completed obligations. Phase is never reduced by a
    /// scar: it drives the concentration and phase caps, which are the community's, not
    /// the member's.
    enum Phase {
        FirstAccess, // 0 completed obligations
        ProvenOnce, // 1 completed, plus PHASE_MIN_TIME_PROVEN_ONCE
        Developing, // 2 to 5 completed
        Established // 6 or more completed, plus PHASE_MIN_TIME_ESTABLISHED
    }

    /// Impact source. Only realized, irreversible Community Credit Account additions
    /// attributable to a member qualify: the seat-fee Community portion and the
    /// member's seasoned realized Vault yield spread. Every other kind of addition
    /// (vault principal, temporary balances, internal transfers, shareout and campaign
    /// rewards, Qudi allocations, community-level funding yield, unrealized yield, principal
    /// repayments, reversed events) has no path to `accrueImpact` at all.
    enum ImpactSource {
        SeatFeeCommunityPortion,
        VaultYieldSpread
    }

    /// Canonical stages, in order. Half-open intervals off the obligation's own
    /// `drawTimestamp`: the boundary instant belongs to the later stage. Price is 0% at every
    /// stage; the stages survive as conduct and enforcement gates only.
    enum Stage {
        Tenor,
        Grace,
        Late,
        FinalCure,
        DefaultRecovery,
        WrittenOff
    }

    /// A read of one account's obligation. One open tab per account, across every
    /// community: `drawTimestamp == 0` means no tab has ever been
    /// drawn. `stage` is the CURRENT derived stage (live, not the last-materialized value).
    /// `payoff` is what settling the tab in full costs right now; it equals `principal` under
    /// the global 0% price, kept as its own field so a price change never reshapes this
    /// struct. `graceAt` through `writeOffAt` are the obligation's own milestone timestamps
    /// (`drawTimestamp` plus each stage boundary offset), zero for an account with no tab; the
    /// countdown to whichever is next is client-side arithmetic against the current time, not
    /// a fifth on-chain read.
    struct ObligationView {
        uint256 principal;
        uint256 originalPrincipal;
        uint256 payoff;
        uint64 drawTimestamp;
        uint256 communityId;
        uint256 teDrawn;
        Stage stage;
        bool writtenOff;
        bool closed;
        uint64 graceAt;
        uint64 lateAt;
        uint64 finalCureAt;
        uint64 defaultRecoveryAt;
        uint64 writeOffAt;
    }

    /// A member's standing in one community: the Line and every
    /// CreditCore-native gate `draw` checks, named separately so the "why not?" drawer can
    /// point at the one that binds instead of the caller re-deriving eligibility from several
    /// round trips. `communityHasCapacity` is whether the community's own budget could support
    /// at least the protocol minimum draw, independent of this member's share of it.
    ///
    /// Membership, the draw-block flag, and seat seasoning are NOT CreditCore state: they
    /// live on `ICommunity.isMember`/`isSeasoned`/`mintedAt` and
    /// `IComplianceRegistry.isBlocked`, which `draw` already reads directly and which already
    /// answer in one call each. Folding them in here would duplicate another contract's ABI
    /// surface inside CreditCore's bytecode to save the drawer a second and third call it can
    /// make just as cheaply; the "why not" drawer composes those two calls itself.
    ///
    /// Phase, raw Impact Units, and pending (unseasoned) Impact are not the eligibility screen's concern
    /// (they belong to the profile/history surface a later phase builds) and are left out so
    /// this struct stays exactly what the eligibility line and its drawer need.
    ///
    /// `hasOpenTab` is not repeated here: the eligibility screen already calls `obligationOf` to render the
    /// active advance strip, and an open tab is exactly `obligationOf(member).drawTimestamp !=
    /// 0 && !closed && !writtenOff`. `preDefaultDisqualified` is not repeated either:
    /// `accountDefaulted` alone already answers "is the account permanently blocked", and
    /// `_line` treats the two identically, so the drawer needs no separate flag to decide
    /// account-wide ineligibility (the per-community historical flag stays in
    /// `WriteOffFinalized`/`PreDefaultUnitsDisqualified` event history for anyone who needs it).
    struct MemberStanding {
        uint256 drawable;
        bool eligible;
        bool agreementAccepted;
        bool communityHasCapacity;
        bool accountDefaulted;
    }

    /// One community's credit account (budget, allocation, Trust Extension budget, capacity).
    /// `impactTotal` (U_C, historical, never falls), `openObligationCount`, and
    /// `attributedYield` (cumulative) are left out: each is either a running total the
    /// indexer already reconstructs from `ImpactSeasoned`/`ObligationCompleted`/
    /// `CommunityAttributedYieldCredited` events, or a host-dashboard breakdown outside this
    /// task's screens, not a live figure `communityHasCapacity` or the Line depend on.
    struct CommunityCredit {
        uint256 allocation;
        bool closed;
        uint256 outstandingPrincipal;
        uint256 impactBudget;
        uint256 teLive;
        uint256 teBudget;
    }

    /// The Treasury: the retained-capital requirement, surplus, and the stage-outstanding
    /// book that formula is computed from. The venue figures (`largestVenueExposure`, `totalVenueExposure`,
    /// `venueAllocationCap`, `perVenueCap`) are Treasury Manager rebalancing telemetry, not a
    /// member-facing concern, so they are left out of the web/indexer surface; `_venues`/venue-loop reads stay available to ops tooling
    /// directly against chain state.
    /// `unallocated` is not its own field: it is `cash - totalAllocated`, both already here.
    struct TreasuryView {
        uint256 cash;
        uint256 totalAllocated;
        int256 surplus;
        uint256 requiredRetainedCapital;
        uint256 current;
        uint256 late;
        uint256 finalCure;
        uint256 defaultRecovery;
    }

    function treasuryManager() external view returns (address);
    function allocationMultisig() external view returns (address);
    /// The `_bookedCash` ledger, for the invariant campaign's cash-conservation check: it
    /// must always equal `usdc.balanceOf(address(this))`. A test/invariant seam, not part of
    /// the web or indexer surface, so it is not folded into `TreasuryView`.
    function expectedCash() external view returns (uint256);
    /// The retained-capital requirement and surplus, the venue summary, and the
    /// stage-outstanding book, bundled in one call.
    function treasuryView() external view returns (TreasuryView memory);
    /// One community's allocation, budget, Trust Extension budget, and capacity, bundled in
    /// one call.
    function communityCreditOf(uint256 communityId) external view returns (CommunityCredit memory);
    /// A member's Line and every gate `draw` checks for `communityId`, bundled in one call.
    function standingOf(uint256 communityId, address member) external view returns (MemberStanding memory);

    event Funded(address indexed from, uint256 amount);
    event AllocationAssigned(
        uint256 indexed communityId,
        AllocationType kind,
        uint256 amount,
        address indexed approver,
        uint256 treasuryUnallocatedAfter,
        uint256 communityBalanceAfter
    );
    event CommunityClosed(uint256 indexed communityId, uint256 returnedToTreasury);
    event VenueAdded(address indexed venue);
    event VenueRemoved(address indexed venue);
    event VenueDeposit(address indexed venue, uint256 assets);
    event VenueWithdraw(address indexed venue, uint256 shares, uint256 assets);
    event TreasuryManagerSet(address indexed previous, address indexed current);
    event AllocationMultisigSet(address indexed previous, address indexed current);

    // ---- Standing lives on `ICreditStanding` ----

    error ZeroAmount();
    error ZeroAddress();
    error NotAllocationMultisig();
    error NotTreasuryManager();
    error UnknownCommunity();
    error CommunityIsClosed();
    error AlreadyClosed();
    error CommunityHasDebt();
    /// `receiveCommunityLeg`: the caller is not a contract `CommunityFactory` created for a
    /// community, so it has no community to top up.
    error NotCommunityContract();
    /// `receiveCommunityLeg`: the caller is a registered community contract, but of a different
    /// community than the one it named. The callee decides, never the caller.
    error CommunityMismatch();
    /// `receiveCommunityLeg`: the USDC has not arrived. A leg books cash it was handed; a leg
    /// that books more than the balance covers would break `expectedCash()`.
    error LegNotFunded();
    error BelowRetainedCapital();
    error DuplicateVenue();
    error UnknownVenue();
    error VenueAssetMismatch();
    error VenueHoldsBalance();
    /// The deposit would push total venue exposure past
    /// `VENUE_ALLOCATION_MAX_BPS` of liquid capital above the operating buffer.
    error VenueAllocationCapExceeded();
    /// `addVenue` is called by anything other than the Risk Committee (the owner of
    /// `Config`, a 48-hour `TimelockController`).
    error NotRiskCommittee();
    /// The venue does not implement `IStrategyDelay.redeemDelay()`, so its redemption
    /// delay cannot be read and it cannot be listed.
    error VenueRedeemDelayUnknown();
    /// The venue's redemption delay exceeds `MAX_VENUE_REDEMPTION_DELAY`.
    error VenueRedeemDelayTooLong();
    /// The deposit would push this one venue's exposure past `PER_VENUE_CAP_BPS` of
    /// total Treasury cash.
    error PerVenueCapExceeded();
    /// The venue's realised amount fell below its ERC-4626 preview by more than
    /// `MAX_VENUE_SLIPPAGE_BPS`.
    error VenueSlippageExceeded();

    // ---- the debt half: draw, settle, the stage machine, write-off ----

    /// A draw landed. `agreementHash` is non-zero only on the account's first-ever draw:
    /// a later draw that needs no fresh acceptance records `bytes32(0)` here.
    event Drawn(
        uint256 indexed communityId,
        address indexed member,
        uint256 principal,
        uint256 teDrawn,
        uint64 drawTimestamp,
        bytes32 agreementHash
    );
    /// A settlement landed. `principalRetired` is what came off the debt; `refund` is the
    /// overpayment returned to the unit; `remainingPrincipal` and `closed`
    /// describe the tab after the payment.
    event Settled(
        uint256 indexed communityId,
        address indexed member,
        uint256 principalRetired,
        uint256 refund,
        uint256 remainingPrincipal,
        bool closed
    );
    /// The deterministic write-off materialized, exactly once per obligation.
    /// `allocationBefore`/`allocationAfter` are the community's allocation immediately around
    /// the loss the waterfall's first step absorbed.
    event WriteOffFinalized(
        uint256 indexed communityId,
        address indexed member,
        uint256 principalWrittenOff,
        uint256 allocationBefore,
        uint256 allocationAfter
    );
    /// Formal Default's permanent consequences recorded account-wide. Fired once, the
    /// first time any obligation on this account crosses into Default Recovery.
    event AccountDefaulted(address indexed member);
    /// A cure's scar could not be recorded because the community's scar
    /// list was still at `_QUEUE_MAX` after pruning every fully-healed entry. No scar was
    /// recorded and `te_earned` was not zeroed; the settle that triggered this still completed.
    event ScarDropped(uint256 indexed communityId, address indexed member, uint256 attemptedConductWad);

    /// `draw` by a wallet that is not a member: no seat, a Suspended or Left one, or one a
    /// removal vote is open against.
    error NotAMember();
    error AccountBlocked();
    error NotSeasoned();
    error TabAlreadyOpen();
    error NotEligible();
    error ExceedsLine();
    /// A first-ever draw for the account with no Credit Agreement hash supplied.
    error CreditAgreementRequired();
    /// The community's aggregate live Trust Extension would exceed
    /// `min(sum of phase budgets, TE_COMMUNITY_CAP_BPS x cumulative attributed funding yield)`.
    error CommunityTeCapExceeded();
    error NoOpenTab();
    error NotYetWrittenOff();
    error AlreadyWrittenOff();

    /// Draw against `communityId` for `amount`, accepting `agreementHash` as the Credit
    /// Agreement hash on the account's first-ever draw (any value on a later draw, ignored).
    function draw(uint256 communityId, uint256 amount, bytes32 agreementHash) external;
    /// Repay the caller's own open tab one-to-one against principal. Never pausable.
    function settle(uint256 amount) external;
    /// Permissionless: materializes the deterministic write-off for `member` if their
    /// obligation has reached the write-off boundary and has not been materialized yet.
    function finalizeWriteOff(address member) external;
    /// Permissionless: records the stage `member`'s obligation has
    /// already reached by its timestamp, and moves its reserve bucket with it. A no-op for
    /// an account with no open obligation, or one whose recorded stage is already current.
    function materialize(address member) external;
    function obligationOf(address member) external view returns (ObligationView memory);
    function hasOpenTab(address member) external view returns (bool);

    /// The second door onto a community's one credit balance. A contract
    /// `CommunityFactory` created for `communityId` transfers the USDC in and then calls this to
    /// book it, which is the shape the retired `receiveMintShare` had. The caller must be
    /// registered (`NotCommunityContract`), must be registered to `communityId` and not another
    /// (`CommunityMismatch`), and the USDC must already have arrived (`LegNotFunded`).
    ///
    /// Not gated on the retained-capital requirement, and that is deliberate: the gate
    /// belongs on paths that reduce unallocated Treasury cash, and a leg raises cash and
    /// allocation by the same amount, so unallocated cash does not move. `test/CreditCoreCommunityLeg.t.sol`
    /// proves that rather than asserting it.
    ///
    /// The kind is **derived** from the caller, never supplied: the seats clone pays the mint
    /// leg and a ledger pays the yield leg. `AllocationAssigned` is where provenance lives now
    /// that there is one balance, and `Growth` and `Stabilization` are unreachable here by
    /// construction.
    function receiveCommunityLeg(uint256 communityId, uint256 amount) external;
}
