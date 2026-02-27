// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @title MockExecutor
/// @notice Mock Executor for testing quoteHop
contract MockExecutor {
    uint256 public constant BASE_FEE = 10_000; // 10000 wei base fee
    uint256 public constant FEE_PER_BYTE = 10; // 10 wei per byte

    function getFee(
        uint32, // _dstEid
        address, // _sender
        uint256 _calldataSize,
        bytes calldata // _options
    ) external pure returns (uint256) {
        return BASE_FEE + (_calldataSize * FEE_PER_BYTE);
    }
}
