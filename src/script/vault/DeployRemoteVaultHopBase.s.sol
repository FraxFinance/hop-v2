pragma solidity 0.8.23;

import { DeployRemoteVaultHop } from "./DeployRemoteVaultHop.s.sol";

// 0x7786473Eff6CE620A4832e98310827B228ee4ed9 - RemoteVaultHop
// 0xF52F46b1207A3Dc1b6e55EdBbd59B17947C8aB25 - RemoteVaulDeposit
contract DeployRemoteVaultHopBase is DeployRemoteVaultHop {
    constructor() {
        frxUSD = 0xe5020A6d073a794B6E7f05678707dE47986Fb0b6;
        frxUsdOft = 0xe5020A6d073a794B6E7f05678707dE47986Fb0b6;
        HOPV2 = 0x22beDD55A0D29Eb31e75C70F54fADa7Ca94339B9;
        EID = 30_184;
        proxyAdmin = 0xF59C41A57AB4565AF7424F64981523DfD7A453c5;
    }
}
