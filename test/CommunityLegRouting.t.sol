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
import {ILedger} from "../src/interfaces/ILedger.sol";
import {Venue} from "../src/Venue.sol";
import {PoolTypes} from "../src/PoolTypes.sol";
import {MockUSDC} from "./mocks/MockUSDC.sol";
import {MockVenue} from "./mocks/MockVenue.sol";

/// The legs. Each pays `CreditCore` directly with a
/// community id where each leg used to pay a per-community `NullCreditPool` clone that had no
/// path to pay anything back out.
///
/// Two communities, because "the right community id" is the whole point: a leg from one
/// community's `Community` or ledger must not land on the other's balance.
///
/// The Term interest leg, once counted as a third, pays through the same
/// `Ledger.claimPoolLeg` path as every other tier since `LockedVault` was deleted, so the
/// ledger proof covers it.
contract CommunityLegRoutingTest is InviteSigner {
    MockUSDC usdc;
    Config config;
    ComplianceRegistry registry;
    CommunityFactory factory;
    CreditStanding standing;
    CreditCore cc;
    Venue flexVault;
    MockVenue venue;

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
    uint256 constant STAKE = 100_000e6;
    uint256 constant GAIN = 10_000e6;

    function setUp() public {
        usdc = new MockUSDC();
        registry = new ComplianceRegistry(screener);
        config = new Config(address(usdc), protocolTreasury, address(registry));

        address communityImpl = address(new Community());
        address ledgerImpl = address(new Ledger());

        // Two creations sit between this nonce read and the factory: the FLEX vault, which takes
        // the factory address as a constructor argument, and `Seats`, which takes it too.
        address predicted = vm.computeCreateAddress(address(this), vm.getNonce(address(this)) + 2);
        flexVault = new Venue(
            IERC20(address(usdc)), IConfig(address(config)), predicted, PoolTypes.FLEX, address(this), "F", "F"
        );
        address[3] memory pools;
        pools[PoolTypes.FLEX] = address(flexVault);
        pools[PoolTypes.CORE] = makeAddr("pool1");
        pools[PoolTypes.TERM] = makeAddr("poolTerm");
        Seats seats = new Seats(predicted);
        factory = new CommunityFactory(address(config), address(seats), communityImpl, ledgerImpl, pools);
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

        venue = new MockVenue(usdc, "Venue", "V");
        flexVault.addVenue(address(venue));
        address[] memory vs = new address[](1);
        vs[0] = address(venue);
        uint16[] memory w = new uint16[](1);
        w[0] = 10_000;
        flexVault.setWeights(vs, w);

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

        usdc.mint(address(this), 1_000_000e6);
        usdc.approve(address(venue), type(uint256).max);
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

    // -----------------------------------------------------------------
    // Proof 9: the vault yield leg lands in CreditCore, against the right community id
    // -----------------------------------------------------------------

    function test_yieldLeg_landsInCreditCoreForTheRightCommunity() public {
        _seatAndContribute(communityA, ledgerA, STAKE);
        flexVault.rebalance();
        venue.fund(GAIN);
        vm.roll(block.number + 1);
        flexVault.harvest(address(venue));

        (, uint16 poolBps,) = config.yieldSplit();
        uint256 expectedLeg = GAIN * poolBps / 10_000;

        // The seat mint in `_seatAndContribute` already paid its own leg, so measure the delta.
        uint256 before0 = cc.communityCreditOf(0).allocation;
        uint256 claimed = ledgerA.claimPoolLeg(PoolTypes.FLEX);
        assertGt(claimed, 0, "the ledger claimed a leg");
        assertApproxEqAbs(claimed, expectedLeg, 2, "and it is the 15% pool leg");

        assertEq(_idOf(address(ledgerA)), 0, "the ledger resolves to its own community");
        assertEq(cc.communityCreditOf(0).allocation - before0, claimed, "which is the balance that rose");
        assertEq(cc.communityCreditOf(1).allocation, 0, "the other community got none of it");
        assertEq(cc.expectedCash(), usdc.balanceOf(address(cc)), "the booked-cash mirror matches");
    }

    /// Two ledgers in the same vault, one per community: each claim credits its own community.
    function test_yieldLeg_twoCommunitiesInOneVaultAreNotCrossed() public {
        _seatAndContribute(communityA, ledgerA, STAKE);
        _seatAndContribute(communityB, ledgerB, STAKE);
        flexVault.rebalance();
        venue.fund(GAIN);
        vm.roll(block.number + 1);
        flexVault.harvest(address(venue));

        uint256 before0 = cc.communityCreditOf(0).allocation;
        uint256 before1 = cc.communityCreditOf(1).allocation;
        uint256 legA = ledgerA.claimPoolLeg(PoolTypes.FLEX);
        uint256 legB = ledgerB.claimPoolLeg(PoolTypes.FLEX);
        assertGt(legA, 0);
        assertGt(legB, 0);
        assertEq(cc.communityCreditOf(0).allocation - before0, legA);
        assertEq(cc.communityCreditOf(1).allocation - before1, legB);
    }

    /// Anyone may call `claimPoolLeg` (the shares go to the community either way), and the leg
    /// still lands on the calling ledger's community, not the caller's.
    function test_yieldLeg_claimableByAnyoneAndStillRoutedByLedger() public {
        _seatAndContribute(communityA, ledgerA, STAKE);
        flexVault.rebalance();
        venue.fund(GAIN);
        vm.roll(block.number + 1);
        flexVault.harvest(address(venue));

        uint256 before0 = cc.communityCreditOf(0).allocation;
        vm.prank(makeAddr("passerby"));
        uint256 claimed = ledgerA.claimPoolLeg(PoolTypes.FLEX);
        assertGt(claimed, 0);
        assertEq(cc.communityCreditOf(0).allocation - before0, claimed);
    }

    function _seatAndContribute(Community community, Ledger ledger, uint256 amount) internal {
        address m = address(uint160(uint256(keccak256(abi.encode(address(community), "member")))));
        usdc.mint(m, SEAT + amount);
        vm.startPrank(m);
        registry.attest(1);
        usdc.approve(address(community), SEAT);
        _invitedJoin(address(community), m);
        usdc.approve(address(ledger), amount);
        uint256 vaultId = ledger.createVault(
            ILedger.VaultParams({
                poolType: PoolTypes.FLEX,
                shared: false,
                lockedUntil: 0,
                contribution: 0,
                name: "savings",
                target: 0,
                targetDate: 0
            })
        );
        ledger.deposit(vaultId, amount);
        vm.stopPrank();
    }
}
