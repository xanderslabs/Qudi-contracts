// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.30;

import {Ownable2Step, Ownable} from "openzeppelin-contracts/contracts/access/Ownable2Step.sol";
import {IPauseGuard} from "./interfaces/IPauseGuard.sol";

/// Three flags the pause key sets with no delay. One small contract read by every money contract,
/// so there is one place to see and flip every lever, and handing the levers to someone else is
/// one ownership transfer instead of one per contract.
///
/// The owner is the timelock. It only rotates the pause key; it cannot set a flag itself, so the
/// one key that can stop things instantly is always a key the timelock chose.
contract PauseGuard is IPauseGuard, Ownable2Step {
    address public override pauser;
    mapping(Flag => bool) internal _paused;

    constructor(address owner_, address pauser_) Ownable(owner_) {
        if (pauser_ == address(0)) revert ZeroAddress();
        pauser = pauser_;
        emit PauserSet(address(0), pauser_);
    }

    function setPaused(Flag flag, bool paused_) external override {
        if (msg.sender != pauser) revert NotPauser();
        _paused[flag] = paused_;
        emit PauseSet(flag, paused_);
    }

    function setPauser(address next) external override onlyOwner {
        if (next == address(0)) revert ZeroAddress();
        emit PauserSet(pauser, next);
        pauser = next;
    }

    function paused(Flag flag) external view override returns (bool) {
        return _paused[flag];
    }
}
