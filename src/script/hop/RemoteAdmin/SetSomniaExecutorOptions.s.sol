// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import { SetExecutorOptionsBase } from "./SetExecutorOptionsBase.s.sol";
import { IHopV2 } from "src/contracts/interfaces/IHopV2.sol";

// forge script src/script/hop/RemoteAdmin/SetSomniaExecutorOptions.s.sol --rpc-url https://rpc.frax.com --ffi
contract SetSomniaExecutorOptions is SetExecutorOptionsBase {
    uint32 public constant SOMNIA_EID = 30_380;
    uint128 public constant SOMNIA_RECEIVE_GAS = 1_000_000;

    constructor() {
        skipCall[30_410] = true; // Tempo — pathway not yet configured
    }

    function _remoteCall() internal pure override returns (bytes memory) {
        bytes memory options = abi.encodePacked(uint8(1), uint16(17), uint8(1), uint128(SOMNIA_RECEIVE_GAS));
        return abi.encodeCall(IHopV2.setExecutorOptions, (SOMNIA_EID, options));
    }

    function _txLabel() internal pure override returns (string memory) {
        return "Set Somnia executor options";
    }

    function _outputFilename() internal pure override returns (string memory) {
        return "src/script/hop/RemoteAdmin/txs/SetSomniaExecutorOptions.json";
    }
}
