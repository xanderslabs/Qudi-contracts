// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IERC4626} from "openzeppelin-contracts/contracts/interfaces/IERC4626.sol";

interface IVenue is IERC4626 {
    /// Whether a vault in this venue may be withdrawn from before a date of its own choosing.
    /// Open venues take withdrawals at any time; a vault in a Locked venue carries an unlock date.
    enum Kind {
        Open,
        Locked
    }

    /// What a member is shown before choosing this venue. Owner-set. `estReturnBps` is the
    /// estimated return to the member, never a promise; `maxRateBps` is the ceiling on how fast the
    /// share price may rise, and the only label the accounting reads.
    struct Labels {
        string name;
        Kind kind;
        uint8 riskKey;
        uint16 estReturnBps;
        uint32 exitSeconds;
        uint16 maxRateBps;
    }

    function factory() external view returns (address);

    // labels (owner)
    function setLabels(Labels calldata l) external;
    function labels() external view returns (Labels memory);

    // strategies (owner)
    function addStrategy(address strategy, uint64 delaySeconds) external;
    function removeStrategy(address strategy) external;
    function setWeights(address[] calldata strategies_, uint16[] calldata bps) external;
    /// The most `strategy` may hold, in assets. Zero until the owner sets it, so nothing is
    /// allocated to a strategy nobody has sized.
    function setCap(address strategy, uint256 cap) external;
    function rebalance() external; // anyone
    function strategies(uint256 i) external view returns (address);
    function strategyCount() external view returns (uint256);
    function isStrategy(address strategy) external view returns (bool);
    function weightBps(address strategy) external view returns (uint16);
    function isInstant(address strategy) external view returns (bool);
    function delayOf(address strategy) external view returns (uint64);
    function capOf(address strategy) external view returns (uint256);

    // value
    /// Books the value the Venue may report now and moves the growth clock. Anyone may call it;
    /// every deposit, withdrawal, request, processing and rebalance does it first.
    function accrue() external;
    /// `idle + the sum of every strategy's totalAssets()`: what the Venue really holds.
    /// `totalAssets()` is this, capped by how far `maxRateBps` lets it grow since the last accrual.
    function realAssets() external view returns (uint256);
    function idle() external view returns (uint256);
    function instantLiquidity() external view returns (uint256);

    // queue
    function requestRedeem(uint256 shares, address receiver) external returns (uint256 requestId);
    function cancelRedeem(uint256 requestId) external;
    function processQueue(uint256 maxSteps) external; // anyone
    function queuedShares(address owner) external view returns (uint256);
    function nextToPay() external view returns (uint256);
    /// The current-price estimate for a queued request. The amount paid is struck when the
    /// request is processed and moves with the Venue until then; this is not a guarantee.
    function queuedRedeemEstimate(uint256 requestId) external view returns (uint256 estimateNow);
    function redeemRequest(uint256 requestId) external view returns (address owner, address receiver, uint256 shares);

    /// USDC a queue payout could not deliver, held for the receiver to collect later.
    function heldPayout(address receiver) external view returns (uint256);
    function totalHeld() external view returns (uint256);
    function releaseHeldPayout(address receiver) external; // anyone

    // reserve
    function reserveShares() external view returns (uint256);
    function fundReserve(uint256 assets) external; // anyone; mints to the reserve

    event LabelsSet(Labels labels);
    event StrategyAdded(address strategy, uint64 delaySeconds, bool instant);
    event StrategyRemoved(address strategy);
    event CapSet(address indexed strategy, uint256 cap);
    event WeightsSet(address[] strategies, uint16[] bps);
    event Rebalanced();
    /// The reported total changed at an accrual. `real` is what the strategies and idle hold.
    event Accrued(uint256 total, uint256 real);
    event RedeemQueued(uint256 indexed requestId, address indexed owner, address receiver, uint256 shares);
    event RedeemPaid(uint256 indexed requestId, uint256 assets);
    event RedeemCancelled(uint256 indexed requestId);
    event PayoutHeld(uint256 indexed requestId, address indexed receiver, uint256 assets);
    event HeldPayoutReleased(address indexed receiver, uint256 assets);

    error NotLedger();
    error NotOwnerOfRequest();
    error ZeroReceiver();
    error DepositCapExceeded();
    error TierLimitBreached();
    error NoticePeriodTooLong();
    error UnknownStrategy();
    error DuplicateStrategy();
    error WeightsMustSum();
    error InsufficientInstantLiquidity();
    error NothingToClaim();
    /// A deposit or mint that would mint no shares at the current price.
    error ZeroShares();
    error TransferRestricted();
    /// `riskKey` outside 1 to 5.
    error RiskKeyOutOfRange();
    /// `maxRateBps` above `Config.MAX_RATE_CEILING_BPS`.
    error MaxRateAboveCeiling();
    /// An allocation that would leave a strategy holding more than its cap.
    error StrategyCapExceeded();
    /// A strategy removed while it still holds value the Venue could not withdraw.
    error StrategyNotEmpty();
}
