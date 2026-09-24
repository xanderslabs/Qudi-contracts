// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

/// A yield venue's redemption delay in seconds. `CreditCore` uses it at listing to reject a venue
/// whose delay exceeds the configured maximum redemption delay. `Venue` no longer reads it: a
/// Venue states each strategy's delay itself when it lists one.
interface IStrategyDelay {
    function redeemDelay() external view returns (uint64);
}
