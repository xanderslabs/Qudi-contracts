// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.30;

import {Math} from "openzeppelin-contracts/contracts/utils/math/Math.sol";
import {Ownable2Step, Ownable} from "openzeppelin-contracts/contracts/access/Ownable2Step.sol";
import {ICreditStanding} from "./interfaces/ICreditStanding.sol";
import {ICreditCore} from "./interfaces/ICreditCore.sol";
import {IConfig} from "./interfaces/IConfig.sol";
import {ICommunityFactory} from "./interfaces/ICommunityFactory.sol";
import {ICommunity} from "./interfaces/ICommunity.sol";
import {ISeats} from "./interfaces/ISeats.sol";
import {IImpactSource} from "./interfaces/IImpactSource.sol";
import {StandingMath} from "./StandingMath.sol";

/// Read-only shape of `CreditCore`'s wiring immutables, declared here rather than importing
/// `CreditCore.sol`, which would make the two files import each other. Used only at `setCreditCore`.
interface ICreditCoreWiring {
    function factory() external view returns (address);
    function config() external view returns (address);
    function standing() external view returns (address);
}

/// The factory's `Seats`, which the default snapshot walks to find every community a member is
/// seated in.
interface IFactorySeats {
    function seats() external view returns (ISeats);
}

/// A member's standing, and the line it adds up to. No money moves here.
///
/// **Impact** comes from the products listed in the registry. Each answers
/// `impactOf(communityId, member)` and the line sums them, so a new product starts counting the
/// moment the timelock lists it, with no change to this contract or `CreditCore`. A member counts
/// impact only in a community where they hold an Active seat.
///
/// **The line** is the smallest of four limits: effective impact in this community times the phase
/// multiplier, activity and conduct; the phase cap; a share of what the community can lend now; and
/// the member cap.
///
/// **Phases** come from advances repaid in full, counted across every community.
///
/// **A default** is account-wide. It zeroes conduct and disqualifies the impact the member held at
/// that moment in every community they are seated in. Repaid in full, it heals after a cooling
/// period and the member starts again at First Access; the disqualified impact stays disqualified.
/// Unrepaid, it never heals.
///
/// **Conduct and activity** follow the decay principle: a slow, visible fade that stops when its
/// cause stops and heals back over time. A repayment after Late leaves a scar at the conduct value
/// of that moment, account-wide, which heals over the heal window. A member's own activity fades
/// after a grace with no deposit, paid seat mint or repayment, down to a floor, never to zero.
///
/// `CreditStanding` never calls `CreditCore`: where the line needs the pool's state, `CreditCore`
/// passes a snapshot in. `creditCore` is the only caller of the four `record` functions, wired once.
contract CreditStanding is ICreditStanding, Ownable2Step {
    IConfig public immutable config;
    address public immutable factory;

    address public override creditCore;

    uint256 internal constant WAD = 1e18;
    uint256 internal constant _QUEUE_MAX = 64;

    struct Scar {
        uint128 frozenConductWad; // conduct value at the moment of cure
        uint64 recordedAt;
    }

    address[] internal _sources;
    mapping(address => bool) internal _isSource;

    /// Account-held: a scar follows the member into every community, now and later.
    mapping(address => Scar[]) internal _scars;
    /// Advances repaid in full, account-wide, and when the first of them was. Both restart when a
    /// default is repaid.
    mapping(address => uint256) internal _repaid;
    mapping(address => uint64) internal _firstRepaidAt;
    /// A default, account-wide. It lasts until `_healsAt`, which stays 0 until the defaulted advance
    /// is repaid in full.
    mapping(address => bool) internal _defaulted;
    mapping(address => uint64) internal _healsAt;
    /// Impact held at a default, per community. Never cleared.
    mapping(uint256 => mapping(address => uint256)) internal _disqualified;

    /// The member's own activity in a community: when they last deposited, paid for a seat or
    /// repaid, and the value it heals from.
    mapping(uint256 => mapping(address => uint64)) internal _lastActivityAt;
    mapping(uint256 => mapping(address => uint256)) internal _healFloorWad;
    mapping(uint256 => mapping(address => uint64)) internal _healFloorAt;
    /// The token id of the seat the activity record was written under. A different seat, or none,
    /// clears it before the next write.
    mapping(uint256 => mapping(address => uint256)) internal _seatStamp;

    modifier onlyCreditCore() {
        if (msg.sender != creditCore) revert NotCreditCore();
        _;
    }

    constructor(IConfig config_, address factory_, address owner_) Ownable(owner_) {
        if (address(config_) == address(0) || factory_ == address(0)) revert ZeroAddress();
        config = config_;
        factory = factory_;
    }

    /// One-way. `CreditCore` takes this contract's address at construction, so it can only be
    /// wired here afterwards. The pair must share a factory and a config, and `CreditCore` must
    /// point back at this contract, or standing and debt would be computed against different
    /// worlds with nothing to catch it.
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

    // ---- the impact registry ----

    /// The timelock lists a product. Its figures count toward every line from this block.
    function addImpactSource(address source) external onlyOwner {
        if (source == address(0)) revert ZeroAddress();
        if (_isSource[source]) revert DuplicateImpactSource();
        _isSource[source] = true;
        _sources.push(source);
        emit ImpactSourceAdded(source);
    }

    function removeImpactSource(address source) external onlyOwner {
        if (!_isSource[source]) revert UnknownImpactSource();
        _isSource[source] = false;
        uint256 n = _sources.length;
        for (uint256 i; i < n; i++) {
            if (_sources[i] == source) {
                _sources[i] = _sources[n - 1];
                _sources.pop();
                break;
            }
        }
        emit ImpactSourceRemoved(source);
    }

    function impactSources() external view returns (address[] memory) {
        return _sources;
    }

    /// The member's Active seat in the community, or 0. Impact counts only while this is non-zero,
    /// whatever a source answers, so a source that forgets the seat cannot lend to someone who
    /// has left or been removed.
    function _liveSeat(uint256 communityId, address member) internal view returns (uint256) {
        return ICommunity(ICommunityFactory(factory).communityAt(communityId)).activeTokenOf(member);
    }

    /// Every source's figure, summed. A source that reverts counts 0: one broken product must not
    /// stop every draw, or the default a repayment has to record first.
    function _heldImpact(uint256 communityId, address member) internal view returns (uint256 total) {
        if (_liveSeat(communityId, member) == 0) return 0;
        uint256 n = _sources.length;
        for (uint256 i; i < n; i++) {
            try IImpactSource(_sources[i]).impactOf(communityId, member) returns (uint256 v) {
                total += v;
            } catch {}
        }
    }

    function _effectiveImpact(uint256 communityId, address member) internal view returns (uint256) {
        uint256 held = _heldImpact(communityId, member);
        uint256 disqualified = _disqualified[communityId][member];
        return held > disqualified ? held - disqualified : 0;
    }

    function impactOf(uint256 communityId, address member) external view returns (uint256) {
        _requireCommunity(communityId);
        return _effectiveImpact(communityId, member);
    }

    function disqualifiedImpactOf(uint256 communityId, address member) external view returns (uint256) {
        return _disqualified[communityId][member];
    }

    // ---- the seat stamp, for the member's activity record ----

    function _seatCurrent(uint256 communityId, address member) internal view returns (bool) {
        uint256 live = _liveSeat(communityId, member);
        return live != 0 && _seatStamp[communityId][member] == live;
    }

    /// Runs before every write to the activity record. A different seat starts from nothing.
    function _syncSeat(uint256 communityId, address member) internal {
        uint256 live = _liveSeat(communityId, member);
        if (_seatStamp[communityId][member] == live) return;
        _seatStamp[communityId][member] = live;
        delete _lastActivityAt[communityId][member];
        delete _healFloorWad[communityId][member];
        delete _healFloorAt[communityId][member];
    }

    // ---- conduct ----

    /// 1 until Late, then falling linearly to 0 at Default Recovery. Elapsed time only.
    function conductDecayAt(uint256 elapsed) external view returns (uint256) {
        return _conductDecayAt(elapsed);
    }

    function _conductDecayAt(uint256 elapsed) internal view returns (uint256) {
        (, uint64 lateStart,, uint64 defaultRecoveryStart,) = config.stageBoundaries();
        return StandingMath.conductDecay(elapsed, lateStart, defaultRecoveryStart);
    }

    /// A scar heals linearly from its frozen value to 1 over `STANDING_HEAL_WINDOW`.
    function _healedScar(Scar storage s) internal view returns (uint256) {
        return StandingMath.healRamp(s.frozenConductWad, block.timestamp - s.recordedAt, config.standingHealWindow());
    }

    /// The deepest scar wins; scars never stack.
    function _deepestHealedScar(address member) internal view returns (uint256 deepest) {
        Scar[] storage list = _scars[member];
        deepest = WAD;
        for (uint256 i; i < list.length; i++) {
            uint256 v = _healedScar(list[i]);
            if (v < deepest) deepest = v;
        }
    }

    /// `min(0 while defaulted else 1, the open advance's decay in this community, the deepest scar)`.
    function _conductFactor(address member, MemberTabSnapshot memory tab) internal view returns (uint256) {
        uint256 floor = _isDefaulted(member) ? 0 : WAD;
        uint256 open = tab.openInCommunity ? _conductDecayAt(tab.elapsedSinceDraw) : WAD;
        uint256 scar = _deepestHealedScar(member);
        uint256 undisqualified = open < scar ? open : scar;
        return floor < undisqualified ? floor : undisqualified;
    }

    /// A repayment after Late. Scar bookkeeping must never fail a repayment, so fully healed scars
    /// are pruned first, and if the list is still full the scar is dropped with an event instead of
    /// reverting.
    function recordScar(uint256 communityId, address member, uint256 frozenConductWad) external onlyCreditCore {
        if (frozenConductWad > WAD) revert ScarValueOutOfRange();
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

    // ---- the member's activity ----

    /// `min(decay since the last activity, heal from the value it was at then)`. A member with no
    /// activity yet in this community on this seat has nothing to fade from.
    function _activityFactor(uint256 communityId, address member) internal view returns (uint256) {
        uint64 last = _seatCurrent(communityId, member) ? _lastActivityAt[communityId][member] : 0;
        if (last == 0) return WAD;
        uint256 decayVal = StandingMath.dormancyDecay(
            block.timestamp - last,
            config.dormancyGrace(),
            config.activityDecayLength(),
            uint256(config.activityFloorBps()) * WAD / 10_000
        );
        uint256 healVal = StandingMath.healRamp(
            _healFloorWad[communityId][member],
            block.timestamp - _healFloorAt[communityId][member],
            config.standingHealWindow()
        );
        return decayVal < healVal ? decayVal : healVal;
    }

    function _noteActivity(uint256 communityId, address member) internal {
        uint256 cur = _activityFactor(communityId, member);
        _lastActivityAt[communityId][member] = uint64(block.timestamp);
        _healFloorWad[communityId][member] = cur < WAD ? cur : WAD;
        _healFloorAt[communityId][member] = uint64(block.timestamp);
    }

    /// A deposit or a paid seat mint in the community keeps the member's own activity fresh there,
    /// as a repayment does.
    function recordActivity(uint256 communityId, address member) external onlyCreditCore {
        _syncSeat(communityId, member);
        _noteActivity(communityId, member);
    }

    // ---- phases ----

    /// An advance repaid in full before its default. It counts toward the phase in every community
    /// and is activity in the one it was drawn in.
    function recordRepaid(uint256 communityId, address member) external onlyCreditCore {
        _syncSeat(communityId, member);
        uint256 n = ++_repaid[member];
        if (_firstRepaidAt[member] == 0) _firstRepaidAt[member] = uint64(block.timestamp);
        _noteActivity(communityId, member);
        emit AdvanceRepaid(communityId, member, n);
    }

    function _phaseOf(address member) internal view returns (ICreditCore.Phase) {
        uint256 n = _repaid[member];
        if (n == 0) return ICreditCore.Phase.FirstAccess;
        uint256 sinceFirst = block.timestamp - _firstRepaidAt[member];
        (,, uint64 minEstablished) = config.phaseTerms(uint8(ICreditCore.Phase.Established));
        (,, uint64 minProven) = config.phaseTerms(uint8(ICreditCore.Phase.ProvenOnce));
        if (n >= 6 && sinceFirst >= minEstablished) return ICreditCore.Phase.Established;
        if (n >= 2) return ICreditCore.Phase.Developing;
        if (sinceFirst >= minProven) return ICreditCore.Phase.ProvenOnce;
        return ICreditCore.Phase.FirstAccess;
    }

    function phaseOf(address member) external view returns (ICreditCore.Phase) {
        return _phaseOf(member);
    }

    function repaidOf(address member) external view returns (uint256 count, uint64 firstAt) {
        return (_repaid[member], _firstRepaidAt[member]);
    }

    // ---- default ----

    function _isDefaulted(address member) internal view returns (bool) {
        uint64 healsAt = _healsAt[member];
        return _defaulted[member] && (healsAt == 0 || block.timestamp < healsAt);
    }

    function isAccountDefaulted(address member) external view returns (bool) {
        return _isDefaulted(member);
    }

    function defaultHealsAt(address member) external view returns (uint64) {
        return _isDefaulted(member) ? _healsAt[member] : 0;
    }

    /// Formal default, once per default. Snapshots the impact the member holds now in every
    /// community they are seated in as disqualified: `Seats` holds one seat per community per
    /// wallet, so the walk is bounded by the communities the member has joined.
    function recordFormalDefault(uint256, address member) external onlyCreditCore {
        if (_isDefaulted(member)) return;
        _defaulted[member] = true;
        _healsAt[member] = 0;
        emit AccountDefaulted(member);

        ISeats seats = IFactorySeats(factory).seats();
        uint256 n = seats.balanceOf(member);
        for (uint256 i; i < n; i++) {
            uint256 c = seats.seatInfo(seats.tokenOfOwnerByIndex(member, i)).communityId;
            uint256 held = _heldImpact(c, member);
            if (held > _disqualified[c][member]) {
                _disqualified[c][member] = held;
                emit ImpactDisqualified(c, member, held);
            }
        }
    }

    /// The defaulted advance is repaid in full. The cooling starts now, and the repaid count
    /// restarts: nothing else can be repaid while the default lasts, because a defaulted member
    /// cannot draw, so restarting it now and at the heal are the same.
    function recordDefaultRepaid(address member) external onlyCreditCore {
        if (!_isDefaulted(member) || _healsAt[member] != 0) return;
        uint64 healsAt = uint64(block.timestamp) + config.defaultHealCooling();
        _healsAt[member] = healsAt;
        _repaid[member] = 0;
        _firstRepaidAt[member] = 0;
        emit DefaultRepaid(member, healsAt);
    }

    // ---- the line ----

    function _min(uint256 a, uint256 b) internal pure returns (uint256) {
        return a < b ? a : b;
    }

    /// `(drawable, eligible)`. Every division rounds down, so a member is never shown more than the
    /// exact figure.
    function line(
        uint256 communityId,
        address member,
        CommunityLedgerSnapshot calldata communitySnap,
        MemberTabSnapshot calldata tabSnap
    ) external view returns (uint256 drawable, bool eligible) {
        if (_isDefaulted(member)) return (0, false);
        (uint256 multiplier, uint256 phaseCap,) = config.phaseTerms(uint8(_phaseOf(member)));

        drawable = _effectiveImpact(communityId, member) * multiplier / 100;
        drawable = Math.mulDiv(drawable, _activityFactor(communityId, member), WAD);
        drawable = Math.mulDiv(drawable, _conductFactor(member, tabSnap), WAD);
        drawable = _min(drawable, phaseCap);
        drawable = _min(drawable, communitySnap.lendable * config.concentrationBps() / 10_000);
        drawable = _min(drawable, config.globalMemberCap());

        eligible = drawable >= config.minLendable() && !tabSnap.openAnywhere;
    }
}
