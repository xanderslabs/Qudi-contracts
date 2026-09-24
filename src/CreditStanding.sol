// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.30;

import {Math} from "openzeppelin-contracts/contracts/utils/math/Math.sol";
import {Ownable2Step, Ownable} from "openzeppelin-contracts/contracts/access/Ownable2Step.sol";
import {ICreditStanding} from "./interfaces/ICreditStanding.sol";
import {ICreditCore} from "./interfaces/ICreditCore.sol";
import {IConfig} from "./interfaces/IConfig.sol";
import {ICommunityFactory} from "./interfaces/ICommunityFactory.sol";
import {ICommunity} from "./interfaces/ICommunity.sol";
import {StandingMath} from "./StandingMath.sol";

/// Read-only shape of `CreditCore`'s two wiring immutables, declared locally rather than
/// importing `CreditCore.sol` (which would import `ICreditStanding.sol`, a cycle). ABI-compatible
/// with `CreditCore.factory()`/`CreditCore.config()` regardless of `config`'s Solidity-level
/// return type there (`IConfig`): every contract/interface type ABI-encodes as `address`.
/// Used only once, at `setCreditCore`, never as a production-path call.
interface ICreditCoreWiring {
    function factory() external view returns (address);
    function config() external view returns (address);
    function standing() external view returns (address);
}

/// `CreditCore`'s Standing half, split out so `CreditCore` fits under
/// EIP-170: Impact Units, the relational share, conduct decay and scars, activity
/// decay, phases, Trust Extension, and the Line. No money moves here.
///
/// **The seam runs both ways.** `CreditCore` calls into this contract at the
/// nine crossings `ICreditStanding` declares. The reverse direction never exists as a call:
/// wherever this contract's math needs Treasury or debt-ledger state
/// (`_communityLiquidCash`, `_openDelinquencyConduct`, `_hasOpenDelinquency`,
/// `_memberCurrentExposure` in the pre-split code), `CreditCore` composes a
/// `CommunityLedgerSnapshot`/`MemberTabSnapshot` from its own storage and passes it in. This
/// contract contains no call to `CreditCore`, anywhere, as a fact about this file: every
/// external contract type this file imports or references is `IConfig`, `ICommunityFactory`,
/// `ICommunity` (read for `activeTokenOf` only, the seat stamp), `ICreditStanding`, or
/// `ICreditCore` (used only for its `Phase`/`ImpactSource` enums and `MemberStanding`-adjacent
/// types, never invoked as a call target).
///
/// **Seat and account.** What is earned belongs to
/// the seat: impact, Trust Extension, completed obligations and the Phase they feed, and
/// activity. What is a consequence belongs to the account: scars and the pre-Default
/// disqualification. Seat-side state keeps its `(communityId, member)` key and is valid only
/// while `_seatStamp` equals the token id of the member's Active seat in that community; a seat
/// that is Suspended or Left (it reads as 0) or a different seat makes all of it read as
/// zero.
///
/// **Roles.** `impactAttributor` is unchanged from the pre-split contract: the
/// only caller of `accrueImpact` and `creditCommunityAttributedYield` (dev key on
/// testnet). `creditCore` replaces `obligationLedger`: it is the only caller of
/// `recordScar`, `creditObligationCompletion` and `recordFormalDefault`, and it is wired exactly
/// once, after `CreditCore` itself deploys (`setCreditCore`, owner-only, reverts if already set,
/// and reverts if `CreditCore` was not wired to this contract's own `factory`/`config`).
/// `disqualifyPreDefaultUnits` is retired as an external entry point;
/// formal Default still reaches it internally through `recordFormalDefault`.
contract CreditStanding is ICreditStanding, Ownable2Step {
    IConfig public immutable config;
    /// Source of the community count for `requireCommunity`. A "community" is a community.
    address public immutable factory;

    address public override impactAttributor;
    address public override creditCore;

    uint256 internal constant WAD = 1e18;
    uint256 internal constant _QUEUE_MAX = 64;

    struct PendingAccrual {
        uint128 amount; // attributed spread USDC, 1:1 with the Units it will mint
        uint64 mintAt; // block.timestamp of the source event + one epoch (seasoning)
    }

    struct Scar {
        uint128 frozenConductWad; // conduct value at the moment of cure
        uint64 recordedAt;
    }

    mapping(uint256 => mapping(address => uint256)) internal _impactSeasoned; // U_i
    mapping(uint256 => uint256) internal _impactSeasonedTotal; // U_C, historical, never falls
    mapping(uint256 => mapping(address => PendingAccrual[])) internal _impactPending;
    mapping(bytes32 => bool) internal _consumedSourceEvent; // idempotency

    /// Account-held: a scar follows the member into every community, now and later.
    mapping(address => Scar[]) internal _scars;
    mapping(uint256 => mapping(address => uint256)) internal _teEarned; // own counter
    mapping(uint256 => mapping(address => uint256)) internal _completedObligations;
    mapping(uint256 => mapping(address => uint64)) internal _firstObligationAt;
    /// Account-held: not escapable by leaving and rejoining.
    mapping(address => bool) internal _preDefaultDisqualified;
    /// Formal Default's permanent consequences, account-wide and persisted rather than
    /// derived. Set once, at the first formal-Default crossing on this account, never cleared
    /// (rehabilitation is deferred with the ban mechanism).
    mapping(address => bool) internal _accountDefaulted;
    mapping(uint256 => uint256) internal _communityAttributedYield; // cumulative

    mapping(uint256 => mapping(address => uint64)) internal _lastActivityAt; // activity decay
    mapping(uint256 => mapping(address => uint256)) internal _healFloorWad; // activity value re-engaged from
    mapping(uint256 => mapping(address => uint64)) internal _healFloorAt;

    /// The token id of the seat the eight seat-side mappings above were
    /// written under (`_impactSeasoned`, `_impactPending`, `_teEarned`, `_completedObligations`,
    /// `_firstObligationAt`, `_lastActivityAt`, `_healFloorWad`, `_healFloorAt`). One stamp covers
    /// all eight because they die together: a seat is given up whole, and one comparison means
    /// no read can see half of an old seat.
    mapping(uint256 => mapping(address => uint256)) internal _seatStamp;
    /// Every community the member has seat-side state in. The exposure cap sums over
    /// it, checking each stamp, so the account figures are derived at the moment they are read
    /// and a Suspended or Left seat leaves them in the same transaction.
    mapping(address => uint256[]) internal _seatCommunities;
    mapping(uint256 => mapping(address => bool)) internal _seatListed;

    modifier onlyImpactAttributor() {
        if (msg.sender != impactAttributor) revert NotImpactAttributor();
        _;
    }

    modifier onlyCreditCore() {
        if (msg.sender != creditCore) revert NotCreditCore();
        _;
    }

    constructor(IConfig config_, address factory_, address owner_) Ownable(owner_) {
        if (address(config_) == address(0) || factory_ == address(0)) revert ZeroAddress();
        config = config_;
        factory = factory_;
    }

    function setImpactAttributor(address next) external onlyOwner {
        if (next == address(0)) revert ZeroAddress();
        emit ImpactAttributorSet(impactAttributor, next);
        impactAttributor = next;
    }

    /// Wiring is fixed and one-way. `CreditCore` is deployed AFTER this contract
    /// (taking this address as an immutable constructor argument), so this is the only order
    /// this call can happen in: `CreditCore` cannot exist yet when `CreditStanding` is
    /// constructed, hence a two-step wire rather than a constructor argument here.
    /// Checked here, since this is the moment both addresses are known.
    /// A pair constructed against different `factory`/`config` instances would compute Standing
    /// against one community set and debt against another with nothing to catch it.
    /// Also checked here is the back-reference,
    /// `creditCore_.standing() == address(this)`. Without it a pair could be wired where
    /// `CreditCore` points back at some other `CreditStanding`.
    function setCreditCore(address creditCore_) external onlyOwner {
        if (creditCore_ == address(0)) revert ZeroAddress();
        if (creditCore != address(0)) revert CreditCoreAlreadySet();
        if (
            ICreditCoreWiring(creditCore_).factory() != factory
                || ICreditCoreWiring(creditCore_).config() != address(config)
        ) revert CreditCoreMismatch();
        if (ICreditCoreWiring(creditCore_).standing() != address(this)) revert CreditCoreStandingMismatch();
        creditCore = creditCore_;
        emit CreditCoreSet(creditCore_);
    }

    function requireCommunity(uint256 communityId) external view {
        _requireCommunity(communityId);
    }

    function _requireCommunity(uint256 communityId) internal view {
        if (communityId >= ICommunityFactory(factory).communityCount()) revert UnknownCommunity();
    }

    // ---- the seat stamp ----

    /// The seat's **token id**, not its `mintedAt`. `Seats` assigns ids in order across every
    /// community and never reuses one, so every seat ever minted has its own, without the hole a timestamp carries: two seats
    /// minted in the same block share a `mintedAt` to the second.
    ///
    /// **`activeTokenOf`, not `tokenOf`.** A seat is never burned
    /// now, so `tokenOf` stays set on a Suspended or Left seat, and reading it would keep that
    /// seat's impact in the account totals and the exposure cap forever.
    /// `activeTokenOf` is 0 for a seat that is not Active and for a wallet that never joined,
    /// which is the zero the stamp needs. It is deliberately **not** 0 for a frozen seat: every
    /// write here runs `_syncSeat`, which deletes the seat-side state once the stamp stops
    /// matching, so a frozen member who settled during the vote would lose their impact for good
    /// even if the vote then failed.
    function _liveSeat(uint256 communityId, address member) internal view returns (uint256) {
        return ICommunity(ICommunityFactory(factory).communityAt(communityId)).activeTokenOf(member);
    }

    /// Whether the seat-side state stored for `(communityId, member)` is the live seat's. No
    /// Active seat (Suspended, Left, or never joined) is never current.
    function _seatCurrent(uint256 communityId, address member) internal view returns (bool) {
        uint256 live = _liveSeat(communityId, member);
        return live != 0 && _seatStamp[communityId][member] == live;
    }

    /// Every write to seat-side state runs this first. A stamp that no longer matches the live
    /// seat means a different seat, so everything the old one earned is cleared before the
    /// write lands on the new one.
    function _syncSeat(uint256 communityId, address member) internal {
        if (!_seatListed[communityId][member]) {
            _seatListed[communityId][member] = true;
            _seatCommunities[member].push(communityId);
        }
        uint256 live = _liveSeat(communityId, member);
        if (_seatStamp[communityId][member] == live) return;
        _seatStamp[communityId][member] = live;
        delete _impactSeasoned[communityId][member];
        delete _impactPending[communityId][member];
        delete _teEarned[communityId][member];
        delete _completedObligations[communityId][member];
        delete _firstObligationAt[communityId][member];
        delete _lastActivityAt[communityId][member];
        delete _healFloorWad[communityId][member];
        delete _healFloorAt[communityId][member];
    }

    function _seasonedOf(uint256 communityId, address member) internal view returns (uint256) {
        return _seatCurrent(communityId, member) ? _impactSeasoned[communityId][member] : 0;
    }

    function _teEarnedOf(uint256 communityId, address member) internal view returns (uint256) {
        return _seatCurrent(communityId, member) ? _teEarned[communityId][member] : 0;
    }

    function _completedOf(uint256 communityId, address member) internal view returns (uint256) {
        return _seatCurrent(communityId, member) ? _completedObligations[communityId][member] : 0;
    }

    /// The exposure cap's two account figures, seasoned impact and te_earned summed across every
    /// community where the member still holds the seat that earned them. Derived on every read
    /// rather than kept as running totals: a running total could only fall when something wrote
    /// to the forfeited community, and nothing has to.
    function _accountTotals(address member) internal view returns (uint256 impact, uint256 teEarned) {
        uint256[] storage list = _seatCommunities[member];
        for (uint256 i; i < list.length; i++) {
            uint256 c = list[i];
            if (!_seatCurrent(c, member)) continue;
            impact += _impactSeasoned[c][member];
            teEarned += _teEarned[c][member];
        }
    }

    // ---- Impact Units ----

    /// Credit `attributedUsdc` of a realized, irreversible, member-attributable Community Credit
    /// Account addition. Units mint 1:1 after one epoch of seasoning. Idempotent by
    /// `sourceEventId`: a report re-sent mints once.
    function accrueImpact(
        uint256 communityId,
        address member,
        uint256 attributedUsdc,
        ICreditCore.ImpactSource source,
        bytes32 sourceEventId,
        uint64 sourceTimestamp
    ) external onlyImpactAttributor {
        _requireCommunity(communityId);
        if (_consumedSourceEvent[sourceEventId]) return; // already minted once
        _consumedSourceEvent[sourceEventId] = true;

        _syncSeat(communityId, member);
        _noteActivity(communityId, member);
        uint256 minted = _roll(communityId, member);

        if (attributedUsdc == 0) {
            emit ImpactAccrued(communityId, member, source, sourceEventId, 0, minted);
            return;
        }
        PendingAccrual[] storage q = _impactPending[communityId][member];
        if (q.length >= _QUEUE_MAX) revert QueueFull();
        uint64 base = sourceTimestamp == 0 ? uint64(block.timestamp) : sourceTimestamp;
        q.push(PendingAccrual({amount: uint128(attributedUsdc), mintAt: base + config.epochLength()}));
        emit ImpactAccrued(communityId, member, source, sourceEventId, attributedUsdc, minted);
    }

    /// Permissionless: roll any seasoned pending accruals for `member` into `U_i` / `U_C`.
    function pokeSeasoning(uint256 communityId, address member) external {
        _syncSeat(communityId, member);
        _roll(communityId, member);
    }

    /// Moves every ripe pending accrual (`block.timestamp >= mintAt`) into the seasoned totals
    /// and compacts the queue. Returns the amount minted this call.
    function _roll(uint256 communityId, address member) internal returns (uint256 minted) {
        PendingAccrual[] storage q = _impactPending[communityId][member];
        uint256 i;
        while (i < q.length) {
            if (block.timestamp >= q[i].mintAt) {
                minted += q[i].amount;
                q[i] = q[q.length - 1];
                q.pop();
            } else {
                i++;
            }
        }
        if (minted != 0) {
            _impactSeasoned[communityId][member] += minted;
            _impactSeasonedTotal[communityId] += minted;
            emit ImpactSeasoned(communityId, member, minted);
        }
    }

    /// Sum of the member's pending, not-yet-seasoned accruals.
    function _pendingImpactOf(uint256 communityId, address member) internal view returns (uint256 total) {
        if (!_seatCurrent(communityId, member)) return 0;
        PendingAccrual[] storage q = _impactPending[communityId][member];
        for (uint256 i; i < q.length; i++) {
            total += q[i].amount;
        }
    }

    /// `share_i = U_i / U_C` as a WAD. Zero when the community has no seasoned Units.
    function _shareWad(uint256 communityId, address member) internal view returns (uint256) {
        uint256 uc = _impactSeasonedTotal[communityId];
        if (uc == 0) return 0;
        return Math.mulDiv(_seasonedOf(communityId, member), WAD, uc); // floor
    }

    // ---- conduct_factor ----

    /// `1 - (t - 65d) / 90d` between Late entry and formal Default, then 0. Elapsed time only.
    /// A pure read of `config`; grouped with the write crossings because its
    /// only caller, `CreditCore._closeTab`, uses it to compute the value passed into
    /// `recordScar` immediately after.
    function conductDecayAt(uint256 elapsed) external view returns (uint256) {
        return _conductDecayAt(elapsed);
    }

    function _conductDecayAt(uint256 elapsed) internal view returns (uint256) {
        (, uint64 lateStart,, uint64 defaultRecoveryStart,) = config.stageBoundaries();
        return StandingMath.conductDecay(elapsed, lateStart, defaultRecoveryStart);
    }

    /// The healed value of one scar: it heals linearly from its frozen value to 1.0 over
    /// `STANDING_HEAL_WINDOW`.
    function _healedScar(Scar storage s) internal view returns (uint256) {
        return StandingMath.healRamp(s.frozenConductWad, block.timestamp - s.recordedAt, config.standingHealWindow());
    }

    function _deepestHealedScar(address member) internal view returns (uint256 deepest) {
        Scar[] storage list = _scars[member];
        deepest = WAD;
        for (uint256 i; i < list.length; i++) {
            uint256 v = _healedScar(list[i]);
            if (v < deepest) deepest = v; // deepest-wins
        }
    }

    function _anyUnhealedScar(address member) internal view returns (bool) {
        Scar[] storage list = _scars[member];
        uint256 hw = config.standingHealWindow();
        for (uint256 i; i < list.length; i++) {
            if (block.timestamp - list[i].recordedAt < hw) return true;
        }
        return false;
    }

    /// `min(the account-wide conduct floor, open-delinquency decay, deepest healed scar)`.
    /// `tab.elapsedSinceDraw` is `CreditCore`'s own live elapsed time, snapshotted at the call
    /// site: `tab.openInCommunity` false reproduces the pre-split "no open
    /// delinquency" WAD default exactly.
    function _conductFactor(uint256 communityId, address member, MemberTabSnapshot memory tab)
        internal
        view
        returns (uint256)
    {
        uint256 floor = _accountDefaulted[member] ? 0 : WAD;
        uint256 open = tab.openInCommunity ? _conductDecayAt(tab.elapsedSinceDraw) : WAD;
        uint256 scar = _deepestHealedScar(member);
        uint256 undisqualified = open < scar ? open : scar;
        return floor < undisqualified ? floor : undisqualified;
    }

    /// `CreditCore._closeTab` calls this on a full repayment during Late or Final Cure, passing
    /// the conduct value frozen at cure. Role-gated to `onlyCreditCore`:
    /// `CreditCore` is the only legitimate caller after the split, the same way it already was
    /// the only legitimate `onlyObligationLedger` caller before it.
    ///
    /// Scar bookkeeping must never fail a repayment, so this
    /// prunes every fully-healed scar before checking the length, and if the list is still full
    /// after pruning, records no scar and emits `ScarDropped` instead of reverting.
    function recordScar(uint256 communityId, address member, uint256 frozenConductWad) external onlyCreditCore {
        _recordScar(communityId, member, frozenConductWad);
    }

    /// The scar event, recorded or dropped, is what
    /// zeroes `te_earned`. Zeroing runs before the queue-full check so a dropped scar
    /// (the list still full after pruning) zeroes it exactly like a recorded one; the record
    /// itself is the only thing the queue can refuse room to.
    ///
    /// The scar goes on the account and reaches every community, while the
    /// Trust Extension wipe stays in `communityId`, where the scar happened. The
    /// events still name `communityId`, so where it happened stays on record.
    function _recordScar(uint256 communityId, address member, uint256 frozenConductWad) internal {
        _requireCommunity(communityId);
        if (frozenConductWad > WAD) revert ScarValueOutOfRange();
        _teEarned[communityId][member] = 0;
        Scar[] storage list = _scars[member];
        _pruneHealedScars(list);
        if (list.length >= _QUEUE_MAX) {
            emit ScarDropped(communityId, member, frozenConductWad);
            return;
        }
        list.push(Scar({frozenConductWad: uint128(frozenConductWad), recordedAt: uint64(block.timestamp)}));
        emit ScarRecorded(communityId, member, frozenConductWad);
    }

    function _pruneHealedScars(Scar[] storage list) internal {
        uint256 i;
        while (i < list.length) {
            if (_healedScar(list[i]) >= WAD) {
                list[i] = list[list.length - 1];
                list.pop();
            } else {
                i++;
            }
        }
    }

    // ---- activity_factor ----

    function _dormancyDecay(uint256 d) internal view returns (uint256) {
        return StandingMath.dormancyDecay(
            d, config.dormancyGrace(), config.activityDecayLength(), uint256(config.activityFloorBps()) * WAD / 10_000
        );
    }

    /// `min(dormancy decay from last activity, heal ramp from the value last re-engaged at)`.
    function _activityFactor(uint256 communityId, address member) internal view returns (uint256) {
        uint64 last = _seatCurrent(communityId, member) ? _lastActivityAt[communityId][member] : 0;
        if (last == 0) return WAD;
        uint256 decayVal = _dormancyDecay(block.timestamp - last);
        uint256 healVal = StandingMath.healRamp(
            _healFloorWad[communityId][member],
            block.timestamp - _healFloorAt[communityId][member],
            config.standingHealWindow()
        );
        return decayVal < healVal ? decayVal : healVal;
    }

    /// Qualifying activity: the Unit-minting set plus settling an obligation.
    function _noteActivity(uint256 communityId, address member) internal {
        uint256 cur = _activityFactor(communityId, member);
        _lastActivityAt[communityId][member] = uint64(block.timestamp);
        _healFloorWad[communityId][member] = cur < WAD ? cur : WAD;
        _healFloorAt[communityId][member] = uint64(block.timestamp);
    }

    // ---- Trust Extension ----

    /// Whether the member has an open delinquency in `communityId`, from the snapshot:
    /// open in this community AND at or past the Late boundary. Equivalent to the
    /// pre-split `stage >= Stage.Late`, since Late begins exactly at `lateStart` and
    /// `tab.openInCommunity` already excludes closed/written-off/wrong-community obligations the
    /// way the pre-split guard clause did.
    function _hasOpenDelinquency(MemberTabSnapshot memory tab) internal view returns (bool) {
        if (!tab.openInCommunity) return false;
        (, uint64 lateStart,,,) = config.stageBoundaries();
        return tab.elapsedSinceDraw >= lateStart;
    }

    /// `min(phase_budget(phase), te_earned)`, zero while any scar is still healing, and zero
    /// while an open delinquency exists (Trust Extension is removed the
    /// moment a delinquency enters Late).
    function _trustExtension(uint256 communityId, address member, MemberTabSnapshot memory tab)
        internal
        view
        returns (uint256)
    {
        if (_hasOpenDelinquency(tab)) return 0;
        if (_anyUnhealedScar(member)) return 0;
        (,, uint256 phaseBudget,) = config.phaseCaps(uint8(_phaseOf(communityId, member)));
        uint256 earned = _teEarnedOf(communityId, member);
        uint256 memberCap = phaseBudget < earned ? phaseBudget : earned;

        uint256 communityCap = _communityTeBudgetLocal(communityId);
        return memberCap < communityCap ? memberCap : communityCap;
    }

    /// `min(sum of phase budgets, TE_COMMUNITY_CAP_BPS x cumulative attributed funding yield)`
    /// is a local copy of `CreditCore._communityTeBudget`'s formula: that function also
    /// needs it directly inside `draw()`'s aggregate-cap check, which is why
    /// `communityAttributedYield` is exposed as a plain crossing rather than
    /// this whole formula being one; here it costs no cross-contract call, since
    /// `_communityAttributedYield` is this contract's own state.
    function _communityTeBudgetLocal(uint256 communityId) internal view returns (uint256) {
        (,, uint256 b1,) = config.phaseCaps(uint8(ICreditCore.Phase.ProvenOnce));
        (,, uint256 b2,) = config.phaseCaps(uint8(ICreditCore.Phase.Developing));
        (,, uint256 b3,) = config.phaseCaps(uint8(ICreditCore.Phase.Established));
        uint256 sumBudgets = b1 + b2 + b3;
        uint256 yieldCap = uint256(config.teCommunityCapBps()) * _communityAttributedYield[communityId] / 10_000;
        return sumBudgets < yieldCap ? sumBudgets : yieldCap;
    }

    function communityAttributedYield(uint256 communityId) external view returns (uint256) {
        return _communityAttributedYield[communityId];
    }

    /// `CreditCore._closeTab` credits Trust Extension earned on each completed obligation.
    /// Role-gated the same way `recordScar` is.
    function creditObligationCompletion(uint256 communityId, address member, uint256 teEarnIncrement)
        external
        onlyCreditCore
    {
        _creditObligationCompletion(communityId, member, teEarnIncrement);
    }

    function _creditObligationCompletion(uint256 communityId, address member, uint256 teEarnIncrement) internal {
        _requireCommunity(communityId);
        _syncSeat(communityId, member);
        uint256 n = ++_completedObligations[communityId][member];
        if (_firstObligationAt[communityId][member] == 0) {
            _firstObligationAt[communityId][member] = uint64(block.timestamp);
        }
        _noteActivity(communityId, member);
        emit ObligationCompleted(communityId, member, n);

        if (teEarnIncrement != 0 && !_anyUnhealedScar(member)) {
            uint256 total = _teEarned[communityId][member] + teEarnIncrement;
            _teEarned[communityId][member] = total;
            emit TrustExtensionEarned(communityId, member, teEarnIncrement, total);
        }
    }

    /// The yield path credits the community's cumulative attributed funding
    /// yield, which caps live Trust Extension exposure.
    function creditCommunityAttributedYield(uint256 communityId, uint256 amount) external onlyImpactAttributor {
        _requireCommunity(communityId);
        uint256 cumulative = _communityAttributedYield[communityId] + amount;
        _communityAttributedYield[communityId] = cumulative;
        emit CommunityAttributedYieldCredited(communityId, amount, cumulative);
    }

    // ---- phases ----

    function _phaseOf(uint256 communityId, address member) internal view returns (ICreditCore.Phase) {
        uint256 n = _completedOf(communityId, member);
        if (n == 0) return ICreditCore.Phase.FirstAccess;
        uint256 sinceFirst = block.timestamp - _firstObligationAt[communityId][member];
        (,,, uint64 minEstablished) = config.phaseCaps(uint8(ICreditCore.Phase.Established));
        (,,, uint64 minProven) = config.phaseCaps(uint8(ICreditCore.Phase.ProvenOnce));
        if (n >= 6 && sinceFirst >= minEstablished) return ICreditCore.Phase.Established;
        if (n >= 2) return ICreditCore.Phase.Developing;
        if (n >= 1 && sinceFirst >= minProven) return ICreditCore.Phase.ProvenOnce;
        return ICreditCore.Phase.FirstAccess;
    }

    // ---- the Line ----

    function _impactBudgetFromSnapshot(CommunityLedgerSnapshot memory snap) internal view returns (uint256) {
        (uint256 perCommunityBuffer,) = config.operatingRequirement();
        uint256 sub = perCommunityBuffer + config.minLendable();
        uint256 liquid = snap.allocation > snap.outstandingPrincipal ? snap.allocation - snap.outstandingPrincipal : 0;
        return liquid > sub ? liquid - sub : 0;
    }

    function communityImpactBudget(uint256, CommunityLedgerSnapshot calldata snap) external view returns (uint256) {
        return _impactBudgetFromSnapshot(snap);
    }

    /// `min(EXPOSURE_IMPACT_MULT x total realized attributable impact + te_earned,
    /// GLOBAL_MEMBER_CAP)`, account-wide across every Community.
    function _accountExposureCap(address member) internal view returns (uint256) {
        (uint256 impact, uint256 teEarned) = _accountTotals(member);
        uint256 val = impact * config.exposureImpactMultX100() / 100 + teEarned;
        uint256 cap = config.globalMemberCap();
        return val < cap ? val : cap;
    }

    function _impactBaseFromSnapshots(
        uint256 communityId,
        address member,
        CommunityLedgerSnapshot memory communitySnap,
        MemberTabSnapshot memory tabSnap
    ) internal view returns (uint256 base) {
        base = Math.mulDiv(_impactBudgetFromSnapshot(communitySnap), _shareWad(communityId, member), WAD);
        base = Math.mulDiv(base, _activityFactor(communityId, member), WAD);
        base = Math.mulDiv(base, _conductFactor(communityId, member, tabSnap), WAD);
    }

    function impactBase(
        uint256 communityId,
        address member,
        CommunityLedgerSnapshot calldata communitySnap,
        MemberTabSnapshot calldata tabSnap
    ) external view returns (uint256) {
        return _impactBaseFromSnapshots(communityId, member, communitySnap, tabSnap);
    }

    function _min(uint256 a, uint256 b) internal pure returns (uint256) {
        return a < b ? a : b;
    }

    /// Whether the member has ever drawn in this community on the seat they hold now: this
    /// contract's own `_completedObligations`, so it needs no snapshot from `CreditCore`.
    function _hasEverDrawn(uint256 communityId, address member) internal view returns (bool) {
        return _completedOf(communityId, member) > 0;
    }

    /// The Line: `(drawable, eligible)`.
    function line(
        uint256 communityId,
        address member,
        CommunityLedgerSnapshot calldata communitySnap,
        MemberTabSnapshot calldata tabSnap
    ) external view returns (uint256 drawable, bool eligible) {
        // Formal Default disqualifies the account everywhere, not only in the community
        // where the default happened.
        if (_preDefaultDisqualified[member] || _accountDefaulted[member]) return (0, false);

        uint256 budget = _impactBudgetFromSnapshot(communitySnap);
        uint256 base = _impactBaseFromSnapshots(communityId, member, communitySnap, tabSnap);
        (uint256 phaseLineCap, uint16 concentrationBps,,) = config.phaseCaps(uint8(_phaseOf(communityId, member)));
        uint256 minLend = config.minLendable();

        drawable = base + _trustExtension(communityId, member, tabSnap);
        drawable = _min(drawable, _accountExposureCap(member));
        drawable = _min(drawable, uint256(concentrationBps) * budget / 10_000);
        drawable = _min(drawable, phaseLineCap);
        drawable = _min(drawable, config.globalMemberCap());
        drawable = _min(drawable, budget);

        if (!_hasEverDrawn(communityId, member)) {
            uint256 cap = _accountExposureCap(member);
            uint256 exp = tabSnap.openAnywhere ? tabSnap.principal : 0;
            (uint256 firstAccessCap,,,) = config.phaseCaps(uint8(ICreditCore.Phase.FirstAccess));
            uint256 firstLine = _min(_min(base, minLend), _min(budget, cap > exp ? cap - exp : 0));
            drawable = _min(drawable, _min(firstLine, firstAccessCap));
        }

        eligible = drawable >= minLend;
    }

    /// Marks a member's pre-Default Impact Units disqualified at formal Default.
    /// The Units stay counted in `U_C`; the member's own Line goes to zero.
    /// Retired as an external, operator-callable entry point. The only
    /// legitimate caller was `CreditCore`, which never called it (the gate was repointed
    /// but no call site was left), so the entry point let an operator hand-disqualify a
    /// member's Impact Units with no formal Default having crossed and no appeal path, the same
    /// discretionary punitive power already refused to the screener. Formal Default still
    /// reaches this internal path through `_recordFormalDefault`, unchanged.
    function _disqualifyPreDefaultUnits(uint256 communityId, address member) internal {
        _requireCommunity(communityId);
        _preDefaultDisqualified[member] = true;
        emit PreDefaultUnitsDisqualified(communityId, member);
    }

    /// Formal Default's permanent consequences, recorded together, once, account-wide.
    /// Idempotent: safe to call again if the 155-day crossing was skipped between touches. Needs
    /// no snapshot: every field it touches (`_preDefaultDisqualified`, `_accountDefaulted`) is
    /// this contract's own state.
    function recordFormalDefault(uint256 communityId, address member) external onlyCreditCore {
        _recordFormalDefault(communityId, member);
    }

    function _recordFormalDefault(uint256 communityId, address member) internal {
        _disqualifyPreDefaultUnits(communityId, member);
        if (!_accountDefaulted[member]) {
            _accountDefaulted[member] = true;
            emit AccountDefaulted(member);
        }
    }

    function isAccountDefaulted(address member) external view returns (bool) {
        return _accountDefaulted[member];
    }
}
