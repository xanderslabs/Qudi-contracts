// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.30;

import {ICommunityInit} from "../../src/interfaces/ICommunityInit.sol";

/// Records the wiring it receives so factory tests can assert it; enforces
/// clone-init discipline by reverting on a second initialize.
contract MockCommunityModule is ICommunityInit {
    CommunityWiring internal _wiring;
    bool public initialized;

    error AlreadyInitialized();

    function initialize(CommunityWiring calldata w) external {
        if (initialized) revert AlreadyInitialized();
        initialized = true;
        _wiring = w;
    }

    function wiring() external view returns (CommunityWiring memory) {
        return _wiring;
    }
}
