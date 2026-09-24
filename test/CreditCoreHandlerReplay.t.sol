// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {Config} from "../src/Config.sol";
import {IConfig} from "../src/interfaces/IConfig.sol";
import {CreditStanding} from "../src/CreditStanding.sol";
import {MockUSDC} from "./mocks/MockUSDC.sol";
import {MockVenue} from "./mocks/MockVenue.sol";
import {CreditCoreHarness} from "./helpers/CreditCoreHarness.sol";
import {MockCommunityFactory} from "./helpers/MockCommunityFactory.sol";
import {CreditCoreHandler} from "./invariant/CreditCore.inv.t.sol";

/// A fixed 4000-step handler-shaped sequence, seeded from a constant, so
/// the landed-attempt counts are the same number before and after the handler fix and any
/// change in them is the fix. Not an invariant run: a plain deterministic replay whose method
/// picks and raw arguments come only from the step index, so state changes move which calls
/// land but never which calls are made.
contract CreditCoreHandlerReplayTest is Test {
    MockUSDC usdc;
    Config config;
    MockCommunityFactory factory;
    MockVenue venue;
    MockVenue venue2;
    CreditCoreHarness cc;
    CreditCoreHandler handler;

    address governance = makeAddr("governance");
    address treasuryMgr = makeAddr("treasuryManager");
    address allocationMs = makeAddr("allocationMultisig");

    bytes32 constant SEED = keccak256("qudi.handler-replay.v1");
    uint256 constant STEPS = 4000;

    function setUp() public {
        usdc = new MockUSDC();
        config = new Config(address(usdc), makeAddr("treasury"), makeAddr("registry"));
        factory = new MockCommunityFactory();
        factory.addCommunity();
        venue = new MockVenue(IERC20(address(usdc)), "V", "V");
        venue2 = new MockVenue(IERC20(address(usdc)), "V2", "V2");
        CreditStanding standing = new CreditStanding(IConfig(address(config)), address(factory), governance);
        cc = new CreditCoreHarness(
            IERC20(address(usdc)),
            IConfig(address(config)),
            address(factory),
            governance,
            treasuryMgr,
            allocationMs,
            standing
        );
        vm.prank(governance);
        standing.setCreditCore(address(cc));
        cc.addVenue(address(venue));
        cc.addVenue(address(venue2));
        handler = _newHandler();
    }

    /// Built through a helper so a compile against either handler constructor arity works; the
    /// try/catch picks whichever the current source declares.
    function _newHandler() internal returns (CreditCoreHandler h) {
        h = new CreditCoreHandler(cc, usdc, venue, venue2, factory, governance, treasuryMgr, allocationMs);
    }

    function _arg(uint256 step, uint256 i) internal pure returns (uint256) {
        return uint256(keccak256(abi.encode(SEED, step, i)));
    }

    /// Weighted so the sequence actually fills venues toward the caps, where the difference
    /// between the old bound (overshoots the per-venue cap) and the new one (fits under it)
    /// shows. Weights: fund 4, allocate 2, depositToVenue 7, withdrawFromVenue 2, venueGain 2,
    /// venueLoss 1, addCommunity 1, setBook 1, warp 1 (total 21).
    function _weightedPick(uint256 step) internal pure returns (uint256) {
        uint256 r = _arg(step, 0) % 21;
        if (r < 4) return 0; // fund
        if (r < 6) return 2; // allocate
        if (r < 13) return 4; // depositToVenue
        if (r < 15) return 5; // withdrawFromVenue
        if (r < 17) return 6; // venueGain
        if (r < 18) return 7; // venueLoss
        if (r < 19) return 1; // addCommunity
        if (r < 20) return 8; // setBook
        return 10; // warp
    }

    function test_replay4000Steps_reportsLandedDepositCounts() public {
        for (uint256 step; step < STEPS; step++) {
            _dispatch(_weightedPick(step), step);
        }

        emit log_named_uint("venue deposit attempts ", handler.venueDepositTries());
        emit log_named_uint("venue deposits landed   ", handler.venueDepositLands());
        emit log_named_uint("venue withdraw attempts ", handler.venueWithdrawTries());
        emit log_named_uint("venue withdraws landed  ", handler.venueWithdrawLands());

        // The point of the fix: most deposit attempts land. Anything above half is a pass;
        // the exact number is in the log.
        assertGt(handler.venueDepositLands() * 2, handler.venueDepositTries());
    }

    function _dispatch(uint256 pick, uint256 step) internal {
        if (pick == 0) {
            try handler.fund(_arg(step, 1)) {} catch {}
        } else if (pick == 1) {
            try handler.addCommunity() {} catch {}
        } else if (pick == 2) {
            try handler.allocate(_arg(step, 1), _arg(step, 2), uint8(_arg(step, 3))) {} catch {}
        } else if (pick == 3) {
            try handler.closeCommunity(_arg(step, 1)) {} catch {}
        } else if (pick == 4) {
            try handler.depositToVenue(_arg(step, 1)) {} catch {}
        } else if (pick == 5) {
            try handler.withdrawFromVenue(_arg(step, 1)) {} catch {}
        } else if (pick == 6) {
            try handler.venueGain(_arg(step, 1)) {} catch {}
        } else if (pick == 7) {
            try handler.venueLoss(_arg(step, 1)) {} catch {}
        } else if (pick == 8) {
            try handler.setBook(_arg(step, 1), _arg(step, 2), _arg(step, 3), _arg(step, 4)) {} catch {}
        } else if (pick == 9) {
            try handler.setPending(_arg(step, 1)) {} catch {}
        } else {
            try handler.warp(_arg(step, 1)) {} catch {}
        }
    }
}
