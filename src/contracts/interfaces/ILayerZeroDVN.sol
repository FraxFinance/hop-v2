// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

interface ILayerZeroDVN {
    // @notice query the dvn fee for relaying block information to the destination chain
    // @param _dstEid the destination endpoint identifier
    // @param _confirmations - block confirmation delay before relaying blocks
    // @param _sender - the source sending contract address
    // @param _options - options
    function getFee(
        uint32 _dstEid,
        uint64 _confirmations,
        address _sender,
        bytes calldata _options
    ) external view returns (uint256 fee);
}
