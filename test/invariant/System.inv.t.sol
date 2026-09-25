// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.30;

import {Vm} from "forge-std/Vm.sol";
import {console} from "forge-std/console.sol";
import {Math} from "openzeppelin-contracts/contracts/utils/math/Math.sol";
import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {Ownable2Step} from "openzeppelin-contracts/contracts/access/Ownable2Step.sol";
import {TimelockController} from "openzeppelin-contracts/contracts/governance/TimelockController.sol";
import {Deploy} from "../../script/Deploy.s.sol";
import {DeployHarness} from "../Deploy.t.sol";
import {Config} from "../../src/Config.sol";
import {IConfig} from "../../src/interfaces/IConfig.sol";
import {Seats} from "../../src/Seats.sol";
import {ISeats} from "../../src/interfaces/ISeats.sol";
import {Community} from "../../src/Community.sol";
import {ICommunity} from "../../src/interfaces/ICommunity.sol";
import {Ledger} from "../../src/Ledger.sol";
import {ILedger} from "../../src/interfaces/ILedger.sol";
import {Venue} from "../../src/Venue.sol";
import {IVenue} from "../../src/interfaces/IVenue.sol";
import {ManualStrategy} from "../../src/ManualStrategy.sol";
import {CreditCore} from "../../src/CreditCore.sol";
import {ICreditCore} from "../../src/interfaces/ICreditCore.sol";
import {CreditStanding} from "../../src/CreditStanding.sol";
import {CloneImpactSource} from "../../src/CloneImpactSource.sol";
import {PauseGuard} from "../../src/PauseGuard.sol";
import {IPauseGuard} from "../../src/interfaces/IPauseGuard.sol";
import {CommunityFactory} from "../../src/CommunityFactory.sol";
import {ComplianceRegistry} from "../../src/ComplianceRegistry.sol";
import {MockUSDC} from "../mocks/MockUSDC.sol";
import {InviteSigner} from "../helpers/InviteSigner.sol";

/// Everything the deployment wires, as `script/Deploy.s.sol` wires it, handed to the fuzzer as one
/// system. Nothing here is a mock except the USDC.
///
/// The deploy runs for real: both timelocks, the handover, every role on its own key. Anything an
/// owner does afterwards goes through the timelock that owns it and waits its delay. Two
/// communities share the three venues and the credit pool: A sells a $50 seat, so its members hold
/// enough seat impact to draw, and B sells a $1 seat.
contract SystemHandler is InviteSigner {
    uint256 public constant ACTORS = 12;
    uint256 internal constant PRICE_UNIT = 1e18;

    // ---- the deployment ----

    Deploy public d;
    MockUSDC public usdc;
    Config public config;
    CommunityFactory public factory;
    Seats public seats;
    CreditCore public core;
    CreditStanding public standing;
    PauseGuard public guard;
    Venue[3] public venues;
    /// The three venue strategies, then the pool's own.
    ManualStrategy[4] public strategies;
    address public owner;
    address public operator;
    address public pauser;
    address public recipient = makeAddr("payout recipient");
    address public destination = makeAddr("listed destination");
    bytes32 public agreement;

    // ---- the communities ----

    Community[2] public communities;
    Ledger[2] public ledgers;
    uint256[2] public communityIds;
    address[ACTORS] public actors;

    /// Every vault each community has opened, in order.
    mapping(uint256 => uint256[]) internal _vaults;
    mapping(uint256 => mapping(address => mapping(uint8 => uint256))) public personalVault;
    mapping(uint256 => mapping(uint8 => uint256)) public sharedVault;
    /// How many money moves a vault has seen, which bounds its rounding.
    mapping(uint256 => mapping(uint256 => uint256)) public vaultMoves;
    /// Withdrawal requests per community, and who made them.
    mapping(uint256 => uint256[]) internal _requests;
    mapping(uint256 => uint256[]) internal _payouts;
    /// Everyone whose draw landed, so repayment picks someone with an advance.
    address[] internal _borrowers;

    // ---- ghosts ----

    /// A venue whose strategy has reported a loss. Its price may then sit below what a vault paid.
    bool[3] public lossEver;
    /// Yield paid into each strategy: `fundYield`, plus what `returnFrom` brought back above what
    /// was deployed.
    uint256[4] public yieldIn;

    uint256 public charges;
    uint256 public feeMiscounts;
    uint256 public chargedAtOrBelowPeak;
    uint256 public splitMismatches;
    uint256 public peakFell;
    uint256 public pauseBlockedAnExit;
    uint256 public overdrawLanded;
    uint256 public usurpLanded;
    string public lastBlockedExit;

    mapping(bytes32 => uint256) public tries;
    mapping(bytes32 => uint256) public lands;
    /// Exits that landed while every pause flag was set.
    mapping(bytes32 => uint256) public landsWhileAllPaused;

    bytes32 internal constant ACCRUED = keccak256("Accrued(uint8,uint256,uint256,uint256)");
    bytes32 internal constant FEES_SETTLED = keccak256("FeesSettled(uint8,uint256,uint256)");

    constructor(Deploy d_, MockUSDC usdc_, address owner_, bytes32 agreement_) {
        d = d_;
        usdc = usdc_;
        owner = owner_;
        agreement = agreement_;
        config = d_.config();
        factory = d_.factory();
        seats = d_.seats();
        core = d_.creditCore();
        standing = d_.standing();
        guard = d_.guard();
        operator = core.operator();
        pauser = guard.pauser();
        for (uint8 i; i < 3; i++) {
            venues[i] = d_.venues(i);
            strategies[i] = d_.strategies(i);
        }
        for (uint256 i; i < ACTORS; i++) {
            actors[i] = makeAddr(string.concat("actor", vm.toString(i)));
        }
    }

    // ---- set up, called once by the test ----

    function setPoolStrategy(ManualStrategy s) external {
        strategies[3] = s;
    }

    function addCommunity(uint256 i, Community c) external {
        communities[i] = c;
        ledgers[i] = Ledger(factory.ledgerOf(address(c)));
        communityIds[i] = factory.communityIdOf(address(c)) - 1;
    }

    function noteYield(uint256 s, uint256 amount) external {
        yieldIn[s] += amount;
    }

    // ---- views for the invariants ----

    function vaultCount(uint256 c) external view returns (uint256) {
        return _vaults[c].length;
    }

    function vaultAt(uint256 c, uint256 i) external view returns (uint256) {
        return _vaults[c][i];
    }

    function hosts(uint256 c) public view returns (address) {
        return communities[c].host();
    }

    /// The actors, then the two hosts.
    function people(uint256 i) public view returns (address) {
        if (i < ACTORS) return actors[i];
        return communities[i - ACTORS].host();
    }

    function peopleCount() external pure returns (uint256) {
        return ACTORS + 2;
    }

    // ---- picking ----

    function _c(uint256 seed) internal pure returns (uint256) {
        return seed % 2;
    }

    function _v(uint256 seed) internal pure returns (uint8) {
        return uint8(seed % 3);
    }

    function _actor(uint256 seed) internal view returns (address) {
        return actors[seed % ACTORS];
    }

    function _land(bytes32 verb, bool ok) internal {
        tries[verb]++;
        if (ok) lands[verb]++;
    }

    function _funded(address who, address spender, uint256 amount) internal {
        usdc.mint(who, amount);
        vm.prank(who);
        usdc.approve(spender, amount);
    }

    // ---- the fee check around every action ----

    /// Snapshots each ledger's peak and shares in each venue, records the logs of the action, and
    /// checks every accrual the action made against that snapshot. The ledger books fees only
    /// through an accrual, and every action touches a ledger at most once per venue, so the
    /// snapshot is the state each accrual started from.
    modifier recorded() {
        uint256[6] memory hwm;
        uint256[6] memory shares;
        for (uint256 c; c < 2; c++) {
            for (uint8 v; v < 3; v++) {
                hwm[c * 3 + v] = ledgers[c].highWaterPrice(v);
                shares[c * 3 + v] = ledgers[c].venueShares(v);
            }
        }
        vm.recordLogs();
        _;
        _checkFees(vm.getRecordedLogs(), hwm, shares);
        for (uint256 c; c < 2; c++) {
            for (uint8 v; v < 3; v++) {
                if (ledgers[c].highWaterPrice(v) < hwm[c * 3 + v]) peakFell++;
            }
        }
    }

    function _checkFees(Vm.Log[] memory logs, uint256[6] memory hwm, uint256[6] memory shares) internal {
        (, uint16 poolBps,) = config.yieldSplit();
        bool[6] memory seen;
        for (uint256 i; i < logs.length; i++) {
            Vm.Log memory l = logs[i];
            uint256 c;
            if (l.emitter == address(ledgers[0])) c = 0;
            else if (l.emitter == address(ledgers[1])) c = 1;
            else continue;
            uint256 k = c * 3 + uint256(l.topics[1]);
            if (l.topics[0] == ACCRUED) {
                (uint256 price, uint256 treasuryFee, uint256 creditFee) =
                    abi.decode(l.data, (uint256, uint256, uint256));
                charges++;
                if (seen[k]) continue;
                seen[k] = true;
                if (price <= hwm[k]) {
                    chargedAtOrBelowPeak++;
                    continue;
                }
                uint256 gain = Math.mulDiv(shares[k], price - hwm[k], PRICE_UNIT);
                if (creditFee != gain * poolBps / 10_000) feeMiscounts++;
                // The treasury's share goes through shares and back, so it may land a wei or two
                // under the credit share, never over.
                if (treasuryFee > creditFee || creditFee - treasuryFee > 2) splitMismatches++;
            } else if (l.topics[0] == FEES_SETTLED) {
                (uint256 toTreasury, uint256 toCredit) = abi.decode(l.data, (uint256, uint256));
                // A closed credit account sends its share to the treasury too; no closure runs here.
                uint256 diff = toTreasury > toCredit ? toTreasury - toCredit : toCredit - toTreasury;
                if (diff > 3) splitMismatches++;
            }
        }
    }

    // ---- the pause check around every exit ----

    function _flags() internal view returns (bool[3] memory f) {
        for (uint8 i; i < 3; i++) {
            f[i] = guard.paused(IPauseGuard.Flag(i));
        }
    }

    function _setFlags(bool[3] memory f) internal {
        for (uint8 i; i < 3; i++) {
            if (guard.paused(IPauseGuard.Flag(i)) != f[i]) {
                vm.prank(pauser);
                guard.setPaused(IPauseGuard.Flag(i), f[i]);
            }
        }
    }

    /// Runs an exit as `who`. If it fails while any flag is set, it runs again with every flag
    /// clear; landing then means the pause alone blocked a way out, which must never happen.
    function _exit(bytes32 verb, address who, address target, bytes memory data) internal returns (bool ok) {
        bool[3] memory f = _flags();
        bool anyPaused = f[0] || f[1] || f[2];
        vm.prank(who);
        (ok,) = target.call(data);
        if (!ok && anyPaused) {
            _setFlags([false, false, false]);
            vm.prank(who);
            (bool unpausedOk,) = target.call(data);
            _setFlags(f);
            if (unpausedOk) {
                pauseBlockedAnExit++;
                lastBlockedExit = string(abi.encodePacked(verb));
            }
        }
        if (ok && f[0] && f[1] && f[2]) landsWhileAllPaused[verb]++;
        _land(verb, ok);
    }

    // ---- joins, with invites ----

    function join(uint256 actorSeed, uint256 cSeed, uint16 usesSeed) external recorded {
        uint256 c = _c(cSeed);
        address who = _actor(actorSeed);
        Community com = communities[c];
        if (seats.seatOf(address(com), who) != 0) return;
        uint256 keyPk = uint256(keccak256(abi.encode("system invite", c, who, ++_inviteSalt)));
        address key = vm.addr(keyPk);
        (uint32 maxUses,) = config.inviteLimits();
        vm.prank(com.host());
        try com.createInvite(key, uint16(bound(usesSeed, 1, maxUses)), uint64(block.timestamp + 7 days)) {}
        catch {
            _land("join", false);
            return;
        }
        _attest(who);
        _funded(who, address(com), com.seatPrice());
        bytes memory sig = _keySign(keyPk, address(com), who);
        vm.prank(who);
        try com.join(key, sig) {
            _land("join", true);
        } catch {
            _land("join", false);
        }
    }

    function _attest(address who) internal {
        ComplianceRegistry r = d.registry();
        if (r.isAttested(who)) return;
        vm.prank(who);
        r.attest(1);
    }

    // ---- deposits and withdrawals in all three venues ----

    /// Into the actor's personal vault in the venue, opened on first use, or into the community's
    /// shared vault there, which the host opens on first use.
    function deposit(uint256 actorSeed, uint256 cSeed, uint256 vSeed, bool shared, uint256 amount) external recorded {
        uint256 c = _c(cSeed);
        uint8 v = _v(vSeed);
        address who = _actor(actorSeed);
        uint256 id = shared ? _sharedVault(c, v) : _personalVault(c, who, v, actorSeed);
        if (id == 0) return;
        amount = bound(amount, 1e6, 5_000e6);
        _funded(who, address(ledgers[c]), amount);
        vm.prank(who);
        try ledgers[c].deposit(id, amount) {
            vaultMoves[c][id]++;
            _land("deposit", true);
        } catch {
            _land("deposit", false);
        }
    }

    function _personalVault(uint256 c, address who, uint8 v, uint256 seed) internal returns (uint256 id) {
        id = personalVault[c][who][v];
        if (id != 0) return id;
        uint64 lock =
            venues[v].labels().kind == IVenue.Kind.Locked ? uint64(block.timestamp + 1 days + seed % 60 days) : 0;
        vm.prank(who);
        try ledgers[c].createVault(
            ILedger.VaultParams({venueId: v, shared: false, lockedUntil: lock, name: "mine"})
        ) returns (
            uint256 created
        ) {
            id = created;
            personalVault[c][who][v] = id;
            _vaults[c].push(id);
        } catch {}
    }

    function _sharedVault(uint256 c, uint8 v) internal returns (uint256 id) {
        id = sharedVault[c][v];
        if (id != 0) return id;
        uint64 lock = venues[v].labels().kind == IVenue.Kind.Locked ? uint64(block.timestamp + 20 days) : 0;
        vm.prank(communities[c].host());
        try ledgers[c].createVault(
            ILedger.VaultParams({venueId: v, shared: true, lockedUntil: lock, name: "ours"})
        ) returns (
            uint256 created
        ) {
            id = created;
            sharedVault[c][v] = id;
            _vaults[c].push(id);
        } catch {}
    }

    /// A withdrawal request from a personal vault, for part or all of its value. An exit.
    function requestWithdraw(uint256 cSeed, uint256 vaultSeed, uint256 amountSeed) external recorded {
        uint256 c = _c(cSeed);
        if (_vaults[c].length == 0) return;
        uint256 id = _vaults[c][vaultSeed % _vaults[c].length];
        (address vaultOwner, bool shared,,,) = ledgers[c].vaults(id);
        if (shared) return;
        uint256 value = ledgers[c].vaultValue(id);
        if (value == 0) return;
        uint256 amount = amountSeed % 4 == 0 ? value : bound(amountSeed, 1, value);
        bool ok = _exit(
            "requestWithdraw", vaultOwner, address(ledgers[c]), abi.encodeCall(ILedger.requestWithdraw, (id, amount))
        );
        if (ok) {
            vaultMoves[c][id]++;
            _requests[c].push(_nextRequestId(c));
        }
    }

    /// A low-level call returns no id. Every request on a ledger comes through this handler, and
    /// the ledger numbers them from 1, so the one that just landed is the last one plus one.
    function _nextRequestId(uint256 c) internal view returns (uint256) {
        uint256 n = _requests[c].length;
        return n == 0 ? 1 : _requests[c][n - 1] + 1;
    }

    function cancelWithdraw(uint256 cSeed, uint256 reqSeed) external recorded {
        uint256 c = _c(cSeed);
        if (_requests[c].length == 0) return;
        uint256 rid = _requests[c][reqSeed % _requests[c].length];
        (uint256 vaultId, address requester, uint256 units,,,) = ledgers[c].withdrawRequests(rid);
        if (units == 0) return;
        vm.prank(requester);
        try ledgers[c].cancelWithdraw(rid) {
            vaultMoves[c][vaultId]++;
            _land("cancelWithdraw", true);
        } catch {
            _land("cancelWithdraw", false);
        }
    }

    /// A withdrawal the venue cannot pay yet, taken back: the strategy's principal is sent out,
    /// which leaves the venue short, a member asks for the whole vault, and then cancels.
    function requestThenCancel(uint256 cSeed, uint256 actorSeed, uint256 vSeed) external recorded {
        uint256 c = _c(cSeed);
        uint8 v = _v(vSeed);
        address who = _actor(actorSeed);
        uint256 id = personalVault[c][who][v];
        if (id == 0) return;
        uint256 value = ledgers[c].vaultValue(id);
        if (value == 0) return;
        ManualStrategy s = strategies[v];
        if (s.principalHeld() != 0) {
            uint256 held = s.principalHeld();
            vm.prank(operator);
            try s.deploy(held, destination, "short") {} catch {}
        }
        vm.prank(who);
        try ledgers[c].requestWithdraw(id, value) returns (uint256 rid) {
            _requests[c].push(rid);
            vaultMoves[c][id]++;
            vm.prank(who);
            try ledgers[c].cancelWithdraw(rid) {
                vaultMoves[c][id]++;
                _land("cancelWithdraw", true);
            } catch {
                _land("cancelWithdraw", false);
            }
        } catch {}
    }

    // ---- venues: the queue, rebalancing, accrual ----

    function processQueue(uint256 vSeed, uint256 steps) external recorded {
        Venue v = venues[_v(vSeed)];
        _exit("processQueue", recipient, address(v), abi.encodeCall(IVenue.processQueue, (bound(steps, 1, 16))));
    }

    function rebalance(uint256 vSeed) external recorded {
        try venues[_v(vSeed)].rebalance() {
            _land("rebalance", true);
        } catch {
            _land("rebalance", false);
        }
    }

    function accrueVenue(uint256 vSeed) external recorded {
        Venue v = venues[_v(vSeed)];
        _exit("accrueVenue", recipient, address(v), abi.encodeCall(IVenue.accrue, ()));
    }

    function accrueLedger(uint256 cSeed) external recorded {
        Ledger l = ledgers[_c(cSeed)];
        _exit("accrueLedger", recipient, address(l), abi.encodeCall(ILedger.accrue, ()));
    }

    function settleFees(uint256 cSeed) external recorded {
        try ledgers[_c(cSeed)].settleFees() {
            _land("settleFees", true);
        } catch {
            _land("settleFees", false);
        }
    }

    // ---- strategies: gains, losses, yield funding, deploy and returnFrom ----

    function fundYield(uint256 sSeed, uint256 amount) external recorded {
        uint256 s = sSeed % 4;
        amount = bound(amount, 1, 200e6);
        _funded(operator, address(strategies[s]), amount);
        vm.prank(operator);
        strategies[s].fundYield(amount);
        yieldIn[s] += amount;
        _land("fundYield", true);
    }

    function setRate(uint256 sSeed, uint16 rate) external recorded {
        uint256 s = sSeed % 4;
        uint16 ceiling = config.manualRateCeilingBps();
        vm.prank(operator);
        strategies[s].setRate(uint16(bound(rate, 0, ceiling)));
        _land("setRate", true);
    }

    function deployOut(uint256 sSeed, uint256 amount) external recorded {
        ManualStrategy s = strategies[sSeed % 4];
        uint256 held = s.principalHeld();
        if (held == 0) return;
        vm.prank(operator);
        try s.deploy(bound(amount, 1, held), destination, "system") {
            _land("deploy", true);
        } catch {
            _land("deploy", false);
        }
    }

    /// Brings deployed principal home, and sometimes more: the excess is a gain, paid into the
    /// buffer and released at the rate.
    function returnFrom(uint256 sSeed, uint256 amount, uint256 extra) external recorded {
        uint256 s = sSeed % 4;
        uint256 out = strategies[s].principalDeployed();
        amount = bound(amount, 0, out) + bound(extra, 0, 50e6);
        if (amount == 0) return;
        _funded(operator, address(strategies[s]), amount);
        vm.prank(operator);
        strategies[s].returnFrom(amount);
        yieldIn[s] += amount > out ? amount - out : 0;
        _land("returnFrom", true);
    }

    /// A loss on deployed principal. A pool loss is kept within Qudi's own money: past it no rule
    /// inside the pool can make up money that is gone, which is the operator's risk.
    function reportLoss(uint256 sSeed, uint256 amount) external recorded {
        uint256 s = sSeed % 4;
        uint256 cap = strategies[s].principalDeployed();
        if (s == 3) cap = Math.min(cap, core.poolView().unallocated);
        if (cap == 0) return;
        vm.prank(operator);
        strategies[s].reportLoss(bound(amount, 1, cap), "system");
        if (s < 3) lossEver[s] = true;
        _land("reportLoss", true);
    }

    /// The Venue asking a strategy for one wei past what it may withdraw, which reaches into the
    /// unreleased buffer or deployed principal. It must always be refused.
    function overdraw(uint256 sSeed) external {
        ManualStrategy s = strategies[sSeed % 4];
        address v = s.venue();
        uint256 max = s.maxWithdraw();
        vm.prank(v);
        try s.withdraw(max + 1, v) {
            overdrawLanded++;
        } catch {}
        _land("overdraw", true);
    }

    // ---- shared payouts by vote ----

    function proposePayout(uint256 cSeed, uint256 vSeed, uint256 amountSeed, bool toActor) external recorded {
        uint256 c = _c(cSeed);
        uint256 id = sharedVault[c][_v(vSeed)];
        if (id == 0) return;
        uint256 value = ledgers[c].vaultValue(id);
        if (value == 0) return;
        address to = toActor ? _actor(amountSeed) : recipient;
        vm.prank(communities[c].host());
        try ledgers[c].proposeWithdrawal(id, to, bound(amountSeed, 1, value)) returns (uint256 pid) {
            _payouts[c].push(pid);
            _land("proposePayout", true);
        } catch {
            _land("proposePayout", false);
        }
    }

    /// Every member the request counted votes, most of them yes, so requests both pass and fail.
    function votePayout(uint256 cSeed, uint256 pSeed, uint256 supportSeed) external recorded {
        uint256 c = _c(cSeed);
        if (_payouts[c].length == 0) return;
        uint256 pid = _payouts[c][pSeed % _payouts[c].length];
        for (uint256 i; i < ACTORS + 2; i++) {
            address who = people(i);
            if (!ledgers[c].isCounted(pid, who) || ledgers[c].hasVoted(pid, who)) continue;
            vm.prank(who);
            try ledgers[c].voteOnWithdrawal(pid, (supportSeed >> i) % 5 != 0) {
                _land("votePayout", true);
            } catch {
                _land("votePayout", false);
            }
        }
    }

    function executePayout(uint256 cSeed, uint256 pSeed) external recorded {
        uint256 c = _c(cSeed);
        if (_payouts[c].length == 0) return;
        uint256 pid = _payouts[c][pSeed % _payouts[c].length];
        uint256 vaultId = ledgers[c].payouts(pid).vaultId;
        bool ok =
            _exit("executePayout", recipient, address(ledgers[c]), abi.encodeCall(ILedger.executeWithdrawal, (pid)));
        if (ok) vaultMoves[c][vaultId]++;
    }

    // ---- accruals and fee settlement come through every action above ----

    // ---- credit: draws, settles, write-offs, repayment after write-off ----

    function draw(uint256 actorSeed, uint256 cSeed, uint256 amount) external recorded {
        uint256 c = _c(cSeed);
        address who = _actor(actorSeed);
        uint256 line = core.standingOf(communityIds[c], who).drawable;
        amount = bound(amount, 10e6, Math.max(line, 10e6));
        vm.prank(who);
        try core.draw(communityIds[c], amount, agreement) {
            _borrowers.push(who);
            _land("draw", true);
        } catch {
            _land("draw", false);
        }
    }

    /// Repays part or all of the actor's advance, written off or not. An exit.
    function settle(uint256 actorSeed, uint256 amount) external recorded {
        if (_borrowers.length == 0) return;
        address who = _borrowers[actorSeed % _borrowers.length];
        ICreditCore.ObligationView memory o = core.obligationOf(who);
        if (o.drawTimestamp == 0 || o.closed) return;
        amount = amount % 3 == 0 ? o.principal : bound(amount, 1, o.principal + 5e6);
        _funded(who, address(core), amount);
        bytes32 verb = o.stage == ICreditCore.Stage.WrittenOff ? bytes32("settleAfterWriteOff") : bytes32("settle");
        _exit(verb, who, address(core), abi.encodeCall(CreditCore.settle, (amount)));
    }

    function materialize(uint256 actorSeed) external recorded {
        core.materialize(_actor(actorSeed));
        _land("materialize", true);
    }

    function finalizeWriteOff(uint256 actorSeed) external recorded {
        try core.finalizeWriteOff(_actor(actorSeed)) {
            _land("writeOff", true);
        } catch {
            _land("writeOff", false);
        }
    }

    /// Qudi's allocation role grants from Qudi's own money.
    function grant(uint256 cSeed, uint256 amount) external recorded {
        uint256 c = _c(cSeed);
        uint256 free = core.poolView().unallocated;
        if (free == 0) return;
        vm.prank(operator);
        try core.allocate(communityIds[c], bound(amount, 1, free), ICreditCore.AllocationType.Growth) {
            _land("grant", true);
        } catch {
            _land("grant", false);
        }
    }

    function poolDeposit(uint256 amount) external recorded {
        amount = bound(amount, 1, usdc.balanceOf(address(core)) + 1);
        vm.prank(operator);
        try core.depositToStrategy(address(strategies[3]), amount) {
            _land("poolDeposit", true);
        } catch {
            _land("poolDeposit", false);
        }
    }

    function poolWithdraw(uint256 amount) external recorded {
        amount = bound(amount, 1, strategies[3].maxWithdraw() + 1);
        vm.prank(operator);
        try core.withdrawFromStrategy(address(strategies[3]), amount) {
            _land("poolWithdraw", true);
        } catch {
            _land("poolWithdraw", false);
        }
    }

    // ---- dormancy ----

    /// A long quiet spell, then a try at sweeping each community's faded balance.
    function goQuiet(uint256 secs) external recorded {
        vm.warp(block.timestamp + bound(secs, 30 days, 400 days));
        for (uint256 c; c < 2; c++) {
            try core.sweepDormant(communityIds[c]) {
                _land("sweepDormant", true);
            } catch {
                _land("sweepDormant", false);
            }
        }
    }

    // ---- seats: removal and leaving ----

    function proposeRemoval(uint256 cSeed, uint256 actorSeed) external recorded {
        uint256 c = _c(cSeed);
        vm.prank(communities[c].host());
        try communities[c].proposeRemoval(_actor(actorSeed)) {
            _land("proposeRemoval", true);
        } catch {
            _land("proposeRemoval", false);
        }
    }

    /// Every member votes on the removal, most of them yes.
    function voteRemoval(uint256 cSeed, uint256 targetSeed, uint256 supportSeed) external recorded {
        uint256 c = _c(cSeed);
        uint256 voteId = communities[c].activeRemovalVoteId(_removalTarget(c, targetSeed));
        if (voteId == 0) return;
        for (uint256 i; i < ACTORS + 2; i++) {
            vm.prank(people(i));
            try communities[c].castVote(voteId, (supportSeed >> i) % 4 != 0) {
                _land("voteRemoval", true);
            } catch {
                _land("voteRemoval", false);
            }
        }
    }

    function executeRemoval(uint256 cSeed, uint256 targetSeed) external recorded {
        uint256 c = _c(cSeed);
        try communities[c].executeRemoval(_removalTarget(c, targetSeed)) {
            _land("executeRemoval", true);
        } catch {
            _land("executeRemoval", false);
        }
    }

    /// An actor with a removal vote open against them, if there is one.
    function _removalTarget(uint256 c, uint256 seed) internal view returns (address) {
        for (uint256 i; i < ACTORS; i++) {
            address a = actors[(seed + i) % ACTORS];
            if (communities[c].activeRemovalVoteId(a) != 0) return a;
        }
        return _actor(seed);
    }

    /// Leaving, as a member does it: every personal vault emptied first, since a seat holding a
    /// personal vault cannot be given up, then the seat.
    function forfeit(uint256 cSeed, uint256 actorSeed) external recorded {
        uint256 c = _c(cSeed);
        address who = _actor(actorSeed);
        for (uint8 v; v < 3; v++) {
            uint256 id = personalVault[c][who][v];
            if (id == 0) continue;
            uint256 value = ledgers[c].vaultValue(id);
            if (value == 0) continue;
            vm.prank(who);
            try ledgers[c].requestWithdraw(id, value) returns (uint256 rid) {
                _requests[c].push(rid);
                vaultMoves[c][id]++;
            } catch {}
        }
        vm.prank(who);
        try communities[c].forfeit() {
            _land("forfeit", true);
        } catch {
            _land("forfeit", false);
        }
    }

    // ---- pauses ----

    /// Every flag set, then each exit in turn: a withdrawal request, a repayment, the queue, a
    /// ledger's accrual and a payout. Half the time the flags stay set for what follows.
    function exitsWhilePaused(uint256 seed) external {
        _setFlags([true, true, true]);
        this.requestWithdraw(seed, seed >> 8, seed >> 16);
        this.settle(seed >> 24, seed >> 32);
        this.processQueue(seed >> 40, 8);
        this.accrueLedger(seed >> 48);
        this.accrueVenue(seed >> 56);
        this.executePayout(seed >> 64, seed >> 72);
        if (seed % 2 == 0) _setFlags([false, false, false]);
        _land("exitsWhilePaused", true);
    }

    /// Sets or clears one flag, or every flag at once.
    function pause(uint256 flagSeed, bool on) external {
        uint256 f = flagSeed % 4;
        if (f == 3) {
            _setFlags([on, on, on]);
        } else {
            vm.prank(pauser);
            guard.setPaused(IPauseGuard.Flag(f), on);
        }
        _land("pause", true);
    }

    // ---- time ----

    function warp(uint256 secs) external recorded {
        vm.warp(block.timestamp + bound(secs, 1 hours, 45 days));
        _land("warp", true);
    }

    // ---- ownership: every other key tries to take something ----

    /// Someone other than a timelock tries to take ownership of an owned contract, a strategy
    /// lister role, the pauser seat or a timelock role.
    function usurp(uint256 whoSeed, uint256 targetSeed) external {
        address who = _usurper(whoSeed);
        address[] memory owned = _owned();
        address target = owned[targetSeed % owned.length];
        vm.prank(who);
        try Ownable2Step(target).transferOwnership(who) {
            usurpLanded++;
        } catch {}
        vm.prank(who);
        try Ownable2Step(target).acceptOwnership() {
            usurpLanded++;
        } catch {}
        vm.prank(who);
        try venues[targetSeed % 3].setStrategyLister(who) {
            usurpLanded++;
        } catch {}
        vm.prank(who);
        try core.setStrategyLister(who) {
            usurpLanded++;
        } catch {}
        vm.prank(who);
        try guard.setPauser(who) {
            usurpLanded++;
        } catch {}
        TimelockController tl = targetSeed % 2 == 0 ? d.timelock() : d.timelockLong();
        bytes32 role = targetSeed % 3 == 0 ? tl.DEFAULT_ADMIN_ROLE() : tl.PROPOSER_ROLE();
        vm.prank(who);
        try tl.grantRole(role, who) {
            usurpLanded++;
        } catch {}
        _land("usurp", true);
    }

    function _usurper(uint256 seed) internal view returns (address) {
        uint256 k = seed % 7;
        if (k == 0) return d.deployer();
        if (k == 1) return operator;
        if (k == 2) return pauser;
        if (k == 3) return d.registry().screener();
        if (k == 4) return config.protocolTreasury();
        if (k == 5) return communities[seed % 2].host();
        return _actor(seed);
    }

    /// Every contract with an owner.
    function _owned() public view returns (address[] memory a) {
        a = new address[](13);
        a[0] = address(config);
        a[1] = address(factory);
        a[2] = address(core);
        a[3] = address(standing);
        a[4] = address(d.registry());
        a[5] = address(guard);
        for (uint8 i; i < 3; i++) {
            a[6 + i] = address(venues[i]);
        }
        for (uint256 i; i < 4; i++) {
            a[9 + i] = address(strategies[i]);
        }
    }
}

/// The system invariants, over the handler above.
contract SystemInvariantTest is InviteSigner {
    DeployHarness d;
    MockUSDC usdc;
    SystemHandler handler;

    address owner = makeAddr("owner");
    address pauser = makeAddr("pauser");
    address operator = makeAddr("operator");
    address screener = makeAddr("screener");
    address treasury = makeAddr("treasury");

    bytes32 constant AGREEMENT = keccak256("qudi credit agreement v1");
    uint256 constant DAY = 24 hours;
    uint256 constant WEEK = 7 days;

    function setUp() public {
        vm.chainId(31337);
        // A real chain's clock. At timestamp 1 a timelock reads an operation stamped 1 as done.
        vm.warp(1_750_000_000);
        usdc = new MockUSDC();
        d = new DeployHarness();
        d.setRecordName("system-invariant");
        d.deploy(
            Deploy.Params({
                usdc: address(usdc),
                owner: owner,
                pauser: pauser,
                operator: operator,
                screener: screener,
                treasury: treasury,
                delay: DAY,
                delayLong: WEEK,
                agreementHash: AGREEMENT,
                gitCommit: "system",
                skipSmoke: true
            })
        );
        handler = new SystemHandler(d, usdc, owner, AGREEMENT);

        _listDestinationsAndPoolStrategy();
        _fundThePool(5_000e6);
        _startYield();
        _communities();
        targetContract(address(handler));
        targetSelector(FuzzSelector({addr: address(handler), selectors: _actions()}));
    }

    /// The handler's actions. Its set-up helpers and views are left out.
    function _actions() internal pure returns (bytes4[] memory a) {
        a = new bytes4[](44);
        a[0] = SystemHandler.join.selector;
        a[1] = SystemHandler.deposit.selector;
        a[2] = SystemHandler.requestWithdraw.selector;
        a[3] = SystemHandler.cancelWithdraw.selector;
        a[4] = SystemHandler.processQueue.selector;
        a[5] = SystemHandler.rebalance.selector;
        a[6] = SystemHandler.accrueVenue.selector;
        a[7] = SystemHandler.accrueLedger.selector;
        a[8] = SystemHandler.settleFees.selector;
        a[9] = SystemHandler.fundYield.selector;
        a[10] = SystemHandler.setRate.selector;
        a[11] = SystemHandler.deployOut.selector;
        a[12] = SystemHandler.returnFrom.selector;
        a[13] = SystemHandler.reportLoss.selector;
        a[14] = SystemHandler.overdraw.selector;
        a[15] = SystemHandler.proposePayout.selector;
        a[16] = SystemHandler.votePayout.selector;
        a[17] = SystemHandler.executePayout.selector;
        a[18] = SystemHandler.draw.selector;
        a[19] = SystemHandler.settle.selector;
        a[20] = SystemHandler.materialize.selector;
        a[21] = SystemHandler.finalizeWriteOff.selector;
        a[22] = SystemHandler.grant.selector;
        a[23] = SystemHandler.poolDeposit.selector;
        a[24] = SystemHandler.poolWithdraw.selector;
        a[25] = SystemHandler.goQuiet.selector;
        a[26] = SystemHandler.proposeRemoval.selector;
        a[27] = SystemHandler.voteRemoval.selector;
        a[28] = SystemHandler.executeRemoval.selector;
        a[29] = SystemHandler.forfeit.selector;
        a[30] = SystemHandler.pause.selector;
        a[31] = SystemHandler.warp.selector;
        a[32] = SystemHandler.usurp.selector;
        // The paths that take several steps in order are drawn twice as often.
        a[33] = SystemHandler.deposit.selector;
        a[34] = SystemHandler.requestWithdraw.selector;
        a[35] = SystemHandler.proposePayout.selector;
        a[36] = SystemHandler.votePayout.selector;
        a[37] = SystemHandler.executePayout.selector;
        a[38] = SystemHandler.voteRemoval.selector;
        a[39] = SystemHandler.executeRemoval.selector;
        a[40] = SystemHandler.draw.selector;
        a[41] = SystemHandler.settle.selector;
        a[42] = SystemHandler.exitsWhilePaused.selector;
        a[43] = SystemHandler.requestThenCancel.selector;
    }

    // ---- setting up, through the timelocks ----

    /// Through the 7-day timelock, after its full delay: one destination for every strategy, and a
    /// pool strategy listed in `CreditCore`.
    function _listDestinationsAndPoolStrategy() internal {
        TimelockController tll = d.timelockLong();
        ManualStrategy pool = new ManualStrategy(
            IERC20(address(usdc)), IConfig(address(d.config())), address(d.creditCore()), address(tll), operator
        );
        handler.setPoolStrategy(pool);
        address[] memory targets = new address[](5);
        uint256[] memory values = new uint256[](5);
        bytes[] memory payloads = new bytes[](5);
        for (uint256 i; i < 4; i++) {
            targets[i] = address(handler.strategies(i));
            payloads[i] = abi.encodeCall(ManualStrategy.addDestination, (handler.destination()));
        }
        targets[4] = address(d.creditCore());
        payloads[4] = abi.encodeCall(CreditCore.addStrategy, (address(pool)));
        vm.prank(owner);
        tll.scheduleBatch(targets, values, payloads, bytes32(0), bytes32("setup"), WEEK);
        vm.warp(block.timestamp + WEEK);
        vm.prank(owner);
        tll.executeBatch(targets, values, payloads, bytes32(0), bytes32("setup"));
    }

    /// Qudi's own money into the pool, through the 24-hour timelock, so the allocation role has
    /// something to grant.
    function _fundThePool(uint256 amount) internal {
        TimelockController tl = d.timelock();
        usdc.mint(address(tl), amount);
        address[] memory targets = new address[](2);
        uint256[] memory values = new uint256[](2);
        bytes[] memory payloads = new bytes[](2);
        targets[0] = address(usdc);
        payloads[0] = abi.encodeCall(IERC20.approve, (address(d.creditCore()), amount));
        targets[1] = address(d.creditCore());
        payloads[1] = abi.encodeCall(CreditCore.fund, (amount));
        vm.prank(owner);
        tl.scheduleBatch(targets, values, payloads, bytes32(0), bytes32("fund"), DAY);
        vm.warp(block.timestamp + DAY);
        vm.prank(owner);
        tl.executeBatch(targets, values, payloads, bytes32(0), bytes32("fund"));
    }

    /// Each venue's strategy pays near its label's gross, from a funded buffer.
    function _startYield() internal {
        uint16[3] memory rates = [uint16(290), 500, 640];
        for (uint256 i; i < 3; i++) {
            ManualStrategy s = handler.strategies(i);
            vm.prank(operator);
            s.setRate(rates[i]);
            usdc.mint(operator, 100e6);
            vm.startPrank(operator);
            usdc.approve(address(s), 100e6);
            s.fundYield(100e6);
            vm.stopPrank();
            handler.noteYield(i, 100e6);
        }
    }

    /// Community A: a $50 seat, its host and six actors. Community B: a $1 seat, its host and four
    /// others. Everyone seasoned, so votes and draws can run from the first call.
    function _communities() internal {
        uint256[2] memory prices = [uint256(50e6), 1e6];
        uint256[2] memory sizes = [uint256(6), 4];
        ComplianceRegistry registry = d.registry();
        CommunityFactory factory = d.factory();
        for (uint256 c; c < 2; c++) {
            address host = makeAddr(string.concat("host", vm.toString(c)));
            vm.prank(host);
            registry.attest(1);
            vm.prank(host);
            Community com = Community(factory.createCommunity("System", prices[c]));
            handler.addCommunity(c, com);
            for (uint256 i; i < sizes[c]; i++) {
                address who = handler.actors(c * 6 + i);
                vm.prank(who);
                registry.attest(1);
                usdc.mint(who, prices[c]);
                vm.prank(who);
                usdc.approve(address(com), prices[c]);
                _joinAs(address(com), who);
            }
        }
        // Money in every venue before the fuzzer starts: each seated actor a personal vault in each
        // venue, and three of them into each community's shared Flex vault. It is seasoned with the
        // seats, so fees, payouts and withdrawals can run from the first call.
        for (uint256 c; c < 2; c++) {
            for (uint256 i; i < sizes[c]; i++) {
                for (uint256 v; v < 3; v++) {
                    handler.deposit(c * 6 + i, c, v, false, 1_000e6);
                }
                if (i < 3) handler.deposit(c * 6 + i, c, 0, true, 100e6);
            }
        }
        for (uint256 v; v < 3; v++) {
            handler.rebalance(v);
        }
        vm.warp(block.timestamp + d.config().memberSeasoningWindow());
    }

    // ---- 1. a vault's value ----

    /// A vault's value is its capital plus its unrealized gain, and the gain goes negative only
    /// through a loss: in a venue that never reported one, no vault is worth less than it holds as
    /// capital, beyond a few wei of rounding per move. The venue's vaults together are never worth
    /// more than the ledger's shares of the Venue.
    function invariant_01_vaultValueIsCapitalPlusGain() public view {
        for (uint256 c; c < 2; c++) {
            Ledger l = handler.ledgers(c);
            uint256[3] memory sum;
            for (uint256 i; i < handler.vaultCount(c); i++) {
                uint256 id = handler.vaultAt(c, i);
                (,, uint8 v,,) = l.vaults(id);
                uint256 value = l.vaultValue(id);
                uint256 capital = l.vaultCapital(id);
                sum[v] += value;
                assertEq(l.vaultEarned(id), value > capital ? value - capital : 0, "earned is value above capital");
                if (!handler.lossEver(v)) {
                    assertGe(value + 4 * handler.vaultMoves(c, id) + 4, capital, "no loss, yet value below capital");
                }
                if (l.vaultUnits(id) == 0) assertEq(value, 0, "no units, no value");
            }
            for (uint8 v; v < 3; v++) {
                Venue venue = handler.venues(v);
                assertLe(sum[v], venue.convertToAssets(venue.balanceOf(address(l))), "vaults above the ledger's share");
            }
        }
    }

    // ---- 2. the fee split ----

    /// Every accrual charges exactly 15% to credit, and the same to the treasury, of the gain
    /// above the ledger's peak price, and settles them in equal parts. The peak never falls, and
    /// no accrual charges at or below it, so after a loss nothing is charged until the price has
    /// passed the old peak.
    function invariant_02_feesAreFifteenAndFifteenAboveThePeak() public view {
        assertEq(handler.feeMiscounts(), 0, "a credit fee that is not 15% of the gain above the peak");
        assertEq(handler.splitMismatches(), 0, "the treasury and credit shares differ");
        assertEq(handler.chargedAtOrBelowPeak(), 0, "a fee charged at or below the peak");
        assertEq(handler.peakFell(), 0, "a peak price fell");
    }

    // ---- 3. impact ----

    /// Each ledger's members' yield impact adds up to the credit fee it has taken, short by
    /// rounding only, never over. No source counts impact for a Suspended or Left seat.
    function invariant_03_impactAddsUpAndStopsAtSuspendedOrLeft() public view {
        CloneImpactSource seatSource = d.seatSource();
        CloneImpactSource ledgerSource = d.ledgerSource();
        CreditStanding standing = d.standing();
        for (uint256 c; c < 2; c++) {
            Ledger l = handler.ledgers(c);
            Community com = handler.communities(c);
            uint256 id = handler.communityIds(c);
            uint256 sum;
            for (uint256 i; i < handler.peopleCount(); i++) {
                address who = handler.people(i);
                sum += l.impactOf(who);
                ICommunity.SeatState s = com.seatStateOf(who);
                if (s == ICommunity.SeatState.Suspended || s == ICommunity.SeatState.Left) {
                    assertEq(seatSource.impactOf(id, who), 0, "seat impact on a gone seat");
                    assertEq(ledgerSource.impactOf(id, who), 0, "yield impact on a gone seat");
                    assertEq(com.impactOf(id, who), 0, "community impact on a gone seat");
                    assertEq(l.impactOf(id, who), 0, "ledger impact on a gone seat");
                    assertEq(standing.impactOf(id, who), 0, "standing counts a gone seat");
                }
            }
            uint256 total = l.totalImpact();
            assertLe(sum, total, "members hold more impact than was taken");
            assertLe(total - sum, 1e4, "members' impact short of the total");
        }
    }

    // ---- 4 and 5. the pool ----

    /// No community has more out than its balance, and cash plus pool strategies cover every
    /// unlent paper balance.
    function invariant_04_noCommunityLendsPastItsBalanceAndBackingHolds() public view {
        CreditCore core = d.creditCore();
        uint256 allocated;
        uint256 outstanding;
        for (uint256 c; c < 2; c++) {
            ICreditCore.CommunityCredit memory r = core.communityCreditOf(handler.communityIds(c));
            assertLe(r.outstanding, r.allocation, "a community lent past its balance");
            allocated += r.allocation;
            outstanding += r.outstanding;
        }
        ICreditCore.PoolView memory p = core.poolView();
        assertEq(p.totalAllocated, allocated, "the total is the sum of the records");
        assertEq(p.totalOutstanding, outstanding, "the outstanding total is the sum of the records");
        assertGe(p.cash + p.strategyValue + p.totalOutstanding, p.totalAllocated, "unlent paper unbacked");
    }

    function invariant_05_bookedCashIsTheBalance() public view {
        CreditCore core = d.creditCore();
        assertEq(core.expectedCash(), usdc.balanceOf(address(core)), "booked cash is not the balance");
    }

    // ---- 6. a venue's total ----

    function invariant_06_venueTotalNeverExceedsIdlePlusStrategies() public view {
        for (uint8 v; v < 3; v++) {
            Venue venue = handler.venues(v);
            uint256 held = venue.idle();
            for (uint256 i; i < venue.strategyCount(); i++) {
                held += ManualStrategy(venue.strategies(i)).totalAssets();
            }
            assertLe(venue.totalAssets(), held, "a venue reports more than it holds");
        }
    }

    // ---- 7. ManualStrategy ----

    /// Every strategy's cash covers its principal at hand, its released yield and its unreleased
    /// buffer, each separately. Released yield plus what is still buffered never exceeds what was
    /// paid in as yield, and no Venue ever withdrew past what it may: never into the buffer.
    function invariant_07_manualStrategyReleasesOnlyFundedYield() public view {
        for (uint256 i; i < 4; i++) {
            ManualStrategy s = handler.strategies(i);
            uint256 released = s.totalAssets() - s.principalHeld() - s.principalDeployed();
            assertEq(usdc.balanceOf(address(s)), s.principalHeld() + released + s.buffer(), "cash identity");
            assertLe(released + s.buffer(), handler.yieldIn(i), "released beyond what was funded");
            assertEq(s.maxWithdraw(), s.principalHeld() + released, "withdrawable reaches the buffer");
        }
        assertEq(handler.overdrawLanded(), 0, "a Venue withdrew past what it may");
    }

    // ---- 8. seats ----

    /// `Seats` and `Community` agree on every seat's state, membership is an Active seat that is not
    /// frozen, and the Active count is `memberCount`.
    function invariant_08_seatsAndCommunityAgree() public view {
        Seats seats = d.seats();
        for (uint256 c; c < 2; c++) {
            Community com = handler.communities(c);
            for (uint256 i; i < handler.peopleCount(); i++) {
                address who = handler.people(i);
                uint256 tokenId = seats.seatOf(address(com), who);
                assertEq(com.tokenOf(who), tokenId, "the token id");
                if (tokenId == 0) {
                    assertEq(uint8(com.seatStateOf(who)), uint8(ICommunity.SeatState.None));
                    assertFalse(com.isMember(who));
                    continue;
                }
                ISeats.Seat memory seat = seats.seatInfo(tokenId);
                assertEq(uint8(com.seatStateOf(who)), uint8(seat.state), "the state");
                assertEq(
                    com.isMember(who),
                    seat.state == ICommunity.SeatState.Active && !com.isFrozen(who),
                    "membership is an Active seat that is not frozen"
                );
            }
            uint256 active;
            uint256 count = seats.seatCount(address(com));
            for (uint256 n = 1; n <= count; n++) {
                if (seats.seatInfo(seats.seatAt(address(com), n)).state == ICommunity.SeatState.Active) active++;
            }
            assertEq(active, com.memberCount(), "the Active count is memberCount");
            assertEq(active, seats.activeCount(address(com)), "Seats counts the same");
        }
    }

    // ---- 9. pauses ----

    /// Repayment, withdrawal requests, queue processing, accrual and payouts: none was ever refused
    /// because a flag was set.
    function invariant_09_everyExitWorksWhilePaused() public view {
        assertEq(handler.pauseBlockedAnExit(), 0, string.concat("a pause blocked ", handler.lastBlockedExit()));
    }

    // ---- 10. ownership ----

    /// Only the timelocks own anything: the 24-hour one owns the configuration contracts and the
    /// venues, the 7-day one owns every strategy and lists every strategy, nothing is pending, and
    /// each timelock is administered by itself alone, with the owner key as its only operator.
    function invariant_10_nobodyButTheTimelockOwnsAnything() public view {
        TimelockController tl = d.timelock();
        TimelockController tll = d.timelockLong();
        address[] memory owned = handler._owned();
        for (uint256 i; i < owned.length; i++) {
            address expected = i < 9 ? address(tl) : address(tll);
            assertEq(Ownable2Step(owned[i]).owner(), expected, "owned by the wrong key");
            assertEq(Ownable2Step(owned[i]).pendingOwner(), address(0), "an ownership is pending");
        }
        for (uint8 v; v < 3; v++) {
            assertEq(handler.venues(v).strategyLister(), address(tll), "a venue's lister moved");
        }
        assertEq(d.creditCore().strategyLister(), address(tll), "the pool's lister moved");
        assertEq(d.guard().pauser(), pauser, "the pauser moved");
        TimelockController[2] memory locks = [tl, tll];
        address[5] memory others = [d.deployer(), operator, pauser, screener, treasury];
        for (uint256 k; k < 2; k++) {
            TimelockController t = locks[k];
            assertTrue(t.hasRole(t.DEFAULT_ADMIN_ROLE(), address(t)), "a timelock stopped administering itself");
            assertFalse(t.hasRole(t.DEFAULT_ADMIN_ROLE(), owner), "the owner key administers a timelock");
            for (uint256 i; i < others.length; i++) {
                assertFalse(t.hasRole(t.PROPOSER_ROLE(), others[i]), "another key proposes");
                assertFalse(t.hasRole(t.DEFAULT_ADMIN_ROLE(), others[i]), "another key administers");
            }
            for (uint256 i; i < handler.peopleCount(); i++) {
                assertFalse(t.hasRole(t.PROPOSER_ROLE(), handler.people(i)), "a member proposes");
            }
        }
        assertEq(handler.usurpLanded(), 0, "a key other than a timelock took something");
    }

    /// Landed counts per verb. A run's counts reset with its state, so with `SYSTEM_COVERAGE=true`
    /// each run appends its counts to `cache/test-deployments/system-coverage.txt`, one line per
    /// verb: name, landed, tried, landed with every flag set. Summing the file shows the campaign
    /// reached every path.
    function afterInvariant() public {
        if (!vm.envOr("SYSTEM_COVERAGE", false)) return;
        string memory path = string.concat(vm.projectRoot(), "/cache/test-deployments/system-coverage.txt");
        string[31] memory verbs = [
            "exitsWhilePaused",
            "join",
            "deposit",
            "requestWithdraw",
            "cancelWithdraw",
            "processQueue",
            "rebalance",
            "accrueVenue",
            "accrueLedger",
            "settleFees",
            "fundYield",
            "setRate",
            "deploy",
            "returnFrom",
            "reportLoss",
            "proposePayout",
            "votePayout",
            "executePayout",
            "draw",
            "settle",
            "settleAfterWriteOff",
            "writeOff",
            "materialize",
            "grant",
            "poolDeposit",
            "poolWithdraw",
            "sweepDormant",
            "proposeRemoval",
            "executeRemoval",
            "forfeit",
            "usurp"
        ];
        for (uint256 i; i < verbs.length; i++) {
            bytes32 k = bytes32(bytes(verbs[i]));
            vm.writeLine(
                path,
                string.concat(
                    verbs[i],
                    " ",
                    vm.toString(handler.lands(k)),
                    " ",
                    vm.toString(handler.tries(k)),
                    " ",
                    vm.toString(handler.landsWhileAllPaused(k))
                )
            );
        }
        vm.writeLine(path, string.concat("charges ", vm.toString(handler.charges()), " 0 0"));
    }
}
