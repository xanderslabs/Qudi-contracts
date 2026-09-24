// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.30;

/// Pool type constants for the three pool instances.
library PoolTypes {
    uint8 constant FLEX = 0;
    uint8 constant CORE = 1;
    /// Renamed from LOCKED on 2026-09-21. It always meant Term, and Term
    /// is a venue profile, not a withdrawal rule: a venue that does not anticipate withdrawals and
    /// can therefore be illiquid. Locking is a property of a vault, enforced in the ledger.
    uint8 constant TERM = 2;
    uint8 constant COUNT = 3;
}
