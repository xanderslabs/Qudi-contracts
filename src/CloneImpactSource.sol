// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.30;

import {IImpactSource} from "./interfaces/IImpactSource.sol";
import {ICommunityFactory} from "./interfaces/ICommunityFactory.sol";

/// The impact source for a product that lives in per-community clones. `Community` (the seat leg)
/// and `Ledger` (the yield leg) are one clone each per community, so neither can be listed in
/// `CreditStanding` directly: this looks up the community's clone through the factory and asks it.
///
/// One instance per clone kind, fixed at deployment. A product built as one contract for every
/// community implements `IImpactSource` itself and is listed with no resolver.
contract CloneImpactSource is IImpactSource {
    ICommunityFactory public immutable factory;
    /// True: the community's `Ledger`. False: its `Community`.
    bool public immutable ledger;

    error ZeroAddress();

    constructor(ICommunityFactory factory_, bool ledger_) {
        if (address(factory_) == address(0)) revert ZeroAddress();
        factory = factory_;
        ledger = ledger_;
    }

    /// 0 for a community the factory never created.
    function impactOf(uint256 communityId, address member) external view returns (uint256) {
        if (communityId >= factory.communityCount()) return 0;
        address target = factory.communityAt(communityId);
        if (ledger) target = factory.ledgerOf(target);
        return IImpactSource(target).impactOf(communityId, member);
    }
}
