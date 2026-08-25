// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

/// @title IRemoteHopV201Tempo
/// @notice Tempo-specific HopV201 entrypoints whose LayerZero fee is paid in TIP20.
interface IRemoteHopV201Tempo {
    /// @notice The requested bridge amount is zero after OFT dust removal.
    error FeeInclusiveZeroAmount();

    /// @notice Emitted when the bridge amount and messaging fee share one source-token input cap.
    event SendOFTFeeInclusive(
        address indexed oft,
        address indexed sender,
        uint32 indexed dstEid,
        bytes32 recipient,
        address feeToken,
        address paymentToken,
        uint256 amountToBridgeLD,
        uint256 feeAmountLD,
        uint256 maxAmountInLD
    );

    /// @notice The dust-cleaned bridge amount plus live converted fee exceeds the caller's input cap.
    error FeeInclusiveAmountExceedsMaximum(uint256 amountToBridgeLD, uint256 feeAmountLD, uint256 maxAmountInLD);

    /// @notice Bridges a fixed net amount while paying the Tempo fee from the same source token allowance.
    /// @dev The fee token is always `IOFT(_oft).token()`. The function dust-cleans
    ///      `_amountToBridgeLD`, quotes the live converted fee, and performs no
    ///      transferFrom unless their sum is at most `_maxAmountInLD`.
    function sendOFTFeeInclusive(
        address _oft,
        uint32 _dstEid,
        bytes32 _recipient,
        uint256 _amountToBridgeLD,
        uint256 _maxAmountInLD,
        uint128 _dstGas,
        bytes memory _data
    ) external payable;

    /// @notice Quotes the exact source-token accounting used by `sendOFTFeeInclusive`.
    /// @return amountToBridgeLD Dust-cleaned amount delivered to the OFT send path.
    /// @return feeToken Token pulled from the caller for both principal and fee.
    /// @return paymentToken Whitelisted token produced for EndpointV2Alt payment.
    /// @return feeAmountLD Amount of `feeToken` required by the current live quote.
    /// @return totalAmountInLD Sum of `amountToBridgeLD` and `feeAmountLD`.
    function quoteFeeInclusive(
        address _oft,
        uint32 _dstEid,
        bytes32 _recipient,
        uint256 _amountToBridgeLD,
        uint128 _dstGas,
        bytes memory _data
    )
        external
        view
        returns (
            uint256 amountToBridgeLD,
            address feeToken,
            address paymentToken,
            uint256 feeAmountLD,
            uint256 totalAmountInLD
        );
}
