// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.30;

import {ERC721} from "openzeppelin-contracts/contracts/token/ERC721/ERC721.sol";
import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import {IConfig} from "./interfaces/IConfig.sol";
import {IComplianceRegistry} from "./interfaces/IComplianceRegistry.sol";
import {ICommunityFactory} from "./interfaces/ICommunityFactory.sol";
import {ICommunityInit} from "./interfaces/ICommunityInit.sol";
import {ICommunity} from "./interfaces/ICommunity.sol";
import {ICreditCore} from "./interfaces/ICreditCore.sol";
import {ILedger} from "./interfaces/ILedger.sol";

/// Soulbound membership seat for a community. join() is open to any wallet that has attested for
/// itself and is not screener-blocked, while a steward exists, and mints at the
/// current price. The proceeds split, config-driven: 40% to the Community Credit
/// Account, 30% to the host's wallet, 30% to the protocol treasury. No seat is ever
/// transferable: every ERC721 mutation path other than mint and burn reverts, and
/// nothing burns one either. A member leaves by forfeit() or is removed by a vote
/// the steward proposes; a steward is replaced only by vote. The mint timestamp is stamped
/// per seat and is the sole source of truth for member seasoning.
///
/// A seat is Active, Suspended or Left, and the last two are
/// final. The seat stays in the wallet in both, keeping `tokenOf` and `mintedAt`, so the app
/// still finds the community and `join()`'s `AlreadyMember` line bars a second mint. Only an
/// Active seat with no unresolved removal vote against it is a member.
///
/// Standing (Impact Units, conduct, phases, Trust Extension) is the singleton `CreditCore`'s,
/// not a per-community clone. A seat mint and its 40% Community leg
/// are an Impact source. That leg pays `CreditCore` directly against this
/// community's community id; it used to pay a per-community credit-pool
/// clone with no path to pay any of it back out. Attribution of the leg to the minting member
/// is later work; only the destination moved.
contract Community is ERC721, ICommunity, ICommunityInit {
    using SafeERC20 for IERC20;

    IConfig internal config;
    /// Stored but not read by any seats logic (seats never touches the vault). The
    /// factory populates the whole wiring struct at initialize(), so this field is kept even
    /// though seats itself never reads it.
    address internal vault;
    address internal factory;

    address public steward;
    uint256 public seatPrice;
    uint256 public memberCount;
    string public communityName;

    /// Kept on a Suspended or Left seat: it is the record, and it is the bar on rejoining.
    mapping(address => uint256) public tokenOf;
    uint256 internal nextTokenId;

    /// Seat mint timestamp per member (seasoning is measured from here). Kept on a
    /// Suspended or Left seat, like `tokenOf`.
    mapping(address => uint64) public mintedAt;

    /// None until the wallet mints here. Set Active at mint, and changed exactly twice anywhere
    /// in this contract: to Suspended by `executeRemoval`, to Left by `forfeit`.
    mapping(address => SeatState) public seatStateOf;

    bool internal _initialized;

    /// One vote per slot, keyed by kind: `target` is the candidate for an election vote, the
    /// steward-at-proposal-time for a steward removal vote (informational only, execution always
    /// vacates on a passing removal), the member for a member removal vote, and unused for a
    /// price vote. `newPrice` is Price-kind only. `activeStewardVoteId` is 0 when no steward
    /// removal/election vote is live.
    ///
    /// `denominator` is fixed when the vote starts: the Active seats
    /// seasoned at `startedAt` under `seasoningWindow`, less a removal's target when the target is
    /// one of them. Reading a count live at execution was exploitable in both directions, by
    /// admitting members to dilute a passing vote or pushing members out to inflate a failing
    /// one, so only the ballots accumulate after the start. Counting every seat, as an earlier version did,
    /// counted seats that cannot vote: no vote could pass in a community's first seasoning window,
    /// and a host could block any vote by adding seats.
    ///
    /// `startedAt` and `seasoningWindow` fix the electorate: a seat votes
    /// only if `_seasonedBy` holds for it at the start, the same predicate that built the
    /// denominator, so a seat counted is exactly a seat that may vote. The window is read once,
    /// here, so a config change mid-vote moves neither.
    struct Vote {
        address target;
        uint64 deadline;
        uint64 startedAt;
        uint64 seasoningWindow;
        uint32 forCount;
        uint32 againstCount;
        VoteKind kind;
        uint256 newPrice;
        uint256 denominator;
        mapping(address => bool) voted;
    }

    mapping(uint256 => Vote) internal votes;
    uint256 public activeStewardVoteId;
    uint256 public activePriceVoteId;
    /// The member's latest removal vote. Left in place when it fails, because the cooldown is
    /// measured from its deadline; cleared when it executes.
    mapping(address => uint256) public activeRemovalVoteId;
    uint256 internal nextVoteId;

    /// The latest vote to remove the steward. Kept apart from
    /// `activeStewardVoteId` because that slot is shared with Election: a removal proposal is
    /// refused while this vote is unresolved, and a failed one starts the host-vote cooldown.
    /// Cleared when it passes and executes, which starts no cooldown.
    uint256 internal lastHostRemovalVoteId;

    /// A Fenwick tree over token ids counting seats that left Active.
    /// `_departedUpTo(k)` is how many of seats 1 to k are Suspended or Left, in log n reads. It is
    /// written only at the two places a seat leaves Active, `forfeit` and `executeRemoval`, and a
    /// new id's node is filled in at mint from the nodes below it, so the tree grows with the ids.
    mapping(uint256 => uint256) internal _departedTree;

    /// A floor of 3 votes: a vote passes only with at least this many yes votes as well as the
    /// threshold. A seasoned denominator can be 0, which the threshold alone passes with no
    /// ballots, or the host alone. A fixed constant, not a config key.
    uint256 internal constant MIN_YES_VOTES = 3;

    constructor() ERC721("Qudi Seat", "SEAT") {}

    // ---- init ----

    function initialize(CommunityWiring calldata w) external {
        if (_initialized) revert AlreadyInitialized();
        _initialized = true;

        config = IConfig(w.config);
        // The founding mint is a mint like any other, so the creator passes the same
        // compliance gates every join() caller passes: attested for themselves and not
        // screener-blocked. Checked here rather than in the factory because this is where the
        // creator's seat is actually minted.
        _requireMintable(w.creator);
        vault = w.vault;
        factory = w.factory;
        steward = w.creator;
        seatPrice = w.seatPrice;
        communityName = w.name;

        nextTokenId = 1;
        // The founding steward's seat is unpaid: no USDC moves,
        // no split runs, and the zero amounts in SeatMinted record that. Every later seat is
        // a paid mint through join().
        _mintSeat(steward);
        emit SeatMinted(steward, 0, 0, 0, 0);
    }

    // ---- ERC721 name/symbol: literal, storage-independent so minimal-proxy clones (whose
    // constructor never runs) still report the right identity ----

    function name() public pure override returns (string memory) {
        return "Qudi Seat";
    }

    function symbol() public pure override returns (string memory) {
        return "SEAT";
    }

    // ---- membership ----

    function join() external {
        // No steward means no destination for the 30% host leg: the transfer in _split()
        // would target address(0), which reverts in USDC. Joining reopens once the community
        // elects a new steward.
        if (stewardVacant()) revert StewardVacant();
        _requireMintable(msg.sender);
        // The bar on rejoining. `tokenOf` is never cleared, so this refuses
        // a wallet whose seat is Active, Suspended or Left alike: a kept seat blocks a second mint.
        if (tokenOf[msg.sender] != 0) revert AlreadyMember();

        // checks-effects-interactions: the seat exists before any sibling or token call runs,
        // so a sibling that re-entered would see the final membership state, not a stale one.
        uint256 price = seatPrice;
        _mintSeat(msg.sender);
        IERC20(config.usdc()).safeTransferFrom(msg.sender, address(this), price);
        (uint256 toSteward, uint256 toPool, uint256 toProtocol) = _split(price);
        emit SeatMinted(msg.sender, price, toSteward, toPool, toProtocol);
    }

    /// The one membership gate every reader uses: vault creation, deposit and the shared
    /// proposal paths in `Ledger`, and `CreditCore.draw`. A Suspended or Left seat is not a
    /// member, and neither is a frozen one.
    function isMember(address wallet) external view returns (bool) {
        return _isMember(wallet);
    }

    function _isMember(address wallet) internal view returns (bool) {
        return seatStateOf[wallet] == SeatState.Active && !_frozen(wallet);
    }

    /// Frozen means a removal vote against the member exists and has not resolved: before its
    /// deadline, or after it with the vote passing and not yet executed.
    /// Derived, never stored: a vote that fails at its deadline releases the member with no
    /// transaction, so there is no flag that someone would have to remember to clear.
    function _frozen(address member) internal view returns (bool) {
        uint256 voteId = activeRemovalVoteId[member];
        return voteId != 0 && !_resolvedAsFailed(voteId);
    }

    function isFrozen(address member) external view returns (bool) {
        return _frozen(member);
    }

    /// The seat's token id while it is Active, else 0. `CreditStanding` stamps a member's
    /// impact against this, so a Suspended or Left seat's impact stops
    /// counting in the same transaction that sets the state. **A frozen seat still reads its
    /// id.** `CreditStanding._syncSeat` deletes every seat-side mapping once the stamp stops
    /// matching, so a frozen member who settled during the vote would lose their impact for
    /// good, and a vote that then failed would hand back a member with nothing.
    function activeTokenOf(address member) external view returns (uint256) {
        return seatStateOf[member] == SeatState.Active ? tokenOf[member] : 0;
    }

    /// The singleton `CreditCore` owns the real debt, not the per-community
    /// credit pool this contract was once wired to, which always answered `false`. Reads
    /// `config.creditCore()` live so the gate turns on the moment a deployment wires it,
    /// without a redeploy of this contract; zero address reads as no tab, matching the rest of
    /// the codebase's "unset disables the check" posture.
    function _hasOpenCreditTab(address member) internal view returns (bool) {
        address core = config.creditCore();
        return core != address(0) && ICreditCore(core).hasOpenTab(member);
    }

    /// Units this member still holds across their own personal vault records. Resolved live
    /// through the factory for the same reason `_hasOpenCreditTab` resolves its core live: the
    /// ledger address is per community and the gate should follow it without a redeploy here.
    /// A community whose ledger is somehow unregistered reads as nothing held, matching the rest
    /// of the codebase's "unset disables the check" posture.
    function _holdsAPersonalVault(address member) internal view returns (bool) {
        address ledger = ICommunityFactory(factory).ledgerOf(address(this));
        return ledger != address(0) && ILedger(ledger).personalUnitsOf(member) != 0;
    }

    /// Member-initiated exit. A member cannot leave holding anything they have a claim on:
    /// every personal vault at zero, and no open tab. A locked personal vault binds the
    /// membership too, by way of the
    /// zeroing rule rather than a rule of its own: they wait out maturity, withdraw, zero it, and
    /// then leave.
    ///
    /// Nothing has to be zeroed in a **shared** vault, and adding a check for one would be both
    /// wrong and unenforceable: nobody ever holds an individual claim on a
    /// shared vault, which is exactly why a leaver forfeits what they left in one. "Anything in
    /// that community" is what a member has a claim on.
    ///
    /// The seat is not burned. It becomes Left and stays in the wallet, which is
    /// final: `join()` refuses that wallet from here on. A member a removal
    /// vote is open against cannot leave until it resolves: the seat's label records what
    /// the community decided, not what the member chose to avoid it.
    function forfeit() external {
        if (seatStateOf[msg.sender] != SeatState.Active) revert NotMember();
        if (_frozen(msg.sender)) revert MemberFrozen();
        if (msg.sender == steward) revert StewardCannotForfeit();
        if (_hasOpenCreditTab(msg.sender)) revert OpenTabBlocks();
        if (_holdsAPersonalVault(msg.sender)) revert VaultHoldsBalance();

        seatStateOf[msg.sender] = SeatState.Left;
        memberCount--;
        _markDeparted(tokenOf[msg.sender]);
        emit SeatForfeited(msg.sender, tokenOf[msg.sender]);
    }

    function stewardVacant() public view returns (bool) {
        return steward == address(0);
    }

    /// StewardRemoval and Election share the steward-vote threshold; Price and Removal share
    /// the community-vote threshold.
    function _thresholdFor(VoteKind kind) internal view returns (uint16 thresholdBps, uint64 window) {
        if (kind == VoteKind.StewardRemoval || kind == VoteKind.Election) {
            return config.hostVote();
        }
        return config.communityVote();
    }

    /// Shared vote-opening body: snapshots the denominator and the start time, sets the
    /// deadline from the kind's threshold window, and emits VoteStarted. The caller writes the
    /// returned id into its own slot (activeStewardVoteId, activePriceVoteId, or
    /// activeRemovalVoteId[member]).
    function _startVote(VoteKind kind, address target, uint256 newPrice) internal returns (uint256 voteId) {
        (, uint64 window) = _thresholdFor(kind);
        uint64 seasoning = config.memberSeasoningWindow();
        voteId = ++nextVoteId;
        Vote storage v = votes[voteId];
        v.target = target;
        v.kind = kind;
        v.newPrice = newPrice;
        v.startedAt = uint64(block.timestamp);
        v.seasoningWindow = seasoning;
        v.deadline = uint64(block.timestamp) + window;

        // Mint time never decreases as the token id rises (ids come from
        // `nextTokenId++`, stamped with `block.timestamp`, and no seat is ever burned), so the
        // seats seasoned at the start are exactly ids 1 to `last`. Those still Active are `last`
        // less the departed among them. A removal's target is Active (proposeRemoval checks it),
        // so it was counted exactly when its id is in the prefix.
        uint256 last = _lastSeasonedId(seasoning, block.timestamp);
        uint256 denominator = last - _departedUpTo(last);
        if (kind == VoteKind.Removal && tokenOf[target] <= last) denominator--;
        v.denominator = denominator;
        emit VoteStarted(voteId, uint8(kind), target);
    }

    /// The one seasoning predicate a vote uses, for its denominator and for every ballot, so the
    /// two can never disagree: a seat minted at `mintTime` is in the electorate of a vote that
    /// started at `start` under `window`. Half-open, as `isSeasoned` is.
    function _seasonedBy(uint256 mintTime, uint256 window, uint256 start) internal pure returns (bool) {
        return mintTime + window <= start;
    }

    /// The highest token id whose seat is seasoned at `start`, or 0 if none is. A binary search:
    /// `_seasonedBy` holds for a prefix of the ids, because mint time never decreases with the id.
    /// Invariant: `lo` is 0 or seasoned, `hi` is `nextTokenId` or not seasoned.
    function _lastSeasonedId(uint256 window, uint256 start) internal view returns (uint256 lo) {
        uint256 hi = nextTokenId;
        while (hi - lo > 1) {
            uint256 mid = (lo + hi) / 2;
            if (_seasonedBy(mintedAt[_ownerOf(mid)], window, start)) lo = mid;
            else hi = mid;
        }
    }

    /// How many of seats 1 to `id` have left Active.
    function _departedUpTo(uint256 id) internal view returns (uint256 n) {
        for (; id != 0; id -= id & (~id + 1)) {
            n += _departedTree[id];
        }
    }

    /// Records that seat `id` left Active, at the two places that happens. Every existing node
    /// covering `id` is below `nextTokenId`; a node minted later takes this into account at mint.
    function _markDeparted(uint256 id) internal {
        uint256 end = nextTokenId;
        for (; id < end; id += id & (~id + 1)) {
            _departedTree[id] += 1;
        }
    }

    /// The comparison a vote must clear to pass, parameterized by its own kind: at least
    /// MIN_YES_VOTES yes votes and the threshold against the stored denominator.
    function _passed(uint256 voteId) internal view returns (bool) {
        Vote storage v = votes[voteId];
        (uint16 thresholdBps,) = _thresholdFor(v.kind);
        if (v.forCount < MIN_YES_VOTES) return false;
        return uint256(v.forCount) * 10_000 >= uint256(thresholdBps) * v.denominator;
    }

    /// True once a vote is settled in a way that can never still apply: its deadline has
    /// passed AND it would fail the threshold check. A vote that would pass must stay blocking
    /// (VoteActive) until execution actually runs and applies it: otherwise a fresh proposal
    /// could silently clobber the slot out from under a winning vote nobody executed yet,
    /// discarding the outcome with no revert and no event. A vote that would fail is safe to
    /// discard without ever being executed: execution would only revert NotPassed on it anyway,
    /// and that revert can't itself persist a clear (state changes in a reverting call are
    /// discarded), so this check recomputes the same threshold math instead of relying on
    /// execution having run.
    function _resolvedAsFailed(uint256 voteId) internal view returns (bool) {
        Vote storage v = votes[voteId];
        if (block.timestamp <= v.deadline) return false; // still open
        // A passed election whose candidate is no longer a member (left, or removed by a vote
        // that was already open when the role fell vacant) can never be executed
        // (CandidateNotMember), so it is failed for blocking purposes: a fresh vote may start.
        // A seat is never burned and `tokenOf` never changes, so this reads the
        // candidate's membership rather than comparing token ids.
        if (v.kind == VoteKind.Election && !_isMember(v.target)) return true;
        return !_passed(voteId);
    }

    function proposeRemoveSteward() external {
        if (!_isMember(msg.sender)) revert NotMember();
        // Nothing to remove while the role is empty, and allowing it would let one member park a
        // pointless vote in activeStewardVoteId that blocks electSteward() for the whole window,
        // over and over, leaving the community leaderless. Vacancy is electSteward()'s to resolve.
        if (stewardVacant()) revert StewardVacant();
        if (activeStewardVoteId != 0 && !_resolvedAsFailed(activeStewardVoteId)) revert VoteActive();
        // A failed host vote waits the same cooldown a failed removal does,
        // or a bloc could keep one open back to back and the host could never remove anyone. A
        // live or passed-but-unexecuted one is refused above; a passed one cleared this slot.
        uint256 lastHostVote = lastHostRemovalVoteId;
        if (lastHostVote != 0 && block.timestamp < votes[lastHostVote].deadline + config.removalReproposeCooldown()) {
            revert HostVoteCooldown();
        }

        uint256 voteId = _startVote(VoteKind.StewardRemoval, steward, 0);
        activeStewardVoteId = voteId;
        lastHostRemovalVoteId = voteId;
    }

    function electSteward(address candidate) external {
        if (!_isMember(msg.sender)) revert NotMember();
        // A steward who is not a member would break stewardIsMemberOrVacant, so the candidacy is
        // where membership must be enforced first; execution checks it again.
        if (!_isMember(candidate)) revert NotMember();
        if (!stewardVacant()) revert StewardNotVacant();
        if (activeStewardVoteId != 0 && !_resolvedAsFailed(activeStewardVoteId)) revert VoteActive();

        activeStewardVoteId = _startVote(VoteKind.Election, candidate, 0);
    }

    /// Card-price changes are proposed by the steward and approved by the members
    /// (community vote, simple-majority default), binding future mints only: the price
    /// actually charged is read at join(), and no minted seat is ever repriced.
    function proposeSeatPrice(uint256 newPrice) external {
        if (msg.sender != steward) revert NotSteward();
        if (newPrice < config.seatPriceFloor()) revert BelowFloor();
        if (activePriceVoteId != 0 && !_resolvedAsFailed(activePriceVoteId)) revert VoteActive();
        activePriceVoteId = _startVote(VoteKind.Price, address(0), newPrice);
    }

    /// Permissionless. The floor is re-checked live at execution: a floor raised by config
    /// mid-vote must not be undercut by a stale proposal.
    function executeSeatPriceVote() external {
        uint256 voteId = activePriceVoteId;
        if (voteId == 0) revert NoActiveVote();
        Vote storage v = votes[voteId];
        if (block.timestamp <= v.deadline) revert VoteWindowOpen();
        if (!_passed(voteId)) revert NotPassed();
        if (v.newPrice < config.seatPriceFloor()) revert BelowFloor();
        activePriceVoteId = 0;
        seatPrice = v.newPrice;
        emit SeatPriceSet(v.newPrice);
    }

    /// Removing a member. Only the steward proposes, the members
    /// decide at the community threshold, and there is no appeal. From this call until the vote
    /// resolves the member is frozen to exit-only: `isMember` reads false, so they cannot draw,
    /// deposit, create a vault, vote or propose, and `forfeit()` refuses them. They can still
    /// withdraw their own personal vaults and settle their tab, which read no membership.
    ///
    /// A failed vote bars a new removal of the same member until its deadline plus
    /// `REMOVAL_REPROPOSE_COOLDOWN`, so a steward cannot keep a member frozen by proposing again
    /// each time a vote fails.
    function proposeRemoval(address member) external {
        if (stewardVacant()) revert StewardVacant();
        if (msg.sender != steward) revert NotSteward();
        if (member == steward) revert CannotRemoveSteward();
        if (seatStateOf[member] != SeatState.Active) revert TargetNotMember();
        // No removal while a vote to remove the steward is unresolved, so a
        // host facing one cannot freeze the members who would vote in it.
        uint256 hostVote = lastHostRemovalVoteId;
        if (hostVote != 0 && !_resolvedAsFailed(hostVote)) revert HostVoteOpen();
        uint256 last = activeRemovalVoteId[member];
        if (last != 0) {
            if (!_resolvedAsFailed(last)) revert VoteActive();
            if (block.timestamp < votes[last].deadline + config.removalReproposeCooldown()) revert RemovalCooldown();
        }
        activeRemovalVoteId[member] = _startVote(VoteKind.Removal, member, 0);
    }

    /// Permissionless after the window, if passed. The seat becomes Suspended for good and stays
    /// in the member's wallet. The target is still Active here: a frozen
    /// member cannot forfeit, and the steward, the one seat that could otherwise change role
    /// mid-vote, cannot be a target.
    function executeRemoval(address member) external {
        uint256 voteId = activeRemovalVoteId[member];
        if (voteId == 0) revert NoActiveVote();
        if (block.timestamp <= votes[voteId].deadline) revert VoteWindowOpen();
        if (!_passed(voteId)) revert NotPassed();
        activeRemovalVoteId[member] = 0;
        seatStateOf[member] = SeatState.Suspended;
        memberCount--;
        _markDeparted(tokenOf[member]);
        emit SeatSuspended(member, tokenOf[member]);
    }

    function castVote(uint256 voteId, bool support) external {
        Vote storage v = votes[voteId];
        if (v.deadline == 0) revert NoActiveVote(); // never started
        if (!_isMember(msg.sender)) revert NotMember();

        // The window is a real window: without this, a vote that closed short of the threshold
        // could be revived months later by one late yes-vote and then executed.
        if (block.timestamp > v.deadline) revert VoteWindowClosed();
        // Seasoned voters only, on every kind: the seat must have been held
        // for the seasoning window when the vote started, so a host cannot invite accounts the
        // day before a vote to carry it. Measured from `startedAt` under the window the vote
        // stored, with the predicate its denominator used.
        if (!_seasonedBy(mintedAt[msg.sender], v.seasoningWindow, v.startedAt)) revert VoteIneligible();
        if (v.voted[msg.sender]) revert AlreadyVoted();
        v.voted[msg.sender] = true;
        if (support) {
            v.forCount++;
        } else {
            v.againstCount++;
        }
    }

    /// Permissionless. The threshold bps is read live from config (no Appendix-A literal), the
    /// denominator is the seasoned Active count stored when the vote started, and the pinned
    /// rounding is unchanged: votesFor * 10_000 >= thresholdBps * denominator, integer-only, with
    /// at least MIN_YES_VOTES votes for.
    function executeRemoveSteward() external {
        uint256 voteId = activeStewardVoteId;
        if (voteId == 0) revert NoActiveVote();

        Vote storage v = votes[voteId];
        if (block.timestamp <= v.deadline) revert VoteWindowOpen();
        if (!_passed(voteId)) revert NotPassed();
        // A candidate who is no longer a member can never be seated: a steward without an Active
        // seat would violate stewardIsMemberOrVacant and leave a non-member running the community.
        // _resolvedAsFailed treats this vote as failed so a new one starts.
        if (v.kind == VoteKind.Election && !_isMember(v.target)) revert CandidateNotMember();

        activeStewardVoteId = 0;
        // A passed host vote starts no cooldown and no longer blocks removals.
        if (v.kind == VoteKind.StewardRemoval) lastHostRemovalVoteId = 0;
        address old = steward;
        steward = v.kind == VoteKind.Election ? v.target : address(0);
        emit StewardChanged(old, steward);
    }

    // ---- pool opening ----

    // ---- internal ----

    /// Reads config.mintSplit() live; the protocol leg is the remainder so the three legs
    /// always sum to `price` exactly, regardless of rounding on the other two.
    ///
    /// The community leg's destination is `config.creditCore()`, resolved live for the same
    /// reason `_hasOpenCreditTab` resolves it live. Unlike that gate it is **not** optional
    /// when unset: the money has to land somewhere real, and the two candidates are this
    /// community's credit balance or nothing. Sending it to Qudi's own revenue instead would be
    /// a silent reroute of the community's 40%, so an unwired deployment fails loud here
    /// instead. A deployment that opens paid mints wires `CREDIT_CORE`.
    function _split(uint256 price) internal returns (uint256 toSteward, uint256 toPool, uint256 toProtocol) {
        (uint16 stewardBps, uint16 poolBps,) = config.mintSplit();
        toSteward = price * stewardBps / 10_000;
        toPool = price * poolBps / 10_000;
        toProtocol = price - toSteward - toPool;

        address core = config.creditCore();
        if (core == address(0)) revert CreditCoreUnset();

        IERC20 usdc = IERC20(config.usdc());
        // The steward leg pays the creator's wallet directly:
        // no vault balance, no cooldown. The protocol leg is unchanged.
        usdc.safeTransfer(steward, toSteward);
        // Transfer then book, which is the shape the retired `receiveMintShare` hook had: the
        // USDC is in `CreditCore` before it is told whose balance to raise.
        usdc.safeTransfer(core, toPool);
        uint256 communityId = ICommunityFactory(factory).communityIdOf(address(this)) - 1;
        ICreditCore(core).receiveCommunityLeg(communityId, toPool);
        usdc.safeTransfer(config.protocolTreasury(), toProtocol);
    }

    function _mintSeat(address who) internal {
        uint256 tokenId = nextTokenId++;
        // The new id's Fenwick node covers ids (tokenId - lowbit, tokenId]. The new seat itself
        // has not departed, so the node is the departed count over the ids just below it, read
        // from the nodes already there. For an odd id that range is empty: no read at all.
        uint256 low = tokenId & (~tokenId + 1);
        uint256 below;
        for (uint256 j = tokenId - 1; j > tokenId - low; j -= j & (~j + 1)) {
            below += _departedTree[j];
        }
        if (below != 0) _departedTree[tokenId] = below;
        tokenOf[who] = tokenId;
        mintedAt[who] = uint64(block.timestamp);
        seatStateOf[who] = SeatState.Active;
        memberCount++;
        _mint(who, tokenId);
    }

    /// Seat-mint gates: the account must have attested for itself, and must not be
    /// screener-blocked. Blocked also gates contribute (in `Ledger`) and draw.
    function _requireMintable(address who) internal view {
        IComplianceRegistry reg = IComplianceRegistry(config.complianceRegistry());
        if (!reg.isAttested(who)) revert NotAttested();
        if (reg.isBlocked(who)) revert AccountBlocked();
    }

    /// The member seasoning fact: true once an Active seat has been held for at least
    /// `config.memberSeasoningWindow()`. Half-open and in seconds. A Suspended or Left seat keeps
    /// its `mintedAt` but is never seasoned: it is not a member.
    function isSeasoned(address member) external view returns (bool) {
        return
            seatStateOf[member] == SeatState.Active
                && block.timestamp - mintedAt[member] >= config.memberSeasoningWindow();
    }

    // ---- soulbound: every mutation path other than mint/burn reverts ----

    function transferFrom(address, address, uint256) public pure override {
        revert Soulbound();
    }

    // The 3-arg safeTransferFrom is not virtual in ERC721; it delegates to the 4-arg
    // overload below, which reverts, so it is soulbound too without a direct override.
    function safeTransferFrom(address, address, uint256, bytes memory) public pure override {
        revert Soulbound();
    }

    function approve(address, uint256) public pure override {
        revert Soulbound();
    }

    function setApprovalForAll(address, bool) public pure override {
        revert Soulbound();
    }

    /// Defense in depth for the soulbound rule: even if some inherited path bypassed the overrides
    /// above, only mint (from == 0) and burn (to == 0) may reach the base ERC721 update.
    function _update(address to, uint256 tokenId, address auth) internal override returns (address) {
        address from = _ownerOf(tokenId);
        if (from != address(0) && to != address(0)) revert Soulbound();
        return super._update(to, tokenId, auth);
    }
}
