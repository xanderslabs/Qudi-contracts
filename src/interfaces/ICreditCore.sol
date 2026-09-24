// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

/// The credit pool and its ledger.
///
/// A community's credit account is a record here: its paper balance (`allocation`), what it has
/// lent (`outstanding`) and what it has written off. A community lends only from its own balance,
/// and a default's loss comes out of that community alone. The USDC behind every unlent paper
/// dollar sits here as cash or in a pool strategy listed through the timelock. What is left over is
/// Qudi's unallocated money, and only that can leave through `withdrawTreasury`.
///
/// Members, hosts and communities have no ownership, redemption or withdrawal right over a balance.
/// It changes by a grant (`allocate`), by a community leg (`receiveCommunityLeg`), by a write-off
/// and a repayment after it, and by closure or dormancy returning it to Qudi.
interface ICreditCore {
    /// Where a top-up of a community's balance came from. One balance, provenance in the event.
    /// `Growth` and `Stabilization` are Qudi's grants. `SeatMint` is the seat fee's 40% community
    /// share, `Yield` is the vault yield's 15% credit share, and `Campaign` is campaign proceeds,
    /// for when campaigns exist.
    ///
    /// Appended, never reordered: the indexer reads these ordinals off the log.
    enum AllocationType {
        Growth,
        Stabilization,
        SeatMint,
        Yield,
        Campaign
    }

    /// Member phases, from repaid advances counted across every community.
    enum Phase {
        FirstAccess, // none repaid
        ProvenOnce, // 1 repaid, and PHASE_MIN_TIME_PROVEN_ONCE since the first
        Developing, // 2 to 5 repaid
        Established // 6 or more repaid, and PHASE_MIN_TIME_ESTABLISHED since the first
    }

    /// An advance's stages, in order, from its own draw timestamp. The boundary instant belongs to
    /// the later stage. The price is 0% at every stage; the stages are conduct and enforcement
    /// gates only.
    enum Stage {
        Tenor,
        Grace,
        Late,
        FinalCure,
        DefaultRecovery,
        WrittenOff
    }

    /// One account's advance. `drawTimestamp == 0` means the account never drew. `stage` is the
    /// live stage. `payoff` is what settling in full costs now, which is the principal at 0%. A
    /// written-off advance keeps its unpaid principal: it can still be repaid. `closed` is true once
    /// it is repaid in full. The milestone timestamps are zero for an account with no advance.
    struct ObligationView {
        uint256 principal;
        uint256 originalPrincipal;
        uint256 payoff;
        uint64 drawTimestamp;
        uint256 communityId;
        Stage stage;
        bool writtenOff;
        bool closed;
        uint64 graceAt;
        uint64 lateAt;
        uint64 finalCureAt;
        uint64 defaultRecoveryAt;
        uint64 writeOffAt;
    }

    /// A member's line in one community and the flags the "why not?" drawer names. Membership,
    /// seasoning and the screener block live on `Community` and `ComplianceRegistry`.
    struct MemberStanding {
        uint256 drawable;
        bool eligible;
        bool agreementAccepted;
        bool accountDefaulted;
    }

    /// One community's record. `lendable` is what it can lend now: its unlent balance times the
    /// dormancy share, `lendableShareWad` (1e18 is all of it).
    struct CommunityCredit {
        uint256 allocation;
        uint256 outstanding;
        uint256 writtenOff;
        uint256 lendable;
        uint256 lendableShareWad;
        uint64 lastActivityAt;
        bool closed;
    }

    /// The pool. `unallocated` is Qudi's own money: cash plus strategies plus what is out on loan,
    /// less every paper balance.
    struct PoolView {
        uint256 cash;
        uint256 strategyValue;
        uint256 totalAllocated;
        uint256 totalOutstanding;
        uint256 unallocated;
    }

    function operator() external view returns (address);
    function allocationMultisig() external view returns (address);
    /// The booked-cash ledger. It must always equal `usdc.balanceOf(address(this))`.
    function expectedCash() external view returns (uint256);
    function poolView() external view returns (PoolView memory);
    function strategies() external view returns (address[] memory);
    function communityCreditOf(uint256 communityId) external view returns (CommunityCredit memory);
    function standingOf(uint256 communityId, address member) external view returns (MemberStanding memory);

    // ---- the pool ----

    /// Qudi puts its own money in. Owner only; no member path can.
    function fund(uint256 amount) external;
    /// A grant from Qudi's unallocated money to a community's balance. Allocation multisig only.
    function allocate(uint256 communityId, uint256 amount, AllocationType kind) external;
    /// A community's own contract has transferred `amount` in and books it: the seat leg from its
    /// `Community`, the yield leg from its `Ledger`.
    function receiveCommunityLeg(uint256 communityId, uint256 amount) external;
    /// A deposit by `member` in the community's `Ledger`, or their paid seat mint in its
    /// `Community`. Only those two contracts may call it.
    function noteActivity(uint256 communityId, address member) external;
    /// Owner only, once nothing is out in the community. Returns its balance to Qudi.
    function closeCommunity(uint256 communityId) external;
    /// Anyone, once the community has been fully faded for the return period and nothing is out.
    function sweepDormant(uint256 communityId) external;
    /// Adds pool strategies. The pool holds community balances, so listing somewhere new it may
    /// invest is a path to member money: the role is apart from the owner and held by the slower
    /// timelock. It starts as the owner.
    function strategyLister() external view returns (address);
    /// Lister only. The owner can neither take the role nor give it away.
    function setStrategyLister(address next) external;
    function addStrategy(address strategy) external; // lister only
    function removeStrategy(address strategy) external; // owner only
    function depositToStrategy(address strategy, uint256 amount) external;
    function withdrawFromStrategy(address strategy, uint256 amount) external;
    /// Owner only. Takes Qudi's unallocated money out.
    function withdrawTreasury(address to, uint256 amount) external;

    // ---- the advance ----

    /// Draw `amount` in `communityId`. `agreementHash` must be the current Credit Agreement's hash
    /// on the account's first draw, and is ignored after.
    function draw(uint256 communityId, uint256 amount, bytes32 agreementHash) external;
    /// Repay the caller's own advance, one to one against principal. Anything over is refunded.
    /// Always open, before and after write-off.
    function settle(uint256 amount) external;
    /// Anyone: records the stage the member's advance has reached by its timestamp.
    function materialize(address member) external;
    /// Anyone, from the write-off boundary: writes the advance off.
    function finalizeWriteOff(address member) external;
    function obligationOf(address member) external view returns (ObligationView memory);
    /// An advance is drawn, not repaid, and not written off.
    function hasOpenTab(address member) external view returns (bool);

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
    event DormantSwept(uint256 indexed communityId, uint256 returnedToTreasury);
    event StrategyListerSet(address indexed previous, address indexed next);
    event StrategyAdded(address indexed strategy);
    event StrategyRemoved(address indexed strategy);
    event StrategyDeposit(address indexed strategy, uint256 amount);
    event StrategyWithdraw(address indexed strategy, uint256 amount);
    event TreasuryWithdrawn(address indexed to, uint256 amount);
    event OperatorSet(address indexed previous, address indexed current);
    event AllocationMultisigSet(address indexed previous, address indexed current);
    /// `agreementHash` is non-zero only on the account's first draw.
    event Drawn(
        uint256 indexed communityId,
        address indexed member,
        uint256 principal,
        uint64 drawTimestamp,
        bytes32 agreementHash
    );
    /// `principalRetired` came off the debt; `refund` went back to the member. On a written-off
    /// advance the retired amount goes back to the community's balance, or to Qudi once the
    /// community's account has closed.
    event Settled(
        uint256 indexed communityId,
        address indexed member,
        uint256 principalRetired,
        uint256 refund,
        uint256 remainingPrincipal,
        bool closed
    );
    /// The loss came out of this community's balance: `allocationBefore` less the unpaid principal.
    event WriteOffFinalized(
        uint256 indexed communityId,
        address indexed member,
        uint256 principalWrittenOff,
        uint256 allocationBefore,
        uint256 allocationAfter
    );

    error ZeroAmount();
    error ZeroAddress();
    error NotAllocationMultisig();
    error NotOperator();
    error UnknownCommunity();
    error CommunityIsClosed();
    error AlreadyClosed();
    error CommunityHasDebt();
    /// `receiveCommunityLeg`: the caller is not a contract the factory created for a community.
    error NotCommunityContract();
    /// `receiveCommunityLeg`: the caller belongs to another community than the one it named.
    error CommunityMismatch();
    /// `receiveCommunityLeg`: the USDC has not arrived.
    error LegNotFunded();
    /// `noteActivity`: the caller is neither this community's `Community` nor its `Ledger`.
    error NotCommunityOwnContract();
    /// The move would leave cash plus pool strategies below the unlent paper balances.
    error Unbacked();
    /// A pool strategy deposit would leave cash below `POOL_LIQUID_FLOOR_BPS` of the unlent paper
    /// balances.
    error BelowLiquidFloor();
    /// The balance is there but the cash is out in a pool strategy. Credit is briefly unavailable.
    error PoolIlliquid();
    error DuplicateStrategy();
    error NotStrategyLister();
    error UnknownStrategy();
    error StrategyAssetMismatch();
    error StrategyHoldsBalance();
    /// `sweepDormant` before the community has been fully faded for the return period.
    error NotDormant();

    /// A wallet that is not a member: no seat, a Suspended or Left one, or a frozen one.
    error NotAMember();
    error AccountBlocked();
    error NotSeasoned();
    /// The account already has an advance that is not repaid, written off or not.
    error TabAlreadyOpen();
    /// The first draw did not carry the current Credit Agreement's hash.
    error WrongAgreement();
    /// Fewer Active seasoned seats than `COMMUNITY_MIN_MEMBERS`.
    error TooFewMembers();
    /// Late plus defaulted principal is above `PORTFOLIO_QUALITY_BPS` of what the community has out.
    error PortfolioQualityBreached();
    /// More than the community can lend now.
    error ExceedsAvailable();
    error NotEligible();
    error ExceedsLine();
    error NoOpenTab();
    error NotYetWrittenOff();
    error AlreadyWrittenOff();
}
