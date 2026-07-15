// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import { FraxtalHopV201 } from "src/contracts/hop/FraxtalHopV201.sol";
import { FraxUpgradeableProxy, ITransparentUpgradeableProxy } from "frax-std/FraxUpgradeableProxy.sol";

function deployFraxtalHopV201(
    address _proxyAdmin,
    uint32 _LOCALEID,
    address _endpoint,
    uint32 _NUMDVN,
    address _EXECUTOR,
    address _DVN,
    address _TREASURY,
    address[] memory _approvedOfts
) returns (address payable) {
    bytes memory initializeArgs = abi.encodeCall(
        FraxtalHopV201.initialize,
        (_LOCALEID, _endpoint, _NUMDVN, _EXECUTOR, _DVN, _TREASURY, _approvedOfts)
    );

    address implementation = address(new FraxtalHopV201());
    FraxUpgradeableProxy proxy = new FraxUpgradeableProxy(
        implementation,
        0x54F9b12743A7DeeC0ea48721683cbebedC6E17bC,
        ""
    );

    ITransparentUpgradeableProxy(address(proxy)).upgradeToAndCall(implementation, initializeArgs);
    ITransparentUpgradeableProxy(address(proxy)).changeAdmin(_proxyAdmin);

    return payable(address(proxy));
}
