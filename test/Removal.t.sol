// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {Seats} from "../src/Seats.sol";
import {InviteSigner} from "./helpers/InviteSigner.sol";
import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {Config} from "../src/Config.sol";
import {ComplianceRegistry} from "../src/ComplianceRegistry.sol";
import {Community} from "../src/Community.sol";
import {CommunityFactory} from "../src/CommunityFactory.sol";
import {Ledger} from "../src/Ledger.sol";
import {Venue} from "../src/Venue.sol";
import {IConfig} from "../src/interfaces/IConfig.sol";
import {ICommunity} from "../src/interfaces/ICommunity.sol";
import {ILedger} from "../src/interfaces/ILedger.sol";
import {ICreditCore} from "../src/interfaces/ICreditCore.sol";
import {PoolTypes} from "../src/PoolTypes.sol";
import {ConfigKeys as K} from "../src/ConfigKeys.sol";
import {MockUSDC} from "./mocks/MockUSDC.sol";
import {CreditCoreHarness} from "./helpers/CreditCoreHarness.sol";
import {CreditStandingHarness} from "./helpers/CreditStandingHarness.sol";

/// Reads the account's credit figures on both sides of one call, inside one transaction. Proof
/// 10 needs this: a test body that reads the cap after a removal only shows the cap is right by
/// the end of the test, and the rule is that it is right in the transaction that
/// changes the seat. It also stands in as a member when the member's own call is the change.
contract SameTxProbe {
    function exec(address target, bytes calldata data) external returns (bytes memory r) {
        bool ok;
        (ok, r) = target.call(data);
        if (!ok) {
            assembly {
                revert(add(r, 32), mload(r))
            }
        }
    }

    function capAround(address target, bytes calldata data, CreditStandingHarness s, address m)
        external
        returns (uint256 capBefore, uint256 capAfter, uint256 totalAfter)
    {
        capBefore = s.accountExposureCap(0, m);
        (bool ok, bytes memory r) = target.call(data);
        if (!ok) {
            assembly {
                revert(add(r, 32), mload(r))
            }
        }
        capAfter = s.accountExposureCap(0, m);
        totalAfter = s.accountImpactTotal(m);
    }
}

/// The host proposes a removal, the members vote, the proposal freezes the member, and a seat is
/// never burned. These are eleven proofs, over the real factory, `Seats`, community, ledger,
/// `CreditCore` and `CreditStanding`, because every one of them is a call between two of those
/// contracts and a stub would prove nothing about the wiring.
///
/// The fixture's five members all hold seats older than the seasoning window before any vote
/// starts, so the community threshold is 3 of 5 and the target is one of the 5.
contract RemovalTest is InviteSigner {
    MockUSDC usdc;
    Config config;
    ComplianceRegistry registry;
    CommunityFactory factory;
    Community community;
    Ledger ledger;
    CreditStandingHarness standing;
    CreditCoreHarness cc;

    address governance = makeAddr("governance");
    address treasuryMgr = makeAddr("treasuryManager");
    address allocationMs = makeAddr("allocationMultisig");
    address treasury = makeAddr("treasury");
    address host = _keyed("host");
    address ada = makeAddr("ada");
    address bea = makeAddr("bea");
    address cid = makeAddr("cid");
    address dee = makeAddr("dee");

    bytes32 constant AGREEMENT = keccak256("qudi credit agreement v1");
    uint8 constant ACTIVE = 1;
    uint8 constant SUSPENDED = 2;
    uint8 constant LEFT = 3;

    function setUp() public {
        vm.warp(1000 days);
        usdc = new MockUSDC();
        registry = new ComplianceRegistry(address(this));
        config = new Config(address(usdc), treasury, address(registry));

        address communityImpl = address(new Community());
        address ledgerImpl = address(new Ledger());
        address predicted = vm.computeCreateAddress(address(this), vm.getNonce(address(this)) + 4);
        address[3] memory poolAddrs;
        for (uint8 t = 0; t < 3; t++) {
            poolAddrs[t] = address(new Venue(usdc, IConfig(address(config)), predicted, t, governance, "Qudi", "q"));
        }
        Seats seats = new Seats(predicted);
        factory = new CommunityFactory(address(config), address(seats), communityImpl, ledgerImpl, poolAddrs);
        assertEq(address(factory), predicted, "the tier vaults are wired to this factory");

        standing = new CreditStandingHarness(IConfig(address(config)), address(factory), governance);
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
        config.setAddress(K.CREDIT_CORE, address(cc));

        usdc.mint(governance, 300_000e6);
        vm.startPrank(governance);
        usdc.approve(address(cc), 300_000e6);
        cc.fund(300_000e6);
        vm.stopPrank();

        address[5] memory people = [host, ada, bea, cid, dee];
        for (uint256 i = 0; i < 5; i++) {
            vm.prank(people[i]);
            registry.attest(1);
            usdc.mint(people[i], 1_000_000e6);
        }
        uint256 price = 50e6;
        vm.prank(host);
        community = Community(factory.createCommunity("Removal Community", price));
        ledger = Ledger(factory.ledgerOf(address(community)));
        for (uint256 i = 0; i < 5; i++) {
            vm.startPrank(people[i]);
            usdc.approve(address(community), type(uint256).max);
            usdc.approve(address(ledger), type(uint256).max);
            usdc.approve(address(cc), type(uint256).max);
            if (people[i] != host) _invitedJoin(address(community), people[i]);
            vm.stopPrank();
        }
        vm.prank(allocationMs);
        cc.allocate(0, 5000e6, ICreditCore.AllocationType.Growth);

        vm.warp(block.timestamp + config.memberSeasoningWindow() + 1 days);
    }

    // ---- adapter: begin ----
    // Every call to an API these proofs add lives here, so the proofs below can be run against the
    // base with this block swapped for the base's nearest equivalent. Nothing outside it names a function or error the base does not have.

    bytes4 internal E_COOLDOWN = ICommunity.RemovalCooldown.selector;
    bytes4 internal E_FROZEN = ICommunity.MemberFrozen.selector;

    function _propose(address by, address m) internal {
        vm.prank(by);
        community.proposeRemoval(m);
    }

    function _voteId(address m) internal view returns (uint256) {
        return community.activeRemovalVoteId(m);
    }

    function _executeCall(address m) internal pure returns (bytes memory) {
        return abi.encodeCall(ICommunity.executeRemoval, (m));
    }

    function _state(address m) internal view returns (uint8) {
        return uint8(community.seatStateOf(m));
    }

    function _cooldown() internal view returns (uint256) {
        return config.removalReproposeCooldown();
    }
    // ---- adapter: end ----

    // ---- helpers ----

    function _execute(address m) internal {
        (bool ok, bytes memory r) = address(community).call(_executeCall(m));
        if (!ok) {
            assembly {
                revert(add(r, 32), mload(r))
            }
        }
    }

    function _window() internal view returns (uint64 window) {
        (, window) = config.communityVote();
    }

    function _yes(uint256 voteId, address who) internal {
        vm.prank(who);
        community.castVote(voteId, true);
    }

    /// The host proposes removing `m` and three of the five vote for it.
    function _proposeAndCarry(address m) internal returns (uint256 voteId) {
        _propose(host, m);
        voteId = _voteId(m);
        address[4] memory others = [host, bea, cid, dee];
        uint256 cast;
        for (uint256 i; i < 4 && cast < 3; i++) {
            if (others[i] == m) continue;
            _yes(voteId, others[i]);
            cast++;
        }
    }

    function _remove(address m) internal {
        _proposeAndCarry(m);
        vm.warp(block.timestamp + _window() + 1);
        _execute(m);
    }

    /// Proposed at the returned deadline minus the window, voted on by nobody, and left alone.
    function _proposeAndLetFail(address m) internal returns (uint256 deadline) {
        _propose(host, m);
        deadline = block.timestamp + _window();
        vm.warp(deadline + 1);
    }

    function _personal(address who) internal returns (uint256 id) {
        vm.prank(who);
        id = ledger.createVault(
            ILedger.VaultParams({
                poolType: PoolTypes.FLEX,
                shared: false,
                lockedUntil: 0,
                contribution: 0,
                name: "personal",
                target: 0,
                targetDate: 0
            })
        );
    }

    function _shared() internal returns (uint256 id) {
        vm.prank(host);
        id = ledger.createVault(
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
    }

    function _draw(address who, uint256 amount) internal {
        vm.prank(who);
        cc.draw(0, amount, AGREEMENT);
    }

    function _settle(address who, uint256 amount) internal {
        vm.prank(who);
        cc.settle(amount);
    }

    /// Seasoned impact enough for a first draw at MIN_LENDABLE.
    function _primeEligible(address who) internal {
        standing.primeImpact(0, who, 500e6, 1000e6);
    }

    // =============================================================================
    // Proof 1: only the host proposes
    // =============================================================================

    function test_proof1_aMemberWhoIsNotTheHostCannotProposeARemoval() public {
        vm.expectRevert(ICommunity.NotSteward.selector);
        _propose(bea, ada);
        assertEq(_voteId(ada), 0, "no vote exists and nobody is frozen");
        assertTrue(community.isMember(ada));

        _propose(host, ada);
        assertTrue(_voteId(ada) != 0, "the host can");
    }

    // =============================================================================
    // Proof 2: the proposal freezes the member to exit-only
    // =============================================================================

    /// Everything that puts something in, decides something, or leaves is refused from the
    /// moment the host proposes, one test per power so each is pinned on its own. The member
    /// holds nothing and owes nothing here, so each refusal is the freeze and nothing else.
    function _freezeAda() internal {
        _primeEligible(ada);
        _propose(host, ada);
        assertFalse(community.isMember(ada), "frozen is not a member");
        assertEq(_state(ada), ACTIVE, "but the seat is still Active: nothing is decided yet");
    }

    function test_proof2_aFrozenMemberCannotDraw() public {
        _freezeAda();
        vm.expectRevert(ICreditCore.NotAMember.selector);
        _draw(ada, 50e6);
    }

    function test_proof2_aFrozenMemberCannotDepositIntoASharedVault() public {
        uint256 pot = _shared();
        _freezeAda();
        vm.expectRevert(ILedger.NotMember.selector);
        vm.prank(ada);
        ledger.deposit(pot, 1e6);
    }

    function test_proof2_aFrozenMemberCannotCreateAVault() public {
        _freezeAda();
        vm.expectRevert(ILedger.NotMember.selector);
        _personal(ada);
    }

    function test_proof2_aFrozenMemberCannotVote() public {
        uint256 newPrice = config.seatPriceFloor() + 1;
        vm.prank(host);
        community.proposeSeatPrice(newPrice);
        uint256 priceVote = community.activePriceVoteId();
        _freezeAda();

        vm.expectRevert(ICommunity.NotMember.selector);
        vm.prank(ada);
        community.castVote(priceVote, true);

        uint256 own = _voteId(ada);
        vm.expectRevert(ICommunity.NotMember.selector);
        vm.prank(ada);
        community.castVote(own, false);
    }

    function test_proof2_aFrozenMemberCannotForfeit() public {
        _freezeAda();
        vm.expectRevert(E_FROZEN);
        vm.prank(ada);
        community.forfeit();
    }

    /// What is in can still come out. A member frozen while holding a personal vault and a tab
    /// withdraws the one and settles the other.
    function test_proof2_aFrozenMemberCanWithdrawAPersonalVaultAndSettle() public {
        uint256 mine = _personal(ada);
        vm.prank(ada);
        ledger.deposit(mine, 100e6);
        _primeEligible(ada);
        _draw(ada, 50e6);

        _propose(host, ada);
        assertFalse(community.isMember(ada), "frozen");

        uint256 walletBefore = usdc.balanceOf(ada);
        vm.prank(ada);
        ledger.withdrawInstant(mine, 100e6);
        assertEq(usdc.balanceOf(ada), walletBefore + 100e6, "the personal vault paid out");

        _settle(ada, 50e6);
        assertFalse(cc.hasOpenTab(ada), "the tab is settled");
    }

    // =============================================================================
    // Proof 3: a failed vote returns everything, with no transaction
    // =============================================================================

    function test_proof3_aFailedVoteUnfreezesAtTheDeadlineWithNoTransaction() public {
        _primeEligible(ada);
        uint256 pot = _shared();
        _propose(host, ada);
        uint256 deadline = block.timestamp + _window();

        vm.warp(deadline);
        assertFalse(community.isMember(ada), "still frozen at the deadline itself: the window is closed-ended");

        vm.warp(deadline + 1);
        // No executeRemoval, no poke, nothing. The failure is read, not written.
        assertTrue(community.isMember(ada), "a failed vote leaves the member unfrozen");
        assertEq(_state(ada), ACTIVE);

        uint256 mine = _personal(ada);
        vm.startPrank(ada);
        ledger.deposit(mine, 10e6);
        ledger.deposit(pot, 1e6);
        vm.stopPrank();

        uint256 newPrice = config.seatPriceFloor() + 1;
        vm.prank(host);
        community.proposeSeatPrice(newPrice);
        uint256 priceVote = community.activePriceVoteId();
        vm.prank(ada);
        community.castVote(priceVote, true);

        _draw(ada, 50e6);
        _settle(ada, 50e6);
        vm.prank(ada);
        ledger.withdrawInstant(mine, 10e6);

        vm.prank(ada);
        community.forfeit();
        assertEq(_state(ada), LEFT, "and leaving is theirs again");
    }

    // =============================================================================
    // Proof 4: a passed removal suspends the seat, which stays in the wallet
    // =============================================================================

    function test_proof4_anExecutedRemovalSuspendsTheSeat() public {
        uint256 tokenId = community.tokenOf(ada);
        assertEq(community.memberCount(), 5);

        _remove(ada);

        assertEq(_state(ada), SUSPENDED, "Suspended");
        assertEq(community.memberCount(), 4, "one fewer member");
        assertFalse(community.isMember(ada), "not a member");
        assertEq(community.tokenOf(ada), tokenId, "the record is kept");
        assertEq(factory.seats().ownerOf(tokenId), ada, "and the seat is still in the member's wallet");
        assertEq(factory.seats().balanceOf(ada), 1);
    }

    // =============================================================================
    // Proof 5: the original defect. A Suspended seat cannot come back
    // =============================================================================

    /// At the base, a suspended member forfeited (which deleted `suspended[msg.sender]` and
    /// burned the seat) and joined again with a clean slate. Here the escape is attempted and
    /// its outcome is not asserted, so that the join is what decides the test either way.
    function test_proof5_aSuspendedSeatsOwnerCannotJoinAgain() public {
        _remove(ada);

        vm.prank(ada);
        try community.forfeit() {} catch {}

        (address inviteKey, bytes memory keySig) = _inviteFor(address(community), ada);
        vm.expectRevert(ICommunity.AlreadyMember.selector);
        vm.prank(ada);
        community.join(inviteKey, keySig);

        assertEq(_state(ada), SUSPENDED, "carried for life on that wallet");
        assertFalse(community.isMember(ada));
        vm.expectRevert(ICommunity.NotMember.selector);
        vm.prank(ada);
        community.forfeit();
    }

    // =============================================================================
    // Proof 6: leaving is Left, the seat stays, and it bars a rejoin
    // =============================================================================

    function test_proof6_aForfeitedSeatIsLeftStaysAndBarsRejoining() public {
        uint256 tokenId = community.tokenOf(ada);
        vm.prank(ada);
        community.forfeit();

        assertEq(_state(ada), LEFT, "Left");
        assertEq(community.tokenOf(ada), tokenId, "the record is kept");
        assertEq(factory.seats().ownerOf(tokenId), ada, "the seat is still in the wallet");
        assertEq(community.memberCount(), 4);
        assertFalse(community.isMember(ada));

        (address inviteKey, bytes memory keySig) = _inviteFor(address(community), ada);
        vm.expectRevert(ICommunity.AlreadyMember.selector);
        vm.prank(ada);
        community.join(inviteKey, keySig);
    }

    // =============================================================================
    // Proof 7: no new removal of the same member inside the cooldown
    // =============================================================================

    function test_proof7_theCooldownBindsTheSameMemberUntilItsBoundary() public {
        uint256 deadline = _proposeAndLetFail(ada);
        assertTrue(community.isMember(ada), "the failed vote released the member");

        // Another member is unaffected, straight away.
        _propose(host, bea);
        assertTrue(_voteId(bea) != 0);

        vm.warp(deadline + _cooldown() - 1);
        vm.expectRevert(E_COOLDOWN);
        _propose(host, ada);
        assertTrue(community.isMember(ada), "a refused proposal freezes nobody");

        vm.warp(deadline + _cooldown());
        _propose(host, ada);
        assertFalse(community.isMember(ada), "at exactly the boundary the host may propose again");
    }

    // =============================================================================
    // Proof 8: only seats seasoned when the vote started may vote in it
    // =============================================================================

    /// `early` was minted exactly the seasoning window before the vote started and may vote.
    /// `late` was minted one second after that and may not, even once it has crossed the window
    /// partway through the vote: eligibility is fixed at the vote's start.
    function _seasoningPair() internal returns (address early, address late) {
        early = makeAddr("early");
        late = makeAddr("late");
        address[2] memory who = [early, late];
        for (uint256 i; i < 2; i++) {
            vm.prank(who[i]);
            registry.attest(1);
            usdc.mint(who[i], 1_000e6);
            vm.prank(who[i]);
            usdc.approve(address(community), type(uint256).max);
        }
        _joinAs(address(community), early);
        vm.warp(block.timestamp + 1);
        _joinAs(address(community), late);
        vm.warp(block.timestamp + config.memberSeasoningWindow() - 1);
    }

    function _assertSeasonedVoting(uint256 voteId, address early, address late) internal {
        vm.prank(early);
        community.castVote(voteId, true);

        vm.expectRevert(ICommunity.VoteIneligible.selector);
        vm.prank(late);
        community.castVote(voteId, true);

        vm.warp(block.timestamp + 2 days);
        assertTrue(community.isSeasoned(late), "seasoned by the clock now");
        vm.expectRevert(ICommunity.VoteIneligible.selector);
        vm.prank(late);
        community.castVote(voteId, true);
    }

    function test_proof8_unseasonedSeatsCannotVote_removal() public {
        (address early, address late) = _seasoningPair();
        _propose(host, ada);
        _assertSeasonedVoting(_voteId(ada), early, late);
    }

    function test_proof8_unseasonedSeatsCannotVote_hostVote() public {
        (address early, address late) = _seasoningPair();
        vm.prank(bea);
        community.proposeRemoveSteward();
        _assertSeasonedVoting(community.activeStewardVoteId(), early, late);
    }

    function test_proof8_unseasonedSeatsCannotVote_priceVote() public {
        (address early, address late) = _seasoningPair();
        uint256 newPrice = config.seatPriceFloor() + 1;
        vm.prank(host);
        community.proposeSeatPrice(newPrice);
        _assertSeasonedVoting(community.activePriceVoteId(), early, late);
    }

    // =============================================================================
    // Proof 9: the freeze does not erase impact
    // =============================================================================

    /// Settling runs `CreditStanding._syncSeat`, which deletes every seat-side mapping when the
    /// stamp stops matching the live seat. If a frozen seat read as gone, this settle would wipe
    /// the member's impact, and a vote that then fails would hand back a member with nothing.
    function test_proof9_aFrozenMemberWhoSettlesKeepsTheirImpactWhenTheVoteFails() public {
        _primeEligible(ada);
        _draw(ada, 50e6);
        (uint256 completedBefore,,,) = standing.standingCountersOf(0, ada);

        _propose(host, ada);
        assertFalse(community.isMember(ada), "frozen");
        vm.warp(block.timestamp + 1 days);
        _settle(ada, 50e6);
        (uint256 completedDuring,,,) = standing.standingCountersOf(0, ada);
        assertEq(completedDuring, completedBefore + 1, "the settle landed on the seat");

        vm.warp(block.timestamp + _window() + 1);
        assertTrue(community.isMember(ada), "the vote failed");
        assertEq(standing.impactUnitsOf(0, ada), 500e6, "impact intact");
        (uint256 completedAfter,,,) = standing.standingCountersOf(0, ada);
        assertEq(completedAfter, completedBefore + 1, "and so is the obligation the frozen member completed");
    }

    // =============================================================================
    // Proof 10: impact ends in the transaction the seat ends in
    // =============================================================================

    function _secondCommunity() internal returns (Community communityB) {
        uint256 price = 50e6;
        vm.prank(host);
        communityB = Community(factory.createCommunity("Second Community", price));
    }

    /// Ada holds 100e6 of impact in A and 400e6 in B, so the cap is 3 x 500e6. Removed from B,
    /// the cap read inside the executing call is 3 x 100e6, with nothing written to B's
    /// `CreditStanding` storage in between.
    function test_proof10_aRemovalEndsImpactInTheSameTransaction() public {
        Community communityB = _secondCommunity();
        address[4] memory members = [ada, bea, cid, dee];
        for (uint256 i; i < 4; i++) {
            vm.startPrank(members[i]);
            usdc.approve(address(communityB), type(uint256).max);
            _invitedJoin(address(communityB), members[i]);
            vm.stopPrank();
        }
        vm.warp(block.timestamp + config.memberSeasoningWindow() + 1);

        standing.primeImpact(0, ada, 100e6, 1000e6);
        standing.primeImpact(1, ada, 400e6, 1000e6);
        assertEq(standing.accountExposureCap(0, ada), 1_500e6, "cap on both seats' impact");

        community = communityB; // the adapter and helpers act on B from here
        _proposeAndCarry(ada);
        vm.warp(block.timestamp + _window() + 1);

        SameTxProbe probe = new SameTxProbe();
        (uint256 capBefore, uint256 capAfter, uint256 totalAfter) =
            probe.capAround(address(communityB), _executeCall(ada), standing, ada);

        assertEq(_state(ada), SUSPENDED, "removed from B");
        assertEq(capBefore, 1_500e6, "frozen in B until the removal executed, and still counted");
        assertEq(capAfter, 300e6, "B's impact left the cap in the executing transaction");
        assertEq(totalAfter, 100e6, "and the account total with it");
    }

    /// The same for leaving. The member is the probe, so its own `forfeit()` and the two reads
    /// are one call.
    function test_proof10_leavingEndsImpactInTheSameTransaction() public {
        Community communityB = _secondCommunity();
        SameTxProbe probe = new SameTxProbe();
        address p = address(probe);
        usdc.mint(p, 1_000e6);
        probe.exec(address(registry), abi.encodeCall(ComplianceRegistry.attest, (1)));
        Community[2] memory both = [community, communityB];
        for (uint256 i; i < 2; i++) {
            probe.exec(address(usdc), abi.encodeCall(IERC20.approve, (address(both[i]), type(uint256).max)));
            (address inviteKey, bytes memory keySig) = _inviteFor(address(both[i]), p);
            probe.exec(address(both[i]), abi.encodeCall(ICommunity.join, (inviteKey, keySig)));
        }
        standing.primeImpact(0, p, 100e6, 1000e6);
        standing.primeImpact(1, p, 400e6, 1000e6);

        (uint256 capBefore, uint256 capAfter, uint256 totalAfter) =
            probe.capAround(address(communityB), abi.encodeCall(ICommunity.forfeit, ()), standing, p);

        assertEq(factory.seats().ownerOf(communityB.tokenOf(p)), p, "the Left seat is still in the wallet");
        assertEq(capBefore, 1_500e6);
        assertEq(capAfter, 300e6, "B's impact left the cap in the forfeiting transaction");
        assertEq(totalAfter, 100e6, "and the account total with it");
    }

    // =============================================================================
    // Proof 11: a Suspended member withdraws and settles, end to end
    // =============================================================================

    function test_proof11_aSuspendedMemberWithdrawsTheirPersonalVaultAndSettles() public {
        uint256 mine = _personal(ada);
        vm.prank(ada);
        ledger.deposit(mine, 100e6);
        _primeEligible(ada);
        _draw(ada, 50e6);

        _remove(ada);
        assertEq(_state(ada), SUSPENDED);
        assertFalse(community.isMember(ada), "no longer a member");

        uint256 walletBefore = usdc.balanceOf(ada);
        vm.prank(ada);
        ledger.withdrawInstant(mine, 100e6);
        assertEq(usdc.balanceOf(ada), walletBefore + 100e6, "the personal vault paid out");
        assertEq(ledger.personalUnitsOf(ada), 0);

        _settle(ada, 50e6);
        assertFalse(cc.hasOpenTab(ada), "the tab is settled");
    }
}
