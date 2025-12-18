// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

interface IHopComposer {
    function hopCompose(uint32 _srcEid, bytes32 _sender, address _oft, uint256 _amount, bytes memory _data) external;
}
