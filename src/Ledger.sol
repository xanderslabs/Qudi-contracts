// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.30;

import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "openzeppelin-contracts/contracts/utils/math/Math.sol";
import {ILedger} from "./interfaces/ILedger.sol";
import {ICommunityInit} from "./interfaces/ICommunityInit.sol";
import {IVenue} from "./interfaces/IVenue.sol";
import {IConfig} from "./interfaces/IConfig.sol";
import {ICommunity} from "./interfaces/ICommunity.sol";
import {ICommunityFactory} from "./interfaces/ICommunityFactory.sol";
import {IComplianceRegistry} from "./interfaces/IComplianceRegistry.sol";
import {ICreditCore} from "./interfaces/ICreditCore.sol";
import {VaultStatus, ProposalStatus} from "./VaultStatus.sol";

/// One community's book: every vault, every venue, one contract, one clone per community.
///
/// **Units.** The ledger holds `Venue` shares for each venue its vaults use and divides them
/// between those vaults as internal units. A venue's book keeps its units and the shares behind
/// them, so the shares behind one unit is `shares / units`. `test/invariant/LedgerInvariants.t.sol`
/// reconciles the books with the ledger's real share balance.
///
/// **The fee and impact layer.** The `Venue` takes no fee and knows nothing about communities, so
/// a community's yield is split here. On every interaction, or a public `accrue`, the gain on each
/// venue position above the highest price this ledger has been charged at is charged: the
/// treasury's share and the credit share are taken as `Venue` shares, so the shares behind every
/// unit fall by exactly that much and every vault in the venue pays its part. After a loss nothing
/// is charged until the price is back above its old peak. The credit share becomes impact the
/// moment it is taken, through a per-venue accumulator: a personal vault's share goes to its
/// owner, a shared vault's to its depositors by what each put in. The fee shares wait in a pending
/// bucket until the venue can pay them out.
///
/// **The lock lives here.** A vault in a Locked-kind venue carries its own unlock date, and no
/// money leaves it before then. The venue's exit time is a separate rule.
///
/// **Withdrawals are pushed.** A personal withdrawal debits the units at once and asks the venue to
/// pay the owner; a shared payout does the same for its recipient once the members vote it
/// through. There is no claim step.
contract Ledger is ILedger, ICommunityInit {
    using SafeERC20 for IERC20;

    IConfig public config;
    address public factory;
    ICommunity public community;
    bool internal initialized;

    /// A payout needs at least this many yes votes when the headcount has this many or more, and
    /// every counted vote when it has fewer. A hard floor, not a parameter, so no configured value
    /// can let one or two people carry a pot that more people paid into.
    uint256 internal constant MIN_YES = 3;

    /// Venue share prices are read as the assets 1e18 shares are worth, so a price keeps its
    /// precision whatever the venue's share decimals.
    uint256 internal constant PRICE_UNIT = 1e18;

    /// Scale of the impact accumulators. Large, so that impact spread over many units or a large
    /// weight still rounds to almost nothing lost.
    uint256 internal constant ACC = 1e36;

    /// The unit of a shared vault's weight scale: 1.0.
    uint256 internal constant SCALE_ONE = 1e18;

    /// How many queue entries a withdrawal asks the venue to process on its way out. Enough for a
    /// liquid venue, whose queue is empty but for this request, to pay in the same transaction,
    /// and bounded so nobody's withdrawal pays to clear a long queue.
    uint256 internal constant QUEUE_STEPS = 8;

    // ---- venues ----

    /// Qudi's `Venue` for each venue id, cached the first time this community touches it. The
    /// address comes from the factory's registry; caching it saves an external call on every
    /// later interaction and is where the one-time USDC approval hangs. `_tier` is the only writer.
    mapping(uint8 => IVenue) internal _tierVault;
    /// The venue ids this community has touched, in order. `accrue` and the impact views walk it.
    uint8[] internal _wired;

    /// One venue's position. `units` is every unit in this venue across the community's vaults and
    /// `shares` the `Venue` shares behind them. `hwm` is the highest price this ledger has been
    /// charged at. `impactPerUnit` is the credit fee per unit so far, scaled by `ACC`. The two
    /// pending counts are fee shares taken and not yet paid out.
    struct VenueBook {
        uint256 units;
        uint256 shares;
        uint256 hwm;
        uint256 impactPerUnit;
        uint256 treasuryShares;
        uint256 creditShares;
    }

    mapping(uint8 => VenueBook) internal _books;
    /// Every credit fee this ledger has taken, in assets at each accrual's price. It is the
    /// community's yield impact.
    uint256 internal _creditTaken;

    // ---- the record ----

    struct Vault {
        address owner; // personal vaults only
        bool shared;
        uint8 venueId;
        uint64 lockedUntil; // 0 in an Open-kind venue
        uint8 status;
    }

    mapping(uint256 => Vault) public override vaults;
    mapping(uint256 => uint256) public override vaultUnits;
    mapping(uint256 => uint256) public override vaultCapital;
    mapping(address => uint256) public override personalUnitsOf;
    /// The venue accumulator a vault's impact was last brought up to.
    mapping(uint256 => uint256) internal _vaultAcc;
    /// Impact a personal vault has earned its owner so far.
    mapping(uint256 => uint256) internal _vaultImpact;
    /// Impact from personal vaults the member has closed, kept after the vault leaves their list.
    mapping(address => uint256) internal _closedImpact;
    mapping(address => uint256[]) internal _vaultsOf;
    /// Units across every shared vault. Only whether it is zero matters: a community cannot close
    /// while it is not.
    uint256 internal _sharedUnits;
    uint256 internal _nextVaultId;
    bool public override communityClosed;

    // ---- shared vaults: stakes and weights ----

    /// A shared vault's weight book. A depositor's weight is `raw * scale / SCALE_ONE`. A payout
    /// shrinks `scale`, which shrinks every weight in proportion in one write. When a payout empties
    /// the vault, the epoch closes: its final accumulator is kept for the depositors in it, and the
    /// next deposit starts a fresh epoch at full scale.
    struct SharedBook {
        uint256 rawTotal;
        uint256 accPerRaw;
        uint256 scale;
        uint64 epoch;
    }

    /// One depositor in one shared vault. `deposited` and `firstAt` answer who the headcount counts;
    /// `countedIn` stamps the payout that counted them. `raw`, `acc` and `impact` are their weight
    /// and the impact it has earned.
    ///
    /// **Weight is not a claim.** Nobody holds a claim on a shared vault's money. Weight only says
    /// how the vault's impact is shared, and no path that moves USDC or units reads it.
    struct Stake {
        uint128 deposited;
        uint64 firstAt;
        uint64 countedIn;
        uint64 epoch;
        uint256 raw;
        uint256 acc;
        uint256 impact;
    }

    mapping(uint256 => SharedBook) internal _shared;
    mapping(uint256 => mapping(uint64 => uint256)) internal _epochAcc;
    mapping(uint256 => mapping(address => Stake)) internal _stakes;
    mapping(uint256 => address[]) internal _depositors;

    // ---- money out ----

    struct WithdrawRequest {
        uint256 vaultId;
        address owner;
        uint256 units; // 0 once cancelled
        uint256 shares;
        uint256 capital;
        uint256 venueRequestId;
    }

    WithdrawRequest[] internal _requests; // ids start at 1

    mapping(uint256 => Payout) internal _payouts;
    mapping(uint256 => mapping(address => bool)) internal _voted;
    /// The latest payout request on each shared vault. Open while it is live inside its window or
    /// passed and not executed; failed once its window closes without passing.
    mapping(uint256 => uint256) internal _lastPayout;
    uint256 internal _nextPayoutId;

    function initialize(CommunityWiring calldata w) external override {
        if (initialized) revert AlreadyInitialized();
        initialized = true;
        config = IConfig(w.config);
        factory = w.factory;
        community = ICommunity(w.community);
    }

    // ---- venues ----

    /// Resolves the venue from the factory the first time the community touches it, approves it
    /// for USDC once, caches it, and starts its high-water mark at the price now, so a gain made
    /// before this community held anything is never charged to it.
    function _tier(uint8 venueId) internal returns (IVenue tv) {
        tv = _tierVault[venueId];
        if (address(tv) != address(0)) return tv;
        if (venueId >= ICommunityFactory(factory).venueCount()) revert IConfig.UnknownPoolType();
        tv = IVenue(ICommunityFactory(factory).venueAt(venueId));
        _tierVault[venueId] = tv;
        _wired.push(venueId);
        _books[venueId].hwm = tv.convertToAssets(PRICE_UNIT);
        IERC20(config.usdc()).forceApprove(address(tv), type(uint256).max);
        emit TierWired(venueId, address(tv));
    }

    function tierVault(uint8 venueId) external view override returns (address) {
        if (venueId >= ICommunityFactory(factory).venueCount()) revert IConfig.UnknownPoolType();
        IVenue tv = _tierVault[venueId];
        return address(tv) != address(0) ? address(tv) : ICommunityFactory(factory).venueAt(venueId);
    }

    function venueUnits(uint8 venueId) external view override returns (uint256) {
        return _books[venueId].units;
    }

    function venueShares(uint8 venueId) external view override returns (uint256) {
        return _books[venueId].shares;
    }

    function pendingFees(uint8 venueId) external view override returns (uint256, uint256) {
        VenueBook storage b = _books[venueId];
        return (b.treasuryShares, b.creditShares);
    }

    function highWaterPrice(uint8 venueId) external view override returns (uint256) {
        return _books[venueId].hwm;
    }

    // ---- accrual ----

    /// The venue's book as an accrual now would leave it, and the credit fee that accrual would
    /// take. The one place the split is computed, so the views and the writes cannot disagree.
    ///
    /// Only the price above `hwm` is gain, so after a loss the recovery back to the old peak is
    /// charged nothing. The fees are converted to shares at the price now and moved off the units'
    /// shares, which lowers the shares behind every unit by the same fraction.
    function _preview(uint8 venueId) internal view returns (VenueBook memory b, uint256 creditFee) {
        b = _books[venueId];
        uint256 price = _tierVault[venueId].convertToAssets(PRICE_UNIT);
        if (price <= b.hwm) return (b, 0);
        if (b.units != 0) {
            uint256 gain = Math.mulDiv(b.shares, price - b.hwm, PRICE_UNIT);
            (, uint16 poolBps, uint16 protocolBps) = config.yieldSplit();
            creditFee = gain * poolBps / 10_000;
            uint256 creditShares = Math.mulDiv(creditFee, PRICE_UNIT, price);
            uint256 treasuryShares = Math.mulDiv(gain * protocolBps / 10_000, PRICE_UNIT, price);
            b.shares -= creditShares + treasuryShares;
            b.creditShares += creditShares;
            b.treasuryShares += treasuryShares;
            b.impactPerUnit += Math.mulDiv(creditFee, ACC, b.units);
        }
        b.hwm = price;
    }

    function _accrueVenue(uint8 venueId) internal {
        VenueBook storage s = _books[venueId];
        uint256 pendingBefore = s.treasuryShares;
        (VenueBook memory b, uint256 creditFee) = _preview(venueId);
        if (b.hwm == s.hwm) return;
        _books[venueId] = b;
        _creditTaken += creditFee;
        if (creditFee != 0) {
            uint256 treasuryFee = Math.mulDiv(b.treasuryShares - pendingBefore, b.hwm, PRICE_UNIT);
            emit Accrued(venueId, b.hwm, treasuryFee, creditFee);
        }
    }

    /// Accrues one venue and, if it holds fees, tries to pay them out. A settlement that cannot go
    /// through (no liquidity, `CreditCore` unwired or refusing) leaves the fees pending and never
    /// blocks the member's own action.
    function _touch(uint8 venueId) internal {
        _accrueVenue(venueId);
        VenueBook storage b = _books[venueId];
        if (b.treasuryShares + b.creditShares != 0) {
            try this.settleFees() {} catch {}
        }
    }

    function accrue() external override {
        uint256 n = _wired.length;
        for (uint256 i; i < n; i++) {
            _accrueVenue(_wired[i]);
        }
        try this.settleFees() {} catch {}
    }

    /// Redeems pending fee shares as far as each venue pays now, and pays the treasury its share
    /// and `CreditCore` this community's. The USDC reaches `CreditCore` before
    /// `receiveCommunityLeg` books it, which is the order that door checks. What cannot be paid
    /// now stays pending, split as it was.
    ///
    /// Once `CreditCore` has closed this community's credit account, the credit share goes to the
    /// treasury too. A closed account takes nothing more, and a closed community's balance already
    /// returns to the treasury, so its later fees follow the same way instead of waiting forever.
    function settleFees() external override {
        address core = config.creditCore();
        if (core == address(0)) revert CreditCoreUnset();
        IERC20 usdc = IERC20(config.usdc());
        uint256 communityId = ICommunityFactory(factory).communityIdOf(address(this)) - 1;
        bool creditClosed = ICreditCore(core).communityCreditOf(communityId).closed;
        uint256 n = _wired.length;
        for (uint256 i; i < n; i++) {
            uint8 id = _wired[i];
            VenueBook storage b = _books[id];
            uint256 pending = b.treasuryShares + b.creditShares;
            if (pending == 0) continue;
            IVenue tv = _tierVault[id];
            uint256 r = Math.min(pending, tv.maxRedeem(address(this)));
            if (r == 0) continue;
            uint256 cr = Math.mulDiv(b.creditShares, r, pending);
            b.creditShares -= cr;
            b.treasuryShares -= r - cr;
            uint256 assets = tv.redeem(r, address(this), address(this));
            uint256 toCredit = creditClosed ? 0 : Math.mulDiv(assets, cr, r);
            usdc.safeTransfer(config.protocolTreasury(), assets - toCredit);
            if (toCredit != 0) {
                usdc.safeTransfer(core, toCredit);
                ICreditCore(core).receiveCommunityLeg(communityId, toCredit);
            }
            emit FeesSettled(id, assets - toCredit, toCredit);
        }
    }

    // ---- impact ----

    /// Brings a vault's impact up to its venue's accumulator. Runs before every change to the
    /// vault's units, so impact is always earned on the units held while it accrued. A personal
    /// vault keeps its impact for its owner; a shared one hands it to its depositors by weight.
    function _syncVault(uint256 vaultId, Vault storage v) internal {
        uint256 acc = _books[v.venueId].impactPerUnit;
        uint256 pending = Math.mulDiv(vaultUnits[vaultId], acc - _vaultAcc[vaultId], ACC);
        _vaultAcc[vaultId] = acc;
        if (pending == 0) return;
        if (!v.shared) {
            _vaultImpact[vaultId] += pending;
        } else {
            SharedBook storage sb = _shared[vaultId];
            // A shared vault with units always has weight: units come in only by deposit, and a
            // deposit adds weight in the same step.
            sb.accPerRaw += Math.mulDiv(pending, ACC, sb.rawTotal);
        }
    }

    /// Brings a depositor's impact up to their shared vault's accumulator. A depositor from an
    /// epoch that has closed is paid up to that epoch's end and starts the current one with no
    /// weight.
    function _syncStake(uint256 vaultId, Stake storage k) internal {
        SharedBook storage sb = _shared[vaultId];
        bool current = k.epoch == sb.epoch;
        uint256 acc = current ? sb.accPerRaw : _epochAcc[vaultId][k.epoch];
        k.impact += Math.mulDiv(k.raw, acc - k.acc, ACC);
        if (!current) {
            k.raw = 0;
            k.epoch = sb.epoch;
            acc = sb.accPerRaw;
        }
        k.acc = acc;
    }

    function impactOf(address member) external view override returns (uint256 total) {
        total = _closedImpact[member];
        uint256[] storage ids = _vaultsOf[member];
        uint256 n = ids.length;
        uint256[] memory accs = _venueAccs();
        for (uint256 i; i < n; i++) {
            uint256 id = ids[i];
            Vault storage v = vaults[id];
            uint256 pending = Math.mulDiv(vaultUnits[id], accs[v.venueId] - _vaultAcc[id], ACC);
            if (!v.shared) {
                total += _vaultImpact[id] + pending;
                continue;
            }
            SharedBook storage sb = _shared[id];
            Stake storage k = _stakes[id][member];
            uint256 acc;
            if (k.epoch == sb.epoch) {
                acc = sb.accPerRaw + (pending == 0 ? 0 : Math.mulDiv(pending, ACC, sb.rawTotal));
            } else {
                acc = _epochAcc[id][k.epoch];
            }
            total += k.impact + Math.mulDiv(k.raw, acc - k.acc, ACC);
        }
    }

    function totalImpact() external view override returns (uint256 total) {
        total = _creditTaken;
        uint256 n = _wired.length;
        for (uint256 i; i < n; i++) {
            (, uint256 fee) = _preview(_wired[i]);
            total += fee;
        }
    }

    /// Each touched venue's accumulator as an accrual now would leave it, indexed by venue id.
    function _venueAccs() internal view returns (uint256[] memory accs) {
        uint256 n = _wired.length;
        uint256 top;
        for (uint256 i; i < n; i++) {
            if (_wired[i] >= top) top = uint256(_wired[i]) + 1;
        }
        accs = new uint256[](top);
        for (uint256 i; i < n; i++) {
            (VenueBook memory b,) = _preview(_wired[i]);
            accs[_wired[i]] = b.impactPerUnit;
        }
    }

    function stakeOf(uint256 vaultId, address member)
        external
        view
        override
        returns (uint256 deposited, uint64 firstDepositAt, uint256 weight)
    {
        Stake storage k = _stakes[vaultId][member];
        SharedBook storage sb = _shared[vaultId];
        weight = k.epoch == sb.epoch ? Math.mulDiv(k.raw, _scale(sb), SCALE_ONE) : 0;
        return (k.deposited, k.firstAt, weight);
    }

    function depositorCount(uint256 vaultId) external view override returns (uint256) {
        return _depositors[vaultId].length;
    }

    function _scale(SharedBook storage sb) internal view returns (uint256) {
        uint256 s = sb.scale;
        return s == 0 ? SCALE_ONE : s;
    }

    // ---- the record ----

    /// A personal vault is any member's, a shared one the host's. The venue must be listed and not
    /// retired. A Locked-kind venue takes only vaults with an unlock date in the future, because
    /// such a venue may be illiquid and that is safe only for money committed for a known period;
    /// an Open-kind venue takes none, because its vaults are open by definition.
    function createVault(VaultParams calldata p) external override returns (uint256 vaultId) {
        if (communityClosed) revert CommunityIsClosed();
        if (p.shared) {
            if (msg.sender != community.steward()) revert NotHost();
        } else if (!community.isMember(msg.sender)) {
            revert NotMember();
        }
        IVenue tv = _tier(p.venueId);
        if (!ICommunityFactory(factory).isActiveVenue(p.venueId)) revert VenueRetired();
        if (tv.labels().kind == IVenue.Kind.Locked) {
            if (p.lockedUntil <= block.timestamp) revert LockRequired();
        } else if (p.lockedUntil != 0) {
            revert LockNotAllowed();
        }

        vaultId = ++_nextVaultId;
        address owner = p.shared ? address(0) : msg.sender;
        vaults[vaultId] = Vault({
            owner: owner, shared: p.shared, venueId: p.venueId, lockedUntil: p.lockedUntil, status: VaultStatus.ACTIVE
        });
        _vaultAcc[vaultId] = _books[p.venueId].impactPerUnit;
        if (!p.shared) _addToList(msg.sender, vaultId);
        emit VaultCreated(vaultId, p.venueId, owner, p.shared, p.lockedUntil, p.name);
    }

    /// Adds a vault to a member's list, which the impact views walk. The cap keeps that walk
    /// within gas.
    function _addToList(address member, uint256 vaultId) internal {
        uint256[] storage ids = _vaultsOf[member];
        if (ids.length >= config.maxVaultsPerMember()) revert TooManyVaults();
        ids.push(vaultId);
    }

    function vaultCount() external view override returns (uint256) {
        return _nextVaultId;
    }

    function vaultsOf(address member) external view override returns (uint256[] memory) {
        return _vaultsOf[member];
    }

    function vaultValue(uint256 vaultId) public view override returns (uint256) {
        Vault storage v = vaults[vaultId];
        if (v.status == VaultStatus.NONE) return 0;
        (VenueBook memory b,) = _preview(v.venueId);
        return _unitsValue(b, v.venueId, vaultUnits[vaultId]);
    }

    function _unitsValue(VenueBook memory b, uint8 venueId, uint256 units) internal view returns (uint256) {
        if (units == 0) return 0;
        return _tierVault[venueId].convertToAssets(Math.mulDiv(units, b.shares, b.units));
    }

    function vaultEarned(uint256 vaultId) external view override returns (uint256) {
        uint256 value = vaultValue(vaultId);
        uint256 capital = vaultCapital[vaultId];
        return value > capital ? value - capital : 0;
    }

    function availableUnits(uint256 vaultId) public view override returns (uint256) {
        return vaultUnits[vaultId] - earmarkedUnits(vaultId);
    }

    function earmarkedUnits(uint256 vaultId) public view override returns (uint256) {
        uint256 id = _lastPayout[vaultId];
        if (id == 0) return 0;
        uint8 s = payoutStatus(id);
        return s == ProposalStatus.LIVE || s == ProposalStatus.PASSED ? _payouts[id].units : 0;
    }

    /// Nothing is deleted, only marked. A vault holding units cannot be closed, which is what stops
    /// a close from stranding money. A closed personal vault leaves its owner's list, and the impact
    /// it earned stays with the owner.
    function closeVault(uint256 vaultId) external override {
        Vault storage v = _liveVault(vaultId);
        if (v.shared) {
            if (msg.sender != community.steward()) revert NotHost();
        } else if (msg.sender != v.owner) {
            revert NotVaultOwner();
        }
        if (vaultUnits[vaultId] != 0) revert VaultHoldsBalance();
        _touch(v.venueId);
        v.status = VaultStatus.CLOSED;
        if (!v.shared) {
            _closedImpact[msg.sender] += _vaultImpact[vaultId];
            _vaultImpact[vaultId] = 0;
            uint256[] storage ids = _vaultsOf[msg.sender];
            uint256 n = ids.length;
            for (uint256 i; i < n; i++) {
                if (ids[i] == vaultId) {
                    ids[i] = ids[n - 1];
                    ids.pop();
                    break;
                }
            }
        }
        emit VaultClosed(vaultId);
    }

    // ---- money in ----

    /// A member deposits into their own personal vault, or into any shared vault. Refused for a
    /// non-member, which includes a frozen member and a seat that is Suspended or Left, and for a
    /// screener-blocked account. A retired venue takes no new vaults, but its existing vaults still
    /// take deposits.
    function deposit(uint256 vaultId, uint256 amount) external override {
        if (communityClosed) revert CommunityIsClosed();
        if (amount == 0) revert ZeroAmount();
        Vault storage v = _liveVault(vaultId);
        if (!community.isMember(msg.sender)) revert NotMember();
        if (!v.shared && msg.sender != v.owner) revert NotVaultOwner();
        // `blocked` covers money going into the protocol, not just draws. Attestation is not
        // re-checked: a deposit already requires a seat, and the seat mint gated it.
        if (IComplianceRegistry(config.complianceRegistry()).isBlocked(msg.sender)) revert AccountBlocked();

        uint8 venueId = v.venueId;
        _touch(venueId);
        _syncVault(vaultId, v);
        IERC20(config.usdc()).safeTransferFrom(msg.sender, address(this), amount);
        uint256 shares = _tierVault[venueId].deposit(amount, address(this));
        VenueBook storage b = _books[venueId];
        // The first units in a venue are one to one with shares. After that a deposit buys units
        // at the shares behind one unit now, so it takes no part of a gain already charged.
        uint256 units = b.units == 0 ? shares : Math.mulDiv(shares, b.units, b.shares);
        if (units == 0) revert ZeroAmount();
        b.units += units;
        b.shares += shares;
        vaultUnits[vaultId] += units;
        vaultCapital[vaultId] += amount;

        if (v.shared) {
            _sharedUnits += units;
            Stake storage k = _stakes[vaultId][msg.sender];
            if (k.firstAt == 0) {
                _addToList(msg.sender, vaultId);
                _depositors[vaultId].push(msg.sender);
                k.firstAt = uint64(block.timestamp);
                k.epoch = _shared[vaultId].epoch;
                k.acc = _shared[vaultId].accPerRaw;
            }
            _syncStake(vaultId, k);
            k.deposited += uint128(amount);
            SharedBook storage sb = _shared[vaultId];
            // Weight equal to the amount, in raw terms at the vault's current scale.
            uint256 raw = Math.mulDiv(amount, SCALE_ONE, _scale(sb));
            k.raw += raw;
            sb.rawTotal += raw;
        } else {
            personalUnitsOf[msg.sender] += units;
        }
        emit Deposited(vaultId, msg.sender, amount, units);
    }

    // ---- money out ----

    /// The units that pay `amount` now, rounded up so the vault never pays out more than it
    /// gives up. Asking for the whole of `available` by its value is never refused for rounding.
    function _unitsFor(uint8 venueId, uint256 amount, uint256 available) internal view returns (uint256 units) {
        if (available == 0) revert ExceedsWithdrawable();
        VenueBook storage b = _books[venueId];
        IVenue tv = _tierVault[venueId];
        units = Math.mulDiv(tv.previewWithdraw(amount), b.units, b.shares, Math.Rounding.Ceil);
        if (units > available) {
            if (amount > tv.convertToAssets(Math.mulDiv(available, b.shares, b.units))) revert ExceedsWithdrawable();
            units = available;
        }
    }

    /// Takes `units` off a vault and its venue: the shares behind them, and the capital share pro
    /// rata. Returns the shares and the capital taken.
    function _debit(uint256 vaultId, Vault storage v, uint256 units)
        internal
        returns (uint256 shares, uint256 capital)
    {
        VenueBook storage b = _books[v.venueId];
        shares = Math.mulDiv(units, b.shares, b.units);
        uint256 held = vaultUnits[vaultId];
        capital = Math.mulDiv(vaultCapital[vaultId], units, held);
        vaultCapital[vaultId] -= capital;
        vaultUnits[vaultId] = held - units;
        b.units -= units;
        b.shares -= shares;
    }

    /// Hands shares to the venue's queue for `receiver` and asks the venue to pay at once. A liquid
    /// venue pays in this transaction; otherwise the payment arrives when anyone processes the
    /// queue.
    function _push(IVenue tv, uint256 shares, address receiver) internal returns (uint256 venueRequestId) {
        venueRequestId = tv.requestRedeem(shares, receiver);
        try tv.processQueue(QUEUE_STEPS) {} catch {}
    }

    /// Owner only, and only past the lock. A frozen or Suspended member may withdraw, and so may one
    /// whose seat has Left: a departed member keeps their personal vaults, so nothing here reads
    /// membership. A closed community still pays out.
    function requestWithdraw(uint256 vaultId, uint256 amount) external override returns (uint256 id) {
        Vault storage v = _liveVault(vaultId);
        if (v.shared) revert SharedVaultNeedsAProposal();
        if (msg.sender != v.owner) revert NotVaultOwner();
        if (block.timestamp < v.lockedUntil) revert VaultLocked();
        if (amount == 0) revert ZeroAmount();

        uint8 venueId = v.venueId;
        _touch(venueId);
        _syncVault(vaultId, v);
        uint256 units = _unitsFor(venueId, amount, vaultUnits[vaultId]);
        (uint256 shares, uint256 capital) = _debit(vaultId, v, units);
        personalUnitsOf[msg.sender] -= units;

        if (_requests.length == 0) _requests.push();
        id = _requests.length;
        _requests.push(
            WithdrawRequest({
                vaultId: vaultId, owner: msg.sender, units: units, shares: shares, capital: capital, venueRequestId: 0
            })
        );
        uint256 venueRequestId = _push(_tierVault[venueId], shares, msg.sender);
        _requests[id].venueRequestId = venueRequestId;
        emit WithdrawRequested(id, vaultId, msg.sender, units, shares, venueRequestId);
    }

    /// Requester only, while the venue has not paid (the venue refuses a paid request). The units,
    /// the shares behind them and the capital come back exactly as they left. A vault closed since
    /// cannot take them back, so its request runs to payment.
    function cancelWithdraw(uint256 id) external override {
        WithdrawRequest storage r = _requests[id];
        if (r.owner != msg.sender || r.units == 0) revert NotRequester();
        uint256 vaultId = r.vaultId;
        Vault storage v = _liveVault(vaultId);
        uint8 venueId = v.venueId;
        _touch(venueId);
        _tierVault[venueId].cancelRedeem(r.venueRequestId);
        _syncVault(vaultId, v);

        uint256 units = r.units;
        r.units = 0;
        VenueBook storage b = _books[venueId];
        b.units += units;
        b.shares += r.shares;
        vaultUnits[vaultId] += units;
        vaultCapital[vaultId] += r.capital;
        personalUnitsOf[msg.sender] += units;
        emit WithdrawCancelled(id, vaultId);
    }

    function withdrawRequests(uint256 id)
        external
        view
        override
        returns (uint256, address, uint256, uint256, uint256, uint256)
    {
        WithdrawRequest storage r = _requests[id];
        return (r.vaultId, r.owner, r.units, r.shares, r.capital, r.venueRequestId);
    }

    function _liveVault(uint256 vaultId) internal view returns (Vault storage v) {
        v = vaults[vaultId];
        if (v.status == VaultStatus.NONE) revert UnknownVault();
        if (v.status != VaultStatus.ACTIVE) revert VaultNotActive();
    }

    // ---- the shared payout ----

    function payouts(uint256 payoutId) external view override returns (Payout memory) {
        return _payouts[payoutId];
    }

    /// The stored status, except that a live request whose window has closed reads FAILED.
    function payoutStatus(uint256 payoutId) public view override returns (uint8) {
        Payout storage p = _payouts[payoutId];
        if (p.status == ProposalStatus.LIVE && block.timestamp > p.deadline) return ProposalStatus.FAILED;
        return p.status;
    }

    function isCounted(uint256 payoutId, address member) external view override returns (bool) {
        return _stakes[_payouts[payoutId].vaultId][member].countedIn == payoutId;
    }

    function hasVoted(uint256 payoutId, address member) external view override returns (bool) {
        return _voted[payoutId][member];
    }

    /// The host asks for a fixed amount to a fixed recipient. One open request per vault, none
    /// before a locked vault's unlock date, and none within `REMOVAL_REPROPOSE_COOLDOWN` of a failed
    /// one, so members who turned a payout down are not asked again the next day. The amount is
    /// converted to units once, here, and those units are earmarked, so no price move before
    /// execution can change the recipient's claim and nothing can spend them twice.
    ///
    /// The headcount is taken now, from the vault's depositors. A member counts with an Active
    /// seasoned seat, at least `minDeposit` put in, a first deposit at least `seasoning` ago, not
    /// frozen, and not the recipient. Each counted member is stamped with this request's id, which
    /// is what the vote checks.
    function proposeWithdrawal(uint256 vaultId, address recipient, uint256 amount)
        external
        override
        returns (uint256 id)
    {
        if (communityClosed) revert CommunityIsClosed();
        Vault storage v = _liveVault(vaultId);
        if (!v.shared) revert PersonalVaultHasNoProposals();
        if (msg.sender != community.steward()) revert NotHost();
        if (block.timestamp < v.lockedUntil) revert VaultLocked();
        if (recipient == address(0)) revert ZeroAddress();
        if (amount == 0) revert ZeroAmount();
        uint256 last = _lastPayout[vaultId];
        if (last != 0) {
            uint8 s = payoutStatus(last);
            if (s == ProposalStatus.LIVE || s == ProposalStatus.PASSED) revert PayoutOpen();
            if (
                s == ProposalStatus.FAILED
                    && block.timestamp < _payouts[last].deadline + config.removalReproposeCooldown()
            ) {
                revert CooldownActive();
            }
        }
        _touch(v.venueId);
        uint256 units = _unitsFor(v.venueId, amount, vaultUnits[vaultId]);

        id = ++_nextPayoutId;
        _lastPayout[vaultId] = id;
        uint32 headcount = _countHeadcount(vaultId, recipient, id);
        // Nobody counted means nobody can vote, so the request could only expire. Refused here
        // instead, which earmarks nothing and starts no cooldown.
        if (headcount == 0) revert NoHeadcount();
        (, uint64 window) = config.communityVote();
        uint64 deadline = uint64(block.timestamp) + window;
        _payouts[id] = Payout({
            vaultId: vaultId,
            recipient: recipient,
            units: units,
            amount: amount,
            deadline: deadline,
            headcount: headcount,
            yes: 0,
            no: 0,
            status: ProposalStatus.LIVE
        });
        emit WithdrawalProposed(id, vaultId, recipient, units, amount, headcount, deadline);
    }

    /// Walks the vault's depositors once and stamps each one the headcount counts. The cheap
    /// checks on the stake come first, so only a member who could count costs a call to
    /// `Community`.
    function _countHeadcount(uint256 vaultId, address recipient, uint256 id) internal returns (uint32 headcount) {
        (uint256 minDeposit, uint64 seasoning) = config.qualifyingContributor();
        address[] storage ds = _depositors[vaultId];
        uint256 n = ds.length;
        for (uint256 i; i < n; i++) {
            address m = ds[i];
            Stake storage k = _stakes[vaultId][m];
            if (m == recipient || k.deposited < minDeposit || block.timestamp < k.firstAt + seasoning) continue;
            if (!community.isSeasoned(m) || community.isFrozen(m)) continue;
            k.countedIn = uint64(id);
            headcount++;
        }
    }

    /// One vote per counted member, inside the window. The request passes the moment the bar is
    /// met, so the vote can end early.
    function voteOnWithdrawal(uint256 id, bool support) external override {
        Payout storage p = _payouts[id];
        if (p.status != ProposalStatus.LIVE) revert ProposalNotLive();
        if (block.timestamp > p.deadline) revert VoteWindowClosed();
        if (_stakes[p.vaultId][msg.sender].countedIn != id) revert NotCounted();
        if (_voted[id][msg.sender]) revert AlreadyVoted();
        _voted[id][msg.sender] = true;
        emit WithdrawalVoteCast(id, msg.sender, support);
        if (!support) {
            p.no++;
            return;
        }
        uint32 yes = ++p.yes;
        if (_barMet(yes, p.headcount)) {
            p.status = ProposalStatus.PASSED;
            emit WithdrawalPassed(id);
        }
    }

    /// Yes votes over half the headcount and at least `MIN_YES` of them. A headcount under
    /// `MIN_YES` needs every counted member, and a headcount of 0 never passes. Non-voters count as
    /// no, because the bar is on the headcount and not on the votes cast.
    function _barMet(uint256 yes, uint256 headcount) internal pure returns (bool) {
        if (headcount < MIN_YES) return headcount != 0 && yes == headcount;
        return yes * 2 > headcount && yes >= MIN_YES;
    }

    /// Anyone, once passed. Exactly the earmarked units leave, with the shares behind them now, and
    /// the venue pays the recipient directly. Every depositor's weight shrinks in proportion.
    function executeWithdrawal(uint256 id) external override {
        Payout storage p = _payouts[id];
        if (p.status != ProposalStatus.PASSED) revert NotPassed();
        p.status = ProposalStatus.EXECUTED;
        uint256 vaultId = p.vaultId;
        Vault storage v = vaults[vaultId];
        uint8 venueId = v.venueId;
        _touch(venueId);
        _syncVault(vaultId, v);

        uint256 units = p.units;
        uint256 before = vaultUnits[vaultId];
        (uint256 shares,) = _debit(vaultId, v, units);
        _sharedUnits -= units;
        _shrinkWeights(vaultId, before - units, before);
        uint256 venueRequestId = _push(_tierVault[venueId], shares, p.recipient);
        emit WithdrawalExecuted(id, vaultId, p.recipient, units, venueRequestId);
    }

    /// Every weight in the vault times `left / before`, in one write. An empty vault closes its
    /// epoch instead: its depositors keep what they earned in it, and the next deposit starts
    /// fresh.
    function _shrinkWeights(uint256 vaultId, uint256 left, uint256 before) internal {
        SharedBook storage sb = _shared[vaultId];
        if (left == 0) {
            _epochAcc[vaultId][sb.epoch] = sb.accPerRaw;
            sb.epoch++;
            sb.accPerRaw = 0;
            sb.rawTotal = 0;
            sb.scale = SCALE_ONE;
            return;
        }
        uint256 s = Math.mulDiv(_scale(sb), left, before);
        sb.scale = s == 0 ? 1 : s;
    }

    // ---- closure ----

    function sharedVaultsHoldMoney() external view override returns (bool) {
        return _sharedUnits != 0;
    }

    /// Only this ledger's `Community` closes it, when a closure vote the members passed executes.
    /// A shared vault holding money blocks it, because nobody has a claim on one and there would be
    /// no way left to pay it out. Personal vaults do not: their owners withdraw afterwards, and they
    /// keep earning and paying the split until they do.
    function closeCommunity() external override {
        if (msg.sender != address(community)) revert NotCommunity();
        if (communityClosed) revert CommunityIsClosed();
        if (_sharedUnits != 0) revert SharedVaultHoldsBalance();
        uint256 n = _wired.length;
        for (uint256 i; i < n; i++) {
            _accrueVenue(_wired[i]);
        }
        communityClosed = true;
        emit CommunityWoundUp();
    }
}
