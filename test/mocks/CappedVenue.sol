// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.30;

import {MockVenue} from "./MockVenue.sol";
import {ERC20, IERC20} from "openzeppelin-contracts/contracts/token/ERC20/extensions/ERC4626.sol";

/// A venue that will not pay out everything it holds, which `MockVenue` cannot express.
///
/// `MockVenue.redeemDelay()` only tags the tier; its `maxWithdraw` is still the full position, so a
/// test using it cannot tell the difference between code that respects the instant tier and code
/// that drains a slow venue anyway, nor reach the clamp that stops a rebalance asking a venue for
/// more than it will give. Both are real bounds in `Venue`, and both were unreachable with the
/// existing doubles. `withdrawCap` is the most a single call may take out.
contract CappedVenue is MockVenue {
    uint256 public withdrawCap = type(uint256).max;

    constructor(IERC20 usdc, string memory name_, string memory symbol_) MockVenue(usdc, name_, symbol_) {}

    function setWithdrawCap(uint256 cap) external {
        withdrawCap = cap;
    }

    function maxWithdraw(address owner) public view override returns (uint256) {
        uint256 full = super.maxWithdraw(owner);
        return full < withdrawCap ? full : withdrawCap;
    }

    function maxRedeem(address owner) public view override returns (uint256) {
        return convertToShares(maxWithdraw(owner));
    }
}
