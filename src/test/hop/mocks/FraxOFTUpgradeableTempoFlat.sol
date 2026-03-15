// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

import "contracts/flat/FraxOFTUpgradeableFlat.sol";

import { ITIP20 } from "@tempo/interfaces/ITIP20.sol";
import { StdPrecompiles } from "tempo-std/StdPrecompiles.sol";
import { StdTokens } from "tempo-std/StdTokens.sol";
import { ILZEndpointDollar } from "src/contracts/interfaces/vendor/layerzero/ILZEndpointDollar.sol";
import { SafeCast } from "@openzeppelin/contracts/utils/math/SafeCast.sol";

interface IEndpointV2AltFlat {
    function nativeToken() external view returns (address);
}

/// @notice Local test helper that preserves the upstream Tempo OFT logic while sourcing
///         the OFT implementation from the published flattened contract to avoid mixed-OZ import conflicts.
contract FraxOFTUpgradeableTempoFlat is FraxOFTUpgradeable {
    error NativeTokenUnavailable();
    error OFTAltCore__msg_value_not_zero(uint256 _msg_value);
    error NoSwappableWhitelistedToken(address userToken);

    ILZEndpointDollar public immutable nativeToken;

    constructor(address _lzEndpoint) FraxOFTUpgradeable(_lzEndpoint) {
        nativeToken = ILZEndpointDollar(IEndpointV2AltFlat(_lzEndpoint).nativeToken());
        _disableInitializers();
    }

    /// @dev Overrides send to prevent msg.value being sent (EndpointV2Alt uses ERC20 for gas)
    function send(
        SendParam calldata _sendParam,
        MessagingFee calldata _fee,
        address _refundAddress
    ) external payable virtual override returns (MessagingReceipt memory msgReceipt, OFTReceipt memory oftReceipt) {
        if (msg.value > 0) revert OFTAltCore__msg_value_not_zero(msg.value);

        (uint256 amountSentLD, uint256 amountReceivedLD) = _debit(
            _sendParam.amountLD,
            _sendParam.minAmountLD,
            _sendParam.dstEid
        );

        (bytes memory message, bytes memory options) = _buildMsgAndOptions(_sendParam, amountReceivedLD);

        msgReceipt = _lzSend(_sendParam.dstEid, message, options, _fee, _refundAddress);
        oftReceipt = OFTReceipt(amountSentLD, amountReceivedLD);

        emit OFTSent(msgReceipt.guid, _sendParam.dstEid, msg.sender, amountSentLD, amountReceivedLD);
    }

    /// @dev Validates the user's gas token swap path; fee stays in endpoint-native units.
    function _quote(
        uint32 _dstEid,
        bytes memory _message,
        bytes memory _options,
        bool _payInLzToken
    ) internal view virtual override returns (MessagingFee memory fee) {
        return _validateQuoteSwapPath(super._quote(_dstEid, _message, _options, _payInLzToken));
    }

    /// @dev Pays the LZ fee via ERC20 swap+wrap through TempoGasTokenBase.
    function _payNative(uint256 _nativeFee) internal virtual override returns (uint256 nativeFee) {
        return _payNativeAltToken(_nativeFee, address(endpoint));
    }

    function setTempoEnforcedOptions(
        uint32 _dstEid,
        bytes calldata _directOptions,
        bytes calldata _composeOptions
    ) external onlyOwner {
        EnforcedOptionParam[] memory enforcedOptions = new EnforcedOptionParam[](2);
        enforcedOptions[0] = EnforcedOptionParam(_dstEid, 1, _directOptions);
        enforcedOptions[1] = EnforcedOptionParam(_dstEid, 2, _composeOptions);

        OAppOptionsType3Storage storage $ = _getOAppOptionsType3Storage();
        for (uint256 i = 0; i < enforcedOptions.length; i++) {
            _assertOptionsType3Memory(enforcedOptions[i].options);
            $.enforcedOptions[enforcedOptions[i].eid][enforcedOptions[i].msgType] = enforcedOptions[i].options;
        }

        emit EnforcedOptionSet(enforcedOptions);
    }

    function _assertOptionsType3Memory(bytes memory _options) internal pure {
        uint16 optionsType = (uint16(uint8(_options[0])) << 8) | uint16(uint8(_options[1]));
        if (optionsType != OPTION_TYPE_3) revert InvalidOptions(_options);
    }

    function _resolveUserToken() internal view returns (address userToken) {
        userToken = StdPrecompiles.TIP_FEE_MANAGER.userTokens(msg.sender);
        if (userToken == address(0)) {
            userToken = StdTokens.PATH_USD_ADDRESS;
        }
    }

    function _findSwapTarget(
        address _userToken,
        uint128 _amountOut
    ) internal view returns (address whitelistedToken, uint128 amountIn) {
        address[] memory _tokens = nativeToken.getWhitelistedTokens();
        uint128 _bestAmountIn = type(uint128).max;
        address _bestToken;

        uint256 _tokenCount = _tokens.length;
        for (uint256 i = 0; i < _tokenCount; i++) {
            if (_tokens[i] == _userToken) continue;

            try
                StdPrecompiles.STABLECOIN_DEX.quoteSwapExactAmountOut({
                    tokenIn: _userToken,
                    tokenOut: _tokens[i],
                    amountOut: _amountOut
                })
            returns (uint128 _quoted) {
                if (_quoted < _bestAmountIn) {
                    _bestAmountIn = _quoted;
                    _bestToken = _tokens[i];
                }
            } catch {
                continue;
            }
        }

        if (_bestToken == address(0)) revert NoSwappableWhitelistedToken(_userToken);
        return (_bestToken, _bestAmountIn);
    }

    function _validateQuoteSwapPath(MessagingFee memory fee) internal view returns (MessagingFee memory) {
        if (fee.nativeFee == 0) return fee;

        address userToken = _resolveUserToken();
        if (nativeToken.isWhitelistedToken(userToken)) {
            return fee;
        }

        _findSwapTarget(userToken, SafeCast.toUint128(fee.nativeFee));
        return fee;
    }

    function _payNativeAltToken(uint256 _nativeFee, address _endpointAddr) internal returns (uint256) {
        if (_nativeFee == 0) return 0;
        if (address(nativeToken) == address(0)) revert NativeTokenUnavailable();

        address userToken = _resolveUserToken();

        if (nativeToken.isWhitelistedToken(userToken)) {
            ITIP20(userToken).transferFrom(msg.sender, address(this), _nativeFee);
            ITIP20(userToken).approve(address(nativeToken), _nativeFee);
            nativeToken.wrap(userToken, _endpointAddr, _nativeFee);
            return 0;
        }

        (address targetToken, uint128 userTokenAmount) = _findSwapTarget(userToken, SafeCast.toUint128(_nativeFee));

        ITIP20(userToken).transferFrom(msg.sender, address(this), userTokenAmount);
        ITIP20(userToken).approve(address(StdPrecompiles.STABLECOIN_DEX), userTokenAmount);
        StdPrecompiles.STABLECOIN_DEX.swapExactAmountOut({
            tokenIn: userToken,
            tokenOut: targetToken,
            amountOut: SafeCast.toUint128(_nativeFee),
            maxAmountIn: userTokenAmount
        });

        ITIP20(targetToken).approve(address(nativeToken), _nativeFee);
        nativeToken.wrap(targetToken, _endpointAddr, _nativeFee);

        return 0;
    }
}
