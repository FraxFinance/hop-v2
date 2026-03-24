// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import { DeployRemoteHopV2 } from "./DeployRemoteHopV2.s.sol";

// forge script src/script/hop/DeployRemoteHopV2Katana.s.sol --rpc-url https://rpc.katana.network --broadcast --gcp --sender 0x54f9b12743a7deec0ea48721683cbebedc6e17bc
// verify via etherscan v2 (katanascan) after deployment:
// FOUNDRY_PROFILE=deploy forge verify-contract <addr> <contract> --chain-id 747474 --verifier etherscan --verifier-url "https://api.etherscan.io/v2/api?chainid=747474" --etherscan-api-key $ETHERSCAN_API_KEY --compiler-version "v0.8.23+commit.f704f362"
contract DeployRemoteHopV2Katana is DeployRemoteHopV2 {
    constructor() {
        proxyAdmin = 0x223a681fc5c5522c85C96157c0efA18cd6c5405c;
        endpoint = 0x6F475642a6e85809B1c36Fa62763669b1b48DD5B;
        localEid = 30_375;

        msig = 0x19A90b0476cdc8EC1239266663CA820175B9B527;

        EXECUTOR = 0x4208D6E27538189bB48E603D6123A94b8Abe0A0b;
        DVN = 0x282b3386571f7f794450d5789911a9804FA346b4;
        SEND_LIBRARY = 0xC39161c743D0307EB9BCc9FEF03eeb9Dc4802de7;

        frxUsdOft = 0x80Eede496655FB9047dd39d9f418d5483ED600df;
        sfrxUsdOft = 0x5Bff88cA1442c2496f7E475E9e7786383Bc070c0;
        frxEthOft = 0x43eDD7f3831b08FE70B7555ddD373C8bF65a9050;
        sfrxEthOft = 0x3Ec3849C33291a9eF4c5dB86De593EB4A37fDe45;
        wFraxOft = 0x64445f0aecC51E94aD52d8AC56b7190e764E561a;
        fpiOft = 0x90581eCa9469D8D7F5D3B60f4715027aDFCf7927;
    }
}
