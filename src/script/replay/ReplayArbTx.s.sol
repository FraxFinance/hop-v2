// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import { Script, console } from "forge-std/Script.sol";

/// @title  ReplayArbTx
/// @notice Replays Arbitrum TX 0x530dfea1ccc0411618475cc5e1a2ab68c97a57bd21ac00ffb13851bffd7a54d3
///         on the target chain by resending the original calldata to the CREATE2 deployer.
///
/// @dev    The calldata (salt + init code) is read from scripts/replay_arb_tx_data.hex.
///
/// Usage:
///   forge script src/script/replay/ReplayArbTx.s.sol \
///     --rpc-url https://rpc.tempo.xyz \
///     --broadcast \
///     --gcp \
///     --sender 0x54f9b12743a7deec0ea48721683cbebedc6e17bc
contract ReplayArbTx is Script {
    /// @dev Keyless CREATE2 deployer (Nick's factory)
    address constant CREATE2_DEPLOYER = 0x4e59b44847b379578588920cA78FbF26c0B4956C;

    function run() external {
        // Read calldata from hex file (0x-prefixed hex string)
        string memory hexStr = vm.readFile("scripts/replay_arb_proxy_tx_data.hex");
        bytes memory data = vm.parseBytes(hexStr);

        console.log("CREATE2 deployer :", CREATE2_DEPLOYER);
        console.log("Calldata length  :", data.length);

        vm.startBroadcast();

        (bool success, bytes memory result) = CREATE2_DEPLOYER.call{ value: 0 }(data);
        require(success, "CREATE2 deployment failed");

        // CREATE2 deployer returns the deployed address as raw bytes
        // forge-lint: disable-next-line(unsafe-typecast)
        address deployed = address(bytes20(result));
        console.log("Deployed to      :", deployed);

        vm.stopBroadcast();
    }
}
