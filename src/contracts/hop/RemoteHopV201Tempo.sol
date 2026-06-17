// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import { OFTComposeMsgCodec } from "@layerzerolabs/oft-evm/contracts/libs/OFTComposeMsgCodec.sol";
import { IOAppComposer } from "@layerzerolabs/oapp-evm/contracts/oapp/interfaces/IOAppComposer.sol";
import { OptionsBuilder } from "@fraxfinance/layerzero-v2-upgradeable/oapp/contracts/oapp/libs/OptionsBuilder.sol";
import { SendParam, MessagingFee, IOFT } from "@fraxfinance/layerzero-v2-upgradeable/oapp/contracts/oft/interfaces/IOFT.sol";
import { ITIP20 } from "@tempo/interfaces/ITIP20.sol";
import { StdPrecompiles } from "tempo-std/StdPrecompiles.sol";

import { HopV201Tempo } from "src/contracts/hop/HopV201Tempo.sol";
import { HopMessage } from "src/contracts/interfaces/IHopV201.sol";
import { TempoGasTokenBase } from "src/contracts/base/TempoGasTokenBase.sol";

// ====================================================================
// |     ______                   _______                             |
// |    / _____________ __  __   / ____(_____  ____ _____  ________   |
// |   / /_  / ___/ __ `| |/_/  / /_  / / __ \/ __ `/ __ \/ ___/ _ \  |
// |  / __/ / /  / /_/ _>  <   / __/ / / / / / /_/ / / / / /__/  __/  |
// | /_/   /_/   \__,_/_/|_|  /_/   /_/_/ /_/\__,_/_/ /_/\___/\___/   |
// |                                                                  |
// ====================================================================
// ======================== RemoteHopV201Tempo ========================
// ====================================================================

/// @title RemoteHopV201Tempo
/// @notice V201 + Tempo variant of `RemoteHopV2Tempo`. Inherits `HopV201Tempo` so it
///         exposes `RECOVER_ROLE` + `recoverERC20` (mirroring every other chain's V201
///         deployment) while dropping the unbounded `recover(address,uint256,bytes)`
///         escape hatch from HopV2. Tempo settles fees in TIP20, so `recoverETH` is
///         intentionally omitted.
///
///         The Tempo proxy at `0x0000006D38568b00B457580b734e0076C62de659` keeps its
///         storage layout (shared ERC-7201 slot) and is upgraded in place from the
///         previous `RemoteHopV2Tempo` implementation.
/// @author Frax Finance: https://github.com/FraxFinance
contract RemoteHopV201Tempo is HopV201Tempo, TempoGasTokenBase, IOAppComposer {
    event Hop(address oft, address indexed recipient, uint256 amount);

    constructor(address _endpoint) TempoGasTokenBase(_endpoint) {
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
        __init_HopV201(_localEid, _endpoint, _numDVNs, _EXECUTOR, _DVN, _TREASURY, _approvedOfts);
        _setRemoteHop(FRAXTAL_EID, _fraxtalHop);
    }

    /// @notice Send an OFT to a destination with encoded data
    /// @dev Inlines base HopV201Tempo.sendOFT logic to:
    ///      1. Reject native ETH (Tempo uses TIP20 gas via EndpointV2Alt)
    ///      2. Skip _handleMsgValue (no native ETH fee handling on Tempo)
    function sendOFT(
        address _oft,
        uint32 _dstEid,
        bytes32 _recipient,
        uint256 _amountLD,
        uint128 _dstGas,
        bytes memory _data
    ) public payable override {
        // EndpointV2Alt uses TIP20 for gas, not native ETH
        if (msg.value > 0) revert OFTAltCore__msg_value_not_zero(msg.value);

        // --- Inlined from HopV201Tempo.sendOFT (skips _handleMsgValue) ---
        HopV2Storage storage $ = _getHopV2Storage();
        if ($.paused) revert HopPaused();
        if (!$.approvedOft[_oft]) revert InvalidOFT();

        // generate hop message
        HopMessage memory hopMessage = HopMessage({
            srcEid: $.localEid,
            dstEid: _dstEid,
            dstGas: _dstGas,
            sender: bytes32(uint256(uint160(msg.sender))),
            recipient: _recipient,
            data: _data
        });

        // Transfer the OFT token to the hop. Clean off dust for the sender that would otherwise be lost through LZ.
        _amountLD = removeDust(_oft, _amountLD);
        if (_amountLD > 0) ITIP20(IOFT(_oft).token()).transferFrom(msg.sender, address(this), _amountLD);

        if (_dstEid == $.localEid) {
            // Sending from src => src - no LZ send needed
            _sendLocal({ _oft: _oft, _amount: _amountLD, _hopMessage: hopMessage });
        } else {
            _sendToDestination(_oft, _amountLD, true, hopMessage);
        }

        // No _handleMsgValue: Tempo bypasses native msg.value fee handling.

        emit SendOFT(_oft, msg.sender, _dstEid, _recipient, _amountLD);
    }

    /// @notice Override quote to return fees in native-LZ units.
    /// @dev This matches `IOFT.quoteSend()` semantics on Tempo OFTs.
    function quote(
        address _oft,
        uint32 _dstEid,
        bytes32 _recipient,
        uint256 _amount,
        uint128 _dstGas,
        bytes memory _data
    ) public view override returns (uint256) {
        return _quoteNativeFee(_oft, _dstEid, _recipient, _amount, _dstGas, _data);
    }

    /// @notice Simulated quote converted into an explicit user gas token.
    /// @dev Analogous to `quoteUserTokenFee()`: get the raw native-LZ quote first,
    ///      then convert it to `_userToken` units.
    function quoteStatic(
        address _oft,
        uint32 _dstEid,
        bytes32 _recipient,
        uint256 _amount,
        uint128 _dstGas,
        bytes memory _data,
        address _userToken
    ) external view returns (uint256) {
        return _quoteUserTokenFee(_userToken, quote(_oft, _dstEid, _recipient, _amount, _dstGas, _data));
    }

    function _quoteNativeFee(
        address _oft,
        uint32 _dstEid,
        bytes32 _recipient,
        uint256 _amount,
        uint128 _dstGas,
        bytes memory _data
    ) internal view returns (uint256) {
        uint32 localEid_ = localEid();
        if (_dstEid == localEid_) return 0;

        HopMessage memory hopMessage = HopMessage({
            srcEid: localEid_,
            dstEid: _dstEid,
            dstGas: _dstGas,
            sender: bytes32(uint256(uint160(msg.sender))),
            recipient: _recipient,
            data: _data
        });

        SendParam memory sendParam = _generateSendParam({
            _amountLD: removeDust(_oft, _amount),
            _hopMessage: hopMessage
        });
        MessagingFee memory fee = IOFT(_oft).quoteSend(sendParam, false);
        uint256 hopFeeOnFraxtal = (_dstEid == FRAXTAL_EID || localEid_ == FRAXTAL_EID)
            ? 0
            : quoteHop(_dstEid, _dstGas, _data);

        return fee.nativeFee + hopFeeOnFraxtal;
    }

    /// @dev Override to let the OFT pay its endpoint fee in TIP20 via EndpointV2Alt.
    ///      The hop collects endpoint and protocol fees once, then retains the protocol fee as the collected payment token.
    function _sendToDestination(
        address _oft,
        uint256 _amountLD,
        bool,
        /*_isTrustedHopMessage*/
        HopMessage memory _hopMessage
    ) internal override returns (uint256) {
        HopV2Storage storage $ = _getHopV2Storage();

        // Generate sendParam (always targets Fraxtal hub)
        SendParam memory sendParam = _generateSendParam({ _amountLD: _amountLD, _hopMessage: _hopMessage });

        // Always quote the send fee. This spoke path is only reached from sendOFT(), so
        // the ignored trusted-hop flag is intentional here. The raw quote stays in
        // endpoint-native units; actual user-token collection happens below.
        MessagingFee memory fee = IOFT(_oft).quoteSend(sendParam, false);

        // Account for hop fee if multi-hop (Tempo → Fraxtal → final dest).
        // When dstEid == FRAXTAL_EID the message lands directly on hub; no second hop needed.
        uint256 hopFeeOnFraxtal = (_hopMessage.dstEid == FRAXTAL_EID || $.localEid == FRAXTAL_EID)
            ? 0
            : quoteHop(_hopMessage.dstEid, _hopMessage.dstGas, _hopMessage.data);

        // Collect the total fee once, then bind the contract to the resulting payment token so the
        // downstream OFT `_payNative()` path can consume it without performing a second swap.
        address paymentToken = _collectNativeAltToken(fee.nativeFee + hopFeeOnFraxtal);
        StdPrecompiles.TIP_FEE_MANAGER.setUserToken(paymentToken);
        _approveOftFee(_oft, paymentToken, _amountLD, fee.nativeFee);

        // Retain hop-fee revenue on this contract as the collected payment token.

        // Send the OFT to Fraxtal hub
        IOFT(_oft).send{ value: 0 }(sendParam, fee, address(this));

        // Return 0 — native msg.value fee handling is bypassed on Tempo.
        return 0;
    }

    /// @dev Sets the approvals needed for the OFT to debit the bridged amount and consume its fee from the collected payment token.
    function _approveOftFee(address _oft, address paymentToken, uint256 _amountLD, uint256 _nativeFee) internal {
        address oftToken = IOFT(_oft).token();
        uint256 oftTokenAllowance = _amountLD;

        if (_nativeFee > 0) {
            if (paymentToken == oftToken) {
                oftTokenAllowance += _nativeFee;
            } else {
                ITIP20(paymentToken).approve(_oft, _nativeFee);
            }
        }

        if (oftTokenAllowance > 0) ITIP20(oftToken).approve(_oft, oftTokenAllowance);
    }

    function _generateSendParam(
        uint256 _amountLD,
        HopMessage memory _hopMessage
    ) internal view override returns (SendParam memory sendParam) {
        sendParam.dstEid = FRAXTAL_EID;
        sendParam.amountLD = _amountLD;
        sendParam.minAmountLD = _amountLD;
        if (_hopMessage.dstEid == FRAXTAL_EID && _hopMessage.data.length == 0) {
            sendParam.to = _hopMessage.recipient;
        } else {
            sendParam.to = remoteHop(FRAXTAL_EID);

            bytes memory options = OptionsBuilder.newOptions();
            if (_hopMessage.dstGas < 400_000) _hopMessage.dstGas = 400_000;
            uint128 fraxtalGas = 1_000_000;
            if (_hopMessage.dstGas > fraxtalGas && _hopMessage.dstEid == FRAXTAL_EID) fraxtalGas = _hopMessage.dstGas;
            options = OptionsBuilder.addExecutorLzComposeOption(options, 0, fraxtalGas, 0);
            sendParam.extraOptions = options;

            sendParam.composeMsg = abi.encode(_hopMessage);
        }
    }

    /// @notice Handles incoming composed messages from LayerZero.
    function lzCompose(
        address _oft,
        bytes32,
        /*_guid*/
        bytes calldata _message,
        address,
        /*Executor*/
        bytes calldata /*Executor Data*/
    ) external payable override {
        (bool isTrustedHopMessage, bool isDuplicateMessage) = _validateComposeMessage(_oft, _message);
        if (isDuplicateMessage) return;

        HopMessage memory hopMessage = abi.decode(OFTComposeMsgCodec.composeMsg(_message), (HopMessage));
        uint256 amountLD = OFTComposeMsgCodec.amountLD(_message);

        if (!isTrustedHopMessage) {
            hopMessage.srcEid = OFTComposeMsgCodec.srcEid(_message);
            hopMessage.sender = OFTComposeMsgCodec.composeFrom(_message);
        }

        _sendLocal({ _oft: _oft, _amount: amountLD, _hopMessage: hopMessage });

        emit Hop(_oft, address(uint160(uint256(hopMessage.recipient))), amountLD);
    }
}
