// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { IOAppComposer } from "@layerzerolabs/oapp-evm/contracts/oapp/interfaces/IOAppComposer.sol";
import { OFTComposeMsgCodec } from "@layerzerolabs/oft-evm/contracts/libs/OFTComposeMsgCodec.sol";
import { OptionsBuilder } from "@fraxfinance/layerzero-v2-upgradeable/oapp/contracts/oapp/libs/OptionsBuilder.sol";
import { SendParam } from "@fraxfinance/layerzero-v2-upgradeable/oapp/contracts/oft/interfaces/IOFT.sol";

import { HopV2, HopMessage } from "src/contracts/hop/HopV2.sol";

/// @title FraxtalHopV2Mock
/// @notice Mock version of FraxtalHopV2 with configurable hub EID for testing
/// @dev Allows overriding FRAXTAL_EID so tests can use mock endpoint EIDs (1, 2, 3)
contract FraxtalHopV2Mock is HopV2, IOAppComposer {
    using OptionsBuilder for bytes;

    /// @notice Configurable hub EID (this chain's EID, production uses 30255)
    uint32 public immutable HUB_EID;

    event Hop(address oft, uint32 indexed srcEid, uint32 indexed dstEid, bytes32 indexed recipient, uint256 amount);

    error InvalidDestinationChain();
    error InvalidRemoteHop();

    constructor(uint32 _hubEid) {
        HUB_EID = _hubEid;
        _disableInitializers();
    }

    function initialize(
        uint32 _localEid,
        address _endpoint,
        uint32 _numDVNs,
        address _EXECUTOR,
        address _DVN,
        address _TREASURY,
        address[] memory _approvedOfts
    ) external initializer {
        __init_HopV2(_localEid, _endpoint, _numDVNs, _EXECUTOR, _DVN, _TREASURY, _approvedOfts);
    }

    // receive ETH
    receive() external payable {}

    function sendOFT(
        address _oft,
        uint32 _dstEid,
        bytes32 _recipient,
        uint256 _amountLD,
        uint128 _dstGas,
        bytes memory _data
    ) public payable override {
        // Use HUB_EID instead of FRAXTAL_EID
        if (_dstEid != HUB_EID && remoteHop(_dstEid) == bytes32(0)) revert InvalidDestinationChain();

        super.sendOFT(_oft, _dstEid, _recipient, _amountLD, _dstGas, _data);
    }

    /// @notice Handles incoming composed messages from LayerZero
    function lzCompose(
        address _oft,
        bytes32, // _guid
        bytes calldata _message,
        address, // _executor
        bytes calldata // _extraData
    ) external payable override {
        if (paused()) revert HopPaused();

        (bool isTrustedHopMessage, bool isDuplicateMessage) = _validateComposeMessage(_oft, _message);
        if (isDuplicateMessage) return;

        // Extract the composed message
        HopMessage memory hopMessage = abi.decode(OFTComposeMsgCodec.composeMsg(_message), (HopMessage));
        uint256 amountLD = OFTComposeMsgCodec.amountLD(_message);

        // Overwrite srcEid and sender for untrusted messages
        if (!isTrustedHopMessage) {
            hopMessage.srcEid = OFTComposeMsgCodec.srcEid(_message);
            hopMessage.sender = OFTComposeMsgCodec.composeFrom(_message);
        }

        // Use HUB_EID instead of FRAXTAL_EID
        if (hopMessage.dstEid == HUB_EID) {
            _sendLocal({ _oft: _oft, _amount: amountLD, _hopMessage: hopMessage });
        } else {
            _sendToDestination({
                _oft: _oft,
                _amountLD: removeDust(_oft, amountLD),
                _isTrustedHopMessage: isTrustedHopMessage,
                _hopMessage: hopMessage
            });
            emit Hop(_oft, hopMessage.srcEid, hopMessage.dstEid, hopMessage.recipient, amountLD);
        }
    }

    function _generateSendParam(
        uint256 _amountLD,
        HopMessage memory _hopMessage
    ) internal view override returns (SendParam memory sendParam) {
        sendParam.dstEid = _hopMessage.dstEid;
        sendParam.amountLD = _amountLD;
        sendParam.minAmountLD = _amountLD;

        // Always add lzReceive gas (required by executor)
        bytes memory options = OptionsBuilder.newOptions();
        uint128 lzReceiveGas = 200_000; // Base gas for lzReceive
        options = options.addExecutorLzReceiveOption(lzReceiveGas, 0);

        if (_hopMessage.data.length == 0) {
            sendParam.to = _hopMessage.recipient;
            sendParam.extraOptions = options;
        } else {
            bytes32 to = remoteHop(_hopMessage.dstEid);
            if (to == bytes32(0)) revert InvalidRemoteHop();
            sendParam.to = to;

            options = options.addExecutorLzComposeOption(0, _hopMessage.dstGas, 0);
            sendParam.extraOptions = options;

            sendParam.composeMsg = abi.encode(_hopMessage);
        }
    }
}
