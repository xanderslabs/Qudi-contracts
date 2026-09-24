// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.30;

import {Community} from "../src/Community.sol";
import {Ledger} from "../src/Ledger.sol";
import {ILedger} from "../src/interfaces/ILedger.sol";
import {ConfigKeys as K} from "../src/ConfigKeys.sol";
import {CreditFixture} from "./helpers/CreditFixture.sol";
import {VenueIds} from "./helpers/VenueIds.sol";

/// A formal default walks every seat the wallet holds and asks every impact source about each,
/// inside the repayment that crosses it. `MAX_SEATS_PER_WALLET` bounds that walk, so a member at the
/// cap can always repay. This measures the worst case the bounds allow: every seat Active, and in
/// each community a full list of `MAX_VAULTS_PER_MEMBER` shared vaults, the most costly kind for the
/// yield leg to read.
contract CreditDefaultGasTest is CreditFixture {
    uint256 constant SETTLE_GAS_CEILING = 10_000_000;

    address m;
    uint256 firstId;

    function setUp() public override {
        super.setUp();
        config.set(K.COMMUNITY_DORMANCY_GRACE, 730 days);
        m = _person();
        uint256 cap = config.maxSeatsPerWallet();
        uint256 vaults = config.maxVaultsPerMember();
        for (uint256 c; c < cap; c++) {
            (Community com, uint256 id, address[] memory people) = _community(100e6, 5);
            _join(com, m);
            if (c == 0) firstId = id;
            _fillWithSharedVaults(id, people[0], vaults);
        }
        assertEq(seats.balanceOf(m), cap, "the member holds the most seats a wallet may");
        _season();
        _grant(firstId, 10_000e6);
    }

    function _fillWithSharedVaults(uint256 id, address host, uint256 n) internal {
        Ledger l = _ledger(id);
        usdc.mint(m, n * 1e6);
        vm.prank(m);
        usdc.approve(address(l), type(uint256).max);
        for (uint256 i; i < n; i++) {
            vm.prank(host);
            uint256 v =
                l.createVault(ILedger.VaultParams({venueId: VenueIds.FLEX, shared: true, lockedUntil: 0, name: "pot"}));
            vm.prank(m);
            l.deposit(v, 1e6);
        }
        assertEq(l.vaultsOf(m).length, n);
    }

    /// The repayment that crosses the default, snapshot included, stays under 10M gas at the cap.
    /// Measured at 8,750,280 with the launch values: 10 seats, 32 shared vaults in each.
    function test_settleAtTheDefaultCrossingFitsAtTheSeatCap() public {
        _draw(m, firstId, 20e6);
        vm.warp(block.timestamp + 156 days);
        usdc.mint(m, 20e6);
        vm.prank(m);
        usdc.approve(address(core), 20e6);

        vm.prank(m);
        uint256 before = gasleft();
        core.settle(20e6);
        uint256 used = before - gasleft();

        emit log_named_uint("settle gas at the seat cap, crossing the default", used);
        assertTrue(standing.isAccountDefaulted(m), "the default was recorded in the same call");
        assertTrue(core.obligationOf(m).closed, "and the advance was repaid");
        assertLt(used, SETTLE_GAS_CEILING);
    }
}
