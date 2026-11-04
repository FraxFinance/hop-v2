// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import { Script, console } from "forge-std/Script.sol";
import { MintRedeemModule } from "src/contracts/hop/MintRedeemModule.sol";
import { deployMintRedeemModule } from "src/script/hop/upgrade/MintRedeemModuleDeployer.s.sol";

// Deploys the mint/redeem action module behind a FraxUpgradeableProxy whose admin is the hub's ProxyAdmin,
// so the Safe that upgrades the hub upgrades the module too. Point the hub at it with
// `FraxtalHopV201.setActionModule(proxy)` (DEFAULT_ADMIN_ROLE), which `UpgradeFraxtalHopV2.s.sol` adds to
// the Fraxtal batch when ACTION_MODULE is set.
//
// forge script src/script/hop/upgrade/DeployMintRedeemModule.s.sol --rpc-url https://rpc.frax.com --gcp --sender 0x54f9b12743a7deec0ea48721683cbebedc6e17bc --broadcast --verify --verifier etherscan --etherscan-api-key $ETHERSCAN_API_KEY
contract DeployMintRedeemModule is Script {
    address constant HUB = 0x00000000e18aFc20Afe54d4B2C8688bB60c06B36;
    /// @dev Owned by the Fraxtal Safe below; the same ProxyAdmin that fronts the hub.
    address constant PROXY_ADMIN = 0x223a681fc5c5522c85C96157c0efA18cd6c5405c;
    address constant ADMIN = 0xC4EB45d80DC1F079045E75D5d55de8eD1c1090E6;
    address constant MINT_REDEEMER = 0xBFc4D34Db83553725eC6c768da71D2D9c1456B55;
    address constant FRXUSD_LOCKBOX = 0x96A394058E2b84A89bac9667B19661Ed003cF5D4;
    address constant SFRXUSD_LOCKBOX = 0x88Aa7854D3b2dAA5e37E7Ce73A1F39669623a361;

    function run() public returns (address proxy) {
        require(block.chainid == 252, "run against Fraxtal");

        vm.startBroadcast();
        proxy = deployMintRedeemModule(PROXY_ADMIN, ADMIN, HUB, MINT_REDEEMER, FRXUSD_LOCKBOX, SFRXUSD_LOCKBOX);
        vm.stopBroadcast();

        MintRedeemModule module = MintRedeemModule(proxy);
        require(module.hub() == HUB && module.assetOft() == FRXUSD_LOCKBOX && module.shareOft() == SFRXUSD_LOCKBOX);
        console.log("MintRedeemModule proxy:", proxy);
    }
}
