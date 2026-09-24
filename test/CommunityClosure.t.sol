// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.30;

import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {InviteSigner} from "./helpers/InviteSigner.sol";
import {Seats} from "../src/Seats.sol";
import {Config} from "../src/Config.sol";
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

/// Closing a community is a member vote, over the real factory, `Community`, `Seats` and `Ledger`,
/// because the vote and the close it triggers are a call between two contracts and a stub would
/// prove nothing about the wiring. Also here: what a closed community refuses, what an open
/// closure vote pauses, who may stand for host, and the headcount over real seats.
contract CommunityClosureTest is InviteSigner {
    MockUSDC usdc;
    Config config;
    ComplianceRegistry registry;
    CommunityFactory factory;
    Community community;
    Ledger ledger;
    Venue[3] venues;
    MockCreditCoreLeg core;

    address owner = makeAddr("owner");
    address treasury = makeAddr("treasury");
    address host = makeAddr("host");
    address ada = makeAddr("ada");
    address bea = makeAddr("bea");
    address cid = makeAddr("cid");
    address dan = makeAddr("dan");
    address eve = makeAddr("eve");
    address newcomer = makeAddr("newcomer");
    address payee = makeAddr("payee");

    uint64 hostWindow;

    function setUp() public {
        vm.warp(1000 days);
        usdc = new MockUSDC();
        registry = new ComplianceRegistry(address(this));
        vm.prank(owner);
        config = new Config(address(usdc), treasury, address(registry));
        core = new MockCreditCoreLeg(IERC20(address(usdc)));
        vm.prank(owner);
        config.setAddress(K.CREDIT_CORE, address(core));
        (, hostWindow) = config.hostVote();

        address communityImpl = address(new Community());
        address ledgerImpl = address(new Ledger());
        address predicted = vm.computeCreateAddress(address(this), vm.getNonce(address(this)) + 4);
        for (uint8 t = 0; t < 3; t++) {
            venues[t] = new Venue(usdc, IConfig(address(config)), predicted, owner, "Qudi", "q");
        }
        Seats seats = new Seats(predicted, IConfig(address(config)));
        factory = new CommunityFactory(address(config), address(seats), communityImpl, ledgerImpl, address(this));
        for (uint8 t = 0; t < 3; t++) {
            vm.prank(owner);
            venues[t].setLabels(VenueIds.labels(t));
            factory.addVenue(address(venues[t]));
        }
        assertEq(address(factory), predicted);

        (community, ledger) = _newCommunity(host);
        address[5] memory people = [ada, bea, cid, dan, eve];
        for (uint256 i; i < 5; i++) {
            _member(community, people[i]);
        }
        _season();
    }

    // ---- helpers ----

    function _fund(address who) internal {
        if (!registry.isAttested(who)) {
            vm.prank(who);
            registry.attest(1);
        }
        usdc.mint(who, 1_000_000e6);
    }

    function _newCommunity(address by) internal returns (Community c, Ledger l) {
        _fund(by);
        vm.prank(by);
        c = Community(factory.createCommunity("Test Community", 0));
        l = Ledger(factory.ledgerOf(address(c)));
        vm.prank(by);
        usdc.approve(address(l), type(uint256).max);
    }

    function _member(Community c, address who) internal {
        _fund(who);
        address l = factory.ledgerOf(address(c));
        vm.prank(who);
        usdc.approve(l, type(uint256).max);
        _joinAs(address(c), who);
    }

    function _season() internal {
        vm.warp(block.timestamp + config.memberSeasoningWindow());
    }

    function _castAll(Community c, uint256 voteId, address[] memory yes) internal {
        for (uint256 i; i < yes.length; i++) {
            vm.prank(yes[i]);
            c.castVote(voteId, true);
        }
    }

    function _list(address a, address b, address d, address e, address f) internal pure returns (address[] memory l) {
        l = new address[](5);
        (l[0], l[1], l[2], l[3], l[4]) = (a, b, d, e, f);
    }

    function _first(address[] memory l, uint256 n) internal pure returns (address[] memory r) {
        r = new address[](n);
        for (uint256 i; i < n; i++) {
            r[i] = l[i];
        }
    }

    function _proposeClosure() internal returns (uint256 voteId) {
        vm.prank(host);
        community.proposeClosure();
        voteId = community.closureVoteId();
    }

    /// The host proposes, five of six vote yes, the window closes, and anyone executes.
    function _close() internal {
        uint256 voteId = _proposeClosure();
        _castAll(community, voteId, _list(host, ada, bea, cid, dan));
        vm.warp(block.timestamp + hostWindow + 1);
        community.executeClosure();
    }

    // ---- proof 13a: the closure vote ----

    /// The host cannot close alone: the ledger takes a close only from its community, and a
    /// closure vote the host alone supports fails.
    function test_proof13a_theHostAloneCannotClose() public {
        vm.expectRevert(ILedger.NotCommunity.selector);
        vm.prank(host);
        ledger.closeCommunity();

        uint256 voteId = _proposeClosure();
        vm.prank(host);
        community.castVote(voteId, true);
        vm.warp(block.timestamp + hostWindow + 1);
        vm.expectRevert(ICommunity.NotPassed.selector);
        community.executeClosure();
        assertFalse(ledger.communityClosed());
    }

    function test_proof13a_onlyTheHostProposes() public {
        vm.expectRevert(ICommunity.NotSteward.selector);
        vm.prank(ada);
        community.proposeClosure();
    }

    /// Six seasoned members: five yes votes clear more than two thirds, four do not.
    function test_proof13a_sixSeasoned_fiveYesPass() public {
        uint256 voteId = _proposeClosure();
        ICommunity.VoteTally memory t = community.voteTally(voteId);
        assertEq(t.denominator, 6);
        assertEq(uint8(t.kind), uint8(ICommunity.VoteKind.Closure));
        _castAll(community, voteId, _list(host, ada, bea, cid, dan));
        vm.warp(block.timestamp + hostWindow + 1);
        community.executeClosure();
        assertTrue(community.closed());
        assertTrue(ledger.communityClosed(), "the passed vote closed the ledger");
    }

    function test_proof13a_sixSeasoned_fourYesFail() public {
        uint256 voteId = _proposeClosure();
        _castAll(community, voteId, _first(_list(host, ada, bea, cid, dan), 4));
        vm.warp(block.timestamp + hostWindow + 1);
        vm.expectRevert(ICommunity.NotPassed.selector);
        community.executeClosure();
    }

    /// Two seasoned members: both yes votes close it. The floor is min(3, headcount), never 3 in a
    /// community that has only two voters.
    function test_proof13a_twoSeasoned_twoYesPass() public {
        address host2 = makeAddr("host2");
        address mate = makeAddr("mate");
        (Community c, Ledger l) = _newCommunity(host2);
        _member(c, mate);
        _season();
        vm.prank(host2);
        c.proposeClosure();
        uint256 voteId = c.closureVoteId();
        assertEq(c.voteTally(voteId).denominator, 2);
        assertEq(c.voteTally(voteId).minYes, 2);

        vm.prank(host2);
        c.castVote(voteId, true);
        vm.prank(mate);
        c.castVote(voteId, true);
        vm.warp(block.timestamp + hostWindow + 1);
        c.executeClosure();
        assertTrue(l.communityClosed());
    }

    /// Refused while a shared vault holds money, when proposing and again when executing.
    function test_proof13a_refusedWhileASharedVaultHoldsMoney() public {
        vm.prank(host);
        uint256 pot = ledger.createVault(ILedger.VaultParams(VenueIds.FLEX, true, 0, "pot"));
        vm.prank(ada);
        ledger.deposit(pot, 20e6);
        vm.expectRevert(ICommunity.SharedVaultHoldsMoney.selector);
        vm.prank(host);
        community.proposeClosure();
    }

    function test_proof13a_executionRechecksTheSharedVaults() public {
        uint256 voteId = _proposeClosure();
        _castAll(community, voteId, _list(host, ada, bea, cid, dan));
        vm.prank(host);
        uint256 pot = ledger.createVault(ILedger.VaultParams(VenueIds.FLEX, true, 0, "pot"));
        vm.prank(ada);
        ledger.deposit(pot, 20e6);
        vm.warp(block.timestamp + hostWindow + 1);
        vm.expectRevert(ICommunity.SharedVaultHoldsMoney.selector);
        community.executeClosure();
    }

    /// Refused while a removal vote is open, and proposable again once it has failed.
    function test_proof13a_refusedWhileARemovalVoteIsOpen() public {
        vm.prank(host);
        community.proposeRemoval(eve);
        vm.expectRevert(ICommunity.VoteActive.selector);
        vm.prank(host);
        community.proposeClosure();

        (, uint64 window) = config.communityVote();
        vm.warp(block.timestamp + window + 1);
        _proposeClosure();
    }

    /// Refused while a vote to remove the host is open, and while a handover is pending.
    function test_proof13a_refusedWhileAHostVoteOrHandoverIsOpen() public {
        vm.prank(ada);
        community.proposeRemoveSteward();
        vm.expectRevert(ICommunity.VoteActive.selector);
        vm.prank(host);
        community.proposeClosure();
        vm.warp(block.timestamp + hostWindow + 1);

        vm.prank(host);
        community.nominateSuccessor(ada);
        vm.expectRevert(ICommunity.NominationPending.selector);
        vm.prank(host);
        community.proposeClosure();
    }

    /// A removal vote opened after the closure vote started still blocks its execution until the
    /// removal's window closes.
    function test_proof13a_executionRechecksTheOtherVotes() public {
        uint256 voteId = _proposeClosure();
        _castAll(community, voteId, _list(host, ada, bea, cid, dan));
        vm.warp(block.timestamp + 3 days);
        vm.prank(host);
        community.proposeRemoval(eve);
        vm.warp(community.voteTally(voteId).deadline + 1);
        vm.expectRevert(ICommunity.VoteActive.selector);
        community.executeClosure();

        vm.warp(community.voteTally(community.activeRemovalVoteId(eve)).deadline + 1);
        community.executeClosure();
        assertTrue(ledger.communityClosed());
    }

    /// After a failed closure vote a new one is refused for 30 days, then allowed.
    function test_proof13a_aFailedVoteCoolsDownFor30Days() public {
        uint256 voteId = _proposeClosure();
        uint64 deadline = community.voteTally(voteId).deadline;
        vm.warp(deadline + 1);
        vm.expectRevert(ICommunity.ClosureCooldown.selector);
        vm.prank(host);
        community.proposeClosure();

        uint64 cooldown = config.removalReproposeCooldown();
        vm.warp(deadline + cooldown - 1);
        vm.expectRevert(ICommunity.ClosureCooldown.selector);
        vm.prank(host);
        community.proposeClosure();
        vm.warp(deadline + cooldown);
        _proposeClosure();
    }

    function test_closure_oneVoteAtATime() public {
        _proposeClosure();
        vm.expectRevert(ICommunity.VoteActive.selector);
        vm.prank(host);
        community.proposeClosure();
    }

    // ---- once closed ----

    function test_closed_joinRefuses() public {
        _close();
        _fund(newcomer);
        (address key, bytes memory sig) = _makeInviteBeforeClosure();
        vm.expectRevert(ICommunity.CommunityIsClosed.selector);
        vm.prank(newcomer);
        community.join(key, sig);
    }

    /// An invite made before closure: registered in the old host term, so closing ends it.
    function _makeInviteBeforeClosure() internal view returns (address key, bytes memory sig) {
        key = vm.addr(0xBEEF);
        sig = _keySign(0xBEEF, address(community), newcomer);
    }

    function test_closed_createInviteRefuses() public {
        _close();
        vm.expectRevert(ICommunity.CommunityIsClosed.selector);
        vm.prank(host);
        community.createInvite(makeAddr("key"), 1, uint64(block.timestamp + 1 days));
    }

    /// Closing ends the host term, so every live invite of it stops working.
    function test_closed_everyLiveInviteStopsWorking() public {
        address key = vm.addr(0xBEEF);
        vm.prank(host);
        community.createInvite(key, 5, uint64(block.timestamp + 20 days));
        uint64 term = community.hostTerm();
        assertEq(community.inviteOf(key).term, term);
        _close();
        assertEq(community.hostTerm(), term + 1, "closing ends the host term");
        assertTrue(community.inviteOf(key).term != community.hostTerm(), "the invite belongs to an ended term");
    }

    function test_closed_hostRemovalNominationResignationAndElectionRefuse() public {
        _close();
        vm.expectRevert(ICommunity.CommunityIsClosed.selector);
        vm.prank(ada);
        community.proposeRemoveSteward();
        vm.expectRevert(ICommunity.CommunityIsClosed.selector);
        vm.prank(host);
        community.nominateSuccessor(ada);
        vm.expectRevert(ICommunity.CommunityIsClosed.selector);
        vm.prank(host);
        community.resignHost();
        vm.expectRevert(ICommunity.CommunityIsClosed.selector);
        vm.prank(ada);
        community.electSteward(bea);
    }

    /// A closed community refuses deposits and still pays its personal vaults out.
    function test_closed_refusesDepositsAndPaysWithdrawals() public {
        vm.prank(ada);
        uint256 mine = ledger.createVault(ILedger.VaultParams(VenueIds.FLEX, false, 0, "mine"));
        vm.prank(ada);
        ledger.deposit(mine, 100e6);
        _close();

        vm.expectRevert(ILedger.CommunityIsClosed.selector);
        vm.prank(ada);
        ledger.deposit(mine, 1e6);

        uint256 before = usdc.balanceOf(ada);
        vm.prank(ada);
        ledger.requestWithdraw(mine, 100e6);
        assertEq(usdc.balanceOf(ada) - before, 100e6);
    }

    // ---- events for the indexer ----

    /// Every ballot emits `VoteCast`, yes or no, on any vote kind.
    function test_castVote_emitsVoteCast() public {
        uint256 voteId = _proposeClosure();
        vm.expectEmit(true, true, false, true, address(community));
        emit ICommunity.VoteCast(voteId, ada, true);
        vm.prank(ada);
        community.castVote(voteId, true);

        vm.expectEmit(true, true, false, true, address(community));
        emit ICommunity.VoteCast(voteId, bea, false);
        vm.prank(bea);
        community.castVote(voteId, false);
    }

    /// Every objection to a handover emits `HandoverObjected`.
    function test_objectToHandover_emitsHandoverObjected() public {
        vm.prank(host);
        community.nominateSuccessor(ada);
        vm.prank(ada);
        community.acceptNomination();
        uint256 voteId = community.pendingHandover().voteId;

        vm.expectEmit(true, true, false, true, address(community));
        emit ICommunity.HandoverObjected(voteId, bea);
        vm.prank(bea);
        community.objectToHandover();
    }

    // ---- while a closure vote is open ----

    /// Someone joining mid-vote would pay for a seat in a community about to close, so joining and
    /// new invites wait until the vote ends. A failed vote reopens both.
    function test_openClosureVote_pausesJoiningAndInvites() public {
        _fund(newcomer);
        address key = vm.addr(0xBEEF);
        vm.prank(host);
        community.createInvite(key, 5, uint64(block.timestamp + 20 days));
        bytes memory sig = _keySign(0xBEEF, address(community), newcomer);

        uint256 voteId = _proposeClosure();
        vm.expectRevert(ICommunity.ClosureVoteOpen.selector);
        vm.prank(newcomer);
        community.join(key, sig);
        vm.expectRevert(ICommunity.ClosureVoteOpen.selector);
        vm.prank(host);
        community.createInvite(makeAddr("key2"), 1, uint64(block.timestamp + 1 days));

        vm.warp(community.voteTally(voteId).deadline + 1);
        vm.prank(newcomer);
        community.join(key, sig);
        assertEq(uint8(community.seatStateOf(newcomer)), uint8(ICommunity.SeatState.Active));
    }

    // ---- who may stand for host ----

    /// A candidate must be a seasoned Active member no removal vote is open against, the bar a
    /// handover nominee meets. Nobody joins and stands for host on day one.
    function test_election_anUnseasonedCandidateIsRefused() public {
        _member(community, newcomer);
        vm.prank(host);
        community.resignHost();
        vm.expectRevert(ICommunity.CandidateIneligible.selector);
        vm.prank(ada);
        community.electSteward(newcomer);

        vm.prank(ada);
        community.electSteward(bea);
    }

    function test_election_aFrozenCandidateIsRefused() public {
        vm.prank(host);
        community.proposeRemoval(bea);
        vm.prank(host);
        community.resignHost();
        vm.expectRevert(ICommunity.CandidateIneligible.selector);
        vm.prank(ada);
        community.electSteward(bea);
    }

    // ---- proof 10 over real seats: a removed member keeps their personal vault ----

    function test_proof10_aSuspendedMemberWithdrawsAndCannotDeposit() public {
        vm.prank(eve);
        uint256 mine = ledger.createVault(ILedger.VaultParams(VenueIds.FLEX, false, 0, "mine"));
        vm.prank(eve);
        ledger.deposit(mine, 100e6);

        vm.prank(host);
        community.proposeRemoval(eve);
        _castAll(community, community.activeRemovalVoteId(eve), _first(_list(host, ada, bea, cid, dan), 4));
        (, uint64 window) = config.communityVote();
        vm.warp(block.timestamp + window + 1);
        community.executeRemoval(eve);
        assertEq(uint8(community.seatStateOf(eve)), uint8(ICommunity.SeatState.Suspended));

        vm.expectRevert(ILedger.NotMember.selector);
        vm.prank(eve);
        ledger.deposit(mine, 1e6);

        uint256 before = usdc.balanceOf(eve);
        vm.prank(eve);
        ledger.requestWithdraw(mine, 100e6);
        assertEq(usdc.balanceOf(eve) - before, 100e6);
    }

    // ---- the headcount over real seats ----

    /// The same measurement as `LedgerSharedPayout.t.sol`, over the real `Community` and `Seats`,
    /// where each counted depositor costs two real calls: 149 members and the host, the most Active
    /// seats a community holds, every one of them counted.
    function test_gas_headcountOverAFullCommunity() public {
        vm.prank(host);
        uint256 pot = ledger.createVault(ILedger.VaultParams(VenueIds.FLEX, true, 0, "pot"));
        address[5] memory people = [ada, bea, cid, dan, eve];
        for (uint256 i; i < 5; i++) {
            vm.prank(people[i]);
            ledger.deposit(pot, 20e6);
        }
        for (uint256 i; i < 144; i++) {
            address m = address(uint160(0x20000 + i));
            _member(community, m);
            vm.prank(m);
            ledger.deposit(pot, 20e6);
        }
        vm.prank(host);
        ledger.deposit(pot, 20e6);
        assertEq(community.memberCount(), 150);
        _season();

        vm.prank(host);
        uint256 g = gasleft();
        uint256 id = ledger.proposeWithdrawal(pot, payee, 10e6);
        g -= gasleft();
        assertEq(ledger.payouts(id).headcount, 150);
        emit log_named_uint("proposeWithdrawal gas, 150 counted members, real Community", g);
        assertLt(g, 10_000_000);
    }
}
