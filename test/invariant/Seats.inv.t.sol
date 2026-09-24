// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {console} from "forge-std/console.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";
import {EnumerableSet} from "openzeppelin-contracts/contracts/utils/structs/EnumerableSet.sol";
import {Config} from "../../src/Config.sol";
import {ConfigKeys as K} from "../../src/ConfigKeys.sol";
import {ComplianceRegistry} from "../../src/ComplianceRegistry.sol";
import {Community} from "../../src/Community.sol";
import {Seats} from "../../src/Seats.sol";
import {ICommunity} from "../../src/interfaces/ICommunity.sol";
import {ICommunityInit} from "../../src/interfaces/ICommunityInit.sol";
import {PoolTypes} from "../../src/PoolTypes.sol";
import {MockUSDC} from "../mocks/MockUSDC.sol";
import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {MockVault, MockCreditCoreLeg} from "../mocks/MockSeatSiblings.sol";
import {InviteSigner} from "../helpers/InviteSigner.sol";

/// A seat handler, driving one community's seats and votes. Every mutating function is guarded to
/// no-op (never revert) on a failed precondition, so the fuzzer can chain deep call
/// sequences without every call reverting the moment one actor is off cooldown/eligibility/etc.
///
/// Ghost-state design note: the fixture's founding steward (`originalSteward`) gets its seat
/// for free in Community.initialize(), outside the handler's 8-actor pool, and is never
/// re-added to the ghost member set by any handler call. So "is the founding steward still
/// seated" is tracked directly via community.seatStateOf(originalSteward) rather than by mirroring
/// the currently-active steward() role, which can move to one of the 8 actors via
/// electSteward() after a removal - at that point the actor is already in the ghost set from
/// their own join(), and double counting a "+1 for current steward" would be wrong.
///
/// A seat is never burned. It is Active, Suspended (an executed removal vote) or Left
/// (forfeit), and the last two are final. `ghostState` mirrors the one write each handler call
/// is allowed to make, so any other path that moved a seat's state shows as a mismatch, and
/// `_members` holds the Active actors `memberCount` counts. Every handler method counts the
/// calls that landed (`lands`) against the calls it tried (`tries`), because this suite was once
/// found comparing 0 to 0: a reshaped handler whose calls all revert inside their `try` makes
/// every invariant hold vacuously, and only a landed count shows it.
contract SeatHandler is InviteSigner {
    Community public community;
    Seats public seats;
    Config public config;
    MockUSDC public usdc;
    MockVault public vault;
    MockCreditCoreLeg public core;
    address public originalSteward;
    address public owner;

    /// 24, not 8: each actor can mint here once in its life, and a
    /// removal carries on three seasoned yes votes, so a small pool is all Left or Suspended
    /// within a few hundred steps and every later call would be a no-op.
    uint256 public constant ACTORS = 24;
    address[24] public actors;

    using EnumerableSet for EnumerableSet.AddressSet;
    EnumerableSet.AddressSet internal _members;

    uint256 public sumMinted;
    uint256 public sumToSteward;
    uint256 public sumToPool;
    uint256 public sumToTreasury;
    address public treasury;

    /// The seat state each actor should hold, as a `uint8` of `ICommunity.SeatState`, and the
    /// token id minted to it. Written only where the contract is allowed to change them: join()
    /// (Active, and the id), forfeit() (Left) and executeRemoval() (Suspended).
    mapping(address => uint8) public ghostState;
    mapping(address => uint256) public ghostToken;

    /// Set if a join() by a wallet that already holds a seat, of any state, ever lands (a kept
    /// seat is the bar on rejoining).
    bool public rejoinLanded;
    /// Set if a forfeit() by a frozen member ever lands.
    bool public forfeitWhileFrozenLanded;

    mapping(bytes32 => uint256) public lands;
    mapping(bytes32 => uint256) public tries;

    /// Set true iff executeSeatPriceVote() ever succeeds while leaving community.seatPrice()
    /// below config.seatPriceFloor() or above config.seatPriceCeiling() at that same instant.
    /// This is the only range property the contract actually promises: seatPrice is sticky once
    /// set and the floor can rise independently afterward (see raiseFloor below), so "seatPrice
    /// in range" is not a standing invariant over live state. It only has to hold at the moment
    /// a price-setting vote executes, which is what executeSeatPriceVote()'s live recheck
    /// exists to guarantee.
    bool public priceOutOfRangeAtExecution;

    constructor(
        Community community_,
        Seats seats_,
        Config config_,
        MockUSDC usdc_,
        MockVault vault_,
        MockCreditCoreLeg core_,
        address steward_,
        address treasury_,
        address owner_
    ) {
        community = community_;
        seats = seats_;
        config = config_;
        usdc = usdc_;
        vault = vault_;
        core = core_;
        originalSteward = steward_;
        treasury = treasury_;
        owner = owner_;
        for (uint256 i = 0; i < actors.length; i++) {
            actors[i] = _keyedFromSeed(uint256(keccak256(abi.encode("seat-actor", i))));
        }
    }

    function actorsCount() external pure returns (uint256) {
        return ACTORS;
    }

    function memberSetLength() external view returns (uint256) {
        return _members.length();
    }

    function memberSetAt(uint256 i) external view returns (address) {
        return _members.at(i);
    }

    function isGhostMember(address who) external view returns (bool) {
        return _members.contains(who);
    }

    function _pickActor(uint256 seed) internal view returns (address) {
        return actors[seed % actors.length];
    }

    // ---- handler surface ----

    // Every join carries a fresh single-use invite from the current host, so the gate itself is
    // never what refuses a join here. With no host nobody can make an invite, and the join is
    // sent with an empty one, which the vacancy check refuses first. A wallet that already
    // holds a seat is still sent through join(), because that is the rejoin the bar refuses.
    function join(uint256 actorSeed) external {
        address actor = _pickActor(actorSeed);
        if (community.tokenOf(actor) != 0) {
            _attemptRejoin(actor);
            return;
        }
        tries["join"]++;

        uint256 price = community.seatPrice();
        usdc.mint(actor, price);
        vm.prank(actor);
        usdc.approve(address(community), price);

        address stewardAtCall = community.steward();
        uint256 stewardBefore = usdc.balanceOf(stewardAtCall);
        uint256 poolBefore = core.totalLegs();
        uint256 treasuryBefore = usdc.balanceOf(treasury);

        (address inviteKey, bytes memory keySig) = _signedInvite(actor);
        vm.prank(actor);
        try community.join(inviteKey, keySig) {
            uint256 stewardAfter = usdc.balanceOf(stewardAtCall);
            uint256 poolAfter = core.totalLegs();
            uint256 treasuryAfter = usdc.balanceOf(treasury);

            sumMinted += price;
            sumToSteward += stewardAfter - stewardBefore;
            sumToPool += poolAfter - poolBefore;
            sumToTreasury += treasuryAfter - treasuryBefore;
            _members.add(actor);
            ghostState[actor] = uint8(ICommunity.SeatState.Active);
            ghostToken[actor] = community.tokenOf(actor);
            lands["join"]++;
        } catch {}
    }

    function _attemptRejoin(address actor) internal {
        tries["rejoin"]++;
        uint256 price = community.seatPrice();
        usdc.mint(actor, price);
        vm.prank(actor);
        usdc.approve(address(community), price);
        (address inviteKey, bytes memory keySig) = _signedInvite(actor);
        vm.prank(actor);
        try community.join(inviteKey, keySig) {
            rejoinLanded = true;
            lands["rejoin"]++;
        } catch {}
    }

    function _signedInvite(address actor) internal returns (address inviteKey, bytes memory keySig) {
        if (community.stewardVacant()) return (inviteKey, keySig);
        return _inviteFor(address(community), actor);
    }

    // The steward cannot forfeit (must be removed by vote first). A frozen member is sent
    // through anyway: forfeit() must refuse them, and a landing would set the flag.
    function forfeit(uint256 actorSeed) external {
        address actor = _pickActor(actorSeed);
        if (community.seatStateOf(actor) != ICommunity.SeatState.Active) return;
        if (actor == community.steward()) return;
        if (core.hasOpenTab(actor)) return;
        tries["forfeit"]++;
        bool frozen = community.isFrozen(actor);

        vm.prank(actor);
        try community.forfeit() {
            if (frozen) forfeitWhileFrozenLanded = true;
            _members.remove(actor);
            ghostState[actor] = uint8(ICommunity.SeatState.Left);
            lands["forfeit"]++;
        } catch {}
    }

    // ---- card price: propose (steward) / vote (members) / execute (permissionless) ----

    // config is not itself a fuzz target (only `owner` may call Config.set(), and no
    // handler-driven actor is the owner), so without this the floor is pinned at its
    // constructor value for the whole run and invariant_priceInRangeAtExecution could never
    // exercise the live re-check in executeSeatPriceVote(): a floor raised after a price vote
    // is proposed but before it executes. This lets the fuzzer raise it mid-run instead. Note
    // this can legitimately push the floor above the currently-standing seatPrice with no vote
    // in flight at all - that is not a bug (seatPrice is never retroactively re-validated), which
    // is why the invariant tracks priceOutOfRangeAtExecution rather than comparing live values.
    function raiseFloor(uint256 newFloorSeed) external {
        uint256 current = config.seatPriceFloor();
        uint256 ceiling = config.seatPriceCeiling();
        if (current >= ceiling) return;
        uint256 newFloor = bound(newFloorSeed, current, ceiling);
        vm.prank(owner);
        try config.set(K.SEAT_PRICE_FLOOR, newFloor) {} catch {}
    }

    function proposeSeatPrice(uint256 priceSeed) external {
        address steward = community.steward();
        if (steward == address(0)) return;
        uint256 floor = config.seatPriceFloor();
        uint256 ceiling = config.seatPriceCeiling();
        if (floor > ceiling) return;
        uint256 price = bound(priceSeed, floor, ceiling);

        tries["proposeSeatPrice"]++;
        vm.prank(steward);
        try community.proposeSeatPrice(price) {
            lands["proposeSeatPrice"]++;
        } catch {}
    }

    /// One ballot on `voteId`, from the first member in pool order from `seed` whose ballot lands,
    /// then the founding steward. A vote needs three seasoned yes votes and a
    /// threshold over the seasoned seats, and ballots from actors
    /// picked at random were mostly refused (already voted, unseasoned), so no price vote or host
    /// vote ever carried and the paths behind them compared 0 to 0.
    function _ballot(uint256 voteId, uint256 seed, bool support) internal returns (bool) {
        for (uint256 i; i < ACTORS; i++) {
            address actor = actors[(seed % ACTORS + i) % ACTORS];
            if (!community.isMember(actor)) continue;
            vm.prank(actor);
            try community.castVote(voteId, support) {
                return true;
            } catch {}
        }
        if (!community.isMember(originalSteward)) return false;
        vm.prank(originalSteward);
        try community.castVote(voteId, support) {
            return true;
        } catch {}
        return false;
    }

    function voteOnPrice(uint256 actorSeed, bool support) external {
        uint256 voteId = community.activePriceVoteId();
        if (voteId == 0) return;
        tries["voteOnPrice"]++;
        if (_ballot(voteId, actorSeed, support)) lands["voteOnPrice"]++;
    }

    function executeSeatPriceVote() external {
        tries["executeSeatPriceVote"]++;
        try community.executeSeatPriceVote() {
            uint256 price = community.seatPrice();
            if (price < config.seatPriceFloor() || price > config.seatPriceCeiling()) {
                priceOutOfRangeAtExecution = true;
            }
            lands["executeSeatPriceVote"]++;
        } catch {}
    }

    // ---- steward removal / election: propose (member) / vote (members) / execute
    // (permissionless), with election reachable only once the role is vacant ----

    function proposeRemoveSteward(uint256 actorSeed) external {
        address actor = _pickActor(actorSeed);
        if (!community.isMember(actor)) return;

        tries["proposeRemoveSteward"]++;
        vm.prank(actor);
        try community.proposeRemoveSteward() {
            lands["proposeRemoveSteward"]++;
        } catch {}
    }

    function voteOnSteward(uint256 actorSeed, bool support) external {
        uint256 voteId = community.activeStewardVoteId();
        if (voteId == 0) return;
        tries["voteOnSteward"]++;
        if (_ballot(voteId, actorSeed, support)) lands["voteOnSteward"]++;
    }

    // Only reachable once the role is vacant, by a passed removal vote or a resignation. A
    // failed election leaves its id in the slot, so the handler does not skip on a non-zero id:
    // the contract refuses a live one itself, and a community whose host resigned before anyone
    // seasoned would otherwise never get another.
    function electSteward(uint256 candidateSeed) external {
        if (!community.stewardVacant()) return;
        uint256 n = _members.length();
        if (n == 0) return;
        address candidate = _members.at(candidateSeed % n);

        tries["electSteward"]++;
        vm.prank(candidate);
        try community.electSteward(candidate) {
            lands["electSteward"]++;
        } catch {}
    }

    function executeRemoveSteward() external {
        tries["executeRemoveSteward"]++;
        try community.executeRemoveSteward() {
            lands["executeRemoveSteward"]++;
        } catch {}
    }

    // ---- handover: nominate (host) / accept (nominee) / object (members) / complete
    // (permissionless) / cancel (host), and resignation (host) ----

    function nominateSuccessor(uint256 nomineeSeed) external {
        address steward = community.steward();
        if (steward == address(0)) return;
        uint256 n = _members.length();
        if (n == 0) return;
        tries["nominateSuccessor"]++;
        vm.prank(steward);
        try community.nominateSuccessor(_members.at(nomineeSeed % n)) {
            lands["nominateSuccessor"]++;
        } catch {}
    }

    function acceptNomination() external {
        ICommunity.PendingHandover memory p = community.pendingHandover();
        if (p.nominee == address(0) || p.acceptedAt != 0) return;
        tries["acceptNomination"]++;
        vm.prank(p.nominee);
        try community.acceptNomination() {
            lands["acceptNomination"]++;
        } catch {}
    }

    /// One objection, from the first member in pool order from `seed` whose objection lands,
    /// then the founding steward, for the reason `_ballot` gives.
    function objectToHandover(uint256 seed) external {
        if (community.pendingHandover().acceptedAt == 0) return;
        tries["objectToHandover"]++;
        for (uint256 i; i <= ACTORS; i++) {
            address who = i == ACTORS ? originalSteward : actors[(seed % ACTORS + i) % ACTORS];
            if (!community.isMember(who)) continue;
            vm.prank(who);
            try community.objectToHandover() {
                lands["objectToHandover"]++;
                return;
            } catch {}
        }
    }

    function completeHandover() external {
        tries["completeHandover"]++;
        try community.completeHandover() {
            lands["completeHandover"]++;
        } catch {}
    }

    function cancelNomination() external {
        address steward = community.steward();
        if (steward == address(0)) return;
        tries["cancelNomination"]++;
        vm.prank(steward);
        try community.cancelNomination() {
            lands["cancelNomination"]++;
        } catch {}
    }

    function resignHost() external {
        address steward = community.steward();
        if (steward == address(0)) return;
        tries["resignHost"]++;
        vm.prank(steward);
        try community.resignHost() {
            lands["resignHost"]++;
        } catch {}
    }

    // ---- member removal: propose (steward only) / vote (members) / execute (permissionless),
    // per-target vote slot ----

    function proposeRemoval(uint256 targetSeed) external {
        address steward = community.steward();
        if (steward == address(0)) return;
        address target = _pickActor(targetSeed);
        if (community.seatStateOf(target) != ICommunity.SeatState.Active) return;
        if (target == steward) return;

        tries["proposeRemoval"]++;
        vm.prank(steward);
        try community.proposeRemoval(target) {
            lands["proposeRemoval"]++;
        } catch {}
    }

    /// Aims at the first actor, in pool order, with a live removal vote. Ballots spread over
    /// every open vote never add up to a majority of 17 seats inside one window, so without
    /// concentrating them no removal would ever carry and `executeRemoval` would never land.
    function voteOnRemoval(uint256 actorSeed, uint256, bool support) external {
        uint256 voteId;
        for (uint256 i; i < ACTORS && voteId == 0; i++) {
            uint256 id = community.activeRemovalVoteId(actors[i]);
            if (
                id != 0 && !community.isMember(actors[i])
                    && community.seatStateOf(actors[i]) == ICommunity.SeatState.Active
            ) {
                voteId = id; // frozen: the vote is unresolved
            }
        }
        if (voteId == 0) return;
        tries["voteOnRemoval"]++;
        if (_ballot(voteId, actorSeed, support)) lands["voteOnRemoval"]++;
    }

    function executeRemoval(uint256 targetSeed) external {
        address target = _pickActor(targetSeed);
        if (community.activeRemovalVoteId(target) == 0) return;

        tries["executeRemoval"]++;
        try community.executeRemoval(target) {
            _members.remove(target);
            ghostState[target] = uint8(ICommunity.SeatState.Suspended);
            lands["executeRemoval"]++;
        } catch {}
    }

    function warp(uint256 secondsSeed) external {
        uint256 delta = bound(secondsSeed, 1, 30 days);
        vm.warp(block.timestamp + delta);
        lands["warp"]++;
    }
}

/// Deploys the same directly-deployed (no clone) Community + mock siblings fixture as
/// Community.t.sol / CommunityVotes.t.sol, with a real `Seats`, then drives it exclusively through SeatHandler so every
/// call sequence the fuzzer explores is precondition-guarded (no reverts to discard).
contract SeatsInvariantTest is StdInvariant, Test {
    Config config;
    MockUSDC usdc;
    MockVault vault;
    MockCreditCoreLeg core;
    Community community;
    Seats seats;
    SeatHandler handler;

    address owner = makeAddr("owner");
    address treasury = makeAddr("treasury");
    address steward = makeAddr("steward");

    /// This test contract is the community's factory (`factory: address(this)` below), so it
    /// answers the two factory reads the community makes, as `test/Community.t.sol` does:
    /// `_split`'s community id plus one, and `forfeit()`'s ledger, zero so the vault gate stays
    /// off here. It is also the factory `Seats` trusts, so it registers the community.
    function communityIdOf(address) external pure returns (uint256) {
        return 1;
    }

    function ledgerOf(address) external pure returns (address) {
        return address(0);
    }

    function setUp() public {
        usdc = new MockUSDC();
        ComplianceRegistry registry = new ComplianceRegistry(address(this));
        vm.prank(steward);
        registry.attest(1);
        vm.prank(owner);
        config = new Config(address(usdc), treasury, address(registry));
        vault = new MockVault();
        // The mint's community leg goes to `config.creditCore()`, and `_split` reverts
        // `CreditCoreUnset` without one. When this fixture wired none, so every handler
        // join() reverted inside its try and the split and membership invariants held vacuously.
        core = new MockCreditCoreLeg(IERC20(address(usdc)));
        vm.prank(owner);
        config.setAddress(K.CREDIT_CORE, address(core));
        community = new Community();
        seats = new Seats(address(this));
        seats.registerCommunity(address(community), 0);

        ICommunityInit.CommunityWiring memory w = ICommunityInit.CommunityWiring({
            config: address(config),
            factory: address(this),
            seats: address(seats),
            community: address(community),
            vault: address(vault),
            creator: steward,
            seatPrice: 50e6,
            name: "Test Community",
            poolType: PoolTypes.CORE
        });
        community.initialize(w);
        vault.initialize(w);

        handler = new SeatHandler(community, seats, config, usdc, vault, core, steward, treasury, owner);

        // Every actor the handler may prank into join() has self-attested. The
        // handler still exercises the blocked path via the compliance registry.
        for (uint256 i = 0; i < handler.ACTORS(); i++) {
            vm.prank(handler.actors(i));
            registry.attest(1);
        }

        targetContract(address(handler));
    }

    function invariant_soulbound() public view {
        // Every actor that ever minted still holds exactly its own seat, whatever its state:
        // nothing burns a seat and nothing moves one. No approval
        // is ever set.
        for (uint256 i = 0; i < handler.ACTORS(); i++) {
            address actor = handler.actors(i);
            bool minted = handler.ghostState(actor) != 0;
            assertEq(seats.balanceOf(actor), minted ? 1 : 0);
            if (minted) {
                uint256 tokenId = handler.ghostToken(actor);
                assertEq(community.tokenOf(actor), tokenId, "tokenOf is kept");
                assertEq(seats.ownerOf(tokenId), actor, "the seat stays in the wallet");
                assertEq(seats.getApproved(tokenId), address(0));
            }
        }
        assertEq(seats.balanceOf(steward), 1);
        assertEq(seats.getApproved(community.tokenOf(steward)), address(0));
    }

    function invariant_splitConserves() public view {
        // The steward leg lands in the steward's wallet balance; sumToSteward is a ghost
        // accumulator of that wallet-balance delta per join(), not a vault credit. The three
        // legs must still sum to every price ever paid, to the wei.
        assertEq(handler.sumToSteward() + handler.sumToPool() + handler.sumToTreasury(), handler.sumMinted());
    }

    function invariant_memberCountMatchesGhost() public view {
        // seats.memberCount() == the Active actors (+1 for the founding steward's seat, which no
        // handler forfeits or targets). Frozen members are Active and are counted.
        uint256 expected = handler.memberSetLength();
        if (community.seatStateOf(steward) == ICommunity.SeatState.Active) expected += 1;
        assertEq(community.memberCount(), expected);
    }

    function invariant_stewardIsMemberOrVacant() public view {
        // stewardVacant() || isMember(steward()).
        assertTrue(community.stewardVacant() || community.isMember(community.steward()));
    }

    /// A handover past acceptance and a vote to remove the host are never live at once, so a
    /// host facing removal cannot hand the seat on.
    function invariant_neverALiveHandoverAndAHostRemovalVote() public view {
        bool liveHandover = community.pendingHandover().acceptedAt != 0;
        assertFalse(liveHandover && _hostRemovalOpen(), "a handover is live during a host removal vote");
    }

    /// A vote to remove the host is open until it fails at its deadline, or until it passes and
    /// executes, which clears the slot.
    function _hostRemovalOpen() internal view returns (bool) {
        uint256 id = community.activeStewardVoteId();
        if (id == 0) return false;
        ICommunity.VoteTally memory t = community.voteTally(id);
        if (t.kind != ICommunity.VoteKind.StewardRemoval) return false;
        if (block.timestamp <= t.deadline) return true;
        return t.yes >= t.minYes && uint256(t.yes) * 10_000 >= uint256(t.thresholdBps) * t.denominator;
    }

    function invariant_priceInRangeAtExecution() public view {
        // seatPrice is sticky once set and the floor (see handler.raiseFloor()) can rise
        // independently afterward with no vote in flight, so "seatPrice in range" does not
        // hold as a standing property of live state - only at the instant a price vote
        // executes, which is what executeSeatPriceVote()'s live recheck guarantees.
        // See handler.priceOutOfRangeAtExecution for the property this actually checks.
        assertFalse(handler.priceOutOfRangeAtExecution());
    }

    /// `Seats` is the one record of a seat's state, and `Community` answers from it: for every
    /// wallet, the community's reads agree with the token, membership is exactly an Active seat
    /// that is not frozen, and the Active seats counted one by one equal `memberCount`.
    function invariant_seatsAndCommunityAgree() public view {
        uint256 n = handler.ACTORS();
        for (uint256 i = 0; i <= n; i++) {
            address who = i == n ? steward : handler.actors(i);
            uint256 tokenId = seats.seatOf(address(community), who);
            assertEq(community.tokenOf(who), tokenId, "the token id");
            if (tokenId == 0) {
                assertEq(uint8(community.seatStateOf(who)), uint8(ICommunity.SeatState.None));
                assertFalse(community.isMember(who));
                continue;
            }
            ICommunity.SeatState state = seats.seatInfo(tokenId).state;
            assertEq(uint8(community.seatStateOf(who)), uint8(state), "the state");
            assertEq(community.mintedAt(who), seats.seatInfo(tokenId).mintedAt, "the mint time");
            assertEq(
                community.isMember(who),
                state == ICommunity.SeatState.Active && !community.isFrozen(who),
                "membership is an Active seat that is not frozen"
            );
        }
        uint256 active;
        uint256 count = seats.seatCount(address(community));
        for (uint256 number = 1; number <= count; number++) {
            if (seats.seatInfo(seats.seatAt(address(community), number)).state == ICommunity.SeatState.Active) {
                active++;
            }
        }
        assertEq(active, community.memberCount(), "the Active count is memberCount");
    }

    function invariant_seatStateOnlyByVoteOrForfeit() public view {
        // The ghost changes only on a landed join(), forfeit() or executeRemoval(), so a state
        // that differs from it means a write path outside those three, including any path out
        // of Suspended or Left.
        for (uint256 i = 0; i < handler.ACTORS(); i++) {
            address actor = handler.actors(i);
            assertEq(uint8(community.seatStateOf(actor)), handler.ghostState(actor));
        }
    }

    function invariant_aKeptSeatBarsRejoining() public view {
        assertFalse(handler.rejoinLanded(), "a wallet holding a seat minted a second one");
    }

    function invariant_aFrozenMemberCannotForfeit() public view {
        assertFalse(handler.forfeitWhileFrozenLanded(), "a frozen member left");
    }

    function _assertAllInvariants() internal view {
        invariant_soulbound();
        invariant_splitConserves();
        invariant_memberCountMatchesGhost();
        invariant_stewardIsMemberOrVacant();
        invariant_neverALiveHandoverAndAHostRemovalVote();
        invariant_priceInRangeAtExecution();
        invariant_seatsAndCommunityAgree();
        invariant_seatStateOnlyByVoteOrForfeit();
        invariant_aKeptSeatBarsRejoining();
        invariant_aFrozenMemberCannotForfeit();
    }

    /// Six actors join and season, and the host nominates the first, who accepts.
    function _acceptedHandover() internal {
        for (uint256 i; i < 6; i++) {
            handler.join(i);
        }
        handler.warp(config.memberSeasoningWindow());
        handler.nominateSuccessor(0);
        handler.acceptNomination();
        assertGt(community.pendingHandover().acceptedAt, 0, "the handover is live");
    }

    /// The fuzzer reaches this ordering rarely, so it is driven here through the same handler:
    /// a vote to remove the host proposed while a handover is live must end the handover.
    function test_sequence_aHostRemovalVoteEndsALiveHandover() public {
        _acceptedHandover();
        handler.proposeRemoveSteward(1);
        assertGt(community.activeStewardVoteId(), 0, "the removal vote is open");
        _assertAllInvariants();
    }

    /// The same for completion: a nominee who left before the period ended never becomes host.
    function test_sequence_aNomineeWhoLeftNeverBecomesHost() public {
        _acceptedHandover();
        handler.forfeit(0);
        handler.warp(config.memberSeasoningWindow());
        handler.completeHandover();
        _assertAllInvariants();
    }

    /// A fixed 3000-step deterministic replay, so the per-method landed counts are stable
    /// numbers (the CreditCoreDebt replay's precedent). Every
    /// invariant above is asserted at the end.
    function test_replay3000Steps_reportsPerMethodLandedCounts() public {
        bytes32 seed = keccak256("qudi.seats-replay.v1");
        for (uint256 step; step < 3000; step++) {
            uint256 a0 = uint256(keccak256(abi.encode(seed, step, 0)));
            uint256 a1 = uint256(keccak256(abi.encode(seed, step, 1)));
            uint256 a2 = uint256(keccak256(abi.encode(seed, step, 2)));
            // Weights out of 40. Forfeit is one step in 160, because every landed forfeit retires
            // an actor for good. Host ballots get six buckets: a host vote needs two thirds of
            // the seasoned seats inside one window, and at fewer it never carried, so the
            // election behind it never ran either. Cancelling and resigning are one step in 160
            // each, and objecting one in 80, so most nominations run their course; at two
            // buckets, objections blocked every handover before its period ended.
            uint256 pick = a0 % 40;
            bool yes = a0 % 4 != 0; // three in four ballots are yes, so some votes carry
            if (pick < 3) {
                handler.join(a1);
            } else if (pick == 3) {
                if (a2 % 4 == 0) handler.forfeit(a1);
            } else if (pick < 6) {
                handler.proposeSeatPrice(a1);
            } else if (pick < 9) {
                handler.voteOnPrice(a1, yes);
            } else if (pick == 9) {
                handler.executeSeatPriceVote();
            } else if (pick < 12) {
                handler.proposeRemoveSteward(a1);
            } else if (pick < 18) {
                handler.voteOnSteward(a1, yes);
            } else if (pick == 18) {
                handler.electSteward(a1);
            } else if (pick == 19) {
                handler.executeRemoveSteward();
            } else if (pick < 22) {
                handler.proposeRemoval(a1);
            } else if (pick < 28) {
                handler.voteOnRemoval(a1, a2, a0 % 2 == 0); // one in two: removals are rarer
            } else if (pick == 28) {
                handler.executeRemoval(a1);
            } else if (pick < 32) {
                handler.warp(a1 % 1 days);
            } else if (pick == 32) {
                handler.nominateSuccessor(a1);
            } else if (pick == 33) {
                handler.acceptNomination();
            } else if (pick == 34) {
                if (a2 % 2 == 0) handler.objectToHandover(a1);
            } else if (pick < 37) {
                handler.completeHandover();
            } else if (pick == 37) {
                if (a2 % 4 == 0) handler.cancelNomination();
            } else if (pick == 38) {
                if (a2 % 4 == 0) handler.resignHost();
            } else {
                handler.warp(a1 % 1 days);
            }
        }
        _assertAllInvariants();

        string[20] memory names = [
            "join",
            "rejoin",
            "forfeit",
            "proposeSeatPrice",
            "voteOnPrice",
            "executeSeatPriceVote",
            "proposeRemoveSteward",
            "voteOnSteward",
            "electSteward",
            "executeRemoveSteward",
            "proposeRemoval",
            "voteOnRemoval",
            "executeRemoval",
            "nominateSuccessor",
            "acceptNomination",
            "objectToHandover",
            "completeHandover",
            "cancelNomination",
            "resignHost",
            "warp"
        ];
        for (uint256 i; i < 20; i++) {
            bytes32 k = bytes32(bytes(names[i]));
            console.log(names[i], handler.lands(k), "/", handler.tries(k));
        }
        // Not 0 compared to 0: each state-changing path landed, and each refusal was tried.
        assertGt(handler.lands("join"), 0, "joins landed");
        assertGt(handler.lands("forfeit"), 0, "forfeits landed");
        assertGt(handler.lands("proposeRemoval"), 0, "removal proposals landed");
        assertGt(handler.lands("voteOnRemoval"), 0, "removal ballots landed");
        assertGt(handler.lands("executeRemoval"), 0, "removals executed");
        // The vote paths behind the price floor and the steward invariant, which an
        // earlier replay never reached.
        assertGt(handler.lands("executeSeatPriceVote"), 0, "a price vote carried");
        assertGt(handler.lands("executeRemoveSteward"), 0, "a host vote carried");
        assertGt(handler.lands("electSteward"), 0, "an election started");
        // The handover paths, each landed at least once.
        assertGt(handler.lands("nominateSuccessor"), 0, "nominations landed");
        assertGt(handler.lands("acceptNomination"), 0, "acceptances landed");
        assertGt(handler.lands("objectToHandover"), 0, "objections landed");
        assertGt(handler.lands("completeHandover"), 0, "a handover completed or failed");
        assertGt(handler.lands("cancelNomination"), 0, "a nomination was cancelled");
        assertGt(handler.lands("resignHost"), 0, "a host resigned");
        assertGt(handler.tries("rejoin"), 0, "rejoins attempted");
        assertEq(handler.lands("rejoin"), 0, "and none landed");
    }
}
