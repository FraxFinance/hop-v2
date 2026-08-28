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
/// Tempo outbound routes stay disabled in frax-lz-route-api until the deployed
/// address is wired in: set `TEMPO_FEE_INCLUSIVE_WRAPPER` in that repo's
/// `wrangler.jsonc` vars block and redeploy the Worker. While it is unset the
/// quote service fails closed (503) on Tempo rather than serving a quote
/// pointing at address(0).
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
