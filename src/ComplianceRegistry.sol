// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.30;

import {Ownable2Step, Ownable} from "openzeppelin-contracts/contracts/access/Ownable2Step.sol";
import {IComplianceRegistry} from "./interfaces/IComplianceRegistry.sol";

/// Holds two per-account facts written by two different parties:
///
/// - `attest(...)` is self-recorded. The function takes no account argument, so the only
///   account it can write is `msg.sender`. There is no owner path, no screener path, and no
///   Risk Committee path to attest on someone's behalf: a screener that could mint
///   eligibility for any address would be a far larger power than blocking one, which is the
///   whole reason these roles are kept apart.
/// - `setBlocked(...)` is screener-only. On testnet the dev key holds the role; the
///   owner (the Risk Committee 48h timelock) rotates it. The real signers are wired later.
///
/// This contract knows nothing about credit, seats, or vaults. It is read by `Community`
/// (attested and not blocked, at mint) and `Ledger` (not blocked, at contribute).
contract ComplianceRegistry is Ownable2Step, IComplianceRegistry {
    struct Attestation {
        uint64 attestedAt;
        uint32 termsVersion;
    }

    mapping(address => Attestation) internal _attestation;
    mapping(address => bool) internal _blocked;

    address public screener;

    constructor(address screener_) Ownable(msg.sender) {
        if (screener_ == address(0)) revert ZeroAddress();
        screener = screener_;
        emit ScreenerRotated(address(0), screener_);
    }

    function attest(uint32 termsVersion) external {
        _attestation[msg.sender] = Attestation(uint64(block.timestamp), termsVersion);
        emit Attested(msg.sender, termsVersion, uint64(block.timestamp));
    }

    function setBlocked(address account, bool blocked) external {
        if (msg.sender != screener) revert NotScreener();
        _blocked[account] = blocked;
        emit DrawBlockSet(account, blocked, msg.sender);
    }

    function setScreener(address newScreener) external onlyOwner {
        if (newScreener == address(0)) revert ZeroAddress();
        emit ScreenerRotated(screener, newScreener);
        screener = newScreener;
    }

    function isAttested(address account) external view returns (bool) {
        return _attestation[account].attestedAt != 0;
    }

    function attestationOf(address account) external view returns (uint64 attestedAt, uint32 termsVersion) {
        Attestation memory a = _attestation[account];
        return (a.attestedAt, a.termsVersion);
    }

    function isBlocked(address account) external view returns (bool) {
        return _blocked[account];
    }
}
