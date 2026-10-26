// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import { DeployRemoteHopV2 } from "./DeployRemoteHopV2.s.sol";

// Step 1 (default profile, mints the canonical V201 implementation — see DeployRemoteHopV201.s.sol):
//   forge script src/script/hop/DeployRemoteHopV201.s.sol --rpc-url https://forno.celo.org --gcp --sender 0x54f9b12743a7deec0ea48721683cbebedc6e17bc --broadcast
// Step 2 — Dry run: FOUNDRY_PROFILE=deploy forge script src/script/hop/DeployRemoteHopV2Celo.s.sol --rpc-url https://forno.celo.org --gcp --sender 0x54f9b12743a7deec0ea48721683cbebedc6e17bc
// Step 2 — Broadcast: FOUNDRY_PROFILE=deploy forge script src/script/hop/DeployRemoteHopV2Celo.s.sol --rpc-url https://forno.celo.org --gcp --sender 0x54f9b12743a7deec0ea48721683cbebedc6e17bc --broadcast
contract DeployRemoteHopV2Celo is DeployRemoteHopV2 {
    function _numDVNs() internal pure override returns (uint32) {
        return 5;
    }

    constructor() {
        proxyAdmin = 0x000000dbfaA1Fb91ca46867cE6D41aB6da4f7428;
        endpoint = 0x1a44076050125825900e736c501f859c50fE728c;
        localEid = 30_125;

        msig = 0xFfdBB6221390d05366df8F6733E586c8CE92103C;

        EXECUTOR = 0x1dDbaF8b75F2291A97C22428afEf411b7bB19e28;
        DVN = 0x75b073994560A5c03Cd970414d9170be0C6e5c36;
        SEND_LIBRARY = 0x42b4E9C6495B4cFDaE024B1eC32E09F28027620e;

        frxUsdOft = 0x00000000D61733e7A393A10A5B48c311AbE8f1E5;
        sfrxUsdOft = 0x00000000fD8C4B8A413A06821456801295921a71;
        frxEthOft = 0x000000008c3930dCA540bB9B3A5D0ee78FcA9A4c;
        sfrxEthOft = 0x00000000883279097A49dB1f2af954EAd0C77E3c;
        wFraxOft = 0x00000000E9CE0f293D1Ce552768b187eBA8a56D4;
        // No FPI on Celo (retired before this chain onboarded)
    }
}
