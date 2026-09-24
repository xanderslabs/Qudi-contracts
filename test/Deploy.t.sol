// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {Ownable} from "openzeppelin-contracts/contracts/access/Ownable.sol";
import {Ownable2Step} from "openzeppelin-contracts/contracts/access/Ownable2Step.sol";
import {TimelockController} from "openzeppelin-contracts/contracts/governance/TimelockController.sol";
import {Deploy} from "../script/Deploy.s.sol";
import {CheckDeployment} from "../script/CheckDeployment.s.sol";
import {ConfigKeys as K} from "../src/ConfigKeys.sol";
import {IVenue} from "../src/interfaces/IVenue.sol";
import {IPauseGuard} from "../src/interfaces/IPauseGuard.sol";
import {ManualStrategy} from "../src/ManualStrategy.sol";
import {CreditCore} from "../src/CreditCore.sol";
import {Config} from "../src/Config.sol";
import {MockUSDC} from "./mocks/MockUSDC.sol";
import {MockStrategy} from "./mocks/MockStrategy.sol";
import {CaliburPin} from "../script/CaliburPin.sol";

/// Writes its record under cache, so a test run never touches the committed records. Tests run in
/// parallel, so a test that reads its record back names its own file.
contract DeployHarness is Deploy {
    string public recordName = "31337";

    function setRecordName(string memory name) external {
        recordName = name;
    }

    function _recordDir() internal view override returns (string memory) {
        return string.concat(vm.projectRoot(), "/cache/test-deployments");
    }

    function recordPath() public view returns (string memory) {
        return string.concat(_recordDir(), "/", recordName, ".json");
    }

    function _recordPath() internal view override returns (string memory) {
        return recordPath();
    }
}

/// The deployment as the beta runs it. One key owns everything through two timelocks: 24 hours for
/// configuration, 7 days for anything that could send member money somewhere new. The deployer
/// hands everything over and keeps nothing, and the record it writes is enough for
/// `CheckDeployment` to prove every wiring fact.
contract DeployTest is Test {
    DeployHarness d;
    MockUSDC usdc;
    Deploy.Params p;

    address owner = makeAddr("owner");
    address pauser = makeAddr("pauser");
    address operator = makeAddr("operator");
    address screener = makeAddr("screener");
    address treasury = makeAddr("treasury");
    address stranger = makeAddr("stranger");

    bytes32 constant AGREEMENT = keccak256("qudi credit agreement v1");
    uint256 constant DAY = 24 hours;
    uint256 constant WEEK = 7 days;

    function setUp() public {
        vm.chainId(31337);
        // A real chain's clock. At timestamp 1 a timelock reads an operation stamped 1 as done.
        vm.warp(1_750_000_000);
        usdc = new MockUSDC();
        p = Deploy.Params({
            usdc: address(usdc),
            owner: owner,
            pauser: pauser,
            operator: operator,
            screener: screener,
            treasury: treasury,
            delay: DAY,
            delayLong: WEEK,
            agreementHash: AGREEMENT,
            gitCommit: "test",
            skipSmoke: false
        });
        d = new DeployHarness();
    }

    /// Uniswap's Calibur runtime, as it sits at the canonical address on Arc mainnet and Ethereum,
    /// put where the deploy looks for it. Checked against the pinned hash first, so the fixture
    /// cannot drift.
    function _calibur() internal {
        bytes memory code =
            vm.parseBytes(vm.readFile(string.concat(vm.projectRoot(), "/test/fixtures/CaliburEntry.runtime.hex")));
        assertEq(keccak256(code), CaliburPin.RUNTIME_CODE_HASH, "the fixture is the pinned runtime");
        vm.etch(CaliburPin.CANONICAL, code);
    }

    function _deploy() internal {
        _calibur();
        d.deploy(p);
    }

    function _check() internal returns (bool) {
        CheckDeployment c = new CheckDeployment();
        return c.check(
            d.recordPath(),
            CheckDeployment.Expected({usdc: address(usdc), delay: DAY, delayLong: WEEK, agreementHash: AGREEMENT})
        );
    }

    /// Every contract the deploy hands to the 24-hour timelock.
    function _ownedByTimelock() internal view returns (address[] memory a) {
        a = new address[](9);
        a[0] = address(d.config());
        a[1] = address(d.factory());
        a[2] = address(d.creditCore());
        a[3] = address(d.standing());
        a[4] = address(d.registry());
        a[5] = address(d.guard());
        for (uint8 i; i < 3; i++) {
            a[6 + i] = address(d.venues(i));
        }
    }

    // ---- proof 5: the handover ----

    function test_proof5_theDeployerOwnsNothingAfterTheDeploy() public {
        _deploy();
        address deployer = d.deployer();
        address tl = address(d.timelock());
        address tll = address(d.timelockLong());

        address[] memory a = _ownedByTimelock();
        for (uint256 i; i < a.length; i++) {
            assertEq(Ownable(a[i]).owner(), tl, "owned by the 24-hour timelock");
            assertEq(Ownable2Step(a[i]).pendingOwner(), address(0), "nothing pending");
        }
        for (uint8 i; i < 3; i++) {
            assertEq(d.strategies(i).owner(), tll, "each strategy is owned by the 7-day timelock");
            assertEq(d.strategies(i).pendingOwner(), address(0));
            assertEq(d.venues(i).strategyLister(), tll, "each venue's strategy lister is the 7-day timelock");
        }
        assertEq(d.creditCore().strategyLister(), tll, "the pool's strategy lister is the 7-day timelock");

        TimelockController[2] memory locks = [d.timelock(), d.timelockLong()];
        bytes32[4] memory roles = [
            locks[0].DEFAULT_ADMIN_ROLE(), locks[0].PROPOSER_ROLE(), locks[0].EXECUTOR_ROLE(), locks[0].CANCELLER_ROLE()
        ];
        for (uint256 l; l < 2; l++) {
            for (uint256 r; r < 4; r++) {
                assertFalse(locks[l].hasRole(roles[r], deployer), "the deployer holds no timelock role");
            }
            assertTrue(locks[l].hasRole(roles[0], address(locks[l])), "each timelock administers itself");
            assertFalse(locks[l].hasRole(roles[0], owner), "and nobody else does");
            for (uint256 r = 1; r < 4; r++) {
                assertTrue(locks[l].hasRole(roles[r], owner), "the owner key proposes, executes and cancels");
            }
            assertFalse(locks[l].hasRole(roles[2], address(0)), "execution is not open to anyone");
        }
        assertEq(d.timelock().getMinDelay(), DAY);
        assertEq(d.timelockLong().getMinDelay(), WEEK);
    }

    // ---- the roles, from the environment ----

    function test_theRolesAreSet() public {
        _deploy();
        assertEq(d.guard().pauser(), pauser);
        for (uint8 i; i < 3; i++) {
            assertEq(d.strategies(i).operator(), operator);
        }
        assertEq(d.creditCore().operator(), operator);
        assertEq(d.creditCore().allocationMultisig(), operator);
        assertEq(d.registry().screener(), screener);
        assertEq(d.config().protocolTreasury(), treasury);
        assertEq(d.config().pauseGuard(), address(d.guard()));
        assertEq(d.config().creditCore(), address(d.creditCore()));
        assertEq(d.config().creditAgreementHash(), AGREEMENT);
        assertEq(d.seats().factory(), address(d.factory()), "Seats trusts the final factory");
    }

    // ---- proof 6: the chain guard ----

    function test_proof6_anUnsupportedChainReverts() public {
        vm.chainId(1);
        vm.expectRevert(Deploy.UnsupportedChain.selector);
        d.checkParams(p, address(this));
    }

    function test_proof6_mainnetRefusesADelayUnder24Hours() public {
        vm.chainId(5042);
        p.skipSmoke = true;
        p.delay = DAY - 1;
        vm.expectRevert(abi.encodeWithSelector(Deploy.DelayBelowFloor.selector, DAY - 1, DAY));
        d.checkParams(p, address(this));
        p.delay = DAY;
        d.checkParams(p, address(this));
    }

    function test_proof6_mainnetRefusesALongDelayUnder7Days() public {
        vm.chainId(5042);
        p.skipSmoke = true;
        p.delayLong = WEEK - 1;
        vm.expectRevert(abi.encodeWithSelector(Deploy.DelayBelowFloor.selector, WEEK - 1, WEEK));
        d.checkParams(p, address(this));
    }

    /// Owner, pauser and operator must be three keys on a public chain, so losing one does not
    /// lose the others' powers with it.
    function test_proof6_publicChainsRefuseSharedKeys() public {
        uint256[2] memory chains = [uint256(5042), 5042002];
        for (uint256 c; c < 2; c++) {
            vm.chainId(chains[c]);
            p.skipSmoke = true;
            Deploy.Params memory q = p;
            q.pauser = owner;
            vm.expectRevert(Deploy.RolesNotDistinct.selector);
            d.checkParams(q, address(this));
            q = p;
            q.operator = owner;
            vm.expectRevert(Deploy.RolesNotDistinct.selector);
            d.checkParams(q, address(this));
            q = p;
            q.operator = pauser;
            vm.expectRevert(Deploy.RolesNotDistinct.selector);
            d.checkParams(q, address(this));
        }
    }

    /// Anvil accepts one key for all three, for local testing.
    function test_proof6_anvilAcceptsSharedKeys() public {
        p.pauser = owner;
        p.operator = owner;
        d.checkParams(p, address(this));
        _deploy();
        assertEq(d.guard().pauser(), owner);
    }

    /// The deployer is retired after the deploy, so it can never also be the owner key.
    function test_proof6_theOwnerIsNeverTheDeployer() public {
        vm.expectRevert(Deploy.OwnerIsDeployer.selector);
        d.checkParams(p, owner);
    }

    // ---- proof 4: the 24-hour timelock ----

    function _schedule(TimelockController tl, address target, bytes memory data, uint256 delay) internal {
        vm.prank(owner);
        tl.schedule(target, 0, data, bytes32(0), bytes32(0), delay);
    }

    function _execute(TimelockController tl, address target, bytes memory data) internal {
        vm.prank(owner);
        tl.execute(target, 0, data, bytes32(0), bytes32(0));
    }

    function test_proof4_aConfigChangeExecutesOnlyAfterTheDelay() public {
        _deploy();
        TimelockController tl = d.timelock();
        address cfg = address(d.config());
        bytes memory data = abi.encodeWithSignature("set(bytes32,uint256)", K.MEMBER_CAP, 120);
        _schedule(tl, cfg, data, DAY);

        vm.warp(block.timestamp + DAY - 1);
        vm.expectRevert(); // not ready
        _execute(tl, cfg, data);
        assertEq(d.config().memberCap(), 150);

        vm.warp(block.timestamp + 1);
        _execute(tl, cfg, data);
        assertEq(d.config().memberCap(), 120);
    }

    function test_proof4_aCancelWorks() public {
        _deploy();
        TimelockController tl = d.timelock();
        address cfg = address(d.config());
        bytes memory data = abi.encodeWithSignature("set(bytes32,uint256)", K.MEMBER_CAP, 120);
        _schedule(tl, cfg, data, DAY);
        bytes32 id = tl.hashOperation(cfg, 0, data, bytes32(0), bytes32(0));
        vm.prank(owner);
        tl.cancel(id);
        vm.warp(block.timestamp + DAY);
        vm.expectRevert();
        _execute(tl, cfg, data);
        assertEq(d.config().memberCap(), 150);
    }

    function test_proof4_nobodyButTheOwnerProposes() public {
        _deploy();
        address[5] memory others = [stranger, d.deployer(), pauser, operator, screener];
        TimelockController[2] memory locks = [d.timelock(), d.timelockLong()];
        bytes memory data = abi.encodeWithSignature("set(bytes32,uint256)", K.MEMBER_CAP, 120);
        address cfg = address(d.config());
        for (uint256 l; l < 2; l++) {
            for (uint256 i; i < others.length; i++) {
                vm.prank(others[i]);
                vm.expectRevert();
                locks[l].schedule(cfg, 0, data, bytes32(0), bytes32(0), WEEK);
            }
        }
    }

    // ---- proof 4, the 7-day timelock: the paths to member money ----

    /// Adding a destination, changing an operator and adding a Venue strategy work through the
    /// 7-day timelock after 7 days, and not a second sooner.
    function test_proof4_memberMoneyPathsWaitSevenDays() public {
        _deploy();
        TimelockController tll = d.timelockLong();
        ManualStrategy s = d.strategies(0);
        IVenue v = d.venues(0);
        MockStrategy extra = new MockStrategy(usdc, address(v));
        CreditCore core = d.creditCore();
        MockStrategy poolExtra = new MockStrategy(usdc, address(core));

        address[4] memory targets = [address(s), address(s), address(v), address(core)];
        bytes[4] memory calls = [
            abi.encodeCall(ManualStrategy.addDestination, (makeAddr("dest"))),
            abi.encodeCall(ManualStrategy.setOperator, (makeAddr("new operator"))),
            abi.encodeCall(IVenue.addStrategy, (address(extra), 0)),
            abi.encodeCall(CreditCore.addStrategy, (address(poolExtra)))
        ];
        vm.prank(owner);
        vm.expectRevert(); // below the 7-day minimum
        tll.schedule(targets[0], 0, calls[0], bytes32(0), bytes32(0), DAY);

        for (uint256 i; i < 4; i++) {
            _schedule(tll, targets[i], calls[i], WEEK);
        }
        vm.warp(block.timestamp + WEEK - 1);
        for (uint256 i; i < 4; i++) {
            vm.expectRevert();
            _execute(tll, targets[i], calls[i]);
        }
        vm.warp(block.timestamp + 1);
        for (uint256 i; i < 4; i++) {
            _execute(tll, targets[i], calls[i]);
        }
        assertTrue(s.isDestination(makeAddr("dest")));
        assertEq(s.operator(), makeAddr("new operator"));
        assertTrue(v.isStrategy(address(extra)));
        assertTrue(core.isStrategy(address(poolExtra)));
    }

    /// The 24-hour timelock cannot do any of them, take either lister role, or redirect the
    /// community legs by moving `CREDIT_CORE`, even after its delay.
    function test_proof4_theDayTimelockCannotReachMemberMoney() public {
        _deploy();
        TimelockController tl = d.timelock();
        ManualStrategy s = d.strategies(0);
        IVenue v = d.venues(0);
        MockStrategy extra = new MockStrategy(usdc, address(v));
        CreditCore core = d.creditCore();
        MockStrategy poolExtra = new MockStrategy(usdc, address(core));
        address cfg = address(d.config());

        address[7] memory targets = [address(s), address(s), address(v), address(v), address(core), address(core), cfg];
        bytes[7] memory calls = [
            abi.encodeCall(ManualStrategy.addDestination, (makeAddr("dest"))),
            abi.encodeCall(ManualStrategy.setOperator, (makeAddr("new operator"))),
            abi.encodeCall(IVenue.addStrategy, (address(extra), 0)),
            abi.encodeCall(IVenue.setStrategyLister, (address(tl))),
            abi.encodeCall(CreditCore.addStrategy, (address(poolExtra))),
            abi.encodeCall(CreditCore.setStrategyLister, (address(tl))),
            abi.encodeCall(Config.setAddress, (K.CREDIT_CORE, makeAddr("elsewhere")))
        ];
        for (uint256 i; i < 7; i++) {
            _schedule(tl, targets[i], calls[i], DAY);
        }
        vm.warp(block.timestamp + DAY);
        for (uint256 i; i < 7; i++) {
            vm.expectRevert();
            _execute(tl, targets[i], calls[i]);
        }
    }

    /// The smoke community is permanent, with the deployer as its host, so Arc mainnet never runs it.
    function test_mainnetRefusesTheSmokeCommunity() public {
        vm.chainId(5042);
        vm.expectRevert(Deploy.NoSmokeOnMainnet.selector);
        d.checkParams(p, address(this));
        p.skipSmoke = true;
        d.checkParams(p, address(this));
    }

    // ---- proof 8: the record round-trips ----

    function test_proof8_checkDeploymentPassesAgainstTheRecord() public {
        d.setRecordName("proof8-pass");
        _deploy();
        assertTrue(_check(), "every check passes");
    }

    function test_proof8_checkDeploymentFailsWhenAFactIsWrong() public {
        d.setRecordName("proof8-fail");
        _deploy();
        IPauseGuard g = d.guard();
        vm.prank(pauser);
        g.setPaused(IPauseGuard.Flag.DEPOSITS, true);
        assertFalse(_check(), "a flag left on fails the check");
    }
}
