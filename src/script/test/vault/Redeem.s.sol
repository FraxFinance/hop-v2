pragma solidity ^0.8.0;

import { BaseScript, console } from "frax-std/BaseScript.sol";

import { RemoteVaultHop } from "src/contracts/vault/RemoteVaultHop.sol";
import { RemoteVaultDeposit } from "src/contracts/vault/RemoteVaultDeposit.sol";

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

// forge script src/script/vault/test/Redeem.s.sol --rpc-url https://mainnet.base.org --broadcast
contract Redeem is BaseScript {
    address frxUsd = 0xe5020A6d073a794B6E7f05678707dE47986Fb0b6;
    RemoteVaultHop remoteVaultHop = RemoteVaultHop(payable(0x7786473Eff6CE620A4832e98310827B228ee4ed9));
    address fraxtalVault = 0x8EdA613EC96992D3C42BCd9aC2Ae58a92929Ceb2;

    function run() public broadcaster {
        RemoteVaultDeposit deposit = RemoteVaultDeposit(remoteVaultHop.depositToken(30_255, fraxtalVault));
        uint256 amount = IERC20(address(deposit)).balanceOf(0xb0E1650A9760e0f383174af042091fc544b8356f) / 2;
        uint256 fee = remoteVaultHop.quote(amount, 30_255, fraxtalVault);

        console.log(amount);
        deposit.redeem{ value: fee }(amount);
    }
}
