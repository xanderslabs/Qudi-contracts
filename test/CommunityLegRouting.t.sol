// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {Seats} from "../src/Seats.sol";
import {InviteSigner} from "./helpers/InviteSigner.sol";
import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {CreditCore} from "../src/CreditCore.sol";
import {CreditStanding} from "../src/CreditStanding.sol";
import {ICreditCore} from "../src/interfaces/ICreditCore.sol";
import {IConfig} from "../src/interfaces/IConfig.sol";
import {Config} from "../src/Config.sol";
import {ConfigKeys as K} from "../src/ConfigKeys.sol";
import {ComplianceRegistry} from "../src/ComplianceRegistry.sol";
import {CommunityFactory} from "../src/CommunityFactory.sol";
import {Community} from "../src/Community.sol";
import {Ledger} from "../src/Ledger.sol";
import {MockUSDC} from "./mocks/MockUSDC.sol";

/// The legs. Each pays `CreditCore` directly with a
/// community id where each leg used to pay a per-community `NullCreditPool` clone that had no
/// path to pay anything back out.
///
/// Two communities, because "the right community id" is the whole point: a leg from one
/// community's `Community` or ledger must not land on the other's balance.
///
/// The yield leg no longer runs through the Venue, which takes no fee; its routing is proved where
/// the ledger that takes it is.
contract CommunityLegRoutingTest is InviteSigner {
    MockUSDC usdc;
    Config config;
    ComplianceRegistry registry;
    CommunityFactory factory;
    CreditStanding standing;
    CreditCore cc;

    Community communityA;
    Community communityB;
    Ledger ledgerA;
    Ledger ledgerB;

    address screener = makeAddr("screener");
    address hostA = _keyed("hostA");
    address hostB = _keyed("hostB");
    address joiner = makeAddr("joiner");
    address protocolTreasury = makeAddr("protocolTreasury");

    uint256 constant SEAT = 50e6;

    function setUp() public {
        usdc = new MockUSDC();
        registry = new ComplianceRegistry(screener);
        config = new Config(address(usdc), protocolTreasury, address(registry));

        address communityImpl = address(new Community());
        address ledgerImpl = address(new Ledger());

        // One creation sits between this nonce read and the factory: `Seats`, which takes the
        // factory address as a constructor argument.
        address predicted = vm.computeCreateAddress(address(this), vm.getNonce(address(this)) + 1);
        Seats seats = new Seats(predicted, IConfig(address(config)));
        factory = new CommunityFactory(address(config), address(seats), communityImpl, ledgerImpl, address(this));
        require(address(factory) == predicted, "factory precompute mismatch");

        standing = new CreditStanding(IConfig(address(config)), address(factory), address(this));
        cc = new CreditCore(
            IERC20(address(usdc)),
            IConfig(address(config)),
            address(factory),
            address(this),
            makeAddr("tm"),
            makeAddr("allocationMultisig"),
            standing
        );
        standing.setCreditCore(address(cc));
        config.setAddress(K.CREDIT_CORE, address(cc));

        // Community 0 and community 1. Neither opens a tier: every tier Qudi
        // deployed is available to every community and there is nothing to open.
        vm.prank(hostA);
        registry.attest(1);
        vm.prank(hostA);
        communityA = Community(factory.createCommunity("A", SEAT));
        ledgerA = Ledger(factory.ledgerOf(address(communityA)));

        vm.prank(hostB);
        registry.attest(1);
        vm.prank(hostB);
        communityB = Community(factory.createCommunity("B", SEAT));
        ledgerB = Ledger(factory.ledgerOf(address(communityB)));

        vm.warp(365 days);
    }

    function _idOf(address communityContract) internal view returns (uint256) {
        return factory.communityIdOf(communityContract) - 1;
    }

    // -----------------------------------------------------------------
    // Proof 8: the seat mint's pool share lands in CreditCore, against community 0
    // -----------------------------------------------------------------

    function test_seatMint_poolShareLandsInCreditCoreForTheRightCommunity() public {
        (uint16 hostBps, uint16 poolBps, uint16 protocolBps) = config.mintSplit();
        assertEq(uint256(hostBps) + poolBps + protocolBps, 10_000, "the split still adds to 100%");

        uint256 expectedPool = SEAT * poolBps / 10_000;
        uint256 expectedHost = SEAT * hostBps / 10_000;
        uint256 expectedProtocol = SEAT - expectedHost - expectedPool;

        usdc.mint(joiner, SEAT);
        vm.prank(joiner);
        registry.attest(1);
        vm.startPrank(joiner);
        usdc.approve(address(communityA), SEAT);
        _invitedJoin(address(communityA), joiner);
        vm.stopPrank();

        assertEq(_idOf(address(communityA)), 0, "fixture: community A is id 0");
        assertEq(cc.communityCreditOf(0).allocation, expectedPool, "the 40% leg is community 0's balance");
        assertEq(cc.communityCreditOf(1).allocation, 0, "community 1 got none of it");
        assertEq(usdc.balanceOf(hostA), expectedHost, "the host leg is unchanged");
        assertEq(usdc.balanceOf(protocolTreasury), expectedProtocol, "and so is the protocol leg");
        assertEq(expectedHost + expectedPool + expectedProtocol, SEAT, "the three legs sum to the price");
        assertEq(usdc.balanceOf(address(communityA)), 0, "the community keeps nothing");
        assertEq(cc.expectedCash(), usdc.balanceOf(address(cc)), "the booked-cash mirror matches");
    }

    /// The other community's mint tops up the other community, which is the half of "the right
    /// community id" a single-community fixture cannot show.
    function test_seatMint_secondCommunityTopsUpItsOwnBalance() public {
        (, uint16 poolBps,) = config.mintSplit();
        uint256 expectedPool = SEAT * poolBps / 10_000;

        usdc.mint(joiner, SEAT);
        vm.prank(joiner);
        registry.attest(1);
        vm.startPrank(joiner);
        usdc.approve(address(communityB), SEAT);
        _invitedJoin(address(communityB), joiner);
        vm.stopPrank();

        assertEq(_idOf(address(communityB)), 1);
        assertEq(cc.communityCreditOf(1).allocation, expectedPool);
        assertEq(cc.communityCreditOf(0).allocation, 0);
    }
}
