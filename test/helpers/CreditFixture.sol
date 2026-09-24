// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.30;

import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {Config} from "../../src/Config.sol";
import {IConfig} from "../../src/interfaces/IConfig.sol";
import {ConfigKeys as K} from "../../src/ConfigKeys.sol";
import {ComplianceRegistry} from "../../src/ComplianceRegistry.sol";
import {Community} from "../../src/Community.sol";
import {CommunityFactory} from "../../src/CommunityFactory.sol";
import {ICommunityFactory} from "../../src/interfaces/ICommunityFactory.sol";
import {Seats} from "../../src/Seats.sol";
import {Ledger} from "../../src/Ledger.sol";
import {ILedger} from "../../src/interfaces/ILedger.sol";
import {Venue} from "../../src/Venue.sol";
import {CreditCore} from "../../src/CreditCore.sol";
import {ICreditCore} from "../../src/interfaces/ICreditCore.sol";
import {CreditStanding} from "../../src/CreditStanding.sol";
import {ICreditStanding} from "../../src/interfaces/ICreditStanding.sol";
import {CloneImpactSource} from "../../src/CloneImpactSource.sol";
import {MockUSDC} from "../mocks/MockUSDC.sol";
import {MockStrategy} from "../mocks/MockStrategy.sol";
import {MockImpactSource} from "../mocks/MockImpactSource.sol";
import {InviteSigner} from "./InviteSigner.sol";
import {VenueIds} from "./VenueIds.sol";

/// The whole credit stack as a deployment wires it: the real factory, `Seats`, `Community` and
/// `Ledger` clones, one Flex `Venue` over a `MockStrategy` so a test can make yield, `CreditStanding`
/// with the seat and yield sources registered, and `CreditCore`. This contract is the owner of
/// everything, which stands in for the timelock.
///
/// Nothing here funds `CreditCore` with Qudi money. A community's balance comes from its seat legs,
/// its yield legs, or an explicit `_grant`, so a test that lends shows where every dollar came from.
abstract contract CreditFixture is InviteSigner {
    MockUSDC usdc;
    Config config;
    ComplianceRegistry registry;
    Seats seats;
    CommunityFactory factory;
    Venue flex;
    MockStrategy flexStrategy;
    CreditStanding standing;
    CreditCore core;
    CloneImpactSource seatSource;
    CloneImpactSource yieldSource;
    MockImpactSource extra;

    address treasury = makeAddr("treasury");
    address operator = makeAddr("operator");
    address allocator = makeAddr("allocator");
    address stranger = makeAddr("stranger");

    bytes32 constant AGREEMENT = keccak256("qudi credit agreement v1");

    uint256 internal _people;

    function setUp() public virtual {
        vm.warp(1000 days);
        usdc = new MockUSDC();
        registry = new ComplianceRegistry(address(this));
        config = new Config(address(usdc), treasury, address(registry));

        address communityImpl = address(new Community());
        address ledgerImpl = address(new Ledger());
        address predicted = vm.computeCreateAddress(address(this), vm.getNonce(address(this)) + 1);
        seats = new Seats(predicted, IConfig(address(config)));
        factory = new CommunityFactory(address(config), address(seats), communityImpl, ledgerImpl, address(this));
        require(address(factory) == predicted, "factory precompute mismatch");

        flex = new Venue(IERC20(address(usdc)), IConfig(address(config)), address(factory), address(this), "F", "F");
        flex.setLabels(VenueIds.labels(VenueIds.FLEX));
        flexStrategy = new MockStrategy(IERC20(address(usdc)), address(flex));
        flex.addStrategy(address(flexStrategy), 0);
        flex.setCap(address(flexStrategy), type(uint256).max);
        address[] memory list = new address[](1);
        uint16[] memory bps = new uint16[](1);
        list[0] = address(flexStrategy);
        bps[0] = 10_000;
        flex.setWeights(list, bps);
        factory.addVenue(address(flex));

        standing = new CreditStanding(IConfig(address(config)), address(factory), address(this));
        core = new CreditCore(
            IERC20(address(usdc)),
            IConfig(address(config)),
            address(factory),
            address(this),
            operator,
            allocator,
            ICreditStanding(address(standing))
        );
        standing.setCreditCore(address(core));
        config.setAddress(K.CREDIT_CORE, address(core));
        config.setCreditAgreementHash(AGREEMENT);

        seatSource = new CloneImpactSource(ICommunityFactory(address(factory)), false);
        yieldSource = new CloneImpactSource(ICommunityFactory(address(factory)), true);
        standing.addImpactSource(address(seatSource));
        standing.addImpactSource(address(yieldSource));
        extra = new MockImpactSource();
    }

    // ---- people and communities ----

    function _person() internal returns (address who) {
        who = makeAddr(string.concat("person", vm.toString(++_people)));
    }

    function _attest(address who) internal {
        if (registry.isAttested(who)) return;
        vm.prank(who);
        registry.attest(1);
    }

    /// A community at `price` with `size` Active seats: a fresh host and `size - 1` members who
    /// joined through invites and paid the price. Nobody is seasoned yet. `people[0]` is the host.
    function _community(uint256 price, uint256 size)
        internal
        returns (Community c, uint256 id, address[] memory people)
    {
        people = new address[](size);
        people[0] = _person();
        _attest(people[0]);
        vm.prank(people[0]);
        c = Community(factory.createCommunity("Credit Community", price));
        id = factory.communityIdOf(address(c)) - 1;
        for (uint256 i = 1; i < size; i++) {
            people[i] = _person();
            _join(c, people[i]);
        }
    }

    function _join(Community c, address who) internal {
        _attest(who);
        uint256 price = c.seatPrice();
        usdc.mint(who, price);
        vm.prank(who);
        usdc.approve(address(c), price);
        _joinAs(address(c), who);
    }

    function _season() internal {
        vm.warp(block.timestamp + config.memberSeasoningWindow());
    }

    function _ledger(uint256 id) internal view returns (Ledger) {
        return Ledger(factory.ledgerOf(factory.communityAt(id)));
    }

    // ---- money ----

    /// Qudi funds `amount` and grants it to community `id` in one go, so Qudi's unallocated money
    /// is where it started.
    function _grant(uint256 id, uint256 amount) internal {
        usdc.mint(address(this), amount);
        usdc.approve(address(core), amount);
        core.fund(amount);
        vm.prank(allocator);
        core.allocate(id, amount, ICreditCore.AllocationType.Growth);
    }

    function _useExtra() internal {
        standing.addImpactSource(address(extra));
    }

    function _draw(address who, uint256 id, uint256 amount) internal {
        vm.prank(who);
        core.draw(id, amount, AGREEMENT);
    }

    /// Mints what the payment needs, so a test never fails for want of USDC.
    function _settle(address who, uint256 amount) internal {
        usdc.mint(who, amount);
        vm.prank(who);
        usdc.approve(address(core), amount);
        vm.prank(who);
        core.settle(amount);
    }

    function _repayAll(address who) internal {
        _settle(who, core.obligationOf(who).principal);
    }

    function _line(uint256 id, address who) internal view returns (uint256) {
        return core.standingOf(id, who).drawable;
    }

    function _eligible(uint256 id, address who) internal view returns (bool) {
        return core.standingOf(id, who).eligible;
    }

    function _credit(uint256 id) internal view returns (ICreditCore.CommunityCredit memory) {
        return core.communityCreditOf(id);
    }

    function _unallocated() internal view returns (uint256) {
        return core.poolView().unallocated;
    }

    // ---- saving ----

    /// A personal Flex vault for `who` with `amount` in it.
    function _save(uint256 id, address who, uint256 amount) internal returns (uint256 vaultId) {
        Ledger l = _ledger(id);
        usdc.mint(who, amount);
        vm.startPrank(who);
        vaultId = l.createVault(
            ILedger.VaultParams({venueId: VenueIds.FLEX, shared: false, lockedUntil: 0, name: "savings"})
        );
        usdc.approve(address(l), amount);
        l.deposit(vaultId, amount);
        vm.stopPrank();
    }

    /// A gain of `amount` in the Flex strategy, reached over `time`.
    function _gain(uint256 amount, uint256 time) internal {
        usdc.mint(address(this), amount);
        usdc.approve(address(flexStrategy), amount);
        flexStrategy.fund(amount);
        vm.warp(block.timestamp + time);
    }

    /// A pool strategy with `CreditCore` as its one depositor, listed through the owner.
    function _poolStrategy() internal returns (MockStrategy s) {
        s = new MockStrategy(IERC20(address(usdc)), address(core));
        core.addStrategy(address(s));
    }
}
