// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.30;

import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {Config} from "../../src/Config.sol";
import {ConfigKeys as K} from "../../src/ConfigKeys.sol";
import {ComplianceRegistry} from "../../src/ComplianceRegistry.sol";
import {Community} from "../../src/Community.sol";
import {CommunityFactory} from "../../src/CommunityFactory.sol";
import {Seats} from "../../src/Seats.sol";
import {ICommunity} from "../../src/interfaces/ICommunity.sol";
import {ICommunityInit} from "../../src/interfaces/ICommunityInit.sol";
import {MockUSDC} from "../mocks/MockUSDC.sol";
import {MockCreditCoreLeg} from "../mocks/MockSeatSiblings.sol";
import {InviteSigner} from "./InviteSigner.sol";

/// Stands in for a community's ledger where a test only needs `forfeit`'s vault gate to read
/// nothing held.
contract MockMemberLedger is ICommunityInit {
    function initialize(CommunityWiring calldata) external {}

    function personalUnitsOf(address) external pure returns (uint256) {
        return 0;
    }
}

/// The real factory, `Seats` and `Community` clones, with a stub ledger and a stub
/// `CreditCore` that checks each community leg was paid. Every person here has a key, so any of
/// them can sign invites once they hold the host role.
abstract contract MembershipFixture is InviteSigner {
    MockUSDC usdc;
    Config config;
    ComplianceRegistry registry;
    MockCreditCoreLeg core;
    Seats seats;
    CommunityFactory factory;

    address treasury = makeAddr("treasury");
    address host = _keyed("host");
    address ada = _keyed("ada");
    address bem = _keyed("bem");
    address cy = _keyed("cy");
    address dee = _keyed("dee");

    uint256 constant PRICE = 50e6;

    function setUp() public virtual {
        vm.warp(1000 days);
        usdc = new MockUSDC();
        registry = new ComplianceRegistry(address(this));
        config = new Config(address(usdc), treasury, address(registry));
        core = new MockCreditCoreLeg(IERC20(address(usdc)));
        config.setAddress(K.CREDIT_CORE, address(core));

        address communityImpl = address(new Community());
        address ledgerImpl = address(new MockMemberLedger());
        address[3] memory pools;
        for (uint256 i; i < 3; i++) {
            pools[i] = makeAddr(string.concat("pool", vm.toString(i)));
        }
        address predicted = vm.computeCreateAddress(address(this), vm.getNonce(address(this)) + 1);
        seats = new Seats(predicted);
        factory = new CommunityFactory(address(config), address(seats), communityImpl, ledgerImpl, pools);
        assertEq(address(factory), predicted, "Seats is wired to this factory");

        _attest(host);
    }

    function _attest(address who) internal {
        if (registry.isAttested(who)) return;
        vm.prank(who);
        registry.attest(1);
    }

    function _create(address by, uint256 price) internal returns (Community c) {
        _attest(by);
        vm.prank(by);
        c = Community(factory.createCommunity("Test Community", price));
    }

    /// Attests, funds and approves `who` for `c`'s current price, then joins through a fresh
    /// invite from the current host.
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

    function _vote(Community c, uint256 voteId, address who, bool support) internal {
        vm.prank(who);
        c.castVote(voteId, support);
    }

    function _pastWindow() internal {
        vm.warp(block.timestamp + 7 days + 1);
    }
}
