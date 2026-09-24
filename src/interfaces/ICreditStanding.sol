// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {ICreditCore} from "./ICreditCore.sol";

/// A member's standing: impact from the registered sources, the phase their repaid advances have
/// reached, conduct and scars, their own activity, a default and its heal, and the line all of it
/// adds up to. No money moves here.
///
/// `CreditStanding` never calls `CreditCore`. Where the line needs the pool's state, `CreditCore`
/// passes a snapshot of its own storage in.
interface ICreditStanding {
    /// What the community can lend now: its unlent balance after the dormancy fade.
    struct CommunityLedgerSnapshot {
        uint256 lendable;
    }

    /// The member's advance as `CreditCore` sees it. `openInCommunity` and `elapsedSinceDraw` are
    /// for an advance drawn in the community asked about, which lowers conduct once it is Late.
    /// `openAnywhere` is any advance on the account that is not repaid, written off or not.
    struct MemberTabSnapshot {
        bool openInCommunity;
        uint64 elapsedSinceDraw;
        bool openAnywhere;
        uint256 principal;
    }

    event CreditCoreSet(address indexed creditCore);
    event ImpactSourceAdded(address indexed source);
    event ImpactSourceRemoved(address indexed source);
    event ScarRecorded(uint256 indexed communityId, address indexed member, uint256 frozenConductWad);
    event ScarDropped(uint256 indexed communityId, address indexed member, uint256 attemptedConductWad);
    event AdvanceRepaid(uint256 indexed communityId, address indexed member, uint256 repaidCount);
    /// A formal default, recorded once per default. The impact the member held in each community
    /// they were seated in is disqualified from then on.
    event AccountDefaulted(address indexed member);
    event ImpactDisqualified(uint256 indexed communityId, address indexed member, uint256 amount);
    /// The defaulted advance was repaid in full. The default heals at `healsAt`.
    event DefaultRepaid(address indexed member, uint64 healsAt);

    error NotCreditCore();
    error ScarValueOutOfRange();
    error ZeroAddress();
    error UnknownCommunity();
    error DuplicateImpactSource();
    error UnknownImpactSource();
    /// `setCreditCore` called a second time: the wiring is one-way.
    error CreditCoreAlreadySet();
    /// `setCreditCore` with a `CreditCore` wired to another factory or config.
    error CreditCoreMismatch();
    /// `setCreditCore` with a `CreditCore` whose `standing()` is not this contract.
    error CreditCoreStandingMismatch();

    /// Owner only, once.
    function setCreditCore(address creditCore_) external;
    function creditCore() external view returns (address);

    // ---- the impact registry ----

    /// Owner only (the timelock). Lists a product whose `impactOf` counts toward every line.
    function addImpactSource(address source) external;
    function removeImpactSource(address source) external;
    function impactSources() external view returns (address[] memory);
    /// Effective impact: the sum over every source, less what a default disqualified, floored at 0.
    /// Zero unless the member holds an Active seat in the community.
    function impactOf(uint256 communityId, address member) external view returns (uint256);
    function disqualifiedImpactOf(uint256 communityId, address member) external view returns (uint256);

    // ---- the line ----

    function requireCommunity(uint256 communityId) external view;
    /// `(drawable, eligible)`. Eligible means a line of at least `MIN_LENDABLE`, no advance open
    /// anywhere, and no default.
    function line(
        uint256 communityId,
        address member,
        CommunityLedgerSnapshot calldata communitySnap,
        MemberTabSnapshot calldata tabSnap
    ) external view returns (uint256 drawable, bool eligible);
    function phaseOf(address member) external view returns (ICreditCore.Phase);
    /// Advances repaid in full since the account started or last healed from a default, and when
    /// the first of them was.
    function repaidOf(address member) external view returns (uint256 count, uint64 firstAt);
    function isAccountDefaulted(address member) external view returns (bool);
    /// When a repaid default heals, or 0 while it is unrepaid (or there is none).
    function defaultHealsAt(address member) external view returns (uint64);
    /// Conduct at `elapsed` seconds after the draw: 1 until Late, falling to 0 at Default Recovery.
    function conductDecayAt(uint256 elapsed) external view returns (uint256);

    // ---- what `CreditCore` records ----

    /// A repayment made after Late: the conduct value at that moment, which heals from there.
    function recordScar(uint256 communityId, address member, uint256 frozenConductWad) external;
    /// A deposit or a paid seat mint by the member in the community: their own activity there.
    function recordActivity(uint256 communityId, address member) external;
    /// An advance repaid in full before its default: one more toward the member's phase.
    function recordRepaid(uint256 communityId, address member) external;
    /// Formal default. Idempotent while the default lasts.
    function recordFormalDefault(uint256 communityId, address member) external;
    /// The defaulted advance is repaid in full, before or after write-off. Starts the cooling.
    function recordDefaultRepaid(address member) external;
}
