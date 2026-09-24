// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {Seats} from "../src/Seats.sol";
import {InviteSigner} from "./helpers/InviteSigner.sol";
import {Config} from "../src/Config.sol";
import {ComplianceRegistry} from "../src/ComplianceRegistry.sol";
import {Community} from "../src/Community.sol";
import {CommunityFactory} from "../src/CommunityFactory.sol";
import {Ledger} from "../src/Ledger.sol";
import {Venue} from "../src/Venue.sol";
import {IConfig} from "../src/interfaces/IConfig.sol";
import {ILedger} from "../src/interfaces/ILedger.sol";
import {PoolTypes} from "../src/PoolTypes.sol";
import {ConfigKeys as K} from "../src/ConfigKeys.sol";
import {MockUSDC} from "./mocks/MockUSDC.sol";
import {MockVenue} from "./mocks/MockVenue.sol";
import {MockCreditCoreLeg} from "./mocks/MockSeatSiblings.sol";
import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";

/// Every tier Qudi has deployed is open to every community,
/// with no host gate. Qudi decides which tiers exist; the host picks the tier for a shared vault
/// and the member picks it for their own. Nothing in between.
///
/// Over the real factory, because "a tier no host ever opened" is only a meaningful phrase if the
/// factory is the real one that used to require opening it.
contract LedgerNoTierGateTest is InviteSigner {
    MockUSDC usdc;
    Config config;
    ComplianceRegistry registry;
    CommunityFactory factory;
    Community community;
    Ledger ledger;
    MockCreditCoreLeg core;
    Venue[3] pools;
    MockVenue[3] venues;

    address owner = makeAddr("owner");
    address treasury = makeAddr("treasury");
    address host = _keyed("host");
    address ada = makeAddr("ada");

    function setUp() public {
        usdc = new MockUSDC();
        registry = new ComplianceRegistry(address(this));
        vm.prank(owner);
        config = new Config(address(usdc), treasury, address(registry));

        core = new MockCreditCoreLeg(IERC20(address(usdc)));
        vm.prank(owner);
        config.setAddress(K.CREDIT_CORE, address(core));

        address communityImpl = address(new Community());
        address ledgerImpl = address(new Ledger());

        address predicted = vm.computeCreateAddress(address(this), vm.getNonce(address(this)) + 4);
        address[3] memory poolAddrs;
        for (uint8 t = 0; t < 3; t++) {
            pools[t] = new Venue(usdc, IConfig(address(config)), predicted, t, owner, "Qudi", "q");
            poolAddrs[t] = address(pools[t]);
        }
        Seats seats = new Seats(predicted);
        factory = new CommunityFactory(address(config), address(seats), communityImpl, ledgerImpl, poolAddrs);
        assertEq(address(factory), predicted);

        for (uint8 t = 0; t < 3; t++) {
            venues[t] = new MockVenue(usdc, "V", "V");
            address[] memory vs = new address[](1);
            vs[0] = address(venues[t]);
            uint16[] memory bps = new uint16[](1);
            bps[0] = 10_000;
            vm.startPrank(owner);
            pools[t].addVenue(address(venues[t]));
            pools[t].setWeights(vs, bps);
            vm.stopPrank();
        }

        address[2] memory people = [host, ada];
        for (uint256 i = 0; i < 2; i++) {
            vm.prank(people[i]);
            registry.attest(1);
            usdc.mint(people[i], 1_000_000e6);
        }

        uint256 seatPrice = 50e6;
        vm.prank(host);
        community = Community(factory.createCommunity("No Gate Community", seatPrice));
        ledger = Ledger(factory.ledgerOf(address(community)));

        vm.startPrank(ada);
        usdc.approve(address(community), type(uint256).max);
        usdc.approve(address(ledger), type(uint256).max);
        _invitedJoin(address(community), ada);
        vm.stopPrank();
        vm.prank(host);
        usdc.approve(address(ledger), type(uint256).max);
    }

    /// TERM records carry a lock and every other tier does not. These
    /// tests are about the tier gate, not about locking, so the lock is supplied here rather than
    /// at each call site: the property being proved is that no tier needs opening, and that is
    /// unchanged by TERM also needing a maturity.
    function _params(uint8 poolType, bool shared) internal view returns (ILedger.VaultParams memory) {
        return ILedger.VaultParams({
            poolType: poolType,
            shared: shared,
            lockedUntil: poolType == PoolTypes.TERM ? uint64(block.timestamp + 180 days) : 0,
            contribution: 0,
            name: "vault",
            target: 0,
            targetDate: 0
        });
    }

    // ---- proof 4: a member's own vault, in a tier nobody opened ----

    /// Nothing in this fixture ever opened a tier, because there is nothing to open. A member
    /// picks the risk tier for their own savings and it works.
    function test_member_opensAPersonalVaultInAnyTier() public {
        for (uint8 t = 0; t < PoolTypes.COUNT; t++) {
            vm.prank(ada);
            uint256 id = ledger.createVault(_params(t, false));
            vm.prank(ada);
            ledger.deposit(id, 100e6);

            assertEq(ledger.vaultUnits(id), 100e6, "the deposit reached the tier");
            assertEq(ledger.tierUnits(t), 100e6);
            assertEq(ledger.tierVault(t), address(pools[t]), "wired to Qudi's own vault for that tier");
            assertEq(pools[t].balanceOf(address(ledger)), 100e6);
        }
    }

    /// The whole round trip in a tier nobody opened: deposit, then the money back out.
    function test_member_withdrawsFromAnUnopenedTier() public {
        vm.prank(ada);
        uint256 id = ledger.createVault(_params(PoolTypes.TERM, false));
        vm.prank(ada);
        ledger.deposit(id, 100e6);

        // A TERM record carries a lock, so the maturity comes first. Then the
        // whole Term flow in one place: request at maturity, and because Term's
        // withdrawal term is zero, execute in the same block. The venue had the lock to prepare.
        (,,, uint64 maturity,,,,,) = ledger.vaults(id);
        vm.warp(uint256(maturity));
        vm.prank(ada);
        uint256 req = ledger.requestWithdraw(id, 100e6);
        vm.warp(block.timestamp + config.withdrawTerm(PoolTypes.TERM));
        uint256 before = usdc.balanceOf(ada);
        vm.prank(ada);
        ledger.executeWithdraw(req);
        assertEq(usdc.balanceOf(ada) - before, 100e6);
        assertEq(ledger.vaultUnits(id), 0);
    }

    // ---- proof 5: a host's shared vault, in a tier nobody opened ----

    function test_host_opensASharedVaultInAnyTier() public {
        for (uint8 t = 0; t < PoolTypes.COUNT; t++) {
            vm.prank(host);
            uint256 id = ledger.createVault(_params(t, true));
            vm.prank(ada);
            ledger.deposit(id, 50e6);

            assertEq(ledger.vaultUnits(id), 50e6);
            // A qualifying contributor is seasoned.
            vm.warp(block.timestamp + 15 days);
            assertTrue(ledger.isDepositor(id, ada));
            assertEq(ledger.tierVault(t), address(pools[t]));
        }
    }

    /// Two communities, both reaching the same tier without either opening it, and the tier
    /// position divides between them exactly as it always did.
    function test_twoCommunitiesShareATierNeitherOpened() public {
        address other = makeAddr("otherHost");
        vm.prank(other);
        registry.attest(1);
        usdc.mint(other, 1_000_000e6);
        uint256 seatPrice = 50e6;
        vm.prank(other);
        Community community2 = Community(factory.createCommunity("Second", seatPrice));
        Ledger ledger2 = Ledger(factory.ledgerOf(address(community2)));
        vm.prank(other);
        usdc.approve(address(ledger2), type(uint256).max);

        vm.prank(ada);
        uint256 a = ledger.createVault(_params(PoolTypes.CORE, false));
        vm.prank(ada);
        ledger.deposit(a, 300e6);

        vm.prank(other);
        uint256 b = ledger2.createVault(_params(PoolTypes.CORE, false));
        vm.prank(other);
        ledger2.deposit(b, 200e6);

        assertEq(ledger.tierUnits(PoolTypes.CORE), 300e6);
        assertEq(ledger2.tierUnits(PoolTypes.CORE), 200e6);
        assertEq(pools[PoolTypes.CORE].totalSupply(), 500e6, "one tier vault, two communities in it");
    }

    // ---- proof 6: the range guard survives the gate's removal ----

    /// `poolType >= PoolTypes.COUNT` must still fail with the config's own typed error and not a
    /// raw array-bounds panic. The guard used to live in `openPool`; removing the opt-in must not
    /// remove the guard with it.
    function test_outOfRangeTierRevertsUnknownPoolType() public {
        vm.expectRevert(IConfig.UnknownPoolType.selector);
        vm.prank(ada);
        ledger.createVault(_params(PoolTypes.COUNT, false));

        vm.expectRevert(IConfig.UnknownPoolType.selector);
        vm.prank(ada);
        ledger.createVault(_params(200, false));

        vm.expectRevert(IConfig.UnknownPoolType.selector);
        vm.prank(host);
        ledger.createVault(_params(7, true));
    }

    /// The same guard on the other entry point that names a tier directly.
    function test_outOfRangeTierRevertsOnTheCreditLegToo() public {
        vm.expectRevert(IConfig.UnknownPoolType.selector);
        ledger.claimPoolLeg(PoolTypes.COUNT);
    }

    /// The view answers Qudi's deployed vault for every real tier and never panics.
    function test_tierVaultAnswersForEveryTier() public view {
        for (uint8 t = 0; t < PoolTypes.COUNT; t++) {
            assertEq(ledger.tierVault(t), address(pools[t]));
        }
    }
}
