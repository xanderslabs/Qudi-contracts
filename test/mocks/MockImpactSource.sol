// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.30;

import {IImpactSource} from "../../src/interfaces/IImpactSource.sol";

/// A third impact source, the shape a future singleton product would have: one contract answering
/// for every community. Its figures are set by hand. It does not look at seats at all, so a test
/// can show that the registry itself stops a Suspended or Left seat from counting.
contract MockImpactSource is IImpactSource {
    mapping(uint256 => mapping(address => uint256)) internal _impact;

    function setImpact(uint256 communityId, address member, uint256 amount) external {
        _impact[communityId][member] = amount;
    }

    function impactOf(uint256 communityId, address member) external view returns (uint256) {
        return _impact[communityId][member];
    }
}

/// A source that always reverts. The registry skips it, so one broken product cannot stop every
/// draw, or the default that must be recorded before a repayment.
contract RevertingImpactSource is IImpactSource {
    function impactOf(uint256, address) external pure returns (uint256) {
        revert("broken source");
    }
}
