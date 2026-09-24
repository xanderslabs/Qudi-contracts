// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.30;

import {Script, console} from "forge-std/Script.sol";
import {CaliburPin} from "./CaliburPin.sol";

/// Puts Uniswap's Calibur delegate at its canonical address, or confirms it is already there.
///
/// The build comes from `script/build-calibur.sh`, which compiles Calibur with its own settings and
/// the pinned compiler. This script checks that build three ways before it trusts it: the init code
/// hash, the compiler recorded in the artifact, and the runtime the init code produces at the
/// canonical address. Then:
///   - code already at the canonical address is used if it is that runtime, and the run stops,
///     naming both hashes, if it is anything else;
///   - an empty canonical address gets the build through the deterministic deployer with Uniswap's
///     salt, except on Arc mainnet, which has Uniswap's own deployment and never gets ours.
/// If `deployments/<chainId>.json` exists, its `calibur` key is set to the canonical address.
///
/// Run, after `script/build-calibur.sh`:
///   forge script script/DeployCalibur.s.sol --rpc-url <url> --account <keystore> --broadcast --slow
contract DeployCalibur is Script {
    uint256 internal constant _ANVIL = 31337;
    uint256 internal constant _ARC_TESTNET = 5042002;
    uint256 internal constant _ARC_MAINNET = 5042;

    error UnsupportedChain();
    error CaliburMismatch(bytes32 found, bytes32 expected);
    error MainnetUsesTheExistingDeployment();
    error NotTheCanonicalBuild(bytes32 initCodeHash);
    error WrongCompiler(string found);
    error NoDeterministicDeployer();
    error DeployFailed();

    function run() external {
        bytes memory initCode = _checkedBuild();
        if (plan()) {
            if (CaliburPin.DETERMINISTIC_DEPLOYER.code.length == 0) revert NoDeterministicDeployer();
            vm.broadcast();
            (bool ok, bytes memory ret) =
                CaliburPin.DETERMINISTIC_DEPLOYER.call(abi.encodePacked(CaliburPin.SALT, initCode));
            if (!ok || ret.length != 20 || address(bytes20(ret)) != CaliburPin.CANONICAL) revert DeployFailed();
            if (CaliburPin.CANONICAL.codehash != CaliburPin.RUNTIME_CODE_HASH) {
                revert CaliburMismatch(CaliburPin.CANONICAL.codehash, CaliburPin.RUNTIME_CODE_HASH);
            }
            console.log("Calibur deployed at", CaliburPin.CANONICAL);
        } else {
            console.log("Calibur already at", CaliburPin.CANONICAL, "with the canonical code; nothing deployed");
        }
        console.log("runtime code hash:");
        console.logBytes32(CaliburPin.CANONICAL.codehash);

        string memory record = string.concat(vm.projectRoot(), "/deployments/", vm.toString(block.chainid), ".json");
        if (vm.isFile(record)) {
            vm.writeJson(string.concat('"', vm.toString(CaliburPin.CANONICAL), '"'), record, ".calibur");
            console.log("recorded in", record);
        }
    }

    /// True when the canonical address is empty and this chain may get our deployment; false when
    /// the canonical code is already there. Reverts for any other code, on Arc mainnet when it is
    /// empty, and on any chain Qudi does not run on.
    function plan() public view returns (bool deploy) {
        if (block.chainid != _ANVIL && block.chainid != _ARC_TESTNET && block.chainid != _ARC_MAINNET) {
            revert UnsupportedChain();
        }
        if (CaliburPin.CANONICAL.code.length != 0) {
            bytes32 found = CaliburPin.CANONICAL.codehash;
            if (found != CaliburPin.RUNTIME_CODE_HASH) revert CaliburMismatch(found, CaliburPin.RUNTIME_CODE_HASH);
            return false;
        }
        if (block.chainid == _ARC_MAINNET) revert MainnetUsesTheExistingDeployment();
        return true;
    }

    /// The build's init code, after checking it is the canonical build: its hash, the compiler that
    /// made it, and the runtime it leaves at the canonical address, found by running it there in a
    /// state snapshot that is thrown away.
    function _checkedBuild() internal returns (bytes memory initCode) {
        initCode = vm.getCode(CaliburPin.ARTIFACT);
        if (keccak256(initCode) != CaliburPin.INIT_CODE_HASH) revert NotTheCanonicalBuild(keccak256(initCode));
        string memory compiler = vm.parseJsonString(vm.readFile(CaliburPin.ARTIFACT), ".metadata.compiler.version");
        if (keccak256(bytes(compiler)) != keccak256(bytes(CaliburPin.SOLC))) revert WrongCompiler(compiler);

        uint256 snap = vm.snapshotState();
        vm.etch(CaliburPin.CANONICAL, "");
        vm.setNonceUnsafe(CaliburPin.CANONICAL, 0);
        (bool ok,) = CaliburPin.DETERMINISTIC_DEPLOYER.call(abi.encodePacked(CaliburPin.SALT, initCode));
        bytes32 built = CaliburPin.CANONICAL.codehash;
        vm.revertToStateAndDelete(snap);
        if (!ok || built != CaliburPin.RUNTIME_CODE_HASH) revert CaliburMismatch(built, CaliburPin.RUNTIME_CODE_HASH);
        console.log("build checked: canonical init code, compiler", compiler);
    }
}
