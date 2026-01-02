// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import { IOAppComposer } from "@layerzerolabs/oapp-evm/contracts/oapp/interfaces/IOAppComposer.sol";
import { OFTComposeMsgCodec } from "@layerzerolabs/oft-evm/contracts/libs/OFTComposeMsgCodec.sol";
import { OptionsBuilder } from "@fraxfinance/layerzero-v2-upgradeable/oapp/contracts/oapp/libs/OptionsBuilder.sol";
import { SendParam } from "@fraxfinance/layerzero-v2-upgradeable/oapp/contracts/oft/interfaces/IOFT.sol";

import { HopV2, HopMessage } from "src/contracts/hop/HopV2.sol";

// ====================================================================
// |     ______                   _______                             |
// |    / _____________ __  __   / ____(_____  ____ _____  ________   |
// |   / /_  / ___/ __ `| |/_/  / /_  / / __ \/ __ `/ __ \/ ___/ _ \  |
// |  / __/ / /  / /_/ _>  <   / __/ / / / / / /_/ / / / / /__/  __/  |
// | /_/   /_/   \__,_/_/|_|  /_/   /_/_/ /_/\__,_/_/ /_/\___/\___/   |
// |                                                                  |
// ====================================================================
// =========================== FraxtalHopV2 ===========================
// ====================================================================

/// @author Frax Finance: https://github.com/FraxFinance
contract FraxtalHopV2 is HopV2, IOAppComposer {
    event Hop(address oft, uint32 indexed srcEid, uint32 indexed dstEid, bytes32 indexed recipient, uint256 amount);

    error InvalidDestinationChain();
    error InvalidRemoteHop();

    constructor() {
        _disableInitializers();
    }

    function initialize(
        uint32 _localEid,
        address _endpoint,
        address _gasPriceOracle,
        uint32 _numDVNs,
        address _EXECUTOR,
        address _DVN,
        address _TREASURY,
        address[] memory _approvedOfts
    ) external initializer {
        __init_HopV2(_localEid, _endpoint, _gasPriceOracle, _numDVNs, _EXECUTOR, _DVN, _TREASURY, _approvedOfts);
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
        if (_dstEid != FRAXTAL_EID && remoteHop(_dstEid) == bytes32(0)) revert InvalidDestinationChain();

        super.sendOFT(_oft, _dstEid, _recipient, _amountLD, _dstGas, _data);
    }

    /// @notice Handles incoming composed messages from LayerZero.
    /// @dev Decodes the message payload to perform a token swap.
    ///      This method expects the encoded compose message to contain the swap amount and recipient address.
    /// @dev source: https://docs.layerzero.network/v2/developers/evm/protocol-gas-settings/options#lzcompose-option
    /// @param _oft The address of the originating OApp/Token.
    /// @param /*_guid*/ The globally unique identifier of the message
    /// @param _message The encoded message content in the format of the OFTComposeMsgCodec.
    /// @param /*Executor*/ Executor address
    /// @param /*Executor Data*/ Additional data for checking for a specific executor
    function lzCompose(
        address _oft,
        bytes32,
        /*_guid*/
        bytes calldata _message,
        address,
        /*Executor*/
        bytes calldata /*Executor Data*/
    ) external payable override {
        if (paused()) revert HopPaused();

        (bool isTrustedHopMessage, bool isDuplicateMessage) = _validateComposeMessage(_oft, _message);
        if (isDuplicateMessage) return;

        // Extract the composed message from the delivered message using the MsgCodec
        HopMessage memory hopMessage = abi.decode(OFTComposeMsgCodec.composeMsg(_message), (HopMessage));
        uint256 amountLD = OFTComposeMsgCodec.amountLD(_message);

        // An untrusted hop message means that the composer on the source chain is not the RemoteHop.  When the composer
        // is not the RemoteHop, they can craft any arbitrary HopMessage.  In these cases, overwrite the srcEid and sender
        // to ensure the HopMessage data is legitimate when passed to IHopComposer.hopCompose().
        if (!isTrustedHopMessage) {
            hopMessage.srcEid = OFTComposeMsgCodec.srcEid(_message);
            hopMessage.sender = OFTComposeMsgCodec.composeFrom(_message);
        }

        if (hopMessage.dstEid == FRAXTAL_EID) {
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

        if (_hopMessage.data.length == 0) {
            // There is no compose message to execute, therefore we know the recipeint should directly receive the tokens.
            sendParam.to = _hopMessage.recipient;
        } else {
            bytes32 to = remoteHop(_hopMessage.dstEid);

            // In sending from A => Fraxtal => B, A does not know if B has a remoteHop.
            // Therefore, revert on Fraxtal lzCompose() when there is no remoteHop to allow replays
            // rather than sending to address(0) on destination
            if (to == bytes32(0)) revert InvalidRemoteHop();
            sendParam.to = to;

            bytes memory options = OptionsBuilder.newOptions();
            options = OptionsBuilder.addExecutorLzComposeOption(options, 0, _hopMessage.dstGas, 0);
            sendParam.extraOptions = options;

            sendParam.composeMsg = abi.encode(_hopMessage);
        }
    }
}
