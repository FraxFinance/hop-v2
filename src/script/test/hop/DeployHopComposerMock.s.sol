pragma solidity ^0.8.0;

import { BaseScript } from "frax-std/BaseScript.sol";
import { HopComposerMock } from "src/script/test/hop/mocks/HopComposerMock.sol";

// forge script src/script/test/hop/DeployHopComposerMock.s.sol
contract DeployHopComposerMock is BaseScript {
    uint256 public configDeployerPK = vm.envUint("PK_CONFIG_DEPLOYER");

    function run() public {
        vm.startBroadcast(configDeployerPK);
        new HopComposerMock();
        vm.stopBroadcast();
    }
}
