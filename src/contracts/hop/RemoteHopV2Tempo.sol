// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import { SendParam, MessagingFee, IOFT } from "@fraxfinance/layerzero-v2-upgradeable/oapp/contracts/oft/interfaces/IOFT.sol";
import { ITIP20 } from "@tempo/interfaces/ITIP20.sol";
import { RemoteHopV2 } from "src/contracts/hop/RemoteHopV2.sol";
import { HopMessage } from "src/contracts/hop/HopV2.sol";
import { TempoGasTokenBase } from "src/contracts/base/TempoGasTokenBase.sol";
import { StdPrecompiles } from "tempo-std/StdPrecompiles.sol";

// ====================================================================
// |     ______                   _______                             |
// |    / _____________ __  __   / ____(_____  ____ _____  ________   |
// |   / /_  / ___/ __ `| |/_/  / /_  / / __ \/ __ `/ __ \/ ___/ _ \  |
// |  / __/ / /  / /_/ _>  <   / __/ / / / / / /_/ / / / / /__/  __/  |
// | /_/   /_/   \__,_/_/|_|  /_/   /_/_/ /_/\__,_/_/ /_/\___/\___/   |
// |                                                                  |
// ====================================================================
// ========================= RemoteHopV2Tempo =========================
// ====================================================================

/// @title RemoteHopV2Tempo
/// @notice Tempo chain variant of RemoteHopV2 that uses ERC20 for gas payment via EndpointV2Alt
/// @author Frax Finance: https://github.com/FraxFinance
contract RemoteHopV2Tempo is RemoteHopV2, TempoGasTokenBase {
    constructor(address _endpoint) TempoGasTokenBase(_endpoint) {
        _disableInitializers();
    }

    /// @notice Send an OFT to a destination with encoded data
    /// @dev Inlines base HopV2.sendOFT logic to:
    ///      1. Reject native ETH (Tempo uses ERC20 gas via EndpointV2Alt)
    ///      2. Skip _handleMsgValue (no native ETH fee handling on Tempo)
    function sendOFT(
        address _oft,
        uint32 _dstEid,
        bytes32 _recipient,
        uint256 _amountLD,
        uint128 _dstGas,
        bytes memory _data
    ) public payable override {
        // EndpointV2Alt uses ERC20 for gas, not native ETH
        if (msg.value > 0) revert OFTAltCore__msg_value_not_zero(msg.value);

        // --- Inlined from HopV2.sendOFT (skips _handleMsgValue) ---
        HopV2Storage storage $ = _getHopV2Storage();
        if ($.paused) revert HopPaused();
        if (!$.approvedOft[_oft]) revert InvalidOFT();

        HopMessage memory hopMessage = HopMessage({
            srcEid: $.localEid,
            dstEid: _dstEid,
            dstGas: _dstGas,
            sender: bytes32(uint256(uint160(msg.sender))),
            recipient: _recipient,
            data: _data
        });

        _amountLD = removeDust(_oft, _amountLD);
        if (_amountLD > 0) ITIP20(IOFT(_oft).token()).transferFrom(msg.sender, address(this), _amountLD);

        if (_dstEid == $.localEid) {
            _sendLocal({ _oft: _oft, _amount: _amountLD, _hopMessage: hopMessage });
        } else {
            _sendToDestination(_oft, _amountLD, true, hopMessage);
        }

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

    /// @dev Override to let the OFT pay its own endpoint fee in ERC20 via EndpointV2Alt.
    ///      The hop separately retains its protocol fee as wrapped LZEndpointDollar.
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

        address userToken = _resolveUserToken();
        StdPrecompiles.TIP_FEE_MANAGER.setUserToken(userToken);

        // Always quote the send fee. This spoke path is only reached from sendOFT(), so
        // the ignored trusted-hop flag is intentional here. Bind TIP_FEE_MANAGER token
        // context here so the downstream OFT fee flow uses the caller's resolved gas token.
        MessagingFee memory fee = IOFT(_oft).quoteSend(sendParam, false);

        // Account for hop fee if multi-hop (Tempo → Fraxtal → final dest).
        // When dstEid == FRAXTAL_EID the message lands directly on hub; no second hop needed.
        uint256 hopFeeOnFraxtal = (_hopMessage.dstEid == FRAXTAL_EID || $.localEid == FRAXTAL_EID)
            ? 0
            : quoteHop(_hopMessage.dstEid, _hopMessage.dstGas, _hopMessage.data);

        address oftToken = IOFT(_oft).token();
        uint256 oftFeeInUserToken = _quoteUserTokenFee(userToken, fee.nativeFee);
        uint256 oftTokenAllowance = _amountLD;

        // Fund the OFT's own _payNative() path from this hop contract so execution matches the real OFT flow.
        if (oftFeeInUserToken > 0) {
            ITIP20(userToken).transferFrom(msg.sender, address(this), oftFeeInUserToken);
            if (userToken == oftToken) {
                oftTokenAllowance += oftFeeInUserToken;
            } else {
                ITIP20(userToken).approve(_oft, oftFeeInUserToken);
            }
        }

        // Collect hop-fee revenue separately; it remains on this contract as wrapped nativeToken.
        if (hopFeeOnFraxtal > 0) {
            _payNativeAltToken(hopFeeOnFraxtal, address(this));
        }

        // Approve and send the OFT to Fraxtal hub
        if (oftTokenAllowance > 0) ITIP20(oftToken).approve(_oft, oftTokenAllowance);
        IOFT(_oft).send{ value: 0 }(sendParam, fee, address(this));

        // Return 0 — native msg.value fee handling is bypassed on Tempo.
        return 0;
    }
}
