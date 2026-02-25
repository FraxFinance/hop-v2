// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import { DeployRemoteHopV2 } from "./DeployRemoteHopV2.s.sol";

// forge script src/script/hop/DeployRemoteHopV2Monad.s.sol --rpc-url https://rpc.monad.xyz --broadcast --gcp --sender 0x54f9b12743a7deec0ea48721683cbebedc6e17bc
// note: chain 143 not in foundry registry; verify separately (omit --chain-id; chainid=143 in --verifier-url routes correctly):
// FOUNDRY_PROFILE=deploy forge verify-contract 0x0000000087ED0dD8b999aE6C7c30f95e9707a3C6 src/contracts/hop/RemoteHopV2.sol:RemoteHopV2 --verifier etherscan --verifier-url "https://api.etherscan.io/v2/api?chainid=143" --etherscan-api-key $ETHERSCAN_API_KEY --compiler-version "v0.8.23+commit.f704f362"
// FOUNDRY_PROFILE=deploy forge verify-contract 0x0000006D38568b00B457580b734e0076C62de659 node_modules/frax-standard-solidity/src/FraxUpgradeableProxy.sol:FraxUpgradeableProxy --verifier etherscan --verifier-url "https://api.etherscan.io/v2/api?chainid=143" --etherscan-api-key $ETHERSCAN_API_KEY --compiler-version "v0.8.23+commit.f704f362" --constructor-args 0000000000000000000000000000000087ed0dd8b999ae6c7c30f95e9707a3c600000000000000000000000054f9b12743a7deec0ea48721683cbebedc6e17bc00000000000000000000000000000000000000000000000000000000000000600000000000000000000000000000000000000000000000000000000000000000
// FOUNDRY_PROFILE=deploy forge verify-contract 0x4bE0942c2CbFd741DB5906CF2831c1AF29fcEa55 src/contracts/RemoteAdmin.sol:RemoteAdmin --verifier etherscan --verifier-url "https://api.etherscan.io/v2/api?chainid=143" --etherscan-api-key $ETHERSCAN_API_KEY --compiler-version "v0.8.23+commit.f704f362" --constructor-args 00000000000000000000000058e3ee6accd124642ddb5d3f91928816be8d8ed30000000000000000000000000000006d38568b00b457580b734e0076c62de6590000000000000000000000005f25218ed9474b721d6a38c115107428e832fa2e
contract DeployRemoteHopV2Monad is DeployRemoteHopV2 {
    constructor() {
        proxyAdmin = 0xC2871Eae630640Ce1a16b39A17C498f22D76c21a;
        endpoint = 0x6F475642a6e85809B1c36Fa62763669b1b48DD5B;
        localEid = 30_390;

        msig = 0x47FF5bBAB981Ff022743AA4281D4d6Dd7Fb1a4D0;

        EXECUTOR = 0x4208D6E27538189bB48E603D6123A94b8Abe0A0b;
        DVN = 0x282b3386571f7f794450d5789911a9804FA346b4;
        SEND_LIBRARY = 0xC39161c743D0307EB9BCc9FEF03eeb9Dc4802de7;

        frxUsdOft = 0x58E3ee6accd124642dDB5d3f91928816Be8D8ed3;
        sfrxUsdOft = 0x137643F7b2C189173867b3391f6629caB46F0F1a;
        frxEthOft = 0x288F9D76019469bfEb56BB77d86aFa2bF563B75B;
        sfrxEthOft = 0x3B4cf37A3335F21c945a40088404c715525fCb29;
        wFraxOft = 0x29aCC7c504665A5EA95344796f784095f0cfcC58;
        fpiOft = 0xBa554F7A47f0792b9fa41A1256d4cf628Bb1D028;
    }
}
