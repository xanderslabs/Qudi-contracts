// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.30;

/// A vault record's lifecycle. Nothing is ever deleted, only marked, so
/// a record moves from ACTIVE to CLOSED and stops there. NONE is not a state a record reaches:
/// it is the zero value of an unwritten slot, which is what makes "does this vault exist?" a
/// read of `status` rather than a separate flag.
library VaultStatus {
    uint8 constant NONE = 0;
    uint8 constant ACTIVE = 1;
    uint8 constant CLOSED = 2;
}

/// A shared vault payout request's lifecycle. LIVE holds an earmark while its vote runs, PASSED
/// holds it until someone executes, and EXECUTED is terminal. FAILED is never stored: a LIVE request
/// whose window closed without passing is failed, so its earmark is released and the cooldown runs
/// with no transaction.
library ProposalStatus {
    uint8 constant NONE = 0;
    uint8 constant LIVE = 1;
    uint8 constant PASSED = 2;
    uint8 constant EXECUTED = 3;
    uint8 constant FAILED = 4;
}
