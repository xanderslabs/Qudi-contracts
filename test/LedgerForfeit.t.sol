// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {Seats} from "../src/Seats.sol";
import {InviteSigner} from "./helpers/InviteSigner.sol";
import {Config} from "../src/Config.sol";
import {PauseGuard} from "../src/PauseGuard.sol";
import {ComplianceRegistry} from "../src/ComplianceRegistry.sol";
import {Community} from "../src/Community.sol";
import {CommunityFactory} from "../src/CommunityFactory.sol";
import {Ledger} from "../src/Ledger.sol";
import {Venue} from "../src/Venue.sol";
import {IConfig} from "../src/interfaces/IConfig.sol";
import {ICommunity} from "../src/interfaces/ICommunity.sol";
import {ILedger} from "../src/interfaces/ILedger.sol";
import {VenueIds} from "./helpers/VenueIds.sol";
import {ConfigKeys as K} from "../src/ConfigKeys.sol";
import {MockUSDC} from "./mocks/MockUSDC.sol";
import {MockCreditCoreLeg} from "./mocks/MockSeatSiblings.sol";
import {MockStrategy} from "./mocks/MockStrategy.sol";
import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";

/// What leaving does and does not do, over the real factory, the real
/// community, `Seats` and ledger, because `forfeit()`'s new gate is a call between two of
/// them and a stub would prove nothing about the wiring.
contract LedgerForfeitTest is InviteSigner {
    MockUSDC usdc;
    Config config;
    ComplianceRegistry registry;
    CommunityFactory factory;
    Community community;
    Ledger ledger;
    Venue[3] pools;
    MockCreditCoreLeg core;

    address owner = makeAddr("owner");
    address treasury = makeAddr("treasury");
    address host = _keyed("host");
    address ada = makeAddr("ada");
    address bea = makeAddr("bea");
    address cid = makeAddr("cid");
    address payee = makeAddr("payee");

    function setUp() public {
        usdc = new MockUSDC();
        registry = new ComplianceRegistry(address(this));
        vm.prank(owner);
        config = new Config(address(usdc), treasury, address(registry));

        // A paid seat mint routes its 40% community leg to CreditCore, so a fixture with paid
        // mints has to wire one.
        core = new MockCreditCoreLeg(IERC20(address(usdc)));
        vm.prank(owner);
        config.setAddress(K.CREDIT_CORE, address(core));
        // Every flag off: the money paths ask the guard before money moves in.
        PauseGuard pauseGuard = new PauseGuard(address(this), address(this));
        vm.prank(owner);
        config.setAddress(K.PAUSE_GUARD, address(pauseGuard));

        address communityImpl = address(new Community());
        address ledgerImpl = address(new Ledger());

        // The factory's constructor needs the three tier vaults and `Seats`, and each needs the
        // factory's address: compute it from this contract's nonce, as Deploy.s.sol does.
        address predicted = vm.computeCreateAddress(address(this), vm.getNonce(address(this)) + 4);
        address[3] memory poolAddrs;
        for (uint8 t = 0; t < 3; t++) {
            pools[t] = new Venue(usdc, IConfig(address(config)), predicted, owner, "Qudi", "q");
            poolAddrs[t] = address(pools[t]);
        }
        Seats seats = new Seats(predicted, IConfig(address(config)));
        factory = new CommunityFactory(address(config), address(seats), communityImpl, ledgerImpl, address(this));
        for (uint8 t = 0; t < 3; t++) {
            vm.prank(owner);
            Venue(poolAddrs[t]).setLabels(VenueIds.labels(t));
            factory.addVenue(poolAddrs[t]);
        }
        assertEq(address(factory), predicted, "the tier vaults are wired to this factory");

        address[4] memory people = [host, ada, bea, cid];
        for (uint256 i = 0; i < 4; i++) {
            vm.prank(people[i]);
            registry.attest(1);
            usdc.mint(people[i], 1_000_000e6);
        }

        uint256 seatPrice = 50e6;
        vm.prank(host);
        community = Community(factory.createCommunity("Test Community", seatPrice));
        ledger = Ledger(factory.ledgerOf(address(community)));

        for (uint256 i = 1; i < 4; i++) {
            vm.startPrank(people[i]);
            usdc.approve(address(community), type(uint256).max);
            usdc.approve(address(ledger), type(uint256).max);
            _invitedJoin(address(community), people[i]);
            vm.stopPrank();
        }
        vm.prank(host);
        usdc.approve(address(ledger), type(uint256).max);
    }

    /// An open personal vault in Flex, or a locked one in Term when `lockedUntil` is set.
    function _personal(address who, uint64 lockedUntil) internal returns (uint256 id) {
        vm.prank(who);
        id = ledger.createVault(
            ILedger.VaultParams({
                venueId: lockedUntil == 0 ? VenueIds.FLEX : VenueIds.TERM,
                shared: false,
                lockedUntil: lockedUntil,
                name: "personal"
            })
        );
    }

    // ---- proof 13 ----

    /// A member leaving a shared vault: the balance stays in the vault and the ex-member has no
    /// claim on it. Nothing is returned, nothing is owed, and nothing about the
    /// vault's books changes when they go.
    function test_leavingASharedVault_leavesTheBalanceBehind() public {
        vm.prank(host);
        uint256 pot = ledger.createVault(
            ILedger.VaultParams({venueId: VenueIds.FLEX, shared: true, lockedUntil: 0, name: "shared"})
        );
        vm.prank(ada);
        ledger.deposit(pot, 500e6);
        vm.prank(bea);
        ledger.deposit(pot, 200e6);

        uint256 balanceBefore = ledger.vaultValue(pot);
        uint256 adaWalletBefore = usdc.balanceOf(ada);

        vm.prank(ada);
        community.forfeit();

        assertFalse(community.isMember(ada), "ada left");
        assertEq(ledger.vaultValue(pot), balanceBefore, "the balance stayed in the vault");
        assertEq(usdc.balanceOf(ada), adaWalletBefore, "nothing came back with her");
        assertEq(ledger.vaultUnits(pot), 700e6);

        // And no claim afterwards: a shared vault only ever pays out through a proposal, and an
        // ex-member cannot even deposit into it, let alone take from it.
        vm.expectRevert(ILedger.NotMember.selector);
        vm.prank(ada);
        ledger.deposit(pot, 1e6);
        vm.expectRevert(ILedger.SharedVaultNeedsAProposal.selector);
        vm.prank(ada);
        ledger.requestWithdraw(pot, 1e6);
    }

    // ---- proof 14 ----

    /// `forfeit()` reverts while the member holds a non-zero personal vault.
    function test_forfeit_revertsWhileAPersonalVaultHoldsABalance() public {
        uint256 id = _personal(ada, 0);
        vm.prank(ada);
        ledger.deposit(id, 100e6);

        vm.expectRevert(ICommunity.VaultHoldsBalance.selector);
        vm.prank(ada);
        community.forfeit();
    }

    /// Including a locked one that has not matured: leaving requires zeroing, and a locked vault cannot be zeroed, so the lock binds
    /// the membership after all.
    function test_forfeit_revertsOnALockedPersonalVaultBeforeMaturity() public {
        uint64 maturity = uint64(block.timestamp + 90 days);
        uint256 id = _personal(ada, maturity);
        vm.prank(ada);
        ledger.deposit(id, 100e6);

        vm.expectRevert(ILedger.VaultLocked.selector);
        vm.prank(ada);
        ledger.requestWithdraw(id, 100e6);

        vm.expectRevert(ICommunity.VaultHoldsBalance.selector);
        vm.prank(ada);
        community.forfeit();

        // They wait it out, withdraw, and then they may leave. No shortcuts.
        vm.warp(maturity);
        vm.prank(ada);
        ledger.requestWithdraw(id, 100e6);
        vm.prank(ada);
        community.forfeit();
        assertFalse(community.isMember(ada));
    }

    // ---- proof 15 ----

    /// `forfeit()` succeeds once every personal vault is at zero, including across more than one
    /// of them: the gate is the whole personal position, not the last one touched.
    function test_forfeit_succeedsOnceEveryPersonalVaultIsZero() public {
        uint256 first = _personal(ada, 0);
        uint256 second = _personal(ada, 0);
        vm.startPrank(ada);
        ledger.deposit(first, 100e6);
        ledger.deposit(second, 50e6);
        ledger.requestWithdraw(first, 100e6);
        vm.stopPrank();

        vm.expectRevert(ICommunity.VaultHoldsBalance.selector);
        vm.prank(ada);
        community.forfeit();

        vm.prank(ada);
        ledger.requestWithdraw(second, 50e6);
        vm.prank(ada);
        community.forfeit();
        assertFalse(community.isMember(ada));
    }

    /// A member who never opened a personal vault is unaffected by the new gate.
    function test_forfeit_isUnchangedForAMemberHoldingNothing() public {
        vm.prank(cid);
        community.forfeit();
        assertFalse(community.isMember(cid));
    }

    /// A withdrawal leaves the vault at the request: the venue owes the member directly from
    /// then on, so a request the venue has not paid yet no longer holds the member back. If they
    /// cancel it after leaving, the money comes back to the personal vault they keep.
    function test_forfeit_aQueuedWithdrawalIsAlreadyTheMembers() public {
        vm.prank(ada);
        uint256 id = ledger.createVault(
            ILedger.VaultParams({venueId: VenueIds.CORE, shared: false, lockedUntil: 0, name: "personal"})
        );
        vm.prank(ada);
        ledger.deposit(id, 100e6);
        // Core's money goes into a strategy that gives nothing back, so the venue cannot pay yet.
        MockStrategy slow = new MockStrategy(IERC20(address(usdc)), address(pools[VenueIds.CORE]));
        address[] memory list = new address[](1);
        list[0] = address(slow);
        uint16[] memory w = new uint16[](1);
        w[0] = 10_000;
        vm.startPrank(owner);
        pools[VenueIds.CORE].addStrategy(address(slow), 0);
        pools[VenueIds.CORE].setCap(address(slow), type(uint256).max);
        pools[VenueIds.CORE].setWeights(list, w);
        vm.stopPrank();
        pools[VenueIds.CORE].rebalance();
        slow.setWithdrawCap(0);

        vm.prank(ada);
        uint256 req = ledger.requestWithdraw(id, 100e6);
        assertEq(ledger.personalUnitsOf(ada), 0);
        vm.prank(ada);
        community.forfeit();
        assertFalse(community.isMember(ada));

        vm.prank(ada);
        ledger.cancelWithdraw(req);
        assertEq(ledger.vaultUnits(id), 100e6, "a departed member keeps their personal vault");
    }

    /// The gate is additive rather than a replacement: the open-tab gate still blocks on its
    /// own, and a member with neither a tab nor a vault still leaves freely.
    function test_forfeit_vaultGateIsAdditiveToTheOpenTabGate() public {
        core.setOpenTab(bea, true);
        vm.expectRevert(ICommunity.OpenTabBlocks.selector);
        vm.prank(bea);
        community.forfeit();

        core.setOpenTab(bea, false);
        vm.prank(bea);
        community.forfeit();
        assertFalse(community.isMember(bea));
    }
}
