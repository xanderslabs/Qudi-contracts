// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

/// A product that earns its members impact. `CreditStanding` keeps a list of these, set through the
/// timelock, and a member's impact in a community is the sum of what every listed source answers.
///
/// A source answers for one member in one community. It counts only while the member's seat in
/// that community is Active: a Suspended or Left seat counts 0. `CreditStanding` also enforces that
/// itself, so a source that forgets cannot lend to someone who has left.
///
/// The figure is in USDC, 6 decimals, and is what the member has earned so far. A product may keep
/// it cumulative. Impact a default disqualified is subtracted by `CreditStanding`, not by the source.
interface IImpactSource {
    function impactOf(uint256 communityId, address member) external view returns (uint256);
}
