pragma solidity 0.8.23;

import { UpgradeHopV2 } from "src/script/hop/upgrade/UpgradeHopV2.sol";
import { FraxtalHopV201 } from "src/contracts/hop/FraxtalHopV201.sol";

// forge script src/script/hop/upgrade/UpgradeFraxtalHopV2.s.sol --rpc-url https://rpc.frax.com --ffi --gcp --sender 0x54f9b12743a7deec0ea48721683cbebedc6e17bc --broadcast --verify --verifier etherscan --etherscan-api-key $ETHERSCAN_API_KEY
contract UpgradeFraxtalHopV2 is UpgradeHopV2 {
    function setUp() public override {
        hop = 0x00000000e18aFc20Afe54d4B2C8688bB60c06B36;
        super.setUp();
    }

    bytes32 internal constant SALT = 0x4e59b44847b379578588920ca78fbf26c0b4956cada2dc35a2676e8544030084;

    function deployImplementation() internal virtual override {
        newImplementation = _deployCreate2(SALT, type(FraxtalHopV201).creationCode);
    }
}
