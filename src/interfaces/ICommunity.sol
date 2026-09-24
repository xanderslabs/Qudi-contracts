// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {ISeats} from "./ISeats.sol";

/// A community's votes and settings: the host (steward) role, the seat price, the invite gate,
/// and the removal, election and handover votes. Its seats live in the one `Seats` contract, which
/// holds every community's seats; this contract mints there at `join` and at creation, and changes
/// a seat's state there at `forfeit` and `executeRemoval`.
///
/// `join` needs an invite the current host registered onchain, bound to the caller by the invite
/// key's own signature, and it seats at most `MEMBER_CAP` Active members. A member leaves by
/// forfeit(), or is removed by a vote the steward proposes and the members carry. Either way the
/// seat stays in the wallet and carries its final state. The host role changes four ways: a
/// handover the members do not block, a resignation, a removal vote, and an election while the
/// seat is empty. Every paid mint splits the price, config-driven: 40% to
/// the Community Credit Account, 30% to the host's wallet (paid directly, no vault calls), 30% to
/// the protocol treasury. A $0 seat moves no money. The founding seat is minted unpaid inside
/// initialize().
interface ICommunity {
    /// StewardRemoval and Election drive proposeRemoveSteward/electSteward; Price drives
    /// proposeSeatPrice/executeSeatPriceVote; Removal drives proposeRemoval/executeRemoval.
    /// Handover is the objection period of an accepted nomination, driven by objectToHandover and
    /// completeHandover. Removal keeps the ordinal the retired Suspension kind had: `VoteStarted`
    /// emits the kind as a `uint8`, so moving it would silently change what the indexer reads.
    /// New kinds go at the end for the same reason. Closure drives proposeClosure/executeClosure.
    enum VoteKind {
        StewardRemoval,
        Election,
        Price,
        Removal,
        Handover,
        Closure
    }

    /// What a seat is. None is a wallet that never minted here. Active to
    /// Suspended happens only by an executed removal vote, Active to Left only by forfeit(), and
    /// nothing leads out of Suspended or Left.
    enum SeatState {
        None,
        Active,
        Suspended,
        Left
    }

    /// An invite the host registered with `createInvite`, keyed by the address of a throwaway
    /// key pair the host's app made. The link carries the private key, and each joiner's app signs
    /// `Join(community, joiner)` with it. It seats up to `maxUses` callers until one second before
    /// `expiry`, and only while `term` is the current `hostTerm` and `epoch` the current
    /// `inviteEpoch`. An `expiry` of 0 means the key was never registered here.
    struct InviteRecord {
        uint64 term;
        uint64 epoch;
        uint64 expiry;
        uint16 maxUses;
        uint16 uses;
        bool revoked;
    }

    /// A nomination that has not completed, failed, been cancelled or lapsed, or all zeros.
    /// `acceptedAt` is 0 until the nominee accepts; from then `voteId` is the objection period's
    /// vote, `voteTally(voteId).no` is the objection count, and `denominator` is the seasoned
    /// Active headcount at acceptance less the host and the nominee.
    struct PendingHandover {
        address nominee;
        uint64 nominatedAt;
        uint64 acceptedAt;
        uint64 objectionDeadline;
        uint32 objections;
        uint256 denominator;
        uint256 voteId;
    }

    /// A vote's tally and the bars it must clear, as `_passed` reads them: yes votes at least
    /// `minYes`, and `yes * 10_000 >= thresholdBps * denominator`.
    struct VoteTally {
        VoteKind kind;
        address target;
        uint64 deadline;
        uint256 denominator;
        uint32 yes;
        uint32 no;
        uint16 thresholdBps;
        uint256 minYes;
    }

    /// Mints at the current price and splits it 40/30/30. `keySig` is the invite key's EIP-712
    /// signature over (community, caller).
    function join(address inviteKey, bytes calldata keySig) external;
    function createInvite(address inviteKey, uint16 maxUses, uint64 expiry) external; // host only
    function revokeInvite(address inviteKey) external; // host only; ends one invite
    function revokeAllInvites() external; // host only; bumps inviteEpoch, ending every invite so far
    function inviteOf(address inviteKey) external view returns (InviteRecord memory);
    function hostTerm() external view returns (uint64); // bumped at every host change
    function inviteEpoch() external view returns (uint64); // bumped by revokeAllInvites
    function forfeit() external; // sets Left; blocked by an open tab, a personal vault, or a removal vote
    function steward() external view returns (address);
    function isMember(address wallet) external view returns (bool); // an Active seat, not frozen
    function memberCount() external view returns (uint256); // Active seats, frozen ones included
    function seatPrice() external view returns (uint256);

    // steward replacement
    function proposeRemoveSteward() external; // any member; starts the 7-day vote
    function castVote(uint256 voteId, bool support) external;
    function executeRemoveSteward() external; // a removal needs over two thirds, an election over half
    function electSteward(address candidate) external; // same vote shape, when the role is vacant

    // handover and resignation
    function nominateSuccessor(address nominee) external; // host only
    function acceptNomination() external; // nominee only; starts the objection period
    function objectToHandover() external; // once, by a member counted in the denominator
    function completeHandover() external; // permissionless after the objection period
    function cancelNomination() external; // host only; no cooldown
    function resignHost() external; // host only; the seat empties and the host stays a member
    function pendingHandover() external view returns (PendingHandover memory);

    // closure
    function proposeClosure() external; // host only; members vote at the host-vote bar
    function executeClosure() external; // permissionless once passed; closes the ledger
    function closureVoteId() external view returns (uint256);
    function closed() external view returns (bool);

    // card-price vote
    function proposeSeatPrice(uint256 newPrice) external; // steward only; floor applies; starts the vote
    function executeSeatPriceVote() external; // permissionless after the window; re-checks the floor live

    // member removal vote
    function proposeRemoval(address member) external; // steward only; per-target slot; freezes the member
    function executeRemoval(address member) external; // permissionless after the window, if passed
    function isFrozen(address member) external view returns (bool);

    function activeStewardVoteId() external view returns (uint256);
    function activePriceVoteId() external view returns (uint256);
    function activeRemovalVoteId(address member) external view returns (uint256);

    function voteTally(uint256 voteId) external view returns (VoteTally memory);

    // seat reads, all answered from `Seats`
    function seats() external view returns (ISeats);
    function tokenOf(address member) external view returns (uint256); // the `Seats` token id; kept on a Suspended or Left seat
    function activeTokenOf(address member) external view returns (uint256); // tokenOf if Active, else 0
    function seatStateOf(address member) external view returns (SeatState);
    function mintedAt(address member) external view returns (uint64);
    function isSeasoned(address member) external view returns (bool);
    function communityName() external view returns (string memory);
    function stewardVacant() external view returns (bool); // the approval freeze

    event SeatMinted(address indexed member, uint256 price, uint256 toSteward, uint256 toPool, uint256 toProtocol);
    /// The seat is Left. It stays in the member's wallet, so no burn `Transfer` accompanies it.
    event SeatForfeited(address indexed member, uint256 indexed tokenId);
    /// The seat is Suspended by an executed removal vote. It stays in the member's wallet.
    event SeatSuspended(address indexed member, uint256 indexed tokenId);
    event SeatPriceSet(uint256 price);
    event VoteStarted(uint256 indexed voteId, uint8 indexed kind, address indexed target);
    event StewardChanged(address indexed oldSteward, address indexed newSteward);
    event InviteCreated(address indexed inviteKey, uint64 term, uint16 maxUses, uint64 expiry);
    event InviteRevoked(address indexed inviteKey);
    event AllInvitesRevoked(uint64 inviteEpoch);
    event SuccessorNominated(address indexed nominee);
    event NominationAccepted(address indexed nominee, uint256 voteId);
    event NominationCancelled(address indexed nominee);
    /// Objections went over half, or the nominee no longer qualified at completion. The host
    /// waits `REMOVAL_REPROPOSE_COOLDOWN` before nominating again.
    event HandoverFailed(address indexed nominee);
    event CommunityClosed();
    /// Every ballot cast with `castVote`. A vote that fails at its deadline has no transaction and
    /// so no event; the indexer reads the outcome from `voteTally`.
    event VoteCast(uint256 indexed voteId, address indexed voter, bool support);
    /// Every objection to a handover, in the objection period's vote.
    event HandoverObjected(uint256 indexed voteId, address indexed member);

    error NotSteward();
    error NotMember();
    error OpenTabBlocks();
    /// `forfeit()` by a member who still holds units in one of their own personal vaults
    /// Zero them and leave; a locked one has to reach maturity first.
    error VaultHoldsBalance();
    /// A paid mint on a deployment whose `Config.CREDIT_CORE` is unset: the community leg
    /// has no destination, and rerouting it to Qudi's revenue would be a silent reassignment of
    /// the community's 40%.
    error CreditCoreUnset();
    error BelowFloor();
    error AboveCeiling();
    /// `join` while the community holds `MEMBER_CAP` Active seats.
    error CommunityFull();
    /// The key is not an invite of this community.
    error InviteNotRegistered();
    error InviteAlreadyRegistered();
    /// At `createInvite`, an expiry not in the future; at `join`, an invite past its expiry.
    error InviteExpired();
    /// The invite would run longer than `INVITE_MAX_TTL` or allow more than `INVITE_MAX_USES` uses.
    error InviteOutOfBounds();
    error InviteUsedUp();
    error InviteWasRevoked();
    /// Created in an earlier host term, or before a `revokeAllInvites`.
    error InviteStale();
    /// `keySig` does not recover the invite key for this caller.
    error BadKeySignature();
    error NotAttested(); // seat mint by an account that has not self-attested
    error AccountBlocked(); // seat mint by a screener-blocked account
    error TargetNotMember(); // removal proposal against a seat that is not Active
    error CannotRemoveSteward(); // removal proposal against the steward; the host vote is for that
    /// A removal of this member inside `REMOVAL_REPROPOSE_COOLDOWN` of their last failed one.
    error RemovalCooldown();
    /// `forfeit()` while a removal vote against the caller is unresolved.
    error MemberFrozen();
    /// A removal proposal while a vote to remove the steward is unresolved.
    error HostVoteOpen();
    /// A steward removal proposal inside `REMOVAL_REPROPOSE_COOLDOWN` of the last failed one.
    error HostVoteCooldown();

    error AlreadyMember();
    error NotSibling();
    error AlreadyInitialized();
    error StewardCannotForfeit();

    // steward vote errors
    error VoteActive();
    error VoteWindowOpen();
    error NotPassed();
    error AlreadyVoted();
    error StewardNotVacant();
    error StewardVacant(); // join(), proposeRemoveSteward() and proposeRemoval() while the role is empty
    error NoActiveVote();
    error VoteWindowClosed(); // a ballot cast after the vote's deadline
    error CandidateNotMember(); // election execution: the candidate is no longer a member
    error VoteIneligible(); // seat not seasoned when the vote started

    // handover errors
    error NominationPending(); // a nomination is live, or already accepted
    error NoNomination();
    error NotNominee();
    error NominationLapsed(); // accepted after HANDOVER_ACCEPT_WINDOW
    error NomineeIneligible(); // not a seasoned Active unfrozen member other than the host
    error HandoverCooldown(); // inside REMOVAL_REPROPOSE_COOLDOWN of a failed handover

    // closure errors
    error CommunityIsClosed();
    error ClosureVoteOpen(); // join or createInvite while a closure vote is open
    error ClosureCooldown(); // inside REMOVAL_REPROPOSE_COOLDOWN of a failed closure vote
    error SharedVaultHoldsMoney();
    error CandidateIneligible(); // not a seasoned Active unfrozen member
}
