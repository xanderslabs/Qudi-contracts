// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {Config} from "../src/Config.sol";
import {ComplianceRegistry} from "../src/ComplianceRegistry.sol";
import {Community} from "../src/Community.sol";
import {CommunityFactory} from "../src/CommunityFactory.sol";
import {Ledger} from "../src/Ledger.sol";
import {Venue} from "../src/Venue.sol";
import {IConfig} from "../src/interfaces/IConfig.sol";
import {ICommunity} from "../src/interfaces/ICommunity.sol";
import {ILedger} from "../src/interfaces/ILedger.sol";
import {PoolTypes} from "../src/PoolTypes.sol";
import {ConfigKeys as K} from "../src/ConfigKeys.sol";
import {MockUSDC} from "./mocks/MockUSDC.sol";
import {MockCreditCoreLeg} from "./mocks/MockSeatSiblings.sol";
import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";

/// What leaving does and does not do, over the real factory, the real
/// seats contract and the real ledger, because `forfeit()`'s new gate is a call between two of
/// them and a stub would prove nothing about the wiring.
contract LedgerForfeitTest is Test {
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
    address host = makeAddr("host");
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

        address seatsImpl = address(new Community());
        address ledgerImpl = address(new Ledger());

        // The factory's constructor needs the three tier vaults, and each needs the factory's
        // address: compute it from this contract's nonce, as Deploy.s.sol does.
        address predicted = vm.computeCreateAddress(address(this), vm.getNonce(address(this)) + 3);
        address[3] memory poolAddrs;
        for (uint8 t = 0; t < 3; t++) {
            pools[t] = new Venue(usdc, IConfig(address(config)), predicted, t, owner, "Qudi", "q");
            poolAddrs[t] = address(pools[t]);
        }
        factory = new CommunityFactory(address(config), seatsImpl, ledgerImpl, poolAddrs);
        assertEq(address(factory), predicted, "the tier vaults are wired to this factory");

        address[4] memory people = [host, ada, bea, cid];
        for (uint256 i = 0; i < 4; i++) {
            vm.prank(people[i]);
            registry.attest(1);
            usdc.mint(people[i], 1_000_000e6);
        }

        // Read the floor before the prank: an argument that is itself a call would consume it.
        uint256 seatPrice = config.seatPriceFloor();
        vm.prank(host);
        community = Community(factory.createCommunity("Test Community", seatPrice));
        ledger = Ledger(factory.ledgerOf(address(community)));

        for (uint256 i = 1; i < 4; i++) {
            vm.startPrank(people[i]);
            usdc.approve(address(community), type(uint256).max);
            usdc.approve(address(ledger), type(uint256).max);
            community.join();
            vm.stopPrank();
        }
        vm.prank(host);
        usdc.approve(address(ledger), type(uint256).max);
    }

    function _personal(address who, uint64 lockedUntil) internal returns (uint256 id) {
        vm.prank(who);
        id = ledger.createVault(
            ILedger.VaultParams({
                poolType: PoolTypes.FLEX,
                shared: false,
                lockedUntil: lockedUntil,
                contribution: 0,
                name: "personal",
                target: 0,
                targetDate: 0
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
            ILedger.VaultParams({
                poolType: PoolTypes.FLEX,
                shared: true,
                lockedUntil: 0,
                contribution: 0,
                name: "shared",
                target: 0,
                targetDate: 0
            })
        );
        vm.prank(ada);
        ledger.deposit(pot, 500e6);
        vm.prank(bea);
        ledger.deposit(pot, 200e6);

        uint256 balanceBefore = ledger.vaultBalance(pot);
        uint256 adaWalletBefore = usdc.balanceOf(ada);

        vm.prank(ada);
        community.forfeit();

        assertFalse(community.isMember(ada), "ada left");
        assertEq(ledger.vaultBalance(pot), balanceBefore, "the balance stayed in the vault");
        assertEq(usdc.balanceOf(ada), adaWalletBefore, "nothing came back with her");
        assertEq(ledger.vaultUnits(pot), 700e6);

        // And no claim afterwards: a shared vault only ever pays out through a proposal, and an
        // ex-member cannot even deposit into it, let alone take from it.
        vm.expectRevert(ILedger.NotMember.selector);
        vm.prank(ada);
        ledger.deposit(pot, 1e6);
        vm.expectRevert(ILedger.SharedVaultNeedsAProposal.selector);
        vm.prank(ada);
        ledger.withdrawInstant(pot, 1e6);
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
        ledger.withdrawInstant(id, 100e6);

        vm.expectRevert(ICommunity.VaultHoldsBalance.selector);
        vm.prank(ada);
        community.forfeit();

        // They wait it out, withdraw, and then they may leave. No shortcuts.
        vm.warp(maturity);
        vm.prank(ada);
        ledger.withdrawInstant(id, 100e6);
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
        ledger.withdrawInstant(first, 100e6);
        vm.stopPrank();

        vm.expectRevert(ICommunity.VaultHoldsBalance.selector);
        vm.prank(ada);
        community.forfeit();

        vm.prank(ada);
        ledger.withdrawInstant(second, 50e6);
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

    /// Units frozen in a pending withdrawal request still count as held: the money has not left
    /// the community yet, so neither may the member.
    function test_forfeit_countsUnitsFrozenInAPendingRequest() public {
        vm.prank(ada);
        uint256 id = ledger.createVault(
            ILedger.VaultParams({
                poolType: PoolTypes.CORE,
                shared: false,
                lockedUntil: 0,
                contribution: 0,
                name: "personal",
                target: 0,
                targetDate: 0
            })
        );
        vm.startPrank(ada);
        ledger.deposit(id, 100e6);
        uint256 req = ledger.requestWithdraw(id, 100e6);
        vm.stopPrank();

        vm.expectRevert(ICommunity.VaultHoldsBalance.selector);
        vm.prank(ada);
        community.forfeit();

        vm.warp(block.timestamp + config.withdrawTerm(PoolTypes.CORE));
        vm.prank(ada);
        ledger.executeWithdraw(req);
        vm.prank(ada);
        community.forfeit();
        assertFalse(community.isMember(ada));
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
