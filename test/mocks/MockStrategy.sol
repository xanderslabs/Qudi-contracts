// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.30;

import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import {IStrategy} from "../../src/interfaces/IStrategy.sol";

/// Test double for a strategy. Its value is its own USDC balance, so a test moves the Venue's
/// position by hand: `fund` adds USDC (a gain) and `skim` removes it (a loss). `withdrawCap` is the
/// most `maxWithdraw` reports, so a test can hold money in a strategy that will not give all of it
/// back at once. Every setter is open, for test convenience.
contract MockStrategy is IStrategy {
    using SafeERC20 for IERC20;

    IERC20 internal immutable _asset;
    address public immutable venue;
    uint256 public withdrawCap = type(uint256).max;

    constructor(IERC20 asset_, address venue_) {
        _asset = asset_;
        venue = venue_;
    }

    function asset() external view returns (address) {
        return address(_asset);
    }

    function totalAssets() public view returns (uint256) {
        return _asset.balanceOf(address(this));
    }

    function maxWithdraw() external view returns (uint256) {
        uint256 v = totalAssets();
        return v < withdrawCap ? v : withdrawCap;
    }

    function deposit(uint256 assets) external {
        if (msg.sender != venue) revert NotVenue();
        _asset.safeTransferFrom(msg.sender, address(this), assets);
    }

    function withdraw(uint256 assets, address receiver) external {
        if (msg.sender != venue) revert NotVenue();
        _asset.safeTransfer(receiver, assets);
    }

    function fund(uint256 assets) external {
        _asset.safeTransferFrom(msg.sender, address(this), assets);
    }

    function skim(uint256 assets) external {
        _asset.safeTransfer(msg.sender, assets);
    }

    function setWithdrawCap(uint256 cap) external {
        withdrawCap = cap;
    }
}
