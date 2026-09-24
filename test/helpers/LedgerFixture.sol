// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {Clones} from "openzeppelin-contracts/contracts/proxy/Clones.sol";
import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {Ledger} from "../../src/Ledger.sol";
import {ILedger} from "../../src/interfaces/ILedger.sol";
import {ICommunityInit} from "../../src/interfaces/ICommunityInit.sol";
import {Venue} from "../../src/Venue.sol";
import {Config} from "../../src/Config.sol";
import {IConfig} from "../../src/interfaces/IConfig.sol";
import {ComplianceRegistry} from "../../src/ComplianceRegistry.sol";
import {ConfigKeys as K} from "../../src/ConfigKeys.sol";
import {PoolTypes} from "../../src/PoolTypes.sol";
import {MockUSDC} from "../mocks/MockUSDC.sol";
import {MockVenue} from "../mocks/MockVenue.sol";

/// A stand-in factory: answers isCommunityContract for addresses we register, hands the ledger the
/// community id the credit leg is booked against, and holds Qudi's tier vaults in `pools`, which
/// is what the ledger resolves a tier from now that the host opt-in is gone.
contract LedgerFactoryStub {
    mapping(address => bool) public isCommunityContract;
    mapping(address => uint256) public communityIdOf;
    address[3] public pools;

    function register(address a) external {
        isCommunityContract[a] = true;
        communityIdOf[a] = 1;
    }

    function setPool(uint8 poolType, address vault) external {
        pools[poolType] = vault;
    }
}

/// Membership and the host, set directly by the test. The real `Community` answers the same two
/// questions and nothing else the ledger asks. A suspended or frozen member is simply
/// not a member (`isMember` false), so there is no separate suspension answer to stub.
contract LedgerSeatsStub {
    mapping(address => bool) public isMember;
    address public steward;

    function setMember(address a, bool v) external {
        isMember[a] = v;
    }

    function setSteward(address a) external {
        steward = a;
    }
}

/// The singleton CreditCore's community leg door. Checks the USDC arrived, exactly as the
/// real one does with `LegNotFunded`, so a leg nobody paid cannot pass here either.
contract LedgerCreditCoreStub {
    IERC20 public immutable usdc;
    mapping(uint256 => uint256) public legOf;
    uint256 internal _booked;

    error LegNotFunded();

    constructor(IERC20 usdc_) {
        usdc = usdc_;
    }

    function receiveCommunityLeg(uint256 communityId, uint256 amount) external {
        if (usdc.balanceOf(address(this)) < _booked + amount) revert LegNotFunded();
        _booked += amount;
        legOf[communityId] += amount;
    }
}

/// One community's ledger over real `Venue` tier instances, wired the way `CommunityFactory`
/// wires it. Two tiers carry real vaults, FLEX and CORE, because the proofs need both an
/// instant path and a queued one; nothing opens them, because there is nothing
/// to open. No tier vault carries a lock of its own since the vault-level one was deleted, so the
/// ledger's `lockedUntil` is the only lock there is.
abstract contract LedgerFixture is Test {
    MockUSDC usdc;
    Config config;
    ComplianceRegistry registry;
    LedgerFactoryStub factory;
    LedgerSeatsStub community;
    LedgerCreditCoreStub creditCore;
    Ledger ledger;

    Venue flexVault;
    Venue coreVault;
    /// Every tier Qudi deploys, so the stub factory's `pools` matches the real one's promise that
    /// no slot is ever zero. Only FLEX and CORE carry venues; TERM exists so a test
    /// can reach a tier this fixture never otherwise touches.
    Venue[3] tierVaults;
    MockVenue flexVenue;
    MockVenue coreVenue;

    address owner = makeAddr("vaultOwner");
    address treasury = makeAddr("treasury");
    address host = makeAddr("host");
    address ada = makeAddr("ada");
    address bea = makeAddr("bea");
    address cid = makeAddr("cid");
    address dan = makeAddr("dan");
    address stranger = makeAddr("stranger");
    address payee = makeAddr("payee");

    function setUpLedger() internal {
        usdc = new MockUSDC();
        registry = new ComplianceRegistry(address(this));
        vm.prank(owner);
        config = new Config(address(usdc), treasury, address(registry));

        factory = new LedgerFactoryStub();

        for (uint8 t = 0; t < PoolTypes.COUNT; t++) {
            tierVaults[t] = _tierVault(t, "Qudi Tier", "qT");
            factory.setPool(t, address(tierVaults[t]));
        }
        flexVault = tierVaults[PoolTypes.FLEX];
        coreVault = tierVaults[PoolTypes.CORE];
        flexVenue = _venue(flexVault, "Flex venue", "FV");
        coreVenue = _venue(coreVault, "Core venue", "CV");

        community = new LedgerSeatsStub();
        creditCore = new LedgerCreditCoreStub(IERC20(address(usdc)));
        vm.prank(owner);
        config.setAddress(K.CREDIT_CORE, address(creditCore));

        ledger = Ledger(Clones.clone(address(new Ledger())));
        ledger.initialize(
            ICommunityInit.CommunityWiring({
                config: address(config),
                factory: address(factory),
                community: address(community),
                vault: address(0),
                creator: host,
                seatPrice: 10e6,
                name: "Test Community",
                poolType: 0
            })
        );
        factory.register(address(ledger));

        community.setSteward(host);
        address[6] memory people = [host, ada, bea, cid, dan, payee];
        for (uint256 i = 0; i < 5; i++) {
            community.setMember(people[i], true);
        }
        for (uint256 i = 0; i < 6; i++) {
            usdc.mint(people[i], 1_000_000e6);
            vm.prank(people[i]);
            usdc.approve(address(ledger), type(uint256).max);
        }
    }

    function _tierVault(uint8 poolType, string memory n, string memory s) internal returns (Venue v) {
        v = new Venue(usdc, IConfig(address(config)), address(factory), poolType, owner, n, s);
    }

    function _venue(Venue v, string memory n, string memory s) internal returns (MockVenue m) {
        m = new MockVenue(usdc, n, s);
        address[] memory vs = new address[](1);
        vs[0] = address(m);
        uint16[] memory bps = new uint16[](1);
        bps[0] = 10_000;
        vm.startPrank(owner);
        v.addVenue(address(m));
        v.setWeights(vs, bps);
        vm.stopPrank();
    }

    // ---- shorthands the proofs read better with ----

    function _personal(address who, uint8 poolType, uint64 lockedUntil) internal returns (uint256 id) {
        vm.prank(who);
        id = ledger.createVault(_params(poolType, false, lockedUntil, "personal"));
    }

    function _shared(uint8 poolType) internal returns (uint256 id) {
        vm.prank(host);
        id = ledger.createVault(_params(poolType, true, 0, "shared"));
    }

    function _params(uint8 poolType, bool shared, uint64 lockedUntil, string memory n)
        internal
        pure
        returns (ILedger.VaultParams memory)
    {
        return ILedger.VaultParams({
            poolType: poolType,
            shared: shared,
            lockedUntil: lockedUntil,
            contribution: 0, // Anytime
            name: n,
            target: 0,
            targetDate: 0
        });
    }

    function _deposit(address who, uint256 vaultId, uint256 amount) internal {
        vm.prank(who);
        ledger.deposit(vaultId, amount);
    }
}
