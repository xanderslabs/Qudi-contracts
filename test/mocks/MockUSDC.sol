// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.30;

import {ERC20} from "openzeppelin-contracts/contracts/token/ERC20/ERC20.sol";

contract MockUSDC is ERC20 {
    /// Stand-in for a real USDC blocklist: a blocked address cannot receive.
    mapping(address => bool) public blocked;

    error Blocked();

    constructor() ERC20("Mock USDC", "USDC") {}

    function setBlocked(address a, bool v) external {
        blocked[a] = v;
    }

    function _update(address from, address to, uint256 value) internal override {
        if (blocked[to]) revert Blocked();
        super._update(from, to, value);
    }

    function decimals() public pure override returns (uint8) {
        return 6;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}
