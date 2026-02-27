// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { OFTAdapter } from "@layerzerolabs/oft-evm/contracts/OFTAdapter.sol";
import { ITIP20 } from "tempo-std/interfaces/ITIP20.sol";
import { ILayerZeroEndpointV2 } from "@layerzerolabs/lz-evm-protocol-v2/contracts/interfaces/ILayerZeroEndpointV2.sol";
import { SendParam, OFTReceipt, MessagingFee, MessagingReceipt } from "@layerzerolabs/oft-evm/contracts/interfaces/IOFT.sol";

/// @dev Interface for EndpointV2Alt's nativeToken function
interface IEndpointV2Alt {
    function nativeToken() external view returns (address);
}

/// @notice TIP20 OFT Adapter for Tempo - uses ERC20 for gas payment (like EndpointV2Alt)
/// @dev Mimics FraxOFTMintableAdapterUpgradeableTIP20 - burns on send, mints on receive
/// @dev Architecture: Tempo side uses this adapter wrapping TIP20, Fraxtal uses OFTAdapter wrapping ERC20
contract TIP20OFTAdapterAltMock is OFTAdapter {
    error NativeTokenUnavailable();
    error OFTAltCore__msg_value_not_zero(uint256 _msg_value);

    address public immutable nativeToken;

    constructor(
        address _token,
        address _lzEndpoint,
        address _delegate
    ) OFTAdapter(_token, _lzEndpoint, _delegate) Ownable(_delegate) {
        nativeToken = IEndpointV2Alt(_lzEndpoint).nativeToken();
    }

    /// @dev Override send to prevent msg.value (ERC20 gas on Tempo, not native ETH)
    function send(
        SendParam calldata _sendParam,
        MessagingFee calldata _fee,
        address _refundAddress
    ) external payable virtual override returns (MessagingReceipt memory msgReceipt, OFTReceipt memory oftReceipt) {
        if (msg.value > 0) revert OFTAltCore__msg_value_not_zero(msg.value);

        // Debit tokens from sender
        (uint256 amountSentLD, uint256 amountReceivedLD) = _debit(
            msg.sender,
            _sendParam.amountLD,
            _sendParam.minAmountLD,
            _sendParam.dstEid
        );

        // Build message and options
        (bytes memory message, bytes memory options) = _buildMsgAndOptions(_sendParam, amountReceivedLD);

        // Send via LayerZero
        msgReceipt = _lzSend(_sendParam.dstEid, message, options, _fee, _refundAddress);
        oftReceipt = OFTReceipt(amountSentLD, amountReceivedLD);

        emit OFTSent(msgReceipt.guid, _sendParam.dstEid, msg.sender, amountSentLD, amountReceivedLD);
    }

    /// @dev Override to burn tokens instead of locking them (mint/burn pattern)
    function _debit(
        address _from,
        uint256 _amountLD,
        uint256 _minAmountLD,
        uint32 _dstEid
    ) internal override returns (uint256 amountSentLD, uint256 amountReceivedLD) {
        (amountSentLD, amountReceivedLD) = _debitView(_amountLD, _minAmountLD, _dstEid);
        // Pull and burn
        IERC20(token()).transferFrom(_from, address(this), amountSentLD);
        ITIP20(token()).burn(amountSentLD);
    }

    /// @dev Override to mint tokens instead of unlocking them (mint/burn pattern)
    function _credit(
        address _to,
        uint256 _amountLD,
        uint32 /*_srcEid*/
    ) internal override returns (uint256 amountReceivedLD) {
        ITIP20(token()).mint(_to, _amountLD);
        return _amountLD;
    }

    /// @dev Still need approval for transferFrom in _debit
    function approvalRequired() external pure override returns (bool) {
        return true;
    }

    /// @dev TIP20 has 6 decimals, sharedDecimals = 6
    function sharedDecimals() public pure override returns (uint8) {
        return 6;
    }

    /// @dev Override _payNative to use ERC20 token for gas payment
    ///      Checks if endpoint already has enough balance (pre-paid by Hop), otherwise pulls from msg.sender
    function _payNative(uint256 _nativeFee) internal virtual override returns (uint256) {
        if (_nativeFee == 0) return 0;
        if (nativeToken == address(0)) revert NativeTokenUnavailable();

        // Check if endpoint already has sufficient balance (Hop pre-paid the fee)
        uint256 endpointBalance = IERC20(nativeToken).balanceOf(address(endpoint));
        if (endpointBalance >= _nativeFee) {
            // Fee already paid by Hop, no additional payment needed
            return 0;
        }

        // Otherwise, pull ERC20 tokens from msg.sender to endpoint
        IERC20(nativeToken).transferFrom(msg.sender, address(endpoint), _nativeFee);
        return 0;
    }
}
