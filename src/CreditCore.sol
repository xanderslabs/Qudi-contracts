// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.30;

import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "openzeppelin-contracts/contracts/utils/math/Math.sol";
import {Ownable2Step, Ownable} from "openzeppelin-contracts/contracts/access/Ownable2Step.sol";
import {ICreditCore} from "./interfaces/ICreditCore.sol";
import {ICreditStanding} from "./interfaces/ICreditStanding.sol";
import {IConfig} from "./interfaces/IConfig.sol";
import {ICommunityFactory} from "./interfaces/ICommunityFactory.sol";
import {ICommunity} from "./interfaces/ICommunity.sol";
import {ILedger} from "./interfaces/ILedger.sol";
import {IComplianceRegistry} from "./interfaces/IComplianceRegistry.sol";
import {IStrategy} from "./interfaces/IStrategy.sol";
import {DebtMath} from "./DebtMath.sol";
import {StandingMath} from "./StandingMath.sol";

/// The credit pool and its ledger, one contract for every community, keyed by community id.
///
/// **One record per community:** its paper balance (`allocation`), what it has lent
/// (`outstanding`) and what it has written off. A community lends only from its own balance, so
/// Qudi needs no money of its own for anyone to draw. What a community can lend now is its
/// unlent balance, faded if the community has gone quiet.
///
/// **A loss stays where it happened.** At write-off the unpaid principal leaves that community's
/// outstanding and its balance, and no other record moves. The advance can still be repaid, and
/// every dollar repaid goes back to the same community, or to Qudi once its account has closed.
///
/// **The backing rule.** Cash plus the pool strategies always cover every unlent paper balance.
/// Every path that lowers Qudi's own money checks it: a grant, a pool strategy deposit or
/// withdrawal, and the treasury withdrawal. Draws, repayments, legs and write-offs move cash and
/// paper together, so they cannot break it. What is left over is Qudi's unallocated money: pool
/// strategy yield and losses land there, never in a community's balance.
///
/// **Liquidity.** A pool strategy deposit must leave `POOL_LIQUID_FLOOR_BPS` of the unlent balances
/// as cash. The floor limits only what the operator sends out; a draw that finds too little cash
/// reverts `PoolIlliquid` and the operator rebalances.
///
/// **Roles.** The owner is the timelock: pool strategy listing, closure, and the treasury
/// withdrawal. The operator moves money between cash and listed pool strategies within the floor.
/// The allocation multisig grants Qudi's money to communities. Nobody else moves money out.
contract CreditCore is ICreditCore, Ownable2Step {
    using SafeERC20 for IERC20;

    IERC20 public immutable usdc;
    /// Validates community ids and names each community's `Community` and `Ledger`.
    address public immutable factory;
    IConfig public immutable config;
    /// The standing half, deployed first and taken here; `CreditStanding.setCreditCore` is the
    /// one-way wire back.
    ICreditStanding public immutable standing;

    address public override operator;
    address public override allocationMultisig;

    uint256 internal constant WAD = 1e18;

    /// `healFromWad` and `healFromAt` are where the lendable share stood at the last activity and
    /// when: after a quiet spell the share heals from there rather than jumping back.
    struct CommunityRecord {
        uint256 allocation;
        uint256 outstanding;
        uint256 writtenOff;
        uint64 lastActivityAt;
        uint64 healFromAt;
        uint64 healFromWad;
        bool closed;
    }

    mapping(uint256 => CommunityRecord) internal _records;
    uint256 internal _totalAllocated;
    uint256 internal _totalOutstanding;

    /// A running mirror of `usdc.balanceOf(address(this))`, moved by exactly what every USDC path
    /// moves. Equality between the two is what proves no path moves money around the ledger.
    uint256 internal _bookedCash;

    address[] internal _strategies;
    mapping(address => bool) public isStrategy;

    /// One advance per account, across every community. A written-off advance keeps its unpaid
    /// principal so it can still be repaid; `closed` means repaid in full. `stage` is the stage as
    /// last recorded, used to see a crossing; every view derives the live stage.
    struct Obligation {
        uint128 principal;
        uint128 originalPrincipal;
        uint64 drawTimestamp;
        uint64 communityId;
        uint8 stage;
        bool writtenOff;
        bool closed;
    }

    mapping(address => Obligation) internal _tab;
    mapping(address => bool) internal _agreementAccepted;
    /// Each community's borrowers with an advance not yet repaid or written off, for the book
    /// quality gate. One advance per account and the member cap keep it short.
    mapping(uint256 => address[]) internal _openBorrowers;
    mapping(address => uint256) internal _openIndex; // position in its community's list, plus one

    constructor(
        IERC20 usdc_,
        IConfig config_,
        address factory_,
        address owner_,
        address operator_,
        address allocationMultisig_,
        ICreditStanding standing_
    ) Ownable(owner_) {
        if (
            address(usdc_) == address(0) || address(config_) == address(0) || factory_ == address(0)
                || operator_ == address(0) || allocationMultisig_ == address(0) || address(standing_) == address(0)
        ) revert ZeroAddress();
        usdc = usdc_;
        config = config_;
        factory = factory_;
        standing = standing_;
        operator = operator_;
        allocationMultisig = allocationMultisig_;
        emit OperatorSet(address(0), operator_);
        emit AllocationMultisigSet(address(0), allocationMultisig_);
    }

    // ---- roles (owner only) ----

    function setOperator(address next) external onlyOwner {
        if (next == address(0)) revert ZeroAddress();
        emit OperatorSet(operator, next);
        operator = next;
    }

    function setAllocationMultisig(address next) external onlyOwner {
        if (next == address(0)) revert ZeroAddress();
        emit AllocationMultisigSet(allocationMultisig, next);
        allocationMultisig = next;
    }

    function _requireCommunity(uint256 communityId) internal view {
        if (communityId >= ICommunityFactory(factory).communityCount()) revert UnknownCommunity();
    }

    // ---- the pool's figures ----

    function _cash() internal view returns (uint256) {
        return usdc.balanceOf(address(this));
    }

    function _strategyValue() internal view returns (uint256 total) {
        uint256 n = _strategies.length;
        for (uint256 i; i < n; i++) {
            total += IStrategy(_strategies[i]).totalAssets();
        }
    }

    /// Every community's balance less what it has lent: the paper the pool must back.
    function _unlent() internal view returns (uint256) {
        return _totalAllocated - _totalOutstanding;
    }

    /// Qudi's own money: cash and strategies above the unlent paper balances.
    function _unallocated() internal view returns (uint256) {
        uint256 assets = _cash() + _strategyValue();
        uint256 unlent = _unlent();
        return assets > unlent ? assets - unlent : 0;
    }

    function _requireBacked() internal view {
        if (_cash() + _strategyValue() < _unlent()) revert Unbacked();
    }

    function expectedCash() external view returns (uint256) {
        return _bookedCash;
    }

    function poolView() external view returns (PoolView memory v) {
        v.cash = _cash();
        v.strategyValue = _strategyValue();
        v.totalAllocated = _totalAllocated;
        v.totalOutstanding = _totalOutstanding;
        v.unallocated = _unallocated();
    }

    function strategies() external view returns (address[] memory) {
        return _strategies;
    }

    // ---- funding and allocation ----

    /// Qudi's own money in. Owner only, so no member path can put money into credit, and the sender
    /// gets no claim on it.
    function fund(uint256 amount) external onlyOwner {
        if (amount == 0) revert ZeroAmount();
        usdc.safeTransferFrom(msg.sender, address(this), amount);
        _bookedCash += amount;
        emit Funded(msg.sender, amount);
    }

    /// A grant of Qudi's money to a community. It can hand out only what is Qudi's: the backing
    /// rule refuses a grant that would leave unlent paper uncovered. A community with no activity
    /// yet starts its dormancy clock here, so a balance that only ever came from grants still fades.
    function allocate(uint256 communityId, uint256 amount, AllocationType kind) external {
        if (msg.sender != allocationMultisig) revert NotAllocationMultisig();
        _assign(communityId, amount, kind);
        if (_records[communityId].lastActivityAt == 0) _noteActivity(communityId);
        _requireBacked();
    }

    /// The door a community's own contracts pay through. The seat mint's 40% comes from its
    /// `Community`, the yield's 15% from its `Ledger`. Three gates, in order: the caller must be a
    /// contract the factory created; it must belong to the community it names, so the callee
    /// decides whose balance rises; and the USDC must already be here, which keeps the booked cash
    /// equal to the balance.
    ///
    /// The kind is derived, never supplied: the community clone pays the seat leg and any other
    /// contract of that community pays a yield leg, so no caller can label its own leg. A seat leg
    /// is community activity. A yield leg is not, because yield arrives whether or not anyone acts.
    ///
    /// No backing check: a leg raises cash and the balance by the same amount.
    function receiveCommunityLeg(uint256 communityId, uint256 amount) external {
        uint256 callerIdPlusOne = ICommunityFactory(factory).communityIdOf(msg.sender);
        if (callerIdPlusOne == 0) revert NotCommunityContract();
        if (callerIdPlusOne - 1 != communityId) revert CommunityMismatch();
        if (usdc.balanceOf(address(this)) < _bookedCash + amount) revert LegNotFunded();

        bool seatLeg = msg.sender == ICommunityFactory(factory).communityAt(communityId);
        _bookedCash += amount;
        _assign(communityId, amount, seatLeg ? AllocationType.SeatMint : AllocationType.Yield);
        if (seatLeg) _noteActivity(communityId);
    }

    function _assign(uint256 communityId, uint256 amount, AllocationType kind) internal {
        if (amount == 0) revert ZeroAmount();
        _requireCommunity(communityId);
        CommunityRecord storage r = _records[communityId];
        if (r.closed) revert CommunityIsClosed();
        r.allocation += amount;
        _totalAllocated += amount;
        emit AllocationAssigned(communityId, kind, amount, msg.sender, _unallocated(), r.allocation);
    }

    // ---- dormancy ----

    /// A deposit in the community's own ledger, or a paid seat mint in its own `Community`, by
    /// `member`. Only those two contracts of this community may report one. It is community activity
    /// and the member's own activity in the community. Both callers call it best-effort, so it can
    /// never block a deposit or a join.
    function noteActivity(uint256 communityId, address member) external {
        address community = ICommunityFactory(factory).communityAt(communityId);
        if (msg.sender != community && msg.sender != ICommunityFactory(factory).ledgerOf(community)) {
            revert NotCommunityOwnContract();
        }
        _noteActivity(communityId);
        standing.recordActivity(communityId, member);
    }

    /// Activity: a paid seat mint, a deposit, or a draw. The share heals from wherever it stands now.
    function _noteActivity(uint256 communityId) internal {
        CommunityRecord storage r = _records[communityId];
        r.healFromWad = uint64(_lendableShare(r));
        r.healFromAt = uint64(block.timestamp);
        r.lastActivityAt = uint64(block.timestamp);
    }

    /// The share of the unlent balance a community can lend now, 1e18 for all of it. After the
    /// grace with no activity it fades linearly to 0 over the fade length; activity heals it back
    /// linearly over the heal length from where it stood. The lower of the two applies. Computed on
    /// read. A community with no activity yet has nothing to fade from.
    function _lendableShare(CommunityRecord storage r) internal view returns (uint256) {
        if (r.lastActivityAt == 0) return WAD;
        (uint64 grace, uint64 fadeLength, uint64 healLength,) = config.communityDormancy();
        uint256 fade = StandingMath.dormancyDecay(block.timestamp - r.lastActivityAt, grace, fadeLength, 0);
        uint256 heal = StandingMath.healRamp(r.healFromWad, block.timestamp - r.healFromAt, healLength);
        return fade < heal ? fade : heal;
    }

    function _lendable(uint256 communityId) internal view returns (uint256) {
        CommunityRecord storage r = _records[communityId];
        return Math.mulDiv(r.allocation - r.outstanding, _lendableShare(r), WAD);
    }

    /// Anyone, once the community has been fully faded for the return period and has nothing out.
    /// The balance becomes Qudi's unallocated money, as at closure. The community is not closed:
    /// new activity starts it again, healing from nothing.
    function sweepDormant(uint256 communityId) external {
        _requireCommunity(communityId);
        CommunityRecord storage r = _records[communityId];
        (uint64 grace, uint64 fadeLength,, uint64 returnAfter) = config.communityDormancy();
        if (r.lastActivityAt == 0 || block.timestamp < uint256(r.lastActivityAt) + grace + fadeLength + returnAfter) {
            revert NotDormant();
        }
        if (r.outstanding != 0) revert CommunityHasDebt();
        uint256 returned = r.allocation;
        r.allocation = 0;
        _totalAllocated -= returned;
        emit DormantSwept(communityId, returned);
    }

    // ---- closure ----

    /// The community's balance returns to Qudi and its account closes for good. It is Qudi's money
    /// earmarked for the community, so an unspent earmark coming back is an accounting finish, not
    /// a distribution. Waits until nothing is out in the community.
    function closeCommunity(uint256 communityId) external onlyOwner {
        _requireCommunity(communityId);
        CommunityRecord storage r = _records[communityId];
        if (r.closed) revert AlreadyClosed();
        if (r.outstanding != 0) revert CommunityHasDebt();
        uint256 returned = r.allocation;
        r.allocation = 0;
        _totalAllocated -= returned;
        r.closed = true;
        emit CommunityClosed(communityId, returned);
    }

    // ---- pool strategies ----

    /// The timelock lists a strategy with this contract as its one depositor. The pool invests
    /// only here, never in member venues.
    function addStrategy(address strategy) external onlyOwner {
        if (isStrategy[strategy]) revert DuplicateStrategy();
        if (IStrategy(strategy).asset() != address(usdc)) revert StrategyAssetMismatch();
        isStrategy[strategy] = true;
        _strategies.push(strategy);
        emit StrategyAdded(strategy);
    }

    /// Only an empty position is removed: the operator brings the money back first, so removal is
    /// never a surprise redemption.
    function removeStrategy(address strategy) external onlyOwner {
        if (!isStrategy[strategy]) revert UnknownStrategy();
        if (IStrategy(strategy).totalAssets() != 0) revert StrategyHoldsBalance();
        isStrategy[strategy] = false;
        uint256 n = _strategies.length;
        for (uint256 i; i < n; i++) {
            if (_strategies[i] == strategy) {
                _strategies[i] = _strategies[n - 1];
                _strategies.pop();
                break;
            }
        }
        emit StrategyRemoved(strategy);
    }

    function _onlyOperatorOn(address strategy, uint256 amount) internal view {
        if (msg.sender != operator) revert NotOperator();
        if (!isStrategy[strategy]) revert UnknownStrategy();
        if (amount == 0) revert ZeroAmount();
    }

    /// The operator sends cash to a listed strategy. The allowance is exactly the amount and is
    /// reset after, so no strategy holds standing authority over the pool's cash. Afterwards the
    /// backing rule must hold, and the cash left must be at least the liquid floor.
    function depositToStrategy(address strategy, uint256 amount) external {
        _onlyOperatorOn(strategy, amount);
        usdc.forceApprove(strategy, amount);
        IStrategy(strategy).deposit(amount);
        usdc.forceApprove(strategy, 0);
        _bookedCash -= amount;
        _requireBacked();
        if (_cash() * 10_000 < uint256(config.poolLiquidFloorBps()) * _unlent()) revert BelowLiquidFloor();
        emit StrategyDeposit(strategy, amount);
    }

    /// The operator brings money back. Cash can only rise, so the floor is not checked: checking it
    /// could only refuse a move toward liquidity.
    function withdrawFromStrategy(address strategy, uint256 amount) external {
        _onlyOperatorOn(strategy, amount);
        uint256 before = _cash();
        IStrategy(strategy).withdraw(amount, address(this));
        uint256 received = _cash() - before;
        _bookedCash += received;
        _requireBacked();
        emit StrategyWithdraw(strategy, received);
    }

    // ---- the treasury withdrawal ----

    /// The timelock takes Qudi's own money out. It can never take a dollar that backs a community's
    /// unlent balance.
    function withdrawTreasury(address to, uint256 amount) external onlyOwner {
        if (to == address(0)) revert ZeroAddress();
        if (amount == 0) revert ZeroAmount();
        _bookedCash -= amount;
        usdc.safeTransfer(to, amount);
        _requireBacked();
        emit TreasuryWithdrawn(to, amount);
    }

    // ---- views ----

    function communityCreditOf(uint256 communityId) external view returns (CommunityCredit memory v) {
        CommunityRecord storage r = _records[communityId];
        v.allocation = r.allocation;
        v.outstanding = r.outstanding;
        v.writtenOff = r.writtenOff;
        v.lendableShareWad = _lendableShare(r);
        v.lendable = Math.mulDiv(r.allocation - r.outstanding, v.lendableShareWad, WAD);
        v.lastActivityAt = r.lastActivityAt;
        v.closed = r.closed;
    }

    function _communitySnapshot(uint256 communityId)
        internal
        view
        returns (ICreditStanding.CommunityLedgerSnapshot memory)
    {
        return ICreditStanding.CommunityLedgerSnapshot({lendable: _lendable(communityId)});
    }

    /// An advance drawn in `communityId` and not yet written off lowers conduct once it is Late.
    /// Any advance not repaid, written off or not, makes the account ineligible.
    function _tabSnapshot(uint256 communityId, address member)
        internal
        view
        returns (ICreditStanding.MemberTabSnapshot memory s)
    {
        Obligation storage o = _tab[member];
        if (o.drawTimestamp == 0 || o.closed) return s;
        s.openAnywhere = true;
        s.principal = o.principal;
        if (!o.writtenOff && o.communityId == communityId) {
            s.openInCommunity = true;
            s.elapsedSinceDraw = uint64(block.timestamp) - o.drawTimestamp;
        }
    }

    function standingOf(uint256 communityId, address member) external view returns (MemberStanding memory v) {
        _requireCommunity(communityId);
        v.agreementAccepted = _agreementAccepted[member];
        v.accountDefaulted = standing.isAccountDefaulted(member);
        (v.drawable, v.eligible) =
            standing.line(communityId, member, _communitySnapshot(communityId), _tabSnapshot(communityId, member));
    }

    // ---- the advance ----

    function _deriveStage(uint256 elapsed) internal view returns (uint8) {
        (uint64 grace, uint64 late, uint64 finalCure, uint64 dr, uint64 wo) = config.stageBoundaries();
        return DebtMath.deriveStage(elapsed, grace, late, finalCure, dr, wo);
    }

    /// An advance is drawn, not repaid, not written off, and has not silently crossed the write-off
    /// boundary.
    function hasOpenTab(address member) public view returns (bool) {
        Obligation storage o = _tab[member];
        if (o.drawTimestamp == 0 || o.closed || o.writtenOff) return false;
        return _deriveStage(block.timestamp - o.drawTimestamp) != DebtMath.STAGE_WRITTEN_OFF;
    }

    function obligationOf(address member) external view returns (ObligationView memory v) {
        Obligation storage o = _tab[member];
        v.principal = o.principal;
        v.originalPrincipal = o.originalPrincipal;
        v.payoff = o.principal;
        v.drawTimestamp = o.drawTimestamp;
        v.communityId = o.communityId;
        v.writtenOff = o.writtenOff;
        v.closed = o.closed;
        if (o.drawTimestamp != 0) {
            v.stage = Stage(o.writtenOff ? DebtMath.STAGE_WRITTEN_OFF : _deriveStage(block.timestamp - o.drawTimestamp));
            (uint64 grace, uint64 late, uint64 finalCure, uint64 dr, uint64 wo) = config.stageBoundaries();
            v.graceAt = o.drawTimestamp + grace;
            v.lateAt = o.drawTimestamp + late;
            v.finalCureAt = o.drawTimestamp + finalCure;
            v.defaultRecoveryAt = o.drawTimestamp + dr;
            v.writeOffAt = o.drawTimestamp + wo;
        }
    }

    /// Membership, the screener block and seat seasoning. A removed, departed or frozen member may
    /// repay what they hold and nothing more, so no new advance opens in their name. Repayment
    /// carries none of these gates: a community's own vote must never trap a member in a debt they
    /// are forbidden to clear.
    function _requireMember(address community, address member) internal view {
        if (!ICommunity(community).isMember(member)) revert NotAMember();
        if (IComplianceRegistry(config.complianceRegistry()).isBlocked(member)) revert AccountBlocked();
        if (block.timestamp < uint256(ICommunity(community).mintedAt(member)) + config.memberSeasoningWindow()) {
            revert NotSeasoned();
        }
    }

    /// The account's first draw must carry the hash of the Credit Agreement `Config` holds now.
    /// Returns the hash to record, or zero once the account has accepted.
    function _acceptAgreement(address member, bytes32 agreementHash) internal returns (bytes32) {
        if (_agreementAccepted[member]) return bytes32(0);
        if (agreementHash == bytes32(0) || agreementHash != config.creditAgreementHash()) revert WrongAgreement();
        _agreementAccepted[member] = true;
        return agreementHash;
    }

    /// No new draw while late plus defaulted principal is above `PORTFOLIO_QUALITY_BPS` of what the
    /// community has out. Each advance's stage comes from its own timestamp, so nobody has to have
    /// recorded it. An empty book passes.
    function _requirePortfolioQuality(uint256 communityId) internal view {
        uint256 out = _records[communityId].outstanding;
        if (out == 0) return;
        (, uint64 lateStart,,,) = config.stageBoundaries();
        address[] storage list = _openBorrowers[communityId];
        uint256 bad;
        uint256 n = list.length;
        for (uint256 i; i < n; i++) {
            Obligation storage o = _tab[list[i]];
            if (block.timestamp - o.drawTimestamp >= lateStart) bad += o.principal;
        }
        if (bad * 10_000 > uint256(config.portfolioQualityBps()) * out) revert PortfolioQualityBreached();
    }

    /// Draws `amount` from the community's own balance. In order: the community exists and has not
    /// closed, in `CreditCore` or by its members' vote; the account has no advance; the member is
    /// seated, seasoned and not blocked; the Credit Agreement; enough Active seasoned members; the
    /// ledger is accrued so the member's yield impact is current; the book is not going bad; the
    /// community can lend this much now; the member's line covers it; and the cash is here.
    function draw(uint256 communityId, uint256 amount, bytes32 agreementHash) external {
        _requireCommunity(communityId);
        if (amount == 0) revert ZeroAmount();
        address community = ICommunityFactory(factory).communityAt(communityId);
        address ledger = ICommunityFactory(factory).ledgerOf(community);
        if (_records[communityId].closed || ILedger(ledger).communityClosed()) revert CommunityIsClosed();

        address m = msg.sender;
        // A tab that silently crossed the write-off boundary is written off here first. Written off
        // or not, an advance with principal still owed blocks a new one.
        _materialize(m);
        Obligation storage o = _tab[m];
        if (o.drawTimestamp != 0 && !o.closed) revert TabAlreadyOpen();
        _requireMember(community, m);
        bytes32 recordedHash = _acceptAgreement(m, agreementHash);
        if (ICommunity(community).seasonedCount() < config.communityMinMembers()) revert TooFewMembers();

        ILedger(ledger).accrue();
        _requirePortfolioQuality(communityId);
        if (amount > _lendable(communityId)) revert ExceedsAvailable();
        (uint256 drawable, bool eligible) =
            standing.line(communityId, m, _communitySnapshot(communityId), _tabSnapshot(communityId, m));
        if (!eligible) revert NotEligible();
        if (amount > drawable) revert ExceedsLine();
        if (_cash() < amount) revert PoolIlliquid();

        _tab[m] = Obligation({
            principal: uint128(amount),
            originalPrincipal: uint128(amount),
            drawTimestamp: uint64(block.timestamp),
            communityId: uint64(communityId),
            stage: DebtMath.STAGE_TENOR,
            writtenOff: false,
            closed: false
        });
        _records[communityId].outstanding += amount;
        _totalOutstanding += amount;
        _openBorrowers[communityId].push(m);
        _openIndex[m] = _openBorrowers[communityId].length;
        _noteActivity(communityId);

        _bookedCash -= amount;
        usdc.safeTransfer(m, amount);
        emit Drawn(communityId, m, amount, uint64(block.timestamp), recordedHash);
    }

    function _removeOpen(uint256 communityId, address member) internal {
        address[] storage list = _openBorrowers[communityId];
        uint256 i = _openIndex[member] - 1;
        address last = list[list.length - 1];
        list[i] = last;
        _openIndex[last] = i + 1;
        list.pop();
        delete _openIndex[member];
    }

    // ---- settle: one to one against principal, always open ----

    /// Repays the caller's own advance. Anything over the principal is refunded. Before write-off a
    /// payment lowers what the community has out; after it, the loss already came out of the
    /// community's balance, so the payment puts it back there, or becomes Qudi's money once the
    /// community's account has closed. Nothing else can block it.
    function settle(uint256 amount) external {
        address m = msg.sender;
        _materialize(m);
        Obligation storage o = _tab[m];
        if (o.drawTimestamp == 0 || o.closed) revert NoOpenTab();
        if (amount == 0) revert ZeroAmount();

        uint256 owed = o.principal;
        uint256 retire = amount < owed ? amount : owed;
        uint256 refund = amount - retire;
        uint256 communityId = o.communityId;

        usdc.safeTransferFrom(m, address(this), amount);
        _bookedCash += amount;
        if (refund != 0) {
            usdc.safeTransfer(m, refund);
            _bookedCash -= refund;
        }

        o.principal = uint128(owed - retire);
        CommunityRecord storage r = _records[communityId];
        if (o.writtenOff) {
            if (!r.closed) {
                r.allocation += retire;
                _totalAllocated += retire;
            }
        } else {
            r.outstanding -= retire;
            _totalOutstanding -= retire;
        }

        bool closedNow = o.principal == 0;
        if (closedNow) _closeTab(m, o);
        emit Settled(communityId, m, retire, refund, o.principal, closedNow);
    }

    /// Repaid in full. A defaulted advance, before or after write-off, starts the default's cooling.
    /// Any other counts toward the member's phase, and one repaid after Late leaves a scar at the
    /// conduct value of that moment.
    function _closeTab(address member, Obligation storage o) internal {
        o.closed = true;
        uint256 communityId = o.communityId;
        if (!o.writtenOff) _removeOpen(communityId, member);
        if (o.stage >= DebtMath.STAGE_DEFAULT_RECOVERY) {
            standing.recordDefaultRepaid(member);
            return;
        }
        if (o.stage >= DebtMath.STAGE_LATE) {
            standing.recordScar(communityId, member, standing.conductDecayAt(block.timestamp - o.drawTimestamp));
        }
        standing.recordRepaid(communityId, member);
    }

    // ---- the stage machine ----

    /// Records the stage the advance has reached by its timestamp, and applies a crossing's one-time
    /// consequence: formal default at Default Recovery, the write-off at its boundary. A no-op with
    /// nothing open. Every debt entry point runs it first.
    function _materialize(address member) internal {
        Obligation storage o = _tab[member];
        if (o.drawTimestamp == 0 || o.closed || o.writtenOff) return;
        uint8 next = _deriveStage(block.timestamp - o.drawTimestamp);
        if (next == o.stage) return;
        if (next == DebtMath.STAGE_WRITTEN_OFF) {
            _executeWriteOff(member, o);
            return;
        }
        if (next >= DebtMath.STAGE_DEFAULT_RECOVERY && o.stage < DebtMath.STAGE_DEFAULT_RECOVERY) {
            standing.recordFormalDefault(o.communityId, member);
        }
        o.stage = next;
    }

    /// Anyone. It can only record a crossing the timestamp has already made: no caller chooses a
    /// stage, moves one early, or holds one back.
    function materialize(address member) external {
        _materialize(member);
    }

    function finalizeWriteOff(address member) external {
        Obligation storage o = _tab[member];
        if (o.drawTimestamp == 0 || o.closed) revert NoOpenTab();
        if (o.writtenOff) revert AlreadyWrittenOff();
        (,,,, uint64 wo) = config.stageBoundaries();
        if (block.timestamp - o.drawTimestamp < wo) revert NotYetWrittenOff();
        _materialize(member);
    }

    /// The unpaid principal leaves the community's outstanding and its balance together, so the
    /// loss is that community's alone and no other record moves. The default is recorded here too
    /// if the crossing was skipped between touches. The principal stays on the advance, owed.
    function _executeWriteOff(address member, Obligation storage o) internal {
        uint256 principal = o.principal;
        uint256 communityId = o.communityId;
        standing.recordFormalDefault(communityId, member);

        CommunityRecord storage r = _records[communityId];
        uint256 allocationBefore = r.allocation;
        r.outstanding -= principal;
        _totalOutstanding -= principal;
        r.allocation = allocationBefore - principal;
        _totalAllocated -= principal;
        r.writtenOff += principal;
        _removeOpen(communityId, member);

        o.writtenOff = true;
        o.stage = DebtMath.STAGE_WRITTEN_OFF;
        emit WriteOffFinalized(communityId, member, principal, allocationBefore, r.allocation);
    }
}
