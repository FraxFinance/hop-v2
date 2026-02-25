// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import { DeployRemoteHopV2 } from "./DeployRemoteHopV2.s.sol";

// forge script src/script/hop/DeployRemoteHopV2Plume.s.sol --rpc-url https://rpc.plume.org --broadcast --verify --verifier blockscout --verifier-url https://explorer.plume.org/api/ --evm-version "shanghai" --gcp --sender 0x54f9b12743a7deec0ea48721683cbebedc6e17bc
contract DeployRemoteHopV2Plume is DeployRemoteHopV2 {
    constructor() {
        proxyAdmin = 0x223a681fc5c5522c85C96157c0efA18cd6c5405c;
        endpoint = 0xC1b15d3B262bEeC0e3565C11C9e0F6134BdaCB36;
        localEid = 30_370;

        msig = 0x77dDd3EC570EEAf2c513de3c833c5E82A721978B;

        EXECUTOR = 0x41Bdb4aa4A63a5b2Efc531858d3118392B1A1C3d;
        DVN = 0x4208D6E27538189bB48E603D6123A94b8Abe0A0b;
        SEND_LIBRARY = 0xFe7C30860D01e28371D40434806F4A8fcDD3A098;

        frxUsdOft = 0x80Eede496655FB9047dd39d9f418d5483ED600df;
        sfrxUsdOft = 0x5Bff88cA1442c2496f7E475E9e7786383Bc070c0;
        frxEthOft = 0x43eDD7f3831b08FE70B7555ddD373C8bF65a9050;
        sfrxEthOft = 0x3Ec3849C33291a9eF4c5dB86De593EB4A37fDe45;
        wFraxOft = 0x64445f0aecC51E94aD52d8AC56b7190e764E561a;
        fpiOft = 0x90581eCa9469D8D7F5D3B60f4715027aDFCf7927;
    }
}
