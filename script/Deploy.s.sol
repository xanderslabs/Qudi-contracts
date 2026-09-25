// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.30;

import {Script, console} from "forge-std/Script.sol";
import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {Ownable2Step} from "openzeppelin-contracts/contracts/access/Ownable2Step.sol";
import {TimelockController} from "openzeppelin-contracts/contracts/governance/TimelockController.sol";
import {Config} from "../src/Config.sol";
import {IConfig} from "../src/interfaces/IConfig.sol";
import {ComplianceRegistry} from "../src/ComplianceRegistry.sol";
import {ManualStrategy} from "../src/ManualStrategy.sol";
import {Venue} from "../src/Venue.sol";
import {IVenue} from "../src/interfaces/IVenue.sol";
import {Community} from "../src/Community.sol";
import {Seats} from "../src/Seats.sol";
import {Ledger} from "../src/Ledger.sol";
import {ILedger} from "../src/interfaces/ILedger.sol";
import {CommunityFactory} from "../src/CommunityFactory.sol";
import {CreditCore} from "../src/CreditCore.sol";
import {CreditStanding} from "../src/CreditStanding.sol";
import {ICreditStanding} from "../src/interfaces/ICreditStanding.sol";
import {CloneImpactSource} from "../src/CloneImpactSource.sol";
import {ICommunityFactory} from "../src/interfaces/ICommunityFactory.sol";
import {PauseGuard} from "../src/PauseGuard.sol";
import {ConfigKeys as K} from "../src/ConfigKeys.sol";
import {CaliburPin} from "./CaliburPin.sol";
import {VenueLabels} from "./VenueLabels.sol";

/// `test/mocks/MockUSDC.sol`'s open `mint`, declared here so this deploy path never imports test
/// code. Called only on anvil, where the USDC is that mock.
interface IMintableTestUsdc {
    function mint(address to, uint256 amount) external;
}

/// Deploys Qudi on anvil, Arc testnet or Arc mainnet, hands every owned contract to two timelocks
/// controlled by one owner key, and writes `deployments/<chainId>.json`, the file the app and the
/// indexer read addresses from.
///
/// What it deploys: `ComplianceRegistry`, `Config`, `Seats`, the `Community` and `Ledger`
/// implementations, `CommunityFactory`, three `Venue`s (Flex, Core and Term) each over one
/// `ManualStrategy`, `CreditStanding` with the seat and ledger impact sources, `CreditCore`,
/// `PauseGuard`, and two `TimelockController`s.
///
/// **`ManualStrategy` reaches Arc mainnet for the beta, deliberately.** Its yield is paid in by
/// Qudi's operator ahead of time and released at a set rate, so this is a deployment whose yield
/// Qudi funds. It is not a third-party venue and must not be described as one.
///
/// Order, and why:
///   1. `ComplianceRegistry`, before `Config`, whose constructor takes it and refuses zero.
///   2. `Config`.
///   3. `Seats`, built with the factory's address precomputed from the deployer's nonce. `Seats`
///      trusts one factory for good, so it must name the final one; the factory's landing address
///      is asserted against the prediction, and a miscount fails the deploy.
///   4. The `Community` and `Ledger` implementations.
///   5. `CommunityFactory`. Nothing else is sent between reading the nonce and this creation,
///      because every transaction moves the nonce.
///   6. The venues and their strategies, labelled. A `Venue` takes the factory as an immutable.
///   7. The venue registry: Flex (0), Core (1), Term (2), each id asserted.
///   8. `CreditStanding` and its two impact sources.
///   9. `CreditCore`, before any seat is sold, because a paid seat routes its pool leg there.
///  10. `PauseGuard`, then every `Config` key: `CREDIT_CORE`, `PAUSE_GUARD` and the agreement hash.
///  11. The roles, each asserted.
///  12. The timelocks and the handover, each owner asserted.
///  13. The smoke community, unless skipped.
///
/// The handover. Every owned contract is `Ownable2Step`, so a transfer only nominates and the
/// timelock must accept. Each timelock is created with no delay and the deployer as a temporary
/// proposer, executor and admin. In one batch it accepts every ownership it was offered and then
/// sets its own delay. The deployer then gives the owner key the proposer, executor and canceller
/// roles and renounces all of its own, so each timelock is administered only by itself. This all
/// happens inside the deploy, before anything holds money.
///
/// The two timelocks. The 24-hour one owns `Config`, `CommunityFactory`, each `Venue`,
/// `CreditCore`, `CreditStanding`, `ComplianceRegistry` and `PauseGuard`. The 7-day one owns each
/// `ManualStrategy` (its destinations and its operator) and holds the strategy-lister role of each
/// Venue and of `CreditCore`, so every path that could send member money somewhere new waits a
/// public week. `Config.CREDIT_CORE`, where every community's seat and yield legs are paid, is set
/// here once and can never be set again.
///
/// Environment:
///   USDC_ADDRESS           the chain's USDC. On anvil, a `test/mocks/MockUSDC.sol` deployed first.
///   OWNER                  the single key behind both timelocks.
///   PAUSER                 `PauseGuard`'s pauser.
///   OPERATOR               every `ManualStrategy`'s operator, and `CreditCore`'s operator and
///                          allocation role.
///   SCREENER               `ComplianceRegistry`'s screener.
///   TREASURY               the protocol treasury in `Config`.
///   TIMELOCK_DELAY         seconds; at least 24 hours on Arc mainnet.
///   TIMELOCK_DELAY_LONG    seconds; at least 7 days on Arc mainnet.
///   CREDIT_AGREEMENT_HASH  the Credit Agreement a member's first draw must carry.
///   GIT_COMMIT             recorded as given, not checked.
///   SKIP_SMOKE             "true" to skip the smoke community. It is permanent, with the deployer
///                          as its host. Only anvil runs it: forge simulates every script locally
///                          first and cannot run Arc USDC's blocklist precompile, so it must be
///                          "true" on Arc testnet, and Arc mainnet refuses it.
///
/// Calibur must already be at its canonical address (`script/DeployCalibur.s.sol`); the record
/// names it only if its code is the pinned build, and `CheckDeployment` fails otherwise.
///
/// Run, then fix the record's block to the first transaction's:
///   forge script script/Deploy.s.sol --rpc-url <url> --account <keystore> --broadcast --slow
///   forge script script/Deploy.s.sol --rpc-url <url> --sig "recordDeployBlock()"
contract Deploy is Script {
    struct Params {
        address usdc;
        address owner;
        address pauser;
        address operator;
        address screener;
        address treasury;
        uint256 delay;
        uint256 delayLong;
        bytes32 agreementHash;
        string gitCommit;
        bool skipSmoke;
    }

    error UnsupportedChain();
    error DelayBelowFloor(uint256 delay, uint256 floor);
    error RolesNotDistinct();
    error ZeroAddress();
    error OwnerIsDeployer();
    error NoSmokeOnMainnet();

    uint256 internal constant _ANVIL = 31337;
    uint256 internal constant _ARC_TESTNET = 5042002;
    uint256 internal constant _ARC_MAINNET = 5042;

    /// Arc mainnet's floors. Anvil and Arc testnet may use less, for testing.
    uint256 internal constant _MAINNET_DELAY_FLOOR = 24 hours;
    uint256 internal constant _MAINNET_DELAY_LONG_FLOOR = 7 days;

    /// Contract creations between reading the deployer's nonce and creating the factory:
    /// `ComplianceRegistry`, `Config`, `Seats` and the two implementations.
    uint256 internal constant _FACTORY_NONCE_OFFSET = 5;

    /// Each venue's one `ManualStrategy` holds this share of the venue; the rest stays idle as the
    /// venue's cash buffer.
    uint16 internal constant _STRATEGY_WEIGHT_BPS = 7500;

    /// What each smoke vault takes.
    uint256 internal constant _SMOKE_AMOUNT = 50e6;

    bytes32 internal constant _HANDOVER_SALT = keccak256("qudi deploy handover");

    // Results live in storage: the deploy reads best as one sequence, and that many locals overflow
    // the stack under the legacy code generator this repository builds with.
    address public deployer;
    uint256 public deployBlock;
    uint256 public deployTimestamp;
    ComplianceRegistry public registry;
    Config public config;
    Seats public seats;
    Community public communityImpl;
    Ledger public ledgerImpl;
    CommunityFactory public factory;
    Venue[3] public venues;
    ManualStrategy[3] public strategies;
    CreditStanding public standing;
    CreditCore public creditCore;
    CloneImpactSource public seatSource;
    CloneImpactSource public ledgerSource;
    PauseGuard public guard;
    TimelockController public timelock;
    TimelockController public timelockLong;
    address public calibur;

    function run() external {
        deploy(
            Params({
                usdc: vm.envAddress("USDC_ADDRESS"),
                owner: vm.envAddress("OWNER"),
                pauser: vm.envAddress("PAUSER"),
                operator: vm.envAddress("OPERATOR"),
                screener: vm.envAddress("SCREENER"),
                treasury: vm.envAddress("TREASURY"),
                delay: vm.envUint("TIMELOCK_DELAY"),
                delayLong: vm.envUint("TIMELOCK_DELAY_LONG"),
                agreementHash: vm.envBytes32("CREDIT_AGREEMENT_HASH"),
                gitCommit: vm.envOr("GIT_COMMIT", string("")),
                skipSmoke: vm.envOr("SKIP_SMOKE", false)
            })
        );
    }

    /// Refuses a chain Qudi does not run on, a mainnet delay under its floor, a zero role, an owner
    /// that is the deployer, and on a public chain any two of owner, pauser and operator that are
    /// the same key. Anvil accepts shared keys, for local testing.
    function checkParams(Params memory p, address deployer_) public view {
        if (block.chainid != _ANVIL && block.chainid != _ARC_TESTNET && block.chainid != _ARC_MAINNET) {
            revert UnsupportedChain();
        }
        if (block.chainid == _ARC_MAINNET) {
            // The smoke community is permanent, with the deployer as its host.
            if (!p.skipSmoke) revert NoSmokeOnMainnet();
            if (p.delay < _MAINNET_DELAY_FLOOR) revert DelayBelowFloor(p.delay, _MAINNET_DELAY_FLOOR);
            if (p.delayLong < _MAINNET_DELAY_LONG_FLOOR) {
                revert DelayBelowFloor(p.delayLong, _MAINNET_DELAY_LONG_FLOOR);
            }
        }
        if (
            p.usdc == address(0) || p.owner == address(0) || p.pauser == address(0) || p.operator == address(0)
                || p.screener == address(0) || p.treasury == address(0)
        ) revert ZeroAddress();
        // The deployer is retired after the deploy and renounces every timelock role, so it can
        // never be the key those roles go to.
        if (p.owner == deployer_) revert OwnerIsDeployer();
        if (block.chainid != _ANVIL) {
            if (p.owner == p.pauser || p.owner == p.operator || p.pauser == p.operator) revert RolesNotDistinct();
        }
    }

    function deploy(Params memory p) public {
        vm.startBroadcast();
        (, deployer,) = vm.readCallers();
        checkParams(p, deployer);
        deployBlock = block.number;
        deployTimestamp = block.timestamp;
        console.log("chain id:", block.chainid);
        console.log("deployer:", deployer);

        address predictedFactory = vm.computeCreateAddress(deployer, vm.getNonce(deployer) + _FACTORY_NONCE_OFFSET);

        // 1 to 5. Creations only, until the factory exists: see `_FACTORY_NONCE_OFFSET`.
        registry = new ComplianceRegistry(p.screener);
        config = new Config(p.usdc, p.treasury, address(registry));
        seats = new Seats(predictedFactory, IConfig(address(config)));
        communityImpl = new Community();
        ledgerImpl = new Ledger();
        factory = new CommunityFactory(
            address(config), address(seats), address(communityImpl), address(ledgerImpl), deployer
        );
        require(address(factory) == predictedFactory, "factory address mismatch");
        require(seats.factory() == address(factory), "Seats trusts another factory");

        // 6 and 7. The venues, their strategies and labels, and the registry.
        for (uint8 i; i < VenueLabels.COUNT; i++) {
            string memory s = VenueLabels.suffix(i);
            venues[i] = new Venue(
                IERC20(p.usdc),
                IConfig(address(config)),
                address(factory),
                deployer,
                string.concat("Qudi ", s),
                string.concat("q", vm.toUppercase(s))
            );
            strategies[i] =
                new ManualStrategy(IERC20(p.usdc), IConfig(address(config)), address(venues[i]), deployer, p.operator);
            _wireVenue(venues[i], strategies[i], i);
            require(factory.addVenue(address(venues[i])) == i, "venue listed under the wrong id");
        }

        // 8. The standing half and the two impact sources: the seat leg in each community's
        // `Community`, and the yield leg in each community's `Ledger`.
        standing = new CreditStanding(IConfig(address(config)), address(factory), deployer);
        seatSource = new CloneImpactSource(ICommunityFactory(address(factory)), false);
        ledgerSource = new CloneImpactSource(ICommunityFactory(address(factory)), true);
        standing.addImpactSource(address(seatSource));
        standing.addImpactSource(address(ledgerSource));

        // 9. The pool. Its operator and allocation role are both the operator key.
        creditCore = new CreditCore(
            IERC20(p.usdc),
            IConfig(address(config)),
            address(factory),
            deployer,
            p.operator,
            p.operator,
            ICreditStanding(address(standing))
        );
        standing.setCreditCore(address(creditCore));

        // 10. The pause, then every `Config` key. Credit stays shut until the agreement hash is set,
        // and every money path refuses money in until the guard is.
        guard = new PauseGuard(deployer, p.pauser);
        config.setAddress(K.CREDIT_CORE, address(creditCore));
        config.setAddress(K.PAUSE_GUARD, address(guard));
        config.setCreditAgreementHash(p.agreementHash);

        // 11. The roles.
        _assertRoles(p);

        // 12. The timelocks and the handover.
        _handOver(p);

        // 13. The smoke community: a real community, vault and deposit in each venue, proving the
        // clones, the registry and the money paths end to end. After the handover, because it needs
        // no owner and proves the handed-over deployment.
        if (!p.skipSmoke) {
            _smoke(p.usdc);
        } else {
            console.log("smoke community: skipped");
        }
        vm.stopBroadcast();

        if (CaliburPin.CANONICAL.codehash == CaliburPin.RUNTIME_CODE_HASH) {
            calibur = CaliburPin.CANONICAL;
        } else {
            console.log("WARNING: no canonical Calibur on this chain; run script/DeployCalibur.s.sol");
        }
        _writeRecord(p);
    }

    function _wireVenue(Venue v, ManualStrategy s, uint8 id) internal {
        v.setLabels(VenueLabels.labels(id));
        // No exit delay: the strategy's principal cash can be withdrawn at once.
        v.addStrategy(address(s), 0);
        v.setCap(address(s), config.globalDepositCap());
        address[] memory list = new address[](1);
        uint16[] memory bps = new uint16[](1);
        list[0] = address(s);
        bps[0] = _STRATEGY_WEIGHT_BPS;
        v.setWeights(list, bps);
    }

    function _assertRoles(Params memory p) internal view {
        require(guard.pauser() == p.pauser, "pauser not set");
        for (uint8 i; i < VenueLabels.COUNT; i++) {
            require(strategies[i].operator() == p.operator, "strategy operator not set");
        }
        require(creditCore.operator() == p.operator, "pool operator not set");
        require(creditCore.allocationMultisig() == p.operator, "allocation role not set");
        require(registry.screener() == p.screener, "screener not set");
        require(config.protocolTreasury() == p.treasury, "treasury not set");
        require(config.complianceRegistry() == address(registry), "compliance registry not wired");
        require(config.creditCore() == address(creditCore), "credit core not wired");
        require(config.pauseGuard() == address(guard), "pause guard not wired");
        require(config.creditAgreementHash() == p.agreementHash, "agreement hash not set");
    }

    function _handOver(Params memory p) internal {
        address[] memory temp = new address[](1);
        temp[0] = deployer;
        timelock = new TimelockController(0, temp, temp, deployer);
        timelockLong = new TimelockController(0, temp, temp, deployer);

        address[] memory day = new address[](9);
        day[0] = address(config);
        day[1] = address(factory);
        day[2] = address(creditCore);
        day[3] = address(standing);
        day[4] = address(registry);
        day[5] = address(guard);
        address[] memory week = new address[](3);
        for (uint8 i; i < VenueLabels.COUNT; i++) {
            day[6 + i] = address(venues[i]);
            week[i] = address(strategies[i]);
            // The lister role is a plain handover: the deployer listed the one strategy each venue
            // starts with, and from here only the 7-day timelock lists another.
            venues[i].setStrategyLister(address(timelockLong));
        }
        // The pool holds community balances, so listing a pool strategy waits the week too.
        creditCore.setStrategyLister(address(timelockLong));
        for (uint256 i; i < day.length; i++) {
            Ownable2Step(day[i]).transferOwnership(address(timelock));
        }
        for (uint256 i; i < week.length; i++) {
            Ownable2Step(week[i]).transferOwnership(address(timelockLong));
        }
        _acceptAndHandOn(timelock, day, p.delay, p.owner);
        _acceptAndHandOn(timelockLong, week, p.delayLong, p.owner);

        for (uint256 i; i < day.length; i++) {
            require(Ownable2Step(day[i]).owner() == address(timelock), "not owned by the timelock");
            require(Ownable2Step(day[i]).pendingOwner() == address(0), "ownership still pending");
        }
        for (uint256 i; i < week.length; i++) {
            require(Ownable2Step(week[i]).owner() == address(timelockLong), "not owned by the 7-day timelock");
            require(Ownable2Step(week[i]).pendingOwner() == address(0), "ownership still pending");
            require(venues[i].strategyLister() == address(timelockLong), "lister is not the 7-day timelock");
        }
        require(creditCore.strategyLister() == address(timelockLong), "pool lister is not the 7-day timelock");
        console.log("timelock (24h):  ", address(timelock));
        console.log("timelock (7d):   ", address(timelockLong));
    }

    /// One zero-delay batch: accept every ownership, then set the real delay. Then the owner key
    /// gets the operating roles and the deployer gives up all of its own.
    function _acceptAndHandOn(TimelockController tl, address[] memory owned, uint256 delay, address owner) internal {
        uint256 n = owned.length;
        address[] memory targets = new address[](n + 1);
        uint256[] memory values = new uint256[](n + 1);
        bytes[] memory payloads = new bytes[](n + 1);
        for (uint256 i; i < n; i++) {
            targets[i] = owned[i];
            payloads[i] = abi.encodeCall(Ownable2Step.acceptOwnership, ());
        }
        targets[n] = address(tl);
        payloads[n] = abi.encodeCall(TimelockController.updateDelay, (delay));
        tl.scheduleBatch(targets, values, payloads, bytes32(0), _HANDOVER_SALT, 0);
        tl.executeBatch(targets, values, payloads, bytes32(0), _HANDOVER_SALT);

        tl.grantRole(tl.PROPOSER_ROLE(), owner);
        tl.grantRole(tl.EXECUTOR_ROLE(), owner);
        tl.grantRole(tl.CANCELLER_ROLE(), owner);
        tl.renounceRole(tl.PROPOSER_ROLE(), deployer);
        tl.renounceRole(tl.EXECUTOR_ROLE(), deployer);
        tl.renounceRole(tl.CANCELLER_ROLE(), deployer);
        tl.renounceRole(tl.DEFAULT_ADMIN_ROLE(), deployer);

        require(tl.getMinDelay() == delay, "delay not set");
        require(
            tl.hasRole(tl.PROPOSER_ROLE(), owner) && tl.hasRole(tl.EXECUTOR_ROLE(), owner)
                && tl.hasRole(tl.CANCELLER_ROLE(), owner),
            "owner roles not granted"
        );
        require(
            !tl.hasRole(tl.PROPOSER_ROLE(), deployer) && !tl.hasRole(tl.EXECUTOR_ROLE(), deployer)
                && !tl.hasRole(tl.CANCELLER_ROLE(), deployer) && !tl.hasRole(tl.DEFAULT_ADMIN_ROLE(), deployer),
            "deployer kept a timelock role"
        );
        require(tl.hasRole(tl.DEFAULT_ADMIN_ROLE(), address(tl)), "timelock does not administer itself");
        require(!tl.hasRole(tl.DEFAULT_ADMIN_ROLE(), owner), "owner holds the admin role");
    }

    // ---- the smoke community ----

    function _smoke(address usdc) internal {
        // The founding mint requires the creator to have attested for itself.
        registry.attest(1);
        address community = factory.createCommunity("Smoke Community", config.seatPriceFloor());
        require(seats.isRegistered(community), "smoke community not registered with Seats");
        require(factory.isCommunityContract(community), "smoke community not registered");
        address ledger = factory.ledgerOf(community);
        require(factory.isCommunityContract(ledger), "smoke ledger not registered");
        for (uint8 i; i < VenueLabels.COUNT; i++) {
            require(Ledger(ledger).tierVault(i) == address(venues[i]), "smoke ledger resolves the wrong venue");
            _smokeDeposit(usdc, Ledger(ledger), i);
        }
        console.log("smoke community:", community);
    }

    /// One personal vault in venue `id` and one deposit into it. A Term vault carries a one-day
    /// lock, because a Locked-kind venue takes no vault without one.
    function _smokeDeposit(address usdc, Ledger ledger, uint8 id) internal {
        if (block.chainid == _ANVIL) IMintableTestUsdc(usdc).mint(deployer, _SMOKE_AMOUNT);
        IERC20(usdc).approve(address(ledger), _SMOKE_AMOUNT);
        uint64 lockedUntil = venues[id].labels().kind == IVenue.Kind.Locked ? uint64(block.timestamp + 1 days) : 0;
        uint256 vaultId = ledger.createVault(
            ILedger.VaultParams({venueId: id, shared: false, lockedUntil: lockedUntil, name: "Smoke savings"})
        );
        ledger.deposit(vaultId, _SMOKE_AMOUNT);
        require(ledger.vaultValue(vaultId) == _SMOKE_AMOUNT, "smoke deposit did not credit the vault");
    }

    // ---- the deployment record ----

    function _recordDir() internal view virtual returns (string memory) {
        return string.concat(vm.projectRoot(), "/deployments");
    }

    function _recordPath() internal view virtual returns (string memory) {
        return string.concat(_recordDir(), "/", vm.toString(block.chainid), ".json");
    }

    function _q(string memory s) internal pure returns (string memory) {
        return string.concat('"', s, '"');
    }

    function _kv(string memory k, address a) internal pure returns (string memory) {
        return string.concat(_q(k), ":", _q(vm.toString(a)));
    }

    /// The record, with exactly the keys the address-book generator reads. Addresses are checksummed
    /// strings; the chain id, block and timestamp are numbers.
    function _writeRecord(Params memory p) internal {
        string memory contracts = string.concat(
            "{",
            _kv("CommunityFactory", address(factory)),
            ",",
            _kv("CommunityImplementation", address(communityImpl)),
            ",",
            _kv("LedgerImplementation", address(ledgerImpl)),
            ",",
            _kv("Seats", address(seats)),
            ",",
            _kv("Config", address(config)),
            ",",
            _kv("ComplianceRegistry", address(registry)),
            ","
        );
        contracts = string.concat(
            contracts,
            _kv("CreditCore", address(creditCore)),
            ",",
            _kv("CreditStanding", address(standing)),
            ",",
            _kv("ImpactSourceSeats", address(seatSource)),
            ",",
            _kv("ImpactSourceLedger", address(ledgerSource)),
            ",",
            _kv("PauseGuard", address(guard)),
            ",",
            _kv("Timelock", address(timelock)),
            ",",
            _kv("TimelockLong", address(timelockLong))
        );
        string memory venueList = "[";
        for (uint8 i; i < VenueLabels.COUNT; i++) {
            string memory s = VenueLabels.suffix(i);
            contracts = string.concat(
                contracts,
                ",",
                _kv(string.concat("Venue", s), address(venues[i])),
                ",",
                _kv(string.concat("ManualStrategy", s), address(strategies[i]))
            );
            IVenue.Labels memory l = venues[i].labels();
            venueList = string.concat(
                venueList,
                i == 0 ? "" : ",",
                "{",
                _q("id"),
                ":",
                vm.toString(uint256(i)),
                ",",
                _q("name"),
                ":",
                _q(l.name),
                ",",
                _q("kind"),
                ":",
                _q(l.kind == IVenue.Kind.Locked ? "Locked" : "Open"),
                ",",
                _kv("venue", address(venues[i])),
                ",",
                _kv("strategy", address(strategies[i])),
                "}"
            );
        }
        contracts = string.concat(contracts, "}");
        venueList = string.concat(venueList, "]");

        string memory roles = string.concat(
            "{",
            _kv("owner", p.owner),
            ",",
            _kv("timelock", address(timelock)),
            ",",
            _kv("pauser", p.pauser),
            ",",
            _kv("operator", p.operator),
            ",",
            _kv("screener", p.screener),
            ",",
            _kv("treasury", p.treasury),
            "}"
        );
        string memory json = string.concat(
            "{",
            _q("chainId"),
            ":",
            vm.toString(block.chainid),
            ",",
            _q("deployBlock"),
            ":",
            vm.toString(deployBlock),
            ",",
            _q("deployTimestamp"),
            ":",
            vm.toString(deployTimestamp),
            ",",
            _q("gitCommit"),
            ":",
            _q(p.gitCommit),
            ","
        );
        json = string.concat(
            json,
            _q("contracts"),
            ":",
            contracts,
            ",",
            _q("venues"),
            ":",
            venueList,
            ",",
            _q("roles"),
            ":",
            roles,
            ",",
            _kv("calibur", calibur),
            "}"
        );
        vm.createDir(_recordDir(), true);
        vm.writeJson(json, _recordPath());
        console.log("deployment record:", _recordPath());
    }

    /// Run after the broadcast. The record's block and timestamp are first written from the state
    /// the script simulated against, which is never later than the first transaction. This sets
    /// them to the block the first deploy transaction actually landed in, read from the broadcast
    /// log, so the indexer starts exactly there.
    function recordDeployBlock() external {
        string memory log =
            string.concat(vm.projectRoot(), "/broadcast/Deploy.s.sol/", vm.toString(block.chainid), "/run-latest.json");
        uint256 first = vm.parseJsonUint(vm.readFile(log), ".receipts[0].blockNumber");
        vm.rollFork(first);
        vm.writeJson(vm.toString(first), _recordPath(), ".deployBlock");
        vm.writeJson(vm.toString(block.timestamp), _recordPath(), ".deployTimestamp");
        console.log("deploy block:", first, "timestamp:", block.timestamp);
    }
}
