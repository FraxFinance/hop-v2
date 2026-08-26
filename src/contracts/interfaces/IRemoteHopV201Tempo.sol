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

    /// @notice The OFT's own token cannot settle the Tempo LayerZero fee.
    /// @dev Fee-inclusive sends pay the fee out of `IOFT(_oft).token()`, so that token must itself be a
    ///      whitelisted EndpointV2Alt stablecoin or be swappable to one on the stablecoin DEX. Only
    ///      stablecoin OFTs (e.g. frxUSD) qualify; non-stablecoin OFTs (frxETH, sfrxETH, WFRAX, FPI, ...)
    ///      have no such route and must be bridged with `sendOFT`, paying the fee from a gas stablecoin.
    error FeeInclusiveUnsupportedFeeToken(address feeToken);

    /// @notice Bridges a fixed net amount while paying the Tempo fee from the same source token allowance.
    /// @dev The fee token is always `IOFT(_oft).token()`. The function dust-cleans
    ///      `_amountToBridgeLD`, quotes the live converted fee, and performs no
    ///      transferFrom unless their sum is at most `_maxAmountInLD`.
    ///
    ///      Only available for stablecoin OFTs: the fee is settled out of `IOFT(_oft).token()`, so that
    ///      token must be a whitelisted EndpointV2Alt stablecoin (e.g. frxUSD) or swappable to one on the
    ///      stablecoin DEX. Otherwise it reverts with `FeeInclusiveUnsupportedFeeToken` before any pull;
    ///      bridge non-stablecoin OFTs with `sendOFT` instead.
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
    /// @dev Reverts with `FeeInclusiveUnsupportedFeeToken` for OFTs whose token cannot settle the fee
    ///      (see `sendOFTFeeInclusive`), so a successful quote also proves the send is supported.
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
