// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";
import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {ICreditCore} from "../../src/interfaces/ICreditCore.sol";
import {Config} from "../../src/Config.sol";
import {IConfig} from "../../src/interfaces/IConfig.sol";
import {MockUSDC} from "../mocks/MockUSDC.sol";
import {CreditStandingHarness} from "../helpers/CreditStandingHarness.sol";
import {MockCommunityFactory} from "../helpers/MockCommunityFactory.sol";
import {MockCreditCoreWiring} from "../helpers/MockCreditCoreWiring.sol";
import {console} from "forge-std/console.sol";

/// Drives every Standing state-changing path from its role and tracks the properties Standing's
/// numbers must hold: `share_i` sums to at most 1, `U_C` never decreases, both multipliers
/// stay in range, `drawable` never exceeds any single bounding term, and a scar or a
/// disqualification never raises a member's Line.
contract StandingHandler is Test {
    CreditStandingHarness public cc;
    Config public config;
    MockUSDC public usdc;
    MockCommunityFactory public factory;

    address public governance;
    address public attributor;
    address public ledger;
    address public allocationMs;

    uint256 internal constant WAD = 1e18;
    uint256 internal constant NCOMM = 2;
    address[4] public members;

    uint256 public ucFloor; // highest U_C ever seen per community, monotonic check
    mapping(uint256 => uint256) public ucSeen;
    bool public ucDecreased;
    bool public shareOverOne;
    bool public multiplierOutOfRange;
    bool public drawableOverTerm;
    bool public scarRaisedLine;
    bool public checkEnabled = true;
    address internal immutable _deployer;

    function setCheckEnabled(bool v) external {
        require(msg.sender == _deployer, "only deployer");
        checkEnabled = v;
    }

    uint256 public nonce;

    // per-method landed-attempt counts
    mapping(bytes32 => uint256) public tries;
    mapping(bytes32 => uint256) public lands;

    constructor(
        CreditStandingHarness cc_,
        Config config_,
        MockUSDC usdc_,
        MockCommunityFactory factory_,
        address governance_,
        address attributor_,
        address ledger_,
        address allocationMs_
    ) {
        _deployer = msg.sender;
        cc = cc_;
        config = config_;
        usdc = usdc_;
        factory = factory_;
        governance = governance_;
        attributor = attributor_;
        ledger = ledger_;
        allocationMs = allocationMs_;
        members[0] = makeAddr("m0");
        members[1] = makeAddr("m1");
        members[2] = makeAddr("m2");
        members[3] = makeAddr("m3");
    }

    function _m(uint256 i) internal view returns (address) {
        return members[i % members.length];
    }

    function _c(uint256 i) internal pure returns (uint256) {
        return i % NCOMM;
    }

    function _bump(bytes32 name, bool ok) internal {
        tries[name] += 1;
        if (ok) lands[name] += 1;
    }

    function _checkAll() internal {
        if (!checkEnabled) return;
        for (uint256 c; c < NCOMM; c++) {
            uint256 uc = cc.communityImpactTotal(c);
            if (uc < ucSeen[c]) ucDecreased = true;
            if (uc > ucSeen[c]) ucSeen[c] = uc;

            uint256 shareSum;
            for (uint256 i; i < members.length; i++) {
                address m = members[i];
                shareSum += cc.shareWad(c, m);

                uint256 act = cc.activityFactor(c, m);
                uint256 con = cc.conductFactor(c, m);
                uint256 floorW = uint256(config.activityFloorBps()) * WAD / 10_000;
                if (act < floorW || act > WAD) multiplierOutOfRange = true;
                if (con > WAD) multiplierOutOfRange = true;

                _checkDrawableTerms(c, m);
            }
            if (shareSum > WAD + members.length) shareOverOne = true; // +len for per-member floor slack
        }
    }

    function _checkDrawableTerms(uint256 c, address m) internal {
        (uint256 drawable,) = cc.line(c, m);
        (,, bool disq) = _counters(c, m);
        if (disq) return; // disqualified line is 0
        uint256 budget = cc.communityImpactBudget(c);
        (uint256 phaseCap, uint16 concBps,,) = config.phaseCaps(uint8(cc.phaseOf(c, m)));
        uint256 baseTe = cc.impactBase(c, m) + cc.trustExtension(c, m);
        if (
            drawable > baseTe || drawable > cc.accountExposureCap(c, m) || drawable > uint256(concBps) * budget / 10_000
                || drawable > phaseCap || drawable > config.globalMemberCap() || drawable > budget
        ) drawableOverTerm = true;
    }

    function _counters(uint256 c, address m) internal view returns (uint256, uint256, bool disq) {
        uint256 a;
        uint256 b;
        (a, b,, disq) = cc.standingCountersOf(c, m);
        return (a, b, disq);
    }

    // ---- handler verbs ----

    function accrueImpact(uint256 mi, uint256 ci, uint256 amount, uint8 src) external {
        uint256 c = _c(ci);
        address m = _m(mi);
        amount = bound(amount, 0, 5_000_000e6);
        bytes32 id = keccak256(abi.encode("evt", nonce++));
        vm.prank(attributor);
        try cc.accrueImpact(c, m, amount, ICreditCore.ImpactSource(src % 2), id, uint64(block.timestamp)) {
            _bump("accrueImpact", true);
        } catch {
            _bump("accrueImpact", false);
        }
        _checkAll();
    }

    function pokeSeasoning(uint256 mi, uint256 ci) external {
        cc.pokeSeasoning(_c(ci), _m(mi));
        _bump("pokeSeasoning", true);
        _checkAll();
    }

    function recordScar(uint256 mi, uint256 ci, uint256 wad) external {
        uint256 c = _c(ci);
        address m = _m(mi);
        wad = bound(wad, 0, WAD);
        (uint256 lineBefore,) = cc.line(c, m);
        vm.prank(ledger);
        try cc.recordScar(c, m, wad) {
            _bump("recordScar", true);
            (uint256 lineAfter,) = cc.line(c, m);
            if (lineAfter > lineBefore) scarRaisedLine = true;
        } catch {
            _bump("recordScar", false);
        }
        _checkAll();
    }

    function creditObligationCompletion(uint256 mi, uint256 ci, uint256 teInc) external {
        teInc = bound(teInc, 0, 100_000e6);
        vm.prank(ledger);
        try cc.creditObligationCompletion(_c(ci), _m(mi), teInc) {
            _bump("creditObligationCompletion", true);
        } catch {
            _bump("creditObligationCompletion", false);
        }
        _checkAll();
    }

    function creditCommunityAttributedYield(uint256 ci, uint256 amount) external {
        amount = bound(amount, 0, 50_000_000e6);
        vm.prank(attributor);
        try cc.creditCommunityAttributedYield(_c(ci), amount) {
            _bump("creditCommunityAttributedYield", true);
        } catch {
            _bump("creditCommunityAttributedYield", false);
        }
        _checkAll();
    }

    /// `disqualifyPreDefaultUnits` is deleted as an external entry point.
    /// `recordFormalDefault` is the only production path left that still sets
    /// `_preDefaultDisqualified` (through the internal `_disqualifyPreDefaultUnits` it calls),
    /// so this verb now drives that instead. It is a strictly bigger consequence than the
    /// retired call (it also sets the account-wide `_accountDefaulted` floor), which is exactly
    /// why the deleted entry point was ruled a dead, discretionary capability rather than
    /// repaired: nothing in production reached the narrower one.
    function disqualify(uint256 mi, uint256 ci) external {
        uint256 c = _c(ci);
        address m = _m(mi);
        (uint256 lineBefore,) = cc.line(c, m);
        vm.prank(ledger);
        try cc.recordFormalDefault(c, m) {
            _bump("disqualify", true);
            (uint256 lineAfter,) = cc.line(c, m);
            if (lineAfter > lineBefore) scarRaisedLine = true;
        } catch {
            _bump("disqualify", false);
        }
        _checkAll();
    }

    function setLiquid(uint256 ci, uint256 v) external {
        v = bound(v, 0, 20_000_000e6);
        cc.setCommunityLiquid(_c(ci), v);
        _bump("setLiquid", true);
        _checkAll();
    }

    /// `setOpenDelinquencyConduct` takes elapsed time, not a conduct WAD (the
    /// harness no longer reimplements the decay formula to accept an arbitrary output value
    /// directly). 400 days spans all three of `_conductDecayAt`'s regions: before Late, the
    /// linear decay to formal Default, and past it.
    function setOpenConduct(uint256 mi, uint256 ci, uint256 elapsed) external {
        cc.setOpenDelinquencyConduct(_c(ci), _m(mi), bound(elapsed, 0, 400 days));
        _bump("setOpenConduct", true);
        _checkAll();
    }

    /// `MemberTabSnapshot.openAnywhere`/`principal` (the
    /// first-access exposure headroom `cap - exp` inside `line`) had no handler verb, so `exp`
    /// was always zero across the whole campaign. `principal` is bounded well under the launch
    /// `GLOBAL_MEMBER_CAP` ($5,000e6) so the headroom this sets is usually a real, non-trivial
    /// constraint rather than always clamping to zero.
    function setMemberExposure(uint256 mi, uint256 ci, uint256 principal) external {
        cc.setMemberExposure(_c(ci), _m(mi), bound(principal, 0, 4_000e6));
        _bump("setMemberExposure", true);
        _checkAll();
    }

    function warp(uint256 s) external {
        vm.warp(block.timestamp + bound(s, 1, 60 days));
        _bump("warp", true);
        _checkAll();
    }
}

contract CreditCoreStandingInvariantTest is StdInvariant, Test {
    MockUSDC usdc;
    Config config;
    MockCommunityFactory factory;
    CreditStandingHarness cc;
    StandingHandler handler;

    address governance = makeAddr("governance");
    address attributor = makeAddr("impactAttributor");
    address ledger;
    address allocationMs = makeAddr("allocationMultisig");

    function setUp() public {
        usdc = new MockUSDC();
        config = new Config(address(usdc), makeAddr("treasury"), makeAddr("registry"));
        factory = new MockCommunityFactory();
        factory.setCommunityCount(2);
        cc = new CreditStandingHarness(IConfig(address(config)), address(factory), governance);
        // `obligationLedger` is retired in favor of `creditCore`. A mock contract
        // exposing `factory()`/`config()` matching `cc`'s own plays the gated-caller role here
        // exactly as `obligationLedger` did pre-split (`setCreditCore` calls
        // and checks both, so a bare EOA no longer works).
        ledger = address(new MockCreditCoreWiring(address(factory), address(config), address(cc)));
        vm.startPrank(governance);
        cc.setImpactAttributor(attributor);
        cc.setCreditCore(ledger);
        vm.stopPrank();
        vm.warp(1000 days);

        handler = new StandingHandler(cc, config, usdc, factory, governance, attributor, ledger, allocationMs);
        bytes4[] memory excl = new bytes4[](1);
        excl[0] = StandingHandler.setCheckEnabled.selector;
        excludeSelector(FuzzSelector({addr: address(handler), selectors: excl}));
        targetContract(address(handler));
    }

    /// Test 22: share_i sums to at most 1, and U_C never decreases.
    function invariant_shareSumAndUcMonotonic() public view {
        assertFalse(handler.shareOverOne(), "share_i sum exceeded 1");
        assertFalse(handler.ucDecreased(), "U_C decreased");
    }

    /// Test 23: activity_factor in [FLOOR, 1], conduct_factor in [0, 1], for every reachable
    /// state.
    function invariant_multipliersInRange() public view {
        assertFalse(handler.multiplierOutOfRange());
    }

    /// Test 24: drawable never exceeds any single one of its six bounding terms (checked
    /// inside the handler after every verb).
    function invariant_drawableWithinEveryTerm() public view {
        assertFalse(handler.drawableOverTerm());
    }

    /// Test 25: a scar or a disqualification never raises a member's Line.
    function invariant_scarNeverRaisesLine() public view {
        assertFalse(handler.scarRaisedLine());
    }

    /// Per-method landed-attempt counts, so the coverage is visible rather than assumed.
    /// Prints in `-vvv`.
    function invariant_reportCoverage() public view {
        console.log(
            "accrueImpact                    ", handler.lands("accrueImpact"), "/", handler.tries("accrueImpact")
        );
        console.log(
            "pokeSeasoning                   ", handler.lands("pokeSeasoning"), "/", handler.tries("pokeSeasoning")
        );
        console.log("recordScar                     ", handler.lands("recordScar"), "/", handler.tries("recordScar"));
        console.log(
            "creditObligationCompletion     ",
            handler.lands("creditObligationCompletion"),
            "/",
            handler.tries("creditObligationCompletion")
        );
        console.log(
            "creditCommunityAttributedYield ",
            handler.lands("creditCommunityAttributedYield"),
            "/",
            handler.tries("creditCommunityAttributedYield")
        );
        console.log("disqualify                     ", handler.lands("disqualify"), "/", handler.tries("disqualify"));
        console.log("setLiquid                      ", handler.lands("setLiquid"), "/", handler.tries("setLiquid"));
        console.log(
            "setOpenConduct                 ", handler.lands("setOpenConduct"), "/", handler.tries("setOpenConduct")
        );
        console.log("warp                           ", handler.lands("warp"), "/", handler.tries("warp"));
    }

    /// A fixed 4000-step deterministic replay of the handler verbs, so the per-method landed
    /// counts are a stable number. Method
    /// picks and raw arguments come only from the step index.
    function test_replay4000Steps_reportsPerMethodLandedCounts() public {
        bytes32 seed = keccak256("qudi.p1.4b.standing-replay.v1");
        handler.setCheckEnabled(false);
        for (uint256 step; step < 4000; step++) {
            uint256 a0 = uint256(keccak256(abi.encode(seed, step, 0)));
            uint256 a1 = uint256(keccak256(abi.encode(seed, step, 1)));
            uint256 a2 = uint256(keccak256(abi.encode(seed, step, 2)));
            uint256 a3 = uint256(keccak256(abi.encode(seed, step, 3)));
            uint256 pick = a0 % 10;
            if (pick == 0) {
                try handler.accrueImpact(a1, a2, a3, uint8(a0)) {} catch {}
            } else if (pick == 1) {
                try handler.pokeSeasoning(a1, a2) {} catch {}
            } else if (pick == 2) {
                try handler.recordScar(a1, a2, a3) {} catch {}
            } else if (pick == 3) {
                try handler.creditObligationCompletion(a1, a2, a3) {} catch {}
            } else if (pick == 4) {
                try handler.creditCommunityAttributedYield(a1, a2) {} catch {}
            } else if (pick == 5) {
                try handler.disqualify(a1, a2) {} catch {}
            } else if (pick == 6) {
                try handler.setLiquid(a1, a2) {} catch {}
            } else if (pick == 7) {
                try handler.setOpenConduct(a1, a2, a3) {} catch {}
            } else if (pick == 8) {
                try handler.setMemberExposure(a1, a2, a3) {} catch {}
            } else {
                try handler.warp(a1) {} catch {}
            }
        }
        emit log_named_uint("accrueImpact landed                   ", handler.lands("accrueImpact"));
        emit log_named_uint("accrueImpact attempts                 ", handler.tries("accrueImpact"));
        emit log_named_uint("pokeSeasoning landed                  ", handler.lands("pokeSeasoning"));
        emit log_named_uint("recordScar landed                     ", handler.lands("recordScar"));
        emit log_named_uint("recordScar attempts                   ", handler.tries("recordScar"));
        emit log_named_uint("creditObligationCompletion landed     ", handler.lands("creditObligationCompletion"));
        emit log_named_uint("creditCommunityAttributedYield landed ", handler.lands("creditCommunityAttributedYield"));
        emit log_named_uint("disqualify landed                     ", handler.lands("disqualify"));
        emit log_named_uint("setLiquid landed                      ", handler.lands("setLiquid"));
        emit log_named_uint("setOpenConduct landed                 ", handler.lands("setOpenConduct"));
        emit log_named_uint("setMemberExposure landed               ", handler.lands("setMemberExposure"));
        emit log_named_uint("warp landed                           ", handler.lands("warp"));
        assertGt(handler.lands("accrueImpact") * 2, handler.tries("accrueImpact"));
        assertGt(handler.lands("recordScar") * 2, handler.tries("recordScar"));
    }
}
