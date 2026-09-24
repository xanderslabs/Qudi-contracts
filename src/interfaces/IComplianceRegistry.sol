// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

/// Two independent compliance gates for a Qudi Account, deliberately held apart from
/// every credit contract so the screener role has no foothold in credit powers.
///
/// - **Attested**: written by the member, in their own transaction, about themselves. There is
///   no account parameter on `attest` and no admin path: the only account any call can write
///   is `msg.sender`.
/// - **Blocked**: written by the screener role only. Checked at seat mint, contribute, and
///   draw.
interface IComplianceRegistry {
    /// Emitted when a member records their own seat-mint attestation (terms, age and lawful
    /// use, region). This is not the first-draw Credit Agreement acceptance, which is
    /// a separate acceptance recorded in the draw event.
    event Attested(address indexed account, uint32 termsVersion, uint64 timestamp);
    event DrawBlockSet(address indexed account, bool blocked, address indexed screener);
    event ScreenerRotated(address indexed oldScreener, address indexed newScreener);

    error NotScreener();
    error ZeroAddress();

    /// The member records that they accepted terms version `termsVersion`. Overwrites any
    /// prior attestation by the same account. Cannot attest for anyone else.
    function attest(uint32 termsVersion) external;

    /// Screener role only. Sets or clears the per-account draw-block flag.
    function setBlocked(address account, bool blocked) external;

    /// Owner only (the Risk Committee timelock). Rotates the
    /// screener key.
    function setScreener(address newScreener) external;

    function isAttested(address account) external view returns (bool);
    function attestationOf(address account) external view returns (uint64 attestedAt, uint32 termsVersion);
    function isBlocked(address account) external view returns (bool);
    function screener() external view returns (address);
}
