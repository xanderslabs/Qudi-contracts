// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.30;

import {IVenue} from "../src/interfaces/IVenue.sol";

/// The three beta venues, listed in the factory's registry in this order: Flex (0), Core (1),
/// Term (2). The deploy script sets these labels and `CheckDeployment` asserts them, so both read
/// them from here.
///
/// The estimated return is what a member receives after the split, an estimate and never a promise.
/// `maxRateBps` sits a little above the gross the strategy earns (about 2.9%, 5.0% and 6.4%), so the
/// growth cap binds only on a jump.
library VenueLabels {
    uint8 internal constant FLEX = 0;
    uint8 internal constant CORE = 1;
    uint8 internal constant TERM = 2;
    uint8 internal constant COUNT = 3;

    function labels(uint8 id) internal pure returns (IVenue.Labels memory) {
        if (id == FLEX) {
            return IVenue.Labels({
                name: "Flex", kind: IVenue.Kind.Open, riskKey: 1, estReturnBps: 200, exitSeconds: 0, maxRateBps: 300
            });
        }
        if (id == CORE) {
            return IVenue.Labels({
                name: "Core",
                kind: IVenue.Kind.Open,
                riskKey: 3,
                estReturnBps: 350,
                exitSeconds: 1 days,
                maxRateBps: 520
            });
        }
        return IVenue.Labels({
            name: "Term", kind: IVenue.Kind.Locked, riskKey: 3, estReturnBps: 450, exitSeconds: 0, maxRateBps: 660
        });
    }

    /// The venue's key in the deployment record: `VenueFlex`, `ManualStrategyFlex` and so on.
    function suffix(uint8 id) internal pure returns (string memory) {
        if (id == FLEX) return "Flex";
        if (id == CORE) return "Core";
        return "Term";
    }
}
