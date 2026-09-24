// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IERC4626} from "openzeppelin-contracts/contracts/interfaces/IERC4626.sol";

interface IVenue is IERC4626 {
    // identity
    function poolType() external view returns (uint8);
    function factory() external view returns (address);

    // venues (owner)
    function addVenue(address venue) external;
    function removeVenue(address venue) external;
    function setWeights(address[] calldata venues_, uint16[] calldata bps) external;
    function rebalance() external; // anyone
    function venues(uint256 i) external view returns (address);
    function venueCount() external view returns (uint256);
    function weightBps(address venue) external view returns (uint16);
    function isInstant(address venue) external view returns (bool);

    // liquidity
    function idle() external view returns (uint256);
    function instantLiquidity() external view returns (uint256);
    /// Live valuation (idle plus venue holdings marked to venue price). The same figure
    /// `totalAssets()` returns: shares are priced live.
    function liveAssets() external view returns (uint256);

    // queue
    function requestRedeem(uint256 shares, address receiver) external returns (uint256 requestId);
    function cancelRedeem(uint256 requestId) external;
    function processQueue(uint256 maxSteps) external; // anyone
    function queuedShares(address owner) external view returns (uint256);
    function nextToPay() external view returns (uint256);
    /// The current-price estimate for a queued request. The amount paid is struck at
    /// fulfillment and moves with the vault until then; this is not a guarantee.
    function queuedRedeemEstimate(uint256 requestId) external view returns (uint256 estimateNow);
    function redeemRequest(uint256 requestId) external view returns (address owner, address receiver, uint256 shares);

    /// USDC a queue payout could not deliver, held for the receiver to collect later.
    function heldPayout(address receiver) external view returns (uint256);
    function totalHeld() external view returns (uint256);
    function releaseHeldPayout(address receiver) external; // anyone

    // report
    function report() external; // anyone
    /// Writes down any venue whose live value has fallen below its recorded basis and burns
    /// reserve shares against the loss, so the member price is the one every view answers at.
    /// Runs at the top of every value-moving entry point; this is it on its own. Anyone may call.
    function settle() external;
    function reserveShares() external view returns (uint256);
    function fundReserve(uint256 assets) external; // anyone; mints to the reserve
    /// The credit leg accrues in USDC, indexed per ledger share. 1e18 fixed point.
    function poolLegIndex() external view returns (uint256);

    // ---- the Yield Engine ----

    /// Realizes venue `venue`'s gain: skims the protocol and credit legs out as USDC and puts
    /// the member leg under the linear unlock. Permissionless. Reverts on a second harvest of
    /// the same venue in the same period, and returns 0 without processing when the deviation
    /// breaker fires. Returns the gain realized.
    function harvest(address venue) external returns (uint256 gain);
    /// The vault's recorded cost basis in `venue`. A gain sits above it and is invisible to the
    /// price until harvested; a loss drops the live value below it and reaches the price at once.
    function venueBasis(address venue) external view returns (uint256);
    /// `idle + sum over venues of min(recorded basis, live value)`, before the
    /// unlock is taken off. The value the vault can honour.
    function recognizedAssets() external view returns (uint256);
    /// Member-leg profit credited by harvests and not yet released. `totalAssets()` is
    /// `recognizedAssets()` less this, so no share can be converted into it.
    function unreleasedProfit() external view returns (uint256);
    /// USDC skimmed for the protocol leg and not yet paid to the protocol treasury.
    function protocolHolding() external view returns (uint256);
    /// USDC skimmed for the credit leg and not yet claimed by a ledger.
    function poolHolding() external view returns (uint256);
    /// Pays the whole protocol holding to `config.protocolTreasury()` in USDC. Anyone may call.
    /// The amount is in `ProtocolLegPaid`; read `protocolHolding()` before the call for a quote.
    function claimProtocolLeg() external;
    /// The deviation breaker. While true, `harvest` reverts, on every venue.
    function attributionPaused() external view returns (bool);
    /// The venue whose outlier paused attribution, or zero when nothing is paused.
    function pausedVenue() external view returns (address);
    /// Clears the breaker after the Risk Committee has looked at `venue`'s outlier, and accepts
    /// that venue's next trip. Reverts unless `venue` is the venue currently paused, so an
    /// acceptance cannot be spent on an unreviewed reading or armed while nothing is paused.
    function resumeAttribution(address venue) external;
    /// The other answer to the same pause: the Risk Committee looked at `venue`'s outlier
    /// and rejected it. Clears the breaker without accepting anything, quarantines the venue so
    /// its reading is never attributed and it can never re-trip the breaker, and lets
    /// `removeVenue` take the position out over the gain still sitting above the basis. Same scope
    /// as `resumeAttribution`: owner only, and only on the venue that is actually paused.
    function refuseAttribution(address venue) external;
    /// True once `refuseAttribution` has quarantined a venue. A refused venue cannot be harvested
    /// and can be removed with a gain above its basis.
    function refusedVenue(address venue) external view returns (bool);
    /// Pays a ledger's accrued credit leg to `creditCore` in USDC. Ledger only, and
    /// `creditCore` must be `Config.CREDIT_CORE`: the leg lands on the singleton
    /// `CreditCore` against the calling ledger's community id, not on a per-community clone.
    function claimPoolLeg(address creditCore) external returns (uint256 assets);
    function ledgerShares(address ledger) external view returns (uint256);

    event VenueAdded(address venue, bool instant);
    event VenueRemoved(address venue);
    event WeightsSet(address[] venues, uint16[] bps);
    event Rebalanced();
    event RedeemQueued(uint256 indexed requestId, address indexed owner, address receiver, uint256 shares);
    event RedeemPaid(uint256 indexed requestId, uint256 assets);
    event RedeemCancelled(uint256 indexed requestId);
    event PayoutHeld(uint256 indexed requestId, address indexed receiver, uint256 assets);
    event HeldPayoutReleased(address indexed receiver, uint256 assets);
    /// Every venue written down to its live value, the unreleased profit the loss consumed, and
    /// the reserve shares burned against whatever the promise could not cover. One event
    /// per call, not per venue: two venues losing in one block is one loss.
    event LossAbsorbed(uint256 loss, uint256 fromUnreleasedProfit, uint256 reserveBurned);
    /// The keeper's periodic accounting event, for the indexer.
    event Reported(uint256 recognized, uint256 unreleased);
    /// A harvest that was processed. Every figure is USDC.
    event Harvested(address indexed venue, uint256 gain, uint256 memberLeg, uint256 poolLeg, uint256 protocolLeg);
    /// The deviation breaker: this harvest was not processed and attribution is now paused.
    event AttributionPaused(address indexed venue, uint256 gain, uint256 average);
    event AttributionResumed(address indexed venue);
    event AttributionRefused(address indexed venue);
    event ProtocolLegPaid(address indexed treasury, uint256 assets);
    event PoolLegClaimed(address indexed ledger, address indexed creditCore, uint256 assets);
    error NotLedger();
    /// `claimPoolLeg` with a destination that is not `Config.CREDIT_CORE`.
    error NotCreditCore();
    error NotOwnerOfRequest();
    error ZeroReceiver();
    error DepositCapExceeded();
    error TierLimitBreached();
    error NoticePeriodTooLong();
    error UnknownVenue();
    error DuplicateVenue();
    error WeightsMustSum();
    error InsufficientInstantLiquidity();
    error NothingToClaim();
    /// A deposit or mint that would mint no shares at the live price.
    error ZeroShares();
    error TransferRestricted();
    /// A second harvest of the same venue in the same period.
    error AlreadyHarvested();
    /// A harvest of a venue whose live value is at or below its recorded basis.
    error NothingToHarvest();
    /// The deviation breaker is up; the Risk Committee has not cleared it yet.
    error AttributionIsPaused();
    /// `harvest` named a venue the Risk Committee has refused. Remove it instead.
    error VenueRefused();
    /// `resumeAttribution` named a venue that is not the one currently paused, or nothing is
    /// paused at all.
    error AttributionNotPaused();
    /// A venue removal while the position still holds a gain nobody has harvested.
    error UnharvestedGain();
}
