// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.30;

import {ERC4626, ERC20, IERC20} from "openzeppelin-contracts/contracts/token/ERC20/extensions/ERC4626.sol";

/// A plain USDC ERC-4626 venue that does NOT implement `IStrategyDelay.redeemDelay()`. Used to
/// assert the fail-closed listing rule: a venue whose redemption delay cannot be read is not
/// listable.
contract NoDelayVenue is ERC4626 {
    constructor(IERC20 usdc, string memory n, string memory s) ERC20(n, s) ERC4626(usdc) {}
}
