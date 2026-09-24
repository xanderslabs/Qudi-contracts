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

/// How a member says they intend to fund a vault (the contribution axis).
/// The ledger stores it on the record and never reads it: enforcing a schedule on chain would
/// need a keeper and a penalty, and neither is part of the design. It is the member's stated intent, which
/// the app shows back to them.
library Contribution {
    uint8 constant ANYTIME = 0;
    uint8 constant SCHEDULED = 1;
    uint8 constant ONE_TIME = 2;
    uint8 constant COUNT = 3;
}

/// A shared-withdrawal proposal's lifecycle. LIVE holds an earmark;
/// EXECUTED and REVERTED are both terminal and both release it, one by paying the recipient and
/// one by returning it to the balance. Nothing expires.
library ProposalStatus {
    uint8 constant NONE = 0;
    uint8 constant LIVE = 1;
    uint8 constant EXECUTED = 2;
    uint8 constant REVERTED = 3;
}
