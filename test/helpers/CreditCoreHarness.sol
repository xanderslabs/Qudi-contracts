// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.30;

import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {CreditCore} from "../../src/CreditCore.sol";
import {ICreditStanding} from "../../src/interfaces/ICreditStanding.sol";
import {IConfig} from "../../src/interfaces/IConfig.sol";

/// `CreditCore` with the debt seams driven from test storage. `_stageOutstanding` and
/// `_communityHasUnresolvedDebt` are `virtual` on `CreditCore` precisely so a test can feed a
/// non-zero book and unresolved debt through the same seam the debt ledger uses; this harness is
/// that feed. It adds no production logic.
///
/// The Standing-side overrides and read wrappers (`setCommunityLiquid`,
/// `setOpenDelinquencyConduct`, `setHasEverDrawn`, `setMemberExposure`, `setOpenDelinquency`,
/// `line`, `impactBase`, `conductFactor`, `trustExtension`, `phaseOf`, `primeImpact`, ...) moved
/// to `CreditStandingHarness`: they exercise `CreditStanding`'s own
/// storage and formulas, which this contract no longer holds.
contract CreditCoreHarness is CreditCore {
    uint256 internal _bookCurrent;
    uint256 internal _bookLate;
    uint256 internal _bookFinalCure;
    uint256 internal _bookDefaultRecovery;
    bool internal _bookSet;
    uint256 internal _pending;
    mapping(uint256 => bool) internal _debt;
    mapping(uint256 => bool) internal _debtSet;

    constructor(
        IERC20 usdc_,
        IConfig config_,
        address factory_,
        address owner_,
        address treasuryManager_,
        address allocationMultisig_,
        ICreditStanding standing_
    ) CreditCore(usdc_, config_, factory_, owner_, treasuryManager_, allocationMultisig_, standing_) {}

    function setBook(uint256 current, uint256 late, uint256 finalCure, uint256 defaultRecovery) external {
        _bookCurrent = current;
        _bookLate = late;
        _bookFinalCure = finalCure;
        _bookDefaultRecovery = defaultRecovery;
        _bookSet = true;
    }

    function setPendingObligationReserve(uint256 v) external {
        _pending = v;
    }

    function setCommunityDebt(uint256 communityId, bool has) external {
        _debt[communityId] = has;
        _debtSet[communityId] = true;
    }

    /// The fixed synthetic book when `setBook` was called (Standing-formula
    /// tests); otherwise the real per-obligation ledger `CreditCore` maintains.
    function _stageOutstanding()
        internal
        view
        override
        returns (uint256 current, uint256 late, uint256 finalCure, uint256 defaultRecovery)
    {
        if (_bookSet) return (_bookCurrent, _bookLate, _bookFinalCure, _bookDefaultRecovery);
        return super._stageOutstanding();
    }

    function _reservedClaimableObligations() internal view override returns (uint256) {
        return _pending;
    }

    function _communityHasUnresolvedDebt(uint256 communityId) internal view override returns (bool) {
        if (_debtSet[communityId]) return _debt[communityId];
        return super._communityHasUnresolvedDebt(communityId);
    }

    /// Test read of the debt seam's current value.
    function communityHasUnresolvedDebt(uint256 communityId) external view returns (bool) {
        return _communityHasUnresolvedDebt(communityId);
    }

    // ---- exposure wrappers for views moved from CreditCore's external ABI to internal
    // helpers to save bytecode. Each wrapper reproduces the exact earlier
    // signature so the test suite exercising the underlying math needs no changes; it adds no
    // production logic and its bytecode is never deployed outside tests.

    function agreementOf(address m) external view returns (bool accepted, bytes32 agreementHash) {
        return (_agreementAccepted[m], _agreementHash[m]);
    }

    // ---- convenience wrappers over the real Standing crossings, composing the live snapshot from
    // this contract's own current storage exactly the way `draw`/`standingOf` do. Distinct from
    // `CreditStandingHarness`'s override-driven wrappers of the same names: these always reflect
    // the real drawn/settled state, never a synthetic value. ----

    function line(uint256 c, address m) external view returns (uint256 drawable, bool eligible) {
        return standing.line(c, m, _communitySnapshot(c), _tabSnapshot(c, m));
    }

    /// A pass-through to the real `_tabSnapshot`, so a test that needs a
    /// `MemberTabSnapshot` for `m`'s live obligation calls production to build it instead of
    /// reimplementing `_tabSnapshot`'s body a second time (the `_liveTabSnapshot` defect,
    /// `test/CreditCoreDebt.t.sol`, closed by this accessor).
    function tabSnapshot(uint256 c, address m) external view returns (ICreditStanding.MemberTabSnapshot memory) {
        return _tabSnapshot(c, m);
    }

    function impactBase(uint256 c, address m) external view returns (uint256) {
        return standing.impactBase(c, m, _communitySnapshot(c), _tabSnapshot(c, m));
    }

    function communityImpactBudget(uint256 c) external view returns (uint256) {
        return standing.communityImpactBudget(c, _communitySnapshot(c));
    }

    function totalOutstandingPrincipal() external view returns (uint256 total) {
        total = _stageBucket[0] + _stageBucket[1] + _stageBucket[2] + _stageBucket[3];
    }

    function outstandingPrincipalOf(uint256 c) external view returns (uint256) {
        return _outstandingPrincipalOf[c];
    }

    function openObligationCountOf(uint256 c) external view returns (uint256) {
        return _openObligationCount[c];
    }

    function stageOutstanding()
        external
        view
        returns (uint256 current, uint256 late, uint256 finalCure, uint256 defaultRecovery)
    {
        return _stageOutstanding();
    }

    function teLiveOf(uint256 c) external view returns (uint256) {
        return _teLiveOf[c];
    }

    function communityTeBudget(uint256 c) external view returns (uint256) {
        return _communityTeBudget(c);
    }

    function currentStage(address m) external view returns (Stage) {
        return _currentStage(_tab[m]);
    }

    function perVenueCap() external view returns (uint256) {
        return _perVenueCap();
    }

    function venueExposure(address venue) external view returns (uint256) {
        return _venueExposureOf(venue);
    }

    function venues(uint256 i) external view returns (address) {
        return _venues[i];
    }

    function venueCount() external view returns (uint256) {
        return _venues.length;
    }

    function largestVenueExposure() external view returns (uint256) {
        return _largestVenueExposure();
    }

    function totalVenueExposure() external view returns (uint256) {
        return _totalVenueExposure();
    }

    function venueAllocationCap() external view returns (uint256) {
        return _venueAllocationCap();
    }

    function requiredRetainedCapital() external view returns (uint256) {
        return _requiredRetainedCapital();
    }

    function unallocated() external view returns (uint256) {
        return _unallocated();
    }

    function surplus() external view returns (int256) {
        return _surplus();
    }

    function isCommunityClosed(uint256 c) external view returns (bool) {
        return _closed[c];
    }

    function allocationOf(uint256 c) external view returns (uint256) {
        return _allocationOf[c];
    }

    function totalAllocated() external view returns (uint256) {
        return _totalAllocated;
    }
}
