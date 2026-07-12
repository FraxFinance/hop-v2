// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import { RemoteHopV201 } from "src/contracts/hop/RemoteHopV201.sol";
import { FraxUpgradeableProxy, ITransparentUpgradeableProxy } from "frax-std/FraxUpgradeableProxy.sol";

function deployRemoteHopV201(
    address _proxyAdmin,
    uint32 _localEid,
    address _endpoint,
    bytes32 _fraxtalHop,
    uint32 _numDVNs,
    address _EXECUTOR,
    address _DVN,
    address _TREASURY,
    address[] memory _approvedOfts
) returns (address payable) {
    bytes memory initializeArgs = abi.encodeCall(
        RemoteHopV201.initialize,
        (_localEid, _endpoint, _fraxtalHop, _numDVNs, _EXECUTOR, _DVN, _TREASURY, _approvedOfts)
    );

    address implementation = address(new RemoteHopV201());
    FraxUpgradeableProxy proxy = new FraxUpgradeableProxy(
        implementation,
        0x54F9b12743A7DeeC0ea48721683cbebedC6E17bC,
        ""
    );

    ITransparentUpgradeableProxy(address(proxy)).upgradeToAndCall(implementation, initializeArgs);
    ITransparentUpgradeableProxy(address(proxy)).changeAdmin(_proxyAdmin);

    return payable(address(proxy));
}
