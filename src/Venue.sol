// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.30;

import {ERC4626, ERC20, IERC20, IERC4626} from "openzeppelin-contracts/contracts/token/ERC20/extensions/ERC4626.sol";
import {SafeERC20} from "openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "openzeppelin-contracts/contracts/utils/math/Math.sol";
import {Ownable2Step, Ownable} from "openzeppelin-contracts/contracts/access/Ownable2Step.sol";
import {IVenue} from "./interfaces/IVenue.sol";
import {IStrategy} from "./interfaces/IStrategy.sol";
import {IConfig} from "./interfaces/IConfig.sol";
import {IPauseGuard} from "./interfaces/IPauseGuard.sol";
import {ICommunityFactory} from "./interfaces/ICommunityFactory.sol";
import {VenueStrategies} from "./VenueStrategies.sol";

/// A shared savings venue. ERC-4626 on USDC, held only by registered community ledgers. Idle USDC
/// is allocated across listed strategies by owner-set weights; strategies listed with no exit
/// delay are the instant group, the rest the slow group. An instant withdrawal is served from idle
/// and the instant group; anything larger goes through the redeem queue, which anyone may process.
///
/// Value is read live, on the pattern of Morpho Vault V2. Every interaction first accrues:
///
///     real  = idle + the sum of every strategy's totalAssets()
///     total = min(real, lastTotal + lastTotal * elapsed * maxRate)
///
/// So a loss reaches the price in the block it happens, and a gain reaches it no faster than
/// `maxRate`. A gain above the cap is not lost: it stays in `real` and is caught up at the capped
/// pace. The cap also means money donated to the Venue cannot move the price in the block it
/// lands in, and a zero base allows no growth at all, so nobody can price out the first depositor.
///
/// The Venue takes no fee and knows nothing about communities. How a gain is shared out is the
/// ledger's business.
contract Venue is IVenue, ERC4626, Ownable2Step {
    using SafeERC20 for IERC20;
    using Math for uint256;

    IConfig public immutable config;
    address public immutable override factory;

    Labels internal _labels;

    address[] internal _strategies;
    mapping(address => bool) public override isStrategy;
    mapping(address => bool) public override isInstant;
    mapping(address => uint16) public override weightBps;
    mapping(address => uint64) public override delayOf;
    mapping(address => uint256) public override capOf;

    /// The total as booked at the last accrual, and when. The growth cap is measured from here.
    /// Money in and out moves it by exactly the amount, so a deposit is never mistaken for growth.
    uint256 internal _lastTotal;
    uint64 internal _lastAccrual;

    /// Shares a deployment buys to seed the Venue, held at the Venue's own address.
    uint256 public override reserveShares;
    /// Head of the redeem queue: the id `processQueue` looks at first.
    uint256 public override nextToPay = 1;
    /// Shares an owner has locked in the queue and not yet been paid for.
    mapping(address => uint256) public override queuedShares;
    /// USDC a queue payout could not deliver (a receiver that rejects the transfer). It sits in the
    /// Venue's balance but belongs to the receiver, so `idle()` nets it out.
    mapping(address => uint256) public override heldPayout;
    uint256 public override totalHeld;

    /// Set only for the duration of `_move`. Outside it, `_update` rejects every transfer.
    bool private _moving;

    /// Adds strategies. It starts as the owner so a deployment can list the first ones, and is then
    /// handed to the slower timelock, which alone names its successor.
    address public override strategyLister;

    constructor(
        IERC20 usdc_,
        IConfig config_,
        address factory_,
        address owner_,
        string memory name_,
        string memory symbol_
    ) ERC20(name_, symbol_) ERC4626(usdc_) Ownable(owner_) {
        config = config_;
        factory = factory_;
        _lastAccrual = uint64(block.timestamp);
        strategyLister = owner_;
        emit StrategyListerSet(address(0), owner_);
    }

    modifier onlyLedger() {
        if (!ICommunityFactory(factory).isCommunityContract(msg.sender)) revert NotLedger();
        _;
    }

    // ---- labels ----

    /// What a member is shown before choosing this venue. `maxRateBps` is also the growth cap, so a
    /// change books the growth the old cap allowed up to now and applies the new one from here.
    function setLabels(Labels calldata l) external override onlyOwner {
        if (l.riskKey < 1 || l.riskKey > 5) revert RiskKeyOutOfRange();
        if (l.maxRateBps > config.maxRateCeilingBps()) revert MaxRateAboveCeiling();
        _accrue();
        _labels.name = l.name;
        _labels.kind = l.kind;
        _labels.riskKey = l.riskKey;
        _labels.estReturnBps = l.estReturnBps;
        _labels.exitSeconds = l.exitSeconds;
        _labels.maxRateBps = l.maxRateBps;
        emit LabelsSet(l);
    }

    function labels() external view override returns (Labels memory) {
        return _labels;
    }

    // ---- value ----

    /// Venue USDC on hand. Held payouts are receivers' money sitting in the same balance, so they
    /// are excluded here and every figure built on idle follows.
    function idle() public view override returns (uint256) {
        uint256 bal = IERC20(asset()).balanceOf(address(this));
        return bal > totalHeld ? bal - totalHeld : 0;
    }

    function realAssets() public view override returns (uint256 real) {
        real = idle();
        uint256 n = _strategies.length;
        for (uint256 i; i < n; i++) {
            real += IStrategy(_strategies[i]).totalAssets();
        }
    }

    /// What the shares are priced against: `realAssets()`, capped by the growth `maxRate` allows
    /// since the last accrual. Never above what the Venue holds.
    function totalAssets() public view override(ERC4626, IERC4626) returns (uint256 total) {
        (total,) = _accrued();
    }

    function _accrued() internal view returns (uint256 total, uint256 real) {
        real = realAssets();
        uint256 last = _lastTotal;
        uint256 ceiling =
            last + last.mulDiv(uint256(_labels.maxRateBps) * (block.timestamp - _lastAccrual), 10_000 * 365 days);
        total = real < ceiling ? real : ceiling;
    }

    /// Books the total and restarts the growth clock. Runs first in every entry point that moves
    /// value, so each caller transacts at the price the view reports.
    function _accrue() internal {
        (uint256 total, uint256 real) = _accrued();
        if (total != _lastTotal) emit Accrued(total, real);
        _lastTotal = total;
        _lastAccrual = uint64(block.timestamp);
    }

    function accrue() external override {
        _accrue();
    }

    // ---- liquidity ----

    function instantLiquidity() public view override returns (uint256) {
        return _liquidity(true);
    }

    /// Idle plus what the strategies can give now: only the instant group's for the instant path,
    /// every strategy's for the queue.
    function _liquidity(bool instantOnly) internal view returns (uint256 liq) {
        liq = idle();
        uint256 n = _strategies.length;
        for (uint256 i; i < n; i++) {
            address a = _strategies[i];
            if (instantOnly && !isInstant[a]) continue;
            liq += IStrategy(a).maxWithdraw();
        }
    }

    /// Instant liquidity the instant path may spend: what is left after the queue head's assets are
    /// set aside. The head is served before anyone who arrives later, so its money is not on offer.
    /// An unpayable head reserves more than there is and closes the path entirely.
    function _availableInstant() internal view returns (uint256) {
        uint256 liq = instantLiquidity();
        uint256 head = _headAssets();
        return liq > head ? liq - head : 0;
    }

    function maxWithdraw(address owner_) public view override(ERC4626, IERC4626) returns (uint256) {
        return Math.min(super.maxWithdraw(owner_), _availableInstant());
    }

    function maxRedeem(address owner_) public view override(ERC4626, IERC4626) returns (uint256) {
        return Math.min(super.maxRedeem(owner_), convertToShares(_availableInstant()));
    }

    /// Makes at least `assets` idle by withdrawing from strategies in list order.
    function _pullToIdle(uint256 assets, bool instantOnly) internal {
        uint256 have = idle();
        if (have >= assets) return;
        uint256 need = assets - have;
        uint256 n = _strategies.length;
        for (uint256 i; i < n && need > 0; i++) {
            address a = _strategies[i];
            if (instantOnly && !isInstant[a]) continue;
            uint256 avail = IStrategy(a).maxWithdraw();
            if (avail == 0) continue;
            uint256 take = avail < need ? avail : need;
            IStrategy(a).withdraw(take, address(this));
            need -= take;
        }
    }

    // ---- deposits and withdrawals ----

    function deposit(uint256 assets, address receiver) public override(ERC4626, IERC4626) returns (uint256) {
        _accrue();
        return super.deposit(assets, receiver);
    }

    function mint(uint256 shares, address receiver) public override(ERC4626, IERC4626) returns (uint256) {
        _accrue();
        return super.mint(shares, receiver);
    }

    /// Asking for more than the instant group holds is not an ERC-4626 max breach, it is the signal
    /// to use the redeem queue, so both entry points say so before the max check.
    function withdraw(uint256 assets, address receiver, address owner_)
        public
        override(ERC4626, IERC4626)
        returns (uint256)
    {
        _accrue();
        if (assets > _availableInstant()) revert InsufficientInstantLiquidity();
        return super.withdraw(assets, receiver, owner_);
    }

    function redeem(uint256 shares, address receiver, address owner_)
        public
        override(ERC4626, IERC4626)
        returns (uint256)
    {
        _accrue();
        if (shares > convertToShares(_availableInstant())) revert InsufficientInstantLiquidity();
        return super.redeem(shares, receiver, owner_);
    }

    function _deposit(address caller, address receiver, uint256 assets, uint256 shares) internal override {
        if (receiver != caller || !ICommunityFactory(factory).isCommunityContract(caller)) revert NotLedger();
        if (totalAssets() + assets > config.globalDepositCap()) revert DepositCapExceeded();
        // A deposit that would mint no shares (dust against a price above one) reverts instead of
        // taking the depositor's money for nothing.
        if (shares == 0) revert ZeroShares();
        super._deposit(caller, receiver, assets, shares);
        _lastTotal += assets;
    }

    /// Reimplements OZ's `ERC4626._withdraw` so the pull from the instant group and the booked
    /// total sit around the same burn, all before the transfer out.
    function _withdraw(address caller, address receiver, address owner_, uint256 assets, uint256 shares)
        internal
        override
    {
        _pullToIdle(assets, true);
        if (caller != owner_) {
            _spendAllowance(owner_, caller, shares);
        }
        _burn(owner_, shares);
        _lastTotal -= assets;
        IERC20(asset()).safeTransfer(receiver, assets);
        emit Withdraw(caller, receiver, owner_, assets, shares);
    }

    // ---- strategies ----

    function setStrategyLister(address next) external override {
        if (msg.sender != strategyLister) revert NotStrategyLister();
        if (next == address(0)) revert ZeroAddress();
        emit StrategyListerSet(strategyLister, next);
        strategyLister = next;
    }

    function addStrategy(address strategy, uint64 delaySeconds) external override {
        if (msg.sender != strategyLister) revert NotStrategyLister();
        bool instant = VenueStrategies.addStrategy(
            _strategies, isStrategy, isInstant, delayOf, strategy, delaySeconds, asset(), config.maxNoticePeriod()
        );
        emit StrategyAdded(strategy, delaySeconds, instant);
    }

    function removeStrategy(address strategy) external override onlyOwner {
        (uint16 floorBps, uint16 ceilingBps) = _tierLimits();
        VenueStrategies.removeStrategy(
            _strategies, isStrategy, isInstant, weightBps, delayOf, capOf, strategy, asset(), floorBps, ceilingBps
        );
        emit StrategyRemoved(strategy);
    }

    function setWeights(address[] calldata strategies_, uint16[] calldata bps) external override onlyOwner {
        (uint16 floorBps, uint16 ceilingBps) = _tierLimits();
        VenueStrategies.setWeights(
            _strategies, isStrategy, isInstant, weightBps, strategies_, bps, floorBps, ceilingBps
        );
        emit WeightsSet(strategies_, bps);
    }

    function setCap(address strategy, uint256 cap) external override onlyOwner {
        if (!isStrategy[strategy]) revert UnknownStrategy();
        capOf[strategy] = cap;
        emit CapSet(strategy, cap);
    }

    function _tierLimits() internal view returns (uint16 floorBps, uint16 ceilingBps) {
        return (config.instantTierFloorBps(), config.slowTierCeilingBps());
    }

    /// Moves each strategy toward its weight of what the Venue really holds. Moving money between
    /// idle and a strategy changes neither `real` nor the booked total, so a rebalance moves no
    /// price. Idle left over, when the weights sum below the whole, is the Venue's cash buffer.
    function rebalance() external override {
        _accrue();
        uint256 total = realAssets();
        uint256 n = _strategies.length;
        // Read once: the first pass changes liquidity, and re-reading between the passes would put
        // back into the strategies exactly what the first pass just took out.
        bool blocked = _queueBlocked();
        // First pass: bring overweight strategies down to idle. A blocked queue makes every target
        // zero, so each strategy gives up whatever it can and the next `processQueue` can pay.
        for (uint256 i; i < n; i++) {
            IStrategy s = IStrategy(_strategies[i]);
            uint256 target = blocked ? 0 : (total * weightBps[address(s)]) / 10_000;
            uint256 have = s.totalAssets();
            if (have > target) {
                uint256 excess = have - target;
                uint256 can = s.maxWithdraw();
                if (can < excess) excess = can;
                if (excess > 0) s.withdraw(excess, address(this));
            }
        }
        if (blocked) return; // idle belongs to the queue until it clears
        // Second pass: allocate idle to underweight strategies.
        for (uint256 i; i < n; i++) {
            IStrategy s = IStrategy(_strategies[i]);
            uint256 target = (total * weightBps[address(s)]) / 10_000;
            uint256 have = s.totalAssets();
            if (have < target) {
                uint256 room = idle();
                uint256 put = target - have;
                if (put > room) put = room;
                if (put > 0) _allocate(s, put);
            }
        }
        emit Rebalanced();
    }

    /// The one place money goes into a strategy. A strategy may never hold more than its cap, so an
    /// allocation past it reverts the whole call rather than landing part-way. The pause stops it
    /// here and only here: a rebalance that only brings money back from a strategy still runs.
    function _allocate(IStrategy s, uint256 amount) internal {
        if (IPauseGuard(config.pauseGuard()).paused(IPauseGuard.Flag.VENUES)) revert IPauseGuard.Paused();
        if (s.totalAssets() + amount > capOf[address(s)]) revert StrategyCapExceeded();
        s.deposit(amount);
    }

    function strategies(uint256 i) external view override returns (address) {
        return _strategies[i];
    }

    function strategyCount() external view override returns (uint256) {
        return _strategies.length;
    }

    // ---- transfer restriction ----

    /// Shares move only by mint, burn, or the Venue's own queue bookkeeping. A holder-initiated
    /// transfer would let shares reach a holder that is not a community ledger, so every one of
    /// them reverts.
    function _update(address from, address to, uint256 value) internal override {
        if (from != address(0) && to != address(0)) {
            if (!_moving) revert TransferRestricted();
            // Defense in depth: even the Venue's own moves stay inside the allowlist.
            bool ok = to == address(this) || ICommunityFactory(factory).isCommunityContract(to);
            if (!ok) revert TransferRestricted();
        }
        super._update(from, to, value);
    }

    /// The only way shares change hands. The queue uses it to lock shares at request and to hand
    /// them back on cancel.
    function _move(address from, address to, uint256 value) internal {
        _moving = true;
        _transfer(from, to, value);
        _moving = false;
    }

    // ---- redeem queue: shares lock at request, paid in order at the price when processed ----
    //
    // The member is shown an ESTIMATE at request; the USDC is STRUCK when processQueue reaches the
    // request, and moves with the Venue (up and down, pro-rata with everyone) until then.
    // `RedeemQueued` carries the locked share count, not an amount, so it never reads as a price
    // promise.

    struct RedeemRequest {
        address owner;
        address receiver;
        uint256 shares; // 0 once paid or cancelled
    }

    RedeemRequest[] internal _queue; // index 0 unused; ids start at 1

    function queuedRedeemEstimate(uint256 requestId) external view override returns (uint256 estimateNow) {
        if (requestId == 0 || requestId >= _queue.length) return 0;
        uint256 s = _queue[requestId].shares;
        return s == 0 ? 0 : convertToAssets(s);
    }

    /// The request as stored: owner, receiver, and the locked share count (0 once paid or
    /// cancelled). No price field, by design.
    function redeemRequest(uint256 requestId)
        external
        view
        override
        returns (address owner, address receiver, uint256 shares)
    {
        RedeemRequest storage r = _queue[requestId];
        return (r.owner, r.receiver, r.shares);
    }

    function requestRedeem(uint256 shares, address receiver) external override onlyLedger returns (uint256 id) {
        _accrue();
        if (shares == 0) revert NothingToClaim();
        if (receiver == address(0)) revert ZeroReceiver();
        if (_queue.length == 0) _queue.push(); // burn index 0
        _move(msg.sender, address(this), shares);
        queuedShares[msg.sender] += shares;
        _queue.push(RedeemRequest({owner: msg.sender, receiver: receiver, shares: shares}));
        id = _queue.length - 1;
        emit RedeemQueued(id, msg.sender, receiver, shares);
    }

    function cancelRedeem(uint256 id) external override {
        RedeemRequest storage r = _queue[id];
        if (r.owner != msg.sender) revert NotOwnerOfRequest();
        if (r.shares == 0) revert NothingToClaim();
        uint256 s = r.shares;
        r.shares = 0;
        queuedShares[msg.sender] -= s;
        _move(address(this), msg.sender, s);
        emit RedeemCancelled(id);
    }

    /// Pays requests in order, straight to each receiver, at the price when each is processed.
    /// Money comes from idle first, then from what each strategy can give now, in list order;
    /// principal a strategy has sent out waits until it comes back. Skips resolved entries and
    /// stops at the first request it cannot pay: first in, first out, without exception.
    function processQueue(uint256 maxSteps) external override {
        _accrue();
        uint256 i = nextToPay;
        uint256 end = _queue.length;
        while (i < end && maxSteps > 0) {
            RedeemRequest storage r = _queue[i];
            if (r.shares == 0) {
                i++;
                continue;
            }
            uint256 assets = convertToAssets(r.shares);
            if (assets > _liquidity(false)) break;
            uint256 s = r.shares;
            r.shares = 0;
            queuedShares[r.owner] -= s;
            _pullToIdle(assets, false);
            _burn(address(this), s);
            _lastTotal -= assets;
            // A receiver that cannot take the USDC (a blocklisted wallet, say) must not freeze the
            // queue behind it: the request is settled either way and the money waits for it.
            bool paid;
            try IERC20(asset()).transfer(r.receiver, assets) returns (bool ok) {
                paid = ok;
            } catch {
                paid = false;
            }
            if (!paid) {
                heldPayout[r.receiver] += assets;
                totalHeld += assets;
                emit PayoutHeld(i, r.receiver, assets);
            }
            emit RedeemPaid(i, assets);
            i++;
            maxSteps--;
        }
        nextToPay = i;
    }

    /// Pays out USDC a queue payout could not deliver. Anyone may call it; it always pays the
    /// receiver, so a receiver that is still refusing simply makes it revert again.
    function releaseHeldPayout(address receiver) external override {
        uint256 a = heldPayout[receiver];
        if (a == 0) revert NothingToClaim();
        heldPayout[receiver] = 0;
        totalHeld -= a;
        IERC20(asset()).safeTransfer(receiver, a);
        emit HeldPayoutReleased(receiver, a);
    }

    /// Assets owed to the first unresolved request at or after `nextToPay`, or 0 when there is
    /// none. The one place that walks past cancelled entries to find the head.
    function _headAssets() internal view returns (uint256) {
        uint256 i = nextToPay;
        uint256 end = _queue.length;
        while (i < end) {
            if (_queue[i].shares != 0) return convertToAssets(_queue[i].shares);
            i++;
        }
        return 0;
    }

    /// True while the request at the head of the queue is more than the Venue could pay now.
    /// Rebalancing stops feeding the strategies until it clears. An empty queue is never blocked.
    function _queueBlocked() internal view returns (bool) {
        uint256 head = _headAssets();
        return head != 0 && head > _liquidity(false);
    }

    // ---- the reserve ----

    /// Buys reserve shares at the current price, so the reserve is a holder like any other and the
    /// price does not move. A deployment seeds each Venue through this.
    function fundReserve(uint256 assets) external override {
        _accrue();
        uint256 shares = previewDeposit(assets);
        // The same guard `_deposit` applies: a seed that would mint no shares must fail loudly
        // rather than hand the Venue free USDC.
        if (shares == 0) revert ZeroShares();
        IERC20(asset()).safeTransferFrom(msg.sender, address(this), assets);
        _mint(address(this), shares);
        reserveShares += shares;
        _lastTotal += assets;
    }
}
