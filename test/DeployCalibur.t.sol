// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {DeployCalibur} from "../script/DeployCalibur.s.sol";
import {CaliburPin} from "../script/CaliburPin.sol";

/// Every Qudi account delegates to the code at one address, so that code must be exactly
/// Uniswap's published build. Code already at the canonical address is used only if it is that
/// build; anything else stops the run and names both hashes. Arc mainnet already has it, so the
/// script never deploys there. The full deploy, and a second run that finds the code and deploys
/// nothing, run against anvil with the real build.
contract DeployCaliburTest is Test {
    DeployCalibur script;

    function setUp() public {
        script = new DeployCalibur();
        vm.chainId(31337);
    }

    function test_calibur_anEmptyAddressIsDeployedTo() public view {
        assertTrue(script.plan(), "nothing there yet, so deploy");
    }

    /// Other code at the canonical address is never accepted as Calibur.
    function test_calibur_aMismatchStops() public {
        bytes memory other = hex"6000";
        vm.etch(CaliburPin.CANONICAL, other);
        vm.expectRevert(
            abi.encodeWithSelector(
                DeployCalibur.CaliburMismatch.selector, keccak256(other), CaliburPin.RUNTIME_CODE_HASH
            )
        );
        script.plan();
    }

    /// Arc mainnet has Uniswap's deployment. Should it ever be missing, the script refuses rather
    /// than deploy a copy of its own there.
    function test_calibur_mainnetIsNeverDeployedTo() public {
        vm.chainId(5042);
        vm.expectRevert(DeployCalibur.MainnetUsesTheExistingDeployment.selector);
        script.plan();
    }

    function test_calibur_otherChainsAreRefused() public {
        vm.chainId(1);
        vm.expectRevert(DeployCalibur.UnsupportedChain.selector);
        script.plan();
    }

    /// The pinned values agree with each other: the init code hash, the salt and the deployer give
    /// the canonical address.
    function test_calibur_thePinIsConsistent() public pure {
        assertEq(
            vm.computeCreate2Address(CaliburPin.SALT, CaliburPin.INIT_CODE_HASH, CaliburPin.DETERMINISTIC_DEPLOYER),
            CaliburPin.CANONICAL
        );
    }
}
