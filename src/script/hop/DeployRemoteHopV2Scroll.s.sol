// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import { DeployRemoteHopV2 } from "./DeployRemoteHopV2.s.sol";

// forge script src/script/hop/DeployRemoteHopV2Scroll.s.sol --rpc-url https://rpc.scroll.io --broadcast --verify --verifier etherscan --etherscan-api-key $ETHERSCAN_API_KEY --gcp --sender 0x54f9b12743a7deec0ea48721683cbebedc6e17bc
contract DeployRemoteHopV2Scroll is DeployRemoteHopV2 {
    constructor() {
        proxyAdmin = 0x8f1B9c1fd67136D525E14D96Efb3887a33f16250;
        endpoint = 0x1a44076050125825900e736c501f859c50fE728c;
        localEid = 30_214;

        msig = 0x73F365d34b81E731825a094c2E722A08574335cd;

        EXECUTOR = 0x581b26F362AD383f7B51eF8A165Efa13DDe398a4;
        DVN = 0xbe0d08a85EeBFCC6eDA0A843521f7CBB1180D2e2;
        SEND_LIBRARY = 0x9BbEb2B2184B9313Cf5ed4a4DDFEa2ef62a2a03B;

        frxUsdOft = 0x397F939C3b91A74C321ea7129396492bA9Cdce82;
        sfrxUsdOft = 0xC6B2BE25d65760B826D0C852FD35F364250619c2;
        frxEthOft = 0x0097Cf8Ee15800d4f80da8A6cE4dF360D9449Ed5;
        sfrxEthOft = 0x73382eb28F35d80Df8C3fe04A3EED71b1aFce5dE;
        wFraxOft = 0x879BA0EFE1AB0119FefA745A21585Fa205B07907;
        fpiOft = 0x93cDc5d29293Cb6983f059Fec6e4FFEb656b6a62;
    }
}
