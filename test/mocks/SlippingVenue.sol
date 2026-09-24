// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.30;

import {ERC4626, ERC20, IERC20} from "openzeppelin-contracts/contracts/token/ERC20/extensions/ERC4626.sol";
import {SafeERC20} from "openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";

/// A USDC ERC-4626 venue whose `deposit` and `redeem` return a settable fraction of what the
/// matching `preview` reports. `depositFactorBps` / `redeemFactorBps` are in basis points with
/// 10_000 meaning "exactly the preview"; below 10_000 is slippage against the Treasury, above
/// is a move in its favour. Used to exercise the venue slippage limit from both directions.
contract SlippingVenue is ERC4626 {
    using SafeERC20 for IERC20;

    uint256 public depositFactorBps = 10_000;
    uint256 public redeemFactorBps = 10_000;
    uint64 internal _redeemDelay;

    constructor(IERC20 usdc, string memory n, string memory s) ERC20(n, s) ERC4626(usdc) {}

    function setDepositFactorBps(uint256 bps) external {
        depositFactorBps = bps;
    }

    function setRedeemFactorBps(uint256 bps) external {
        redeemFactorBps = bps;
    }

    function setRedeemDelay(uint64 d) external {
        _redeemDelay = d;
    }

    function redeemDelay() external view returns (uint64) {
        return _redeemDelay;
    }

    function deposit(uint256 assets, address receiver) public override returns (uint256 shares) {
        shares = (previewDeposit(assets) * depositFactorBps) / 10_000;
        IERC20(asset()).safeTransferFrom(msg.sender, address(this), assets);
        _mint(receiver, shares);
    }

    function redeem(uint256 shares, address receiver, address owner) public override returns (uint256 assets) {
        assets = (previewRedeem(shares) * redeemFactorBps) / 10_000;
        if (msg.sender != owner) _spendAllowance(owner, msg.sender, shares);
        _burn(owner, shares);
        IERC20(asset()).safeTransfer(receiver, assets);
    }
}
