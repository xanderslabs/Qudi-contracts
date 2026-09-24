// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.30;

import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {IERC4626} from "openzeppelin-contracts/contracts/interfaces/IERC4626.sol";
import {SafeERC20} from "openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "openzeppelin-contracts/contracts/utils/math/Math.sol";
import {SafeCast} from "openzeppelin-contracts/contracts/utils/math/SafeCast.sol";
import {Ownable2Step, Ownable} from "openzeppelin-contracts/contracts/access/Ownable2Step.sol";
import {ICreditCore} from "./interfaces/ICreditCore.sol";
import {ICreditStanding} from "./interfaces/ICreditStanding.sol";
import {IConfig} from "./interfaces/IConfig.sol";
import {ICommunityFactory} from "./interfaces/ICommunityFactory.sol";
import {ICommunity} from "./interfaces/ICommunity.sol";
import {IComplianceRegistry} from "./interfaces/IComplianceRegistry.sol";
import {IStrategyDelay} from "./interfaces/IStrategyDelay.sol";
import {DebtMath} from "./DebtMath.sol";

/// The singleton CreditCore, Treasury half. Keyed by community id, not
/// per-community clones.
///
/// **What it holds.** Qudi-owned credit capital in USDC, and nothing else. No member
/// vault principal, no Collective Vault balances, no Shareouts, no Campaign rewards, no
/// temporary member balances. It accepts no public deposits: `fund` is owner-only Qudi seed.
/// It issues no share, LP or redemption token, and there is no path for anyone to withdraw a
/// balance they put in.
///
/// **Community Credit Accounts** are restricted internal accounting allocations: a number
/// (`allocationOf[communityId]`) inside this contract. Members, hosts and communities have no
/// ownership, redemption or withdrawal right over it, and there is no function that pays one
/// out. It changes only by an Allocation Multisig `allocate` (up), by a registered community
/// contract's `receiveCommunityLeg` (up), or by `closeCommunity` (down, back to the global
/// Treasury once debts resolve). That sentence is what makes closure a sweep and not a
/// distribution.
///
/// **The gate.** Every path that reduces unallocated Treasury cash ends in
/// `_requireRetained()`, which reverts unless
/// `cash >= totalAllocated + requiredRetainedCapital()`. This is what stands between the
/// protocol and lending out its own reserves. Standing and the debt half (draw, repay,
/// write-off, the bad-debt waterfall) add to this contract; their outflows call the same
/// `_requireRetained()`.
///
/// **Roles.** The owner is governance (the Risk Committee timelock on
/// mainnet). The Treasury Manager (2-of-3, no delay) rebalances venue capital within the
/// owner-set allowlist and nothing else: it cannot allocate, distribute surplus, transfer to
/// the company, or touch a committed allocation. The Community Allocation Multisig (2-of-3,
/// 24h) is the only caller of `allocate`; on mainnet its address is a `TimelockController`
/// whose delay is the 24 hours. On testnet the dev key holds every role.
contract CreditCore is ICreditCore, Ownable2Step {
    using SafeERC20 for IERC20;
    using SafeCast for uint256;

    IERC20 public immutable usdc;
    /// Source of the community count for the operating requirement and of community-id
    /// validation. A "community" is a community.
    address public immutable factory;
    IConfig public immutable config;
    /// The Standing half, split out into its own contract. Deployed before this contract and
    /// taken here as an immutable constructor argument; `CreditStanding.setCreditCore` (owner
    /// -only, reverts if already set) is the matching one-way wire in the other direction. This
    /// contract never mutates `CreditStanding`'s wiring.
    ICreditStanding public immutable standing;

    address public override treasuryManager;
    address public override allocationMultisig;

    /// Sum of every `allocationOf` entry. `cash - totalAllocated` is unallocated Treasury cash.
    uint256 internal _totalAllocated;
    mapping(uint256 => uint256) internal _allocationOf;
    mapping(uint256 => bool) internal _closed;

    /// An independent running mirror of `usdc.balanceOf(address(this))`, moved by exactly the
    /// same amounts every USDC-moving path moves the real balance by. Equality between the two
    /// (checked by the invariant campaign's `expectedCash()`) is what proves no path ever
    /// raw-transfers around the ledger.
    uint256 internal _bookedCash;

    address[] internal _venues;
    mapping(address => bool) public isVenue;

    constructor(
        IERC20 usdc_,
        IConfig config_,
        address factory_,
        address owner_,
        address treasuryManager_,
        address allocationMultisig_,
        ICreditStanding standing_
    ) Ownable(owner_) {
        if (
            address(usdc_) == address(0) || address(config_) == address(0) || factory_ == address(0)
                || treasuryManager_ == address(0) || allocationMultisig_ == address(0)
                || address(standing_) == address(0)
        ) revert ZeroAddress();
        usdc = usdc_;
        config = config_;
        factory = factory_;
        standing = standing_;
        treasuryManager = treasuryManager_;
        allocationMultisig = allocationMultisig_;
        emit TreasuryManagerSet(address(0), treasuryManager_);
        emit AllocationMultisigSet(address(0), allocationMultisig_);
    }

    // ---- role wiring (owner only) ----

    function setTreasuryManager(address next) external onlyOwner {
        if (next == address(0)) revert ZeroAddress();
        emit TreasuryManagerSet(treasuryManager, next);
        treasuryManager = next;
    }

    function setAllocationMultisig(address next) external onlyOwner {
        if (next == address(0)) revert ZeroAddress();
        emit AllocationMultisigSet(allocationMultisig, next);
        allocationMultisig = next;
    }

    // ---- funding (Qudi seed only: no public deposits) ----

    /// One-way. The sender gets no share, no claim, and no way to pull it back. Owner-only so
    /// no member path can put money into credit. A raw USDC transfer to this contract also
    /// just increases unallocated cash; `treasuryView().unallocated` is defined from the live
    /// balance.
    function fund(uint256 amount) external onlyOwner {
        if (amount == 0) revert ZeroAmount();
        usdc.safeTransferFrom(msg.sender, address(this), amount);
        _bookedCash += amount;
        emit Funded(msg.sender, amount);
    }

    /// The `_bookedCash` ledger, for the invariant campaign's cash-conservation check:
    /// it must always equal `usdc.balanceOf(address(this))`.
    function expectedCash() external view returns (uint256) {
        return _bookedCash;
    }

    // ---- allocations (Community Allocation Multisig only) ----

    /// Assign unallocated capital to a community's account. Growth or Stabilization; both
    /// create nothing member-attributable and neither targets a member Line. Reverts if it
    /// would leave the Treasury below its retained-capital requirement. Not recallable:
    /// there is no function that lowers an allocation except `closeCommunity` after debts
    /// resolve.
    function allocate(uint256 communityId, uint256 amount, AllocationType kind) external {
        if (msg.sender != allocationMultisig) revert NotAllocationMultisig();
        _assign(communityId, amount, kind);
        // The gate belongs here and not in `receiveCommunityLeg`: this path moves existing cash
        // from unallocated to allocated, which is what the retained-capital gate stands in front of.
        _requireRetained();
    }

    /// The second door onto the same balance. A contract `CommunityFactory`
    /// created for `communityId` has already transferred the USDC in and calls this to book it:
    /// the seat mint's 40% community share from `Community._split`, and the vault yield's 15%
    /// pool leg from `Ledger.claimPoolLeg`. Campaign proceeds use the same door when
    /// campaigns exist.
    ///
    /// `kind` is the leg's provenance and it is the caller's to name, because `CreditCore`
    /// **The kind is derived, never supplied.** The seats clone pays the mint leg and a ledger
    /// pays the yield leg, so comparing the caller against the community's seats address
    /// separates them without asking. `communityAt` is the same read `draw` already makes. A
    /// caller-supplied kind was built first and replaced: it let a contract label
    /// its own leg, which is the same weakness that rules out a caller-named community id.
    /// `Growth` and `Stabilization` are unreachable here by construction rather than by a guard.
    ///
    /// Three gates, in order. The caller must be a registered community contract; it must be
    /// registered to the community it named, so the callee decides provenance rather than the
    /// caller asserting it; and the USDC must already be in the contract, which is what keeps
    /// `expectedCash()` equal to the real balance and stops a registered contract booking a leg
    /// it never paid.
    ///
    /// No `_requireRetained()`. A leg raises cash and allocation by the same amount, so
    /// unallocated cash does not move and this is not a path that reduces it. Proved in
    /// `test/CreditCoreCommunityLeg.t.sol` rather than argued, because it is a money gate.
    function receiveCommunityLeg(uint256 communityId, uint256 amount) external {
        uint256 callerIdPlusOne = ICommunityFactory(factory).communityIdOf(msg.sender);
        if (callerIdPlusOne == 0) revert NotCommunityContract();
        if (callerIdPlusOne - 1 != communityId) revert CommunityMismatch();
        if (usdc.balanceOf(address(this)) < _bookedCash + amount) revert LegNotFunded();

        AllocationType kind = msg.sender == ICommunityFactory(factory).communityAt(communityId)
            ? AllocationType.SeatMint
            : AllocationType.Yield;

        _bookedCash += amount;
        _assign(communityId, amount, kind);
    }

    /// One internal assignment for both doors, so a leg and a grant reach the same
    /// `_allocationOf` entry and emit the same `AllocationAssigned` with the same `kind`
    /// semantics. One balance, provenance in the event stream.
    function _assign(uint256 communityId, uint256 amount, AllocationType kind) internal {
        if (amount == 0) revert ZeroAmount();
        if (communityId >= ICommunityFactory(factory).communityCount()) revert UnknownCommunity();
        if (_closed[communityId]) revert CommunityIsClosed();

        _allocationOf[communityId] += amount;
        _totalAllocated += amount;

        emit AllocationAssigned(communityId, kind, amount, msg.sender, _unallocated(), _allocationOf[communityId]);
    }

    // ---- closure ----

    /// The community's remaining balance returns to the global Treasury and the community
    /// enters a closed state. It is Qudi's money earmarked for the community
    /// (members, hosts and communities have no claim on it), so an unspent
    /// earmark coming back is an accounting finish, not a distribution.
    ///
    /// **This narrows the no-recall rule rather than overriding it.** That rule blocked closure
    /// while a balance was outstanding so that governance could not pull an allocation back *at will*. Winding
    /// up a dead community's books is not at will: it is terminal, `onlyOwner`, and gated by
    /// `_communityHasUnresolvedDebt`, which is not a stub (it reads
    /// `_openObligationCount[communityId] > 0`), so every obligation must be settled first. The
    /// blanket block conflated recalling a live allocation with winding up a dead community.
    ///
    /// What still gates closure: `onlyOwner`, the already-closed guard, and the debt gate. What
    /// closure does not do is stop the community operating; the factory has no closure concept,
    /// which belongs to the Ledger's state machine.
    ///
    /// Idempotent guard: a closed community cannot be closed again, or topped up through either
    /// door.
    function closeCommunity(uint256 communityId) external onlyOwner {
        if (_closed[communityId]) revert AlreadyClosed();
        if (_communityHasUnresolvedDebt(communityId)) revert CommunityHasDebt();

        uint256 returned = _allocationOf[communityId];
        _allocationOf[communityId] = 0;
        _totalAllocated -= returned;
        _closed[communityId] = true;
        // Unallocated cash only rises here, so the retained-capital gate cannot be breached.
        emit CommunityClosed(communityId, returned);
    }

    // ---- venue rebalance (Treasury Manager only) ----

    /// Whitelist a USDC ERC-4626 venue.
    ///
    /// **Risk Committee only.** Listing is the highest-consequence action on this
    /// contract, so it carries the Risk Committee's 48-hour delay, the same mechanism that
    /// parameter changes sit behind: the caller must be the owner of `Config`, which is that
    /// `TimelockController`. `removeVenue` stays immediate (emergencies run one
    /// direction only).
    ///
    /// **Duration limit.** The venue's `IStrategyDelay.redeemDelay()` must not
    /// exceed `MAX_VENUE_REDEMPTION_DELAY`, which is the pending-obligation window. That
    /// window had its own key and this value was derived from it; the key was retired as
    /// unread, so `Config` now sets this one directly with the same reason recorded there.
    /// A venue that does not implement `redeemDelay()` cannot be listed: its delay is unknown,
    /// so it fails closed. Checked here at listing and re-checked in `depositToVenue`, because a
    /// venue can lengthen its delay after it is listed.
    ///
    /// Listing grants no token allowance. `depositToVenue` approves exactly the deposit amount
    /// for the duration of that one call and resets to zero, so a listed venue holds no standing
    /// authority to move Treasury USDC and the retained-capital gate sees every outflow.
    function addVenue(address venue) external {
        if (msg.sender != _riskCommittee()) revert NotRiskCommittee();
        if (isVenue[venue]) revert DuplicateVenue();
        if (IERC4626(venue).asset() != address(usdc)) revert VenueAssetMismatch();
        try IStrategyDelay(venue).redeemDelay() returns (uint64 delay) {
            if (delay > config.maxVenueRedemptionDelay()) revert VenueRedeemDelayTooLong();
        } catch {
            revert VenueRedeemDelayUnknown();
        }
        isVenue[venue] = true;
        _venues.push(venue);
        emit VenueAdded(venue);
    }

    /// The Risk Committee is the owner of `Config`: a 48-hour `TimelockController` on
    /// mainnet, the dev key on testnet. Reused here so venue listing
    /// runs through the exact timelock a parameter change does, with no second timelock shape.
    function _riskCommittee() internal view returns (address) {
        return Ownable(address(config)).owner();
    }

    function removeVenue(address venue) external onlyOwner {
        if (!isVenue[venue]) revert UnknownVenue();
        // The Treasury Manager must withdraw the position first; a governance call does not
        // trigger a surprise redemption.
        if (IERC4626(venue).balanceOf(address(this)) != 0) revert VenueHoldsBalance();
        isVenue[venue] = false;
        uint256 n = _venues.length;
        for (uint256 i; i < n; i++) {
            if (_venues[i] == venue) {
                _venues[i] = _venues[n - 1];
                _venues.pop();
                break;
            }
        }
        usdc.forceApprove(venue, 0);
        emit VenueRemoved(venue);
    }

    /// Move idle USDC into an allowlisted venue. Cash falls by `assets` and the venue-loss
    /// reserve rises with the new exposure, so this is doubly gated by `_requireRetained()`:
    /// venue positions never count as cash toward the requirement.
    ///
    /// The USDC allowance is set to exactly `assets` immediately before the deposit and back to
    /// zero immediately after, so no venue ever holds standing authority to pull Treasury cash.
    ///
    /// The venue's redemption delay is re-read here as well as at listing: a venue can
    /// lengthen its delay after it is listed, and this stops new money entering one whose delay
    /// has grown past the limit. It does not pull out money already there; delisting is for
    /// that, and `removeVenue` stays immediate so it is always available.
    ///
    /// Three further limits apply after the deposit lands:
    /// - **Slippage.** The shares the venue actually minted must not fall below
    ///   `previewDeposit(assets)` by more than `MAX_VENUE_SLIPPAGE_BPS`. A deposit receives
    ///   shares, so the comparison is on shares. More shares than previewed is favourable and
    ///   never reverts.
    /// - **Per-venue cap.** This one venue's exposure must not exceed `PER_VENUE_CAP_BPS` of
    ///   total Treasury cash (`cash + total venue exposure`, not the venue sleeve, so the cap
    ///   does not loosen as the sleeve grows).
    /// - **Aggregate cap.** Total venue exposure must not exceed `VENUE_ALLOCATION_MAX_BPS` of
    ///   liquid capital above the operating buffer.
    function depositToVenue(address venue, uint256 assets) external {
        if (msg.sender != treasuryManager) revert NotTreasuryManager();
        if (!isVenue[venue]) revert UnknownVenue();
        if (assets == 0) revert ZeroAmount();
        if (IStrategyDelay(venue).redeemDelay() > config.maxVenueRedemptionDelay()) revert VenueRedeemDelayTooLong();
        uint256 previewShares = IERC4626(venue).previewDeposit(assets);
        usdc.forceApprove(venue, assets);
        uint256 gotShares = IERC4626(venue).deposit(assets, address(this));
        usdc.forceApprove(venue, 0);
        _bookedCash -= assets;
        _checkSlippage(gotShares, previewShares);
        _requireRetained();
        if (_venueExposureOf(venue) > _perVenueCap()) revert PerVenueCapExceeded();
        if (_totalVenueExposure() > _venueAllocationCap()) revert VenueAllocationCapExceeded();
        emit VenueDeposit(venue, assets);
    }

    /// Redeem venue shares back to idle USDC. Cash rises, so the retained-capital gate is not
    /// needed. Standard ERC-4626 `redeem` by the share owner (this contract) needs no USDC
    /// allowance, so there is nothing to mirror from the deposit side.
    ///
    /// Slippage: the USDC the venue actually paid must not fall below
    /// `previewRedeem(shares)` by more than `MAX_VENUE_SLIPPAGE_BPS`. A redeem receives
    /// assets, so the comparison is on assets. More assets than previewed is favourable and
    /// never reverts.
    function withdrawFromVenue(address venue, uint256 shares) external {
        if (msg.sender != treasuryManager) revert NotTreasuryManager();
        if (!isVenue[venue]) revert UnknownVenue();
        if (shares == 0) revert ZeroAmount();
        uint256 previewAssets = IERC4626(venue).previewRedeem(shares);
        uint256 assets = IERC4626(venue).redeem(shares, address(this), address(this));
        _bookedCash += assets;
        _checkSlippage(assets, previewAssets);
        emit VenueWithdraw(venue, shares, assets);
    }

    /// Reverts `VenueSlippageExceeded` when `got` is below `preview` by more than
    /// `MAX_VENUE_SLIPPAGE_BPS`. Cross-multiplied so there is no division and no rounding
    /// slack in the venue's favour. `got >= preview` (favourable, or an empty-venue zero
    /// preview) can never trip it.
    function _checkSlippage(uint256 got, uint256 preview) internal view {
        if (got >= preview) return;
        uint256 floorBps = 10_000 - config.maxVenueSlippageBps();
        if (got * 10_000 < preview * floorBps) revert VenueSlippageExceeded();
    }

    /// One venue's USDC exposure, marked to venue price.
    function _venueExposureOf(address venue) internal view returns (uint256) {
        return IERC4626(venue).convertToAssets(IERC4626(venue).balanceOf(address(this)));
    }

    /// `PER_VENUE_CAP_BPS` of total Treasury cash, which is `cash + total venue
    /// exposure`, the same base the aggregate cap uses. Measured against that base, not the
    /// venue sleeve, so the cap does not loosen as the sleeve grows. Rounds down.
    function _perVenueCap() internal view returns (uint256) {
        uint256 base = usdc.balanceOf(address(this)) + _totalVenueExposure();
        return Math.mulDiv(base, config.perVenueCapBps(), 10_000, Math.Rounding.Floor);
    }

    function _largestVenueExposure() internal view returns (uint256 largest) {
        uint256 n = _venues.length;
        for (uint256 i; i < n; i++) {
            IERC4626 v = IERC4626(_venues[i]);
            uint256 assets = v.convertToAssets(v.balanceOf(address(this)));
            if (assets > largest) largest = assets;
        }
    }

    /// Sum of every venue position, marked to venue price. Feeds the venue allocation cap.
    function _totalVenueExposure() internal view returns (uint256 total) {
        uint256 n = _venues.length;
        for (uint256 i; i < n; i++) {
            IERC4626 v = IERC4626(_venues[i]);
            total += v.convertToAssets(v.balanceOf(address(this)));
        }
    }

    /// At most `VENUE_ALLOCATION_MAX_BPS` (50% at launch) of liquid capital above
    /// the operating buffer may sit in venues; the rest stays instantly liquid. Liquid capital
    /// is cash plus venue positions, less committed community allocations and the operating
    /// requirement. Rounds down: the cap is never overstated.
    function _venueAllocationCap() internal view returns (uint256) {
        uint256 base = usdc.balanceOf(address(this)) + _totalVenueExposure();
        uint256 committed = _totalAllocated + _operatingRequirement();
        if (base <= committed) return 0;
        return Math.mulDiv(base - committed, config.venueAllocationMaxBps(), 10_000, Math.Rounding.Floor);
    }

    // ---- the retained-capital requirement ----

    /// `OPERATING_REQUIREMENT + CREDIT_LOSS_RESERVE + VENUE_LOSS_RESERVE
    ///  + PENDING_OBLIGATION_RESERVE + STRESS_CAPITAL`, every parameter read live from
    /// `Config` at its launch values. The book is an input (`_stageOutstanding`), not
    /// a constant.
    function _requiredRetainedCapital() internal view returns (uint256) {
        return _operatingRequirement() + _creditLossReserve() + _venueLossReserve() + _pendingObligationReserve()
            + _stressCapital();
    }

    /// Stage-weighted allowance on the outstanding book, cash-backed at the configured percentages
    /// (this reserve does reduce lendable cash). Each stage's slice
    /// rounds up: the requirement is never understated.
    function _creditLossReserve() internal view returns (uint256) {
        (uint256 current, uint256 late, uint256 finalCure, uint256 defaultRecovery) = _stageOutstanding();
        (uint16 currentBps, uint16 lateBps, uint16 finalCureBps, uint16 defaultRecoveryBps) =
            config.creditLossReserveBps();
        return _ceilBps(current, currentBps) + _ceilBps(late, lateBps) + _ceilBps(finalCure, finalCureBps)
            + _ceilBps(defaultRecovery, defaultRecoveryBps);
    }

    /// 20% of the largest single-venue exposure, rounded up.
    function _venueLossReserve() internal view returns (uint256) {
        return _ceilBps(_largestVenueExposure(), config.venueLossReserveBps());
    }

    /// `max(10% of total outstanding, $100,000)`. The rate slice rounds up.
    function _stressCapital() internal view returns (uint256) {
        (uint16 rateBps, uint256 floor) = config.stressCapital();
        (uint256 current, uint256 late, uint256 finalCure, uint256 defaultRecovery) = _stageOutstanding();
        uint256 byRate = _ceilBps(current + late + finalCure + defaultRecovery, rateBps);
        return byRate > floor ? byRate : floor;
    }

    function _ceilBps(uint256 amount, uint256 bps) internal pure returns (uint256) {
        return Math.mulDiv(amount, bps, 10_000, Math.Rounding.Ceil);
    }

    /// Sum of the per-community operating buffers, with the global floor as the minimum. The
    /// "global ops float" addend in the requirement has no `Config` parameter and is not
    /// derived from one here; the floor is the effective global minimum.
    function _operatingRequirement() internal view returns (uint256) {
        (uint256 perCommunity, uint256 globalFloor) = config.operatingRequirement();
        uint256 byCommunity = ICommunityFactory(factory).communityCount() * perCommunity;
        return byCommunity > globalFloor ? byCommunity : globalFloor;
    }

    /// Reserved claimable withdrawals and the payment-reversal window (the charge term that
    /// was once part of it is retired). Computed from an input, not returned as a constant: it is the sum of
    /// obligations the Credit Treasury itself owes and holds cash against. That input is empty
    /// today because no fee leg, reversal holdback, or claimable obligation is routed into
    /// CreditCore yet; it is a seam, the same shape as `_stageOutstanding`, not a hardcoded
    /// zero.
    function _pendingObligationReserve() internal view virtual returns (uint256) {
        return _reservedClaimableObligations();
    }

    /// Obligations owed by the Credit Treasury with cash reserved against them: reversal
    /// holdbacks and any claimable-withdrawal leg a later task routes here. Zero until
    /// that state exists on chain.
    function _reservedClaimableObligations() internal view virtual returns (uint256) {
        return 0;
    }

    // ---- the debt-ledger reads ----
    //
    // Real reads of the per-obligation debt ledger below. Still `virtual`: the test harness
    // overrides them with a direct poke when a test sets one, and falls through to these
    // bodies otherwise, so the synthetic-book tests and the real-draw tests share one
    // contract without one shadowing the other's state.

    function _stageOutstanding()
        internal
        view
        virtual
        returns (uint256 current, uint256 late, uint256 finalCure, uint256 defaultRecovery)
    {
        return (_stageBucket[0], _stageBucket[1], _stageBucket[2], _stageBucket[3]);
    }

    function _communityHasUnresolvedDebt(uint256 communityId) internal view virtual returns (bool) {
        return _openObligationCount[communityId] > 0;
    }

    // ---- the gate ----

    /// Reverts unless the live USDC balance covers every community allocation plus the full
    /// retained-capital requirement. Called at the end of every path that reduces
    /// unallocated cash. Only cash counts: venue positions and receivables never do.
    function _requireRetained() internal view {
        if (usdc.balanceOf(address(this)) < _totalAllocated + _requiredRetainedCapital()) {
            revert BelowRetainedCapital();
        }
    }

    // ---- views ----

    function _unallocated() internal view returns (uint256) {
        uint256 cash = usdc.balanceOf(address(this));
        return cash > _totalAllocated ? cash - _totalAllocated : 0;
    }

    function _surplus() internal view returns (int256) {
        uint256 cash = usdc.balanceOf(address(this));
        return cash.toInt256() - _totalAllocated.toInt256() - _requiredRetainedCapital().toInt256();
    }

    /// The retained-capital requirement and surplus, and the stage-outstanding book that
    /// formula is computed from, bundled in one call. Replaces the standalone
    /// `requiredRetainedCapital`, `unallocated` (derivable: `cash - totalAllocated`),
    /// `surplus`, `totalAllocated`, `stageOutstanding`, and `totalOutstandingPrincipal`
    /// (derivable: the sum of the four stage buckets). The venue views
    /// (`largestVenueExposure`, `totalVenueExposure`, `venueAllocationCap`, `perVenueCap`) are
    /// removed rather than folded in here; see `TreasuryView`'s doc comment.
    function treasuryView() external view returns (TreasuryView memory v) {
        (uint256 current, uint256 late, uint256 finalCure, uint256 defaultRecovery) = _stageOutstanding();
        v.cash = usdc.balanceOf(address(this));
        v.totalAllocated = _totalAllocated;
        v.surplus = _surplus();
        v.requiredRetainedCapital = _requiredRetainedCapital();
        v.current = current;
        v.late = late;
        v.finalCure = finalCure;
        v.defaultRecovery = defaultRecovery;
    }

    /// One community's allocation, budget, Trust Extension budget, and capacity, bundled in
    /// one call. Replaces the standalone `allocationOf`, `isCommunityClosed`,
    /// `outstandingPrincipalOf`, `communityImpactBudget`, and `teLiveOf`/`communityTeBudget`.
    /// `openObligationCountOf`, `communityImpactTotal`, and the attributed-yield leg
    /// of `standingCountersOf` are removed rather than folded in; see `CommunityCredit`'s doc
    /// comment.
    function communityCreditOf(uint256 communityId) external view returns (CommunityCredit memory v) {
        v.allocation = _allocationOf[communityId];
        v.closed = _closed[communityId];
        v.outstandingPrincipal = _outstandingPrincipalOf[communityId];
        v.impactBudget = standing.communityImpactBudget(communityId, _communitySnapshot(communityId));
        v.teLive = _teLiveOf[communityId];
        v.teBudget = _communityTeBudget(communityId);
    }

    // =================================================================================
    // Standing lives in `CreditStanding`: Impact Units, the
    // relational share, conduct decay and scars, activity decay, phases, Trust
    // Extension, and the Line. `standingOf` stays here: it is a composed view
    // mixing this contract's own agreement/debt state with Standing reads, and CreditCore is
    // the half that holds the context those reads need.
    // =================================================================================

    /// The snapshot `communityImpactBudget`/`line`/`impactBase` need from this contract's own
    /// storage: `CreditStanding` never reads `_allocationOf`/
    /// `_outstandingPrincipalOf` itself.
    function _communitySnapshot(uint256 communityId)
        internal
        view
        returns (ICreditStanding.CommunityLedgerSnapshot memory)
    {
        return ICreditStanding.CommunityLedgerSnapshot({
            allocation: _allocationOf[communityId], outstandingPrincipal: _outstandingPrincipalOf[communityId]
        });
    }

    /// The snapshot `line`/`impactBase` need of `member`'s obligation.
    /// `openInCommunity`/`elapsedSinceDraw` answer the per-community delinquency questions
    /// (`_openDelinquencyConduct`/`_hasOpenDelinquency` in the pre-split code: open, not closed,
    /// not written off, AND drawn against `communityId`). `openAnywhere`/`principal` answer the
    /// account-wide exposure question (`_memberCurrentExposure` in the pre-split code always
    /// ignored `communityId`: one open tab per account, not per community), so they are computed
    /// without the community match.
    function _tabSnapshot(uint256 communityId, address member)
        internal
        view
        returns (ICreditStanding.MemberTabSnapshot memory s)
    {
        Obligation storage o = _tab[member];
        bool exists = o.drawTimestamp != 0 && !o.closed && !o.writtenOff;
        if (!exists) return s;
        s.openAnywhere = true;
        s.principal = o.principal;
        if (o.communityId == communityId) {
            s.openInCommunity = true;
            s.elapsedSinceDraw = uint64(block.timestamp) - o.drawTimestamp;
        }
    }

    /// A member's Line and every CreditCore-native gate `draw` checks
    /// for `communityId`, named separately so the "why not?" drawer can point at the one that
    /// binds. Membership, the draw-block flag, and seat seasoning are a different contract's
    /// state (see `MemberStanding`'s doc comment) and are not duplicated here. Replaces the
    /// standalone `line`, `isAccountDefaulted`, and `agreementOf`. `phaseOf`,
    /// `impactUnitsOf`, `pendingImpactOf`, `communityImpactTotal`, and `trustExtension` are
    /// also removed here: none of them are this view's concern, so
    /// their values are not reachable from any external view until a profile/history screen
    /// gives them one; the test suite still reaches the math directly through
    /// `CreditCoreHarness`/`CreditStandingHarness`.
    function standingOf(uint256 communityId, address member) external view returns (MemberStanding memory v) {
        standing.requireCommunity(communityId);
        ICreditStanding.CommunityLedgerSnapshot memory communitySnap = _communitySnapshot(communityId);
        v.agreementAccepted = _agreementAccepted[member];
        v.communityHasCapacity = standing.communityImpactBudget(communityId, communitySnap) >= config.minLendable();
        v.accountDefaulted = standing.isAccountDefaulted(member);
        (v.drawable, v.eligible) = standing.line(communityId, member, communitySnap, _tabSnapshot(communityId, member));
    }

    // =================================================================================
    // The debt lifecycle: draw, settle, the stage machine, and deterministic
    // write-off. One open tab per account, across every community. Nothing a member is paid
    // or deposits is ever applied to their debt: debt falls only
    // through the member's own settlement or through write-off.
    // =================================================================================

    /// One account, one obligation, ever open at a time. Fields
    /// packed to keep the struct at two slots. `stage` is the stage as of the last
    /// materialization (draw, settle, finalizeWriteOff, or `materialize` touching this account),
    /// used only to detect a transition for the reserve-bucket bookkeeping; every VIEW of
    /// the current stage (`currentStage`, `obligationOf`) derives it live instead.
    struct Obligation {
        uint128 principal;
        uint128 originalPrincipal;
        uint64 drawTimestamp;
        uint64 communityId;
        uint128 teDrawn;
        uint8 stage;
        bool writtenOff;
        bool closed;
    }

    mapping(address => Obligation) internal _tab;
    mapping(address => bool) internal _agreementAccepted; // Once per account
    mapping(address => bytes32) internal _agreementHash;

    mapping(uint256 => uint256) internal _outstandingPrincipalOf; // per-community receivable
    mapping(uint256 => uint256) internal _openObligationCount;
    mapping(uint256 => uint256) internal _teLiveOf; // aggregate, per community
    /// The four credit-loss reserve buckets (`DebtMath.reserveIdx`): Current, Late, Final
    /// Cure, Default Recovery. Global across every community; `stageOutstanding()` reads it.
    uint256[4] internal _stageBucket;

    /// `hasOpenTab`: an obligation exists, is not closed
    /// or written off, and has not silently crossed the write-off boundary unmaterialized.
    function hasOpenTab(address member) public view returns (bool) {
        Obligation storage o = _tab[member];
        if (o.drawTimestamp == 0 || o.closed || o.writtenOff) return false;
        return _currentStage(o) != Stage.WrittenOff;
    }

    /// `min(sum of phase budgets, TE_COMMUNITY_CAP_BPS x cumulative attributed funding yield)`
    /// is the same community-cap term `CreditStanding._trustExtension` computes, exposed
    /// standalone so the draw gate can compare it against live aggregate usage.
    /// `communityAttributedYield` is one of the crossings into Standing: the cumulative figure
    /// itself is `CreditStanding`'s own state, read here rather than duplicated, while the phase
    /// budgets (config-only) and the formula stay local since `_teLiveOf` (this contract's own
    /// state) is compared against the result right at the call site in `draw`.
    function _communityTeBudget(uint256 communityId) internal view returns (uint256) {
        (,, uint256 b1,) = config.phaseCaps(uint8(Phase.ProvenOnce));
        (,, uint256 b2,) = config.phaseCaps(uint8(Phase.Developing));
        (,, uint256 b3,) = config.phaseCaps(uint8(Phase.Established));
        uint256 sumBudgets = b1 + b2 + b3;
        uint256 yieldCap = uint256(config.teCommunityCapBps()) * standing.communityAttributedYield(communityId) / 10_000;
        return sumBudgets < yieldCap ? sumBudgets : yieldCap;
    }

    /// `currentStage`'s pure arithmetic, taking the boundaries as a single call so every entry
    /// point that needs them (materialize, the views) reads the config once.
    function _deriveStage(uint256 elapsed) internal view returns (uint8) {
        (uint64 grace, uint64 late, uint64 finalCure, uint64 dr, uint64 wo) = config.stageBoundaries();
        return DebtMath.deriveStage(elapsed, grace, late, finalCure, dr, wo);
    }

    function _currentStage(Obligation storage o) internal view returns (Stage) {
        if (o.drawTimestamp == 0) return Stage.Tenor;
        return Stage(_deriveStage(block.timestamp - o.drawTimestamp));
    }

    /// The tab view, bundled: principal, live stage, exact payoff, and
    /// every milestone timestamp the countdown needs, in one call. `payoff` equals `principal`
    /// under the 0% price; kept as its own field so a price change never reshapes this
    /// struct. Milestone fields are zero for an account with no tab.
    function obligationOf(address member) external view returns (ObligationView memory v) {
        Obligation storage o = _tab[member];
        v.principal = o.principal;
        v.originalPrincipal = o.originalPrincipal;
        v.payoff = o.principal;
        v.drawTimestamp = o.drawTimestamp;
        v.communityId = o.communityId;
        v.teDrawn = o.teDrawn;
        v.stage = _currentStage(o);
        v.writtenOff = o.writtenOff;
        v.closed = o.closed;

        if (o.drawTimestamp != 0) {
            (uint64 grace, uint64 late, uint64 finalCure, uint64 dr, uint64 wo) = config.stageBoundaries();
            v.graceAt = o.drawTimestamp + grace;
            v.lateAt = o.drawTimestamp + late;
            v.finalCureAt = o.drawTimestamp + finalCure;
            v.defaultRecoveryAt = o.drawTimestamp + dr;
            v.writeOffAt = o.drawTimestamp + wo;
        }
    }

    // ---- draw (agreement, aggregate cap, retained capital) ----

    function draw(uint256 communityId, uint256 amount, bytes32 agreementHash) external {
        standing.requireCommunity(communityId);
        if (_closed[communityId]) revert CommunityIsClosed();
        // A zero draw opens a real obligation with no principal at risk,
        // and a same-block settle of it still credits a completed obligation and te_earned.
        // Rejecting it closes the free-completion path that needs no capital at all. It does
        // not close the residual same-block draw-then-settle gap, which is deferred.
        if (amount == 0) revert ZeroAmount();
        address m = msg.sender;

        // Materialize the caller's own tab first: if it silently crossed the write-off
        // boundary, this closes it in the same transaction, exactly as a debt-sensitive entry
        // point must, before the "one open tab" gate below reads it.
        _materialize(m);
        if (hasOpenTab(m)) revert TabAlreadyOpen();

        address community = ICommunityFactory(factory).communityAt(communityId);
        // Suspension and the freeze are exit-only, "no in only out of existing", and `isMember` is false for
        // both, so this one line is the gate. A removed, departed or frozen member may zero out
        // what they already hold and nothing more, so no new obligation opens in their name.
        // `settle`, `materialize` and `finalizeWriteOff` deliberately carry no such gate: each of
        // them only ever reduces what is owed, and gating them would let a community's own vote
        // trap a member in a debt they are forbidden to clear.
        if (!ICommunity(community).isMember(m)) revert NotAMember();
        if (IComplianceRegistry(config.complianceRegistry()).isBlocked(m)) revert AccountBlocked();
        uint64 seatedAt = ICommunity(community).mintedAt(m);
        if (block.timestamp < uint256(seatedAt) + config.memberSeasoningWindow()) revert NotSeasoned();

        bytes32 recordedHash;
        if (!_agreementAccepted[m]) {
            if (agreementHash == bytes32(0)) revert CreditAgreementRequired();
            _agreementAccepted[m] = true;
            _agreementHash[m] = agreementHash;
            recordedHash = agreementHash;
        }

        // Composed fresh at each call rather than held in a local: `_tab[m]` is
        // guaranteed closed/absent at this point (the `hasOpenTab` gate above already reverted
        // otherwise), so both snapshots reflect "no open tab" and neither call sees the draw
        // this transaction is about to record. Kept as inline expressions, not named locals,
        // because the legacy (non-`via_ir`) codegen this contract compiles under
        // runs out of stack slots in this function otherwise.
        (uint256 drawable, bool eligible) =
            standing.line(communityId, m, _communitySnapshot(communityId), _tabSnapshot(communityId, m));
        if (!eligible) revert NotEligible();
        if (amount > drawable) revert ExceedsLine();

        uint256 base =
            standing.impactBase(communityId, m, _communitySnapshot(communityId), _tabSnapshot(communityId, m));
        uint256 teComponent = amount > base ? amount - base : 0;
        if (teComponent != 0) {
            uint256 budget = _communityTeBudget(communityId);
            if (_teLiveOf[communityId] + teComponent > budget) revert CommunityTeCapExceeded();
        }

        _tab[m] = Obligation({
            principal: uint128(amount),
            originalPrincipal: uint128(amount),
            drawTimestamp: uint64(block.timestamp),
            communityId: uint64(communityId),
            teDrawn: uint128(teComponent),
            stage: uint8(Stage.Tenor),
            writtenOff: false,
            closed: false
        });
        _outstandingPrincipalOf[communityId] += amount;
        _openObligationCount[communityId] += 1;
        _teLiveOf[communityId] += teComponent;
        _stageBucket[0] += amount;

        _bookedCash -= amount;
        usdc.safeTransfer(m, amount);
        _requireRetained();

        emit Drawn(communityId, m, amount, teComponent, uint64(block.timestamp), recordedHash);
    }

    // ---- settle (one to one against principal; never pausable) ----

    function settle(uint256 amount) external {
        address m = msg.sender;
        _materialize(m);
        Obligation storage o = _tab[m];
        if (o.drawTimestamp == 0 || o.closed || o.writtenOff) revert NoOpenTab();
        if (amount == 0) revert ZeroAmount();

        uint256 outstanding = o.principal;
        uint256 retire = amount < outstanding ? amount : outstanding;
        uint256 refund = amount - retire;
        uint256 communityId = o.communityId;

        usdc.safeTransferFrom(m, address(this), amount);
        _bookedCash += amount;
        if (refund != 0) {
            usdc.safeTransfer(m, refund);
            _bookedCash -= refund;
        }

        o.principal = uint128(outstanding - retire);
        _outstandingPrincipalOf[communityId] -= retire;
        _stageBucket[DebtMath.reserveIdx(o.stage)] -= retire;

        bool closedNow;
        if (o.principal == 0) {
            _closeTab(m, o);
            closedNow = true;
        }

        emit Settled(communityId, m, retire, refund, o.principal, closedNow);
    }

    /// Full settlement: closes the tab, releases live TE exposure, and,
    /// if the obligation was ever delinquent and is being cured before formal Default, records
    /// a scar at the decayed conduct value and marks the obligation completed (Standing
    /// progression, `te_earned`). A cure reaching formal Default was already
    /// disqualified by `_materialize` before this ever runs (the obligation would already be
    /// written off, or `_materialize` already zeroed conduct and disqualified pre-Default
    /// Units at the 155-day crossing); this only handles the Tenor/Grace/Late/Final-Cure cures.
    function _closeTab(address member, Obligation storage o) internal {
        o.closed = true;
        uint256 communityId = o.communityId;
        _openObligationCount[communityId] -= 1;
        if (o.teDrawn != 0) {
            _teLiveOf[communityId] -= o.teDrawn;
            o.teDrawn = 0;
        }
        if (o.stage < uint8(Stage.DefaultRecovery)) {
            if (o.stage >= uint8(Stage.Late)) {
                // Two of the nine crossings, in sequence. `conductDecayAt` is a
                // pure read of `standing`'s own config-derived math (no state to order against);
                // `recordScar` is the write it feeds, called immediately after with the same
                // value, exactly as the pre-split `_recordScar(communityId, member,
                // _conductDecayAt(...))` call did in one contract.
                uint256 decayed = standing.conductDecayAt(block.timestamp - o.drawTimestamp);
                standing.recordScar(communityId, member, decayed);
            }
            // `_teLiveOf`/`_openObligationCount` above are already updated for this obligation,
            // so `creditObligationCompletion`'s activity/phase bookkeeping on `CreditStanding`
            // runs after this contract's own state for the same tab is final, matching the
            // pre-split ordering (both mutations happened in `_closeTab`, this one last).
            standing.creditObligationCompletion(communityId, member, config.teEarnIncrement());
        }
    }

    // ---- the stage machine: materialize before other debt logic ----

    /// Derives the account's current stage and, if it differs from the last materialized value,
    /// moves the reserve bucket and applies any one-time consequence of the crossing
    /// (formal Default's pre-Default disqualification and TE release; write-off's loss
    /// waterfall). A no-op for an account with no open obligation. Every debt-sensitive entry
    /// point (`draw`, `settle`, `finalizeWriteOff`, `materialize`) calls this first.
    function _materialize(address member) internal {
        Obligation storage o = _tab[member];
        if (o.drawTimestamp == 0 || o.closed || o.writtenOff) return;

        uint8 newStage = _deriveStage(block.timestamp - o.drawTimestamp);
        if (newStage == DebtMath.STAGE_WRITTEN_OFF) {
            _executeWriteOff(member, o);
            return;
        }
        if (newStage == o.stage) return;

        uint8 oldIdx = DebtMath.reserveIdx(o.stage);
        uint8 newIdx = DebtMath.reserveIdx(newStage);
        if (oldIdx != newIdx) {
            _stageBucket[oldIdx] -= o.principal;
            _stageBucket[newIdx] += o.principal;
        }
        if (newStage == DebtMath.STAGE_DEFAULT_RECOVERY && o.stage < DebtMath.STAGE_DEFAULT_RECOVERY) {
            // `recordFormalDefault` needs no snapshot (every field it touches on
            // `CreditStanding` is that contract's own state), so call ordering relative to the
            // stage-bucket move above and the `teDrawn` release below is not a correctness
            // question, only an audit-trail one; kept at the same point in the sequence the
            // pre-split `_recordFormalDefault` call held.
            standing.recordFormalDefault(o.communityId, member);
            if (o.teDrawn != 0) {
                _teLiveOf[o.communityId] -= o.teDrawn;
                o.teDrawn = 0;
            }
        }
        o.stage = newStage;
    }

    /// Permissionless. Records the stage `member`'s obligation is
    /// already in by its timestamp, and moves the reserve bucket with it. It runs
    /// `_materialize` and nothing else, so it can only record a crossing that
    /// `block.timestamp - drawTimestamp` has already made: a caller cannot choose a stage, move
    /// one early, or hold one back (a keeper does not control stage entry). At the
    /// write-off boundary it executes the write-off exactly as `finalizeWriteOff` does.
    function materialize(address member) external {
        _materialize(member);
    }

    // ---- deterministic write-off ----

    function finalizeWriteOff(address member) external {
        Obligation storage o = _tab[member];
        if (o.drawTimestamp == 0) revert NoOpenTab();
        if (o.writtenOff) revert AlreadyWrittenOff();
        if (o.closed) revert NoOpenTab();
        (,,,, uint64 wo) = config.stageBoundaries();
        if (block.timestamp - o.drawTimestamp < wo) revert NotYetWrittenOff();
        _materialize(member); // derives Written Off and executes it, exactly once
    }

    /// The bad-debt waterfall's first and, for now, only automatic step:
    /// the community's own allocated capital absorbs the loss immediately, clamped at
    /// what the community still has (the credit-loss reserve, unallocated Treasury, and the
    /// global pause are formula/operational responses, not automatic transfers built here). Runs exactly once per obligation: `o.writtenOff` is set
    /// before any external interaction, and every entry point that could reach here goes
    /// through `_materialize`, which already excludes a closed-or-written-off tab.
    function _executeWriteOff(address member, Obligation storage o) internal {
        uint256 principal = o.principal;
        uint256 communityId = o.communityId;

        _outstandingPrincipalOf[communityId] -= principal;
        _openObligationCount[communityId] -= 1;
        _stageBucket[DebtMath.reserveIdx(o.stage)] -= principal;

        if (o.teDrawn != 0) {
            _teLiveOf[communityId] -= o.teDrawn;
        }
        // Idempotent: applies formal-Default consequences now if the 155-day crossing was
        // skipped between touches (the jump still disqualifies at formal Default). Called
        // here, before the community loss waterfall below, the same position the pre-split
        // `_recordFormalDefault` call held; it needs no snapshot of `_allocationOf` or `o`.
        standing.recordFormalDefault(communityId, member);

        uint256 allocationBefore = _allocationOf[communityId];
        uint256 fromCommunity = principal > allocationBefore ? allocationBefore : principal;
        _allocationOf[communityId] = allocationBefore - fromCommunity;
        _totalAllocated -= fromCommunity;

        o.principal = 0;
        o.teDrawn = 0;
        o.writtenOff = true;
        o.closed = true;

        emit WriteOffFinalized(communityId, member, principal, allocationBefore, _allocationOf[communityId]);
    }
}
