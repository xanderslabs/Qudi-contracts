// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {Venue} from "../../src/Venue.sol";
import {ManualStrategy} from "../../src/ManualStrategy.sol";
import {Config} from "../../src/Config.sol";
import {IConfig} from "../../src/interfaces/IConfig.sol";
import {IVenue} from "../../src/interfaces/IVenue.sol";
import {ComplianceRegistry} from "../../src/ComplianceRegistry.sol";
import {MockUSDC} from "../mocks/MockUSDC.sol";
import {MockStrategy} from "../mocks/MockStrategy.sol";
import {VenueFactoryStub} from "../helpers/VenueFixture.sol";

/// Drives one Venue over a `ManualStrategy` and a slow `MockStrategy` through every money path:
/// deposits, instant withdrawals, queued requests and their processing, losses, released yield,
/// and the operator sending money out and bringing it back.
contract VenueHandler is Test {
    Venue public vault;
    ManualStrategy public ms;
    MockStrategy public slow;
    MockUSDC public usdc;
    address public operator;
    address public dest = address(0xDE57);
    address[2] public ledgers;

    /// Shares sitting in the queue, as the handler counts them.
    uint256 public ghostQueued;

    constructor(Venue v, ManualStrategy m, MockStrategy s, MockUSDC u, address op, address l0, address l1) {
        vault = v;
        ms = m;
        slow = s;
        usdc = u;
        operator = op;
        ledgers = [l0, l1];
        usdc.approve(address(slow), type(uint256).max);
    }

    function _ledger(uint256 seed) internal view returns (address) {
        return ledgers[seed % 2];
    }

    function deposit(uint256 seed, uint256 assets) external {
        assets = bound(assets, 1e6, 100_000e6);
        address l = _ledger(seed);
        usdc.mint(l, assets);
        vm.startPrank(l);
        usdc.approve(address(vault), assets);
        try vault.deposit(assets, l) {} catch {}
        vm.stopPrank();
    }

    function withdraw(uint256 seed, uint256 assets) external {
        address l = _ledger(seed);
        uint256 max = vault.maxWithdraw(l);
        if (max == 0) return;
        assets = bound(assets, 1, max);
        vm.prank(l);
        vault.withdraw(assets, l, l);
    }

    function requestRedeem(uint256 seed, uint256 shares) external {
        address l = _ledger(seed);
        uint256 bal = vault.balanceOf(l);
        if (bal == 0) return;
        shares = bound(shares, 1, bal);
        vm.prank(l);
        vault.requestRedeem(shares, l);
        ghostQueued += shares;
    }

    function processQueue(uint256 steps) external {
        uint256 before = vault.balanceOf(address(vault));
        vault.processQueue(bound(steps, 1, 5));
        ghostQueued -= before - vault.balanceOf(address(vault));
    }

    function rebalance() external {
        vault.rebalance();
    }

    function accrue() external {
        vault.accrue();
    }

    function warp(uint256 secs) external {
        vm.warp(block.timestamp + bound(secs, 1, 30 days));
    }

    /// A slow strategy that loses value.
    function loseSlow(uint256 amount) external {
        uint256 have = slow.totalAssets();
        if (have == 0) return;
        slow.skim(bound(amount, 1, have));
    }

    /// A slow strategy that gains value, which the cap then paces.
    function gainSlow(uint256 amount) external {
        amount = bound(amount, 1, 10_000e6);
        usdc.mint(address(this), amount);
        slow.fund(amount);
    }

    function fundYield(uint256 amount, uint16 rate) external {
        amount = bound(amount, 1, 10_000e6);
        usdc.mint(operator, amount);
        vm.startPrank(operator);
        usdc.approve(address(ms), amount);
        ms.fundYield(amount);
        ms.setRate(uint16(bound(rate, 0, 2000)));
        vm.stopPrank();
    }

    function deploy(uint256 amount) external {
        uint256 held = ms.principalHeld();
        if (held == 0) return;
        vm.prank(operator);
        ms.deploy(bound(amount, 1, held), dest, bytes32(0));
    }

    /// Money coming back, sometimes more than went out: the excess is yield for the buffer.
    function returnFrom(uint256 amount) external {
        amount = bound(amount, 1, ms.principalDeployed() + 1_000e6);
        usdc.mint(operator, amount);
        vm.startPrank(operator);
        usdc.approve(address(ms), amount);
        ms.returnFrom(amount);
        vm.stopPrank();
    }

    function reportLoss(uint256 amount) external {
        uint256 out = ms.principalDeployed();
        if (out == 0) return;
        vm.prank(operator);
        ms.reportLoss(bound(amount, 1, out), "loss");
    }
}

contract VenueInvariantsTest is Test {
    VenueHandler handler;
    Venue vault;
    ManualStrategy ms;
    MockStrategy slow;
    MockUSDC usdc;
    address owner = address(0xA11CE);
    address operator = address(0x0FE);
    address l0 = address(0x1ED);
    address l1 = address(0x2ED);

    function setUp() public {
        usdc = new MockUSDC();
        vm.prank(owner);
        Config config = new Config(address(usdc), address(0x7EA), address(new ComplianceRegistry(address(this))));
        VenueFactoryStub factory = new VenueFactoryStub();
        factory.register(l0);
        factory.register(l1);
        vault = new Venue(usdc, IConfig(address(config)), address(factory), owner, "Qudi Core", "qCORE");
        ms = new ManualStrategy(usdc, IConfig(address(config)), address(vault), owner, operator);
        slow = new MockStrategy(usdc, address(vault));

        vm.startPrank(owner);
        vault.setLabels(
            IVenue.Labels({
                name: "Core",
                kind: IVenue.Kind.Open,
                riskKey: 3,
                estReturnBps: 350,
                exitSeconds: 1 days,
                maxRateBps: 520
            })
        );
        vault.addStrategy(address(ms), 0);
        vault.addStrategy(address(slow), 1 days);
        vault.setCap(address(ms), type(uint256).max);
        vault.setCap(address(slow), type(uint256).max);
        address[] memory vs = new address[](2);
        vs[0] = address(ms);
        vs[1] = address(slow);
        uint16[] memory w = new uint16[](2);
        w[0] = 7000;
        w[1] = 2500;
        vault.setWeights(vs, w);
        ms.addDestination(address(0xDE57));
        vm.stopPrank();

        handler = new VenueHandler(vault, ms, slow, usdc, operator, l0, l1);
        targetContract(address(handler));
    }

    /// 14. The Venue never reports more than it holds: idle plus what every strategy says its
    /// position is worth.
    function invariant_totalAssetsNeverExceedsWhatTheVenueHolds() public view {
        uint256 held = vault.idle() + ms.totalAssets() + slow.totalAssets();
        assertLe(vault.totalAssets(), held);
        assertEq(vault.realAssets(), held);
    }

    /// Every share the Venue itself holds is either reserve or locked in the queue.
    function invariant_theVenuesOwnSharesAreReserveOrQueued() public view {
        assertEq(vault.balanceOf(address(vault)), vault.reserveShares() + handler.ghostQueued());
    }

    /// Shares sit only with registered ledgers and the Venue itself.
    function invariant_sharesOnlyAtPermittedHolders() public view {
        assertEq(vault.totalSupply(), vault.balanceOf(l0) + vault.balanceOf(l1) + vault.balanceOf(address(vault)));
    }

    /// Money a receiver could not take is still in the Venue's balance, outside its value.
    function invariant_heldPayoutsAreCovered() public view {
        assertGe(usdc.balanceOf(address(vault)), vault.totalHeld());
    }
}
