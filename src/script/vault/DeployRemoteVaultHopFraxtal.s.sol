pragma solidity 0.8.24;

import { DeployRemoteVaultHop } from "./DeployRemoteVaultHop.s.sol";

// 0x10AF0e184CfEEB8167e82B1Fa7d0AA243453e902
contract DeployRemoteVaultHopFraxtal is DeployRemoteVaultHop {
    constructor() {
        frxUSD = 0xFc00000000000000000000000000000000000001;
        frxUsdOft = 0x96A394058E2b84A89bac9667B19661Ed003cF5D4;
        HOPV2 = 0xe8Cd13de17CeC6FCd9dD5E0a1465Da240f951536;
        EID = 30_255; // Fraxtal Mainnet
        proxyAdmin = 0x223a681fc5c5522c85C96157c0efA18cd6c5405c;
    }
}
