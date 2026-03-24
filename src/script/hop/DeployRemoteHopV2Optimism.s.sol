// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import { DeployRemoteHopV2 } from "./DeployRemoteHopV2.s.sol";

// forge script src/script/hop/DeployRemoteHopV2Optimism.s.sol --rpc-url https://mainnet.optimism.io --broadcast --verify --verifier etherscan --etherscan-api-key $ETHERSCAN_API_KEY --gcp --sender 0x54f9b12743a7deec0ea48721683cbebedc6e17bc
contract DeployRemoteHopV2Optimism is DeployRemoteHopV2 {
    constructor() {
        proxyAdmin = 0x223a681fc5c5522c85C96157c0efA18cd6c5405c;
        endpoint = 0x1a44076050125825900e736c501f859c50fE728c;
        localEid = 30_111;

        msig = 0x419e672d625f998dd07a7ecf2E06B896F8717cb2;

        EXECUTOR = 0x2D2ea0697bdbede3F01553D2Ae4B8d0c486B666e;
        DVN = 0x6A02D83e8d433304bba74EF1c427913958187142;
        SEND_LIBRARY = 0x1322871e4ab09Bc7f5717189434f97bBD9546e95;

        frxUsdOft = 0x80Eede496655FB9047dd39d9f418d5483ED600df;
        sfrxUsdOft = 0x5Bff88cA1442c2496f7E475E9e7786383Bc070c0;
        frxEthOft = 0x43eDD7f3831b08FE70B7555ddD373C8bF65a9050;
        sfrxEthOft = 0x3Ec3849C33291a9eF4c5dB86De593EB4A37fDe45;
        wFraxOft = 0x64445f0aecC51E94aD52d8AC56b7190e764E561a;
        fpiOft = 0x90581eCa9469D8D7F5D3B60f4715027aDFCf7927;
    }
}
