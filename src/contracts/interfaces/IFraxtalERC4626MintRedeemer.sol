// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

/// @notice The Fraxtal frxUSD <-> sfrxUSD mint-redeemer (0xBFc4D34Db83553725eC6c768da71D2D9c1456B55).
interface IFraxtalERC4626MintRedeemer {
    function deposit(uint256 _assetsIn, address _receiver) external returns (uint256 _sharesOut);
    function redeem(uint256 _sharesIn, address _receiver, address _owner) external returns (uint256 _assetsOut);
    function pricePerShare() external view returns (uint256);
}
