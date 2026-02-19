// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import { Script } from "forge-std/Script.sol";
import { console } from "forge-std/Script.sol";
import { FraxtalHopV2 } from "src/contracts/hop/FraxtalHopV2.sol";
import { HopV2 } from "src/contracts/hop/HopV2.sol";
import { RemoteAdmin } from "src/contracts/RemoteAdmin.sol";

import { FraxUpgradeableProxy, ITransparentUpgradeableProxy } from "frax-std/FraxUpgradeableProxy.sol";

// forge script src/script/hop/DeployFraxtalHopV2.s.sol --rpc-url https://rpc.frax.com --broadcast --verify --verifier etherscan --etherscan-api-key $TODO
contract DeployFraxtalHopV2 is Script {
    address constant proxyAdmin = 0x223a681fc5c5522c85C96157c0efA18cd6c5405c;
    address constant msig = 0x5f25218ed9474b721d6a38c115107428E832fA2E;

    address constant frxUsdLockbox = 0x96A394058E2b84A89bac9667B19661Ed003cF5D4;
    address constant sfrxUsdLockbox = 0x88Aa7854D3b2dAA5e37E7Ce73A1F39669623a361;
    address constant frxEthLockbox = 0x9aBFE1F8a999B0011ecD6116649AEe8D575F5604;
    address constant sfrxEthLockbox = 0x999dfAbe3b1cc2EF66eB032Eea42FeA329bBa168;
    address constant fxsLockbox = 0xd86fBBd0c8715d2C1f40e451e5C3514e65E7576A;
    address constant fpiLockbox = 0x75c38D46001b0F8108c4136216bd2694982C20FC;
    address[] approvedOfts;

    address constant EXECUTOR = 0x41Bdb4aa4A63a5b2Efc531858d3118392B1A1C3d;
    address constant DVN = 0xcCE466a522984415bC91338c232d98869193D46e;
    address constant TREASURY = 0xc1B621b18187F74c8F6D52a6F709Dd2780C09821;

    function run() public {
        approvedOfts.push(frxUsdLockbox);
        approvedOfts.push(sfrxUsdLockbox);
        approvedOfts.push(frxEthLockbox);
        approvedOfts.push(sfrxEthLockbox);
        approvedOfts.push(fxsLockbox);
        approvedOfts.push(fpiLockbox);

        vm.startBroadcast();

        address hop = deployFraxtalHopV2(
            proxyAdmin,
            30_255,
            0x1a44076050125825900e736c501f859c50fE728c,
            3,
            EXECUTOR,
            DVN,
            TREASURY,
            approvedOfts
        );
        console.log("FraxtalHopV2 deployed at:", hop);

        address remoteAdmin = address(new RemoteAdmin(frxUsdLockbox, hop, msig));
        console.log("RemoteAdmin deployed at:", remoteAdmin);

        // grant Pauser roles to msig msig owners
        bytes32 PAUSER_ROLE = 0x65d7a28e3265b37a6474929f336521b332c1681b933f6cb9f3376673440d862a;

        // carter
        HopV2(hop).grantRole(PAUSER_ROLE, 0x54C5Ef136D02b95C4Ff217aF93FA63F9E4119919);
        // sam
        HopV2(hop).grantRole(PAUSER_ROLE, 0x17e06ce6914E3969f7BD37D8b2a563890cA1c96e);
        // dhruvin
        HopV2(hop).grantRole(PAUSER_ROLE, 0x8d8290d49e88D16d81C6aDf6C8774eD88762274A);
        // travis
        HopV2(hop).grantRole(PAUSER_ROLE, 0xcbc616D595D38483e6AdC45C7E426f44bF230928);
        // thomas
        HopV2(hop).grantRole(PAUSER_ROLE, 0x381e2495e683868F693AA5B1414F712f21d34b40);
        // nader
        HopV2(hop).grantRole(PAUSER_ROLE, 0x6e74053a3798e0fC9a9775F7995316b27f21c4D2);
        // dennis
        HopV2(hop).grantRole(PAUSER_ROLE, 0xC6EF452b0de9E95Ccb153c2A5A7a90154aab3419);

        // transfer admin role to fraxtal msig & RemoteAdmin and renounce from deployer
        HopV2(hop).grantRole(bytes32(0), msig);
        HopV2(hop).grantRole(bytes32(0), remoteAdmin);
        HopV2(hop).renounceRole(bytes32(0), msg.sender);

        vm.stopBroadcast();
    }
}

function deployFraxtalHopV2(
    address _proxyAdmin,
    uint32 _LOCALEID,
    address _endpoint,
    uint32 _NUMDVN,
    address _EXECUTOR,
    address _DVN,
    address _TREASURY,
    address[] memory _approvedOfts
) returns (address payable) {
    bytes memory initializeArgs = abi.encodeCall(
        FraxtalHopV2.initialize,
        (_LOCALEID, _endpoint, _NUMDVN, _EXECUTOR, _DVN, _TREASURY, _approvedOfts)
    );

    //
    address implementation = address(
        new FraxtalHopV2{ salt: bytes32(0x4e59b44847b379578588920ca78fbf26c0b4956c91747cf1b91c32641c050060) }()
    );
    require(implementation == 0x1E92C54DccA30015ca00a1e19500004600003f02, "Implementation deployment failed");
    FraxUpgradeableProxy proxy = new FraxUpgradeableProxy{
        salt: bytes32(0x4e59b44847b379578588920ca78fbf26c0b4956c7f4c78212c484a739f030080)
    }(implementation, msg.sender, "");
    require(address(proxy) == 0x00000000e18aFc20Afe54d4B2C8688bB60c06B36, "Proxy deployment failed");

    ITransparentUpgradeableProxy(address(proxy)).upgradeToAndCall(implementation, initializeArgs);
    ITransparentUpgradeableProxy(address(proxy)).changeAdmin(_proxyAdmin);
    return payable(address(proxy));
}
