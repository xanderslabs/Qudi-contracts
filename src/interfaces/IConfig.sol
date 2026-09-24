// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

/// Read surface of the Qudi parameter registry. Consumers read live at each use;
/// a parameter change binds future actions only.
interface IConfig {
    error UnknownPoolType();
    function seatPriceFloor() external view returns (uint256);
    function seatPriceCeiling() external view returns (uint256);
    /// The most Active seats a community holds.
    function memberCap() external view returns (uint256);
    /// The largest invite `join` accepts: its uses, and seconds from issue to expiry.
    function inviteLimits() external view returns (uint32 maxUses, uint64 maxTtl);
    function mintSplit() external view returns (uint16 host, uint16 pool, uint16 protocol);
    function epochLength() external view returns (uint64);
    function withdrawTerm(uint8 poolType) external view returns (uint64);
    function hostVote() external view returns (uint16 thresholdBps, uint64 window);
    function communityVote() external view returns (uint16 thresholdBps, uint64 window);
    /// The shared-vault withdrawal's two bars, both counts of people.
    function sharedWithdrawalVote() external view returns (uint16 quorumBps, uint16 approvalBps);
    /// Seconds after a passed proposal's window closes before it becomes revertible.
    function qualifyingContributor() external view returns (uint256 minDeposit, uint64 seasoning);
    function sharedProposalRevertDelay() external view returns (uint64);
    /// Seconds after a failed removal vote's deadline before the same member may be proposed
    /// again.
    function removalReproposeCooldown() external view returns (uint64);
    function stageBoundaries()
        external
        view
        returns (
            uint64 graceStart,
            uint64 lateStart,
            uint64 finalCureStart,
            uint64 defaultRecoveryStart,
            uint64 writtenOffAt
        );
    function dormancyGrace() external view returns (uint64);
    function eligibility()
        external
        view
        returns (uint8 minMembers, uint8 cleanEpochs, uint8 memberMonths, uint8 maxGapMonths);
    function yieldSplit() external view returns (uint16 memberBps, uint16 poolBps, uint16 protocolBps);
    function navPauseThresholdBps() external view returns (uint16);
    function instantTierFloorBps() external view returns (uint16);
    function slowTierCeilingBps() external view returns (uint16);
    function maxNoticePeriod() external view returns (uint64);
    function globalDepositCap() external view returns (uint256);
    function protocolTreasury() external view returns (address);
    function complianceRegistry() external view returns (address);
    function memberSeasoningWindow() external view returns (uint64);
    // The Yield Engine, vault half. The unlock window, the harvest
    // idempotency period and the deviation-breaker multiple, read together because
    // `Venue.harvest` needs all three.
    function yieldEngine() external view returns (uint64 unlockPeriod, uint64 harvestPeriod, uint16 deviationX100);
    function usdc() external view returns (address);
    function flexBufferTargetBps() external view returns (uint16);
    function minLendable() external view returns (uint256);
    function globalMemberCap() external view returns (uint256);
    function exposureImpactMultX100() external view returns (uint256);
    function activityDecayLength() external view returns (uint64);
    function activityFloorBps() external view returns (uint16);
    function standingHealWindow() external view returns (uint64);
    function teCommunityCapBps() external view returns (uint16);
    function phaseCaps(uint8 phase)
        external
        view
        returns (uint256 lineCap, uint16 concentrationBps, uint256 trustExtensionBudget, uint64 minTime);
    function operatingRequirement() external view returns (uint256 perCommunityBuffer, uint256 globalFloor);
    function creditLossReserveBps()
        external
        view
        returns (uint16 current, uint16 late, uint16 finalCure, uint16 defaultRecovery);
    function venueLossReserveBps() external view returns (uint16);
    function venueAllocationMaxBps() external view returns (uint16);
    function perVenueCapBps() external view returns (uint16);
    function maxVenueRedemptionDelay() external view returns (uint64);
    function maxVenueSlippageBps() external view returns (uint16);
    function stressCapital() external view returns (uint16 rateBps, uint256 floor);

    // ---- the debt half ----

    /// Zero until a deployment sets it. `Community` reads it for the open-tab forfeit gate.
    function creditCore() external view returns (address);
    /// The per-completed-obligation increment to a member's earned Trust Extension
    /// counter. Launch value is a bounded starting point, to be calibrated.
    function teEarnIncrement() external view returns (uint256);
}
