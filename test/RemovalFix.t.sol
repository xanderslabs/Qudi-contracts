// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {Config} from "../src/Config.sol";
import {ComplianceRegistry} from "../src/ComplianceRegistry.sol";
import {Community} from "../src/Community.sol";
import {Seats} from "../src/Seats.sol";
import {ICommunity} from "../src/interfaces/ICommunity.sol";
import {ICommunityInit} from "../src/interfaces/ICommunityInit.sol";
import {VenueIds} from "./helpers/VenueIds.sol";
import {ConfigKeys as K} from "../src/ConfigKeys.sol";
import {MockUSDC} from "./mocks/MockUSDC.sol";
import {MockVault, MockCreditCoreLeg} from "./mocks/MockSeatSiblings.sol";
import {InviteSigner} from "./helpers/InviteSigner.sol";

/// A vote's threshold counts the Active seats seasoned at its start, minus a removal's target; a
/// vote needs at least 3 yes votes; and a host cannot freeze voters while a vote to remove the
/// host runs, nor can a failed host vote be re-proposed inside the cooldown.
///
/// A directly deployed community wired to a real `Seats` and mock siblings, as `Community.t.sol` is: every proof here
/// is about the vote arithmetic and the seat states, and none moves money past the seat mint.
contract RemovalFixTest is InviteSigner {
    Config config;
    ComplianceRegistry registry;
    MockUSDC usdc;
    MockVault vault;
    MockCreditCoreLeg core;
    Community community;
    Seats seats;

    address owner = makeAddr("owner");
    address treasury = makeAddr("treasury");
    address host = _keyed("host");

    uint8 constant ACTIVE = 1;

    /// This test contract is the community's factory, as in `Community.t.sol`: the community id
    /// for `_split`, and no ledger, so `forfeit()`'s vault gate stays off. It is also the factory
    /// `Seats` trusts.
    function communityIdOf(address) external pure returns (uint256) {
        return 1;
    }

    function ledgerOf(address) external pure returns (address) {
        return address(0);
    }

    function setUp() public {
        vm.warp(1000 days);
        usdc = new MockUSDC();
        registry = new ComplianceRegistry(address(this));
        vm.prank(host);
        registry.attest(1);
        vm.prank(owner);
        config = new Config(address(usdc), treasury, address(registry));
        vault = new MockVault();
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
            creator: host,
            seatPrice: 50e6,
            name: "Fix Community",
            poolType: VenueIds.CORE
        });
        community.initialize(w);
        vault.initialize(w);
    }

    // ---- adapter: begin ----
    // Every name these proofs add lives here, so the proofs can run against the base with this
    // block swapped. Nothing outside it names an error the base
    // does not have.

    bytes4 internal E_HOST_VOTE_OPEN = ICommunity.HostVoteOpen.selector;
    bytes4 internal E_HOST_VOTE_COOLDOWN = ICommunity.HostVoteCooldown.selector;
    // ---- adapter: end ----

    // ---- helpers ----

    function _m(uint256 i) internal pure returns (address) {
        return address(uint160(uint256(keccak256(abi.encode("fix-member", i)))));
    }

    function _join(address who) internal {
        vm.prank(who);
        registry.attest(1);
        uint256 price = community.seatPrice();
        usdc.mint(who, price);
        vm.prank(who);
        usdc.approve(address(community), price);
        _joinAs(address(community), who);
    }

    /// Joins members `from` to `to - 1`.
    function _joinRange(uint256 from, uint256 to) internal {
        for (uint256 i = from; i < to; i++) {
            _join(_m(i));
        }
    }

    function _season() internal {
        vm.warp(block.timestamp + config.memberSeasoningWindow());
    }

    function _window() internal view returns (uint64 w) {
        (, w) = config.communityVote();
    }

    function _hostWindow() internal view returns (uint64 w) {
        (, w) = config.hostVote();
    }

    function _yes(uint256 voteId, address who) internal {
        vm.prank(who);
        community.castVote(voteId, true);
    }

    function _proposeRemoval(address m) internal returns (uint256 voteId) {
        vm.prank(host);
        community.proposeRemoval(m);
        voteId = community.activeRemovalVoteId(m);
    }

    /// Members 0 to 2 and the host carry a removal of `m`, and it executes.
    function _remove(address m) internal {
        uint256 voteId = _proposeRemoval(m);
        _yes(voteId, host);
        for (uint256 i; i < 3; i++) {
            if (_m(i) != m) _yes(voteId, _m(i));
        }
        vm.warp(block.timestamp + _window() + 1);
        community.executeRemoval(m);
    }

    // =============================================================================
    // Proof 1: newcomers no longer block
    // =============================================================================

    /// The host and three members are seasoned; seven more were minted a day before the vote, and
    /// the target is one of the seven. The denominator is 4, so 3 yes votes clear the community
    /// threshold: 3 x 10,000 = 30,000 >= 5,001 x 4 = 20,004. Counting every seat, it would be 11,
    /// and 30,000 < 5,001 x 11 = 55,011.
    function test_fix1_newcomersDoNotBlockARemoval() public {
        _joinRange(0, 3);
        _season();
        _joinRange(3, 10);
        vm.warp(block.timestamp + 1 days);
        address target = _m(9);

        uint256 voteId = _proposeRemoval(target);
        assertEq(community.voteTally(voteId).denominator, 4, "the host and three seasoned members");
        _yes(voteId, _m(0));
        _yes(voteId, _m(1));
        _yes(voteId, _m(2));
        vm.warp(block.timestamp + _window() + 1);
        community.executeRemoval(target);
        assertFalse(community.isMember(target), "carried by three of the four who could vote");
    }

    // =============================================================================
    // Proof 2: packing no longer blocks
    // =============================================================================

    /// The host and six members are seasoned. The host mints five seats the day before members
    /// propose removing the host. The six vote yes against a denominator of 7:
    /// 6 x 10,000 = 60,000 >= 6,667 x 7 = 46,669. Counting the packed seats it would be 12, and
    /// 60,000 < 6,667 x 12 = 80,004.
    function test_fix2_packedSeatsDoNotBlockAHostVote() public {
        _joinRange(0, 6);
        _season();
        _joinRange(100, 105); // the host's five
        vm.warp(block.timestamp + 1 days);

        vm.prank(_m(0));
        community.proposeRemoveSteward();
        uint256 voteId = community.activeStewardVoteId();
        assertEq(community.voteTally(voteId).denominator, 7, "the host and six seasoned members");
        for (uint256 i; i < 6; i++) {
            _yes(voteId, _m(i));
        }
        vm.prank(host);
        community.castVote(voteId, false);
        vm.warp(block.timestamp + _hostWindow() + 1);
        community.executeRemoveSteward();
        assertTrue(community.stewardVacant(), "six of the seven who could vote removed the host");
    }

    // =============================================================================
    // Proof 3: the removal target is not counted
    // =============================================================================

    function test_fix3_aSeasonedTargetIsNotCounted_anUnseasonedOneChangesNothing() public {
        _joinRange(0, 4); // host plus four: five seasoned
        _season();
        _join(_m(50)); // unseasoned
        vm.warp(block.timestamp + 1 days);

        vm.prank(host);
        community.proposeSeatPrice(80e6);
        assertEq(community.voteTally(community.activePriceVoteId()).denominator, 5, "a price vote counts the five");

        assertEq(community.voteTally(_proposeRemoval(_m(3))).denominator, 4, "a seasoned target is one fewer");
        assertEq(community.voteTally(_proposeRemoval(_m(50))).denominator, 5, "an unseasoned target was never counted");
    }

    // =============================================================================
    // Proof 4: departed seats are not counted
    // =============================================================================

    /// Six seasoned seats; one leaves and one is suspended before the vote; a seventh seat minted
    /// afterwards is unseasoned. The denominator is 4. A seasoned member who leaves after the vote
    /// starts does not change it.
    function test_fix4_departedSeatsAreNotCounted() public {
        _joinRange(0, 5); // host plus five
        _season();
        vm.prank(_m(4));
        community.forfeit();
        _remove(_m(3));
        _join(_m(60));
        vm.warp(block.timestamp + 1 days);

        vm.prank(host);
        community.proposeSeatPrice(80e6);
        uint256 voteId = community.activePriceVoteId();
        assertEq(
            community.voteTally(voteId).denominator, 4, "host and members 0 to 2: Left, Suspended and new are not in"
        );

        vm.prank(_m(2));
        community.forfeit();
        assertEq(community.voteTally(voteId).denominator, 4, "a departure after the start does not move it");
    }

    // =============================================================================
    // Proof 5: exact under scale
    // =============================================================================

    address[] internal _holders; // index i holds token id i + 1

    function _brute(uint256 window, address target) internal view returns (uint256 n) {
        for (uint256 i; i < _holders.length; i++) {
            address h = _holders[i];
            if (uint8(community.seatStateOf(h)) != ACTIVE) continue;
            if (uint256(community.mintedAt(h)) + window > block.timestamp) continue;
            if (h == target) continue;
            n++;
        }
    }

    function _mintAndMaybeLeave(uint256 i) internal {
        _join(_m(i));
        _holders.push(_m(i));
        vm.warp(block.timestamp + uint256(keccak256(abi.encode("gap", i))) % 6 hours);
    }

    /// 200 seats minted over time, some in the same second; 4 removed by vote and 36 who left, in
    /// mixed order. For cutoffs at, one second before, and one second after six mint times, each
    /// removal's stored denominator equals a count over every seat done here.
    function test_fix5_theDenominatorIsExactAt200SeatsWith40Departures() public {
        // Up to 160 seats are Active at once here, above the launch member cap.
        vm.prank(owner);
        config.set(K.MEMBER_CAP, 200);
        _holders.push(host);
        for (uint256 i = 1; i < 20; i++) {
            _mintAndMaybeLeave(i);
        }
        _season();
        // Four removals at once: 20 seasoned seats, 19 counted with the target out, so 10 yes.
        address[4] memory removed = [_m(3), _m(7), _m(11), _m(15)];
        uint256[4] memory ids;
        for (uint256 r; r < 4; r++) {
            ids[r] = _proposeRemoval(removed[r]);
        }
        for (uint256 r; r < 4; r++) {
            _yes(ids[r], host);
            uint256 cast = 1;
            for (uint256 i = 1; i < 20 && cast < 12; i++) {
                if (_m(i) == removed[0] || _m(i) == removed[1] || _m(i) == removed[2] || _m(i) == removed[3]) continue;
                _yes(ids[r], _m(i));
                cast++;
            }
        }
        vm.warp(block.timestamp + _window() + 1);
        for (uint256 r; r < 4; r++) {
            community.executeRemoval(removed[r]);
        }
        // 180 more, with a departure every fifth mint, picked from anywhere earlier.
        uint256 left;
        for (uint256 i = 20; i < 200; i++) {
            _mintAndMaybeLeave(i);
            if (i % 5 == 0) {
                uint256 j = uint256(keccak256(abi.encode("leaver", i))) % i;
                while (_m(j) == host || uint8(community.seatStateOf(_m(j))) != ACTIVE) {
                    j = (j + 1) % i;
                }
                vm.prank(_m(j));
                community.forfeit();
                left++;
            }
        }
        assertEq(_holders.length, 200, "200 seats");
        assertEq(left, 36, "36 left, and 4 were removed");
        // Two days, so the smallest window set below (the last mint, one second after) stays above
        // MEMBER_SEASONING_WINDOW's one-day floor.
        vm.warp(block.timestamp + 2 days);

        uint256[6] memory at = [uint256(1), 2, 40, 100, 160, 199]; // indexes into _holders
        uint256 busiest;
        uint256 nextTarget = 199;
        for (uint256 c; c < 6; c++) {
            uint256 t = community.mintedAt(_holders[at[c]]);
            for (uint256 d; d < 3; d++) {
                // d = 0: the cutoff is at the mint time; 1: one second before it; 2: one after.
                uint256 window = block.timestamp - t + (d == 1 ? 1 : 0) - (d == 2 ? 1 : 0);
                vm.prank(owner);
                config.set(K.MEMBER_SEASONING_WINDOW, window);
                while (
                    _holders[nextTarget] == host || uint8(community.seatStateOf(_holders[nextTarget])) != ACTIVE
                        || community.activeRemovalVoteId(_holders[nextTarget]) != 0
                ) {
                    nextTarget--;
                }
                address target = _holders[nextTarget];
                uint256 before = gasleft();
                vm.prank(host);
                community.proposeRemoval(target);
                uint256 used = before - gasleft();
                if (used > busiest) busiest = used;
                uint256 voteId = community.activeRemovalVoteId(target);
                assertEq(community.voteTally(voteId).denominator, _brute(window, target), "stored equals counted");
                nextTarget -= 7; // targets spread over seasoned and unseasoned seats
            }
        }
        emit log_named_uint("busiest proposeRemoval gas, 200 seats", busiest);
    }

    // =============================================================================
    // Proof 6: at least 3 yes votes
    // =============================================================================

    function test_fix6_aVoteNeedsThreeYesVotes() public {
        // A denominator of 0: nothing is seasoned in the first 14 days, and no ballot is needed to
        // clear 0 >= 0.
        vm.prank(host);
        community.proposeSeatPrice(80e6);
        vm.warp(block.timestamp + _window() + 1);
        vm.expectRevert(ICommunity.NotPassed.selector);
        community.executeSeatPriceVote();

        // A denominator of 2, both yes: 2 x 10,000 >= 5,001 x 2 clears the threshold, not the floor.
        _join(_m(0));
        _season();
        vm.prank(host);
        community.proposeSeatPrice(90e6);
        uint256 voteId = community.activePriceVoteId();
        assertEq(community.voteTally(voteId).denominator, 2);
        _yes(voteId, host);
        _yes(voteId, _m(0));
        vm.warp(block.timestamp + _window() + 1);
        vm.expectRevert(ICommunity.NotPassed.selector);
        community.executeSeatPriceVote();
        assertEq(community.seatPrice(), 50e6);

        // A host who is the only seasoned member cannot remove anyone alone.
        _joinRange(1, 4);
        vm.warp(block.timestamp + 1 days);
        vm.prank(_m(0));
        community.forfeit();
        uint256 removal = _proposeRemoval(_m(1));
        assertEq(community.voteTally(removal).denominator, 1, "the host alone");
        _yes(removal, host);
        vm.warp(block.timestamp + _window() + 1);
        vm.expectRevert(ICommunity.NotPassed.selector);
        community.executeRemoval(_m(1));
    }

    // =============================================================================
    // Proof 7: no removal while a host vote is open
    // =============================================================================

    function test_fix7_noRemovalWhileAHostVoteIsOpen_thenItFails() public {
        _joinRange(0, 4);
        _season();
        vm.prank(_m(0));
        community.proposeRemoveSteward();

        vm.expectRevert(E_HOST_VOTE_OPEN);
        vm.prank(host);
        community.proposeRemoval(_m(3));

        vm.warp(block.timestamp + _hostWindow() + 1); // nobody voted: it failed
        _proposeRemoval(_m(3));
        assertTrue(community.isFrozen(_m(3)), "after a failed host vote the host may propose again");
    }

    function test_fix7_noRemovalWhileAHostVoteIsOpen_thenItPasses() public {
        _joinRange(0, 4);
        _season();
        vm.prank(_m(0));
        community.proposeRemoveSteward();
        uint256 hostVote = community.activeStewardVoteId();
        for (uint256 i; i < 4; i++) {
            _yes(hostVote, _m(i));
        }
        vm.warp(block.timestamp + _hostWindow() + 1);

        vm.expectRevert(E_HOST_VOTE_OPEN); // passed and not executed is still unresolved
        vm.prank(host);
        community.proposeRemoval(_m(3));

        community.executeRemoveSteward();
        vm.prank(_m(0));
        community.electSteward(_m(0));
        uint256 election = community.activeStewardVoteId();
        for (uint256 i; i < 4; i++) {
            _yes(election, _m(i)); // 4 x 10,000 >= 6,667 x 5
        }
        vm.warp(block.timestamp + _hostWindow() + 1);
        community.executeRemoveSteward();
        assertEq(community.steward(), _m(0));

        vm.prank(_m(0));
        community.proposeRemoval(_m(3));
        assertTrue(community.isFrozen(_m(3)), "the next host may propose once the host vote passed");
    }

    // =============================================================================
    // Proof 8: the host-vote cooldown
    // =============================================================================

    function test_fix8_aFailedHostVoteCoolsDown_aPassedOneDoesNot() public {
        _joinRange(0, 4);
        _season();
        vm.prank(_m(0));
        community.proposeRemoveSteward();
        uint256 deadline = block.timestamp + _hostWindow();
        vm.warp(deadline + 1);

        vm.warp(deadline + config.removalReproposeCooldown() - 1);
        vm.expectRevert(E_HOST_VOTE_COOLDOWN);
        vm.prank(_m(1));
        community.proposeRemoveSteward();

        vm.warp(deadline + config.removalReproposeCooldown());
        vm.prank(_m(1));
        community.proposeRemoveSteward();
        uint256 second = community.activeStewardVoteId();
        for (uint256 i; i < 4; i++) {
            _yes(second, _m(i));
        }
        vm.warp(block.timestamp + _hostWindow() + 1);
        community.executeRemoveSteward();

        vm.prank(_m(0));
        community.electSteward(_m(1)); // a passed host vote starts no cooldown
        assertTrue(community.activeStewardVoteId() != second);
    }

    // =============================================================================
    // Proof 9: a pre-emptive freeze buys at most a week
    // =============================================================================

    /// The host freezes three likely voters. Members wait out those votes, then carry a host vote,
    /// and the host can freeze nobody during it: not the same three, and not anyone else.
    function test_fix9_aPreEmptiveFreezeBuysAtMostAWeek() public {
        _joinRange(0, 7); // host plus seven seasoned
        _season();
        for (uint256 i; i < 3; i++) {
            _proposeRemoval(_m(i));
        }
        assertFalse(community.isMember(_m(0)));
        vm.warp(block.timestamp + _window() + 1); // nobody but the host would vote: all three fail
        assertTrue(
            community.isMember(_m(0)) && community.isMember(_m(1)) && community.isMember(_m(2)), "a week, then back"
        );

        vm.prank(_m(3));
        community.proposeRemoveSteward();
        uint256 hostVote = community.activeStewardVoteId();
        for (uint256 i; i < 7; i++) {
            _yes(hostVote, _m(i)); // 7 x 10,000 >= 6,667 x 8
        }
        for (uint256 i; i < 3; i++) {
            vm.expectRevert(E_HOST_VOTE_OPEN);
            vm.prank(host);
            community.proposeRemoval(_m(i));
        }
        vm.expectRevert(E_HOST_VOTE_OPEN);
        vm.prank(host);
        community.proposeRemoval(_m(6));

        vm.warp(block.timestamp + _hostWindow() + 1);
        community.executeRemoveSteward();
        assertTrue(community.stewardVacant(), "the host vote carried");
    }

    // =============================================================================
    // Proof 10 (settled from the report): isSeasoned needs an Active seat
    // =============================================================================

    function test_fix10_isSeasonedIsFalseForASuspendedOrLeftSeat() public {
        _joinRange(0, 5);
        _season();
        vm.prank(_m(4));
        community.forfeit();
        _remove(_m(3));
        vm.warp(block.timestamp + 30 days);
        assertTrue(community.isSeasoned(_m(0)), "an Active seat past the window");
        assertFalse(community.isSeasoned(_m(4)), "Left");
        assertFalse(community.isSeasoned(_m(3)), "Suspended");
    }
}
