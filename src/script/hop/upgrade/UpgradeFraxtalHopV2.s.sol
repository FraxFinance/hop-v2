pragma solidity ^0.8.0;

import { UpgradeHopV2 } from "src/script/hop/upgrade/UpgradeHopV2.sol";
import { FraxtalHopV201 } from "src/contracts/hop/FraxtalHopV201.sol";

// forge script src/script/hop/upgrade/UpgradeFraxtalHopV2.s.sol --rpc-url https://rpc.frax.com --ffi --gcp --sender 0x54f9b12743a7deec0ea48721683cbebedc6e17bc --broadcast --verify --verifier etherscan --etherscan-api-key $ETHERSCAN_API_KEY
contract UpgradeFraxtalHopV2 is UpgradeHopV2 {
    function setUp() public override {
        hop = 0x00000000e18aFc20Afe54d4B2C8688bB60c06B36;
        super.setUp();
    }

    function deployImplementation() internal virtual override {
        vm.startBroadcast();

        newImplementation = address(
            new FraxtalHopV201{ salt: 0x4e59b44847b379578588920ca78fbf26c0b4956cada2dc35a2676e8544030084 }()
        );
        require(newImplementation == 0x00000000d25B8809150b59ce5dAE5699FfD26485, "Unexpected implementation address");

        vm.stopBroadcast();
    }
}
