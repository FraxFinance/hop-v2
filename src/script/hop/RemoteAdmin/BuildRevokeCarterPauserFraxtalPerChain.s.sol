// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import { Script, console } from "forge-std/Script.sol";
import { SafeTxHelper, SafeTx } from "frax-std/SafeTxHelper.sol";
import { IAccessControl } from "@openzeppelin/contracts/access/IAccessControl.sol";
import { IHopV2 } from "src/contracts/interfaces/IHopV2.sol";
import { HopConstants, HopV2Target, RemoteAdminRoute } from "src/script/hop/HopConstants.sol";

// Generic role revoke builder.
// Required env vars:
// - ROLE: bytes32 role to revoke (hex string)
// - ACCOUNT: address to revoke role from
// Optional env vars:
// - ROLE_LABEL: human label used in Safe tx names, e.g. "PAUSER_ROLE"
// - OUTPUT_DIR: output directory for per-chain JSON files
// ROLE=0x65d7a28e3265b37a6474929f336521b332c1681b933f6cb9f3376673440d862a ACCOUNT=0x54C5Ef136D02b95C4Ff217aF93FA63F9E4119919 ROLE_LABEL=PAUSER_ROLE OUTPUT_DIR=src/script/hop/RemoteAdmin/txs/RevokeCarterPauserAllChains forge script src/script/hop/RemoteAdmin/BuildRevokeCarterPauserFraxtalPerChain.s.sol --rpc-url https://rpc.frax.com --ffi
contract BuildRevokeCarterPauserFraxtalPerChain is Script, HopConstants {
    address public constant FRAXTAL_HOP = 0x00000000e18aFc20Afe54d4B2C8688bB60c06B36;
    address public constant FRXUSD_LOCKBOX = 0x96A394058E2b84A89bac9667B19661Ed003cF5D4;
    uint32 public constant FRAXTAL_EID = 30_255;
    uint128 public constant COMPOSE_GAS = 400_000;

    function run() external {
        bytes32 role = _roleToRevoke();
        address account = _accountToRevoke();
        string memory roleLabel = _roleLabel();
        string memory outputDir = _outputDir();

        bytes memory remoteCall = abi.encodeCall(IAccessControl.revokeRole, (role, account));
        vm.createDir(outputDir, true);
        RemoteAdminRoute[] storage routes = _remoteAdminRoutes();

        console.log("Role:", vm.toString(role));
        console.log("Account:", account);

        for (uint256 i = 0; i < routes.length; i++) {
            RemoteAdminRoute memory route = routes[i];
            HopV2Target storage target = _hopV2TargetFor(route.chainId);
            address remoteAdmin = _remoteAdminForEid(route.eid);

            bytes memory composeData = abi.encode(target.hop, remoteCall);
            uint256 fee = IHopV2(FRAXTAL_HOP).quote({
                _oft: FRXUSD_LOCKBOX,
                _dstEid: route.eid,
                _recipient: bytes32(uint256(uint160(remoteAdmin))),
                _amountLD: 0,
                _dstGas: COMPOSE_GAS,
                _data: composeData
            });
            fee = (fee * 150) / 100;

            bytes memory localCall = abi.encodeWithSignature(
                "sendOFT(address,uint32,bytes32,uint256,uint128,bytes)",
                FRXUSD_LOCKBOX,
                route.eid,
                bytes32(uint256(uint160(remoteAdmin))),
                uint256(0),
                COMPOSE_GAS,
                composeData
            );

            SafeTx[] memory txs = new SafeTx[](1);
            txs[0] = SafeTx({
                name: string.concat("Revoke ", roleLabel, " on ", target.name),
                to: FRAXTAL_HOP,
                value: fee,
                data: localCall
            });

            string memory filename = string(
                abi.encodePacked(
                    outputDir,
                    "/",
                    vm.toString(uint256(FRAXTAL_EID)),
                    "-",
                    vm.toString(uint256(route.eid)),
                    "(",
                    target.name,
                    ").json"
                )
            );

            new SafeTxHelper().writeTxs(txs, filename);
            console.log("Wrote:", filename);
        }
    }

    function _roleToRevoke() internal view returns (bytes32 role) {
        require(vm.envExists("ROLE"), "missing ROLE env");
        role = vm.envBytes32("ROLE");
    }

    function _accountToRevoke() internal view returns (address account) {
        require(vm.envExists("ACCOUNT"), "missing ACCOUNT env");
        account = vm.envAddress("ACCOUNT");
    }

    function _roleLabel() internal view returns (string memory label) {
        label = vm.envExists("ROLE_LABEL") ? vm.envString("ROLE_LABEL") : "PAUSER_ROLE";
    }

    function _outputDir() internal view returns (string memory dir) {
        dir = vm.envExists("OUTPUT_DIR")
            ? vm.envString("OUTPUT_DIR")
            : "src/script/hop/RemoteAdmin/txs/RevokeRoleAllChains";
    }
}
