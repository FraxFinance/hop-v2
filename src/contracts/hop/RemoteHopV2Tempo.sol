// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import { SendParam, MessagingFee, IOFT } from "@fraxfinance/layerzero-v2-upgradeable/oapp/contracts/oft/interfaces/IOFT.sol";
import { SafeCast } from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import { ITIP20 } from "@tempo/interfaces/ITIP20.sol";
import { RemoteHopV2 } from "src/contracts/hop/RemoteHopV2.sol";
import { HopMessage } from "src/contracts/hop/HopV2.sol";
import { TempoGasTokenBase } from "src/contracts/base/TempoGasTokenBase.sol";
import { StdPrecompiles } from "tempo-std/StdPrecompiles.sol";
import { StdTokens } from "tempo-std/StdTokens.sol";

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
    ///      2. Adopt the caller's gas token so the contract pays fees in the same ERC20
    ///      3. Skip _handleMsgValue (no native ETH fee handling on Tempo)
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

        // Adopt caller's resolved gas token so the contract pays fees in the same ERC20,
        // including PATH_USD fallback when the user has no explicit token configured.
        StdPrecompiles.TIP_FEE_MANAGER.setUserToken(_resolveUserToken());

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

    /// @notice Override quote to return fees in the caller's resolved user-token units.
    /// @dev On Tempo, the user's gas token may require a DEX swap to obtain a whitelisted
    ///      stablecoin. This override translates the endpoint-native fee so that callers get
    ///      a single-step quote() → approve() → sendOFT() UX matching ETH chains.
    /// @dev This overload quotes using the caller's configured gas token, matching sendOFT()
    ///      behavior. Treat this as a compatibility view helper.
    ///      For deterministic UI pricing on Tempo, prefer `quoteStatic()` or
    ///      `previewQuoteForUserToken()` via eth_call/simulation.
    function quote(
        address _oft,
        uint32 _dstEid,
        bytes32 _recipient,
        uint256 _amount,
        uint128 _dstGas,
        bytes memory _data
    ) public view override returns (uint256) {
        address userToken = _resolveUserToken();
        return
            _quoteWithUserToken({
                _oft: _oft,
                _dstEid: _dstEid,
                _recipient: _recipient,
                _amount: _amount,
                _dstGas: _dstGas,
                _data: _data,
                _userToken: userToken
            });
    }

    /// @notice Simulated quote using an explicit user gas token.
    /// @dev Intended for off-chain simulation (eth_call). This sets hop contract token context
    ///      before calling IOFT.quoteSend() so fee routing matches execution.
    function quoteStatic(
        address _oft,
        uint32 _dstEid,
        bytes32 _recipient,
        uint256 _amount,
        uint128 _dstGas,
        bytes memory _data,
        address _userToken
    ) external returns (uint256) {
        StdPrecompiles.TIP_FEE_MANAGER.setUserToken(_userToken);

        return
            _quoteWithUserToken({
                _oft: _oft,
                _dstEid: _dstEid,
                _recipient: _recipient,
                _amount: _amount,
                _dstGas: _dstGas,
                _data: _data,
                _userToken: _userToken
            });
    }

    /// @notice Preview the quote for an explicit user gas token.
    /// @dev Intended for off-chain simulation (eth_call) under a specific token assumption.
    ///      This sets hop contract token context before IOFT.quoteSend() for deterministic pricing.
    ///      Use this when the UI needs arbitrary-token previews without requiring a prior on-chain
    ///      user token update.
    function previewQuoteForUserToken(
        address _oft,
        uint32 _dstEid,
        bytes32 _recipient,
        uint256 _amount,
        uint128 _dstGas,
        bytes memory _data,
        address _userToken
    ) public returns (uint256) {
        StdPrecompiles.TIP_FEE_MANAGER.setUserToken(_userToken);

        return
            _quoteWithUserToken({
                _oft: _oft,
                _dstEid: _dstEid,
                _recipient: _recipient,
                _amount: _amount,
                _dstGas: _dstGas,
                _data: _data,
                _userToken: _userToken
            });
    }

    function _quoteWithUserToken(
        address _oft,
        uint32 _dstEid,
        bytes32 _recipient,
        uint256 _amount,
        uint128 _dstGas,
        bytes memory _data,
        address _userToken
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

        return _quoteUserTokenFee(_userToken, fee.nativeFee) + _quoteUserTokenFee(_userToken, hopFeeOnFraxtal);
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

        // Always quote the send fee. This spoke path is only reached from sendOFT(), so
        // the ignored trusted-hop flag is intentional here. sendOFT() already bound
        // TIP_FEE_MANAGER user token for this flow.
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
