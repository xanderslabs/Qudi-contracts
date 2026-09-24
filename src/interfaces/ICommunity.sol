// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {ISeats} from "./ISeats.sol";

/// A community's votes and settings: the host (steward) role, the seat price, the invite gate,
/// and the removal and election votes. Its seats live in the one `Seats` contract, which holds
/// every community's seats; this contract mints there at `join` and at creation, and changes a
/// seat's state there at `forfeit` and `executeRemoval`.
///
/// `join` needs an invite the current host signed, bound to the caller by the invite key's own
/// signature, and it seats at most `MEMBER_CAP` Active members. A member leaves by forfeit(), or is
/// removed by a vote the steward proposes and the members carry. Either way the seat stays in the
/// wallet and carries its final state, and a defaulting steward faces the same consequences as any
/// member: the role changes only by vote. Every paid mint splits the price, config-driven: 40% to
/// the Community Credit Account, 30% to the host's wallet (paid directly, no vault calls), 30% to
/// the protocol treasury. A $0 seat moves no money. The founding seat is minted unpaid inside
/// initialize().
interface ICommunity {
    /// StewardRemoval and Election drive proposeRemoveSteward/electSteward; Price drives
    /// proposeSeatPrice/executeSeatPriceVote; Removal drives proposeRemoval/executeRemoval.
    /// Removal keeps the ordinal the retired Suspension kind had: `VoteStarted` emits the kind
    /// as a `uint8`, so moving it would silently change what the indexer reads.
    enum VoteKind {
        StewardRemoval,
        Election,
        Price,
        Removal
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

    /// An invite, as EIP-712 typed data in this community's domain. The host signs it once, off
    /// chain, and it seats up to `maxUses` callers from `issuedAt` until `expiry`. `inviteKey` is
    /// the address of a throwaway key pair the host's app made for this invite; the link carries
    /// the private key, and each joiner's app signs `Join(community, joiner)` with it.
    struct Invite {
        address community;
        address inviteKey;
        uint64 issuedAt;
        uint64 expiry;
        uint32 maxUses;
        uint256 hostNonce;
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

    /// Mints at the current price and splits it 40/30/30. `hostSig` is the current host's
    /// signature over `invite`; `keySig` is the invite key's signature over (community, caller).
    function join(Invite calldata invite, bytes calldata hostSig, bytes calldata keySig) external;
    function revokeInvite(address inviteKey) external; // host only; ends one invite
    function revokeAllInvites() external; // host only; bumps hostNonce, ending every invite signed before
    function hostNonce() external view returns (uint256);
    function inviteUses(address inviteKey) external view returns (uint256);
    function inviteRevoked(address inviteKey) external view returns (bool);
    function forfeit() external; // sets Left; blocked by an open tab, a personal vault, or a removal vote
    function steward() external view returns (address);
    function isMember(address wallet) external view returns (bool); // an Active seat, not frozen
    function memberCount() external view returns (uint256); // Active seats, frozen ones included
    function seatPrice() external view returns (uint256);

    // steward replacement
    function proposeRemoveSteward() external; // any member; starts the 7-day vote
    function castVote(uint256 voteId, bool support) external;
    function executeRemoveSteward() external; // needs two thirds at window close
    function electSteward(address candidate) external; // same vote shape, when the role is vacant

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
    event InviteRevoked(address indexed inviteKey);
    event AllInvitesRevoked(uint256 hostNonce);

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
    error InviteWrongCommunity();
    error InviteNotYetValid();
    error InviteExpired();
    /// The invite runs longer than `INVITE_MAX_TTL` or allows more than `INVITE_MAX_USES` uses.
    error InviteOutOfBounds();
    error InviteUsedUp();
    error InviteWasRevoked();
    /// Signed under a host nonce `revokeAllInvites` has since moved past.
    error InviteStaleNonce();
    /// `hostSig` does not recover the current host.
    error BadHostSignature();
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
}
