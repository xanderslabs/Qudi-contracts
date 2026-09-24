// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

/// Soulbound seat ERC-721: open membership, steward role, seat price, removal/election vote.
/// join() is open to any wallet that has attested for itself and is not
/// screener-blocked, while a steward exists; there is no admit gate and no member cap.
/// A member leaves by forfeit(), or is removed by a vote the
/// steward proposes and the members carry. Either way the seat stays in the wallet and
/// carries its final state, and a defaulting steward faces the same consequences as any
/// member: the role changes only by vote. Every paid mint splits the
/// price, config-driven: 40% to the Community Credit Account, 30% to the host's
/// wallet (paid directly, no vault calls), 30% to the protocol treasury. The founding
/// seat is minted unpaid inside initialize(); every later seat is
/// a paid mint through join().
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

    function join() external; // open; mints at current price, splits 40/30/30
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

    function tokenOf(address member) external view returns (uint256); // kept on a Suspended or Left seat
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

    error Soulbound();
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
