// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.30;

import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {ICreditCore} from "../../src/interfaces/ICreditCore.sol";
import {ICommunityInit} from "../../src/interfaces/ICommunityInit.sol";

/// Seats makes no vault calls, and `ISeatsVaultHooks`, the empty interface this mock used
/// to implement, was deleted. `balances` and `setBalance` remain as a plain test fixture
/// for Seats tests asserting savings are untouched by seat membership changes.
contract MockVault is ICommunityInit {
    bool public initialized;
    mapping(address => uint256) public balances;

    error AlreadyInitialized();

    function initialize(CommunityWiring calldata) external {
        if (initialized) revert AlreadyInitialized();
        initialized = true;
    }

    function setBalance(address who, uint256 amount) external {
        balances[who] = amount;
    }

    // Accepts the factory's post-init pool wiring when this mock stands in for the ledger
    // implementation in factory fixtures.
    function setVault(address) external {}
}

/// A community contract stand-in that only accepts `initialize`. Its hooks went with
/// `ISeatsCreditPoolHooks`: the mint's community leg pays `CreditCore`, and the forfeit
/// gate reads `CreditCore.hasOpenTab`, both through `MockCreditCoreLeg` below.
contract MockCreditPool is ICommunityInit {
    bool public initialized;

    error AlreadyInitialized();

    function initialize(CommunityWiring calldata) external {
        if (initialized) revert AlreadyInitialized();
        initialized = true;
    }
}

/// A minimal stand-in for the two parts of the singleton CreditCore that community contracts touch,
/// wired through `Config.CREDIT_CORE`.
///
/// `hasOpenTab` is the forfeit gate: `Community.forfeit` reads
/// `config.creditCore().hasOpenTab(member)`, not a per-community credit pool.
///
/// `receiveCommunityLeg` is the community leg door. It records per-community totals so a
/// seats-level test can assert the 40% landed against the right community id, and it **checks
/// that the USDC actually arrived**, the same bound the real `CreditCore` enforces with
/// `LegNotFunded`. Without that check this mock would accept a leg nobody paid, which is
/// exactly the shape of fixture that passes while proving nothing.
contract MockCreditCoreLeg {
    IERC20 public immutable usdc;

    mapping(address => bool) public openTab;
    mapping(uint256 => uint256) public legOf;
    uint256 public totalLegs;
    uint256 public lastCommunityId;
    uint256 internal _booked;

    error LegNotFunded();

    constructor(IERC20 usdc_) {
        usdc = usdc_;
    }

    function setOpenTab(address who, bool v) external {
        openTab[who] = v;
    }

    function hasOpenTab(address member) external view returns (bool) {
        return openTab[member];
    }

    function receiveCommunityLeg(uint256 communityId, uint256 amount) external {
        if (usdc.balanceOf(address(this)) < _booked + amount) revert LegNotFunded();
        _booked += amount;
        legOf[communityId] += amount;
        totalLegs += amount;
        lastCommunityId = communityId;
    }
}
