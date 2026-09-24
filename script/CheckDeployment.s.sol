// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.30;

import {Script, console} from "forge-std/Script.sol";
import {Ownable2Step} from "openzeppelin-contracts/contracts/access/Ownable2Step.sol";
import {TimelockController} from "openzeppelin-contracts/contracts/governance/TimelockController.sol";
import {Config} from "../src/Config.sol";
import {ComplianceRegistry} from "../src/ComplianceRegistry.sol";
import {ManualStrategy} from "../src/ManualStrategy.sol";
import {Venue} from "../src/Venue.sol";
import {IVenue} from "../src/interfaces/IVenue.sol";
import {Seats} from "../src/Seats.sol";
import {CommunityFactory} from "../src/CommunityFactory.sol";
import {CreditCore} from "../src/CreditCore.sol";
import {CreditStanding} from "../src/CreditStanding.sol";
import {CloneImpactSource} from "../src/CloneImpactSource.sol";
import {PauseGuard} from "../src/PauseGuard.sol";
import {ConfigKeys as K} from "../src/ConfigKeys.sol";
import {IPauseGuard} from "../src/interfaces/IPauseGuard.sol";
import {CaliburPin} from "./CaliburPin.sol";
import {VenueLabels} from "./VenueLabels.sol";

/// Reads a deployment record and checks every wiring fact against the chain, one PASS or FAIL line
/// per check. Read only: it sends nothing. It reverts at the end if any check failed.
///
/// Environment: USDC_ADDRESS, TIMELOCK_DELAY, TIMELOCK_DELAY_LONG and CREDIT_AGREEMENT_HASH, the
/// values the deploy was given, and optionally DEPLOYMENT_RECORD (default
/// `deployments/<chainId>.json`).
///
/// Run: forge script script/CheckDeployment.s.sol --rpc-url <url>
contract CheckDeployment is Script {
    struct Expected {
        address usdc;
        uint256 delay;
        uint256 delayLong;
        bytes32 agreementHash;
    }

    error ChecksFailed(uint256 failed);

    string internal _json;
    uint256 internal _failed;
    uint256 internal _passed;

    function run() external {
        string memory path = vm.envOr(
            "DEPLOYMENT_RECORD", string.concat(vm.projectRoot(), "/deployments/", vm.toString(block.chainid), ".json")
        );
        bool ok = check(
            path,
            Expected({
                usdc: vm.envAddress("USDC_ADDRESS"),
                delay: vm.envUint("TIMELOCK_DELAY"),
                delayLong: vm.envUint("TIMELOCK_DELAY_LONG"),
                agreementHash: vm.envBytes32("CREDIT_AGREEMENT_HASH")
            })
        );
        if (!ok) revert ChecksFailed(_failed);
    }

    function _a(string memory key) internal view returns (address) {
        return vm.parseJsonAddress(_json, key);
    }

    function _c(string memory name) internal view returns (address) {
        return _a(string.concat(".contracts.", name));
    }

    function _r(string memory name) internal view returns (address) {
        return _a(string.concat(".roles.", name));
    }

    function _expect(bool ok, string memory what) internal {
        if (ok) {
            _passed++;
            console.log(string.concat("PASS  ", what));
        } else {
            _failed++;
            console.log(string.concat("FAIL  ", what));
        }
    }

    /// True when every check passes.
    function check(string memory path, Expected memory e) public returns (bool) {
        _json = vm.readFile(path);
        _failed = 0;
        _passed = 0;
        console.log("record:", path);

        _expect(vm.parseJsonUint(_json, ".chainId") == block.chainid, "record is for this chain");
        uint256 deployBlock = vm.parseJsonUint(_json, ".deployBlock");
        _expect(deployBlock != 0 && deployBlock <= block.number, "deploy block is a past block");

        _checkOwners();
        _checkTimelocks(e);
        _checkRoles();
        _checkConfig(e);
        _checkVenues();
        _checkCredit();
        _checkPause();
        _checkCalibur();

        console.log(string.concat(vm.toString(_passed), " passed, ", vm.toString(_failed), " failed"));
        return _failed == 0;
    }

    function _owned(string memory name, address expectedOwner, string memory lock) internal {
        Ownable2Step c = Ownable2Step(_c(name));
        _expect(
            c.owner() == expectedOwner && c.pendingOwner() == address(0),
            string.concat(name, " owned by ", lock, ", nothing pending")
        );
    }

    function _checkOwners() internal {
        address tl = _c("Timelock");
        address tll = _c("TimelockLong");
        _expect(_r("timelock") == tl, "roles.timelock is the 24-hour timelock");
        string[6] memory day =
            ["Config", "CommunityFactory", "CreditCore", "CreditStanding", "ComplianceRegistry", "PauseGuard"];
        for (uint256 i; i < day.length; i++) {
            _owned(day[i], tl, "the 24-hour timelock");
        }
        for (uint8 i; i < VenueLabels.COUNT; i++) {
            string memory s = VenueLabels.suffix(i);
            _owned(string.concat("Venue", s), tl, "the 24-hour timelock");
            _owned(string.concat("ManualStrategy", s), tll, "the 7-day timelock");
        }
    }

    /// Both delays, the owner key's roles, no admin but each timelock itself, and no path to member
    /// money on the 24-hour one.
    function _checkTimelocks(Expected memory e) internal {
        TimelockController tl = TimelockController(payable(_c("Timelock")));
        TimelockController tll = TimelockController(payable(_c("TimelockLong")));
        _expect(tl.getMinDelay() == e.delay, string.concat("24-hour timelock delay is ", vm.toString(e.delay)));
        _expect(tll.getMinDelay() == e.delayLong, string.concat("7-day timelock delay is ", vm.toString(e.delayLong)));
        if (block.chainid == 5042) {
            _expect(tl.getMinDelay() >= 24 hours, "mainnet: 24-hour timelock delay at least 24 hours");
            _expect(tll.getMinDelay() >= 7 days, "mainnet: 7-day timelock delay at least 7 days");
        }
        address owner = _r("owner");
        TimelockController[2] memory locks = [tl, tll];
        string[2] memory names = ["24-hour", "7-day"];
        for (uint256 i; i < 2; i++) {
            TimelockController l = locks[i];
            _expect(
                l.hasRole(l.PROPOSER_ROLE(), owner) && l.hasRole(l.EXECUTOR_ROLE(), owner)
                    && l.hasRole(l.CANCELLER_ROLE(), owner),
                string.concat(names[i], " timelock: owner proposes, executes and cancels")
            );
            _expect(
                l.hasRole(l.DEFAULT_ADMIN_ROLE(), address(l)) && !l.hasRole(l.DEFAULT_ADMIN_ROLE(), owner),
                string.concat(names[i], " timelock administers itself")
            );
            _expect(
                !l.hasRole(l.EXECUTOR_ROLE(), address(0)) && !l.hasRole(l.PROPOSER_ROLE(), address(0)),
                string.concat(names[i], " timelock has no open role")
            );
        }
        for (uint8 i; i < VenueLabels.COUNT; i++) {
            string memory s = VenueLabels.suffix(i);
            Venue v = Venue(_c(string.concat("Venue", s)));
            ManualStrategy m = ManualStrategy(_c(string.concat("ManualStrategy", s)));
            _expect(
                v.strategyLister() == address(tll) && v.strategyLister() != address(tl),
                string.concat("Venue", s, ": only the 7-day timelock adds strategies")
            );
            _expect(
                m.owner() != address(tl),
                string.concat("ManualStrategy", s, ": destinations and operator are not on the 24-hour timelock")
            );
        }
    }

    function _checkRoles() internal {
        address operator = _r("operator");
        _expect(PauseGuard(_c("PauseGuard")).pauser() == _r("pauser"), "PauseGuard pauser");
        for (uint8 i; i < VenueLabels.COUNT; i++) {
            string memory name = string.concat("ManualStrategy", VenueLabels.suffix(i));
            _expect(ManualStrategy(_c(name)).operator() == operator, string.concat(name, " operator"));
        }
        CreditCore core = CreditCore(_c("CreditCore"));
        _expect(core.operator() == operator, "CreditCore operator");
        _expect(core.allocationMultisig() == operator, "CreditCore allocation role");
        _expect(
            ComplianceRegistry(_c("ComplianceRegistry")).screener() == _r("screener"), "ComplianceRegistry screener"
        );
    }

    function _checkConfig(Expected memory e) internal {
        Config cfg = Config(_c("Config"));
        _expect(cfg.usdc() == e.usdc, "Config usdc");
        _expect(cfg.protocolTreasury() == _r("treasury"), "Config PROTOCOL_TREASURY");
        _expect(cfg.complianceRegistry() == _c("ComplianceRegistry"), "Config COMPLIANCE_REGISTRY");
        _expect(cfg.creditCore() == _c("CreditCore"), "Config CREDIT_CORE");
        _expect(cfg.pauseGuard() == _c("PauseGuard"), "Config PAUSE_GUARD");
        _expect(cfg.creditAgreementHash() == e.agreementHash, "Config CREDIT_AGREEMENT_HASH");
        _expect(_creditCoreIsFixed(cfg), "Config CREDIT_CORE cannot be set again, even by its owner");
    }

    /// Tries to move `CREDIT_CORE` as the owner in a state snapshot that is thrown away. Nothing is
    /// sent: this script never broadcasts.
    function _creditCoreIsFixed(Config cfg) internal returns (bool fixed_) {
        uint256 snap = vm.snapshotState();
        vm.prank(cfg.owner());
        try cfg.setAddress(K.CREDIT_CORE, address(0xdead)) {
            fixed_ = false;
        } catch (bytes memory reason) {
            fixed_ = bytes4(reason) == Config.CreditCoreAlreadySet.selector;
        }
        vm.revertToStateAndDelete(snap);
    }

    function _checkVenues() internal {
        CommunityFactory f = CommunityFactory(_c("CommunityFactory"));
        _expect(Seats(_c("Seats")).factory() == address(f), "Seats trusts the factory");
        _expect(f.venueCount() == VenueLabels.COUNT, "three venues listed");
        for (uint8 i; i < VenueLabels.COUNT; i++) {
            string memory s = VenueLabels.suffix(i);
            Venue v = Venue(_c(string.concat("Venue", s)));
            address m = _c(string.concat("ManualStrategy", s));
            string memory key = string.concat(".venues[", vm.toString(uint256(i)), "]");
            _expect(
                vm.parseJsonUint(_json, string.concat(key, ".id")) == i
                    && vm.parseJsonAddress(_json, string.concat(key, ".venue")) == address(v)
                    && vm.parseJsonAddress(_json, string.concat(key, ".strategy")) == m,
                string.concat("record venues[", vm.toString(uint256(i)), "] is ", s)
            );
            _expect(
                f.venueAt(i) == address(v) && f.isActiveVenue(i),
                string.concat(s, " is registry id ", vm.toString(uint256(i)))
            );
            _expect(
                v.strategyCount() == 1 && v.strategies(0) == m && ManualStrategy(m).venue() == address(v),
                string.concat(s, " holds its one ManualStrategy")
            );
            IVenue.Labels memory want = VenueLabels.labels(i);
            IVenue.Labels memory have = v.labels();
            _expect(
                keccak256(bytes(have.name)) == keccak256(bytes(want.name)) && have.kind == want.kind
                    && have.riskKey == want.riskKey && have.estReturnBps == want.estReturnBps
                    && have.exitSeconds == want.exitSeconds,
                string.concat(s, " labels")
            );
            _expect(
                have.maxRateBps == want.maxRateBps, string.concat(s, " maxRate ", vm.toString(uint256(want.maxRateBps)))
            );
        }
    }

    function _checkCredit() internal {
        CreditStanding st = CreditStanding(_c("CreditStanding"));
        address seatsSource = _c("ImpactSourceSeats");
        address ledgerSource = _c("ImpactSourceLedger");
        address[] memory sources = st.impactSources();
        _expect(
            sources.length == 2 && sources[0] == seatsSource && sources[1] == ledgerSource,
            "the two impact sources are registered"
        );
        _expect(
            !CloneImpactSource(seatsSource).ledger() && CloneImpactSource(ledgerSource).ledger()
                && address(CloneImpactSource(seatsSource).factory()) == _c("CommunityFactory")
                && address(CloneImpactSource(ledgerSource).factory()) == _c("CommunityFactory"),
            "impact sources read the seat and ledger legs through the factory"
        );
        _expect(st.creditCore() == _c("CreditCore"), "CreditStanding wired to CreditCore");
        CreditCore core = CreditCore(_c("CreditCore"));
        _expect(
            core.strategyLister() == _c("TimelockLong") && core.strategyLister() != _c("Timelock"),
            "CreditCore: only the 7-day timelock adds pool strategies"
        );
    }

    function _checkPause() internal {
        PauseGuard g = PauseGuard(_c("PauseGuard"));
        _expect(
            !g.paused(IPauseGuard.Flag.DEPOSITS) && !g.paused(IPauseGuard.Flag.DRAWS)
                && !g.paused(IPauseGuard.Flag.VENUES),
            "PauseGuard flags all off"
        );
    }

    function _checkCalibur() internal {
        address c = _a(".calibur");
        _expect(
            c == CaliburPin.CANONICAL && c.codehash == CaliburPin.RUNTIME_CODE_HASH,
            "Calibur at the canonical address with the pinned runtime hash"
        );
    }
}
