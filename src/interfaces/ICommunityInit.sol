// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

/// Initialization the factory performs on each freshly cloned community module.
interface ICommunityInit {
    struct CommunityWiring {
        address config;
        address factory;
        address seats;
        address community;
        address vault;
        address creator;
        uint256 seatPrice;
        string name;
        uint8 poolType;
    }

    function initialize(CommunityWiring calldata w) external;
}
