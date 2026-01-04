pragma solidity 0.8.23;

import { BaseScript } from "frax-std/BaseScript.sol";
import { console } from "frax-std/BaseScript.sol";
import { RemoteVaultHop } from "src/contracts/vault/RemoteVaultHop.sol";
import { FraxUpgradeableProxy } from "frax-std/FraxUpgradeableProxy.sol";

abstract contract DeployRemoteVaultHop is BaseScript {
    address frxUSD;
    address frxUsdOft;
    address HOPV2;
    uint32 EID;
    address proxyAdmin;

    function run() public broadcaster {
        bytes memory initializeArgs = abi.encodeCall(
            RemoteVaultHop.initialize,
            (frxUSD, frxUsdOft, HOPV2, EID, proxyAdmin)
        );
        address implementation = address(new RemoteVaultHop());
        FraxUpgradeableProxy vaultHopProxy = new FraxUpgradeableProxy(implementation, proxyAdmin, initializeArgs);
        RemoteVaultHop vaultHop = RemoteVaultHop(payable(address(vaultHopProxy)));
        console.log("RemoteVaultHop deployed at:", address(vaultHop));

        if (EID == 30_255) {
            vaultHop.addLocalVault(
                0x8EdA613EC96992D3C42BCd9aC2Ae58a92929Ceb2,
                0x8EdA613EC96992D3C42BCd9aC2Ae58a92929Ceb2
            );
        } else {
            vaultHop.setRemoteVaultHop(30_255, 0x10AF0e184CfEEB8167e82B1Fa7d0AA243453e902);
            vaultHop.addRemoteVault(
                30_255,
                0x8EdA613EC96992D3C42BCd9aC2Ae58a92929Ceb2,
                "Remote Fraxtal Fraxlend frxUSD (WFRAX)",
                "rffrxUSD(WFRAX)"
            );
        }
    }
}
