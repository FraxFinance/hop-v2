pragma solidity ^0.8.0;

import { UpgradeRemoteHopV2 } from "src/script/hop/upgrade/UpgradeRemoteHopV2.s.sol";

// Generate upgrade msig txs for chains where RemoteHopV201 was deployed via replayed txns
// forge script src/script/hop/upgrade/GenerateRemoteHopV2Txs.s.sol --rpc-url https://api.infra.mainnet.somnia.network --ffi
// forge script src/script/hop/upgrade/GenerateRemoteHopV2Txs.s.sol --rpc-url https://rpc.hyperliquid.xyz/evm --ffi
// forge script src/script/hop/upgrade/GenerateRemoteHopV2Txs.s.sol --rpc-url https://mainnet.era.zksync.io --ffi
// forge script src/script/hop/upgrade/GenerateRemoteHopV2Txs.s.sol --rpc-url https://api.mainnet.abs.xyz --ffi
contract GenerateRemoteHopV2Txs is UpgradeRemoteHopV2 {
    function deployImplementation() internal override {
        newImplementation = 0xD3b7B923990000003500009264561127A87B00Bd;
    }
}
