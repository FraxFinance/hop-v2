// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @title MockTreasury
/// @notice Mock LayerZero Treasury for testing quoteHop
contract MockTreasury {
    /// @notice Returns a fixed treasury fee of 0 for testing
    function getFee(
        address, // _sender
        uint32, // _dstEid
        uint256, // _totalFee
        bool // _payInLzToken
    ) external pure returns (uint256) {
        return 0; // No treasury fee for testing
    }
}
