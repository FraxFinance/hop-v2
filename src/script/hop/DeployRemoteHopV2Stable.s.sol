// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import { DeployRemoteHopV2 } from "./DeployRemoteHopV2.s.sol";

// forge script src/script/hop/DeployRemoteHopV2Stable.s.sol --rpc-url https://rpc.stable.xyz --broadcast --slow --gcp --sender 0x54f9b12743a7deec0ea48721683cbebedc6e17bc
// verify: forge verify-contract <addr> <contract> --chain-id 988 --verifier custom --verifier-url "https://api.etherscan.io/v2/api?chainid=988" --verifier-api-key $ETHERSCAN_API_KEY --compiler-version "v0.8.23+commit.f704f362" --watch
contract DeployRemoteHopV2Stable is DeployRemoteHopV2 {
    constructor() {
        proxyAdmin = 0x223a681fc5c5522c85C96157c0efA18cd6c5405c;
        endpoint = 0x6F475642a6e85809B1c36Fa62763669b1b48DD5B;
        localEid = 30_396;

        msig = 0x0C46f54BF9EF8fd58e2D294b8cEA488204EcB3D8;

        EXECUTOR = 0x4208D6E27538189bB48E603D6123A94b8Abe0A0b;
        DVN = 0x9C061c9A4782294eeF65ef28Cb88233A987F4bdD;
        SEND_LIBRARY = 0x37aaaf95887624a363effB7762D489E3C05c2a02;

        frxUsdOft = 0x80Eede496655FB9047dd39d9f418d5483ED600df;
        sfrxUsdOft = 0x5Bff88cA1442c2496f7E475E9e7786383Bc070c0;
        frxEthOft = 0x43eDD7f3831b08FE70B7555ddD373C8bF65a9050;
        sfrxEthOft = 0x3Ec3849C33291a9eF4c5dB86De593EB4A37fDe45;
        wFraxOft = 0x64445f0aecC51E94aD52d8AC56b7190e764E561a;
        fpiOft = 0x90581eCa9469D8D7F5D3B60f4715027aDFCf7927;
    }
}
