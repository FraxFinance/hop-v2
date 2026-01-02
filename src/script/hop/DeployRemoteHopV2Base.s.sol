// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import { DeployRemoteHopV2 } from "./DeployRemoteHopV2.s.sol";

// forge script src/script/hop/Remote/DeployRemoteHopV2Base.s.sol --rpc-url https://mainnet.base.org --broadcast --verify --verifier etherscan --etherscan-api-key $BASESCAN_API_KEY
contract DeployRemoteHopV2Base is DeployRemoteHopV2 {
    constructor() {
        EXECUTOR = 0x2CCA08ae69E0C44b18a57Ab2A87644234dAebaE4;
        DVN = 0x9e059a54699a285714207b43B055483E78FAac25;
        SEND_LIBRARY = 0xB5320B0B3a13cC860893E2Bd79FCd7e13484Dda2;

        proxyAdmin = 0xF59C41A57AB4565AF7424F64981523DfD7A453c5;
        endpoint = 0x1a44076050125825900e736c501f859c50fE728c;
        gasPriceOracle = 0x6506D235cBac14222f91B975594AAa0c723FE486;
        localEid = 30_184;

        msig = 0xCBfd4Ef00a8cf91Fd1e1Fe97dC05910772c15E53;

        frxUsdOft = 0xe5020A6d073a794B6E7f05678707dE47986Fb0b6;
        sfrxUsdOft = 0x91A3f8a8d7a881fBDfcfEcd7A2Dc92a46DCfa14e;
        frxEthOft = 0x7eb8d1E4E2D0C8b9bEDA7a97b305cF49F3eeE8dA;
        sfrxEthOft = 0x192e0C7Cc9B263D93fa6d472De47bBefe1Fb12bA;
        wFraxOft = 0x0CEAC003B0d2479BebeC9f4b2EBAd0a803759bbf;
        fpiOft = 0xEEdd3A0DDDF977462A97C1F0eBb89C3fbe8D084B;
    }
}
