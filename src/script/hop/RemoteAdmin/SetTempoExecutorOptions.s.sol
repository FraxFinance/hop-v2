// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import { SetExecutorOptionsBase } from "./SetExecutorOptionsBase.s.sol";
import { IHopV2 } from "src/contracts/interfaces/IHopV2.sol";

// forge script src/script/hop/RemoteAdmin/SetTempoExecutorOptions.s.sol --rpc-url https://rpc.frax.com --ffi
contract SetTempoExecutorOptions is SetExecutorOptionsBase {
    uint32 public constant TEMPO_EID = 30_410;
    uint128 public constant TEMPO_RECEIVE_GAS = 2_500_000;

    function _remoteCall() internal pure override returns (bytes memory) {
        bytes memory options = abi.encodePacked(uint8(1), uint16(17), uint8(1), uint128(TEMPO_RECEIVE_GAS));
        return abi.encodeCall(IHopV2.setExecutorOptions, (TEMPO_EID, options));
    }

    function _txLabel() internal pure override returns (string memory) {
        return "Set Tempo executor options";
    }

    function _outputDir() internal pure override returns (string memory) {
        return "src/script/hop/RemoteAdmin/txs/SetTempoExecutorOptions";
    }

    function _sourceEid() internal pure override returns (uint32) {
        return TEMPO_EID;
    }
}
