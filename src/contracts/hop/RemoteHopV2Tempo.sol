// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import { SendParam, MessagingFee, IOFT } from "@fraxfinance/layerzero-v2-upgradeable/oapp/contracts/oft/interfaces/IOFT.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { ITIP20 } from "@tempo/interfaces/ITIP20.sol";
import { StdPrecompiles } from "tempo-std/StdPrecompiles.sol";
import { RemoteHopV2 } from "src/contracts/hop/RemoteHopV2.sol";
import { HopMessage } from "src/contracts/hop/HopV2.sol";

/// @dev Interface for EndpointV2Alt's nativeToken function
interface IEndpointV2Alt {
    function nativeToken() external view returns (address);
}

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
contract RemoteHopV2Tempo is RemoteHopV2 {
    using SafeERC20 for IERC20;

    error NativeTokenUnavailable();
    error MsgValueNotZero(uint256 msgValue);

    /// @notice The ERC20 token used as native gas by EndpointV2Alt (PATH_USD on Tempo)
    address public immutable nativeToken;

    constructor(address _endpoint) {
        nativeToken = IEndpointV2Alt(_endpoint).nativeToken();
        _disableInitializers();
    }

    /// @notice Send an OFT to a destination with encoded data
    /// @dev Overrides base to use ERC20 gas payment instead of msg.value
    function sendOFT(
        address _oft,
        uint32 _dstEid,
        bytes32 _recipient,
        uint256 _amountLD,
        uint128 _dstGas,
        bytes memory _data
    ) public payable override {
        // EndpointV2Alt uses ERC20 for gas, not native ETH
        if (msg.value > 0) revert MsgValueNotZero(msg.value);

        HopV2Storage storage $ = _getHopV2StorageTempo();
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
        if (_amountLD > 0) SafeERC20.safeTransferFrom(IERC20(IOFT(_oft).token()), msg.sender, address(this), _amountLD);

        if (_dstEid == $.localEid) {
            // Sending from src => src - no LZ send needed
            _sendLocal({ _oft: _oft, _amount: _amountLD, _hopMessage: hopMessage });
        } else {
            _sendToDestinationTempo({
                _oft: _oft,
                _amountLD: _amountLD,
                _isTrustedHopMessage: true,
                _hopMessage: hopMessage
            });
        }

        emit SendOFT(_oft, msg.sender, _dstEid, _recipient, _amountLD);
    }

    /// @notice Get the gas cost estimate in user's TIP20 gas token terms
    /// @dev Returns fee converted to user's gas token if different from endpoint native
    /// @dev Use this instead of quote() on Tempo chain for accurate gas token pricing
    function quoteTempo(
        address _oft,
        uint32 _dstEid,
        bytes32 _recipient,
        uint256 _amount,
        uint128 _dstGas,
        bytes memory _data
    ) public view returns (uint256) {
        uint256 baseFee = quote(_oft, _dstEid, _recipient, _amount, _dstGas, _data);
        if (baseFee == 0) return 0;

        // Convert fee from endpoint native token to user's gas token if different
        address userToken = StdPrecompiles.TIP_FEE_MANAGER.userTokens(msg.sender);
        if (userToken != nativeToken) {
            return
                StdPrecompiles.STABLECOIN_DEX.quoteSwapExactAmountOut({
                    tokenIn: userToken,
                    tokenOut: nativeToken,
                    amountOut: uint128(baseFee)
                });
        }
        return baseFee;
    }

    /// @dev Send the OFT to execute hopCompose on a destination chain using ERC20 gas payment
    function _sendToDestinationTempo(
        address _oft,
        uint256 _amountLD,
        bool _isTrustedHopMessage,
        HopMessage memory _hopMessage
    ) internal {
        // generate sendParam
        SendParam memory sendParam = _generateSendParam({
            _amountLD: removeDust(_oft, _amountLD),
            _hopMessage: _hopMessage
        });

        MessagingFee memory fee;
        if (_isTrustedHopMessage) {
            fee = IOFT(_oft).quoteSend(sendParam, false);
        } else {
            // For untrusted messages, we need the caller to have pre-approved gas tokens
            fee.nativeFee = 0;
        }

        // Pay for LZ gas using ERC20 (Tempo's EndpointV2Alt)
        if (fee.nativeFee > 0) {
            _payNativeFee(fee.nativeFee);
        }

        // Send the OFT to the recipient
        if (_amountLD > 0) SafeERC20.forceApprove(IERC20(IOFT(_oft).token()), _oft, _amountLD);
        IOFT(_oft).send{ value: 0 }(sendParam, fee, address(this));
    }

    /// @dev Handles gas payment for EndpointV2Alt which uses ERC20 as native token
    ///      Swaps user's TIP20 gas token to the endpoint's native token if needed
    function _payNativeFee(uint256 _nativeFee) internal {
        if (nativeToken == address(0)) revert NativeTokenUnavailable();

        HopV2Storage storage $ = _getHopV2StorageTempo();
        address userToken = StdPrecompiles.TIP_FEE_MANAGER.userTokens(msg.sender);

        if (userToken != nativeToken) {
            // Quote swap amount needed to receive exactly _nativeFee of endpoint native token
            uint128 _userTokenAmount = StdPrecompiles.STABLECOIN_DEX.quoteSwapExactAmountOut({
                tokenIn: userToken,
                tokenOut: nativeToken,
                amountOut: uint128(_nativeFee)
            });
            // Pull user's gas token and swap to endpoint native token
            ITIP20(userToken).transferFrom(msg.sender, address(this), _userTokenAmount);
            ITIP20(userToken).approve(address(StdPrecompiles.STABLECOIN_DEX), _userTokenAmount);
            StdPrecompiles.STABLECOIN_DEX.swapExactAmountOut({
                tokenIn: userToken,
                tokenOut: nativeToken,
                amountOut: uint128(_nativeFee),
                maxAmountIn: _userTokenAmount
            });
            // Transfer endpoint native token to endpoint
            ITIP20(nativeToken).transfer($.endpoint, _nativeFee);
        } else {
            // Pull endpoint native token directly from user to endpoint
            ITIP20(nativeToken).transferFrom(msg.sender, $.endpoint, _nativeFee);
        }
    }

    /// @dev Access storage - duplicate of parent's private function
    function _getHopV2StorageTempo() private pure returns (HopV2Storage storage $) {
        bytes32 HopV2StorageLocation = 0x6f2b5e4a4e4e1ee6e84aeabd150e6bcb39c4b05494d47809c3cd3d998f859100;
        assembly {
            $.slot := HopV2StorageLocation
        }
    }
}
