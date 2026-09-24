// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {ComplianceRegistry} from "../src/ComplianceRegistry.sol";
import {IComplianceRegistry} from "../src/interfaces/IComplianceRegistry.sol";

contract ComplianceRegistryTest is Test {
    ComplianceRegistry reg;

    address owner = makeAddr("owner");
    address screener = makeAddr("screenerRole");
    address riskCommittee = makeAddr("riskCommittee");
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");

    function setUp() public {
        vm.prank(owner);
        reg = new ComplianceRegistry(screener);
    }

    // ---------------------------------------------------------------------
    // Test 1: a member attests for themselves; account, version, timestamp recorded and evented
    // ---------------------------------------------------------------------

    function test_selfAttest_recordsAndEvents() public {
        vm.warp(1_700_000_000);
        vm.expectEmit(true, false, false, true);
        emit IComplianceRegistry.Attested(alice, 3, uint64(block.timestamp));
        vm.prank(alice);
        reg.attest(3);

        assertTrue(reg.isAttested(alice));
        (uint64 at, uint32 version) = reg.attestationOf(alice);
        assertEq(at, uint64(block.timestamp));
        assertEq(version, 3);
        assertFalse(reg.isAttested(bob));
    }

    function test_reAttest_overwritesWithLatest() public {
        vm.prank(alice);
        reg.attest(1);
        vm.warp(block.timestamp + 10 days);
        vm.prank(alice);
        reg.attest(2);
        (uint64 at, uint32 version) = reg.attestationOf(alice);
        assertEq(version, 2);
        assertEq(at, uint64(block.timestamp));
    }

    // ---------------------------------------------------------------------
    // Test 2: the registry's central claim. No caller other than the account itself can write its
    // attestation. `attest` takes no account parameter, so this is structural: the only
    // account any caller can write is msg.sender. One case per role.
    // ---------------------------------------------------------------------

    function test_noOneCanAttestForAnotherAccount() public {
        // The screener attesting writes the SCREENER's record, never alice's.
        vm.prank(screener);
        reg.attest(1);
        assertTrue(reg.isAttested(screener));
        assertFalse(reg.isAttested(alice));

        // The owner (stands in for the Risk Committee timelock) likewise.
        vm.prank(owner);
        reg.attest(1);
        assertTrue(reg.isAttested(owner));
        assertFalse(reg.isAttested(alice));

        // An arbitrary Risk Committee signer address likewise.
        vm.prank(riskCommittee);
        reg.attest(1);
        assertTrue(reg.isAttested(riskCommittee));
        assertFalse(reg.isAttested(alice));

        // An arbitrary address likewise.
        address rando = makeAddr("rando");
        vm.prank(rando);
        reg.attest(1);
        assertTrue(reg.isAttested(rando));
        assertFalse(reg.isAttested(alice));

        // alice is still not attested: nothing any other party did touched her record.
        assertFalse(reg.isAttested(alice));
        // The ABI has no function that takes an account to attest. `setBlocked` is the only
        // per-account writer and it cannot set attestation. This line documents that the
        // absence is by design; there is nothing to call.
    }

    // ---------------------------------------------------------------------
    // Test 3: the screener sets and clears `blocked`; no other caller can
    // ---------------------------------------------------------------------

    function test_onlyScreenerSetsBlocked() public {
        vm.expectEmit(true, false, false, true);
        emit IComplianceRegistry.DrawBlockSet(alice, true, screener);
        vm.prank(screener);
        reg.setBlocked(alice, true);
        assertTrue(reg.isBlocked(alice));

        vm.prank(screener);
        reg.setBlocked(alice, false);
        assertFalse(reg.isBlocked(alice));
    }

    function test_nonScreenerCannotSetBlocked() public {
        address[4] memory notScreener = [owner, riskCommittee, alice, makeAddr("rando")];
        for (uint256 i; i < notScreener.length; i++) {
            vm.prank(notScreener[i]);
            vm.expectRevert(IComplianceRegistry.NotScreener.selector);
            reg.setBlocked(bob, true);
        }
        assertFalse(reg.isBlocked(bob));
    }

    function test_ownerRotatesScreener() public {
        address newScreener = makeAddr("newScreener");
        vm.expectEmit(true, true, false, false);
        emit IComplianceRegistry.ScreenerRotated(screener, newScreener);
        vm.prank(owner);
        reg.setScreener(newScreener);
        assertEq(reg.screener(), newScreener);

        // The old screener can no longer block.
        vm.prank(screener);
        vm.expectRevert(IComplianceRegistry.NotScreener.selector);
        reg.setBlocked(alice, true);

        // The new one can.
        vm.prank(newScreener);
        reg.setBlocked(alice, true);
        assertTrue(reg.isBlocked(alice));
    }

    function test_nonOwnerCannotRotateScreener() public {
        vm.prank(screener);
        vm.expectRevert();
        reg.setScreener(makeAddr("x"));
    }

    function test_constructorRejectsZeroScreener() public {
        vm.expectRevert(IComplianceRegistry.ZeroAddress.selector);
        new ComplianceRegistry(address(0));
    }

    // ---------------------------------------------------------------------
    // Test 4: attested and blocked are independently readable and independently settable
    // ---------------------------------------------------------------------

    function test_attestedAndBlockedAreIndependent() public {
        // Attested, not blocked.
        vm.prank(alice);
        reg.attest(1);
        assertTrue(reg.isAttested(alice));
        assertFalse(reg.isBlocked(alice));

        // Block an attested account: attestation unchanged.
        vm.prank(screener);
        reg.setBlocked(alice, true);
        assertTrue(reg.isAttested(alice));
        assertTrue(reg.isBlocked(alice));

        // Block an UNattested account: it stays unattested.
        vm.prank(screener);
        reg.setBlocked(bob, true);
        assertFalse(reg.isAttested(bob));
        assertTrue(reg.isBlocked(bob));

        // A blocked account can still attest; the block persists.
        vm.prank(bob);
        reg.attest(7);
        assertTrue(reg.isAttested(bob));
        assertTrue(reg.isBlocked(bob));
    }
}
