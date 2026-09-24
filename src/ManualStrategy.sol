// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.30;

import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "openzeppelin-contracts/contracts/utils/math/Math.sol";
import {Ownable2Step, Ownable} from "openzeppelin-contracts/contracts/access/Ownable2Step.sol";
import {IStrategy} from "./interfaces/IStrategy.sol";
import {IConfig} from "./interfaces/IConfig.sol";
import {IPauseGuard} from "./interfaces/IPauseGuard.sol";

/// Qudi's own strategy, with pre-funded yield.
///
/// The operator pays yield in ahead of time, into a buffer, and the strategy releases it into value
/// second by second at a set rate on the principal. Released yield can never exceed what was paid
/// in, so the value members are shown never rests on a promise Qudi has not paid. When the buffer
/// runs dry, yield pauses.
///
///     totalAssets = principal held + principal deployed + released yield
///     released    = accounted + min(rate * elapsed * principal, buffer)
///
/// Accrual follows Maple's pattern: an accounted amount and a moving start time. Every change to
/// the principal, the buffer or the rate books what has been released so far and restarts the
/// clock, so a rate change never reprices the past.
///
/// The operator may send principal cash out to a destination the owner has listed. Money out
/// keeps its value until the operator reports a loss, which lowers it at once; money that comes
/// back beyond what was sent out is yield and goes to the buffer.
contract ManualStrategy is IStrategy, Ownable2Step {
    using SafeERC20 for IERC20;

    IERC20 internal immutable _asset;
    IConfig public immutable config;
    address public immutable venue;
    address public operator;

    /// Principal as cash in this contract, available to the Venue.
    uint256 public principalHeld;
    /// Principal out at listed destinations. Still the Venue's, until a loss is reported.
    uint256 public principalDeployed;
    /// Yield released up to `_start` and not yet withdrawn by the Venue. Cash, the Venue's.
    uint256 internal _accounted;
    /// Yield cash paid in and not released as of `_start`.
    uint256 internal _buffer;
    uint64 internal _start;
    uint16 public rateBps;

    mapping(address => bool) public isDestination;

    event OperatorSet(address operator);
    event DestinationAdded(address destination);
    event DestinationRemoved(address destination);
    event YieldFunded(uint256 amount);
    event RateSet(uint16 annualBps);
    event Deployed(address indexed destination, uint256 amount, bytes32 ref);
    event Returned(uint256 amount, uint256 toPrincipal, uint256 toBuffer);
    event LossReported(uint256 amount, string reason);

    error NotOperator();
    error ZeroAddress();
    error UnlistedDestination();
    error RateAboveCeiling();
    /// More than the principal cash held, or, for the Venue, more than principal and released
    /// yield together. The unreleased buffer is never paid out.
    error ExceedsCash();
    error ExceedsDeployed();

    constructor(IERC20 asset_, IConfig config_, address venue_, address owner_, address operator_) Ownable(owner_) {
        if (venue_ == address(0) || operator_ == address(0)) revert ZeroAddress();
        _asset = asset_;
        config = config_;
        venue = venue_;
        operator = operator_;
        _start = uint64(block.timestamp);
    }

    modifier onlyVenue() {
        if (msg.sender != venue) revert NotVenue();
        _;
    }

    modifier onlyOperator() {
        if (msg.sender != operator) revert NotOperator();
        _;
    }

    // ---- value ----

    /// Yield released since `_start` and not yet booked: the rate on the principal for the time
    /// elapsed, never more than the buffer that pays for it. Rounds down.
    function _pending() internal view returns (uint256) {
        uint256 accrued = Math.mulDiv(
            principalHeld + principalDeployed, uint256(rateBps) * (block.timestamp - _start), 10_000 * 365 days
        );
        return accrued < _buffer ? accrued : _buffer;
    }

    /// Books what has been released and restarts the clock. Runs before anything that changes the
    /// principal, the buffer or the rate, so each stretch of time accrues at the terms that held
    /// during it.
    function _accrue() internal {
        uint256 p = _pending();
        _accounted += p;
        _buffer -= p;
        _start = uint64(block.timestamp);
    }

    function asset() external view returns (address) {
        return address(_asset);
    }

    function totalAssets() external view returns (uint256) {
        return principalHeld + principalDeployed + _accounted + _pending();
    }

    /// Principal cash and released yield. Deployed principal waits for `returnFrom`, and the
    /// unreleased buffer is not the Venue's yet.
    function maxWithdraw() external view returns (uint256) {
        return principalHeld + _accounted + _pending();
    }

    /// Yield cash paid in and not yet released.
    function buffer() external view returns (uint256) {
        return _buffer - _pending();
    }

    // ---- the Venue ----

    function deposit(uint256 assets) external onlyVenue {
        _accrue();
        principalHeld += assets;
        _asset.safeTransferFrom(msg.sender, address(this), assets);
    }

    /// Pays released yield first and principal after it, so the principal the rate runs on stays
    /// as large as it can for as long as it can.
    function withdraw(uint256 assets, address receiver) external onlyVenue {
        _accrue();
        uint256 fromYield = assets < _accounted ? assets : _accounted;
        uint256 fromPrincipal = assets - fromYield;
        if (fromPrincipal > principalHeld) revert ExceedsCash();
        _accounted -= fromYield;
        principalHeld -= fromPrincipal;
        _asset.safeTransfer(receiver, assets);
    }

    // ---- the operator ----

    function fundYield(uint256 amount) external onlyOperator {
        _accrue();
        _buffer += amount;
        _asset.safeTransferFrom(msg.sender, address(this), amount);
        emit YieldFunded(amount);
    }

    /// Effective from now. Bounded by `Config.MANUAL_RATE_CEILING_BPS`; the Venue's own `maxRate`
    /// caps what reaches its price again.
    function setRate(uint16 annualBps) external onlyOperator {
        if (annualBps > config.manualRateCeilingBps()) revert RateAboveCeiling();
        _accrue();
        rateBps = annualBps;
        emit RateSet(annualBps);
    }

    /// Sends principal cash to a listed destination. The value is unchanged: the money is still the
    /// Venue's, only somewhere else. A stolen operator key can move money only to places the owner
    /// has already listed through the timelock.
    function deploy(uint256 amount, address destination, bytes32 ref) external onlyOperator {
        if (IPauseGuard(config.pauseGuard()).paused(IPauseGuard.Flag.VENUES)) revert IPauseGuard.Paused();
        if (!isDestination[destination]) revert UnlistedDestination();
        if (amount > principalHeld) revert ExceedsCash();
        _accrue();
        principalHeld -= amount;
        principalDeployed += amount;
        _asset.safeTransfer(destination, amount);
        emit Deployed(destination, amount, ref);
    }

    /// Pulls USDC back from the operator. Up to what is deployed it is principal coming home; above
    /// that it is yield, and goes to the buffer to be released at the rate.
    function returnFrom(uint256 amount) external onlyOperator {
        _accrue();
        uint256 toPrincipal = amount < principalDeployed ? amount : principalDeployed;
        uint256 toBuffer = amount - toPrincipal;
        principalDeployed -= toPrincipal;
        principalHeld += toPrincipal;
        _buffer += toBuffer;
        _asset.safeTransferFrom(msg.sender, address(this), amount);
        emit Returned(amount, toPrincipal, toBuffer);
    }

    /// The only way deployed principal goes down without cash coming back. It shows in value at
    /// once. Money recovered later comes back through `returnFrom` as yield.
    function reportLoss(uint256 amount, string calldata reason) external onlyOperator {
        if (amount > principalDeployed) revert ExceedsDeployed();
        _accrue();
        principalDeployed -= amount;
        emit LossReported(amount, reason);
    }

    // ---- the owner ----

    function setOperator(address operator_) external onlyOwner {
        if (operator_ == address(0)) revert ZeroAddress();
        operator = operator_;
        emit OperatorSet(operator_);
    }

    function addDestination(address destination) external onlyOwner {
        if (destination == address(0)) revert ZeroAddress();
        isDestination[destination] = true;
        emit DestinationAdded(destination);
    }

    function removeDestination(address destination) external onlyOwner {
        isDestination[destination] = false;
        emit DestinationRemoved(destination);
    }
}
