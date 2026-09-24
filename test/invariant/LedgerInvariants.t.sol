// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.30;

import {Test, Vm, console} from "forge-std/Test.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";
import {Clones} from "openzeppelin-contracts/contracts/proxy/Clones.sol";
import {Ledger} from "../../src/Ledger.sol";
import {ILedger} from "../../src/interfaces/ILedger.sol";
import {ICommunityInit} from "../../src/interfaces/ICommunityInit.sol";
import {Venue} from "../../src/Venue.sol";
import {Config} from "../../src/Config.sol";
import {IConfig} from "../../src/interfaces/IConfig.sol";
import {ConfigKeys as K} from "../../src/ConfigKeys.sol";
import {ComplianceRegistry} from "../../src/ComplianceRegistry.sol";
import {VenueIds} from "../helpers/VenueIds.sol";
import {MockUSDC} from "../mocks/MockUSDC.sol";
import {MockStrategy} from "../mocks/MockStrategy.sol";
import {LedgerFactoryStub, LedgerCommunityStub, LedgerCreditCoreStub} from "../helpers/LedgerFixture.sol";

/// Drives one real ledger over two real `Venue`s with deposits, withdrawals and cancels, shared
/// payouts and their votes, gains, losses, queue processing and time. Every verb no-ops rather than
/// reverting on a failed precondition, and every ghost moves only on a success path.
///
/// Each verb ends with an `accrue`, and the handler adds up the credit fee from every `Accrued`
/// event the ledger emits. That sum is the credit fee taken, counted from the events and not from
/// the ledger's own total, so the impact invariant checks one against the other.
contract LedgerHandler is Test {
    Ledger public ledger;
    Venue public flexVault;
    Venue public coreVault;
    MockStrategy public flexStrategy;
    MockStrategy public coreStrategy;
    MockUSDC public usdc;
    LedgerCommunityStub public community;

    uint256 internal constant ACTORS = 5; // index 0 is the host
    address[ACTORS] public actors;

    /// Index 0 and 1 are shared (Flex, Core); 2 to 5 personal, two per venue, owned by actors 1 to 4.
    uint256 internal constant VAULTS = 6;
    uint256[VAULTS] public vaultIds;

    uint256 internal constant MAX_DEPOSIT = 10_000e6;
    uint256 internal constant MAX_GAIN = 2_000e6;

    bytes32 internal constant ACCRUED = keccak256("Accrued(uint8,uint256,uint256,uint256)");

    /// The credit fee taken, from the ledger's events.
    uint256 public creditFeeFromEvents;
    /// The largest amount by which the members' impact has fallen short of the total, in wei.
    uint256 public maxShortfall;
    /// Landed calls per verb, and accruals that charged a fee, so a campaign can show it reached
    /// every path the invariants are about.
    mapping(bytes32 => uint256) public lands;
    uint256 public charges;

    uint256[] internal _requestIds;
    mapping(uint256 => address) internal _requester;
    uint256[] internal _payoutIds;

    constructor(
        Ledger ledger_,
        LedgerCommunityStub community_,
        MockStrategy flexStrategy_,
        MockStrategy coreStrategy_,
        address[ACTORS] memory actors_,
        uint256[VAULTS] memory ids
    ) {
        ledger = ledger_;
        flexVault = Venue(ledger_.tierVault(VenueIds.FLEX));
        coreVault = Venue(ledger_.tierVault(VenueIds.CORE));
        flexStrategy = flexStrategy_;
        coreStrategy = coreStrategy_;
        usdc = MockUSDC(ledger_.config().usdc());
        community = community_;
        actors = actors_;
        vaultIds = ids;
    }

    modifier recorded() {
        vm.recordLogs();
        _;
        ledger.accrue();
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i; i < logs.length; i++) {
            if (logs[i].emitter == address(ledger) && logs[i].topics[0] == ACCRUED) {
                (,, uint256 creditFee) = abi.decode(logs[i].data, (uint256, uint256, uint256));
                creditFeeFromEvents += creditFee;
                charges++;
            }
        }
        uint256 total = ledger.totalImpact();
        uint256 sum = sumImpact();
        if (sum <= total && total - sum > maxShortfall) maxShortfall = total - sum;
    }

    function sumImpact() public view returns (uint256 sum) {
        for (uint256 i; i < ACTORS; i++) {
            sum += ledger.impactOf(actors[i]);
        }
    }

    function _venue(uint256 seed) internal view returns (Venue) {
        return seed % 2 == 0 ? flexVault : coreVault;
    }

    function _strategy(uint256 seed) internal view returns (MockStrategy) {
        return seed % 2 == 0 ? flexStrategy : coreStrategy;
    }

    // ---- money in and out ----

    /// Into a shared vault by any member, or into a personal vault by its owner.
    function deposit(uint256 actorSeed, uint256 vaultSeed, uint256 amountSeed) external recorded {
        uint256 i = vaultSeed % VAULTS;
        uint256 id = vaultIds[i];
        address m = i < 2 ? actors[actorSeed % ACTORS] : actors[i - 1];
        uint256 amount = bound(amountSeed, 1e6, MAX_DEPOSIT);
        usdc.mint(m, amount);
        vm.startPrank(m);
        usdc.approve(address(ledger), amount);
        try ledger.deposit(id, amount) {
            lands[keccak256("deposit")]++;
        } catch {}
        vm.stopPrank();
    }

    function requestWithdraw(uint256 vaultSeed, uint256 amountSeed) external recorded {
        uint256 i = 2 + vaultSeed % 4;
        uint256 id = vaultIds[i];
        address owner = actors[i - 1];
        uint256 worth = ledger.vaultValue(id);
        if (worth == 0) return;
        vm.prank(owner);
        try ledger.requestWithdraw(id, bound(amountSeed, 1, worth)) returns (uint256 rid) {
            _requestIds.push(rid);
            _requester[rid] = owner;
            lands[keccak256("requestWithdraw")]++;
        } catch {}
    }

    /// One of the three latest requests, which are the ones most likely still unpaid.
    function cancelWithdraw(uint256 idSeed) external recorded {
        uint256 n = _requestIds.length;
        if (n == 0) return;
        uint256 id = _requestIds[n - 1 - idSeed % (n < 3 ? n : 3)];
        vm.prank(_requester[id]);
        try ledger.cancelWithdraw(id) {
            lands[keccak256("cancelWithdraw")]++;
        } catch {}
    }

    // ---- the shared payout ----

    function proposeWithdrawal(uint256 vaultSeed, uint256 amountSeed) external recorded {
        uint256 id = vaultIds[vaultSeed % 2];
        uint256 worth = ledger.vaultValue(id);
        if (worth == 0) return;
        vm.prank(actors[0]);
        try ledger.proposeWithdrawal(id, address(0xBEEF), bound(amountSeed, 1, worth)) returns (uint256 pid) {
            _payoutIds.push(pid);
            lands[keccak256("proposeWithdrawal")]++;
        } catch {}
    }

    /// On one of the two latest requests, which are the ones still open. Mostly yes.
    function voteOnWithdrawal(uint256 idSeed, uint256 actorSeed, uint256 supportSeed) external recorded {
        uint256 n = _payoutIds.length;
        if (n == 0) return;
        vm.prank(actors[actorSeed % ACTORS]);
        try ledger.voteOnWithdrawal(_payoutIds[n - 1 - idSeed % (n < 2 ? n : 2)], supportSeed % 4 != 0) {
            lands[keccak256("voteOnWithdrawal")]++;
        } catch {}
    }

    function executeWithdrawal(uint256 idSeed) external recorded {
        uint256 n = _payoutIds.length;
        if (n == 0) return;
        try ledger.executeWithdrawal(_payoutIds[n - 1 - idSeed % (n < 2 ? n : 2)]) {
            lands[keccak256("executeWithdrawal")]++;
        } catch {}
    }

    // ---- the venues underneath ----

    function gain(uint256 gainSeed, uint256 whichSeed) external recorded {
        uint256 amount = bound(gainSeed, 1, MAX_GAIN);
        usdc.mint(address(_venue(whichSeed)), amount);
    }

    function loss(uint256 lossSeed, uint256 whichSeed) external recorded {
        MockStrategy s = _strategy(whichSeed);
        uint256 held = s.totalAssets();
        if (held == 0) return;
        s.skim(bound(lossSeed, 1, held / 50 + 1));
        lands[keccak256("loss")]++;
    }

    /// Lets a strategy give its money back, or not, so requests sometimes wait in the queue and
    /// can be cancelled, and fees sometimes wait in the pending bucket.
    function setLiquid(uint256 whichSeed, bool liquid) external recorded {
        if (!liquid) {
            try _venue(whichSeed).rebalance() {} catch {}
        }
        _strategy(whichSeed).setWithdrawCap(liquid ? type(uint256).max : 0);
    }

    function rebalance(uint256 whichSeed) external recorded {
        try _venue(whichSeed).rebalance() {} catch {}
    }

    function processQueue(uint256 whichSeed) external recorded {
        try _venue(whichSeed).processQueue(5) {} catch {}
    }

    function settleFees() external recorded {
        try ledger.settleFees() {} catch {}
    }

    function warp(uint256 secondsSeed) external recorded {
        vm.warp(block.timestamp + bound(secondsSeed, 1 hours, 20 days));
    }
}

contract LedgerInvariantTest is StdInvariant, Test {
    MockUSDC usdc;
    Config config;
    LedgerFactoryStub factory;
    LedgerCommunityStub community;
    LedgerCreditCoreStub creditCore;
    Ledger ledger;
    Venue flexVault;
    Venue coreVault;
    MockStrategy flexStrategy;
    MockStrategy coreStrategy;
    LedgerHandler handler;
    address[5] actors;

    address owner = makeAddr("vaultOwner");
    address treasury = makeAddr("treasury");

    function setUp() public {
        usdc = new MockUSDC();
        ComplianceRegistry registry = new ComplianceRegistry(address(this));
        vm.prank(owner);
        config = new Config(address(usdc), treasury, address(registry));
        // Headroom so a long campaign is not spent bouncing off the deposit cap, and a slow group
        // wide enough that a withdrawal really can outrun what the venue pays at once.
        vm.startPrank(owner);
        config.set(K.GLOBAL_DEPOSIT_CAP, 100_000_000_000e6);
        config.set(K.SLOW_TIER_CEILING_BPS, 7_500);
        vm.stopPrank();

        factory = new LedgerFactoryStub();
        flexVault = new Venue(usdc, IConfig(address(config)), address(factory), owner, "Qudi Flex", "qFLEX");
        coreVault = new Venue(usdc, IConfig(address(config)), address(factory), owner, "Qudi Core", "qCORE");
        vm.startPrank(owner);
        flexVault.setLabels(VenueIds.labels(VenueIds.FLEX));
        coreVault.setLabels(VenueIds.labels(VenueIds.CORE));
        vm.stopPrank();
        flexStrategy = _strategy(flexVault);
        coreStrategy = _strategy(coreVault);
        factory.addVenue(address(flexVault));
        factory.addVenue(address(coreVault));

        community = new LedgerCommunityStub();
        creditCore = new LedgerCreditCoreStub(usdc);
        vm.prank(owner);
        config.setAddress(K.CREDIT_CORE, address(creditCore));

        ledger = Ledger(Clones.clone(address(new Ledger())));
        ledger.initialize(
            ICommunityInit.CommunityWiring({
                config: address(config),
                factory: address(factory),
                seats: address(0),
                community: address(community),
                vault: address(0),
                creator: address(0),
                seatPrice: 0,
                name: "Invariant Community",
                poolType: 0
            })
        );
        factory.register(address(ledger));

        for (uint256 i; i < 5; i++) {
            actors[i] = address(uint160(uint256(keccak256(abi.encode("ledger-actor", i)))));
            community.setMember(actors[i], true);
            community.setSeasoned(actors[i], true);
        }
        community.setSteward(actors[0]);

        uint256[6] memory ids;
        vm.startPrank(actors[0]);
        ids[0] = ledger.createVault(ILedger.VaultParams(VenueIds.FLEX, true, 0, "shared flex"));
        ids[1] = ledger.createVault(ILedger.VaultParams(VenueIds.CORE, true, 0, "shared core"));
        vm.stopPrank();
        for (uint256 i = 2; i < 6; i++) {
            vm.prank(actors[i - 1]);
            ids[i] =
                ledger.createVault(ILedger.VaultParams(i % 2 == 0 ? VenueIds.FLEX : VenueIds.CORE, false, 0, "mine"));
        }

        handler = new LedgerHandler(ledger, community, flexStrategy, coreStrategy, actors, ids);
        targetContract(address(handler));
    }

    /// A strategy listed with an exit delay, taking three quarters of the venue, so a withdrawal
    /// can outrun what the venue pays at once and go to the queue.
    function _strategy(Venue v) internal returns (MockStrategy m) {
        m = new MockStrategy(usdc, address(v));
        address[] memory vs = new address[](1);
        vs[0] = address(m);
        uint16[] memory bps = new uint16[](1);
        bps[0] = 7_500;
        vm.startPrank(owner);
        v.addStrategy(address(m), 2 days);
        v.setCap(address(m), type(uint256).max);
        v.setWeights(vs, bps);
        vm.stopPrank();
        m.setWithdrawCap(type(uint256).max);
    }

    /// A fixed 1,000-step replay over every verb, so the paths the invariants are about are shown
    /// to be reached, with stable counts, and every invariant is checked again at the end.
    function test_replay1000Steps_reachesEveryPath() public {
        bytes32 seed = keccak256("qudi.ledger-replay.v1");
        for (uint256 step; step < 1000; step++) {
            uint256 a0 = uint256(keccak256(abi.encode(seed, step, 0)));
            uint256 a1 = uint256(keccak256(abi.encode(seed, step, 1)));
            uint256 a2 = uint256(keccak256(abi.encode(seed, step, 2)));
            uint256 pick = a0 % 12;
            if (pick < 3) handler.deposit(a1, a2, a0 >> 8);
            else if (pick == 3) handler.requestWithdraw(a1, a2);
            else if (pick == 4) handler.cancelWithdraw(a1);
            else if (pick == 5) handler.proposeWithdrawal(a1, a2);
            else if (pick == 6) handler.voteOnWithdrawal(a1, a2, a0 >> 8);
            else if (pick == 7) handler.executeWithdrawal(a1);
            else if (pick == 8) handler.gain(a1, a2);
            else if (pick == 9) handler.loss(a1, a2);
            else if (pick == 10) handler.rebalance(a1);
            else if (pick == 11 && a2 % 2 == 0) handler.setLiquid(a1, a0 % 2 == 0);
            else handler.warp(a1);
            if (step % 7 == 0) handler.processQueue(a2);
            if (step % 11 == 0) handler.settleFees();
        }
        string[7] memory verbs = [
            "deposit",
            "requestWithdraw",
            "cancelWithdraw",
            "proposeWithdrawal",
            "voteOnWithdrawal",
            "executeWithdrawal",
            "loss"
        ];
        for (uint256 i; i < verbs.length; i++) {
            uint256 n = handler.lands(keccak256(bytes(verbs[i])));
            emit log_named_uint(verbs[i], n);
            assertGt(n, 0, string.concat(verbs[i], " never landed"));
        }
        emit log_named_uint("accruals that charged a fee", handler.charges());
        emit log_named_uint("largest impact shortfall, wei", handler.maxShortfall());
        assertGt(handler.charges(), 10, "the split was rarely charged");
        invariant_proof7_impactAddsUpToTheCreditFeeTaken();
        invariant_venueUnitsIsTheSumOfItsVaults();
        invariant_sharesReconcileWithTheLedgersPosition();
        invariant_earmarksAreCoveredByTheUnits();
    }

    // ---- proof 7: the impact invariant ----

    /// The members' impact adds up to the community's, and the community's is exactly the credit
    /// fee taken. Integer division floors each member's share, so the members may fall short of
    /// the total by rounding, never exceed it; the shortfall is bounded at a hundredth of a cent.
    function invariant_proof7_impactAddsUpToTheCreditFeeTaken() public view {
        uint256 total = ledger.totalImpact();
        uint256 sum = handler.sumImpact();
        assertEq(total, handler.creditFeeFromEvents(), "total impact is the credit fee taken");
        assertLe(sum, total, "members never hold more impact than was taken");
        assertLe(total - sum, 1e4, "the members' impact adds up to the total");
    }

    /// Landed counts per verb. Prints in `-vv`.
    function invariant_reportCoverage() public view {
        string[7] memory verbs = [
            "deposit",
            "requestWithdraw",
            "cancelWithdraw",
            "proposeWithdrawal",
            "voteOnWithdrawal",
            "executeWithdrawal",
            "loss"
        ];
        for (uint256 i; i < verbs.length; i++) {
            console.log(verbs[i], handler.lands(keccak256(bytes(verbs[i]))));
        }
        console.log("accruals that charged a fee", handler.charges());
        console.log("largest impact shortfall, wei", handler.maxShortfall());
    }

    // ---- reconciliation ----

    /// A venue's units are exactly the sum of its vaults' units.
    function invariant_venueUnitsIsTheSumOfItsVaults() public view {
        uint256 flex;
        uint256 core;
        for (uint256 i; i < 6; i++) {
            uint256 id = handler.vaultIds(i);
            (,, uint8 venueId,,) = ledger.vaults(id);
            if (venueId == VenueIds.FLEX) flex += ledger.vaultUnits(id);
            else core += ledger.vaultUnits(id);
        }
        assertEq(ledger.venueUnits(VenueIds.FLEX), flex);
        assertEq(ledger.venueUnits(VenueIds.CORE), core);
    }

    /// The shares behind the units and the pending fee shares are exactly what the ledger holds in
    /// each venue. Shares handed to the queue have left both sides.
    function invariant_sharesReconcileWithTheLedgersPosition() public view {
        _reconcile(VenueIds.FLEX, flexVault);
        _reconcile(VenueIds.CORE, coreVault);
    }

    function _reconcile(uint8 id, Venue v) internal view {
        (uint256 t, uint256 c) = ledger.pendingFees(id);
        assertEq(ledger.venueShares(id) + t + c, v.balanceOf(address(ledger)), "shares do not reconcile");
    }

    /// An earmark never exceeds the units its vault holds.
    function invariant_earmarksAreCoveredByTheUnits() public view {
        for (uint256 i; i < 2; i++) {
            uint256 id = handler.vaultIds(i);
            assertLe(ledger.earmarkedUnits(id), ledger.vaultUnits(id));
        }
    }

    /// No member ever holds venue shares.
    function invariant_sharesNeverHeldByMembers() public view {
        for (uint256 i; i < 5; i++) {
            assertEq(flexVault.balanceOf(actors[i]), 0);
            assertEq(coreVault.balanceOf(actors[i]), 0);
        }
    }
}
