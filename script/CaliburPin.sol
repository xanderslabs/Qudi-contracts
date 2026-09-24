// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.30;

/// The Calibur delegate Qudi accounts point at: Uniswap's `CaliburEntry` v1.1.0, at the address its
/// published salt gives through the deterministic deployer. Every value here is checked against the
/// others, so a wrong build cannot pass as the right one:
///   - the init code hash, with the salt and the deployer, gives the canonical address;
///   - the runtime hash is the code that init code leaves at that address, the same on every chain,
///     because its only immutables are its own address and two constant name hashes.
library CaliburPin {
    address internal constant CANONICAL = 0x000000005c84F8Fd50b21CAC312528A64437030e;
    /// The CREATE2 deployer present on every chain Qudi runs on.
    address internal constant DETERMINISTIC_DEPLOYER = 0x4e59b44847b379578588920cA78FbF26c0B4956C;
    bytes32 internal constant SALT = 0x3b55ce071a9e4ef8dd49e65ab8ba6c747bec4c1c5b8efc95909fb463c4e53396;
    /// `CaliburEntry.sol` names this compiler exactly. `script/build-calibur.sh` builds with it.
    string internal constant SOLC = "0.8.29+commit.ab55807c";
    bytes32 internal constant INIT_CODE_HASH = 0xd3a7ea2bc0c320de0cb9288c0a3f67e8e07f7982d99fdac28208501bd1e74149;
    bytes32 internal constant RUNTIME_CODE_HASH = 0xba697585ba58ba66ebd095ab4c7f980ed42ad115b2e3bb9b5b9bdf167bf08b1b;
    /// Where `script/build-calibur.sh` leaves the build.
    string internal constant ARTIFACT = "cache/calibur/out/CaliburEntry.sol/CaliburEntry.json";
}
