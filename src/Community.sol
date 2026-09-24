// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.30;

import {EIP712} from "openzeppelin-contracts/contracts/utils/cryptography/EIP712.sol";
import {ECDSA} from "openzeppelin-contracts/contracts/utils/cryptography/ECDSA.sol";
import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import {IConfig} from "./interfaces/IConfig.sol";
import {IComplianceRegistry} from "./interfaces/IComplianceRegistry.sol";
import {ICommunityFactory} from "./interfaces/ICommunityFactory.sol";
import {ICommunityInit} from "./interfaces/ICommunityInit.sol";
import {ICommunity} from "./interfaces/ICommunity.sol";
import {ICreditCore} from "./interfaces/ICreditCore.sol";
import {ILedger} from "./interfaces/ILedger.sol";
import {ISeats} from "./interfaces/ISeats.sol";
import {IImpactSource} from "./interfaces/IImpactSource.sol";

/// A community's votes and settings. Its seats are tokens in the one `Seats` contract: this
/// contract mints there at creation and at join(), and changes a seat's state there at forfeit()
/// and executeRemoval(). `Seats` is the one record of a seat's state, mint time and number, and
/// every seat read here answers from it. The only seat index kept here is the departed-seat tree
/// the vote arithmetic needs, keyed by seat number.
///
/// join() needs an invite the current host registered onchain and the invite key bound to the
/// caller, from a wallet that has attested for itself and is not screener-blocked, while a host
/// exists and the community is under `MEMBER_CAP` Active seats. It mints at the current price, which the
/// host sets from `SEAT_PRICE_FLOOR` to `SEAT_PRICE_CEILING` and the members change by vote. A
/// paid seat splits, config-driven: 40% to the Community Credit Account, 30% to the host's
/// wallet, 30% to the protocol treasury. A $0 seat moves no money. A member leaves by forfeit()
/// or is removed by a vote the host proposes. The host role changes by a handover the members
/// do not block, a resignation, a removal vote, or an election while the seat is empty. The mint
/// timestamp is the sole source of truth for member seasoning.
///
/// A seat is Active, Suspended or Left, and the last two are final. The seat stays in the wallet
/// in both, so the app still finds the community and join()'s `AlreadyMember` line bars a second
/// mint. Only an Active seat with no unresolved removal vote against it is a member.
///
/// A paid seat is an impact source. Its 40% community leg pays `CreditCore` against this
/// community's id, and `impactOf` credits that same share of the price to the member who paid it,
/// for as long as the seat is Active.
contract Community is EIP712, ICommunity, ICommunityInit, IImpactSource {
    using SafeERC20 for IERC20;

    IConfig internal config;
    ISeats public seats;
    /// This community's `Ledger`. A closure vote reads whether its shared vaults hold money and,
    /// once passed, closes it.
    address internal ledger;
    address internal factory;

    address public host;
    uint256 public seatPrice;
    string public communityName;

    bool internal _initialized;

    /// The invite gate. Each invite is stamped with the host term and the revoke-all epoch it was
    /// made in, and is valid only while both are current. Every host change bumps `hostTerm`, so
    /// the invites of a host who is gone die with the role, even if the same address takes it
    /// again: whoever holds the role answers for every open invite. `revokeAllInvites` bumps
    /// `inviteEpoch`, so one transaction ends every invite made before it.
    uint64 public hostTerm;
    uint64 public inviteEpoch;
    mapping(address => InviteRecord) internal _invites;

    bytes32 internal constant JOIN_TYPEHASH = keccak256("Join(address community,address joiner)");

    /// One vote per slot, keyed by kind: `target` is the candidate for an election vote, the
    /// host-at-proposal-time for a host removal vote (informational only, execution always
    /// vacates on a passing removal), the member for a member removal vote, and unused for a
    /// price vote. `newPrice` is Price-kind only. `activeHostVoteId` is 0 when no host
    /// removal/election vote is live. A handover's objection period is a Handover vote whose
    /// `target` is the nominee and whose `againstCount` is the objections.
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
    uint256 public activeHostVoteId;
    uint256 public activePriceVoteId;
    /// The member's latest removal vote. Left in place when it fails, because the cooldown is
    /// measured from its deadline; cleared when it executes.
    mapping(address => uint256) public activeRemovalVoteId;
    uint256 internal nextVoteId;

    /// The latest vote to remove the host. Kept apart from
    /// `activeHostVoteId` because that slot is shared with Election: a removal proposal is
    /// refused while this vote is unresolved, and a failed one starts the host-vote cooldown.
    /// Cleared when it passes and executes, which starts no cooldown.
    uint256 internal lastHostRemovalVoteId;

    /// A Fenwick tree over seat numbers counting seats that left Active.
    /// `_departedUpTo(k)` is how many of seats 1 to k are Suspended or Left, in log n reads. It is
    /// written only at the two places a seat leaves Active, `forfeit` and `executeRemoval`, and a
    /// new id's node is filled in at mint from the nodes below it, so the tree grows with the ids.
    mapping(uint256 => uint256) internal _departedTree;

    /// The host's nomination of a successor. `voteId` is 0 until the nominee accepts, and then
    /// the objection period's vote. Cleared when it completes, fails or is cancelled; a
    /// nomination not accepted in time lapses in place, with no transaction.
    struct Handover {
        address nominee;
        uint64 nominatedAt;
        uint256 voteId;
    }

    Handover internal _handover;
    /// When the last handover failed. The host waits `REMOVAL_REPROPOSE_COOLDOWN` from here
    /// before nominating again, as after any failed vote, so members who blocked a nominee are
    /// not asked again the next day.
    uint64 internal _handoverFailedAt;

    /// A handover is blocked when objections are more than half its denominator. Half exactly
    /// does not block: a nominee the host chose and half the members accept takes the role.
    uint256 internal constant HANDOVER_BLOCK_BPS = 5000;

    /// A floor of 3 votes: a vote passes only with at least this many yes votes as well as the
    /// threshold. A seasoned denominator can be 0, which the threshold alone passes with no
    /// ballots, or the host alone. A fixed constant, not a config key. An election's floor is
    /// lower when there are fewer voters (see `_minYes`).
    uint256 internal constant MIN_YES_VOTES = 3;

    /// The latest closure vote. Kept after it fails, because the cooldown runs from its deadline.
    uint256 public closureVoteId;
    /// Set when a closure vote executes. Terminal: nobody joins, no invite works, and the host role
    /// no longer changes hands.
    bool public closed;
    /// The latest deadline of any removal vote. A closure cannot be proposed or executed before it.
    uint64 internal _removalWindowEnd;

    /// Clones share this contract's code, so the name and version are the implementation's, and
    /// each clone's domain separator is rebuilt with its own address as the verifying contract.
    constructor() EIP712("Qudi Community", "1") {}

    // ---- init ----

    function initialize(CommunityWiring calldata w) external {
        if (_initialized) revert AlreadyInitialized();
        _initialized = true;

        config = IConfig(w.config);
        seats = ISeats(w.seats);
        // The founding mint is a mint like any other, so the creator passes the same
        // compliance gates every join() caller passes: attested for themselves and not
        // screener-blocked. Checked here rather than in the factory because this is where the
        // creator's seat is actually minted.
        _requireMintable(w.creator);
        ledger = w.vault;
        factory = w.factory;
        host = w.creator;
        seatPrice = w.seatPrice;
        communityName = w.name;

        // The founding host's seat is unpaid and needs no invite: no USDC moves, no split
        // runs, and the zero amounts in SeatMinted record that.
        _mintSeat(host, 0);
        emit SeatMinted(host, address(0), 0, 0, 0, 0);
    }

    // ---- membership ----

    function join(address inviteKey, bytes calldata keySig) external {
        // Someone joining while members vote on closing would pay for a seat in a community about
        // to close, and a closed community takes nobody.
        _requireOpen();
        // No host means no one to answer for an invite, and no destination for the 30% host
        // leg. Joining reopens once the community has a host again.
        if (hostVacant()) revert HostVacant();
        _requireMintable(msg.sender);
        // The bar on rejoining. A seat is never burned and `Seats` keeps it in the wallet, so this
        // refuses a wallet whose seat is Active, Suspended or Left alike.
        if (seats.seatOf(address(this), msg.sender) != 0) revert AlreadyMember();
        if (memberCount() >= config.memberCap()) revert CommunityFull();
        _spendInvite(inviteKey, keySig);

        // checks-effects-interactions: the seat exists before any sibling or token call runs,
        // so a sibling that re-entered would see the final membership state, not a stale one.
        uint256 price = seatPrice;
        _mintSeat(msg.sender, price);
        // A $0 seat moves nothing and splits nothing, so it needs no allowance and no wired
        // `CreditCore`.
        if (price == 0) {
            emit SeatMinted(msg.sender, inviteKey, 0, 0, 0, 0);
            return;
        }
        IERC20(config.usdc()).safeTransferFrom(msg.sender, address(this), price);
        (uint256 toHost, uint256 toPool, uint256 toProtocol) = _split(price);
        emit SeatMinted(msg.sender, inviteKey, price, toHost, toPool, toProtocol);
    }

    /// Checks an invite and counts one use of it. The host registered the invite key; the key,
    /// whose private half travels in the link, signs this caller. Binding the key's signature to
    /// the caller means a watcher who copies a join from the mempool cannot spend the invite
    /// first: the copy comes from the wrong address.
    function _spendInvite(address inviteKey, bytes calldata keySig) internal {
        InviteRecord storage inv = _invites[inviteKey];
        if (inv.expiry == 0) revert InviteNotRegistered();
        if (inv.term != hostTerm) revert InviteStale();
        if (inv.epoch != inviteEpoch) revert InviteStale();
        if (inv.revoked) revert InviteWasRevoked();
        if (block.timestamp >= inv.expiry) revert InviteExpired();
        if (inv.uses >= inv.maxUses) revert InviteUsedUp();

        bytes32 joinHash = keccak256(abi.encode(JOIN_TYPEHASH, address(this), msg.sender));
        address key = _signer(joinHash, keySig);
        if (key == address(0) || key != inviteKey) revert BadKeySignature();

        inv.uses++;
    }

    /// The EIP-712 signer of `structHash` in this community's domain, or 0 for a malformed
    /// signature.
    function _signer(bytes32 structHash, bytes calldata signature) internal view returns (address signer) {
        (signer,,) = ECDSA.tryRecover(_hashTypedDataV4(structHash), signature);
    }

    /// Registers an invite of this host term. The config bounds hold here, when the invite is
    /// made: it seats at most `INVITE_MAX_USES` and lives at most `INVITE_MAX_TTL`. Only the host
    /// calls it, so with the seat empty nobody does. A key is registered once, so a revoked or
    /// spent invite cannot be refilled under the same link.
    function createInvite(address inviteKey, uint16 maxUses, uint64 expiry) external {
        if (msg.sender != host) revert NotHost();
        _requireOpen();
        if (_invites[inviteKey].expiry != 0) revert InviteAlreadyRegistered();
        if (expiry <= block.timestamp) revert InviteExpired();
        (uint32 usesCap, uint64 maxTtl) = config.inviteLimits();
        if (maxUses > usesCap) revert InviteOutOfBounds();
        if (expiry - block.timestamp > maxTtl) revert InviteOutOfBounds();
        uint64 term = hostTerm;
        _invites[inviteKey] =
            InviteRecord({term: term, epoch: inviteEpoch, expiry: expiry, maxUses: maxUses, uses: 0, revoked: false});
        emit InviteCreated(inviteKey, term, maxUses, expiry);
    }

    function inviteOf(address inviteKey) external view returns (InviteRecord memory) {
        return _invites[inviteKey];
    }

    /// Ends one invite, whatever uses it has left.
    function revokeInvite(address inviteKey) external {
        if (msg.sender != host) revert NotHost();
        InviteRecord storage inv = _invites[inviteKey];
        if (inv.expiry == 0) revert InviteNotRegistered();
        inv.revoked = true;
        emit InviteRevoked(inviteKey);
    }

    /// Ends every invite made so far, in one transaction.
    function revokeAllInvites() external {
        if (msg.sender != host) revert NotHost();
        emit AllInvitesRevoked(++inviteEpoch);
    }

    // ---- seat reads, all from `Seats` ----

    function tokenOf(address member) public view returns (uint256) {
        return seats.seatOf(address(this), member);
    }

    /// The member's seat, or an empty one (state None) if they never held one here.
    function _seat(address member) internal view returns (uint256 tokenId, ISeats.Seat memory s) {
        tokenId = seats.seatOf(address(this), member);
        if (tokenId != 0) s = seats.seatInfo(tokenId);
    }

    function seatStateOf(address member) external view returns (SeatState state) {
        (, ISeats.Seat memory s) = _seat(member);
        return s.state;
    }

    function mintedAt(address member) public view returns (uint64) {
        (, ISeats.Seat memory s) = _seat(member);
        return s.mintedAt;
    }

    /// Active seats, frozen ones included.
    function memberCount() public view returns (uint256) {
        return seats.activeCount(address(this));
    }

    /// The one membership gate every reader uses: vault creation, deposit and the shared
    /// proposal paths in `Ledger`, and `CreditCore.draw`. A Suspended or Left seat is not a
    /// member, and neither is a frozen one.
    function isMember(address wallet) external view returns (bool) {
        return _isMember(wallet);
    }

    function _isMember(address wallet) internal view returns (bool) {
        (, ISeats.Seat memory s) = _seat(wallet);
        return s.state == SeatState.Active && !_frozen(wallet);
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

    /// The seat's `Seats` token id while it is Active, else 0. The id is unique across every
    /// community and never reused. `CreditStanding` counts a member's impact only while this is
    /// non-zero, so a Suspended or Left seat's impact stops counting in the same transaction that
    /// sets the state, and it stamps the member's activity record against it. **A frozen seat
    /// still reads its id.** `CreditStanding._syncSeat` clears the activity record once the stamp
    /// stops matching, so a frozen member who repaid during the vote would lose it for good, and a
    /// vote that then failed would hand back a member with nothing.
    function activeTokenOf(address member) external view returns (uint256) {
        (uint256 tokenId, ISeats.Seat memory s) = _seat(member);
        return s.state == SeatState.Active ? tokenId : 0;
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
        address l = ICommunityFactory(factory).ledgerOf(address(this));
        return l != address(0) && ILedger(l).personalUnitsOf(member) != 0;
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
        (uint256 tokenId, ISeats.Seat memory s) = _seat(msg.sender);
        if (s.state != SeatState.Active) revert NotMember();
        if (_frozen(msg.sender)) revert MemberFrozen();
        if (msg.sender == host) revert HostCannotForfeit();
        if (_hasOpenCreditTab(msg.sender)) revert OpenTabBlocks();
        if (_holdsAPersonalVault(msg.sender)) revert VaultHoldsBalance();

        seats.setState(tokenId, SeatState.Left);
        _markDeparted(s.seatNumber);
        emit SeatForfeited(msg.sender, tokenId);
    }

    function hostVacant() public view returns (bool) {
        return host == address(0);
    }

    /// A vote to remove the host takes the host-vote threshold, more than two thirds, because it
    /// overrides the one role the community chose, and so does a vote to close, because it cannot
    /// be undone. Every other kind is a community vote at more than half. That includes an election: a seat left empty should be easy to
    /// fill, since with no host nobody can join and no shared vault can pay out. A handover's
    /// objection period takes only the community vote's window from here.
    function _thresholdFor(VoteKind kind) internal view returns (uint16 thresholdBps, uint64 window) {
        if (kind == VoteKind.HostRemoval || kind == VoteKind.Closure) return config.hostVote();
        return config.communityVote();
    }

    /// Shared vote-opening body: snapshots the denominator and the start time, sets the
    /// deadline from the kind's threshold window, and emits VoteStarted. The caller writes the
    /// returned id into its own slot (activeHostVoteId, activePriceVoteId, or
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

        // Mint time never decreases as the seat number rises (numbers are given in order, each
        // stamped with `block.timestamp`, and no seat is ever burned), so the seats seasoned at
        // the start are exactly numbers 1 to `last`. Those still Active are `last` less the
        // departed among them. A removal's target is Active (proposeRemoval checks it), so it was
        // counted exactly when its number is in the prefix.
        uint256 last = _lastSeasonedId(seasoning, block.timestamp);
        uint256 denominator = last - _departedUpTo(last);
        if (kind == VoteKind.Removal) {
            (, ISeats.Seat memory t) = _seat(target);
            if (t.seatNumber <= last) denominator--;
        } else if (kind == VoteKind.Handover) {
            // Neither the host nor the nominee is counted: whether to accept the change is the
            // other members' call.
            denominator -= _countedIn(host, last) + _countedIn(target, last);
        }
        v.denominator = denominator;
        emit VoteStarted(voteId, uint8(kind), target, newPrice);
    }

    /// 1 if `who` holds an Active seat numbered 1 to `last`, which is exactly a seat the seasoned
    /// count includes, else 0.
    function _countedIn(address who, uint256 last) internal view returns (uint256) {
        (, ISeats.Seat memory s) = _seat(who);
        return s.state == SeatState.Active && s.seatNumber <= last ? 1 : 0;
    }

    /// The one seasoning predicate a vote uses, for its denominator and for every ballot, so the
    /// two can never disagree: a seat minted at `mintTime` is in the electorate of a vote that
    /// started at `start` under `window`. Half-open, as `isSeasoned` is.
    function _seasonedBy(uint256 mintTime, uint256 window, uint256 start) internal pure returns (bool) {
        return mintTime + window <= start;
    }

    /// The highest seat number whose seat is seasoned at `start`, or 0 if none is. A binary
    /// search: `_seasonedBy` holds for a prefix of the numbers, because mint time never decreases
    /// with the number. Invariant: `lo` is 0 or seasoned, `hi` is one past the last seat or not
    /// seasoned.
    function _lastSeasonedId(uint256 window, uint256 start) internal view returns (uint256 lo) {
        uint256 hi = _nextSeatNumber();
        while (hi - lo > 1) {
            uint256 mid = (lo + hi) / 2;
            if (_seasonedBy(seats.seatInfo(seats.seatAt(address(this), mid)).mintedAt, window, start)) lo = mid;
            else hi = mid;
        }
    }

    function _nextSeatNumber() internal view returns (uint256) {
        return seats.seatCount(address(this)) + 1;
    }

    /// How many of seats 1 to `id` have left Active.
    function _departedUpTo(uint256 id) internal view returns (uint256 n) {
        for (; id != 0; id -= id & (~id + 1)) {
            n += _departedTree[id];
        }
    }

    /// Records that seat number `id` left Active, at the two places that happens. Every existing
    /// node covering `id` is below the next seat number; a node minted later takes this into
    /// account at mint.
    function _markDeparted(uint256 id) internal {
        uint256 end = _nextSeatNumber();
        for (; id < end; id += id & (~id + 1)) {
            _departedTree[id] += 1;
        }
    }

    /// The comparison a vote must clear to pass, parameterized by its own kind: at least
    /// `_minYes` yes votes and the threshold against the stored denominator.
    function _passed(uint256 voteId) internal view returns (bool) {
        Vote storage v = votes[voteId];
        (uint16 thresholdBps,) = _thresholdFor(v.kind);
        if (v.forCount < _minYes(v)) return false;
        return uint256(v.forCount) * 10_000 >= uint256(thresholdBps) * v.denominator;
    }

    /// The yes votes a vote needs besides its threshold. Every kind needs MIN_YES_VOTES, so a
    /// host cannot remove anyone alone, except an election and a closure, which need as many as
    /// there are voters, up to MIN_YES_VOTES, and never fewer than 1. A small community can still
    /// close by agreeing, and the host can never close it alone. Without that, a community that lost
    /// its host with one or two seasoned members left could never elect another: nobody could
    /// join, and no shared-vault withdrawal could ever be proposed. With no voter at all the floor
    /// is still 1, so no election passes on no votes.
    function _minYes(Vote storage v) internal view returns (uint256) {
        if (v.kind != VoteKind.Election && v.kind != VoteKind.Closure) return MIN_YES_VOTES;
        uint256 d = v.denominator;
        if (d > MIN_YES_VOTES) return MIN_YES_VOTES;
        return d == 0 ? 1 : d;
    }

    /// A vote's tally and the bars it must clear, exactly as `_passed` reads them. A handover's
    /// objection period has no yes side: `no` is the objections, and they block the handover
    /// when `no * 10_000 > thresholdBps * denominator`.
    function voteTally(uint256 voteId) external view returns (VoteTally memory t) {
        Vote storage v = votes[voteId];
        (uint16 thresholdBps,) = _thresholdFor(v.kind);
        bool handover = v.kind == VoteKind.Handover;
        t = VoteTally({
            kind: v.kind,
            target: v.target,
            deadline: v.deadline,
            denominator: v.denominator,
            yes: v.forCount,
            no: v.againstCount,
            thresholdBps: handover ? uint16(HANDOVER_BLOCK_BPS) : thresholdBps,
            minYes: handover ? 0 : _minYes(v)
        });
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

    function proposeRemoveHost() external {
        if (!_isMember(msg.sender)) revert NotMember();
        // A closed community needs no host changes.
        if (closed) revert CommunityIsClosed();
        // Nothing to remove while the role is empty, and allowing it would let one member park a
        // pointless vote in activeHostVoteId that blocks electHost() for the whole window,
        // over and over, leaving the community leaderless. Vacancy is electHost()'s to resolve.
        if (hostVacant()) revert HostVacant();
        if (activeHostVoteId != 0 && !_resolvedAsFailed(activeHostVoteId)) revert VoteActive();
        // A failed host vote waits the same cooldown a failed removal does,
        // or a bloc could keep one open back to back and the host could never remove anyone. A
        // live or passed-but-unexecuted one is refused above; a passed one cleared this slot.
        uint256 lastHostVote = lastHostRemovalVoteId;
        if (lastHostVote != 0 && block.timestamp < votes[lastHostVote].deadline + config.removalReproposeCooldown()) {
            revert HostVoteCooldown();
        }

        uint256 voteId = _startVote(VoteKind.HostRemoval, host, 0);
        activeHostVoteId = voteId;
        lastHostRemovalVoteId = voteId;
        // A host facing removal cannot hand the seat on to escape it: the vote cancels any
        // nomination, and none can be made until it resolves.
        if (_handoverPending()) _cancelNomination();
    }

    function electHost(address candidate) external {
        if (!_isMember(msg.sender)) revert NotMember();
        if (closed) revert CommunityIsClosed();
        // The bar a handover nominee meets: a seasoned Active member no removal vote is open
        // against, so nobody can join and stand for host on day one. Execution checks membership
        // again.
        if (!_canHost(candidate)) revert CandidateIneligible();
        if (!hostVacant()) revert HostNotVacant();
        if (activeHostVoteId != 0 && !_resolvedAsFailed(activeHostVoteId)) revert VoteActive();

        activeHostVoteId = _startVote(VoteKind.Election, candidate, 0);
    }

    /// Card-price changes are proposed by the host and approved by the members
    /// (community vote, simple-majority default), binding future mints only: the price
    /// actually charged is read at join(), and no minted seat is ever repriced. The price stays
    /// inside the same floor and ceiling a community is created with.
    function proposeSeatPrice(uint256 newPrice) external {
        if (msg.sender != host) revert NotHost();
        _requirePriceInRange(newPrice);
        if (activePriceVoteId != 0 && !_resolvedAsFailed(activePriceVoteId)) revert VoteActive();
        activePriceVoteId = _startVote(VoteKind.Price, address(0), newPrice);
    }

    /// Permissionless. The range is re-checked live at execution: a floor raised or a ceiling
    /// lowered by config mid-vote must not be undercut by a stale proposal.
    function executeSeatPriceVote() external {
        uint256 voteId = activePriceVoteId;
        if (voteId == 0) revert NoActiveVote();
        Vote storage v = votes[voteId];
        if (block.timestamp <= v.deadline) revert VoteWindowOpen();
        if (!_passed(voteId)) revert NotPassed();
        _requirePriceInRange(v.newPrice);
        activePriceVoteId = 0;
        seatPrice = v.newPrice;
        emit SeatPriceSet(v.newPrice);
    }

    /// Removing a member. Only the host proposes, the members
    /// decide at the community threshold, and there is no appeal. From this call until the vote
    /// resolves the member is frozen to exit-only: `isMember` reads false, so they cannot draw,
    /// deposit, create a vault, vote or propose, and `forfeit()` refuses them. They can still
    /// withdraw their own personal vaults and settle their tab, which read no membership.
    ///
    /// A failed vote bars a new removal of the same member until its deadline plus
    /// `REMOVAL_REPROPOSE_COOLDOWN`, so a host cannot keep a member frozen by proposing again
    /// each time a vote fails.
    function proposeRemoval(address member) external {
        if (hostVacant()) revert HostVacant();
        if (msg.sender != host) revert NotHost();
        if (member == host) revert CannotRemoveHost();
        (, ISeats.Seat memory s) = _seat(member);
        if (s.state != SeatState.Active) revert TargetNotMember();
        // No removal while a vote to remove the host is unresolved, so a
        // host facing one cannot freeze the members who would vote in it.
        uint256 hostVote = lastHostRemovalVoteId;
        if (hostVote != 0 && !_resolvedAsFailed(hostVote)) revert HostVoteOpen();
        uint256 last = activeRemovalVoteId[member];
        if (last != 0) {
            if (!_resolvedAsFailed(last)) revert VoteActive();
            if (block.timestamp < votes[last].deadline + config.removalReproposeCooldown()) revert RemovalCooldown();
        }
        uint256 voteId = _startVote(VoteKind.Removal, member, 0);
        activeRemovalVoteId[member] = voteId;
        uint64 deadline = votes[voteId].deadline;
        if (deadline > _removalWindowEnd) _removalWindowEnd = deadline;
    }

    /// Permissionless after the window, if passed. The seat becomes Suspended for good and stays
    /// in the member's wallet. The target is still Active here: a frozen
    /// member cannot forfeit, and the host, the one seat that could otherwise change role
    /// mid-vote, cannot be a target.
    function executeRemoval(address member) external {
        uint256 voteId = activeRemovalVoteId[member];
        if (voteId == 0) revert NoActiveVote();
        if (block.timestamp <= votes[voteId].deadline) revert VoteWindowOpen();
        if (!_passed(voteId)) revert NotPassed();
        activeRemovalVoteId[member] = 0;
        (uint256 tokenId, ISeats.Seat memory s) = _seat(member);
        seats.setState(tokenId, SeatState.Suspended);
        _markDeparted(s.seatNumber);
        emit SeatSuspended(member, tokenId);
    }

    function castVote(uint256 voteId, bool support) external {
        Vote storage v = votes[voteId];
        if (v.deadline == 0) revert NoActiveVote(); // never started
        // A handover's objection period has no ballot to cast; objections go through
        // objectToHandover.
        if (v.kind == VoteKind.Handover) revert NoActiveVote();
        if (!_isMember(msg.sender)) revert NotMember();

        // The window is a real window: without this, a vote that closed short of the threshold
        // could be revived months later by one late yes-vote and then executed.
        if (block.timestamp > v.deadline) revert VoteWindowClosed();
        // Seasoned voters only, on every kind: the seat must have been held
        // for the seasoning window when the vote started, so a host cannot invite accounts the
        // day before a vote to carry it. Measured from `startedAt` under the window the vote
        // stored, with the predicate its denominator used.
        if (!_seasonedBy(mintedAt(msg.sender), v.seasoningWindow, v.startedAt)) revert VoteIneligible();
        if (v.voted[msg.sender]) revert AlreadyVoted();
        v.voted[msg.sender] = true;
        if (support) {
            v.forCount++;
        } else {
            v.againstCount++;
        }
        emit VoteCast(voteId, msg.sender, support);
    }

    /// Permissionless. The threshold bps is read live from config (no Appendix-A literal), the
    /// denominator is the seasoned Active count stored when the vote started, and the pinned
    /// rounding is unchanged: votesFor * 10_000 >= thresholdBps * denominator, integer-only, with
    /// at least `_minYes` votes for.
    function executeRemoveHost() external {
        uint256 voteId = activeHostVoteId;
        if (voteId == 0) revert NoActiveVote();

        Vote storage v = votes[voteId];
        if (block.timestamp <= v.deadline) revert VoteWindowOpen();
        if (!_passed(voteId)) revert NotPassed();
        // A candidate who is no longer a member can never be seated: a host without an Active
        // seat would violate hostIsMemberOrVacant and leave a non-member running the community.
        // _resolvedAsFailed treats this vote as failed so a new one starts.
        if (v.kind == VoteKind.Election && !_isMember(v.target)) revert CandidateNotMember();

        activeHostVoteId = 0;
        // A passed host vote starts no cooldown and no longer blocks removals.
        if (v.kind == VoteKind.HostRemoval) lastHostRemovalVoteId = 0;
        address old = host;
        host = v.kind == VoteKind.Election ? v.target : address(0);
        hostTerm++;
        emit HostChanged(old, host, uint8(v.kind == VoteKind.Election ? HostChange.Election : HostChange.Removal));
    }

    // ---- handover and resignation ----

    /// A vote to remove the host is open until it fails at its deadline, or passes and executes.
    function _hostVoteOpen() internal view returns (bool) {
        uint256 id = lastHostRemovalVoteId;
        return id != 0 && !_resolvedAsFailed(id);
    }

    /// A nomination is pending from the moment it is made until it completes, fails or is
    /// cancelled, or, while the nominee has not accepted, until `HANDOVER_ACCEPT_WINDOW` after it.
    /// A lapsed one needs no transaction to clear.
    function _handoverPending() internal view returns (bool) {
        Handover storage h = _handover;
        if (h.nominee == address(0)) return false;
        return h.voteId != 0 || block.timestamp <= h.nominatedAt + config.handoverAcceptWindow();
    }

    /// Who may be nominated, and who may take the role at completion: a seasoned Active member
    /// that no removal vote is open against.
    function _canHost(address who) internal view returns (bool) {
        return _isMember(who) && _isSeasoned(who);
    }

    /// The host names a successor. Nothing changes until the nominee accepts and the members
    /// have had the objection period; the host keeps every power meanwhile.
    function nominateSuccessor(address nominee) external {
        if (closed) revert CommunityIsClosed();
        if (msg.sender != host) revert NotHost();
        if (_hostVoteOpen()) revert HostVoteOpen();
        if (_handoverPending()) revert NominationPending();
        uint64 failedAt = _handoverFailedAt;
        if (failedAt != 0 && block.timestamp < failedAt + config.removalReproposeCooldown()) {
            revert HandoverCooldown();
        }
        if (nominee == host || !_canHost(nominee)) revert NomineeIneligible();
        _handover = Handover({nominee: nominee, nominatedAt: uint64(block.timestamp), voteId: 0});
        emit SuccessorNominated(nominee);
    }

    /// The nominee takes the nomination up, and the objection period starts. Its denominator is
    /// fixed here, as any vote's is at its start: the seasoned Active seats, less the host and
    /// the nominee.
    function acceptNomination() external {
        Handover storage h = _handover;
        if (h.nominee == address(0)) revert NoNomination();
        if (msg.sender != h.nominee) revert NotNominee();
        if (h.voteId != 0) revert NominationPending();
        if (block.timestamp > h.nominatedAt + config.handoverAcceptWindow()) revert NominationLapsed();
        uint256 voteId = _startVote(VoteKind.Handover, msg.sender, 0);
        h.voteId = voteId;
        emit NominationAccepted(msg.sender, voteId);
    }

    /// One objection from a member the denominator counts: seasoned when the nominee accepted,
    /// and neither the host nor the nominee.
    function objectToHandover() external {
        uint256 voteId = _handover.voteId;
        if (voteId == 0) revert NoActiveVote();
        Vote storage v = votes[voteId];
        if (block.timestamp > v.deadline) revert VoteWindowClosed();
        if (!_isMember(msg.sender)) revert NotMember();
        if (msg.sender == host || msg.sender == v.target) revert VoteIneligible();
        if (!_seasonedBy(mintedAt(msg.sender), v.seasoningWindow, v.startedAt)) revert VoteIneligible();
        if (v.voted[msg.sender]) revert AlreadyVoted();
        v.voted[msg.sender] = true;
        v.againstCount++;
        emit HandoverObjected(voteId, msg.sender);
        // Objections only grow, so once they are over half the handover can never complete. It
        // fails here and the cooldown starts now; waiting for the deadline would let the host
        // cancel first, which starts no cooldown, and nominate again the same day.
        if (uint256(v.againstCount) * 10_000 > HANDOVER_BLOCK_BPS * v.denominator) _failHandover();
    }

    /// Permissionless once the objection period is over. The nominee is checked again: one who
    /// left, or whom a removal vote now freezes, cannot take the role, and the handover fails.
    function completeHandover() external {
        uint256 voteId = _handover.voteId;
        if (voteId == 0) revert NoActiveVote();
        if (block.timestamp <= votes[voteId].deadline) revert VoteWindowOpen();
        address nominee = _handover.nominee;
        if (!_canHost(nominee)) {
            _failHandover();
            return;
        }
        delete _handover;
        address old = host;
        host = nominee;
        hostTerm++;
        emit HostChanged(old, nominee, uint8(HostChange.Handover));
    }

    /// The host withdraws a nomination before it completes. Nothing failed, so no cooldown.
    function cancelNomination() external {
        if (msg.sender != host) revert NotHost();
        if (!_handoverPending()) revert NoNomination();
        _cancelNomination();
    }

    function _cancelNomination() internal {
        emit NominationCancelled(_handover.nominee);
        delete _handover;
    }

    function _failHandover() internal {
        emit HandoverFailed(_handover.nominee);
        delete _handover;
        _handoverFailedAt = uint64(block.timestamp);
    }

    /// The host steps down. The seat empties and an election can follow; the old host keeps
    /// their own seat as an ordinary member. Not while members are voting on removing them,
    /// since the vote is theirs to finish, and not with a nomination pending, which the host
    /// cancels first.
    function resignHost() external {
        if (closed) revert CommunityIsClosed();
        if (msg.sender != host) revert NotHost();
        if (_hostVoteOpen()) revert HostVoteOpen();
        if (_handoverPending()) revert NominationPending();
        host = address(0);
        hostTerm++;
        emit HostChanged(msg.sender, address(0), uint8(HostChange.Resignation));
    }

    function pendingHandover() external view returns (PendingHandover memory p) {
        if (!_handoverPending()) return p;
        Handover storage h = _handover;
        p.nominee = h.nominee;
        p.nominatedAt = h.nominatedAt;
        p.voteId = h.voteId;
        if (h.voteId != 0) {
            Vote storage v = votes[h.voteId];
            p.acceptedAt = v.startedAt;
            p.objectionDeadline = v.deadline;
            p.objections = v.againstCount;
            p.denominator = v.denominator;
        }
    }

    // ---- closure ----

    /// Closing is the members' decision. The host proposes; the seasoned members vote at the
    /// host-vote bar. Refused while any other vote about who is in or who hosts is open, while a
    /// handover is pending, and while a shared vault holds money, and within
    /// `REMOVAL_REPROPOSE_COOLDOWN` of a failed closure vote.
    function proposeClosure() external {
        if (msg.sender != host) revert NotHost();
        _requireClosable();
        uint256 last = closureVoteId;
        if (last != 0) {
            if (!_resolvedAsFailed(last)) revert VoteActive();
            if (block.timestamp < votes[last].deadline + config.removalReproposeCooldown()) revert ClosureCooldown();
        }
        closureVoteId = _startVote(VoteKind.Closure, address(0), 0);
    }

    /// Anyone, once the vote has passed and its window closed. Every condition is checked again,
    /// because something may have opened since the vote started. Closing ends the host term, so
    /// every live invite stops working, and closes the ledger.
    function executeClosure() external {
        uint256 voteId = closureVoteId;
        if (voteId == 0) revert NoActiveVote();
        if (block.timestamp <= votes[voteId].deadline) revert VoteWindowOpen();
        if (!_passed(voteId)) revert NotPassed();
        _requireClosable();
        closed = true;
        hostTerm++;
        ILedger(ledger).closeCommunity();
        emit CommunityClosed();
    }

    function _requireClosable() internal view {
        if (closed) revert CommunityIsClosed();
        uint256 hostVote = activeHostVoteId;
        if (block.timestamp <= _removalWindowEnd || (hostVote != 0 && !_resolvedAsFailed(hostVote))) {
            revert VoteActive();
        }
        if (_handoverPending()) revert NominationPending();
        if (ILedger(ledger).sharedVaultsHoldMoney()) revert SharedVaultHoldsMoney();
    }

    /// Joining and new invites wait while a closure vote is open, and stop once it has passed.
    function _requireOpen() internal view {
        if (closed) revert CommunityIsClosed();
        uint256 id = closureVoteId;
        if (id != 0 && !_resolvedAsFailed(id)) revert ClosureVoteOpen();
    }

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
    function _split(uint256 price) internal returns (uint256 toHost, uint256 toPool, uint256 toProtocol) {
        (uint16 hostBps, uint16 poolBps,) = config.mintSplit();
        toHost = price * hostBps / 10_000;
        toPool = price * poolBps / 10_000;
        toProtocol = price - toHost - toPool;

        address core = config.creditCore();
        if (core == address(0)) revert CreditCoreUnset();

        IERC20 usdc = IERC20(config.usdc());
        // The host leg pays the creator's wallet directly:
        // no vault balance, no cooldown. The protocol leg is unchanged.
        usdc.safeTransfer(host, toHost);
        // Transfer then book, which is the shape the retired `receiveMintShare` hook had: the
        // USDC is in `CreditCore` before it is told whose balance to raise.
        usdc.safeTransfer(core, toPool);
        uint256 communityId = ICommunityFactory(factory).communityIdOf(address(this)) - 1;
        ICreditCore(core).receiveCommunityLeg(communityId, toPool);
        // A paid seat is the joiner's own activity too. Best-effort: credit never blocks a join.
        try ICreditCore(core).noteActivity(communityId, msg.sender) {} catch {}
        usdc.safeTransfer(config.protocolTreasury(), toProtocol);
    }

    function _mintSeat(address who, uint256 price) internal {
        uint256 number = _nextSeatNumber();
        // The new number's Fenwick node covers numbers (number - lowbit, number]. The new seat
        // itself has not departed, so the node is the departed count over the numbers just below
        // it, read from the nodes already there. For an odd number that range is empty.
        uint256 low = number & (~number + 1);
        uint256 below;
        for (uint256 j = number - 1; j > number - low; j -= j & (~j + 1)) {
            below += _departedTree[j];
        }
        if (below != 0) _departedTree[number] = below;
        seats.mint(who, price);
    }

    /// A seat price from `SEAT_PRICE_FLOOR` to `SEAT_PRICE_CEILING`, both read live.
    function _requirePriceInRange(uint256 price) internal view {
        if (price < config.seatPriceFloor()) revert BelowFloor();
        if (price > config.seatPriceCeiling()) revert AboveCeiling();
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
        return _isSeasoned(member);
    }

    /// Active seats held for at least the seasoning window, frozen ones included. Credit opens in a
    /// community only once there are enough of them.
    function seasonedCount() external view returns (uint256) {
        uint256 last = _lastSeasonedId(config.memberSeasoningWindow(), block.timestamp);
        return last - _departedUpTo(last);
    }

    /// The seat leg's impact: the community's share of what the member paid for the seat, at the
    /// seat-fee split's credit share. Counts only while the seat is Active, and only in this
    /// community.
    function impactOf(uint256 communityId, address member) external view returns (uint256) {
        (, ISeats.Seat memory s) = _seat(member);
        if (s.state != SeatState.Active || s.communityId != communityId) return 0;
        (, uint16 poolBps,) = config.mintSplit();
        return uint256(s.pricePaid) * poolBps / 10_000;
    }

    function _isSeasoned(address member) internal view returns (bool) {
        (, ISeats.Seat memory s) = _seat(member);
        return s.state == SeatState.Active && block.timestamp - s.mintedAt >= config.memberSeasoningWindow();
    }
}
