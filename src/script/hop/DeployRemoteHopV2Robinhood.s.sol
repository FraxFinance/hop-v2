// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import { DeployRemoteHopV2 } from "./DeployRemoteHopV2.s.sol";

// forge script src/script/hop/DeployRemoteHopV2Robinhood.s.sol --rpc-url https://rpc.mainnet.chain.robinhood.com --broadcast --gcp --sender 0x54f9b12743a7deec0ea48721683cbebedc6e17bc
contract DeployRemoteHopV2Robinhood is DeployRemoteHopV2 {
    address constant REMOTE_ADMIN = 0xB4BF1a4Bedb27cedc0bfb1eb5f78464d3C2d60b4;

    function _numDVNs() internal pure override returns (uint32) {
        return 4;
    }

    constructor() {
        proxyAdmin = 0x000000dbfaA1Fb91ca46867cE6D41aB6da4f7428;
        endpoint = 0x6F475642a6e85809B1c36Fa62763669b1b48DD5B;
        localEid = 30_416;

        msig = 0xFA1224aDd725eb2708BA4d15F627F4027dAfcEde;

        EXECUTOR = 0x4208D6E27538189bB48E603D6123A94b8Abe0A0b;
        DVN = 0x8D77D35604A9f37f488E41D1d916b2A0088F82Dd;
        SEND_LIBRARY = 0xC39161c743D0307EB9BCc9FEF03eeb9Dc4802de7;

        frxUsdOft = 0x00000000D61733e7A393A10A5B48c311AbE8f1E5;
        sfrxUsdOft = 0x00000000fD8C4B8A413A06821456801295921a71;
        frxEthOft = 0x000000008c3930dCA540bB9B3A5D0ee78FcA9A4c;
        sfrxEthOft = 0x00000000883279097A49dB1f2af954EAd0C77E3c;
        wFraxOft = 0x00000000E9CE0f293D1Ce552768b187eBA8a56D4;
        fpiOft = 0x00000000bC4aEF4bA6363a437455Cb1af19e2aEb;
    }

    function _deployRemoteAdmin(address remoteHop) internal override returns (address remoteAdmin) {
        remoteAdmin = super._deployRemoteAdmin(remoteHop);
        require(remoteAdmin == REMOTE_ADMIN, "RemoteAdmin address mismatch");
    }
}
