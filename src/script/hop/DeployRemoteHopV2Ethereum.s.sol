// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import { DeployRemoteHopV2 } from "./DeployRemoteHopV2.s.sol";

// forge script src/script/hop/Remote/DeployRemoteHopV2Ethereum.s.sol --rpc-url https://ethereum-rpc.publicnode.com --broadcast --verify --verifier etherscan --etherscan-api-key $ARBISCAN_API_KEY
contract DeployRemoteHopV2Ethereum is DeployRemoteHopV2 {
    constructor() {
        EXECUTOR = 0x173272739Bd7Aa6e4e214714048a9fE699453059;
        DVN = 0x589dEDbD617e0CBcB916A9223F4d1300c294236b;
        SEND_LIBRARY = 0xbB2Ea70C9E858123480642Cf96acbcCE1372dCe1;

        proxyAdmin = 0x223a681fc5c5522c85C96157c0efA18cd6c5405c;
        endpoint = 0x1a44076050125825900e736c501f859c50fE728c;
        gasPriceOracle = 0x5f4eC3Df9cbd43714FE2740f5E3616155c5b8419;
        localEid = 30_101;

        msig = 0x6cCF3F2Ca29591F90ADB403D67E4dcB49cEcC634;

        frxUsdOft = 0x566a6442A5A6e9895B9dCA97cC7879D632c6e4B0;
        sfrxUsdOft = 0x7311CEA93ccf5f4F7b789eE31eBA5D9B9290E126;
        frxEthOft = 0x1c1649A38f4A3c5A0c4a24070f688C525AB7D6E6;
        sfrxEthOft = 0xbBc424e58ED38dd911309611ae2d7A23014Bd960;
        wFraxOft = 0x04ACaF8D2865c0714F79da09645C13FD2888977f;
        fpiOft = 0x9033BAD7aA130a2466060A2dA71fAe2219781B4b;
    }
}
