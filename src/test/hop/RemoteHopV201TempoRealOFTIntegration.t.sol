// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

import { RemoteHopV201Tempo } from "src/contracts/hop/RemoteHopV201Tempo.sol";
import { RemoteHopV2TempoRealOFTIntegration } from "./RemoteHopV2TempoRealOFTIntegration.t.sol";

/// @notice Runs the real-OFT Tempo integration suite against `RemoteHopV201Tempo`, the implementation behind the
///         deployed Tempo proxy, so the fee-swap headroom fix is exercised on the code that actually ships.
/// @dev Both hops share `initialize(uint32,address,bytes32,uint32,address,address,address,address[])` and the
///      public surface the suite calls, so only the implementation differs.
contract RemoteHopV201TempoRealOFTIntegration is RemoteHopV2TempoRealOFTIntegration {
    function _deployTempoHopImplementation() internal override returns (address) {
        return address(new RemoteHopV201Tempo(address(tempoEndpoint)));
    }
}
