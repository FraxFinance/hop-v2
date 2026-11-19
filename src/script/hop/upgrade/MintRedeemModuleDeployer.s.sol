// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import { FraxUpgradeableProxy } from "frax-std/FraxUpgradeableProxy.sol";
import { MintRedeemModule } from "src/contracts/hop/MintRedeemModule.sol";

/// @dev The proxy runs `initialize` inside its constructor and is created with `_proxyAdmin` as admin, so there is
///      no temporary admin and no dependence on who the caller is. (The hop helpers cannot do this because their
///      proxy init code is pinned for CREATE2; the module has no such constraint.)
function deployMintRedeemModule(
    address _proxyAdmin,
    address _admin,
    address _hub,
    address _mintRedeemer,
    address _assetOft,
    address _shareOft
) returns (address) {
    bytes memory initializeArgs = abi.encodeCall(
        MintRedeemModule.initialize,
        (_admin, _hub, _mintRedeemer, _assetOft, _shareOft)
    );
    address implementation = address(new MintRedeemModule());
    return address(new FraxUpgradeableProxy(implementation, _proxyAdmin, initializeArgs));
}
