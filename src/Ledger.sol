// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.30;

import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import {ILedger} from "./interfaces/ILedger.sol";
import {ICommunityInit} from "./interfaces/ICommunityInit.sol";
import {IVenue} from "./interfaces/IVenue.sol";
import {IConfig} from "./interfaces/IConfig.sol";
import {ICommunity} from "./interfaces/ICommunity.sol";
import {ICommunityFactory} from "./interfaces/ICommunityFactory.sol";
import {IComplianceRegistry} from "./interfaces/IComplianceRegistry.sol";
import {VaultStatus, ProposalStatus} from "./VaultStatus.sol";

/// One community's book: every vault, every tier, one contract,
/// one clone per community.
///
/// A vault is a record. The ledger holds one position per tier in that tier's shared `Venue`
/// and divides it between the records that named the tier, so a community can run "Rent fund" and
/// "School fees" as two Core 1 vaults without fragmenting the tier position across two small
/// depositors. `tierUnits[t]` is the real position and `vaultUnits` is its division; the two
/// equalities in `test/invariant/LedgerInvariants.t.sol` are the reconciliation.
///
/// **The lock lives here, and nowhere else.** Term is an ordinary tier and locking is a property
/// of a vault record. There is no vault-level lock, because a
/// tier vault serves many records with many different dates and could carry at most one. This
/// contract enforces each record's own `lockedUntil`.
///
/// **There is no per-member unit accounting**. A shared vault belongs to the
/// community: a member who leaves forfeits what they left in one, so nobody ever holds an
/// individual claim on it, and a payout is a proposal the depositors vote through. A personal
/// vault has exactly one owner. Per-member contribution history is served from events by the
/// indexer, which is where display data belongs, and it is also why the epoch and time-weighted
/// block this file used to carry is gone: with no per-member units in a shared vault, per-member
/// balance-time is not computable on chain at all.
contract Ledger is ILedger, ICommunityInit {
    using SafeERC20 for IERC20;

    IConfig public config;
    address public factory;
    ICommunity public community;
    bool internal initialized;

    /// No vote passes on fewer than three votes, whatever the percentage. A hard
    /// floor rather than a parameter, because a community of two cannot pass anything until it
    /// grows and no configured percentage should be able to change that.
    uint32 internal constant MIN_VOTES = 3;

    /// Qudi's `Venue` for each tier, cached the first time this community touches it.
    /// A cache and nothing more: the address comes from the factory's venue registry, which is Qudi's
    /// deployment, and a community has no say in it. Caching it saves an external call on every
    /// later deposit and is where the one-time USDC approval hangs; `_tier` is the only writer.
    mapping(uint8 => IVenue) internal _tierVault;

    struct Vault {
        uint8 poolType;
        bool shared;
        address owner; // personal vaults only
        uint64 lockedUntil; // 0 = open
        uint8 contribution;
        uint8 status;
        string name;
        uint256 target;
        uint64 targetDate;
    }

    mapping(uint256 => Vault) public override vaults;
    mapping(uint256 => uint256) public override vaultUnits;
    /// Units of `vaultUnits` a pending withdrawal request has reserved. A **subset** of the
    /// record's units, not a move off them: the shares have not left the tier vault yet, so the
    /// tier position has not changed and neither has the record's share of it. Freezing them
    /// stops the same units being requested twice; the debit happens at execution, where the
    /// units actually leave.
    mapping(uint256 => uint256) internal _frozenUnits;
    mapping(uint8 => uint256) public override tierUnits;
    mapping(uint256 => uint256) public override vaultPrincipal;
    /// Units a live proposal has reserved on a shared vault. **Units, not dollars.**
    /// The funds are earmarked at proposal time and no parameter changes at
    /// execution; reserving units is what makes that literally true, because a price move cannot
    /// outrun a claim that is already counted in the thing the vault is made of. A dollar earmark
    /// needed a clamp when the price fell, and a clamp changes the executed amount away from the
    /// approved one, which is the thing 1.15 says cannot happen.
    mapping(uint256 => uint256) public override earmarkedUnits;
    /// Units a member holds across their own personal records, frozen units included. Kept as a
    /// running total rather than derived, because `Community.forfeit()` reads it and walking a
    /// member's records there would cost gas proportional to how long they had been a member.
    mapping(address => uint256) public override personalUnitsOf;
    /// What this member has put into this shared vault, cumulatively, and the moment that total
    /// first reached the amount bar. A qualifying
    /// contributor is someone who deposited at least `QUALIFYING_CONTRIBUTOR_MIN_DEPOSIT` at
    /// least `QUALIFYING_CONTRIBUTOR_SEASONING` before the proposal, and those two figures are
    /// what it takes to answer that: a running sum, because the bar is
    /// on the total and not on any one deposit, and the crossing timestamp, because the
    /// seasoning runs from when the stake became real rather than from the first dollar.
    ///
    /// **A deliberate narrow exception to the rule that forbids a per-member claim
    /// on a shared vault's money.** Eligibility to vote is not a claim: neither number is units,
    /// neither converts to units, and no path that moves USDC or units reads either one. They
    /// are read in exactly two places, `_qualifiesAt` and `_qualifyingContributorsAt`, and both
    /// answer questions about people rather than about money.
    mapping(uint256 => mapping(address => uint256)) internal _depositedInto;
    mapping(uint256 => mapping(address => uint64)) internal _qualifiedSince;
    /// Every crossing timestamp for a shared vault, in the order they happened. Ascending by
    /// construction, because `block.timestamp` is, which is what lets the denominator be counted
    /// by binary search instead of a walk. A count of people, appended once per member and never
    /// removed: a contributor who leaves forfeits what they left and the electorate
    /// they were part of does not shrink behind a live proposal.
    mapping(uint256 => uint64[]) internal _qualifiedAt;
    uint256 internal _nextVaultId;

    mapping(address => uint64) public override lastWithdrawalAt;
    bool public override communityClosed;

    function initialize(CommunityWiring calldata w) external override {
        if (initialized) revert AlreadyInitialized();
        initialized = true;
        config = IConfig(w.config);
        factory = w.factory;
        community = ICommunity(w.community);
    }

    /// Every tier Qudi has deployed is available to every community. There is
    /// nothing to open and no host gate: Qudi decides which tiers exist, the host picks one when
    /// creating a shared vault, and a member picks one for their own. This resolves the tier's
    /// `Venue` from the factory the first time the community touches that tier, approves it
    /// for USDC once, and caches it.
    ///
    /// The range guard lives here because this is the only door: an id the registry never handed
    /// out is refused with the config's own typed error.
    function _tier(uint8 poolType) internal returns (IVenue tv) {
        tv = _tierVault[poolType];
        if (address(tv) != address(0)) return tv;
        if (poolType >= ICommunityFactory(factory).venueCount()) revert IConfig.UnknownPoolType();
        tv = IVenue(ICommunityFactory(factory).venueAt(poolType));
        _tierVault[poolType] = tv;
        IERC20(config.usdc()).forceApprove(address(tv), type(uint256).max);
        emit TierWired(poolType, address(tv));
    }

    /// Qudi's vault for this tier, whether or not this community has touched it yet. Answers the
    /// same address `_tier` would wire, so a reader never has to know about the cache.
    function tierVault(uint8 poolType) external view override returns (address) {
        if (poolType >= ICommunityFactory(factory).venueCount()) revert IConfig.UnknownPoolType();
        IVenue tv = _tierVault[poolType];
        return address(tv) != address(0) ? address(tv) : ICommunityFactory(factory).venueAt(poolType);
    }

    // ---- the record ----

    /// A shared vault is the host's to open, a personal one is any member's. Both may sit in any
    /// tier that is open, and both carry their own `lockedUntil`.
    function createVault(VaultParams calldata p) external override returns (uint256 vaultId) {
        if (communityClosed) revert CommunityIsClosed();
        if (p.shared) {
            if (msg.sender != community.steward()) revert NotHost();
        } else if (!community.isMember(msg.sender)) {
            revert NotMember();
        }
        // Wires the tier on first use and range-guards `poolType`. Every record therefore has a
        // resolved tier vault from birth, which is what lets every money path below read the
        // cache directly.
        IVenue tv = _tier(p.poolType);
        // A maturity already in the past is a lock that never locked, and it is far more likely
        // to be a mistyped date than an intention. Same refusal `Venue`'s constructor makes.
        if (p.lockedUntil != 0 && p.lockedUntil <= block.timestamp) revert VaultLocked();
        // A record in a Locked venue must carry a lock. A Locked venue does not anticipate
        // withdrawals and may therefore be illiquid, and the only reason that is safe is that the
        // money is committed for a known period.
        if (tv.labels().kind == IVenue.Kind.Locked && p.lockedUntil == 0) revert TermRecordMustBeLocked();

        vaultId = ++_nextVaultId;
        Vault storage v = vaults[vaultId];
        v.poolType = p.poolType;
        v.shared = p.shared;
        v.owner = p.shared ? address(0) : msg.sender;
        v.lockedUntil = p.lockedUntil;
        v.contribution = p.contribution;
        v.status = VaultStatus.ACTIVE;
        v.name = p.name;
        v.target = p.target;
        v.targetDate = p.targetDate;

        emit VaultCreated(
            vaultId, p.poolType, v.owner, p.shared, p.lockedUntil, p.contribution, p.name, p.target, p.targetDate
        );
    }

    function vaultCount() external view override returns (uint256) {
        return _nextVaultId;
    }

    /// Units frozen in a pending request are part of `vaultUnits` already: they are still the
    /// vault's money until the request executes.
    function vaultBalance(uint256 vaultId) public view override returns (uint256) {
        Vault storage v = vaults[vaultId];
        if (v.status == VaultStatus.NONE) return 0;
        return _tierVault[v.poolType].convertToAssets(vaultUnits[vaultId]);
    }

    /// Units no live proposal has reserved. The ceiling a new proposal is measured against.
    function availableUnits(uint256 vaultId) public view override returns (uint256) {
        uint256 u = vaultUnits[vaultId];
        uint256 e = earmarkedUnits[vaultId];
        return u > e ? u - e : 0;
    }

    /// What those free units are worth now. A display figure: the money bound is `availableUnits`,
    /// because that is what a proposal reserves.
    function availableBalance(uint256 vaultId) public view override returns (uint256) {
        Vault storage v = vaults[vaultId];
        if (v.status == VaultStatus.NONE) return 0;
        return _tierVault[v.poolType].convertToAssets(availableUnits(vaultId));
    }

    function vaultEarned(uint256 vaultId) external view override returns (uint256) {
        uint256 b = vaultBalance(vaultId);
        uint256 p = vaultPrincipal[vaultId];
        return b > p ? b - p : 0;
    }

    /// Whether this member is a qualifying contributor **as of now**, which is the question the
    /// app asks when it shows someone whether they hold a vote. The vote path does not use this:
    /// it asks the same question as of the proposal's creation time, through `_qualifiesAt`.
    function isDepositor(uint256 vaultId, address member) external view override returns (bool) {
        return _qualifiesAt(vaultId, member, uint64(block.timestamp));
    }

    /// The two qualifying-contributor bars, measured at `at`: the member's deposits crossed the amount bar,
    /// and they crossed it at least `seasoning` before `at`. Half-open at the far end, the same
    /// shape as the seat seasoning window: the instant the window elapses, they qualify.
    function _qualifiesAt(uint256 vaultId, address member, uint64 at) internal view returns (bool) {
        uint64 since = _qualifiedSince[vaultId][member];
        if (since == 0) return false;
        (, uint64 seasoning) = config.qualifyingContributor();
        return at >= since + seasoning;
    }

    /// How many qualifying contributors a shared vault had as of `at`. `_qualifiedAt` is
    /// ascending, so this is an upper bound over it: the number of crossings at or before
    /// `at - seasoning`.
    function _qualifyingContributorsAt(uint256 vaultId, uint64 at) internal view returns (uint256) {
        (, uint64 seasoning) = config.qualifyingContributor();
        if (at < seasoning) return 0;
        uint64 cutoff = at - seasoning;
        uint64[] storage xs = _qualifiedAt[vaultId];
        uint256 lo;
        uint256 hi = xs.length;
        while (lo < hi) {
            uint256 mid = (lo + hi) >> 1;
            if (xs[mid] <= cutoff) lo = mid + 1;
            else hi = mid;
        }
        return lo;
    }

    /// Everyone who has crossed the amount bar in this shared vault, seasoned or not. A display
    /// figure: the quorum denominator is `_qualifyingContributorsAt`, frozen on each proposal.
    function depositorCount(uint256 vaultId) external view override returns (uint256) {
        return _qualifiedAt[vaultId].length;
    }

    /// Nothing is deleted, only marked. A record holding a balance cannot be closed,
    /// which is what stops a close from stranding money behind a state nothing pays out of.
    function closeVault(uint256 vaultId) external override {
        Vault storage v = _liveVault(vaultId);
        if (v.shared) {
            if (msg.sender != community.steward()) revert NotHost();
        } else if (msg.sender != v.owner) {
            revert NotVaultOwner();
        }
        if (vaultUnits[vaultId] != 0) revert VaultHoldsBalance();
        v.status = VaultStatus.CLOSED;
        emit VaultClosed(vaultId);
    }

    // ---- money in ----

    /// Every dollar in buys units for the record: a deposit is
    /// savings, never a repayment. A shared vault takes money from any member; a personal one
    /// only from its owner.
    function deposit(uint256 vaultId, uint256 amount) external override {
        if (communityClosed) revert CommunityIsClosed();
        if (amount == 0) revert ZeroAmount();
        Vault storage v = _liveVault(vaultId);
        // Also the exit-only gate: `isMember` is false for a
        // Suspended or Left seat and for a member a removal vote is open against.
        if (!community.isMember(msg.sender)) revert NotMember();
        if (!v.shared && msg.sender != v.owner) revert NotVaultOwner();
        // `blocked` covers money going INTO the protocol, not just draws. Attestation is
        // not re-checked here: a deposit already requires a seat, and the seat mint gated it.
        if (IComplianceRegistry(config.complianceRegistry()).isBlocked(msg.sender)) revert AccountBlocked();

        IERC20(config.usdc()).safeTransferFrom(msg.sender, address(this), amount);
        uint256 units = _tierVault[v.poolType].deposit(amount, address(this));
        vaultUnits[vaultId] += units;
        tierUnits[v.poolType] += units;
        vaultPrincipal[vaultId] += amount;
        if (v.shared) {
            uint256 contributed = _depositedInto[vaultId][msg.sender] + amount;
            _depositedInto[vaultId][msg.sender] = contributed;
            (uint256 minDeposit,) = config.qualifyingContributor();
            if (_qualifiedSince[vaultId][msg.sender] == 0 && contributed >= minDeposit) {
                _qualifiedSince[vaultId][msg.sender] = uint64(block.timestamp);
                _qualifiedAt[vaultId].push(uint64(block.timestamp));
            }
        } else {
            personalUnitsOf[msg.sender] += units;
        }
        emit Deposited(vaultId, msg.sender, amount, units, vaultUnits[vaultId]);
    }

    // ---- money out ----

    struct WithdrawRequest {
        uint256 vaultId;
        address receiver;
        uint256 units; // frozen units; 0 once executed or cancelled
        uint64 requestedAt;
    }

    WithdrawRequest[] internal _requests; // ids start at 1
    mapping(uint256 => uint256) internal _pendingOf; // one pending request per vault; 0 none

    function requests(uint256 requestId)
        external
        view
        override
        returns (uint256 vaultId, address receiver, uint256 units, uint64 requestedAt)
    {
        WithdrawRequest storage r = _requests[requestId];
        return (r.vaultId, r.receiver, r.units, r.requestedAt);
    }

    function requestWithdraw(uint256 vaultId, uint256 amount) external override returns (uint256 id) {
        Vault storage v = _liveVault(vaultId);
        // Every money path reads post-settle views, so the instant-vs-queue decision and the unit
        // conversions match what the vault will do once it has settled for itself.
        _tierVault[v.poolType].accrue();
        _requirePersonalWithdrawer(v);
        if (amount == 0) revert ZeroAmount();
        if (_pendingOf[vaultId] != 0) revert CooldownActive();

        uint256 units = _tierVault[v.poolType].convertToShares(amount);
        if (units > vaultUnits[vaultId] - _frozenUnits[vaultId]) revert ExceedsWithdrawable();
        _frozenUnits[vaultId] += units;

        if (_requests.length == 0) _requests.push();
        _requests.push(
            WithdrawRequest({
                vaultId: vaultId, receiver: msg.sender, units: units, requestedAt: uint64(block.timestamp)
            })
        );
        id = _requests.length - 1;
        _pendingOf[vaultId] = id;
        emit WithdrawRequested(id, vaultId, msg.sender, units);
    }

    /// The venue's stated exit time, and nothing else: no request waits longer because the member
    /// owes.
    function releaseAfter(uint256 id) public view returns (uint256) {
        WithdrawRequest storage r = _requests[id];
        return r.requestedAt + _tierVault[vaults[r.vaultId].poolType].labels().exitSeconds;
    }

    function executeWithdraw(uint256 id) external override {
        WithdrawRequest storage r = _requests[id];
        if (r.receiver != msg.sender) revert NotRequester();
        if (r.units == 0) revert NotRequester();
        uint256 vaultId = r.vaultId;
        Vault storage v = vaults[vaultId];
        _tierVault[v.poolType].accrue();
        // Checked again here, not only at request time: the money has not left until now, and a
        // lock that let the last step through would be a lock on the paperwork.
        if (v.lockedUntil != 0 && block.timestamp < v.lockedUntil) revert VaultLocked();
        if (block.timestamp < releaseAfter(id)) revert CooldownActive();

        uint256 units = r.units;
        r.units = 0;
        _pendingOf[vaultId] = 0;
        _frozenUnits[vaultId] -= units;
        vaultUnits[vaultId] -= units;
        tierUnits[v.poolType] -= units;
        personalUnitsOf[msg.sender] -= units;
        uint256 assets = _payOut(v, units, msg.sender, id, vaultId);
        _reducePrincipal(vaultId, assets);
        lastWithdrawalAt[msg.sender] = uint64(block.timestamp);
    }

    function cancelWithdraw(uint256 id) external override {
        WithdrawRequest storage r = _requests[id];
        if (r.receiver != msg.sender) revert NotRequester();
        if (r.units == 0) revert NotRequester();
        uint256 vaultId = r.vaultId;
        uint256 units = r.units;
        r.units = 0;
        _pendingOf[vaultId] = 0;
        // The units never left `vaultUnits`, so cancelling only releases the reservation.
        _frozenUnits[vaultId] -= units;
        emit WithdrawCancelled(id, vaultId);
    }

    function withdrawInstant(uint256 vaultId, uint256 amount) external override {
        Vault storage v = _liveVault(vaultId);
        _tierVault[v.poolType].accrue();
        _requirePersonalWithdrawer(v);
        if (amount == 0) revert ZeroAmount();
        // The instant path is for an Open venue with no exit time.
        IVenue.Labels memory l = _tierVault[v.poolType].labels();
        if (l.kind != IVenue.Kind.Open || l.exitSeconds != 0) revert InstantPathBlocked();

        uint256 units = _tierVault[v.poolType].convertToShares(amount);
        if (units > vaultUnits[vaultId] - _frozenUnits[vaultId]) revert ExceedsWithdrawable();
        vaultUnits[vaultId] -= units;
        tierUnits[v.poolType] -= units;
        personalUnitsOf[msg.sender] -= units;
        // redeem, not withdraw: it burns exactly the units debited above, so the ledger's unit
        // total never drifts from the shares it actually holds. `withdraw` rounds the burn up and
        // would leave the ledger a share short of its books at any price above 1.
        uint256 assets = _tierVault[v.poolType].redeem(units, msg.sender, address(this));
        _reducePrincipal(vaultId, assets);
        lastWithdrawalAt[msg.sender] = uint64(block.timestamp);
        emit Withdrawn(vaultId, msg.sender, assets, units, vaultUnits[vaultId]);
    }

    /// The instant-or-queue branch both executed paths share. Compare units against `maxRedeem`,
    /// not assets against `maxWithdraw`: at a non-unit share price, `convertToShares(assets)`
    /// inside the vault's redeem() guard can floor one share below `units` even when assets ==
    /// the available amount, which would revert `InsufficientInstantLiquidity` here instead of
    /// queueing.
    function _payOut(Vault storage v, uint256 units, address receiver, uint256 id, uint256 vaultId)
        internal
        returns (uint256 assets)
    {
        IVenue tv = _tierVault[v.poolType];
        assets = tv.convertToAssets(units);
        if (units <= tv.maxRedeem(address(this))) {
            tv.redeem(units, receiver, address(this));
            emit WithdrawExecuted(id, vaultId, assets);
        } else {
            // Not instantly liquid: hand the units to the tier vault's FIFO queue, paid to the
            // receiver. A separate event, because nobody has been paid yet.
            uint256 vid = tv.requestRedeem(units, receiver);
            emit WithdrawQueued(id, vaultId, units, vid);
        }
        emit Withdrawn(vaultId, receiver, assets, units, vaultUnits[vaultId]);
    }

    function _reducePrincipal(uint256 vaultId, uint256 assets) internal {
        uint256 p = vaultPrincipal[vaultId];
        vaultPrincipal[vaultId] = assets >= p ? 0 : p - assets;
    }

    /// A personal vault pays its owner and nobody else. A shared one has no member-initiated
    /// withdrawal path at all: the only way out of one is a proposal the depositors vote through,
    /// which is what makes the earmark a real reservation rather than a hint.
    function _requirePersonalWithdrawer(Vault storage v) internal view {
        if (v.shared) revert SharedVaultNeedsAProposal();
        if (msg.sender != v.owner) revert NotVaultOwner();
        if (v.lockedUntil != 0 && block.timestamp < v.lockedUntil) revert VaultLocked();
    }

    function _liveVault(uint256 vaultId) internal view returns (Vault storage v) {
        v = vaults[vaultId];
        if (v.status == VaultStatus.NONE) revert UnknownVault();
        if (v.status != VaultStatus.ACTIVE) revert VaultNotActive();
    }

    // ---- the shared withdrawal ----

    struct Proposal {
        uint256 vaultId;
        address recipient;
        /// The reservation, and the only figure execution acts on.
        uint256 units;
        /// What those units were worth when the vote was asked for. A snapshot for the app to
        /// show what was approved beside what was delivered; no money path reads it.
        uint256 amountAtProposal;
        uint64 openedAt;
        uint64 deadline;
        uint32 forVotes;
        uint32 againstVotes;
        uint256 depositorsAtProposal;
        uint8 status;
        mapping(address => bool) voted;
    }

    mapping(uint256 => Proposal) internal _proposals;
    uint256 internal _nextProposalId;

    function proposals(uint256 proposalId)
        external
        view
        override
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
        )
    {
        Proposal storage p = _proposals[proposalId];
        return (
            p.vaultId,
            p.recipient,
            p.units,
            p.amountAtProposal,
            p.deadline,
            p.forVotes,
            p.againstVotes,
            p.depositorsAtProposal,
            p.status
        );
    }

    function hasVoted(uint256 proposalId, address member) external view override returns (bool) {
        return _proposals[proposalId].voted[member];
    }

    /// The host proposes, naming a fixed recipient and a fixed amount. The host asks in USDC,
    /// which is how a host thinks about a payout, and the ledger converts it to units once, here,
    /// at the price the voters are being shown. **Those units are the reservation**:
    /// they cannot be spent twice or withdrawn out from under a live proposal, and no price move
    /// between now and execution can change what the recipient's claim is.
    function proposeWithdrawal(uint256 vaultId, address recipient, uint256 amount)
        external
        override
        returns (uint256 proposalId)
    {
        if (communityClosed) revert CommunityIsClosed();
        Vault storage v = _liveVault(vaultId);
        if (!v.shared) revert PersonalVaultHasNoProposals();
        if (msg.sender != community.steward()) revert NotHost();
        // A lock is a lock on a shared vault too. Gated here rather than at
        // execution, because a vote that cannot legally execute should never start: the community
        // would spend its whole voting window on a withdrawal this contract then refuses. The
        // accepted cost is that a locked shared vault holding a balance blocks community closure
        // until its date, which is what the lock meaning something costs.
        if (v.lockedUntil != 0 && block.timestamp < v.lockedUntil) revert VaultLocked();
        if (recipient == address(0)) revert ZeroAddress();
        if (amount == 0) revert ZeroAmount();
        IVenue tv = _tierVault[v.poolType];
        tv.accrue();

        uint256 units = tv.convertToShares(amount);
        if (units == 0) revert ZeroAmount();
        if (units > availableUnits(vaultId)) revert ExceedsAvailable();

        earmarkedUnits[vaultId] += units;
        proposalId = ++_nextProposalId;
        Proposal storage p = _proposals[proposalId];
        p.vaultId = vaultId;
        p.recipient = recipient;
        p.units = units;
        p.amountAtProposal = amount;
        p.openedAt = uint64(block.timestamp);
        (, uint64 window) = config.communityVote();
        p.deadline = uint64(block.timestamp) + window;
        p.depositorsAtProposal = _qualifyingContributorsAt(vaultId, uint64(block.timestamp));
        p.status = ProposalStatus.LIVE;
        emit WithdrawalProposed(proposalId, vaultId, recipient, units, amount, p.deadline);
    }

    /// One depositor one vote. Never weighted by balance: there are no per-member units, so
    /// there are no per-member balances to weight by.
    ///
    /// One vote per qualifying contributor: enough in, and in
    /// for long enough, by the two bars `config.qualifyingContributor()` holds.
    ///
    /// The electorate is frozen at proposal time on both sides, and **both bars are measured
    /// against `p.openedAt`, never against `block.timestamp`**. The denominator is
    /// `depositorsAtProposal`, counted at that same instant, so a member who qualifies today
    /// does not thereby qualify for a vote opened last week, and the numerator cannot outgrow
    /// the denominator it is compared against. Letting a late qualifier in would be the exploit
    /// `Community` already guards against one level up: a dollar into the pot mid-vote should
    /// not buy a vote on a proposal that was already running.
    function voteOnWithdrawal(uint256 proposalId, bool support) external override {
        Proposal storage p = _proposals[proposalId];
        if (p.status != ProposalStatus.LIVE) revert ProposalNotLive();
        if (block.timestamp > p.deadline) revert VoteWindowClosed();
        if (!_qualifiesAt(p.vaultId, msg.sender, p.openedAt)) revert NotDepositor();
        if (p.voted[msg.sender]) revert AlreadyVoted();
        p.voted[msg.sender] = true;
        if (support) p.forVotes += 1;
        else p.againstVotes += 1;
        emit WithdrawalVoteCast(proposalId, msg.sender, support);
    }

    /// Quorum 20% of the qualifying contributors, approval two thirds of the votes cast, and at
    /// least three votes whatever the percentages say. Counts of people throughout.
    /// `depositorsAtProposal` is the qualifying-contributor electorate, frozen when the proposal
    /// opened; it once was everyone who had ever deposited anything, which made every shared
    /// withdrawal easier to pass than the design intends.
    function _passed(uint256 proposalId) internal view returns (bool) {
        Proposal storage p = _proposals[proposalId];
        uint256 cast = uint256(p.forVotes) + p.againstVotes;
        if (cast < MIN_VOTES) return false;
        (uint16 quorumBps, uint16 approvalBps) = config.sharedWithdrawalVote();
        if (cast * 10_000 < uint256(quorumBps) * p.depositorsAtProposal) return false;
        return uint256(p.forVotes) * 10_000 >= uint256(approvalBps) * cast;
    }

    /// Anyone in the community may execute a passed proposal, and execution is mechanical: the
    /// recipient is already set, the amount is already reserved, and no parameter can be changed
    /// here. There is no timelock between passing and executing, for a stated reason
    /// rather than taste: Moloch's grace period is an exit window for members who
    /// voted no, and with no per-member claim on a shared vault that exit is impossible here, so a copied delay would be the
    /// waiting without the protection.
    function executeWithdrawal(uint256 proposalId) external override {
        Proposal storage p = _proposals[proposalId];
        if (p.status != ProposalStatus.LIVE) revert ProposalNotLive();
        if (!community.isMember(msg.sender)) revert NotMember();
        if (block.timestamp <= p.deadline) revert VoteWindowOpen();
        if (!_passed(proposalId)) revert NotPassed();

        uint256 vaultId = p.vaultId;
        Vault storage v = vaults[vaultId];
        _tierVault[v.poolType].accrue();
        p.status = ProposalStatus.EXECUTED;

        // Exactly the units the proposal reserved, with nothing to clamp: a shared vault's only
        // unit outflow is this function, so the reserved units are still there by construction.
        uint256 units = p.units;
        earmarkedUnits[vaultId] -= units;
        vaultUnits[vaultId] -= units;
        tierUnits[v.poolType] -= units;
        uint256 assets = _payOut(v, units, p.recipient, proposalId, vaultId);
        _reducePrincipal(vaultId, assets);
        emit WithdrawalExecuted(proposalId, vaultId, p.recipient, units, assets);
    }

    /// Releasing an earmark is a revert, never an expiry. A proposal that did not
    /// pass is revertible as soon as its window closes. One that passed sits until someone
    /// executes it, with no deadline, and becomes revertible only after
    /// `sharedProposalRevertDelay`: long enough that a host who is slow, travelling or waiting on
    /// the recipient does not lose a passed vote, short enough that money is not frozen for a
    /// month. Nothing dies on a timer, and the earmark can always be freed by someone acting.
    function revertWithdrawal(uint256 proposalId) external override {
        Proposal storage p = _proposals[proposalId];
        if (p.status != ProposalStatus.LIVE) revert ProposalNotLive();
        if (!community.isMember(msg.sender)) revert NotMember();
        if (block.timestamp <= p.deadline) revert VoteWindowOpen();
        if (_passed(proposalId) && block.timestamp < p.deadline + config.sharedProposalRevertDelay()) {
            revert RevertDelayNotElapsed();
        }
        p.status = ProposalStatus.REVERTED;
        earmarkedUnits[p.vaultId] -= p.units;
        emit WithdrawalReverted(proposalId, p.vaultId, p.units);
    }

    // ---- closure ----

    /// Nothing in, what is in can come out. A community cannot close while a shared vault holds a
    /// balance, because nobody has an individual claim on one and there would be no path left to
    /// pay it out. It can close while personal vaults hold balances: those owners withdraw
    /// afterwards, and the asymmetry is exactly that a personal vault has an owner to withdraw.
    function closeCommunity() external override {
        if (communityClosed) revert CommunityIsClosed();
        if (msg.sender != community.steward()) revert NotHost();
        uint256 n = _nextVaultId;
        for (uint256 id = 1; id <= n; id++) {
            Vault storage v = vaults[id];
            if (v.shared && v.status == VaultStatus.ACTIVE && vaultUnits[id] != 0) {
                revert SharedVaultHoldsBalance();
            }
        }
        communityClosed = true;
        emit CommunityWoundUp();
    }
}
