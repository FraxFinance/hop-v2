// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import { DeployRemoteHopV2 } from "./DeployRemoteHopV2.s.sol";

// Dry run: FOUNDRY_PROFILE=deploy forge script src/script/hop/DeployRemoteHopV2Somnia.s.sol --rpc-url https://api.infra.mainnet.somnia.network --gcp --sender 0x54f9b12743a7deec0ea48721683cbebedc6e17bc --gas-estimate-multiplier 2000
// Broadcast: FOUNDRY_PROFILE=deploy forge script src/script/hop/DeployRemoteHopV2Somnia.s.sol --rpc-url https://api.infra.mainnet.somnia.network --gcp --sender 0x54f9b12743a7deec0ea48721683cbebedc6e17bc --broadcast --verify --chain-id 5031 --watch --verifier-url https://explorer.somnia.network/api --verifier blockscout
contract DeployRemoteHopV2Somnia is DeployRemoteHopV2 {
    constructor() {
        proxyAdmin = 0x000000dbfaA1Fb91ca46867cE6D41aB6da4f7428;
        endpoint = 0x6F475642a6e85809B1c36Fa62763669b1b48DD5B;
        localEid = 30_380;

        msig = 0x9527e19F55d1afCE9F1e9Edcea79552bF41983F9;

        EXECUTOR = 0x4208D6E27538189bB48E603D6123A94b8Abe0A0b;
        DVN = 0x282b3386571f7f794450d5789911a9804FA346b4;
        SEND_LIBRARY = 0xC39161c743D0307EB9BCc9FEF03eeb9Dc4802de7;

        frxUsdOft = 0x00000000D61733e7A393A10A5B48c311AbE8f1E5;
        sfrxUsdOft = 0x00000000fD8C4B8A413A06821456801295921a71;
        frxEthOft = 0x000000008c3930dCA540bB9B3A5D0ee78FcA9A4c;
        sfrxEthOft = 0x00000000883279097A49dB1f2af954EAd0C77E3c;
        wFraxOft = 0x00000000E9CE0f293D1Ce552768b187eBA8a56D4;
        fpiOft = 0x00000000bC4aEF4bA6363a437455Cb1af19e2aEb;
    }
}
