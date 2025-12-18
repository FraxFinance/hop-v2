// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

interface ILayerZeroTreasury {
    function getFee(
        address _sender,
        uint32 _dstEid,
        uint256 _totalNativeFee,
        bool _payInLzToken
    ) external view returns (uint256 fee);
}
