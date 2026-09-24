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
    function hostVote() external view returns (uint16 thresholdBps, uint64 window);
    function communityVote() external view returns (uint16 thresholdBps, uint64 window);
    /// Who a shared vault payout counts: at least `minDeposit` in, first at least `seasoning` ago.
    function qualifyingContributor() external view returns (uint256 minDeposit, uint64 seasoning);
    /// Seconds after a failed removal vote's deadline before the same member may be proposed
    /// again.
    function removalReproposeCooldown() external view returns (uint64);
    function handoverAcceptWindow() external view returns (uint64);
    /// The most vaults one member's list in one community may hold.
    function maxVaultsPerMember() external view returns (uint256);
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
    function yieldSplit() external view returns (uint16 memberBps, uint16 poolBps, uint16 protocolBps);
    function instantTierFloorBps() external view returns (uint16);
    function slowTierCeilingBps() external view returns (uint16);
    function maxNoticePeriod() external view returns (uint64);
    function globalDepositCap() external view returns (uint256);
    /// The ceiling on any Venue's `maxRate`, in annual bps.
    function maxRateCeilingBps() external view returns (uint16);
    /// The ceiling on `ManualStrategy.setRate`, in annual bps.
    function manualRateCeilingBps() external view returns (uint16);
    function protocolTreasury() external view returns (address);
    function complianceRegistry() external view returns (address);
    function memberSeasoningWindow() external view returns (uint64);
    function usdc() external view returns (address);
    function minLendable() external view returns (uint256);
    function globalMemberCap() external view returns (uint256);
    function activityDecayLength() external view returns (uint64);
    function activityFloorBps() external view returns (uint16);
    function standingHealWindow() external view returns (uint64);
    /// Per phase: the multiplier on impact in hundredths, the line cap, and the time since the
    /// first repaid advance the phase needs.
    function phaseTerms(uint8 phase) external view returns (uint256 multiplierX100, uint256 cap, uint64 minTime);
    /// The most one member's line may be, as a share of what the community can lend now.
    function concentrationBps() external view returns (uint16);
    /// Seconds from a defaulted advance's full repayment until the default heals.
    function defaultHealCooling() external view returns (uint64);

    // ---- the pool ----

    /// Zero until a deployment sets it. `Community` reads it for the open-tab forfeit gate.
    function creditCore() external view returns (address);
    function pauseGuard() external view returns (address);
    /// The share of every unlent paper balance a pool strategy deposit must leave as cash.
    function poolLiquidFloorBps() external view returns (uint16);
    /// The community dormancy windows, in seconds.
    function communityDormancy()
        external
        view
        returns (uint64 grace, uint64 fadeLength, uint64 healLength, uint64 returnAfter);
    /// The most late plus defaulted principal may be, as a share of what a community has out,
    /// before its draws stop.
    function portfolioQualityBps() external view returns (uint16);
    /// The Active seasoned seats a community needs before anyone in it may draw.
    function communityMinMembers() external view returns (uint256);
    /// The most seats one wallet may hold across every community, in any state.
    function maxSeatsPerWallet() external view returns (uint256);
    /// The current Credit Agreement's hash. A member's first draw must carry it.
    function creditAgreementHash() external view returns (bytes32);
}
