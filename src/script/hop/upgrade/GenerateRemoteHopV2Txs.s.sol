pragma solidity ^0.8.0;

import { UpgradeRemoteHopV2 } from "src/script/hop/upgrade/UpgradeRemoteHopV2.s.sol";

// Generate upgrade msig txs for chains where RemoteHopV201 was deployed via replayed txns
// forge script src/script/hop/upgrade/GenerateRemoteHopV2Txs.s.sol --rpc-url https://api.infra.mainnet.somnia.network --ffi
// forge script src/script/hop/upgrade/GenerateRemoteHopV2Txs.s.sol --rpc-url https://rpc.hyperliquid.xyz/evm --ffi
// forge script src/script/hop/upgrade/GenerateRemoteHopV2Txs.s.sol --rpc-url https://mainnet.era.zksync.io --ffi
// forge script src/script/hop/upgrade/GenerateRemoteHopV2Txs.s.sol --rpc-url https://api.mainnet.abs.xyz --ffi
contract GenerateRemoteHopV2Txs is UpgradeRemoteHopV2 {
    /// @dev Points at the already-deployed canonical `RemoteHopV201`, the same address
    ///      `UpgradeRemoteHopV2.s.sol` mines and every chain's proxy now delegates to.
    ///      This previously held `0xD3b7B923990000003500009264561127A87B00Bd`, which is
    ///      NOT a HopV201 implementation: it has no `version()` and no
    ///      `feeMultipliers()`, yet it does carry 19069 bytes of code on all four target
    ///      chains, so the code-length check inside `upgradeAndCall` would have passed
    ///      and the generated batch would have bricked the proxy. The assert below makes
    ///      that class of mistake impossible to turn into a batch.
    function deployImplementation() internal override {
        newImplementation = 0x0000000f9a66622C8885E1071B78E37b2b3ecCCd;

        require(newImplementation.code.length != 0, "implementation has no code");
        (bool ok, bytes memory out) = newImplementation.staticcall(abi.encodeWithSignature("version()"));
        require(ok && keccak256(out) == keccak256(abi.encode("2.0.1")), "implementation is not HopV201 2.0.1");
    }
}
