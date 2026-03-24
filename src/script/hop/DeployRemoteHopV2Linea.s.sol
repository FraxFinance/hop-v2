// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import { DeployRemoteHopV2 } from "./DeployRemoteHopV2.s.sol";

// forge script src/script/hop/DeployRemoteHopV2Linea.s.sol --rpc-url https://rpc.linea.build --broadcast --verify --verifier etherscan --etherscan-api-key $LINEASCAN_API_KEY
contract DeployRemoteHopV2Linea is DeployRemoteHopV2 {
    constructor() {
        proxyAdmin = 0x3cf371c128b092b085B7732069cEAF3Fd863F270;
        endpoint = 0x1a44076050125825900e736c501f859c50fE728c;
        localEid = 30_183;

        msig = 0x0E5a5284820E350ffce7fe7ba3364FaC1C53eaFD;

        EXECUTOR = 0x0408804C5dcD9796F22558464E6fE5bDdF16A7c7;
        DVN = 0x129Ee430Cb2Ff2708CCADDBDb408a88Fe4FFd480;
        SEND_LIBRARY = 0x32042142DD551b4EbE17B6FEd53131dd4b4eEa06;

        frxUsdOft = 0xC7346783f5e645aa998B106Ef9E7f499528673D8;
        sfrxUsdOft = 0x592a48c0FB9c7f8BF1701cB0136b90DEa2A5B7B6;
        frxEthOft = 0xB1aFD04774c02AE84692619448B08BA79F19b1ff;
        sfrxEthOft = 0x383Eac7CcaA89684b8277cBabC25BCa8b13B7Aa2;
        wFraxOft = 0x5217Ab28ECE654Aab2C68efedb6A22739df6C3D5;
        fpiOft = 0xDaF72Aa849d3C4FAA8A9c8c99f240Cf33dA02fc4;
    }
}
