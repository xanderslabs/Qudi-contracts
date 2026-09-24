// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";

// Toolchain sanity: solc pins, forge-std and OpenZeppelin remappings resolve, CI runs.
contract SanityTest is Test {
    function test_toolchain() public pure {
        assert(type(IERC20).interfaceId != bytes4(0));
    }
}
