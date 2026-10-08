// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import { Script, console } from "forge-std/Script.sol";
import { HopConstants } from "src/script/hop/HopConstants.sol";
import { TempoFeeInclusiveWrapper } from "src/contracts/hop/TempoFeeInclusiveWrapper.sol";

/// @notice Deploys the immutable `TempoFeeInclusiveWrapper` in front of the
///         already-deployed `RemoteHopV201Tempo` proxy on Tempo mainnet.
///
/// Usage:
///   forge script src/script/hop/DeployTempoFeeInclusiveWrapper.s.sol \
///     --rpc-url https://rpc.tempo.xyz --gcp --sender 0x54f9b12743a7deec0ea48721683cbebedc6e17bc \
///     --broadcast
///
/// Tempo outbound routes stay disabled in frax-lz-route-api until the deployed
/// address is wired in: set `TEMPO_FEE_INCLUSIVE_WRAPPER` in that repo's
/// `wrangler.jsonc` vars block and redeploy the Worker. While it is unset the
/// quote service fails closed (503) on Tempo rather than serving a quote
/// pointing at address(0).
contract DeployTempoFeeInclusiveWrapper is Script, HopConstants {
    uint256 internal constant TEMPO_CHAIN_ID = 4217;

    function run() public {
        // The wrapper binds to Tempo's fee-manager precompile, so it is only
        // meaningful on Tempo — and the hop address is the same CREATE2 vanity
        // on every mesh chain, so the registry lookup alone would not catch a
        // wrong `--rpc-url`. Check the chain explicitly; an immutable contract
        // deployed to the wrong network cannot be repointed.
        require(block.chainid == TEMPO_CHAIN_ID, "not Tempo");
        address hop = _hopV2TargetFor(block.chainid).hop;
        require(hop.code.length != 0, "hop has no code");

        vm.startBroadcast();
        TempoFeeInclusiveWrapper wrapper = new TempoFeeInclusiveWrapper(hop);
        vm.stopBroadcast();

        require(address(wrapper.HOP()) == hop, "HOP mismatch");
        // Proves the bound address answers the hop ABI, not merely that it has code.
        wrapper.HOP().paused();

        console.log("TempoFeeInclusiveWrapper deployed at:", address(wrapper));
        console.log("Wraps RemoteHopV201Tempo at:", hop);
    }
}
