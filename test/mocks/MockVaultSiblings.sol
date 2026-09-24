// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.30;

import {ICommunityInit} from "../../src/interfaces/ICommunityInit.sol";

/// Records tab and payments for each member. setTab lets tests stage member tabs; receiveTabPayment
/// decrements the tab and accumulates paymentsReceived for that member. Also accepts the
/// factory's initialize call (no-op) so it can stand in as a community contract in factory fixtures.
///
/// A plain contract: `IVaultCreditPoolHooks`, the interface it used to implement, lost
/// its last caller and was deleted. `NoIntercept.t.sol` keeps it as the adversary, a
/// per-community pool that reports a tab and would accept a repayment if anything routed one.
contract MockCreditPoolForVault is ICommunityInit {
    function initialize(CommunityWiring calldata) external {}

    mapping(address => uint256) public tab;
    mapping(address => uint256) public paymentsReceived;

    function setTab(address member, uint256 amount) external {
        tab[member] = amount;
    }

    function tabOutstanding(address member) external view returns (uint256) {
        return tab[member];
    }

    function receiveTabPayment(address member, uint256 amount) external {
        tab[member] -= amount;
        paymentsReceived[member] += amount;
    }
}
