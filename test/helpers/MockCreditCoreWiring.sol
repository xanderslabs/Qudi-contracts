// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.30;

/// A minimal `factory()`/`config()`/`standing()`-shaped stand-in for `CreditCore`, for a
/// Standing-only test fixture that needs an address to play the `creditCore` role (the
/// `setCreditCore` wiring checks call these three getters) without wiring up a real `CreditCore`. Public state vars, no logic:
/// `CreditStanding` never calls anything else on it, and it is never itself under test.
contract MockCreditCoreWiring {
    address public factory;
    address public config;
    address public standing;

    constructor(address factory_, address config_, address standing_) {
        factory = factory_;
        config = config_;
        standing = standing_;
    }
}
