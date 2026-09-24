// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";
import {Vm} from "forge-std/Vm.sol";
import {Venue} from "../../src/Venue.sol";
import {Config} from "../../src/Config.sol";
import {IConfig} from "../../src/interfaces/IConfig.sol";
import {ConfigKeys as K} from "../../src/ConfigKeys.sol";
import {ComplianceRegistry} from "../../src/ComplianceRegistry.sol";
import {PoolTypes} from "../../src/PoolTypes.sol";
import {MockUSDC} from "../mocks/MockUSDC.sol";
import {MockVenue} from "../mocks/MockVenue.sol";
import {FactoryStub} from "../Venue.t.sol";

/// The handler for `Venue`. Same shape as the other harnesses under `test/invariant/`:
/// every verb no-ops rather than reverting on a failed precondition, so the fuzzer keeps chaining
/// deep sequences instead of discarding them, and every ghost moves only on a success path.
///
/// Two registered depositors (`ledgers`) stand in for community ledgers -- the vault only ever asks the
/// factory whether the caller is a registered community contract, and the `FactoryStub` says yes for
/// exactly them, the seed holder and the credit pool. Two venues: one instant, one slow.
///
/// The pricing model these ghosts are denominated in (the contract's own doc):
/// `totalAssets()` is `idle + sum min(basis, live) - unreleased`, so a venue loss reaches the share
/// price at once while a gain waits for a harvest, and the 70/15/15 split is an asset skim taken at
/// that harvest rather than a fee-share mint taken on every touch. Every verb that touches the
/// vault is `watched` and reports what happened through `_observe()`, which reads the `Harvested`
/// and `LossAbsorbed` events the call emitted and moves the ghosts on the figures the vault itself
/// put in them. Nothing here reads a price that an absorb has not just been given the chance to run.
contract VenueHandler is Test {
    Venue public vault;
    IConfig public config;
    MockUSDC public usdc;
    MockVenue public fastVenue;
    MockVenue public slowVenue;
    address public owner;
    address public creditPool;

    /// The two depositors the fuzzer drives.
    address[2] public ledgers;
    /// A third registered depositor, deposited once by the fixture and never touched again. It
    /// exists to keep `totalSupply()` well away from zero: a vault drained to zero shares keeps a
    /// dust of settled value (a withdrawal rounds the burn up, so the last holder leaves a unit or two
    /// behind), and the next deposit then prices against that dust and doubles the share price.
    /// Repeat that a few times inside one campaign and the price is orders of magnitude off unity,
    /// at which point every `convertToAssets` floor costs thousands of units and the rounding
    /// tolerances below stop meaning anything. Its shares are part of the supply identity, so
    /// `sumLedgerBalances` counts them.
    address public seedHolder;
    /// A payout receiver `MockUSDC` refuses to pay. Every campaign therefore reaches
    /// `processQueue`'s held-payout branch instead of leaving it unexercised, and
    /// `releaseHeldPayout` below is the only thing that ever unblocks it.
    address public blockedReceiver;

    /// Deposits start at one whole USDC: a vault whose supply is a handful of wei is the same
    /// degenerate-price problem `seedHolder` exists to prevent, reached from the other end.
    uint256 internal constant MIN_DEPOSIT = 1e6;
    uint256 internal constant MAX_DEPOSIT = 100_000e6;
    /// Venue gains are at least a whole USDC for `invariant_skimmedLegsMatchSplit`'s sake: the two
    /// legs are floor divisions, so a gain of a few wei skims nothing at all and would drag the
    /// comparison of "skimmed" against "30% of gains" arbitrarily far off with no bug behind it.
    /// At 1e6 the two floors cost at most a couple of wei out of 300,000.
    uint256 internal constant MIN_GAIN = 1e6;
    uint256 internal constant MAX_GAIN = 50_000e6;
    /// The share balance a venue must already hold for the vault before a gain may be dropped into
    /// it. A venue the vault holds a handful of shares of is a venue whose ERC-4626 read has come
    /// apart: `convertToAssets(shares)` carries the virtual-offset error `1/(shares + 1)`, which at
    /// one share is half the venue's balance and at 1e6 shares is a millionth of it. Dropping a
    /// 50,000 USDC gain onto a venue the vault holds one share of therefore does not raise the
    /// vault's reading of that venue by 50,000, it raises it by 25,000 -- and `rebalance()`, which
    /// computes every target from exactly that reading, then allocates against a valuation that is
    /// off by tens of percent and leaves the slow tier over its ceiling by a real margin. That was
    /// a measured counterexample, not a hypothetical, and it is a fixture artefact rather than a
    /// vault bug: a real venue with a real depositor base is never read through one share. Holding
    /// the gain until the vault has a whole USDC of shares in the venue keeps every venue read
    /// inside a millionth of its true value, which is well under the tier check's own 1e6 slack.
    uint256 internal constant MIN_VENUE_SHARES_FOR_GAIN = 1e6;
    uint256 internal constant MAX_RESERVE = 10_000e6;
    /// Queue steps per `processQueue` call.
    uint256 internal constant MAX_QUEUE_STEPS = 5;

    // ---- ghosts ----

    /// `convertToAssets(1e6)` as it stood at the end of the last call that settled. The floor the
    /// member price may not fall below while no venue has lost anything: a gain only ever raises it
    /// (the split comes out of the gain, never out of what the members already had), and deposit
    /// and withdrawal rounding only ever leaves the remaining holders a shade better off.
    uint256 public lastSettledPrice;
    /// `convertToAssets(1e6)` as it stood at the end of the last call that ran an **absorb**, which
    /// is a stricter thing than `lastSettledPrice`: four watched verbs reach the vault without
    /// absorbing (`claimProtocolLeg`, `releaseHeldPayout`, `cancelRedeem`, `setWeights`), and all
    /// four record the price they found, which after a quiet stretch is above the price the last
    /// absorb left because the unlock has been releasing into it since.
    ///
    /// The absorb rule makes the difference load-bearing. What the promise may absorb is the promise standing
    /// at the last **touch**, so the floor a covered loss may not push the members below is the
    /// price at that touch, not the price at the last time anyone looked. Measured from the last
    /// observation instead, a promise-covered loss reads as members paying while the reserve sat
    /// idle, which is the released part of the promise being handed back and not principal moving.
    uint256 public lastAbsorbPrice;
    /// Set by a venue loss, cleared by the next settle. While it stands, the member price is
    /// expected to be below `lastSettledPrice` and the floor invariant steps aside.
    bool public lossSinceSettle;
    /// Set by a deposit whose shares came out worth more than the USDC it paid. That is what
    /// buying into a gain someone else earned would look like from the newcomer's side, and the
    /// settle at the top of `deposit` is what makes it impossible.
    bool public freeGainObserved;
    /// Set by a verb that reaches the vault, settles nothing and moves no value, yet left
    /// `convertToAssets(1e6)` somewhere other than where it found it.
    bool public priceMovedWithoutSettle;

    /// Summed over every harvest that was processed, from the `Harvested` event: the USDC skimmed
    /// for the two 15% legs, the gain it was taken out of, and the member leg left behind. All
    /// three are asset figures now, so the comparison between them is exact integer
    /// arithmetic and needs no price conversion and no price-relative dust bound.
    uint256 public skimmedLegs;
    uint256 public positiveGains;
    uint256 public harvestCount;
    /// Nonzero only if some harvest's own skim fell short of its own 30% by more than the two
    /// floor divisions that produce it (`protocolLeg` and `poolLeg` are floored independently).
    uint256 public worstShortfallOverBound;
    /// What the members are credited, summed per harvest: the residual the harvest itself reported,
    /// so a harvest that split the wrong way shows up here as the wrong member credit. An upper
    /// bound on what any payout can reach, because only the released part of it is ever in the
    /// price.
    uint256 public memberGains;

    /// Set by an absorb that lowered the member share price while the reserve was NOT exhausted by
    /// the loss it absorbed -- the exact thing the reserve exists to prevent. "Not exhausted" is
    /// read off the `LossAbsorbed` event (`burned` short of the reserve the call started with), so
    /// refilling the reserve later cannot resurrect a stale latch and exhausting it later cannot
    /// hide a violation that already happened.
    bool public membersTookLoss;
    /// Set by any observation where `totalAssets()` reported more than the vault could honour, or
    /// more than it had recognized. Property 5 of the Yield Engine, across the whole campaign.
    bool public reportedMoreThanHeld;
    /// The waterfall, summed across the campaign: the losses absorbed and the part of each
    /// taken out of the unreleased profit rather than out of the share price.
    uint256 public lossAbsorbed;
    uint256 public profitAbsorbed;
    /// Set if any absorb charged the promise for more than the loss it was absorbing, or burned
    /// reserve shares for a loss the promise had already covered in full.
    bool public waterfallOverCharged;
    /// An absorb never raises the price, latched at the absorb that broke it: a loss absorb that left the member
    /// price above where it found it. A burn exists to charge a loss somewhere, so one that leaves
    /// the members better off than the vault found them has invented value out of the reserve. Both
    /// halves of the waterfall are in the price views now, the promise through `_heldBack` and the
    /// reserve through `_previewSettleSupply`, so an absorb realizes a price that was already
    /// struck and the expected movement is exactly zero. `worstPriceRiseAtAnAbsorb` carries the
    /// size of the largest breach, in USDC per 1e6 shares, so a failure says how bad rather than
    /// only that.
    bool public absorbRaisedThePrice;
    uint256 public worstPriceRiseAtAnAbsorb;
    /// Set by any observation where the reported total plus what is held back did not equal the
    /// recognized total, which is the saturating subtraction in `totalAssets()` engaging. The waterfall
    /// says it never should; the proof is recorded as QV-29.
    bool public reportedTotalFloored;

    /// USDC that has actually reached a holder: instant withdrawals, delivered queue payouts, and
    /// held payouts once released. A payout the receiver refused is not counted here -- it is still
    /// in the vault's balance, netted out of `idle()` by `totalHeld`, and counted only when
    /// `releaseHeldPayout` finally delivers it.
    uint256 public paidOut;
    /// USDC the two driven ledgers put in. The seed deposit and reserve funding are deliberately
    /// not in here: `invariant_noHolderRedeemsMoreThanWorth` is tighter for excluding them, and
    /// `invariant_usdcClosure` adds them back explicitly.
    uint256 public depositedIn;
    uint256 public reserveFunded;
    /// USDC minted into a venue (a gain) and skimmed out of one (a loss).
    uint256 public venueGains;
    uint256 public venueLosses;

    /// A `rebalance` that left the slow tier above its ceiling, and a `setWeights` that was
    /// accepted with the slow tier weighted above it. Both must stay zero.
    uint256 public tierBreaches;
    uint256 public weightBreaches;

    uint256[] internal _requestIds;
    mapping(uint256 => address) internal _requestOwner;

    constructor(
        Venue vault_,
        MockVenue fastVenue_,
        MockVenue slowVenue_,
        address creditPool_,
        address[2] memory ledgers_,
        address seedHolder_,
        address blockedReceiver_
    ) {
        vault = vault_;
        config = vault_.config();
        usdc = MockUSDC(vault_.asset());
        fastVenue = fastVenue_;
        slowVenue = slowVenue_;
        owner = vault_.owner();
        creditPool = creditPool_;
        ledgers = ledgers_;
        seedHolder = seedHolder_;
        blockedReceiver = blockedReceiver_;
    }

    bytes32 internal constant HARVESTED = keccak256("Harvested(address,uint256,uint256,uint256,uint256)");
    // Three unindexed uint256 since the profit-absorbed figure was added. This constant once named an
    // `address` first parameter, left over from the per-venue form of the
    // event that a size reduction replaced with one aggregate event. The topic therefore
    // never matched, the branch below never ran, and `invariant_reserveBurnsBeforeMembers` was
    // vacuous for that stretch. Found while updating this file for the waterfall.
    bytes32 internal constant LOSS_ABSORBED = keccak256("LossAbsorbed(uint256,uint256,uint256)");
    /// `reserveShares` as the current call found it, which is also what the settle at the top of
    /// that call had to absorb a loss out of.
    uint256 internal _reserveBefore;

    /// Wraps every verb that reaches the vault: starts the recording `_settled` reads back, and
    /// clears whatever is left in the buffer afterwards, which is how a reverted call's logs are
    /// thrown away. `vm.getRecordedLogs()` hands back the logs a reverted call emitted just as
    /// readily as a successful one's, so `_settled` is called from inside each verb's `try` branch
    /// and never from here.
    modifier watched() {
        _reserveBefore = vault.reserveShares();
        vm.recordLogs();
        _;
        vm.getRecordedLogs();
    }

    /// For the three verbs that reach the vault, settle nothing and move no value: `setWeights`
    /// touches no money, `cancelRedeem` hands locked shares back, and `releaseHeldPayout` pays out
    /// USDC that `idle()` already nets out. The member price must come back exactly as it was.
    /// `lastSettledPrice` is a floor and tolerates rounding drift upward; this tolerates nothing.
    modifier priceExact() {
        uint256 before = vault.convertToAssets(1e6);
        _;
        if (vault.convertToAssets(1e6) != before) priceMovedWithoutSettle = true;
    }

    /// Reads back the `Harvested` and `LossAbsorbed` events the call just emitted, if any, and
    /// moves the ghosts on exactly the figures the contract reported. Called on the success path
    /// only: a harvest that was reverted away never happened.
    ///
    /// Every watched verb runs `_absorb()` at the top, so reaching here at all means any venue
    /// loss standing at the time has been taken onto the reserve or onto the holders. That is why
    /// `lastSettledPrice` and `lossSinceSettle` are updated unconditionally rather than only when
    /// an event was found: a call that had nothing to absorb and nothing to harvest
    /// emits nothing, and the price it leaves behind is still the settled one.
    function _observe() internal {
        _observe(true);
    }

    /// `settling` is false for the verbs that reach the vault without running an absorb. They still
    /// move `lastSettledPrice`, which is a floor for `invariant_memberPriceNeverFallsWithoutLoss`
    /// and correct at any observation, but they must not move `lastAbsorbPrice`: see its comment.
    function _observe(bool settling) internal {
        Vm.Log[] memory logs = vm.getRecordedLogs();
        // `_absorb()` walks every venue in one call, so a single call can emit one `LossAbsorbed`
        // per venue, and the price this ghost can read is the one left after all of them. Judging
        // each event on its own against that single price latches a violation whenever an earlier
        // venue's loss left the reserve too thin for a later one, which is the reserve running out
        // rather than failing to go first. The property is about the call, so the burns are summed
        // across the call and checked once, after the loop.
        uint256 burnedInCall;
        uint256 profitAbsorbedInCall;
        bool sawLoss;
        for (uint256 i; i < logs.length; i++) {
            if (logs[i].emitter != address(vault) || logs[i].topics.length == 0) continue;
            bytes32 topic = logs[i].topics[0];
            if (topic == HARVESTED) {
                (uint256 gain, uint256 memberLeg, uint256 poolLeg, uint256 protocolLeg) =
                    abi.decode(logs[i].data, (uint256, uint256, uint256, uint256));
                positiveGains += gain;
                skimmedLegs += poolLeg + protocolLeg;
                memberGains += memberLeg;
                harvestCount += 1;
                // Per-harvest shortfall against its own 30%. `protocolLeg` and `poolLeg` are two
                // independent floor divisions of the same gain, so the skim can fall one unit
                // short on each and no further. This is a raw unit bound, and correctly so: both
                // figures are USDC, so unlike the fee-share model it replaced (with its
                // price-relative bound) no share price enters the arithmetic and none of it drifts.
                uint256 expected = (gain * 3000) / 10_000;
                uint256 got = poolLeg + protocolLeg;
                if (got < expected && expected - got > 2) {
                    uint256 excess = expected - got - 2;
                    if (excess > worstShortfallOverBound) worstShortfallOverBound = excess;
                }
            } else if (topic == LOSS_ABSORBED) {
                (uint256 lossSeen, uint256 fromProfit, uint256 burned) =
                    abi.decode(logs[i].data, (uint256, uint256, uint256));
                burnedInCall += burned;
                profitAbsorbedInCall += fromProfit;
                lossAbsorbed += lossSeen;
                profitAbsorbed += fromProfit;
                // The promise answers first and the reserve answers only for the rest, so a
                // burn can never be charged for a loss the promise already covered.
                if (fromProfit > lossSeen) waterfallOverCharged = true;
                if (fromProfit == lossSeen && burned > 0) waterfallOverCharged = true;
                sawLoss = true;
            }
        }
        // The burns stopped short of the reserve the call started with, so the reserve covered
        // whatever the promise did not and the member price must be back where the last absorb left
        // it. A loss the promise absorbed outright burns nothing and moves no price, which this
        // condition admits without a special case.
        if (sawLoss && burnedInCall < _reserveBefore) {
            uint256 price = vault.convertToAssets(1e6);
            if (price + _priceDust(lastAbsorbPrice, vault.totalSupply()) < lastAbsorbPrice) {
                membersTookLoss = true;
            }
        }
        _honourable();
        lastSettledPrice = vault.convertToAssets(1e6);
        if (settling) lastAbsorbPrice = lastSettledPrice;
        lossSinceSettle = false;
    }

    /// Property 5, checked after every verb that reaches the vault rather than only at the end of
    /// a campaign: what the vault reports is never more than what it holds, and never more than it
    /// has recognized. `liveAssets()` is the ceiling because `idle()` already nets out the held
    /// payouts, the break escrow and the two skimmed legs, so what is left is the money the vault
    /// could actually raise for its shareholders.
    function _honourable() internal {
        uint256 reported = vault.totalAssets();
        if (reported > vault.liveAssets()) reportedMoreThanHeld = true;
        uint256 recognized = vault.recognizedAssets();
        if (reported > recognized) reportedMoreThanHeld = true;
        // No flooring. What is reported plus what is held back is what is recognized, at
        // every point, so a loss can never leave value stranded behind a zero price.
        if (reported + vault.unreleasedProfit() != recognized) reportedTotalFloored = true;
    }

    function _pickLedger(uint256 seed) internal view returns (address) {
        return ledgers[seed % 2];
    }

    /// Redeem receivers: either driven ledger, or the receiver that cannot take USDC.
    function _pickReceiver(uint256 seed) internal view returns (address) {
        uint256 i = seed % 3;
        return i == 2 ? blockedReceiver : ledgers[i];
    }

    function _pickVenue(uint256 seed) internal view returns (MockVenue) {
        return seed % 2 == 0 ? fastVenue : slowVenue;
    }

    /// Every address a payout can reach. Used to measure what `processQueue` actually delivered,
    /// which cannot be read off the vault's own balance because the same call also pulls USDC in
    /// from the venues.
    function _receiversUsdc() internal view returns (uint256) {
        return usdc.balanceOf(ledgers[0]) + usdc.balanceOf(ledgers[1]) + usdc.balanceOf(blockedReceiver);
    }

    // ---- views the invariants read ----

    function sumLedgerBalances() external view returns (uint256) {
        return vault.balanceOf(ledgers[0]) + vault.balanceOf(ledgers[1]) + vault.balanceOf(seedHolder);
    }

    function sumQueuedShares() external view returns (uint256) {
        return vault.queuedShares(ledgers[0]) + vault.queuedShares(ledgers[1]) + vault.queuedShares(seedHolder);
    }

    // ---- handler surface ----

    function deposit(uint256 ledgerSeed, uint256 amountSeed) external watched {
        address l = _pickLedger(ledgerSeed);
        uint256 amount = bound(amountSeed, MIN_DEPOSIT, MAX_DEPOSIT);
        usdc.mint(l, amount);
        vm.prank(l);
        usdc.approve(address(vault), amount);
        vm.prank(l);
        try vault.deposit(amount, l) returns (uint256 shares) {
            depositedIn += amount;
            // What the newcomer just bought, valued the instant it landed. Worth more than it paid
            // means it was handed a slice of a gain that was already sitting in the vault.
            if (vault.convertToAssets(shares) > amount + 1) freeGainObserved = true;
            _observe();
        } catch {}
    }

    function withdraw(uint256 ledgerSeed, uint256 amountSeed) external watched {
        address l = _pickLedger(ledgerSeed);
        uint256 worth = vault.convertToAssets(vault.balanceOf(l));
        if (worth == 0) return;
        uint256 assets = bound(amountSeed, 1, worth);
        vm.prank(l);
        try vault.withdraw(assets, l, l) {
            paidOut += assets;
            _observe();
        } catch {}
    }

    function requestRedeem(uint256 ledgerSeed, uint256 sharesSeed, uint256 receiverSeed) external watched {
        address l = _pickLedger(ledgerSeed);
        uint256 bal = vault.balanceOf(l);
        if (bal == 0) return;
        uint256 shares = bound(sharesSeed, 1, bal);
        address receiver = _pickReceiver(receiverSeed);
        vm.prank(l);
        try vault.requestRedeem(shares, receiver) returns (uint256 id) {
            _requestIds.push(id);
            _requestOwner[id] = l;
            _observe();
        } catch {}
    }

    function cancelRedeem(uint256 idSeed) external watched priceExact {
        if (_requestIds.length == 0) return;
        uint256 id = _requestIds[idSeed % _requestIds.length];
        vm.prank(_requestOwner[id]);
        try vault.cancelRedeem(id) {
            _observe(false); // does not absorb: see `lastAbsorbPrice`
        } catch {}
    }

    function processQueue(uint256 stepsSeed) external watched {
        uint256 steps = bound(stepsSeed, 1, MAX_QUEUE_STEPS);
        uint256 before = _receiversUsdc();
        try vault.processQueue(steps) {
            paidOut += _receiversUsdc() - before;
            _observe();
        } catch {}
    }

    /// The tier bound is checked here, immediately after the call, rather than as a standing
    /// property: nothing stops a venue losing value between rebalances, and the ratio it leaves
    /// behind is not a tier breach until a rebalance has had the chance to correct it.
    ///
    /// Denominated in recorded basis against `recognizedAssets()`, because those are the two
    /// figures `rebalance()` itself computes its targets from. An unharvested gain sitting in the
    /// slow venue can put that venue's live reading above the ceiling, and a rebalance cannot
    /// correct it without pulling the venue below its basis, which would recognize the gain with
    /// no skim taken and no unlock applied. What settles which of the two this
    /// is: venue limits bind actions, not outcomes. The action here is allocation, and allocation
    /// is what the basis measures.
    function rebalance() external watched {
        try vault.rebalance() {
            uint256 slowBasis = vault.venueBasis(address(slowVenue));
            if (slowBasis > (vault.recognizedAssets() * config.slowTierCeilingBps()) / 10_000 + 1e6) tierBreaches++;
            _observe();
        } catch {}
    }

    /// Slow weights are drawn up to twice the ceiling, so roughly half the draws must be refused by
    /// `_checkTiers` and the other half land. A landed call that left the slow tier weighted above
    /// its ceiling is counted as a breach.
    function setWeights(uint256 fastSeed, uint256 slowSeed) external watched priceExact {
        uint16 slowW = uint16(bound(slowSeed, 0, 5_000));
        uint16 fastW = uint16(bound(fastSeed, 0, 10_000 - slowW));
        address[] memory vs = new address[](2);
        vs[0] = address(fastVenue);
        vs[1] = address(slowVenue);
        uint16[] memory bps = new uint16[](2);
        bps[0] = fastW;
        bps[1] = slowW;
        vm.prank(owner);
        try vault.setWeights(vs, bps) {
            if (vault.weightBps(address(slowVenue)) > config.slowTierCeilingBps()) weightBreaches++;
            _observe(false); // does not absorb: see `lastAbsorbPrice`
        } catch {}
    }

    /// The keeper's touch. It is the same `_absorb()` every other verb runs first, so it needs no
    /// accounting of its own: `_observe()` reads its events like it reads every other call's.
    ///
    /// It is also the campaign's probe for the rule that an absorb never raises the price. `report()` is an absorb and an event and
    /// nothing else: it moves no USDC, mints nothing, and takes no fee, so the member price across
    /// this call is the member price across the absorb, with no other movement mixed into it and no
    /// rounding tolerance to allow for. Whatever state the fuzzer has built, a loss absorbed here
    /// must not leave the price higher than it found it.
    function report() external watched {
        uint256 priceBefore = vault.convertToAssets(1e6);
        try vault.report() {
            uint256 priceAfter = vault.convertToAssets(1e6);
            if (priceAfter > priceBefore) {
                absorbRaisedThePrice = true;
                uint256 rise = priceAfter - priceBefore;
                if (rise > worstPriceRiseAtAnAbsorb) worstPriceRiseAtAnAbsorb = rise;
            }
            _observe();
        } catch {}
    }

    /// How far the member price may legitimately sit below where the last settle left it after a
    /// loss the reserve fully absorbed. An absorb values the loss at the pre-loss price and burns
    /// `floor(loss * supply / (totalAssets + loss))` reserve shares, so it can leave up to one share
    /// unburned; one share is worth `price / (supply + 1)` at this scale, and the two
    /// `convertToAssets` floors either side cost a unit each.
    function _priceDust(uint256 price, uint256 supply) internal pure returns (uint256) {
        return price / (supply + 1) + 2;
    }

    function fundReserve(uint256 amountSeed) external watched {
        uint256 amount = bound(amountSeed, MIN_DEPOSIT, MAX_RESERVE);
        usdc.mint(address(this), amount);
        usdc.approve(address(vault), amount);
        try vault.fundReserve(amount) {
            reserveFunded += amount;
            _observe();
        } catch {}
    }

    /// A venue gain is USDC appearing inside a venue the vault holds shares of. Skipped when the
    /// vault holds none: the venue would keep the money forever and `invariant_usdcClosure` would
    /// be counting USDC that never belonged to the vault in the first place. Skipped again when it
    /// holds only dust, for the reason `MIN_VENUE_SHARES_FOR_GAIN` documents at length.
    function venueGain(uint256 venueSeed, uint256 amountSeed) external {
        MockVenue v = _pickVenue(venueSeed);
        if (v.balanceOf(address(vault)) < MIN_VENUE_SHARES_FOR_GAIN) return;
        uint256 amount = bound(amountSeed, MIN_GAIN, MAX_GAIN);
        usdc.mint(address(v), amount);
        venueGains += amount;
    }

    /// `skim` sends the USDC to this handler, which is where it stays: money that has left the
    /// vault's world entirely, which is exactly what a venue loss is.
    function venueLoss(uint256 venueSeed, uint256 amountSeed) external {
        MockVenue v = _pickVenue(venueSeed);
        uint256 have = usdc.balanceOf(address(v));
        if (have == 0) return;
        uint256 amount = bound(amountSeed, 1, have);
        v.skim(amount);
        venueLosses += amount;
        // The price falls with it, live. It stays below `lastSettledPrice` until a settle has
        // taken the loss onto the reserve or onto the holders.
        lossSinceSettle = true;
    }

    /// Not in the task's verb list, but `invariant_supplyAccounting` names `balanceOf(creditPool)`
    /// and nothing else in the handler can ever put a share there.
    function claimPoolLeg(uint256 ledgerSeed) external watched {
        address l = _pickLedger(ledgerSeed);
        vm.prank(l);
        try vault.claimPoolLeg(creditPool) {
            _observe();
        } catch {}
    }

    /// The discrete harvest. Reverts on a double harvest in the same period, on a venue
    /// with nothing above its basis, and while the breaker stands; all three no-op here, which is
    /// what keeps deep sequences alive.
    function harvest(uint256 venueSeed) external watched {
        MockVenue v = _pickVenue(venueSeed);
        try vault.harvest(address(v)) {
            _observe();
        } catch {}
    }

    /// Clears the deviation breaker, so a campaign that trips it keeps harvesting afterwards instead of
    /// spending the rest of its depth on a paused vault.
    function resumeAttribution() external watched {
        address paused = vault.pausedVenue();
        if (paused == address(0)) return;
        vm.prank(owner);
        try vault.resumeAttribution(paused) {
            _observe();
        } catch {}
    }

    /// Time. Without it the unlock never releases anything and the gradual release sits at
    /// `elapsed == 0` for the length of the campaign. Bounded by a stretch of days so a single
    /// draw can run past the unlock period as well as stop inside it.
    function warp(uint256 secondsSeed) external {
        vm.warp(block.timestamp + bound(secondsSeed, 1, 5 days));
        _honourable();
    }

    /// Pays the protocol leg out to the treasury in USDC. `invariant_usdcClosure` counts
    /// the treasury's balance, and nothing else in the handler can put USDC there.
    function claimProtocolLeg() external watched {
        try vault.claimProtocolLeg() {
            _observe(false); // does not absorb: see `lastAbsorbPrice`
        } catch {}
    }

    /// Unblocks the receiver for exactly the length of this call, so held payouts get delivered and
    /// counted, and the held branch stays reachable for everything after it.
    function releaseHeldPayout() external watched priceExact {
        uint256 held = vault.heldPayout(blockedReceiver);
        if (held == 0) return;
        usdc.setBlocked(blockedReceiver, false);
        try vault.releaseHeldPayout(blockedReceiver) {
            paidOut += held;
            _observe(false); // does not absorb: see `lastAbsorbPrice`
        } catch {}
        usdc.setBlocked(blockedReceiver, true);
    }
}

/// `Venue`'s invariant suite: one real vault of the Core pool type
/// with two real `MockVenue`s (one instant, one slow) and two registered stand-in ledgers, driven
/// exclusively through `VenueHandler`.
contract VenueInvariantTest is StdInvariant, Test {
    MockUSDC usdc;
    Config config;
    FactoryStub factory;
    Venue vault;
    MockVenue fast;
    MockVenue slow;
    VenueHandler handler;

    address owner = makeAddr("vaultOwner");
    address treasury = makeAddr("treasury");
    address creditPool = makeAddr("creditPool");
    address ledgerA = makeAddr("ledgerA");
    address ledgerB = makeAddr("ledgerB");
    address seedHolder = makeAddr("seedHolder");
    address blockedReceiver = makeAddr("blockedReceiver");
    address stranger = makeAddr("stranger");

    /// See `VenueHandler.seedHolder` for why the vault is never left empty.
    uint256 constant SEED = 1_000e6;

    function setUp() public {
        usdc = new MockUSDC();
        config = new Config(address(usdc), treasury, address(new ComplianceRegistry(address(this))));
        // Headroom so a long campaign is not spent bouncing off the deposit cap. An ordinary
        // in-bounds config value, read live by the vault like any other.
        config.set(K.GLOBAL_DEPOSIT_CAP, 100_000_000_000e6);

        factory = new FactoryStub();
        factory.register(ledgerA);
        factory.register(ledgerB);
        factory.register(seedHolder);
        factory.register(creditPool);
        // The credit leg's destination is `Config.CREDIT_CORE` now, not any address the
        // factory registry vouches for (`CreditCore` is a singleton, never a community contract), so
        // the fixture's stand-in pool has to be the configured one.
        config.setAddress(K.CREDIT_CORE, creditPool);

        vault = new Venue(usdc, IConfig(address(config)), address(factory), PoolTypes.CORE, owner, "Qudi Core", "qCORE");

        fast = new MockVenue(usdc, "Fast", "F");
        slow = new MockVenue(usdc, "Slow", "S");
        slow.setRedeemDelay(2 days);
        vm.startPrank(owner);
        vault.addVenue(address(fast));
        vault.addVenue(address(slow));
        address[] memory vs = new address[](2);
        vs[0] = address(fast);
        vs[1] = address(slow);
        uint16[] memory bps = new uint16[](2);
        bps[0] = 7_500;
        bps[1] = 2_500;
        vault.setWeights(vs, bps);
        vm.stopPrank();

        usdc.mint(seedHolder, SEED);
        vm.startPrank(seedHolder);
        usdc.approve(address(vault), SEED);
        vault.deposit(SEED, seedHolder);
        vm.stopPrank();

        usdc.setBlocked(blockedReceiver, true);

        handler = new VenueHandler(vault, fast, slow, creditPool, [ledgerA, ledgerB], seedHolder, blockedReceiver);
        targetContract(address(handler));
    }

    /// The member price never falls unless a venue lost money. A gain cannot lower it: the split is
    /// minted out of the gain, so the members keep the member leg and the price ends at or above
    /// where the last settle left it. The `+ 1` is the one direction rounding can push it: a
    /// deposit mints shares rounded down and a withdrawal burns them rounded up, both of which
    /// leave the remaining holders a shade better off.
    function invariant_memberPriceNeverFallsWithoutLoss() public view {
        // if the handler recorded no venue loss since the last settle, the member price is at or
        // above the last settled price
        if (!handler.lossSinceSettle()) {
            assertGe(
                vault.convertToAssets(1e6) + 1, handler.lastSettledPrice(), "the member price fell with nothing lost"
            );
        }
    }

    /// Nobody buys into a gain they were not there for. Every gain is settled before the deposit
    /// that follows it is priced, so a deposit is never worth more than it paid: measured on the
    /// newcomer's own shares at the moment they land (see `VenueHandler.freeGainObserved`),
    /// which is the side of the split the depositor can actually see.
    function invariant_noFreeGainForNewcomers() public view {
        assertFalse(handler.freeGainObserved(), "a deposit was worth more than the USDC it paid");
    }

    /// The verbs that reach the vault but settle nothing and move no value leave the member price
    /// exactly as they found it: `setWeights`, `cancelRedeem`, `releaseHeldPayout`. Not a floor
    /// like `invariant_memberPriceNeverFallsWithoutLoss`, an equality.
    function invariant_nonSettlingVerbsLeaveThePriceAlone() public view {
        assertFalse(handler.priceMovedWithoutSettle(), "a verb that settles nothing moved the member price");
    }

    /// The protocol and credit legs together are 30% of every gain ever harvested
    /// (YIELD_SPLIT_POOL 1500 plus YIELD_SPLIT_PROTOCOL 1500 at the launch defaults this
    /// fixture never changes), and the member leg is the rest.
    ///
    /// The fee-share version of this was rewritten from a relative-tolerance comparison to the
    /// directional property that is actually true, and then had to price the per-settle bound at
    /// each settle's own share price, because the same two share-wei of rounding cost more in
    /// asset terms the higher a campaign had drifted the price. The asset skim removes that
    /// whole problem: `protocolLeg` and `poolLeg` are floor divisions of a USDC gain into USDC, no
    /// share price enters the arithmetic, and the bound is two raw units per harvest at every
    /// price level the campaign can reach.
    ///
    /// Two parts, checked separately because they are not the same shape. **Never exceeds, in
    /// aggregate, with zero tolerance**: Qudi is never overpaid, which holds because
    /// `sum(floor(x_i)) <= floor(sum(x_i))` for every partition. **Falls short by at most two
    /// units per harvest, checked per harvest**, in `_observe()`.
    function invariant_skimmedLegsMatchSplit() public view {
        uint256 expected = (handler.positiveGains() * 3000) / 10_000;
        uint256 skimmed = handler.skimmedLegs();
        if (expected == 0) {
            assertEq(skimmed, 0, "legs were skimmed with no gain to skim them from");
            return;
        }
        assertLe(skimmed, expected, "the skim must never exceed 30% of the gain (Qudi is never overpaid)");
        assertEq(
            handler.worstShortfallOverBound(),
            0,
            "some harvest's skim fell short of its own 30% by more than its two floor divisions"
        );
        // The member leg is the residual the harvest reported, so the three legs close on the gain.
        assertEq(handler.memberGains() + skimmed, handler.positiveGains(), "the three legs do not close on the gain");
    }

    /// Property 5 of the Yield Engine, across the whole campaign: `totalAssets()` never reports a
    /// value the vault cannot honour. Checked inside the handler after every verb that reaches the
    /// vault and after every warp (see `VenueHandler._honourable`), rather than only here at
    /// the end of a sequence, so the violating step is the one that latches it.
    function invariant_totalAssetsIsHonourable() public view {
        assertFalse(handler.reportedMoreThanHeld(), "totalAssets reported more than the vault holds");
        assertLe(vault.totalAssets(), vault.liveAssets(), "totalAssets exceeds the live value");
        assertLe(vault.totalAssets(), vault.recognizedAssets(), "totalAssets exceeds the recognized value");
    }

    /// Property 4 of the Yield Engine, standing: what the unlock is holding back is never in the
    /// reported price. Stated as the identity the implementation has to satisfy at every point in
    /// every sequence, so a mutation that drops the subtraction, or holds back the wrong amount,
    /// kills it.
    ///
    /// The waterfall makes this an exact identity with no clamp. Before it, a venue could lose more than the
    /// vault had recognized while a harvest's member leg was still unreleased, the held-back figure
    /// would exceed anything left to hold back, and `totalAssets()` floored at zero: a reported
    /// price of zero with live assets in the venue, and the remainder surfacing behind zero shares
    /// once the schedule decayed. The loss now consumes the promise first, so the held-back figure
    /// can never exceed the recognized total and the clamp never engages.
    function invariant_unreleasedProfitIsNeverInThePrice() public view {
        assertEq(
            vault.totalAssets() + vault.unreleasedProfit(),
            vault.recognizedAssets(),
            "totalAssets is not the recognized total less what is held back"
        );
        assertFalse(handler.reportedTotalFloored(), "the reported total floored against the recognized total");
    }

    /// The waterfall, across the campaign: the promise is charged before the share price, never
    /// for more than the loss it is absorbing, and the reserve is never burned for a loss the
    /// promise covered outright. Both latches are set inside the handler at the absorb that would
    /// have violated them, off the vault's own `LossAbsorbed` figures.
    function invariant_lossEatsTheJuniorClaimFirst() public view {
        assertFalse(handler.waterfallOverCharged(), "an absorb charged the promise or the reserve out of order");
        assertLe(
            handler.profitAbsorbed(),
            handler.lossAbsorbed(),
            "more unreleased profit was consumed than there were losses to consume it"
        );
    }

    /// An absorb never raises the price, over every path the campaign reaches rather than the handful a unit test
    /// enumerates: an absorb never increases the share price. Measured across `report()`, which is
    /// an absorb and nothing else (see `VenueHandler.report`), so the comparison is exact and
    /// carries no tolerance.
    function invariant_anAbsorbNeverRaisesThePrice() public view {
        assertFalse(handler.absorbRaisedThePrice(), "a loss absorb raised the member share price");
        assertEq(handler.worstPriceRiseAtAnAbsorb(), 0, "the largest price rise an absorb produced was not zero");
    }

    /// A loss is absorbed by the reserve before it ever reaches the member price. The "the reserve
    /// covered it" condition is inside the ghost (see `VenueHandler.membersTookLoss`), measured
    /// at the settle that would have violated it, which is what makes it immune to the reserve
    /// being refilled or exhausted later.
    function invariant_reserveBurnsBeforeMembers() public view {
        assertFalse(handler.membersTookLoss(), "a report lowered the member price while the reserve still had shares");
    }

    /// Nobody carries out more USDC than their shares are worth: everything paid to a holder is
    /// covered by what the holders put in plus the member leg of the gains that were settled.
    function invariant_noHolderRedeemsMoreThanWorth() public view {
        assertLe(
            handler.paidOut(),
            handler.depositedIn() + handler.memberGains() + 10,
            "more USDC was paid out than was deposited plus credited"
        );
    }

    /// Three statements, one property. The weights standing on the vault right now respect the slow
    /// tier ceiling; no `setWeights` was ever accepted that broke it; and no `rebalance` left the
    /// slow tier holding more than the ceiling allows (measured in the handler immediately after
    /// each rebalance -- see `VenueHandler.rebalance` for why it cannot be a standing check).
    function invariant_tierLimitsHold() public view {
        assertLe(vault.weightBps(address(slow)), config.slowTierCeilingBps(), "slow tier weighted above its ceiling");
        assertEq(handler.weightBreaches(), 0, "a setWeights above the slow tier ceiling was accepted");
        assertEq(handler.tierBreaches(), 0, "a rebalance left the slow tier above its ceiling");
    }

    /// Every share is in exactly one of the three places left that can hold one. It was six under
    /// the fee-share model; the asset skim took the unclaimed credit leg, the treasury's protocol leg and
    /// the credit pool's holding out of the share ledger entirely by paying all three in USDC, and
    /// the second half of this asserts that they are really gone rather than merely unused.
    function invariant_supplyAccounting() public view {
        assertEq(
            vault.totalSupply(),
            handler.sumLedgerBalances() + vault.reserveShares() + handler.sumQueuedShares(),
            "shares exist outside the three places that may hold them"
        );
        assertEq(vault.balanceOf(treasury), 0, "the protocol leg is not paid in shares");
        assertEq(vault.balanceOf(creditPool), 0, "no credit capital sits in the savings vault as shares");
    }

    /// Carried forward from the deleted QAMO/CommunityVault harnesses: shares are never held by an EOA
    /// or a member -- only registered community contracts, the vault itself, and the protocol treasury.
    /// The second half pins what the vault's own balance is made of, which is what stops a share
    /// going missing between the reserve, the unclaimed pool leg and the queue and still adding up.
    function invariant_sharesOnlyAtPermittedHolders() public view {
        assertEq(vault.balanceOf(address(handler)), 0, "the handler holds shares");
        assertEq(vault.balanceOf(stranger), 0, "an unregistered address holds shares");
        assertEq(vault.balanceOf(blockedReceiver), 0, "a payout receiver holds shares");
        assertEq(vault.balanceOf(owner), 0, "the owner holds shares");
        assertEq(
            vault.balanceOf(address(vault)),
            vault.reserveShares() + handler.sumQueuedShares(),
            "the vault's own share balance is not the reserve plus the queue"
        );
    }

    /// Carried forward from the deleted QAMO/CommunityVault harnesses: USDC closes. What the vault
    /// holds (held payouts included -- they are in the balance, just not in `idle()`), plus what
    /// the venues hold for it, plus everything ever paid out, plus everything ever skimmed out of a
    /// venue as a loss, equals everything ever put in plus everything ever gained in a venue.
    ///
    /// Exact, with no dust allowance, and that is the point: every USDC movement in this fixture
    /// has a counterpart on one side or the other, so a single unit unaccounted for is a unit that
    /// went somewhere nobody is watching. The venue leg is the venue's own USDC balance rather than
    /// `convertToAssets(shares)`: the vault owns every share either venue has issued (asserted
    /// first, because the rest depends on it), so the venue's balance is the vault's money, whereas
    /// the ERC-4626 read of it rounds down by the virtual-offset gap -- which grows with the venue's
    /// price and is a reading artefact, not money that left.
    function invariant_usdcClosure() public view {
        assertEq(fast.totalSupply(), fast.balanceOf(address(vault)), "the vault is not the fast venue's only holder");
        assertEq(slow.totalSupply(), slow.balanceOf(address(vault)), "the vault is not the slow venue's only holder");
        uint256 accountedFor = usdc.balanceOf(address(vault)) + usdc.balanceOf(address(fast))
            + usdc.balanceOf(address(slow)) + handler.paidOut() + handler.venueLosses()
            // The two skimmed legs, once claimed, are USDC sitting at their destinations. Before a
            // claim they are still in the vault's own balance, counted by the first term.
            + usdc.balanceOf(treasury) + usdc.balanceOf(creditPool);
        uint256 everIn = SEED + handler.depositedIn() + handler.reserveFunded() + handler.venueGains();
        assertEq(accountedFor, everIn, "USDC was created or went missing");
    }
}

