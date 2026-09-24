// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

/// One community's book. Every vault, every venue, one contract, one clone per community.
///
/// A vault is a record: an owner (none for a shared vault), a venue and, in a Locked-kind venue,
/// an unlock date. For each venue it uses, the ledger holds `Venue` shares and divides them between
/// its vaults as internal units. `venueShares(id) / venueUnits(id)` is the shares behind one unit.
///
/// The ledger is also where a community's yield is split and turned into impact. On every
/// interaction, or a public `accrue`, the gain on each venue position above its previous peak
/// price is charged: the treasury's share and this community's credit share are taken as `Venue`
/// shares, so the shares behind every unit fall by exactly that much, and the credit share becomes
/// impact for the vaults' owners and depositors at once.
interface ILedger {
    /// What a member states when they open a vault. `lockedUntil` is 0 in an Open-kind venue and a
    /// future date in a Locked-kind one. `name` is emitted and not stored.
    struct VaultParams {
        uint8 venueId;
        bool shared;
        uint64 lockedUntil;
        string name;
    }

    /// A shared vault payout request. `units` is the earmark, fixed at the request. `headcount` is
    /// the number of members counted when it was made. `status` is a `ProposalStatus` value as
    /// stored; `payoutStatus` also reports FAILED, which is never stored.
    struct Payout {
        uint256 vaultId;
        address recipient;
        uint256 units;
        uint256 amount;
        uint64 deadline;
        uint32 headcount;
        uint32 yes;
        uint32 no;
        uint8 status;
    }

    // ---- venues ----

    /// The `Venue` behind a venue id, whether or not this community has used it yet. Reverts
    /// `UnknownPoolType` for an id the registry never handed out.
    function tierVault(uint8 venueId) external view returns (address);

    // ---- the record ----

    function createVault(VaultParams calldata p) external returns (uint256 vaultId);
    function vaults(uint256 vaultId)
        external
        view
        returns (address owner, bool shared, uint8 venueId, uint64 lockedUntil, uint8 status);
    function vaultCount() external view returns (uint256);
    /// The vault ids a member owns or has deposited into, closed personal vaults excepted. At most
    /// `MAX_VAULTS_PER_MEMBER` long.
    function vaultsOf(address member) external view returns (uint256[] memory);
    function vaultUnits(uint256 vaultId) external view returns (uint256);
    /// Every unit in this venue across this community's vaults.
    function venueUnits(uint8 venueId) external view returns (uint256);
    /// The `Venue` shares behind those units, as of the last accrual. Pending fee shares are not
    /// part of it.
    function venueShares(uint8 venueId) external view returns (uint256);
    /// Fee shares taken and not yet paid out.
    function pendingFees(uint8 venueId) external view returns (uint256 treasuryShares, uint256 creditShares);
    /// The venue share price this ledger was last charged at or above, in assets per 1e18 shares.
    function highWaterPrice(uint8 venueId) external view returns (uint256);
    /// Units times shares per unit times the venue's price, as if accrued now.
    function vaultValue(uint256 vaultId) external view returns (uint256);
    /// What went in, less the capital share of what came out, pro rata by units.
    function vaultCapital(uint256 vaultId) external view returns (uint256);
    /// Value above capital, floored at 0.
    function vaultEarned(uint256 vaultId) external view returns (uint256);
    /// Units an open payout request has not earmarked.
    function availableUnits(uint256 vaultId) external view returns (uint256);
    /// Units an open payout request holds on a shared vault: a live request inside its window, or
    /// one that passed and has not executed.
    function earmarkedUnits(uint256 vaultId) external view returns (uint256);
    /// Units a member holds across their own personal vaults. `Community.forfeit` reads it.
    function personalUnitsOf(address member) external view returns (uint256);
    function closeVault(uint256 vaultId) external;

    // ---- accrual and impact ----

    /// Charges the gain above each venue's peak and records the credit share as impact. Anyone.
    function accrue() external;
    /// Pays pending fee shares out as far as each venue can pay now: the treasury's share to the
    /// treasury, the credit share to `CreditCore` for this community. Anyone.
    function settleFees() external;
    /// The member's yield impact in this community: from every personal vault they own and every
    /// shared vault they deposited into, settled and pending.
    function impactOf(address member) external view returns (uint256);
    /// The community's yield impact: the credit fee this ledger has taken, including what an
    /// accrual now would take.
    function totalImpact() external view returns (uint256);
    /// A depositor's stake in a shared vault: what they put in, when they first did, and the weight
    /// their share of the vault's impact follows.
    function stakeOf(uint256 vaultId, address member)
        external
        view
        returns (uint256 deposited, uint64 firstDepositAt, uint256 weight);
    function depositorCount(uint256 vaultId) external view returns (uint256);

    // ---- money ----

    function deposit(uint256 vaultId, uint256 amount) external;
    /// Owner only, past the lock. Debits the units now and asks the venue to pay the owner; a
    /// liquid venue pays in the same transaction.
    function requestWithdraw(uint256 vaultId, uint256 amount) external returns (uint256 requestId);
    /// Requester only, while the venue has not paid. The units and capital come back.
    function cancelWithdraw(uint256 requestId) external;
    function withdrawRequests(uint256 requestId)
        external
        view
        returns (uint256 vaultId, address owner, uint256 units, uint256 shares, uint256 capital, uint256 venueRequestId);

    // ---- the shared payout ----

    /// Host only. Earmarks the units for `amount` and counts the members who may vote. Reverts
    /// `NoHeadcount` when nobody would be counted.
    function proposeWithdrawal(uint256 vaultId, address recipient, uint256 amount) external returns (uint256 payoutId);
    /// Once per member counted in the headcount, inside the vote window.
    function voteOnWithdrawal(uint256 payoutId, bool support) external;
    /// Anyone, once passed. The venue pays the recipient directly.
    function executeWithdrawal(uint256 payoutId) external;
    function payouts(uint256 payoutId) external view returns (Payout memory);
    function payoutStatus(uint256 payoutId) external view returns (uint8);
    function isCounted(uint256 payoutId, address member) external view returns (bool);
    function hasVoted(uint256 payoutId, address member) external view returns (bool);

    // ---- closure ----

    function communityClosed() external view returns (bool);
    /// True while any shared vault holds units. A community cannot close then.
    function sharedVaultsHoldMoney() external view returns (bool);
    /// Called by this ledger's `Community` when a closure vote executes. Terminal.
    function closeCommunity() external;

    // ---- events ----

    event TierWired(uint8 indexed venueId, address venue);
    event VaultCreated(
        uint256 indexed vaultId,
        uint8 indexed venueId,
        address indexed owner,
        bool shared,
        uint64 lockedUntil,
        string name
    );
    event Deposited(uint256 indexed vaultId, address indexed member, uint256 amount, uint256 units);
    event WithdrawRequested(
        uint256 indexed requestId,
        uint256 indexed vaultId,
        address indexed owner,
        uint256 units,
        uint256 shares,
        uint256 venueRequestId
    );
    event WithdrawCancelled(uint256 indexed requestId, uint256 indexed vaultId);
    event VaultClosed(uint256 indexed vaultId);
    event CommunityWoundUp();
    /// A gain above the peak was charged. Both fees are in assets at the accrual price.
    event Accrued(uint8 indexed venueId, uint256 price, uint256 treasuryFee, uint256 creditFee);
    event FeesSettled(uint8 indexed venueId, uint256 toTreasury, uint256 toCredit);
    event WithdrawalProposed(
        uint256 indexed payoutId,
        uint256 indexed vaultId,
        address indexed recipient,
        uint256 units,
        uint256 amount,
        uint32 headcount,
        uint64 deadline
    );
    event WithdrawalVoteCast(uint256 indexed payoutId, address indexed voter, bool support);
    event WithdrawalPassed(uint256 indexed payoutId);
    event WithdrawalExecuted(
        uint256 indexed payoutId, uint256 indexed vaultId, address recipient, uint256 units, uint256 venueRequestId
    );

    // ---- errors ----

    error AlreadyInitialized();
    error NotMember();
    error NotHost();
    error NotCommunity();
    error NotVaultOwner();
    error NotCounted();
    error AccountBlocked(); // a money-in path taken by a screener-blocked account
    error ZeroAmount();
    error ZeroAddress();
    error UnknownVault();
    error VaultNotActive();
    error VaultLocked();
    /// A vault in a Locked-kind venue needs an unlock date in the future.
    error LockRequired();
    /// A vault in an Open-kind venue takes no unlock date.
    error LockNotAllowed();
    /// A retired venue takes no new vaults.
    error VenueRetired();
    error TooManyVaults();
    error VaultHoldsBalance();
    error SharedVaultHoldsBalance();
    error SharedVaultNeedsAProposal();
    error PersonalVaultHasNoProposals();
    error CommunityIsClosed();
    error ExceedsWithdrawable();
    error PayoutOpen();
    /// A payout request that would count nobody: no depositor clears every headcount bar.
    error NoHeadcount();
    error CooldownActive();
    error NotRequester();
    error AlreadyVoted();
    error VoteWindowClosed();
    error NotPassed();
    error ProposalNotLive();
    error CreditCoreUnset();
}
