// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import { Script } from "forge-std/Script.sol";
import { RemoteHopV201 } from "src/contracts/hop/RemoteHopV201.sol";

/// @dev The canonical RemoteHopV201 implementation (0x0000000f9a66...) was minted with the
///      default profile (optimizer_runs = 200) via UpgradeRemoteHopV2.s.sol, while
///      DeployRemoteHopV2<Chain>.s.sol must compile under FOUNDRY_PROFILE=deploy
///      (optimizer_runs = 1_000_000) to reproduce the V2/proxy salts. One compile cannot
///      satisfy both, so on a new chain run this script first (NO FOUNDRY_PROFILE), then run
///      the chain's DeployRemoteHopV2 script, which picks up the existing implementation.
// forge script src/script/hop/DeployRemoteHopV201.s.sol --rpc-url https://rpc.mainnet.chain.robinhood.com --gcp --sender 0x54f9b12743a7deec0ea48721683cbebedc6e17bc --broadcast
contract DeployRemoteHopV201 is Script {
    function run() external {
        vm.startBroadcast();

        address hopV201 = address(
            new RemoteHopV201{ salt: 0x4e59b44847b379578588920ca78fbf26c0b4956ce6ac70492feaa59e63000008 }()
        );
        require(hopV201 == 0x0000000f9a66622C8885E1071B78E37b2b3ecCCd, "Unexpected implementation address");

        vm.stopBroadcast();
    }
}
