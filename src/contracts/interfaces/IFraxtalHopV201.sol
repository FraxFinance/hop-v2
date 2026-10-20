// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

/// @notice Hub-only surface of `FraxtalHopV201`: the action module that executes tagged `HopMessage.data`.
interface IFraxtalHopV201 {
    event ActionModuleSet(address indexed module);
    event ActionApplied(
        bytes4 indexed action,
        address indexed oftIn,
        address indexed oftOut,
        uint256 amountIn,
        uint256 amountOut,
        uint32 srcEid,
        uint32 dstEid,
        bytes32 recipient
    );

    error ActionUnavailable();
    error ActionOutputMismatch();

    function setActionModule(address _module) external;

    function actionModule() external view returns (address);
}
