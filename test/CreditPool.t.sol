// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.30;

import {Ownable} from "openzeppelin-contracts/contracts/access/Ownable.sol";
import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {Community} from "../src/Community.sol";
import {CreditCore} from "../src/CreditCore.sol";
import {IConfig} from "../src/interfaces/IConfig.sol";
import {ICreditStanding} from "../src/interfaces/ICreditStanding.sol";
import {ICreditCore} from "../src/interfaces/ICreditCore.sol";
import {ConfigKeys as K} from "../src/ConfigKeys.sol";
import {CreditFixture} from "./helpers/CreditFixture.sol";
import {MockStrategy} from "./mocks/MockStrategy.sol";

/// `CreditCore` is the pool and a ledger. A community lends only its own balance, a loss comes out
/// of the community it happened in, and every unlent paper dollar is backed by cash or a pool
/// strategy. Qudi's own money is whatever is left over, and Qudi can only take that.
contract CreditPoolTest is CreditFixture {
    Community a;
    uint256 aId;
    address[] pa;

    function setUp() public override {
        super.setUp();
        // Five paid seats at $100 put 5 x $40 = $200 in the community's balance.
        (a, aId, pa) = _community(100e6, 6);
        _season();
    }

    // ---- proof 1: no Qudi money needed ----

    /// The old pool refused every draw unless Qudi's own unallocated cash covered all lending plus
    /// about $110,000 of retained capital. A community now lends from its own balance, so it can
    /// lend with no Qudi money in the pool at all.
    function test_proof1_aCommunityLendsItsOwnBalanceWithNoQudiMoney() public {
        _grant(aId, 800e6);
        assertEq(_credit(aId).allocation, 1_000e6, "the community holds $1,000");
        assertEq(_unallocated(), 0, "Qudi has nothing unallocated");

        address m = pa[1];
        uint256 before = usdc.balanceOf(m);
        _draw(m, aId, 40e6);

        assertEq(usdc.balanceOf(m) - before, 40e6, "the member was paid");
        assertEq(_credit(aId).outstanding, 40e6);
        assertEq(_unallocated(), 0, "and Qudi still has nothing unallocated");
    }

    // ---- proof 2: the community limit ----

    /// A draw can never take more than what the community has left to lend: its balance less what
    /// is already out.
    function test_proof2_aDrawBeyondWhatTheCommunityCanLendReverts() public {
        _useExtra();
        extra.setImpact(aId, pa[1], 10_000e6);
        extra.setImpact(aId, pa[2], 10_000e6);
        // Let one member take the whole balance, so the limit is what binds rather than the line.
        config.set(K.CONCENTRATION_BPS, 10_000);
        config.set(K.PHASE_CAP_FIRST_ACCESS, 1_000e6);

        _draw(pa[1], aId, 150e6);
        assertEq(_credit(aId).lendable, 50e6, "$200 less the $150 out");

        vm.prank(pa[2]);
        vm.expectRevert(ICreditCore.ExceedsAvailable.selector);
        core.draw(aId, 50e6 + 1, AGREEMENT);

        _draw(pa[2], aId, 50e6);
        assertEq(_credit(aId).outstanding, _credit(aId).allocation, "lent to the last dollar, never past it");
    }

    // ---- proof 3: loss isolation ----

    /// A write-off in one community takes exactly the unpaid principal out of that community's
    /// balance. No other community pays for it.
    function test_proof3_aWriteOffLowersOnlyItsOwnCommunityByTheUnpaidPrincipal() public {
        (, uint256 bId, address[] memory pb) = _community(100e6, 6);
        _season();
        _draw(pb[1], bId, 30e6);
        _fund(100e6); // Qudi's own money, so any drift in it shows

        address m = pa[1];
        _draw(m, aId, 40e6);
        _settle(m, 15e6);

        ICreditCore.CommunityCredit memory aBefore = _credit(aId);
        ICreditCore.CommunityCredit memory bBefore = _credit(bId);
        uint256 unallocatedBefore = _unallocated();

        vm.warp(block.timestamp + 365 days);
        core.finalizeWriteOff(m);

        ICreditCore.CommunityCredit memory aAfter = _credit(aId);
        assertEq(aBefore.allocation - aAfter.allocation, 25e6, "A lost exactly the unpaid $25");
        assertEq(aAfter.outstanding, 0);
        assertEq(aAfter.writtenOff, 25e6);

        ICreditCore.CommunityCredit memory bAfter = _credit(bId);
        assertEq(bAfter.allocation, bBefore.allocation, "B's balance did not move");
        assertEq(bAfter.outstanding, bBefore.outstanding, "B's lending did not move");
        assertEq(bAfter.writtenOff, bBefore.writtenOff);
        assertEq(_unallocated(), unallocatedBefore, "and Qudi's own money did not move");
    }

    // ---- proof 4: repayment after write-off ----

    /// A written-off advance can still be repaid, and every dollar goes back to the community whose
    /// balance took the loss.
    function test_proof4_aPaymentOnAWrittenOffAdvanceRaisesTheCommunityBalance() public {
        address m = pa[1];
        _draw(m, aId, 40e6);
        vm.warp(block.timestamp + 365 days);
        core.finalizeWriteOff(m);
        uint256 before = _credit(aId).allocation;

        _settle(m, 10e6);
        assertEq(_credit(aId).allocation, before + 10e6, "a part payment comes back at once");
        assertEq(core.obligationOf(m).principal, 30e6);

        _settle(m, 30e6);
        assertEq(_credit(aId).allocation, before + 40e6, "the whole advance came back");
        assertEq(core.obligationOf(m).principal, 0);
        assertTrue(core.obligationOf(m).closed, "the advance is repaid");
        assertEq(core.expectedCash(), usdc.balanceOf(address(core)));
    }

    /// Once the community's credit account has closed there is no balance to return to, so the
    /// payment becomes Qudi's unallocated money.
    function test_proof4_aPaymentAfterClosureGoesToQudi() public {
        address m = pa[1];
        _draw(m, aId, 40e6);
        vm.warp(block.timestamp + 365 days);
        core.finalizeWriteOff(m);
        core.closeCommunity(aId);
        assertEq(_credit(aId).allocation, 0);
        uint256 before = _unallocated();

        _settle(m, 40e6);
        assertEq(_credit(aId).allocation, 0, "a closed account takes nothing");
        assertEq(_unallocated(), before + 40e6, "the payment is Qudi's");
    }

    // ---- proof 5: illiquid ----

    /// The balance is on paper; the cash may be out in a pool strategy. A draw that finds too
    /// little cash reverts with its own error, so the app can say credit is briefly unavailable,
    /// and it works again once the operator brings the money back.
    function test_proof5_aDrawWithTheCashInAPoolStrategyRevertsPoolIlliquid() public {
        MockStrategy s = _poolStrategy();
        config.set(K.POOL_LIQUID_FLOOR_BPS, 1);
        vm.prank(operator);
        core.depositToStrategy(address(s), 190e6);
        assertEq(usdc.balanceOf(address(core)), 10e6);

        vm.prank(pa[1]);
        vm.expectRevert(ICreditCore.PoolIlliquid.selector);
        core.draw(aId, 40e6, AGREEMENT);

        vm.prank(operator);
        core.withdrawFromStrategy(address(s), 190e6);
        _draw(pa[1], aId, 40e6);
        assertEq(_credit(aId).outstanding, 40e6);
    }

    // ---- proof 6: the floor ----

    /// A pool strategy deposit must leave at least 30% of every unlent paper balance as cash.
    /// $200 unlent means at most $140 may go out.
    function test_proof6_aStrategyDepositMustLeaveThirtyPercentOfUnlentBalancesAsCash() public {
        MockStrategy s = _poolStrategy();
        vm.prank(operator);
        vm.expectRevert(ICreditCore.BelowLiquidFloor.selector);
        core.depositToStrategy(address(s), 140e6 + 1);

        vm.prank(operator);
        core.depositToStrategy(address(s), 140e6);
        assertEq(usdc.balanceOf(address(core)), 60e6, "exactly 30% left as cash");
        assertEq(core.poolView().strategyValue, 140e6);
    }

    /// The floor limits only what the operator sends out. Draws may take cash below it.
    function test_proof6_theFloorDoesNotBlockDraws() public {
        MockStrategy s = _poolStrategy();
        vm.prank(operator);
        core.depositToStrategy(address(s), 140e6);
        _draw(pa[1], aId, 40e6);
        assertEq(usdc.balanceOf(address(core)), 20e6, "cash is now under 30% of the $160 unlent");
    }

    // ---- proof 7: backing ----

    /// Qudi may take only its own money. A withdrawal that would leave cash plus strategies below
    /// the unlent paper balances reverts.
    function test_proof7_withdrawTreasuryNeverBreaksBacking() public {
        _fund(100e6);
        vm.expectRevert(ICreditCore.Unbacked.selector);
        core.withdrawTreasury(treasury, 100e6 + 1);

        core.withdrawTreasury(treasury, 100e6);
        assertEq(usdc.balanceOf(treasury) - _treasuryAtStart, 100e6);
        assertEq(_unallocated(), 0);
    }

    /// A grant can only hand out money Qudi has.
    function test_proof7_allocateNeverBreaksBacking() public {
        _fund(100e6);
        vm.prank(allocator);
        vm.expectRevert(ICreditCore.Unbacked.selector);
        core.allocate(aId, 100e6 + 1, ICreditCore.AllocationType.Growth);

        vm.prank(allocator);
        core.allocate(aId, 100e6, ICreditCore.AllocationType.Growth);
        assertEq(_credit(aId).allocation, 300e6);
    }

    /// Strategy positions back paper balances as well as cash does.
    function test_proof7_strategyPositionsCountTowardBacking() public {
        _fund(100e6);
        MockStrategy s = _poolStrategy();
        vm.prank(operator);
        core.depositToStrategy(address(s), 150e6);

        core.withdrawTreasury(treasury, 100e6);
        assertEq(usdc.balanceOf(address(core)) + s.totalAssets(), 200e6, "exactly the unlent balances left");
    }

    function test_proof7_onlyTheOwnerWithdrawsTheTreasury() public {
        _fund(100e6);
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger));
        core.withdrawTreasury(stranger, 1);
        vm.prank(operator);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, operator));
        core.withdrawTreasury(operator, 1);
    }

    function test_withdrawTreasury_zeroRevertsAndAWithdrawalIsEvented() public {
        _fund(100e6);
        vm.expectRevert(ICreditCore.ZeroAmount.selector);
        core.withdrawTreasury(treasury, 0);
        vm.expectRevert(ICreditCore.ZeroAddress.selector);
        core.withdrawTreasury(address(0), 1);

        vm.expectEmit(true, false, false, true, address(core));
        emit ICreditCore.TreasuryWithdrawn(treasury, 60e6);
        core.withdrawTreasury(treasury, 60e6);
        assertEq(core.expectedCash(), usdc.balanceOf(address(core)));
    }

    // ---- pool strategies ----

    /// Yield and losses in a pool strategy are Qudi's. They move Qudi's unallocated money and never
    /// a community's balance.
    function test_strategy_gainsAndLossesMoveOnlyQudisMoney() public {
        _fund(100e6);
        MockStrategy s = _poolStrategy();
        vm.prank(operator);
        core.depositToStrategy(address(s), 100e6);
        uint256 allocation = _credit(aId).allocation;

        usdc.mint(address(this), 20e6);
        usdc.approve(address(s), 20e6);
        s.fund(20e6);
        assertEq(_unallocated(), 120e6, "a gain is Qudi's");
        assertEq(_credit(aId).allocation, allocation);

        s.skim(50e6);
        assertEq(_unallocated(), 70e6, "and so is a loss");
        assertEq(_credit(aId).allocation, allocation);
    }

    /// Listing belongs to the strategy lister, which starts as the owner.
    function test_strategy_listingIsTheListersAndMovingIsTheOperators() public {
        MockStrategy s = new MockStrategy(IERC20(address(usdc)), address(core));
        vm.prank(operator);
        vm.expectRevert(ICreditCore.NotStrategyLister.selector);
        core.addStrategy(address(s));
        core.addStrategy(address(s));
        vm.expectRevert(ICreditCore.DuplicateStrategy.selector);
        core.addStrategy(address(s));

        vm.expectRevert(ICreditCore.NotOperator.selector);
        core.depositToStrategy(address(s), 1e6);
        vm.prank(stranger);
        vm.expectRevert(ICreditCore.NotOperator.selector);
        core.withdrawFromStrategy(address(s), 1e6);

        MockStrategy unlisted = new MockStrategy(IERC20(address(usdc)), address(core));
        vm.prank(operator);
        vm.expectRevert(ICreditCore.UnknownStrategy.selector);
        core.depositToStrategy(address(unlisted), 1e6);
    }

    /// A strategy over another asset cannot be listed, and one still holding money cannot be
    /// removed: the operator brings the money back first.
    function test_strategy_assetMustMatchAndRemovalWaitsForAnEmptyPosition() public {
        MockStrategy wrong = new MockStrategy(IERC20(makeAddr("otherToken")), address(core));
        vm.expectRevert(ICreditCore.StrategyAssetMismatch.selector);
        core.addStrategy(address(wrong));

        MockStrategy s = _poolStrategy();
        vm.prank(operator);
        core.depositToStrategy(address(s), 50e6);
        vm.expectRevert(ICreditCore.StrategyHoldsBalance.selector);
        core.removeStrategy(address(s));

        vm.prank(operator);
        core.withdrawFromStrategy(address(s), 50e6);
        core.removeStrategy(address(s));
        assertEq(core.strategies().length, 0);
    }

    function test_constructorRejectsZeroAddresses() public {
        address[6] memory parts =
            [address(usdc), address(config), address(factory), operator, allocator, address(standing)];
        for (uint256 i; i < parts.length; i++) {
            address[6] memory a = parts;
            a[i] = address(0);
            vm.expectRevert(ICreditCore.ZeroAddress.selector);
            new CreditCore(IERC20(a[0]), IConfig(a[1]), a[2], address(this), a[3], a[4], ICreditStanding(a[5]));
        }
    }

    // ---- allocation and closure ----

    function test_allocate_onlyTheAllocatorAndOnlyALiveCommunity() public {
        _fund(100e6);
        vm.prank(stranger);
        vm.expectRevert(ICreditCore.NotAllocationMultisig.selector);
        core.allocate(aId, 1e6, ICreditCore.AllocationType.Growth);

        vm.prank(allocator);
        vm.expectRevert(ICreditCore.UnknownCommunity.selector);
        core.allocate(aId + 1, 1e6, ICreditCore.AllocationType.Growth);

        core.closeCommunity(aId);
        vm.prank(allocator);
        vm.expectRevert(ICreditCore.CommunityIsClosed.selector);
        core.allocate(aId, 1e6, ICreditCore.AllocationType.Growth);
    }

    /// Closing a community's credit account returns its balance to Qudi. It waits for every
    /// advance in the community to be repaid or written off.
    function test_closure_returnsTheBalanceOnceNothingIsOut() public {
        _draw(pa[1], aId, 40e6);
        vm.expectRevert(ICreditCore.CommunityHasDebt.selector);
        core.closeCommunity(aId);

        _repayAll(pa[1]);
        core.closeCommunity(aId);
        assertEq(_credit(aId).allocation, 0);
        assertEq(_unallocated(), 200e6, "the whole balance is Qudi's again");
        vm.expectRevert(ICreditCore.AlreadyClosed.selector);
        core.closeCommunity(aId);
    }

    // ---- helpers ----

    uint256 internal _treasuryAtStart;

    function _fund(uint256 amount) internal {
        _treasuryAtStart = usdc.balanceOf(treasury);
        usdc.mint(address(this), amount);
        usdc.approve(address(core), amount);
        core.fund(amount);
    }
}
