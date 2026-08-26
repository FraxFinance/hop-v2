// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import { Script, console } from "forge-std/Script.sol";
import { TempoFeeInclusiveWrapper } from "src/contracts/hop/TempoFeeInclusiveWrapper.sol";

/// @notice Deploys the immutable `TempoFeeInclusiveWrapper` in front of the
///         already-deployed `RemoteHopV201Tempo` proxy on Tempo mainnet.
///
/// Usage:
///   forge script src/script/hop/DeployTempoFeeInclusiveWrapper.s.sol \
///     --rpc-url https://rpc.tempo.xyz --broadcast
///
/// After deploying, set the resulting address as
/// `TEMPO_FEE_INCLUSIVE_WRAPPER` in the frax-lz-route-api quote service.
contract DeployTempoFeeInclusiveWrapper is Script {
    /// @dev Deployed RemoteHopV201Tempo proxy (Tempo mainnet).
    address public constant REMOTE_HOP_TEMPO = 0x0000006D38568b00B457580b734e0076C62de659;

    function run() public {
        vm.startBroadcast();
        TempoFeeInclusiveWrapper wrapper = new TempoFeeInclusiveWrapper(REMOTE_HOP_TEMPO);
        console.log("TempoFeeInclusiveWrapper deployed at:", address(wrapper));
        console.log("Wraps RemoteHopV201Tempo at:", REMOTE_HOP_TEMPO);
        vm.stopBroadcast();
    }
}
