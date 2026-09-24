// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.30;

import {Community} from "../../src/Community.sol";

/// `Community` with one read added: the threshold denominator a vote stored when it started
/// The deployed contract has no view for it, and the proofs need
/// to compare it against a count done in the test.
contract CommunityHarness is Community {
    function denominatorOf(uint256 voteId) external view returns (uint256) {
        return votes[voteId].denominator;
    }
}
