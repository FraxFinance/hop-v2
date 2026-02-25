// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import { DeployRemoteHopV2 } from "./DeployRemoteHopV2.s.sol";

// forge script src/script/hop/DeployRemoteHopV2Ink.s.sol --rpc-url https://rpc-gel.inkonchain.com --broadcast --gcp --sender 0x54f9b12743a7deec0ea48721683cbebedc6e17bc
// note: blockscout verifier is broken on ink; verify via routescan after deployment:
// FOUNDRY_PROFILE=deploy forge verify-contract <addr> <contract> --chain-id 57073 --verifier etherscan --verifier-url "https://api.routescan.io/v2/network/mainnet/evm/57073/etherscan" --etherscan-api-key "verifyContract" --compiler-version "v0.8.23+commit.f704f362"
contract DeployRemoteHopV2Ink is DeployRemoteHopV2 {
    constructor() {
        proxyAdmin = 0x223a681fc5c5522c85C96157c0efA18cd6c5405c;
        endpoint = 0xca29f3A6f966Cb2fc0dE625F8f325c0C46dbE958;
        localEid = 30_339;

        msig = 0x91eBC17cD330DD694225133455583FBCA54b8eC8;

        EXECUTOR = 0xFEbCF17b11376C724AB5a5229803C6e838b6eAe5;
        DVN = 0x174F2bA26f8ADeAfA82663bcf908288d5DbCa649;
        SEND_LIBRARY = 0x76111DE813F83AAAdBD62773Bf41247634e2319a;

        frxUsdOft = 0x80Eede496655FB9047dd39d9f418d5483ED600df;
        sfrxUsdOft = 0x5Bff88cA1442c2496f7E475E9e7786383Bc070c0;
        frxEthOft = 0x43eDD7f3831b08FE70B7555ddD373C8bF65a9050;
        sfrxEthOft = 0x3Ec3849C33291a9eF4c5dB86De593EB4A37fDe45;
        wFraxOft = 0x64445f0aecC51E94aD52d8AC56b7190e764E561a;
        fpiOft = 0x90581eCa9469D8D7F5D3B60f4715027aDFCf7927;
    }
}
