// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {Config} from "../src/Config.sol";
import {ComplianceRegistry} from "../src/ComplianceRegistry.sol";
import {Community} from "../src/Community.sol";
import {IConfig} from "../src/interfaces/IConfig.sol";
import {Seats} from "../src/Seats.sol";
import {ICommunity} from "../src/interfaces/ICommunity.sol";
import {ICommunityInit} from "../src/interfaces/ICommunityInit.sol";
import {ICreditCore} from "../src/interfaces/ICreditCore.sol";
import {VenueIds} from "./helpers/VenueIds.sol";
import {MockUSDC} from "./mocks/MockUSDC.sol";
import {MockVault, MockCreditPool, MockCreditCoreLeg} from "./mocks/MockSeatSiblings.sol";
import {ConfigKeys} from "../src/ConfigKeys.sol";
import {InviteSigner} from "./helpers/InviteSigner.sol";

/// Shared fixture for the community unit/fuzz suite (and CommunityVotes.t.sol via
/// inheritance): a directly-deployed Community (no clone) wired to a real `Seats` and mock
/// siblings.
contract CommunityTest is InviteSigner {
    Config config;
    ComplianceRegistry registry;
    MockUSDC usdc;
    MockVault vault;
    MockCreditPool pool;
    MockCreditCoreLeg core;
    Community community;
    Seats seats;

    /// This test contract is the community's factory (`factory: address(this)` below), so it
    /// answers the one factory read `_split` makes: the community a registered community contract
    /// belongs to, plus one. One community, id 0, so every community here is 1. It is also the
    /// factory `Seats` trusts, so it registers each community it deploys.
    function communityIdOf(address) external pure returns (uint256) {
        return 1;
    }

    /// The other factory read `forfeit()` makes: the community's ledger, whose
    /// `personalUnitsOf` is the vault gate. Zero here, which is the codebase's
    /// "unset disables the check" posture, so these suites keep testing the seat half on its own.
    /// The gate itself is proved end to end over the real factory in `test/LedgerForfeit.t.sol`.
    function ledgerOf(address) external pure returns (address) {
        return address(0);
    }

    address owner = makeAddr("owner");
    address treasury = makeAddr("treasury");
    address host = _keyed("host");
    address ada = _keyed("ada");
    address bem = _keyed("bem");

    /// A member records their own attestation before they can mint a seat.
    function _attest(address who) internal {
        vm.prank(who);
        registry.attest(1);
    }

    function setUp() public virtual {
        usdc = new MockUSDC();
        registry = new ComplianceRegistry(address(this));
        _attest(host);
        _attest(ada);
        _attest(bem);
        vm.prank(owner);
        config = new Config(address(usdc), treasury, address(registry));
        vault = new MockVault();
        pool = new MockCreditPool();
        core = new MockCreditCoreLeg(IERC20(address(usdc)));
        // The seat mint's 40% community leg pays `config.creditCore()`, and a deployment
        // with paid mints has to have one wired, so the fixture wires it.
        vm.prank(owner);
        config.setAddress(ConfigKeys.CREDIT_CORE, address(core));
        seats = new Seats(address(this), IConfig(address(config)));
        community = _fresh();

        ICommunityInit.CommunityWiring memory w = ICommunityInit.CommunityWiring({
            config: address(config),
            factory: address(this),
            seats: address(seats),
            community: address(community),
            vault: address(vault),
            creator: host,
            seatPrice: 50e6,
            name: "Test Community",
            poolType: VenueIds.CORE
        });
        community.initialize(w);
        vault.initialize(w);
        pool.initialize(w);
    }

    /// A seat votes only if it was held for the seasoning window when the
    /// vote started. A vote test calls this after its joins and before its first proposal, so
    /// every seat that exists by then is in the electorate, as it was before seasoning applied.
    function _season() internal {
        vm.warp(block.timestamp + config.memberSeasoningWindow());
    }

    /// A community registered with `Seats`, not yet initialized.
    function _fresh() internal returns (Community c) {
        c = new Community();
        seats.registerCommunity(address(c), 0);
    }

    function _join(address who) internal {
        _attest(who);
        uint256 price = community.seatPrice();
        usdc.mint(who, price);
        vm.prank(who);
        usdc.approve(address(community), price);
        _joinAs(address(community), who);
    }

    function testFuzz_mintSplitConserves(uint256 price) public {
        price = bound(price, 1, config.seatPriceCeiling());
        // Price changes now require a member vote; this fuzz test is about the split math at
        // an arbitrary price, not about the vote path, so pin the price at creation instead.
        Community freshCommunity = _fresh();
        ICommunityInit.CommunityWiring memory w = ICommunityInit.CommunityWiring({
            config: address(config),
            factory: address(this),
            seats: address(seats),
            community: address(freshCommunity),
            vault: address(vault),
            creator: host,
            seatPrice: price,
            name: "Test Community",
            poolType: VenueIds.CORE
        });
        freshCommunity.initialize(w);
        usdc.mint(ada, price);
        vm.prank(ada);
        usdc.approve(address(freshCommunity), price);
        (address inviteKey, bytes memory keySig) = _inviteFor(address(freshCommunity), ada);
        vm.expectEmit(true, false, false, false);
        emit ICommunity.SeatMinted(ada, inviteKey, 0, 0, 0, 0);
        vm.prank(ada);
        freshCommunity.join(inviteKey, keySig);
        (uint16 sBps, uint16 pBps, uint16 protBps) = config.mintSplit();
        uint256 toHost = price * sBps / 10_000;
        uint256 toPool = price * pBps / 10_000;
        // protocol takes the remainder so the three legs always sum to the price
        assertEq(usdc.balanceOf(host), toHost);
        // The community leg is `CreditCore`'s, booked against this community's community id.
        assertEq(core.legOf(0), toPool);
        assertEq(core.lastCommunityId(), 0);
        // No kind assertion here since 2026-09-21: the kind is derived inside `CreditCore` by
        // comparing the caller against the community's address, so a mock cannot know it
        // and asserting against one would only prove the mock recorded what it was handed.
        // `test_leg_kindIsDerivedFromTheCaller` proves it against the real contract.
        assertEq(usdc.balanceOf(address(core)), toPool);
        assertEq(usdc.balanceOf(treasury), price - toHost - toPool);
        assertEq(usdc.balanceOf(address(freshCommunity)), 0);
        protBps; // silence unused warning; remainder rule asserted above
    }

    /// Test 8: the 40/30/30 split lands in three destinations in one transaction,
    /// with the protocol leg taking the remainder, on a price that does not divide evenly by
    /// 10,000. The three legs sum to exactly the price; nothing is stranded in the
    /// community contract.
    function test_split_nonDividingPriceSumsToExactly() public {
        uint256 price = 33_333_333; // not a multiple of 10_000
        Community freshCommunity = _fresh();
        freshCommunity.initialize(
            ICommunityInit.CommunityWiring({
                config: address(config),
                factory: address(this),
                seats: address(seats),
                community: address(freshCommunity),
                vault: address(vault),
                creator: host,
                seatPrice: price,
                name: "Test Community",
                poolType: VenueIds.CORE
            })
        );
        address carl = makeAddr("carl");
        _attest(carl);
        usdc.mint(carl, price);
        uint256 hostBefore = usdc.balanceOf(host);
        uint256 treasuryBefore = usdc.balanceOf(treasury);
        uint256 poolBefore = core.legOf(0);
        vm.prank(carl);
        usdc.approve(address(freshCommunity), price);
        _joinAs(address(freshCommunity), carl);

        uint256 toHost = usdc.balanceOf(host) - hostBefore;
        uint256 toPool = core.legOf(0) - poolBefore;
        uint256 toProtocol = usdc.balanceOf(treasury) - treasuryBefore;
        assertEq(toHost + toPool + toProtocol, price, "legs do not sum to price");
        assertEq(usdc.balanceOf(address(freshCommunity)), 0, "dust stranded in the community");
        (uint16 hostBps, uint16 poolBps,) = config.mintSplit();
        assertEq(toHost, price * hostBps / 10_000);
        assertEq(toPool, price * poolBps / 10_000);
        // protocol is the remainder, not its own bps slice
        assertEq(toProtocol, price - (price * hostBps / 10_000) - (price * poolBps / 10_000));
    }

    // ---------------------------------------------------------------------
    // Test 10: seasoning boundary, half-open and in seconds
    // ---------------------------------------------------------------------

    function test_seasoning_halfOpenBoundary() public {
        _join(ada);
        uint64 mintTs = community.mintedAt(ada);
        assertEq(mintTs, uint64(block.timestamp));
        uint64 window = config.memberSeasoningWindow();
        assertEq(window, 14 days);

        assertFalse(community.isSeasoned(ada)); // immediately after mint

        vm.warp(mintTs + window - 1);
        assertFalse(community.isSeasoned(ada)); // 14 days - 1s

        vm.warp(mintTs + window);
        assertTrue(community.isSeasoned(ada)); // exactly 14 days

        // A non-member is never seasoned.
        assertFalse(community.isSeasoned(bem));
    }

    function test_mintSplitPaysHostWallet() public {
        address stranger = makeAddr("stranger");
        _attest(stranger);
        uint256 before = usdc.balanceOf(host);
        uint256 price = community.seatPrice();
        usdc.mint(stranger, price);
        vm.prank(stranger);
        usdc.approve(address(community), price);
        _joinAs(address(community), stranger);
        // 30% straight to the creator's wallet: no vault involvement, no cooldown.
        assertEq(usdc.balanceOf(host) - before, community.seatPrice() * 3000 / 10_000);
    }

    function test_forfeitIsTheOnlyExit() public {
        // remove() no longer exists; a member leaves only by relinquishing, and an open tab
        // blocks it.
        _join(ada);
        vm.prank(ada);
        community.forfeit();
        assertFalse(community.isMember(ada));
    }

    /// Seat-mint gates: attested AND not blocked. `ada` is attested in setUp.
    function test_seatMintGates_attestationAndBlock() public {
        address carl = makeAddr("carl");
        usdc.mint(carl, 50e6);
        vm.prank(carl);
        usdc.approve(address(community), 50e6);
        (address inviteKey, bytes memory keySig) = _inviteFor(address(community), carl);

        // Unattested: cannot mint.
        vm.prank(carl);
        vm.expectRevert(ICommunity.NotAttested.selector);
        community.join(inviteKey, keySig);

        // Attested but screener-blocked: still cannot mint.
        _attest(carl);
        registry.setBlocked(carl, true); // test contract holds the screener role
        vm.prank(carl);
        vm.expectRevert(ICommunity.AccountBlocked.selector);
        community.join(inviteKey, keySig);

        // Unblocked: mints.
        registry.setBlocked(carl, false);
        vm.prank(carl);
        community.join(inviteKey, keySig);
        assertTrue(community.isMember(carl));
    }

    function test_doubleJoinReverts() public {
        _join(ada);
        usdc.mint(ada, 50e6);
        vm.prank(ada);
        usdc.approve(address(community), 50e6);
        (address inviteKey, bytes memory keySig) = _inviteFor(address(community), ada);
        vm.prank(ada);
        vm.expectRevert(ICommunity.AlreadyMember.selector);
        community.join(inviteKey, keySig);
    }

    /// `forfeit()` moves no money. It has a gate (a member
    /// cannot leave holding a personal vault), and that is a refusal, never a transfer or a
    /// sweep. The gate itself is proved over the real ledger in `test/LedgerForfeit.t.sol`; what
    /// this pins is that the exit path touches no balance on its way out.
    function test_forfeitMovesNoMoney() public {
        _join(ada);
        vault.setBalance(ada, 200e6);
        vm.prank(ada);
        community.forfeit();
        assertFalse(community.isMember(ada));
        assertEq(vault.balances(ada), 200e6);
    }

    function test_forfeitBlockedByTab() public {
        _join(ada);
        // Forfeit's open-tab gate reads the singleton CreditCore via
        // config now, not the per-community credit pool `pool` stands in for.
        core.setOpenTab(ada, true);
        vm.prank(ada);
        vm.expectRevert(ICommunity.OpenTabBlocks.selector);
        community.forfeit();
    }

    function testFuzz_repriceProspective(uint256 newPrice) public {
        _join(ada); // ada minted at 50e6
        address carl = makeAddr("carl");
        _join(carl); // a third voter: a vote needs three yes votes
        newPrice = bound(newPrice, config.seatPriceFloor(), config.seatPriceCeiling());
        _season();
        vm.prank(host);
        community.proposeSeatPrice(newPrice);
        uint256 voteId = community.activePriceVoteId();
        vm.prank(host);
        community.castVote(voteId, true);
        vm.prank(ada);
        community.castVote(voteId, true);
        vm.prank(carl);
        community.castVote(voteId, true);
        vm.warp(block.timestamp + 7 days + 1);
        community.executeSeatPriceVote();
        assertEq(community.seatPrice(), newPrice);
        assertTrue(community.isMember(ada)); // existing seat untouched
        // next mint pays the new price:
        usdc.mint(bem, newPrice);
        vm.prank(bem);
        usdc.approve(address(community), newPrice);
        _joinAs(address(community), bem);
        assertEq(seats.seatInfo(community.tokenOf(bem)).pricePaid, newPrice, "the next seat pays the new price");
    }

    function test_repriceBelowFloorReverts() public {
        // The launch floor is 0, so the floor is raised first to have something to be below.
        vm.prank(owner);
        config.set(ConfigKeys.SEAT_PRICE_FLOOR, 10e6);
        // floor read before expectRevert: vm.expectRevert() latches onto the very next CALL,
        // and an inline config.seatPriceFloor() call as an argument would be caught instead of
        // the intended community.proposeSeatPrice() call.
        uint256 floor = config.seatPriceFloor();
        vm.prank(host);
        vm.expectRevert(ICommunity.BelowFloor.selector);
        community.proposeSeatPrice(floor - 1);
    }

    /// With no host there is nowhere to send the 30% host leg. _split() would
    /// revert on a transfer to address(0) (real USDC) and strand nothing, but joining stays
    /// shut until the community elects a replacement: vacancy is resolved by vote, not by
    /// admitting around it.
    function test_joinBlockedWhileHostVacant() public {
        // Vacate the host the only way it happens now: a passing removal vote.
        _join(ada);
        _join(bem);
        address cy = makeAddr("cy");
        _join(cy);
        _season();
        vm.prank(ada);
        community.proposeRemoveHost();
        uint256 voteId = community.activeHostVoteId();
        vm.prank(ada);
        community.castVote(voteId, true);
        vm.prank(bem);
        community.castVote(voteId, true);
        vm.prank(cy);
        community.castVote(voteId, true);
        vm.warp(block.timestamp + 7 days + 1);
        community.executeRemoveHost();
        assertTrue(community.hostVacant());

        // With no host there is nobody to make an invite; the vacancy refuses first.
        address dara = makeAddr("dara");
        usdc.mint(dara, 50e6);
        vm.prank(dara);
        usdc.approve(address(community), 50e6);
        vm.prank(dara);
        vm.expectRevert(ICommunity.HostVacant.selector);
        community.join(address(0), "");

        assertFalse(community.isMember(dara));
    }

    function test_onlyHostAdmin() public {
        vm.startPrank(ada);
        vm.expectRevert(ICommunity.NotHost.selector);
        community.proposeSeatPrice(60e6);
        vm.stopPrank();
    }
}

// `SeatsOpenPoolTest` lived here and is deleted, not moved. Both its bounds were the host tier
// opt-in, which is removed: a host opening a tier, and a member being refused.
// There is nothing to open now, and the statement that replaces it, that any member reaches any
// tier without the host, is proved in `test/LedgerNoTierGate.t.sol`.
