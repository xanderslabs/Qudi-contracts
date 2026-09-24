// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {Venue} from "../../src/Venue.sol";
import {IVenue} from "../../src/interfaces/IVenue.sol";
import {Config} from "../../src/Config.sol";
import {IConfig} from "../../src/interfaces/IConfig.sol";
import {ComplianceRegistry} from "../../src/ComplianceRegistry.sol";
import {MockUSDC} from "../mocks/MockUSDC.sol";
import {MockStrategy} from "../mocks/MockStrategy.sol";

/// A stand-in factory: answers `isCommunityContract` for addresses a test registers.
contract VenueFactoryStub {
    mapping(address => bool) public isCommunityContract;

    function register(address a) external {
        isCommunityContract[a] = true;
    }
}

/// One Venue over `MockStrategy`s, with a registered ledger that holds USDC and has approved the
/// Venue. `maxRateBps` starts at 1,000 (10% a year), so a test that wants to see growth can.
abstract contract VenueFixture is Test {
    MockUSDC usdc;
    Config config;
    VenueFactoryStub factory;
    Venue vault;

    address owner = address(0xA11CE);
    address treasury = address(0x7EA);
    address ledger = address(0x1ED);
    address stranger = address(0xBAD);

    uint16 constant MAX_RATE_BPS = 1000;

    function setUpVenue() internal {
        usdc = new MockUSDC();
        address screener = address(new ComplianceRegistry(address(this)));
        vm.prank(owner); // Config takes its owner from msg.sender
        config = new Config(address(usdc), treasury, screener);
        factory = new VenueFactoryStub();
        factory.register(ledger);
        vault = new Venue(usdc, IConfig(address(config)), address(factory), owner, "Qudi Core", "qCORE");
        _setMaxRate(MAX_RATE_BPS);
        usdc.mint(ledger, 1_000_000e6);
        vm.prank(ledger);
        usdc.approve(address(vault), type(uint256).max);
        usdc.mint(address(this), 1_000_000e6);
    }

    function _labels(uint16 maxRateBps) internal pure returns (IVenue.Labels memory) {
        return IVenue.Labels({
            name: "Core",
            kind: IVenue.Kind.Open,
            riskKey: 3,
            estReturnBps: 350,
            exitSeconds: 1 days,
            maxRateBps: maxRateBps
        });
    }

    function _setMaxRate(uint16 maxRateBps) internal {
        vm.prank(owner);
        vault.setLabels(_labels(maxRateBps));
    }

    /// Lists a fresh `MockStrategy` with `delay`, a cap large enough never to bind, and `weight`.
    /// Weights are rewritten from scratch by `setWeights`, so a test listing two strategies passes
    /// both through `_weigh` afterwards.
    function _addStrategy(uint64 delay) internal returns (MockStrategy s) {
        s = new MockStrategy(usdc, address(vault));
        vm.startPrank(owner);
        vault.addStrategy(address(s), delay);
        vault.setCap(address(s), type(uint256).max);
        vm.stopPrank();
        usdc.approve(address(s), type(uint256).max);
    }

    function _weigh(address a, uint16 wa, address b, uint16 wb) internal {
        address[] memory vs = new address[](b == address(0) ? 1 : 2);
        uint16[] memory w = new uint16[](vs.length);
        vs[0] = a;
        w[0] = wa;
        if (b != address(0)) {
            vs[1] = b;
            w[1] = wb;
        }
        vm.prank(owner);
        vault.setWeights(vs, w);
    }

    function _deposit(uint256 assets) internal returns (uint256 shares) {
        vm.prank(ledger);
        shares = vault.deposit(assets, ledger);
    }

    /// Assets per 1e6 shares: the share price in USDC units.
    function _price() internal view returns (uint256) {
        return vault.convertToAssets(1e6);
    }
}
