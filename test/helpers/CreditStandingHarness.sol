// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.30;

import {CreditStanding} from "../../src/CreditStanding.sol";
import {ICreditCore} from "../../src/interfaces/ICreditCore.sol";
import {IConfig} from "../../src/interfaces/IConfig.sol";

/// `CreditStanding` with the snapshot seams driven from test storage.
///
/// **every accessor here is a pass-through to the deployed function, or it does
/// not exist.** None of `line`, `impactBase`, `conductFactor`, `trustExtension` or
/// `communityImpactBudget` reimplements the clamp chain, the Trust Extension formula, or the
/// budget formula: each builds a `CommunityLedgerSnapshot`/`MemberTabSnapshot` from the override
/// mappings below and calls the real, inherited, deployed function with it, exactly the shape
/// `CreditCore` itself uses. Where the production function takes no snapshot
/// (`_conductFactor`/`_trustExtension`'s 3-argument form already existed for this purpose), the
/// call goes straight to it. Its predecessor hand-copied these five formulas, so the Standing
/// suite and the Standing invariant campaign asserted against a test copy, and two money bounds
/// could be deleted from the deployed `CreditStanding.line` with the suite green. Every
/// clamp-chain bound now fails a test when deleted from this file's `super` calls.
contract CreditStandingHarness is CreditStanding {
    mapping(uint256 => mapping(address => bool)) internal _tabOpenInCommunity;
    mapping(uint256 => mapping(address => uint64)) internal _tabElapsed;
    mapping(uint256 => mapping(address => bool)) internal _tabOpenAnywhere;
    mapping(uint256 => mapping(address => uint256)) internal _tabPrincipal;
    mapping(uint256 => uint256) internal _liquidOverride;
    mapping(uint256 => bool) internal _liquidSet;

    constructor(IConfig config_, address factory_, address owner_) CreditStanding(config_, factory_, owner_) {}

    /// The override IS the liquid-cash figure directly (matching the pre-split
    /// `_communityLiquidCash` override), so it is handed to the real `communityImpactBudget` as
    /// an `allocation` with zero `outstandingPrincipal`: the subtraction inside that function
    /// then reproduces exactly the override value.
    function setCommunityLiquid(uint256 c, uint256 v) external {
        _liquidOverride[c] = v;
        _liquidSet[c] = true;
    }

    /// Sets the member's obligation as open in `c`, `elapsedSinceDraw` seconds past draw. Takes
    /// elapsed time, not a conduct WAD (the pre-split harness took a WAD and stored it as an
    /// arbitrary, formula-bypassing override; the real `MemberTabSnapshot` only carries elapsed
    /// time, so a test wanting a specific decayed value passes the elapsed time that produces
    /// it, the same way `CreditCore` itself only ever has elapsed time to offer).
    function setOpenDelinquencyConduct(uint256 c, address m, uint256 elapsedSinceDraw) external {
        _tabOpenInCommunity[c][m] = true;
        _tabElapsed[c][m] = uint64(elapsedSinceDraw);
    }

    /// Convenience over `setOpenDelinquencyConduct`: `true` sets elapsed exactly to the Late
    /// boundary (delinquent, and conduct decay is still exactly WAD there, since the decay
    /// function's own domain starts past that instant), `false` clears the override.
    function setOpenDelinquency(uint256 c, address m, bool v) external {
        if (v) {
            (, uint64 lateStart,,,) = config.stageBoundaries();
            _tabOpenInCommunity[c][m] = true;
            _tabElapsed[c][m] = lateStart;
        } else {
            _tabOpenInCommunity[c][m] = false;
            _tabElapsed[c][m] = 0;
        }
    }

    /// The account-wide exposure seam (`_memberCurrentExposure` in the pre-split code, ignoring
    /// `communityId`): sets `openAnywhere`/`principal` on the snapshot every `c` reads.
    function setMemberExposure(uint256 c, address m, uint256 v) external {
        _tabOpenAnywhere[c][m] = true;
        _tabPrincipal[c][m] = v;
    }

    /// `_hasEverDrawn` is real, inherited, unmodified state (`_completedObligations[c][m] > 0`),
    /// so this primes that state directly rather than overriding the read: `true` sets it to 1
    /// only if it is still 0 (never clobbers a higher count `primeCompletedObligations` already
    /// set), with `firstObligationAt` at `now` so phase stays FirstAccess until a test primes
    /// otherwise; `false` resets both to 0.
    function setHasEverDrawn(uint256 c, address m, bool v) external {
        _syncSeat(c, m);
        if (v) {
            if (_completedObligations[c][m] == 0) {
                _completedObligations[c][m] = 1;
                _firstObligationAt[c][m] = uint64(block.timestamp);
            }
        } else {
            _completedObligations[c][m] = 0;
            _firstObligationAt[c][m] = 0;
        }
    }

    function _communitySnapshotOverride(uint256 c) internal view returns (CommunityLedgerSnapshot memory) {
        return CommunityLedgerSnapshot({allocation: _liquidSet[c] ? _liquidOverride[c] : 0, outstandingPrincipal: 0});
    }

    function _tabSnapshotOverride(uint256 c, address m) internal view returns (MemberTabSnapshot memory s) {
        s.openInCommunity = _tabOpenInCommunity[c][m];
        s.elapsedSinceDraw = _tabElapsed[c][m];
        s.openAnywhere = _tabOpenAnywhere[c][m];
        s.principal = _tabPrincipal[c][m];
    }

    /// Pass-through: builds the snapshot, calls the real, deployed, inherited
    /// `communityImpactBudget(uint256, CommunityLedgerSnapshot)`.
    function communityImpactBudget(uint256 c) external view returns (uint256) {
        return this.communityImpactBudget(c, _communitySnapshotOverride(c));
    }

    /// Pass-through: calls the harness's own 3-argument `conductFactor` overload below, which is
    /// itself a pass-through to the real, deployed, inherited `_conductFactor`.
    function conductFactor(uint256 c, address m) external view returns (uint256) {
        return this.conductFactor(c, m, _tabSnapshotOverride(c, m));
    }

    /// Pass-through: calls the harness's own 3-argument `trustExtension` overload below, which is
    /// itself a pass-through to the real, deployed, inherited `_trustExtension`.
    function trustExtension(uint256 c, address m) external view returns (uint256) {
        return this.trustExtension(c, m, _tabSnapshotOverride(c, m));
    }

    /// Pass-through: calls the real, deployed, inherited
    /// `impactBase(uint256,address,CommunityLedgerSnapshot,MemberTabSnapshot)`.
    function impactBase(uint256 c, address m) external view returns (uint256) {
        return this.impactBase(c, m, _communitySnapshotOverride(c), _tabSnapshotOverride(c, m));
    }

    /// Pass-through: calls the real, deployed, inherited
    /// `line(uint256,address,CommunityLedgerSnapshot,MemberTabSnapshot)`.
    function line(uint256 c, address m) external view returns (uint256 drawable, bool eligible) {
        return this.line(c, m, _communitySnapshotOverride(c), _tabSnapshotOverride(c, m));
    }

    /// Overload taking an explicit snapshot, calling straight through to the real (non-override)
    /// `CreditStanding._conductFactor`/`_trustExtension`. For a test exercising a real draw
    /// through `CreditCoreHarness`, the snapshot is built from the real obligation
    /// (`ICreditCore.ObligationView`), not from `setOpenDelinquencyConduct`/`setOpenDelinquency`.
    function conductFactor(uint256 c, address m, MemberTabSnapshot calldata tab) external view returns (uint256) {
        return _conductFactor(c, m, tab);
    }

    function trustExtension(uint256 c, address m, MemberTabSnapshot calldata tab) external view returns (uint256) {
        return _trustExtension(c, m, tab);
    }

    /// Pass-through to the real, deployed, inherited
    /// `_communityTeBudgetLocal`, so a test can assert it against
    /// `CreditCoreHarness.communityTeBudget` without either side being a copy.
    function communityTeBudgetLocal(uint256 c) external view returns (uint256) {
        return _communityTeBudgetLocal(c);
    }

    // ---- plain read wrappers over private/internal state, unchanged from the pre-split harness ----

    function phaseOf(uint256 c, address m) external view returns (ICreditCore.Phase) {
        return _phaseOf(c, m);
    }

    function impactUnitsOf(uint256 c, address m) external view returns (uint256) {
        return _seasonedOf(c, m);
    }

    function communityImpactTotal(uint256 c) external view returns (uint256) {
        return _impactSeasonedTotal[c];
    }

    function pendingImpactOf(uint256 c, address m) external view returns (uint256) {
        return _pendingImpactOf(c, m);
    }

    function standingCountersOf(uint256 c, address m)
        external
        view
        returns (
            uint256 completedObligations,
            uint256 trustExtensionEarned,
            uint256 communityAttributedYield_,
            bool disqualified
        )
    {
        return (_completedOf(c, m), _teEarnedOf(c, m), _communityAttributedYield[c], _preDefaultDisqualified[m]);
    }

    function shareWad(uint256 c, address m) external view returns (uint256) {
        return _shareWad(c, m);
    }

    function activityFactor(uint256 c, address m) external view returns (uint256) {
        return _activityFactor(c, m);
    }

    function accountExposureCap(uint256, address m) external view returns (uint256) {
        return _accountExposureCap(m);
    }

    /// The account impact figure, the sum the exposure cap multiplies.
    function accountImpactTotal(address m) external view returns (uint256 impact) {
        (impact,) = _accountTotals(m);
    }

    // Every prime below writes seat-side state, so each stamps it against the member's live
    // seat first, exactly as the production write paths do.

    /// Set `U_i` and `U_C` directly, so a formula test does not have to accrue and season.
    function primeImpact(uint256 c, address m, uint256 ui, uint256 uc) external {
        _syncSeat(c, m);
        _impactSeasoned[c][m] = ui;
        _impactSeasonedTotal[c] = uc;
    }

    function primeActivity(uint256 c, address m, uint64 lastAt, uint256 healFloorWad, uint64 healAt) external {
        _syncSeat(c, m);
        _lastActivityAt[c][m] = lastAt;
        _healFloorWad[c][m] = healFloorWad;
        _healFloorAt[c][m] = healAt;
    }

    function primeCompletedObligations(uint256 c, address m, uint256 n, uint64 firstAt) external {
        _syncSeat(c, m);
        _completedObligations[c][m] = n;
        _firstObligationAt[c][m] = firstAt;
    }

    function primeTeEarned(uint256 c, address m, uint256 amount) external {
        _syncSeat(c, m);
        _teEarned[c][m] = amount;
    }

    function primeCommunityAttributedYield(uint256 c, uint256 amount) external {
        _communityAttributedYield[c] = amount;
    }

    /// Trigger the internal qualifying-activity note without an `accrueImpact` call.
    function pokeActivity(uint256 c, address m) external {
        _syncSeat(c, m);
        _noteActivity(c, m);
    }
}
