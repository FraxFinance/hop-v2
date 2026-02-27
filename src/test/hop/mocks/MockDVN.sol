// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @title MockDVN
/// @notice Mock DVN for testing quoteHop
contract MockDVN {
    uint256 public constant FEE_PER_CONFIRMATION = 1000; // 1000 wei per confirmation

    function getFee(
        uint32, // _dstEid
        uint64 _confirmations,
        address, // _sender
        bytes calldata // _options
    ) external pure returns (uint256) {
        return FEE_PER_CONFIRMATION * _confirmations;
    }
}
