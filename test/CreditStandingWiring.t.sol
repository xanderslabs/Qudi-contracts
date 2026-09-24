// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.30;

import {Ownable} from "openzeppelin-contracts/contracts/access/Ownable.sol";
import {Config} from "../src/Config.sol";
import {IConfig} from "../src/interfaces/IConfig.sol";
import {CreditStanding} from "../src/CreditStanding.sol";
import {ICreditStanding} from "../src/interfaces/ICreditStanding.sol";
import {CreditFixture} from "./helpers/CreditFixture.sol";
import {MockCreditCoreWiring} from "./helpers/MockCreditCoreWiring.sol";
import {MockUSDC} from "./mocks/MockUSDC.sol";

/// `CreditStanding` is wired to `CreditCore` once, by the owner, and only to one built on the same
/// factory and config that points back at it. Standing and debt computed against different worlds
/// would have nothing to catch them.
contract CreditStandingWiringTest is CreditFixture {
    function test_setCreditCore_revertsOnFactoryOrConfigMismatch() public {
        CreditStanding fresh = new CreditStanding(IConfig(address(config)), address(factory), address(this));

        address wrongFactory =
            address(new MockCreditCoreWiring(makeAddr("otherFactory"), address(config), address(fresh)));
        vm.expectRevert(ICreditStanding.CreditCoreMismatch.selector);
        fresh.setCreditCore(wrongFactory);

        Config otherConfig = new Config(address(new MockUSDC()), makeAddr("treasury2"), makeAddr("registry2"));
        address wrongConfig = address(new MockCreditCoreWiring(address(factory), address(otherConfig), address(fresh)));
        vm.expectRevert(ICreditStanding.CreditCoreMismatch.selector);
        fresh.setCreditCore(wrongConfig);

        address matching = address(new MockCreditCoreWiring(address(factory), address(config), address(fresh)));
        fresh.setCreditCore(matching);
        assertEq(fresh.creditCore(), matching);
    }

    function test_setCreditCore_revertsOnStandingBackReferenceMismatch() public {
        CreditStanding fresh = new CreditStanding(IConfig(address(config)), address(factory), address(this));
        address pointsElsewhere =
            address(new MockCreditCoreWiring(address(factory), address(config), makeAddr("otherStanding")));
        vm.expectRevert(ICreditStanding.CreditCoreStandingMismatch.selector);
        fresh.setCreditCore(pointsElsewhere);
    }

    function test_setCreditCore_cannotBeRewired() public {
        vm.expectRevert(ICreditStanding.CreditCoreAlreadySet.selector);
        standing.setCreditCore(makeAddr("someOtherCreditCore"));
    }

    function test_setCreditCore_onlyTheOwner() public {
        CreditStanding fresh = new CreditStanding(IConfig(address(config)), address(factory), address(this));
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger));
        fresh.setCreditCore(address(core));
    }

    function test_requireCommunity_unknownIdReverts() public {
        vm.expectRevert(ICreditStanding.UnknownCommunity.selector);
        standing.requireCommunity(0);
        _community(0, 1);
        standing.requireCommunity(0);
    }
}
