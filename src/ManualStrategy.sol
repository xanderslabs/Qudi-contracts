// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.30;

import {ERC4626, ERC20, IERC20} from "openzeppelin-contracts/contracts/token/ERC20/extensions/ERC4626.sol";
import {SafeERC20} from "openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable2Step, Ownable} from "openzeppelin-contracts/contracts/access/Ownable2Step.sol";

/// Testnet-only stand-in for a real yield venue. A plain ERC-4626 on USDC whose share price the
/// owner moves by hand: `fund` adds USDC without minting (gain), `skim` removes USDC without
/// burning (loss). The seed script calls `fund` on a schedule so the app shows a live rate.
/// Never deployed to mainnet.
contract ManualStrategy is ERC4626, Ownable2Step {
    using SafeERC20 for IERC20;

    uint64 internal _redeemDelay;

    event Funded(uint256 assets);
    event Skimmed(uint256 assets);

    constructor(IERC20 usdc, address owner_, string memory name_, string memory symbol_)
        ERC20(name_, symbol_)
        ERC4626(usdc)
        Ownable(owner_)
    {}

    function fund(uint256 assets) external onlyOwner {
        IERC20(asset()).safeTransferFrom(msg.sender, address(this), assets);
        emit Funded(assets);
    }

    function skim(uint256 assets) external onlyOwner {
        IERC20(asset()).safeTransfer(msg.sender, assets);
        emit Skimmed(assets);
    }

    function setRedeemDelay(uint64 d) external onlyOwner {
        _redeemDelay = d;
    }

    /// 0 means instant tier; above 0 the vault treats this venue as slow.
    function redeemDelay() external view returns (uint64) {
        return _redeemDelay;
    }
}
