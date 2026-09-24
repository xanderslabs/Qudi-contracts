// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

/// The one interface every strategy under a `Venue` implements. A partner protocol plugs in with
/// a thin adapter to this, so the money goes to the partner directly and the Venue never needs to
/// know how the partner works.
///
/// Modelled on ERC-4626 but not one: a strategy has exactly one depositor, its Venue, so there are
/// no shares to price and every figure is the Venue's position in assets. How long money takes to
/// come out is not part of this interface. The Venue states that delay itself when it lists the
/// strategy, because an adapter cannot be trusted to report its own exit time honestly.
interface IStrategy {
    /// `deposit` or `withdraw` called by anyone but the strategy's Venue.
    error NotVenue();

    /// The token the strategy holds. The Venue refuses a strategy whose asset is not its own.
    function asset() external view returns (address);

    /// What the Venue's position is worth now, in assets. The Venue reads this on every
    /// interaction, so it must never count money the Venue could not eventually receive.
    function totalAssets() external view returns (uint256);

    /// What the Venue could withdraw right now, in assets.
    function maxWithdraw() external view returns (uint256);

    /// Pulls `assets` from the Venue. Venue only.
    function deposit(uint256 assets) external;

    /// Sends `assets` to `receiver`. Venue only.
    function withdraw(uint256 assets, address receiver) external;
}
