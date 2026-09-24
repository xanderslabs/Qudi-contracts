// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

/// One community's book. Every vault, every tier, one contract,
/// one clone per community.
///
/// A vault is a record, not a contract: `VaultParams` opens one, and many records may sit in the
/// same tier. The ledger holds one position per tier in that tier's shared `Venue` and
/// divides it between the records, so `tierUnits[t]` is both the sum of the tier's active
/// `vaultUnits` and the ledger's own unit balance in `tierVault(t)`.
///
/// There is no per-member unit accounting, and no per-member unit balance to read (the
/// getter that used to answer one is gone, not renamed). A shared vault
/// belongs to the community and a member who leaves forfeits what they left in one; a personal
/// vault belongs to exactly one owner. Per-member contribution history is served from events by
/// the indexer, which is where display data belongs.
interface ILedger {
    /// What a member states when they open a record. `poolType` is the tier (PoolTypes.sol) and
    /// must already be open; `shared` picks host-created community-wide over personal;
    /// `lockedUntil` is 0 for an open vault and otherwise the timestamp before which withdrawals
    /// revert; `contribution`, `name`, `target` and `targetDate` are the member's stated intent
    /// and the ledger stores them without reading them.
    struct VaultParams {
        uint8 poolType;
        bool shared;
        uint64 lockedUntil;
        uint8 contribution;
        string name;
        uint256 target;
        uint64 targetDate;
    }

    // ---- tiers ----

    /// Qudi's `Venue` for this tier. Every tier Qudi has deployed is available to every
    /// community and there is nothing to open: the host picks the tier when creating
    /// a shared vault and the member picks it for their own. Reverts `UnknownPoolType` above
    /// `PoolTypes.COUNT`.
    function tierVault(uint8 poolType) external view returns (address);

    // ---- the record ----

    function createVault(VaultParams calldata p) external returns (uint256 vaultId);
    function vaults(uint256 vaultId)
        external
        view
        returns (
            uint8 poolType,
            bool shared,
            address owner,
            uint64 lockedUntil,
            uint8 contribution,
            uint8 status,
            string memory name,
            uint256 target,
            uint64 targetDate
        );
    function vaultCount() external view returns (uint256);
    /// The record's units in its tier. `tierUnits(t)` is the sum of these over the tier's active
    /// records, and also the ledger's own unit balance in `tierVault(t)`.
    function vaultUnits(uint256 vaultId) external view returns (uint256);
    function tierUnits(uint8 poolType) external view returns (uint256);
    /// The record's USDC value now, frozen units included: they are still the vault's money
    /// until the request executes.
    function vaultBalance(uint256 vaultId) external view returns (uint256);
    /// Units no live proposal has reserved, and the ceiling a new proposal is measured against.
    /// Equal to `vaultUnits` on a personal vault, which has no proposals.
    function availableUnits(uint256 vaultId) external view returns (uint256);
    /// What those free units are worth now. A display figure; `availableUnits` is the bound.
    function availableBalance(uint256 vaultId) external view returns (uint256);
    function vaultPrincipal(uint256 vaultId) external view returns (uint256);
    function vaultEarned(uint256 vaultId) external view returns (uint256);
    /// Units this member holds across their own personal records, frozen units included. The
    /// number `Community.forfeit()` reads: a member cannot leave holding anything they have a
    /// claim on.
    function personalUnitsOf(address member) external view returns (uint256);
    function closeVault(uint256 vaultId) external;

    // ---- money ----

    function deposit(uint256 vaultId, uint256 amount) external;
    /// Flex only, personal only, and only past the record's own `lockedUntil`.
    function withdrawInstant(uint256 vaultId, uint256 amount) external;
    function requestWithdraw(uint256 vaultId, uint256 amount) external returns (uint256 requestId);
    function executeWithdraw(uint256 requestId) external;
    function cancelWithdraw(uint256 requestId) external;
    function requests(uint256 requestId)
        external
        view
        returns (uint256 vaultId, address receiver, uint256 units, uint64 requestedAt);
    function lastWithdrawalAt(address member) external view returns (uint64);
    /// Anyone; forwards this tier's accrued credit leg to `CreditCore` against this community.
    function claimPoolLeg(uint8 poolType) external returns (uint256 assets);

    // ---- the shared withdrawal ----

    /// A qualifying contributor as of now: enough deposited
    /// into this shared vault, long enough ago, by the two bars `Config` holds. The vote
    /// path asks the same question as of the proposal's creation time instead.
    function isDepositor(uint256 vaultId, address member) external view returns (bool);
    /// Everyone who has crossed the amount bar in this shared vault, seasoned or not.
    function depositorCount(uint256 vaultId) external view returns (uint256);
    /// Units live proposals have reserved on this vault. **Units, not dollars**:
    /// the claim is fixed when the proposal is made, so no price move can outrun it and execution
    /// has nothing to clamp.
    function earmarkedUnits(uint256 vaultId) external view returns (uint256);
    /// Host only. Names a fixed recipient and a fixed amount in USDC, converts it to units once
    /// at the price the voters are shown, and reserves those units so they cannot be spent twice
    /// or withdrawn out from under a live proposal.
    function proposeWithdrawal(uint256 vaultId, address recipient, uint256 amount) external returns (uint256 proposalId);
    /// Depositors of that vault at proposal time. One depositor one vote; never weighted by
    /// balance, because there are no per-member balances to weight by.
    function voteOnWithdrawal(uint256 proposalId, bool support) external;
    /// Anyone in the community, once the window has closed and the vote passed. Mechanical: no
    /// parameter can be changed, and there is no timelock between passing and executing.
    function executeWithdrawal(uint256 proposalId) external;
    /// Anyone in the community. A proposal that did not pass is revertible as soon as its window
    /// closes; one that passed becomes revertible after `sharedProposalRevertDelay`. Nothing
    /// expires: the earmark is always freed by someone acting.
    function revertWithdrawal(uint256 proposalId) external;
    function proposals(uint256 proposalId)
        external
        view
        returns (
            uint256 vaultId,
            address recipient,
            uint256 units,
            uint256 amountAtProposal,
            uint64 deadline,
            uint32 forVotes,
            uint32 againstVotes,
            uint256 depositorsAtProposal,
            uint8 status
        );
    function hasVoted(uint256 proposalId, address member) external view returns (bool);

    // ---- closure ----

    function communityClosed() external view returns (bool);
    /// Host only, terminal. Refuses while any shared vault holds a balance; personal balances do
    /// not block it, and their owners withdraw afterwards.
    function closeCommunity() external;

    // ---- events ----
    //
    // The indexer's whole surface. Deleting the epoch block means per-member contribution
    // history and time-weighted balance come from here: `Deposited` and `Withdrawn` carry the
    // member, the amount, the units and the record's unit total after the move, so integrating
    // units against block time reproduces balance-time per vault, and summing a member's own
    // `Deposited` amounts reproduces their contribution history. Per-member balance-time inside a
    // shared vault is not reconstructible from any event, and that is by design rather than an
    // omission: a shared vault has no per-member units for it to be a share of.

    /// The first time this community touches a tier and caches Qudi's vault for it. Not an
    /// opening: every tier was available all along.
    event TierWired(uint8 indexed poolType, address tierVault);
    event VaultCreated(
        uint256 indexed vaultId,
        uint8 indexed poolType,
        address indexed owner,
        bool shared,
        uint64 lockedUntil,
        uint8 contribution,
        string name,
        uint256 target,
        uint64 targetDate
    );
    event Deposited(
        uint256 indexed vaultId, address indexed member, uint256 amount, uint256 units, uint256 vaultUnitsAfter
    );
    event Withdrawn(
        uint256 indexed vaultId, address indexed receiver, uint256 amount, uint256 units, uint256 vaultUnitsAfter
    );
    event WithdrawRequested(
        uint256 indexed requestId, uint256 indexed vaultId, address indexed receiver, uint256 units
    );
    event WithdrawExecuted(uint256 indexed requestId, uint256 indexed vaultId, uint256 amount);
    /// An execution the tier vault could not pay instantly: the units went to its FIFO redeem
    /// queue and the receiver is paid from there. A separate event, because nobody has been paid
    /// yet.
    event WithdrawQueued(uint256 indexed requestId, uint256 indexed vaultId, uint256 units, uint256 vaultRequestId);
    event WithdrawCancelled(uint256 indexed requestId, uint256 indexed vaultId);
    event VaultClosed(uint256 indexed vaultId);
    event CommunityWoundUp();
    event PoolLegForwarded(uint8 indexed poolType, uint256 assets);
    /// `units` is the reservation and the only figure execution acts on; `amountAtProposal` is
    /// what they were worth when the vote was asked for, for the app to show what was approved.
    event WithdrawalProposed(
        uint256 indexed proposalId,
        uint256 indexed vaultId,
        address indexed recipient,
        uint256 units,
        uint256 amountAtProposal,
        uint64 deadline
    );
    event WithdrawalVoteCast(uint256 indexed proposalId, address indexed voter, bool support);
    /// `units` is what was burned, exactly as reserved; `assets` is what that was worth on the
    /// day, which is the number the recipient actually received.
    event WithdrawalExecuted(
        uint256 indexed proposalId, uint256 indexed vaultId, address recipient, uint256 units, uint256 assets
    );
    event WithdrawalReverted(uint256 indexed proposalId, uint256 indexed vaultId, uint256 units);

    // ---- errors ----

    error AlreadyInitialized();
    error NotMember();
    error NotHost();
    error NotVaultOwner();
    error NotDepositor();
    error AccountBlocked(); // a money-in path taken by a screener-blocked account
    error ZeroAmount();
    error ZeroAddress();
    error UnknownVault();
    error VaultNotActive();
    error VaultLocked();
    /// `createVault`: a TERM record carries no `lockedUntil`. Term is the venue profile for money
    /// that is committed, which is the only reason its venues may be illiquid.
    error TermRecordMustBeLocked();
    error VaultHoldsBalance();
    error SharedVaultHoldsBalance();
    error SharedVaultNeedsAProposal();
    error PersonalVaultHasNoProposals();
    error CommunityIsClosed();
    error ExceedsWithdrawable();
    error ExceedsAvailable();
    error CooldownActive();
    error InstantPathBlocked();
    error NotRequester();
    error AlreadyVoted();
    error VoteWindowOpen();
    error VoteWindowClosed();
    error NotPassed();
    error ProposalNotLive();
    error RevertDelayNotElapsed();
    /// `claimPoolLeg` on a deployment whose `Config.CREDIT_CORE` is unset: the yield leg has
    /// no community balance to land on.
    error CreditCoreUnset();
}
