// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

/// The instant stop. Each money contract reads `Config.pauseGuard()` and asks it one question
/// before money moves in. Only money going in can be stopped: every path that brings money back
/// to a member, repays an advance or books a gain that already happened stays open, so a pause
/// can never trap anyone's money.
interface IPauseGuard {
    /// DEPOSITS stops `Ledger.deposit`. DRAWS stops `CreditCore.draw`. VENUES stops money moving
    /// into a strategy: a Venue's allocation, `CreditCore.depositToStrategy` and
    /// `ManualStrategy.deploy`.
    enum Flag {
        DEPOSITS,
        DRAWS,
        VENUES
    }

    /// Sets or clears one flag, at once. Pauser only.
    function setPaused(Flag flag, bool paused_) external;
    /// Owner only. The owner is the timelock, so the pause key can stop things instantly but
    /// cannot hand that power to anyone else.
    function setPauser(address next) external;
    function paused(Flag flag) external view returns (bool);
    function pauser() external view returns (address);

    event PauseSet(Flag indexed flag, bool paused);
    event PauserSet(address indexed previous, address indexed next);

    /// Raised by the money contracts when the flag guarding the call is set.
    error Paused();
    error NotPauser();
    error ZeroAddress();
}
