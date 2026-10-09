// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import { DeployRemoteHopV2 } from "./DeployRemoteHopV2.s.sol";

// forge script src/script/hop/DeployRemoteHopV2Arbitrum.s.sol --rpc-url https://arbitrum.public.blockpi.network/v1/rpc/public --broadcast --verify --verifier etherscan --etherscan-api-key $ARBISCAN_API_KEY
contract DeployRemoteHopV2Arbitrum is DeployRemoteHopV2 {
    constructor() {
        EXECUTOR = 0x31CAe3B7fB82d847621859fb1585353c5720660D;
        DVN = 0x2f55C492897526677C5B68fb199ea31E2c126416;
        SEND_LIBRARY = 0x975bcD720be66659e3EB3C0e4F1866a3020E493A;

        proxyAdmin = 0x223a681fc5c5522c85C96157c0efA18cd6c5405c;
        endpoint = 0x1a44076050125825900e736c501f859c50fE728c;
        gasPriceOracle = 0x639Fe6ab55C921f74e7fac1ee960C0B6293ba612;
        localEid = 30_110;

        msig = 0x3da490b19F300E7cb2280426C8aD536dB2df445c;

        frxUsdOft = 0x80Eede496655FB9047dd39d9f418d5483ED600df;
        sfrxUsdOft = 0x5Bff88cA1442c2496f7E475E9e7786383Bc070c0;
        frxEthOft = 0x43eDD7f3831b08FE70B7555ddD373C8bF65a9050;
        sfrxEthOft = 0x3Ec3849C33291a9eF4c5dB86De593EB4A37fDe45;
        wFraxOft = 0x64445f0aecC51E94aD52d8AC56b7190e764E561a;
        fpiOft = 0x90581eCa9469D8D7F5D3B60f4715027aDFCf7927;
    }
}
