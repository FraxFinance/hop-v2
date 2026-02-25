// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import { DeployRemoteHopV2 } from "./DeployRemoteHopV2.s.sol";

// forge script src/script/hop/DeployRemoteHopV2Hyperliquid.s.sol --rpc-url https://rpc.hyperliquid.xyz/evm --broadcast --verify --verifier etherscan --etherscan-api-key $ETHERSCAN_API_KEY --chain-id 999 --verifier-url https://api.etherscan.io/v2/api --gcp --sender 0x54f9b12743a7deec0ea48721683cbebedc6e17bc
contract DeployRemoteHopV2Hyperliquid is DeployRemoteHopV2 {
    constructor() {
        proxyAdmin = 0x223a681fc5c5522c85C96157c0efA18cd6c5405c;
        endpoint = 0x3A73033C0b1407574C76BdBAc67f126f6b4a9AA9;
        localEid = 30_367;

        msig = 0x738ee62157f127C879Ff5c4B7102Eb0d166C7a6d;

        EXECUTOR = 0x41Bdb4aa4A63a5b2Efc531858d3118392B1A1C3d;
        DVN = 0xc097ab8CD7b053326DFe9fB3E3a31a0CCe3B526f;
        SEND_LIBRARY = 0xfd76d9CB0Bac839725aB79127E7411fe71b1e3CA;

        frxUsdOft = 0x80Eede496655FB9047dd39d9f418d5483ED600df;
        sfrxUsdOft = 0x5Bff88cA1442c2496f7E475E9e7786383Bc070c0;
        frxEthOft = 0x43eDD7f3831b08FE70B7555ddD373C8bF65a9050;
        sfrxEthOft = 0x3Ec3849C33291a9eF4c5dB86De593EB4A37fDe45;
        wFraxOft = 0x64445f0aecC51E94aD52d8AC56b7190e764E561a;
        fpiOft = 0x90581eCa9469D8D7F5D3B60f4715027aDFCf7927;
    }
}
