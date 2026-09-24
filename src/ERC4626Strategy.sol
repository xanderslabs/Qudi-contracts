// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.30;

import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {IERC4626} from "openzeppelin-contracts/contracts/interfaces/IERC4626.sol";
import {SafeERC20} from "openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import {IStrategy} from "./interfaces/IStrategy.sol";

/// A strategy over any ERC-4626 vault on the Venue's asset: Morpho, Yearn V3, Aave's wrapped
/// tokens. The money goes straight into the target and comes straight back to the Venue.
///
/// There is no operator and no owner. Nothing here can send money anywhere but into the target and
/// back out to its Venue, so listing one needs nothing but trust in the target itself.
contract ERC4626Strategy is IStrategy {
    using SafeERC20 for IERC20;

    IERC4626 public immutable target;
    address public immutable venue;
    IERC20 internal immutable _asset;

    error ZeroAddress();

    constructor(IERC4626 target_, address venue_) {
        if (venue_ == address(0) || address(target_) == address(0)) revert ZeroAddress();
        target = target_;
        venue = venue_;
        _asset = IERC20(target_.asset());
        _asset.forceApprove(address(target_), type(uint256).max);
    }

    modifier onlyVenue() {
        if (msg.sender != venue) revert NotVenue();
        _;
    }

    function asset() external view returns (address) {
        return address(_asset);
    }

    /// The adapter's shares at the target's own share price.
    function totalAssets() external view returns (uint256) {
        return target.convertToAssets(target.balanceOf(address(this)));
    }

    function maxWithdraw() external view returns (uint256) {
        return target.maxWithdraw(address(this));
    }

    function deposit(uint256 assets) external onlyVenue {
        _asset.safeTransferFrom(msg.sender, address(this), assets);
        target.deposit(assets, address(this));
    }

    function withdraw(uint256 assets, address receiver) external onlyVenue {
        target.withdraw(assets, receiver, address(this));
    }
}
