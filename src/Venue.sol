// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.30;

import {ERC4626, ERC20, IERC20, IERC4626} from "openzeppelin-contracts/contracts/token/ERC20/extensions/ERC4626.sol";
import {SafeERC20} from "openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "openzeppelin-contracts/contracts/utils/math/Math.sol";
import {Ownable2Step, Ownable} from "openzeppelin-contracts/contracts/access/Ownable2Step.sol";
import {IVenue} from "./interfaces/IVenue.sol";
import {IConfig} from "./interfaces/IConfig.sol";
import {ICommunityFactory} from "./interfaces/ICommunityFactory.sol";
import {PoolTypes} from "./PoolTypes.sol";
import {IStrategyDelay} from "./interfaces/IStrategyDelay.sol";
import {VenueStrategies} from "./VenueStrategies.sol";

/// The shared strategy vault for one pool type. ERC-4626 on USDC. Depositors are
/// registered community ledgers only. Idle USDC is allocated across whitelisted ERC-4626 venues by
/// owner-set weights; venues with redeemDelay() == 0 are the instant tier, others the slow tier.
/// Instant withdrawals are served from idle then instant venues; anything larger goes through
/// the FIFO redeem queue.
/// Recognition is asymmetric:
///
///     recognizedAssets = idle + sum over venues of min(recorded basis, live value)
///     totalAssets      = recognizedAssets - unreleasedProfit
///
/// A gain sits above the recorded basis and is invisible to the price until a harvest realizes
/// it, which is what makes it skimmable and unlockable. A loss drops the live
/// value below the basis and reaches the price in the block it happens, without waiting for
/// anything, because a vault must never report a price it cannot honour.
/// `harvest(venue)` is the discrete realization: it skims the protocol and credit legs
/// out of the member pool as USDC into holding balances, raises the venue's basis, and puts the
/// member's 70% under a linear unlock so an address present for one block captures approximately
/// nothing. Harvests are idempotent per venue per period, and a single harvest far above the
/// venue's historical average pauses attribution instead of being processed.
/// A deposit that would mint no shares at that price reverts rather than wiping the depositor,
/// and deployments seed each vault's reserve, so a donation cannot get in ahead of the first
/// depositor and set a price no one can buy at.
contract Venue is IVenue, ERC4626, Ownable2Step {
    using SafeERC20 for IERC20;
    using Math for uint256;

    IConfig public immutable config;
    address public immutable override factory;
    uint8 public immutable override poolType;

    // venues
    address[] internal _venues;
    mapping(address => bool) public isVenue;
    mapping(address => bool) public override isInstant;
    mapping(address => uint16) public override weightBps;
    /// The vault's recorded cost basis in each venue.
    mapping(address => uint256) public override venueBasis;
    /// `period + 1` for the period each venue was last harvested in; 0 means never.
    mapping(address => uint256) public harvestedPeriod;

    // accounting
    /// The vault's recorded cost basis in each venue: what it put in, less what it took out,
    /// raised by a harvest to the post-skim live value and written down by `_absorb` when the
    /// live value falls below it. `min(basis, live)` is the venue's contribution to recognized
    /// value, which is what makes a gain invisible until harvest and a loss visible at once.

    /// Member-leg profit credited by the last harvest and still releasing, with the timestamp it
    /// was set at and the unlock period that harvest struck. `unreleasedProfit()` decays this
    /// linearly to zero; a later harvest adds its own leg to whatever is left and restarts the
    /// clock, so overlapping harvests release on one schedule rather than several.
    uint256 internal _lockedProfit;
    uint64 internal _lockedProfitAt;
    uint64 internal _lockedProfitPeriod;
    /// The promise as it stood at the last touch, which is the most a loss first observed now
    /// could have been covered by when it landed.
    ///
    /// Absorption is lazy: a venue loses value with no transaction, and the vault only sees it at
    /// the next touch, which can be a whole unlock window later. Reading the promise's capacity at
    /// the touch charges the loss against a schedule that has decayed since it landed, and the
    /// reserve then pays for a loss the promise had already covered. The vault cannot know when
    /// the loss happened, so it uses the one thing it does know: every touch runs `_absorb`, so a
    /// loss standing now arose after the last touch, and the schedule only decays between touches.
    /// The promise at the last touch is the schedule's supremum over the whole interval the loss
    /// could have landed in, and charging against it keeps the junior claim first
    /// wherever in that interval the loss actually fell.
    ///
    /// It is at or above `_scheduledProfit()` at every point, which is what lets the views stay as
    /// they are written: it is set to the schedule at each touch and the schedule only decays
    /// between them, so `max(0, scheduled - min(loss, cap))` and `max(0, scheduled - loss)` are the
    /// same number and `_heldBack` needs no cap of its own.
    uint256 internal _promiseCap;
    /// USDC skimmed at harvest for the two 15% legs. Both sit in the vault's own USDC
    /// balance and belong to someone else, so `idle()` nets them out and no member price, deposit
    /// cap or liquidity figure counts them.
    uint256 public override protocolHolding;
    uint256 public override poolHolding;

    /// Running history per venue, for the deviation breaker: the average gain a harvest is
    /// measured against. A rolling average weighted three parts history to one part the harvest
    /// that just landed, so a venue whose yield genuinely changes level is followed within a few
    /// harvests rather than tripping the breaker for as long as its whole history outweighs it.
    mapping(address => uint256) internal _avgGain;
    /// The venue whose outlier paused attribution, or zero when nothing is paused. While
    /// it is set, no venue may be harvested; the owner clears it once the outlier has been looked
    /// at. Held as the venue rather than a flag so an acceptance can be tied to the
    /// reading that was actually reviewed.
    address public override pausedVenue;
    /// The venue whose next breaker trip the owner has already accepted, or zero for none.
    /// Consumed by that venue's next harvest. Without an acceptance, clearing the pause achieves
    /// nothing: the outlier gain is still sitting above the basis and the next harvest measures the
    /// same figure against the same average and pauses again, so the vault could never realize that
    /// gain at all. It is one harvest wide and one venue wide: a global flag could be
    /// consumed by an unreviewed outlier on a different venue, and could be armed while nothing was
    /// paused, leaving a standing auto-accept behind.
    address internal _acceptedVenue;
    /// Venues the Risk Committee has rejected. The breaker on its own was accept-only, and
    /// since a pause halts every venue's harvests it has to be cleared, so the only way out was to
    /// accept a reading the Committee may have called wrong. `refuseAttribution` is the other
    /// answer, and this is what it leaves behind: the venue is never harvested again, so its
    /// outlier is never attributed and it cannot re-trip the breaker, and `removeVenue` will take
    /// the position out over the unharvested gain that would otherwise block the exit.
    mapping(address => bool) public override refusedVenue;
    /// Shares held by each registered ledger (deposit-minted, redeem-burned). The pool leg index
    /// is denominated per ledger share, so this excludes reserve, unclaimed pool-leg, and treasury shares.
    mapping(address => uint256) public override ledgerShares;
    uint256 public totalLedgerShares;
    /// Head of the FIFO redeem queue: the id `processQueue` looks at first.
    uint256 public override nextToPay = 1;
    /// Shares an owner has locked in the queue and not yet been paid for.
    mapping(address => uint256) public override queuedShares;
    /// USDC a queue payout could not deliver (a receiver that rejects the transfer). It sits in the
    /// vault's balance but belongs to the receiver, not to the vault, so `idle()` nets it out.
    mapping(address => uint256) public override heldPayout;
    uint256 public override totalHeld;

    /// Set only for the duration of `_move`. Outside it, `_update` rejects every transfer.
    bool private _moving;

    constructor(
        IERC20 usdc_,
        IConfig config_,
        address factory_,
        uint8 poolType_,
        address owner_,
        string memory name_,
        string memory symbol_
    ) ERC20(name_, symbol_) ERC4626(usdc_) Ownable(owner_) {
        if (poolType_ >= PoolTypes.COUNT) revert IConfig.UnknownPoolType();
        config = config_;
        factory = factory_;
        poolType = poolType_;
    }

    // ---- gates ----

    modifier onlyLedger() {
        if (!ICommunityFactory(factory).isCommunityContract(msg.sender)) revert NotLedger();
        _;
    }

    // ---- valuation ----

    /// Vault USDC on hand. Held payouts are the receivers' money sitting in the same balance, so
    /// they are excluded here and every liquidity figure built on idle() follows.
    function idle() public view override returns (uint256) {
        uint256 bal = IERC20(asset()).balanceOf(address(this));
        // Held queue payouts and the two skimmed legs are both money that already belongs to
        // someone else; net them out so no liquidity figure, and no share price, offers them to
        // anyone else.
        uint256 reserved = totalHeld + protocolHolding + poolHolding;
        return bal > reserved ? bal - reserved : 0;
    }

    /// What the shares are priced against: the recognized value less the
    /// member-leg profit a harvest has credited but not yet released. Never above
    /// `recognizedAssets()`, and never above `liveAssets()`, so it is never a price the vault
    /// cannot honour; and never below the recognized value by more than the vault is actually
    /// still holding back.
    ///
    /// The subtraction cannot underflow. `recognized + loss` is exactly `idle + sum of every
    /// recorded basis`, because a venue contributes `min(basis, live)` to the first and
    /// `max(0, basis - live)` to the second, which sum to its basis either way. That quantity is
    /// at least the scheduled profit at every point in the vault's life: a harvest raises both
    /// sides by the member leg, `_absorb` lowers both by the same loss while any promise remains,
    /// and a payout can never exceed `recognized - heldBack` because that is the price it is
    /// struck at. So `heldBack <= scheduled <= recognized + loss - loss = recognized`. The
    /// saturating form below is a backstop rather than a branch anything reaches, and its proof
    /// is recorded in the mutation catalogue as QV-29.
    function totalAssets() public view override(ERC4626, IERC4626) returns (uint256) {
        (, uint256 recognized, uint256 loss) = _totals();
        uint256 held = _heldBack(loss);
        return recognized > held ? recognized - held : 0;
    }

    /// `idle + sum over venues of min(recorded basis, live value)`. The asymmetry is this one
    /// `min`: above the basis is an unharvested gain, which no share may be converted into until
    /// a harvest realizes it; below it is a loss, which is in the figure the moment it happens.
    function recognizedAssets() public view override returns (uint256 recognized) {
        (, recognized,) = _totals();
    }

    /// One pass over the venues for the three figures built on them: what they would pay today,
    /// what of that the vault has recognized, and how far the losing ones have fallen below their
    /// recorded basis. The third is not the difference between the first two. A venue sitting on
    /// an unharvested gain widens that difference without having lost anything, so the loss has to
    /// be accumulated per venue rather than inferred from the totals.
    function _totals() internal view returns (uint256 live, uint256 recognized, uint256 loss) {
        live = idle();
        recognized = live;
        uint256 n = _venues.length;
        for (uint256 i; i < n; i++) {
            IERC4626 v = IERC4626(_venues[i]);
            uint256 l = v.convertToAssets(v.balanceOf(address(this)));
            uint256 b = venueBasis[address(v)];
            live += l;
            if (l < b) {
                recognized += l;
                loss += b - l;
            } else {
                recognized += b;
            }
        }
    }

    /// What the vault is really still holding back from the member price: the schedule, less any
    /// venue loss it has observed and not yet absorbed.
    ///
    /// The loss term is what keeps the view and `_absorb` telling the same story. A loss reaches
    /// the price through `min(basis, live)` the moment it happens, with no transaction, so the
    /// junior claim has to absorb it in the same place, or a read taken between touches would
    /// report a promise the loss has already destroyed. That was the mid-unlock wipe: held back
    /// more than was left, price floored at zero, exits paid nothing, and the remainder surfaced
    /// behind zero shares once the schedule decayed.
    function unreleasedProfit() public view override returns (uint256) {
        (,, uint256 loss) = _totals();
        return _heldBack(loss);
    }

    /// The schedule less `loss`, floored at zero. A loss at or above the schedule leaves nothing
    /// held back at all, which is the whole of the waterfall on the view side.
    function _heldBack(uint256 loss) internal view returns (uint256) {
        uint256 scheduled = _scheduledProfit();
        return scheduled > loss ? scheduled - loss : 0;
    }

    /// The linear release schedule on its own, before any loss is charged against it. Rounds the
    /// released part down, so the unreleased part rounds up and the price is never ahead of the
    /// schedule. A period of zero has never been written: `_lockedProfit` is only ever set
    /// alongside a period read from `Config`, whose floor is one day.
    function _scheduledProfit() internal view returns (uint256) {
        uint256 lp = _lockedProfit;
        if (lp == 0) return 0;
        uint256 period = _lockedProfitPeriod;
        uint256 elapsed = block.timestamp - _lockedProfitAt;
        if (elapsed >= period) return 0;
        return lp - lp.mulDiv(elapsed, period);
    }

    /// What the vault is worth today, marked to what the venues would pay: the ceiling on what
    /// `totalAssets()` may report, and the figure the indexer reads for a live rate.
    function liveAssets() public view override returns (uint256 live) {
        (live,,) = _totals();
    }

    function instantLiquidity() public view override returns (uint256 liq) {
        liq = idle();
        uint256 n = _venues.length;
        for (uint256 i; i < n; i++) {
            address a = _venues[i];
            if (!isInstant[a]) continue;
            liq += _venueAvailable(IERC4626(a));
        }
    }

    /// Instant liquidity the instant path may spend: what is left after the queue head's assets are
    /// set aside. The head is served before anyone who arrives later, so its money is not on offer,
    /// and it stays reserved through the drain a blocked rebalance performs. An unpayable head
    /// reserves more than there is and closes the path entirely.
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

    /// The share price, over the supply an `_absorb()` would leave rather than the supply standing.
    ///
    /// A venue loses value with no transaction, so `totalAssets()` falls the moment it happens.
    /// The reserve's answer to that loss is a share burn, and a burn only happens at a touch, so
    /// with the raw supply underneath, the price dropped when the loss landed and jumped back at
    /// the next touch: an absorb that raised the share price, and a `previewRedeem` that
    /// understated what the redeem it precedes would actually pay. The promise closes the same split
    /// by putting the loss into `_heldBack` at once; this is the reserve's half of it.
    /// Both halves of the waterfall are now in the view, so an absorb moves no price at all: the
    /// supply it leaves is exactly the supply the price was already struck over.
    ///
    /// Nothing on a mutating path changes. Every one of them runs `_absorb()` before any preview,
    /// and after an absorb `_previewSettleSupply()` is `totalSupply()`.
    function _convertToShares(uint256 assets, Math.Rounding rounding) internal view override returns (uint256) {
        return assets.mulDiv(_previewSettleSupply() + 10 ** _decimalsOffset(), totalAssets() + 1, rounding);
    }

    function _convertToAssets(uint256 shares, Math.Rounding rounding) internal view override returns (uint256) {
        return shares.mulDiv(totalAssets() + 1, _previewSettleSupply() + 10 ** _decimalsOffset(), rounding);
    }

    // ---- deposits and withdrawals ----

    /// Every value-moving entry point absorbs first, before OZ computes any preview, so the price
    /// the caller transacts at already carries any venue loss and the reserve has already taken
    /// what of it the reserve can take.
    function deposit(uint256 assets, address receiver) public override(ERC4626, IERC4626) returns (uint256) {
        _absorb();
        return super.deposit(assets, receiver);
    }

    function mint(uint256 shares, address receiver) public override(ERC4626, IERC4626) returns (uint256) {
        _absorb();
        return super.mint(shares, receiver);
    }

    /// Asking for more than the instant tier holds is not an ERC-4626 max breach, it is the
    /// signal to use the redeem queue, so both entry points say so before the max check.
    function withdraw(uint256 assets, address receiver, address owner_)
        public
        override(ERC4626, IERC4626)
        returns (uint256)
    {
        _absorb();
        if (assets > _availableInstant()) revert InsufficientInstantLiquidity();
        return super.withdraw(assets, receiver, owner_);
    }

    function redeem(uint256 shares, address receiver, address owner_)
        public
        override(ERC4626, IERC4626)
        returns (uint256)
    {
        _absorb();
        if (shares > convertToShares(_availableInstant())) {
            revert InsufficientInstantLiquidity();
        }
        return super.redeem(shares, receiver, owner_);
    }

    function _deposit(address caller, address receiver, uint256 assets, uint256 shares) internal override {
        _settlePoolLeg(receiver);
        if (receiver != caller || !ICommunityFactory(factory).isCommunityContract(caller)) revert NotLedger();
        if (totalAssets() + assets > config.globalDepositCap()) revert DepositCapExceeded();
        // A deposit that would mint no shares (a donated-up empty vault, or dust against a high
        // price) reverts instead of wiping the depositor. The deploy script also seeds each vault's
        // reserve, so a pre-deposit donation cannot set a zero-share price in the first place.
        if (shares == 0) revert ZeroShares();
        super._deposit(caller, receiver, assets, shares);
        ledgerShares[receiver] += shares;
        totalLedgerShares += shares;
    }

    function _withdraw(address caller, address receiver, address owner_, uint256 assets, uint256 shares)
        internal
        override
    {
        _settlePoolLeg(owner_);
        if (assets > _availableInstant()) revert InsufficientInstantLiquidity();
        _pullToIdle(assets);
        // Reimplements OZ's ERC4626._withdraw so `_pullToIdle` and the ledger-share books sit
        // around the same burn. Every piece of this vault's own accounting lands before the
        // transfer out. `receiver` is paid the full `assets`, whatever they owe.
        if (caller != owner_) {
            _spendAllowance(owner_, caller, shares);
        }
        _burn(owner_, shares);
        // Non-ledger holders redeem too (the reserve, the treasury); only a ledger's own shares
        // come off the ledger books.
        if (ledgerShares[owner_] >= shares) {
            ledgerShares[owner_] -= shares;
            totalLedgerShares -= shares;
        }
        IERC20(asset()).safeTransfer(receiver, assets);
        emit Withdraw(caller, receiver, owner_, assets, shares);
    }

    /// Takes `assets` out of a venue and draws the basis down with it, so the venue's recognized
    /// contribution plus the cash that came out is exactly what it was before: `min(basis, live)`
    /// was the basis, is `basis - assets` after, and the cash makes up the difference. Nothing of
    /// an unharvested gain leaks into the price through a withdrawal.
    ///
    /// Subtracting `assets` flat is right because every path that reaches here has run `_absorb()`
    /// in the same call, which writes every venue down to its live value, and no venue can lose
    /// value part-way through a transaction. So `basis <= live` holds at this point, always, and
    /// there is no under-water case for the basis to come down proportionally from. The two
    /// callers are additionally held to `_venueAvailable`, which caps what they may ask for at the
    /// basis itself, so the saturating subtraction below is a backstop rather than a branch anyone
    /// reaches.
    function _venueWithdraw(IERC4626 v, uint256 assets) internal {
        v.withdraw(assets, address(this), address(this));
        uint256 basis = venueBasis[address(v)];
        venueBasis[address(v)] = basis > assets ? basis - assets : 0;
    }

    /// What a venue will give up without realizing an unharvested gain: what it can pay, capped at
    /// the basis the vault has recorded against it. The cap is property 4 of the yield engine seen
    /// from the liquidity side. Unharvested gain is not anybody's money yet, so it is not liquidity
    /// either, and a payout that reached past the basis would put it in the price with no skim
    /// taken and no unlock applied, which is precisely what a harvest exists to do properly.
    function _venueAvailable(IERC4626 v) internal view returns (uint256) {
        uint256 can = v.maxWithdraw(address(this));
        uint256 basis = venueBasis[address(v)];
        return can < basis ? can : basis;
    }

    /// Makes at least `assets` idle by redeeming from instant venues in order.
    function _pullToIdle(uint256 assets) internal {
        uint256 have = idle();
        if (have >= assets) return;
        uint256 need = assets - have;
        uint256 n = _venues.length;
        for (uint256 i; i < n && need > 0; i++) {
            address a = _venues[i];
            if (!isInstant[a]) continue;
            uint256 avail = _venueAvailable(IERC4626(a));
            if (avail == 0) continue;
            uint256 take = avail < need ? avail : need;
            _venueWithdraw(IERC4626(a), take);
            need -= take;
        }
    }

    // ---- venues ----

    function addVenue(address venue) external override onlyOwner {
        bool instant = VenueStrategies.addVenue(_venues, isVenue, isInstant, venue, asset(), config.maxNoticePeriod());
        emit VenueAdded(venue, instant);
    }

    function removeVenue(address venue) external override onlyOwner {
        // Before the position is liquidated, so a venue removed while under water writes its loss
        // down and lets the promise and the reserve take it in that order. Afterwards there is no
        // venue reading left for `min(basis, live)` to see and the loss would land on members in
        // silence.
        _absorb();
        (uint16 floorBps, uint16 ceilingBps) = _tierLimits();
        VenueStrategies.removeVenue(
            _venues,
            isVenue,
            isInstant,
            weightBps,
            venueBasis,
            venue,
            asset(),
            floorBps,
            ceilingBps,
            refusedVenue[venue]
        );
        emit VenueRemoved(venue);
    }

    function setWeights(address[] calldata venues_, uint16[] calldata bps) external override onlyOwner {
        (uint16 floorBps, uint16 ceilingBps) = _tierLimits();
        VenueStrategies.setWeights(_venues, isVenue, isInstant, weightBps, venues_, bps, floorBps, ceilingBps);
        emit WeightsSet(venues_, bps);
    }

    function _tierLimits() internal view returns (uint16 floorBps, uint16 ceilingBps) {
        return (uint16(config.instantTierFloorBps()), uint16(config.slowTierCeilingBps()));
    }

    function rebalance() external override {
        _absorb();
        // Targets are struck against recognized value and compared against each venue's basis, not
        // its live reading. Mixing the two is what let a rebalance pull a venue below its basis and
        // recognize an unharvested gain as a side effect of moving money between venues.
        uint256 total = recognizedAssets();
        uint256 keepIdle = poolType == PoolTypes.FLEX ? (total * config.flexBufferTargetBps()) / 10_000 : 0;
        uint256 n = _venues.length;
        // Read once: the first pass changes instant liquidity, and re-reading between the passes
        // would put back into the venues exactly what the drain just took out.
        bool blocked = _queueBlocked();
        // first pass: withdraw overweight venues to idle. A blocked queue makes every target 0, so
        // the slow venues give up whatever they allow and the keeper's next processQueue can pay.
        for (uint256 i; i < n; i++) {
            IERC4626 v = IERC4626(_venues[i]);
            uint256 target = blocked ? 0 : ((total - keepIdle) * weightBps[address(v)]) / 10_000;
            uint256 have = venueBasis[address(v)];
            if (have > target) {
                uint256 excess = have - target;
                uint256 can = _venueAvailable(v);
                if (can < excess) excess = can;
                if (excess > 0) _venueWithdraw(v, excess);
            }
        }
        if (blocked) return; // idle belongs to the queue until it clears
        // second pass: deposit idle above the buffer into underweight venues
        for (uint256 i; i < n; i++) {
            IERC4626 v = IERC4626(_venues[i]);
            uint256 target = ((total - keepIdle) * weightBps[address(v)]) / 10_000;
            uint256 have = venueBasis[address(v)];
            if (have < target) {
                uint256 room = idle() > keepIdle ? idle() - keepIdle : 0;
                uint256 put = target - have;
                if (put > room) put = room;
                if (put > 0) {
                    v.deposit(put, address(this));
                    venueBasis[address(v)] += put;
                }
            }
        }
        emit Rebalanced();
    }

    function venues(uint256 i) external view override returns (address) {
        return _venues[i];
    }

    function venueCount() external view override returns (uint256) {
        return _venues.length;
    }

    // ---- transfer restriction ----

    /// Shares move only by mint, burn, or the vault's own bookkeeping. A holder-initiated
    /// transfer would move shares without moving `ledgerShares`, so every one of them reverts.
    function _update(address from, address to, uint256 value) internal override {
        if (from != address(0) && to != address(0)) {
            if (!_moving) revert TransferRestricted();
            // Defense in depth: even the vault's own moves stay inside the allowlist.
            bool ok = to == address(this) || to == config.protocolTreasury()
                || ICommunityFactory(factory).isCommunityContract(to);
            if (!ok) revert TransferRestricted();
        }
        super._update(from, to, value);
    }

    /// The only way shares change hands. The queue uses it to lock shares at request and to hand
    /// them back on cancel, and the pool-leg claim uses it to pay a credit pool.
    function _move(address from, address to, uint256 value) internal {
        _moving = true;
        _transfer(from, to, value);
        _moving = false;
    }

    // ---- redeem queue: shares lock at request, pay FIFO at claim-time price ----
    //
    // The member is shown an ESTIMATE at request; the USDC is STRUCK when processQueue
    // reaches the request, and moves with the vault (up and down, pro-rata with everyone) until
    // then. `RedeemQueued` carries the locked share count, not an amount, so it never reads as a
    // price promise. `queuedRedeemEstimate` is the current-price estimate for an interface to
    // show; nothing about it is a guarantee.

    struct RedeemRequest {
        address owner;
        address receiver;
        uint256 shares; // 0 once paid or cancelled
    }

    RedeemRequest[] internal _queue; // index 0 unused; ids start at 1

    /// The USDC a queued request would fetch at the current price. An estimate only:
    /// the amount paid is struck when `processQueue` reaches the request.
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
        _absorb();
        _settlePoolLeg(msg.sender);
        if (shares == 0) revert NothingToClaim();
        if (receiver == address(0)) revert ZeroReceiver();
        if (_queue.length == 0) _queue.push(); // burn index 0
        // lock: move shares into the vault's own balance; ledgerShares falls now so the pool leg
        // index stops accruing to shares that are on their way out
        _move(msg.sender, address(this), shares);
        ledgerShares[msg.sender] -= shares;
        totalLedgerShares -= shares;
        queuedShares[msg.sender] += shares;
        _queue.push(RedeemRequest({owner: msg.sender, receiver: receiver, shares: shares}));
        id = _queue.length - 1;
        emit RedeemQueued(id, msg.sender, receiver, shares);
    }

    function cancelRedeem(uint256 id) external override {
        _settlePoolLeg(msg.sender);
        RedeemRequest storage r = _queue[id];
        if (r.owner != msg.sender) revert NotOwnerOfRequest();
        if (r.shares == 0) revert NothingToClaim();
        uint256 s = r.shares;
        r.shares = 0;
        queuedShares[msg.sender] -= s;
        ledgerShares[msg.sender] += s;
        totalLedgerShares += s;
        _move(address(this), msg.sender, s);
        emit RedeemCancelled(id);
    }

    /// Pays requests in order at the current price while instant liquidity covers each one.
    /// Skips resolved entries. Stops at the first request it cannot pay; FIFO is absolute.
    function processQueue(uint256 maxSteps) external override {
        _absorb();
        uint256 i = nextToPay;
        uint256 end = _queue.length;
        while (i < end && maxSteps > 0) {
            RedeemRequest storage r = _queue[i];
            if (r.shares == 0) {
                i++;
                continue;
            }
            uint256 assets = convertToAssets(r.shares);
            if (assets > instantLiquidity()) break;
            uint256 s = r.shares;
            r.shares = 0;
            queuedShares[r.owner] -= s;
            _pullToIdle(assets);
            _burn(address(this), s);
            // A receiver that cannot take the USDC (a blocklisted wallet, say) must not freeze the
            // queue behind it: the request is settled either way and the money waits to be claimed.
            // This holds for every receiver, whatever they owe.
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

    /// True while the request at the head of the queue is one instant liquidity cannot cover.
    /// Rebalancing stops feeding the venues until it clears. An empty queue is never blocked.
    function _queueBlocked() internal view returns (bool) {
        uint256 head = _headAssets();
        return head != 0 && head > instantLiquidity();
    }

    // ---- the settled-supply preview, which every price the vault quotes is struck over ----

    /// The `totalSupply()` an `_absorb()` would leave. A harvest is the only thing that mints or
    /// credits now, and it is never implicit, so the only supply move a touch can make is the
    /// reserve burn against an unabsorbed venue loss. Every share price the vault quotes is struck
    /// over this rather than the standing supply (see `_convertToAssets`), so a preview matches
    /// the price the call it precedes will strike, to the unit, even with venue movement since the
    /// last touch, and an absorb moves no price at all. Mirrors `_absorb`'s
    /// arithmetic exactly, cap included.
    function _previewSettleSupply() internal view returns (uint256 supply) {
        supply = totalSupply();
        // Exactly what `_absorb()` would burn, from the same pass every price read already makes.
        // The reserve answers only for the part of the loss the unreleased profit cannot cover,
        // so the preview charges the waterfall in the same order, or a quote taken before
        // a redeem would not match the price that redeem strikes.
        (,, uint256 loss) = _totals();
        uint256 cap = _promiseCap;
        uint256 remainder = loss > cap ? loss - cap : 0;
        if (supply == 0 || remainder == 0) return supply;
        uint256 burn = _lossBurn(remainder, supply);
        return supply - (burn < reserveShares ? burn : reserveShares);
    }

    /// The reserve shares whose burn puts the member price back where it stood before `loss`.
    /// Valued at the pre-loss price, as the old settle did: pricing at the post-loss price would
    /// over-burn. The price base is `totalAssets()`, the figure members are actually paid at, so
    /// an unlock in flight is on both sides of the arithmetic and cancels.
    function _lossBurn(uint256 loss, uint256 supply) internal view returns (uint256) {
        uint256 preTotal = totalAssets() + loss;
        if (preTotal == 0) return 0;
        return loss.mulDiv(supply, preTotal);
    }

    // ---- report: gain split, reserve, pool-leg index, loss ----

    uint256 public override reserveShares; // held at address(this)
    uint256 public poolLegUnclaimed; // held at address(this)
    // USDC, not shares. The credit leg was re-denominated from shares to assets when the split
    // became a skim of realised USDC at harvest. `_routePoolLeg` adds USDC to `poolHolding` and indexes that same USDC.
    uint256 public override poolLegIndex; // 1e18: cumulative pool-leg USDC per ledger share
    mapping(address => uint256) public poolLegIndexOf; // last index a ledger settled at
    mapping(address => uint256) public poolLegAccrued; // USDC owed to a ledger, not yet claimed

    /// Buys reserve shares at the settled price and adds the USDC to the value the vault is
    /// answerable for, so the reserve is a holder like any other and the member price does not move.
    function fundReserve(uint256 assets) external override {
        _absorb();
        uint256 shares = previewDeposit(assets);
        // The same guard `_deposit` applies, and this is the path a deployment seeds through: a
        // seed that would mint no shares must fail loudly rather than hand the vault free USDC.
        if (shares == 0) revert ZeroShares();
        IERC20(asset()).safeTransferFrom(msg.sender, address(this), assets);
        _mint(address(this), shares);
        reserveShares += shares;
    }

    /// Recognizes any venue loss into storage and lets the reserve take what it can of it.
    ///
    /// This is what still has to happen on a touch, and the only thing that does. `totalAssets()`
    /// already carries a loss through `min(basis, live)` the moment it happens, so the price a
    /// caller transacts at is correct with or without this call; what `_absorb` adds is the two
    /// things a view cannot do. It writes the venue down, so the loss is permanent rather than a
    /// mark that a later recovery silently reverses. And it burns reserve shares against the
    /// loss at the pre-loss price, which is how the reserve does its job: members stay
    /// whole up to the reserve's size, and `totalAssets()` still falls by the whole loss, because
    /// burning shares moves the price and never the assets.
    ///
    /// A gain is deliberately not handled here. A gain reaches the price only when a
    /// harvest realizes it, so there is nothing for a touch to do with one.
    function _absorb() internal {
        (,, uint256 loss) = _totals();
        uint256 scheduled = _scheduledProfit();
        if (loss == 0) {
            // Still a touch, so the checkpoint moves: nothing is standing unabsorbed now, and a
            // loss first seen after this call cannot have landed before it.
            if (_promiseCap != scheduled) _promiseCap = scheduled;
            return;
        }

        // The junior claim absorbs first. Unreleased profit has been credited to nobody and
        // no exit can claim it, so charging a loss against member principal while protecting that
        // promise is backwards. Only what the promise cannot cover reaches the share price.
        //
        // "what the promise can cover" is the promise at the last touch, not the promise
        // now. See `_promiseCap`. The part of that cover still on the schedule is written down
        // below; the rest of it has already been released into the member price, which is where
        // it is borne, and needs no storage move. Either way the reserve answers only for what the
        // cover cannot reach, so a loss the promise covered when it landed never burns a share.
        uint256 fromProfit = loss < _promiseCap ? loss : _promiseCap;
        uint256 fromSchedule = fromProfit < scheduled ? fromProfit : scheduled;
        if (fromSchedule > 0) {
            // Re-base the schedule onto what is left of its own window, so the release still
            // finishes when it was always going to. Restarting the full period here would stretch
            // the tail every time a venue dipped, which is the clock-restart hazard
            // reached from a second direction.
            uint256 elapsed = block.timestamp - _lockedProfitAt;
            _lockedProfitPeriod = uint64(_lockedProfitPeriod - elapsed);
            _lockedProfit = scheduled - fromSchedule;
            _lockedProfitAt = uint64(block.timestamp);
        }
        _promiseCap = scheduled - fromSchedule;
        uint256 remainder = loss - fromProfit;

        uint256 burned;
        if (remainder > 0) {
            // Struck after the promise has been written down, so `totalAssets()` inside
            // `_lossBurn` is the post-loss figure and `+ remainder` puts it back to the pre-loss
            // one: the promise is zero by now, so that figure is the recognized total. One burn for
            // the whole call rather than one per venue, because two venues losing in the same
            // block is one loss to the members.
            burned = _lossBurn(remainder, totalSupply());
            if (burned > reserveShares) burned = reserveShares;
            if (burned > 0) {
                _burn(address(this), burned);
                reserveShares -= burned;
            }
        }

        uint256 n = _venues.length;
        for (uint256 i; i < n; i++) {
            address a = _venues[i];
            IERC4626 v = IERC4626(a);
            uint256 live = v.convertToAssets(v.balanceOf(address(this)));
            if (live < venueBasis[a]) venueBasis[a] = live;
        }
        emit LossAbsorbed(loss, fromProfit, burned);
    }

    /// The absorb on its own, for anyone who needs the vault's views to answer post-absorb
    /// before they act on them. `report()` is this plus the keeper's event.
    function settle() external override {
        _absorb();
    }

    /// The keeper's periodic touch. Everything it does, every other entry point has already done
    /// for its own caller; what report() adds is the accounting event the indexer reads.
    function report() external override {
        _absorb();
        emit Reported(recognizedAssets(), unreleasedProfit());
    }

    // ---- the Yield Engine ----

    /// Realizes `venue`'s gain. Permissionless, because nothing here is a discretionary figure:
    /// the gain is `live - basis`, a balance delta the vault reads itself (balance deltas
    /// are unforgeable onchain facts), and the split is config.
    ///
    /// The money half is in `_realize`: the skim of the two 15% legs out as USDC, and the
    /// linear unlock on the member's 70%.
    function harvest(address venue) external override returns (uint256 gain) {
        if (pausedVenue != address(0)) revert AttributionIsPaused();
        if (!isVenue[venue]) revert UnknownVenue();
        if (refusedVenue[venue]) revert VenueRefused(); // Refused readings are never attributed
        _absorb();

        (uint64 unlockWindow, uint64 harvestWindow, uint16 deviationX100) = config.yieldEngine();
        {
            // Idempotent by venue and period. Stored as `period + 1` so "never harvested"
            // is distinguishable from "harvested in period 0".
            uint256 period = block.timestamp / harvestWindow;
            if (harvestedPeriod[venue] == period + 1) revert AlreadyHarvested();
            harvestedPeriod[venue] = period + 1;
        }

        // The acceptance is consumed by this venue's next harvest whether or not the breaker trips,
        // which is what makes "one harvest wide" literally true. Leaving it armed until something
        // tripped would let a review of today's outlier auto-accept an unrelated one much later,
        // which is the standing auto-accept problem from the other direction.
        bool accepted = _acceptedVenue == venue;
        if (accepted) _acceptedVenue = address(0);

        IERC4626 v = IERC4626(venue);
        uint256 live = v.convertToAssets(v.balanceOf(address(this)));
        uint256 basis = venueBasis[venue];
        if (live <= basis) revert NothingToHarvest();
        gain = live - basis;

        // The deviation breaker. Checked before any money moves, so a paused harvest leaves
        // the vault as it found it and the gain stays unrecognized above the basis until the Risk
        // Committee has looked at it. The period stamp above is deliberately already written: a
        // paused harvest has still had its turn in that period, so retrying it in a loop achieves
        // nothing.
        uint256 average = _avgGain[venue];
        if (average > 0 && gain * 100 > average * deviationX100) {
            if (!accepted) {
                pausedVenue = venue;
                emit AttributionPaused(venue, gain, average);
                return 0;
            }
        }
        _avgGain[venue] = average == 0 ? gain : (average * 3 + gain) / 4;

        _realize(v, live, gain, unlockWindow);
    }

    /// The money half of a harvest, split out to keep `harvest` off a too-deep stack.
    ///
    /// The two 15% legs are withdrawn from the venue as USDC into holding balances, which is
    /// the skim. The venue's basis is raised to what is left, so the whole gain is recognized.
    /// And the member's 70% is added to the locked profit, which `totalAssets()` subtracts and
    /// releases linearly. Net effect on the member price at this moment: none. Recognized value
    /// rises by the member leg and the unlock holds exactly the member leg back.
    function _realize(IERC4626 v, uint256 live, uint256 gain, uint64 unlockWindow) internal {
        (, uint16 poolBps, uint16 protocolBps) = config.yieldSplit();
        uint256 protocolLeg = (gain * protocolBps) / 10_000;
        uint256 poolLeg = (gain * poolBps) / 10_000;
        // The remainder, so nothing is lost to rounding between the three legs.
        uint256 memberLeg = gain - protocolLeg - poolLeg;
        uint256 cash = protocolLeg + poolLeg;

        // The skim has to be cash in hand, not a claim on a venue that cannot pay yet. A venue
        // that cannot deliver it reverts the whole harvest through its own ERC-4626 max check,
        // rather than the harvest half-processing.
        if (cash > 0) v.withdraw(cash, address(this), address(this));
        venueBasis[address(v)] = live - cash; // the old basis plus the member leg

        _lockedProfit = unreleasedProfit() + memberLeg;
        _lockedProfitAt = uint64(block.timestamp);
        _lockedProfitPeriod = unlockWindow;
        // The harvest is a touch and it has just raised the promise, so the promise checkpoint moves
        // up with it. Without this a loss landing right after a harvest would be capped by the
        // promise the harvest replaced.
        _promiseCap = _lockedProfit;

        protocolHolding += protocolLeg;
        _routePoolLeg(poolLeg);
        emit Harvested(address(v), gain, memberLeg, poolLeg, protocolLeg);
    }

    /// Clears the deviation breaker once the outlier has been looked at, and accepts the next harvest of
    /// that venue that would trip it. Owner only: the breaker exists to put a human between an
    /// anomalous venue reading and the attribution it would drive, and this is that human saying
    /// the reading is real.
    ///
    /// The acceptance is one harvest wide and one venue wide. `venue` must be the venue
    /// whose outlier is actually paused, so an acceptance cannot be spent on a reading nobody
    /// looked at, and the call reverts when nothing is paused, so there is no way to leave a
    /// standing auto-accept armed ahead of time.
    function resumeAttribution(address venue) external override onlyOwner {
        if (pausedVenue != venue || venue == address(0)) revert AttributionNotPaused();
        pausedVenue = address(0);
        _acceptedVenue = venue;
        emit AttributionResumed(venue);
    }

    /// The Risk Committee's other answer. `resumeAttribution` says the outlier is real;
    /// this says it is not, and takes the venue out of the attribution path rather than crediting
    /// a reading nobody believes. It arms nothing: there is no acceptance behind it and the venue
    /// cannot be harvested again, so the reading is never attributed and the breaker cannot trip on
    /// it a second time to halt every other venue.
    ///
    /// The exit is refuse, then `removeVenue`, which is permitted over the unharvested gain for a
    /// refused venue precisely because harvesting it first is the thing the Committee refused. The
    /// position is liquidated and whatever it really fetches lands in idle, so a fabricated gain
    /// fetches nothing and a real one reaches the members with no skim taken and no unlock: the
    /// protocol forgoes its two legs on a reading it would not attribute. Setting the venue's
    /// weight to zero belongs in the same owner session, so a `rebalance` in between does not fund
    /// it again; nothing is at risk if one does, since removal liquidates the whole position.
    function refuseAttribution(address venue) external override onlyOwner {
        if (pausedVenue != venue || venue == address(0)) revert AttributionNotPaused();
        pausedVenue = address(0);
        refusedVenue[venue] = true;
        emit AttributionRefused(venue);
    }

    /// True while the deviation breaker stands, on any venue. `pausedVenue()` says which.
    function attributionPaused() external view override returns (bool) {
        return pausedVenue != address(0);
    }

    /// Pays the protocol leg out in USDC. Anyone may call it; it always pays the treasury.
    function claimProtocolLeg() external override {
        uint256 assets = protocolHolding;
        if (assets == 0) revert NothingToClaim();
        protocolHolding = 0;
        address to = config.protocolTreasury();
        IERC20(asset()).safeTransfer(to, assets);
        emit ProtocolLegPaid(to, assets);
    }

    /// The credit leg is held here as USDC and indexed per ledger share until a ledger claims it
    /// to its credit pool. With no ledger shares to index against there is nobody to attribute it
    /// to, so it goes to the protocol treasury instead.
    function _routePoolLeg(uint256 poolLeg) internal {
        if (poolLeg == 0) return;
        if (totalLedgerShares == 0) {
            protocolHolding += poolLeg;
            return;
        }
        poolHolding += poolLeg;
        poolLegIndex += poolLeg.mulDiv(1e18, totalLedgerShares);
    }

    /// Settles a ledger's accrued credit leg at the current index. Called before any change to
    /// that ledger's share count (deposit, withdraw, request, cancel) and by claimPoolLeg. This
    /// is the other thing a touch still has to do: the index only attributes to shares that are
    /// on the books when a harvest lands, so it has to be carried before the books move.
    function _settlePoolLeg(address ledger) internal {
        uint256 delta = poolLegIndex - poolLegIndexOf[ledger];
        if (delta > 0 && ledgerShares[ledger] > 0) {
            poolLegAccrued[ledger] += ledgerShares[ledger].mulDiv(delta, 1e18);
        }
        poolLegIndexOf[ledger] = poolLegIndex;
    }

    /// The destination is the singleton `CreditCore`, checked against config rather
    /// than against the factory registry: it is not a community contract, and the registry check was
    /// what made the old per-community pool clone the only possible target.
    /// The caller still books the leg against its own community id (`Ledger.claimPoolLeg`).
    function claimPoolLeg(address creditCore) external override onlyLedger returns (uint256 assets) {
        if (creditCore == address(0) || creditCore != config.creditCore()) revert NotCreditCore();
        _absorb();
        _settlePoolLeg(msg.sender);
        assets = poolLegAccrued[msg.sender];
        if (assets == 0) return 0;
        poolLegAccrued[msg.sender] = 0;
        if (assets > poolHolding) assets = poolHolding; // rounding guard
        poolHolding -= assets;
        IERC20(asset()).safeTransfer(creditCore, assets);
        emit PoolLegClaimed(msg.sender, creditCore, assets);
    }
}
