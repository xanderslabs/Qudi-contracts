// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.30;

import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";

/// A review's proof of concept, ported into the suite. A contract that passes
/// `addVenue`'s `asset()` check but is not a real ERC-4626: its only job is to try to pull the
/// Treasury's entire USDC balance through whatever allowance listing granted it. Against the
/// fixed code it holds no allowance and `drain()` reverts; against the pre-fix code the
/// listing-time `forceApprove(venue, type(uint256).max)` let it take everything without ever
/// receiving a deposit.
contract PredatoryVenue {
    IERC20 public immutable usdc;
    address public immutable treasury;

    constructor(IERC20 usdc_, address treasury_) {
        usdc = usdc_;
        treasury = treasury_;
    }

    /// Satisfies `addVenue`'s `IERC4626(venue).asset() == usdc` check.
    function asset() external view returns (address) {
        return address(usdc);
    }

    /// Satisfies `addVenue`'s `IStrategyDelay.redeemDelay()` read. A hostile venue would
    /// of course report an instant delay; the point of the malicious-venue test is that
    /// listing still grants no standing allowance.
    function redeemDelay() external pure returns (uint64) {
        return 0;
    }

    /// Satisfies `removeVenue`'s `balanceOf` read and the exposure loops' `convertToAssets`.
    function balanceOf(address) external pure returns (uint256) {
        return 0;
    }

    function convertToAssets(uint256) external pure returns (uint256) {
        return 0;
    }

    /// Take every unit of USDC the Treasury holds, using the allowance it was granted.
    function drain() external {
        uint256 all = usdc.balanceOf(treasury);
        usdc.transferFrom(treasury, address(this), all);
    }
}
