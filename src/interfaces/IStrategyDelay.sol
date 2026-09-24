// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

/// A yield venue's redemption delay in seconds. `Venue` uses it to sort venues into the
/// instant tier (delay 0) and the slow tier; `CreditCore` uses it at listing to reject a venue
/// whose delay exceeds the configured maximum redemption delay. The same selector both contracts already relied on,
/// lifted here so there is one definition.
interface IStrategyDelay {
    function redeemDelay() external view returns (uint64);
}
