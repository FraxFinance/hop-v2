pragma solidity ^0.8.0;

import { UpgradeHopV2 } from "src/script/hop/upgrade/UpgradeHopV2.s.sol";
import { FraxtalHopV201 } from "src/contracts/hop/FraxtalHopV201.sol";

// forge script src/script/hop/upgrade/UpgradeFraxtalHopV2.s.sol --rpc-url https://rpc.frax.com --broadcast --verify --verifier etherscan --etherscan-api-key $ETHERSCAN_API_KEY
contract UpgradeFraxtalHopV2 is UpgradeHopV2 {
    function setUp() public override {
        hop = 0x00000000e18aFc20Afe54d4B2C8688bB60c06B36;
        super.setUp();
    }

    function deployImplementation() internal override {
        vm.startBroadcast();

        newImplementation = address(
            new FraxtalHopV201{ salt: 0x4e59b44847b379578588920ca78fbf26c0b4956cdf60486171286f02d00800c0 }()
        );
        require(newImplementation == 0x0074113c005e7E23000952000024Ac005eE1317c, "Unexpected implementation address");

        vm.stopBroadcast();
    }
}
