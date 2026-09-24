// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.30;

import {IVenue} from "../../src/interfaces/IVenue.sol";

/// The venue ids a deployment lists, in the order the deploy script lists them. Tests name a
/// venue by these rather than by a bare number.
library VenueIds {
    uint8 constant FLEX = 0;
    uint8 constant CORE = 1;
    uint8 constant TERM = 2;
    uint8 constant COUNT = 3;

    /// The labels a deployment gives each venue: Flex Open with no exit time, Core Open with a
    /// one-day exit, Term Locked. `maxRateBps` is the config ceiling's launch value, so a test that
    /// moves value sees it within days.
    function labels(uint8 id) internal pure returns (IVenue.Labels memory l) {
        l.name = "Qudi";
        l.riskKey = 3;
        l.maxRateBps = 2000;
        if (id == CORE) l.exitSeconds = 1 days;
        if (id == TERM) l.kind = IVenue.Kind.Locked;
    }
}
