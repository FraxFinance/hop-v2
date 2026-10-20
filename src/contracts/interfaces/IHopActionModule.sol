// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

/// @notice A contract the Fraxtal hub delegates tagged actions to. See `HopActions`.
interface IHopActionModule {
    /// @notice The OFT the hub forwards after `convert(_action, _oftIn, ...)`. Reverts for an unsupported input.
    function outputOft(bytes4 _action, address _oftIn) external view returns (address oftOut);

    /// @notice Pull `_amountIn` of `_oftIn`'s token from the caller (the hub), convert it, and deliver the
    ///         output token straight back to the caller.
    /// @return oftOut The OFT of the delivered token, always equal to `outputOft(_action, _oftIn)`
    /// @return amountOut The amount delivered to the caller
    function convert(
        bytes4 _action,
        address _oftIn,
        uint256 _amountIn
    ) external returns (address oftOut, uint256 amountOut);
}
