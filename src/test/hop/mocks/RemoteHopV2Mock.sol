// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { OFTComposeMsgCodec } from "@layerzerolabs/oft-evm/contracts/libs/OFTComposeMsgCodec.sol";
import { IOAppComposer } from "@layerzerolabs/oapp-evm/contracts/oapp/interfaces/IOAppComposer.sol";
import { OptionsBuilder } from "@fraxfinance/layerzero-v2-upgradeable/oapp/contracts/oapp/libs/OptionsBuilder.sol";
import { SendParam } from "@fraxfinance/layerzero-v2-upgradeable/oapp/contracts/oft/interfaces/IOFT.sol";

import { HopV2, HopMessage } from "src/contracts/hop/HopV2.sol";
import { IHopComposer } from "src/contracts/interfaces/IHopComposer.sol";

/// @title RemoteHopV2Mock
/// @notice Mock version of RemoteHopV2 with configurable hub EID for testing
/// @dev Allows overriding FRAXTAL_EID so tests can use mock endpoint EIDs (1, 2, 3)
contract RemoteHopV2Mock is HopV2, IOAppComposer {
    using OptionsBuilder for bytes;

    /// @notice Configurable hub EID (production uses hardcoded 30255)
    uint32 public immutable HUB_EID;

    event Hop(address oft, address indexed recipient, uint256 amount);

    constructor(uint32 _hubEid) {
        HUB_EID = _hubEid;
        _disableInitializers();
    }

    function initialize(
        uint32 _localEid,
        address _endpoint,
        bytes32 _fraxtalHop,
        uint32 _numDVNs,
        address _EXECUTOR,
        address _DVN,
        address _TREASURY,
        address[] memory _approvedOfts
    ) external initializer {
        __init_HopV2(_localEid, _endpoint, _numDVNs, _EXECUTOR, _DVN, _TREASURY, _approvedOfts);
        _setRemoteHop(HUB_EID, _fraxtalHop);
    }

    // receive ETH
    receive() external payable {}

    function _generateSendParam(
        uint256 _amountLD,
        HopMessage memory _hopMessage
    ) internal view override returns (SendParam memory sendParam) {
        sendParam.dstEid = HUB_EID;
        sendParam.amountLD = _amountLD;
        sendParam.minAmountLD = _amountLD;

        // Always add lzReceive gas (required by executor)
        bytes memory options = OptionsBuilder.newOptions();
        uint128 lzReceiveGas = 200_000; // Base gas for lzReceive
        options = options.addExecutorLzReceiveOption(lzReceiveGas, 0);

        if (_hopMessage.dstEid == HUB_EID && _hopMessage.data.length == 0) {
            // Send directly to hub, no compose needed
            sendParam.to = _hopMessage.recipient;
            sendParam.extraOptions = options;
        } else {
            sendParam.to = remoteHop(HUB_EID);

            if (_hopMessage.dstGas < 400_000) _hopMessage.dstGas = 400_000;
            uint128 hubGas = 1_000_000;
            if (_hopMessage.dstGas > hubGas && _hopMessage.dstEid == HUB_EID) hubGas = _hopMessage.dstGas;
            options = options.addExecutorLzComposeOption(0, hubGas, 0);
            sendParam.extraOptions = options;

            sendParam.composeMsg = abi.encode(_hopMessage);
        }
    }

    /// @notice Handles incoming composed messages from LayerZero
    /// @param _oft The address of the originating OApp/Token
    /// @param _message The encoded message content
    function lzCompose(
        address _oft,
        bytes32, // _guid
        bytes calldata _message,
        address, // _executor
        bytes calldata // _extraData
    ) external payable override {
        (bool isTrustedHopMessage, bool isDuplicateMessage) = _validateComposeMessage(_oft, _message);
        if (isDuplicateMessage) return;

        // Decode the amount and data from the message
        uint256 amount = OFTComposeMsgCodec.amountLD(_message);
        bytes memory composeMsg = OFTComposeMsgCodec.composeMsg(_message);

        // Decode the original hop message
        HopMessage memory hopMessage = abi.decode(composeMsg, (HopMessage));

        // Decode recipient
        address recipient = address(uint160(uint256(hopMessage.recipient)));

        // Handle the received tokens
        if (isTrustedHopMessage && hopMessage.data.length > 0) {
            // Forward to a composer contract if there's data
            IHopComposer(recipient).hopCompose(
                OFTComposeMsgCodec.srcEid(_message),
                OFTComposeMsgCodec.composeFrom(_message),
                _oft,
                amount,
                hopMessage.data
            );
        }

        emit Hop(_oft, recipient, amount);
    }
}
