// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import { UpgradeRemoteHopV2 } from "src/script/hop/upgrade/UpgradeRemoteHopV2.s.sol";

// Generate the upgrade batch for a chain whose 2.1.0 implementation was already deployed (for example by a replayed
// deployment on an EraVM chain). The implementation is not deterministic, so pass it explicitly:
//
//   NEW_IMPLEMENTATION=0x... forge script src/script/hop/upgrade/GenerateRemoteHopV2Txs.s.sol --rpc-url <rpc> --ffi
//
// The address is refused unless it carries code whose `version()` is 2.1.0. That check exists because an earlier
// revision pointed at `0xD3b7B923990000003500009264561127A87B00Bd`, a contract with 19069 bytes of code and no
// `version()`, which the code-length check inside `upgradeAndCall` would have accepted and bricked the proxy.
interface IVersioned {
    function version() external view returns (string memory);
}

contract GenerateRemoteHopV2Txs is UpgradeRemoteHopV2 {
    /// @dev The batch may only point at code that reports this release's version.
    function deployImplementation() internal override {
        address impl = vm.envAddress("NEW_IMPLEMENTATION");
        require(impl.code.length != 0, "implementation has no code");
        require(keccak256(bytes(IVersioned(impl).version())) == keccak256("2.1.0"), "implementation is not Hop 2.1.0");
        newImplementation = impl;
    }
}
