// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import { Script } from "forge-std/Script.sol";
import { console } from "forge-std/Script.sol";
import { RemoteHopV2 } from "src/contracts/hop/RemoteHopV2.sol";
import { ITransparentUpgradeableProxy } from "frax-std/FraxUpgradeableProxy.sol";

interface ISendLibrary {
    function treasury() external view returns (address);
}

/// @notice Recovery script to initialize the Sei RemoteHopV2 proxy after failed deployment.
/// @dev Pre-requisite: Sei msig (0x223a681fc5c5522c85C96157c0efA18cd6c5405c) must first call
///      changeAdmin(deployer) on the proxy to give deployer proxy admin back.
///
/// forge script src/script/hop/InitRemoteHopV2Sei.s.sol --rpc-url https://evm-rpc.sei-apis.com --broadcast --gcp --sender 0x54f9b12743a7deec0ea48721683cbebedc6e17bc
contract InitRemoteHopV2Sei is Script {
    // Addresses
    address constant PROXY = 0x0000006D38568b00B457580b734e0076C62de659;
    address constant IMPLEMENTATION = 0x0000000087ED0dD8b999aE6C7c30f95e9707a3C6;
    address constant REMOTE_ADMIN = 0x954286118E93df807aB6f99aE0454f8710f0a8B9;
    address constant PROXY_ADMIN_MSIG = 0x223a681fc5c5522c85C96157c0efA18cd6c5405c;

    // LZ config
    address constant ENDPOINT = 0x1a44076050125825900e736c501f859c50fE728c;
    uint32 constant LOCAL_EID = 30_280;
    address constant FRAXTAL_HOP = 0x00000000e18aFc20Afe54d4B2C8688bB60c06B36;
    address constant EXECUTOR = 0xc097ab8CD7b053326DFe9fB3E3a31a0CCe3B526f;
    address constant DVN = 0x6788f52439ACA6BFF597d3eeC2DC9a44B8FEE842;
    address constant SEND_LIBRARY = 0xC39161c743D0307EB9BCc9FEF03eeb9Dc4802de7;

    // Sei governance msig (for DEFAULT_ADMIN_ROLE)
    address constant SEI_MSIG = 0x0357D02fc95320b990322d3ff69204c3D251171b;

    // Approved OFTs
    address constant frxUsdOft = 0x80Eede496655FB9047dd39d9f418d5483ED600df;
    address constant sfrxUsdOft = 0x5Bff88cA1442c2496f7E475E9e7786383Bc070c0;
    address constant frxEthOft = 0x43eDD7f3831b08FE70B7555ddD373C8bF65a9050;
    address constant sfrxEthOft = 0x3Ec3849C33291a9eF4c5dB86De593EB4A37fDe45;
    address constant wFraxOft = 0x64445f0aecC51E94aD52d8AC56b7190e764E561a;
    address constant fpiOft = 0x90581eCa9469D8D7F5D3B60f4715027aDFCf7927;

    bytes32 constant PAUSER_ROLE = 0x65d7a28e3265b37a6474929f336521b332c1681b933f6cb9f3376673440d862a;

    function run() public {
        vm.startBroadcast();

        // --- Phase 1: Proxy admin operations (deployer must be proxy admin) ---

        // Build initialize calldata
        address[] memory approvedOfts = new address[](6);
        approvedOfts[0] = frxUsdOft;
        approvedOfts[1] = sfrxUsdOft;
        approvedOfts[2] = frxEthOft;
        approvedOfts[3] = sfrxEthOft;
        approvedOfts[4] = wFraxOft;
        approvedOfts[5] = fpiOft;

        address TREASURY = ISendLibrary(SEND_LIBRARY).treasury();
        console.log("Treasury:", TREASURY);

        bytes memory initializeArgs = abi.encodeCall(
            RemoteHopV2.initialize,
            (
                LOCAL_EID,
                ENDPOINT,
                bytes32(uint256(uint160(FRAXTAL_HOP))),
                3, // numDVNs
                EXECUTOR,
                DVN,
                TREASURY,
                approvedOfts
            )
        );

        // 1. upgradeToAndCall (requires deployer to be proxy admin)
        ITransparentUpgradeableProxy(PROXY).upgradeToAndCall(IMPLEMENTATION, initializeArgs);
        console.log("upgradeToAndCall: OK");

        // 2. Return proxy admin to msig
        ITransparentUpgradeableProxy(PROXY).changeAdmin(PROXY_ADMIN_MSIG);
        console.log("changeAdmin back to msig: OK");

        // --- Phase 2: Implementation calls (deployer is NOT proxy admin, calls fall through) ---

        RemoteHopV2 remoteHop = RemoteHopV2(payable(PROXY));

        // 3. Set Solana executor options
        remoteHop.setExecutorOptions(
            30_168,
            hex"0100210100000000000000000000000000030D40000000000000000000000000002DC6C0"
        );
        console.log("setExecutorOptions: OK");

        // 4. Grant PAUSER_ROLE to 7 signers
        remoteHop.grantRole(PAUSER_ROLE, 0x54C5Ef136D02b95C4Ff217aF93FA63F9E4119919); // carter
        remoteHop.grantRole(PAUSER_ROLE, 0x17e06ce6914E3969f7BD37D8b2a563890cA1c96e); // sam
        remoteHop.grantRole(PAUSER_ROLE, 0x8d8290d49e88D16d81C6aDf6C8774eD88762274A); // dhruvin
        remoteHop.grantRole(PAUSER_ROLE, 0xcbc616D595D38483e6AdC45C7E426f44bF230928); // travis
        remoteHop.grantRole(PAUSER_ROLE, 0x381e2495e683868F693AA5B1414F712f21d34b40); // thomas
        remoteHop.grantRole(PAUSER_ROLE, 0x6e74053a3798e0fC9a9775F7995316b27f21c4D2); // nader
        remoteHop.grantRole(PAUSER_ROLE, 0xC6EF452b0de9E95Ccb153c2A5A7a90154aab3419); // dennis
        console.log("grantRole PAUSER_ROLE x7: OK");

        // 5. Grant DEFAULT_ADMIN_ROLE to governance msig and RemoteAdmin
        remoteHop.grantRole(bytes32(0), SEI_MSIG);
        remoteHop.grantRole(bytes32(0), REMOTE_ADMIN);
        console.log("grantRole DEFAULT_ADMIN_ROLE to msig & remoteAdmin: OK");

        // 6. Renounce deployer's DEFAULT_ADMIN_ROLE
        remoteHop.renounceRole(bytes32(0), msg.sender);
        console.log("renounceRole DEFAULT_ADMIN_ROLE: OK");

        vm.stopBroadcast();

        console.log("\n=== Sei RemoteHopV2 initialization complete ===");
        console.log("Proxy:", PROXY);
        console.log("Implementation:", IMPLEMENTATION);
        console.log("Proxy Admin:", PROXY_ADMIN_MSIG);
        console.log("RemoteAdmin:", REMOTE_ADMIN);
    }
}
