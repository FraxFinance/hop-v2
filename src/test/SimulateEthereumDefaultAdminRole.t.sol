// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import { Test } from "forge-std/Test.sol";
import { IAccessControl } from "@openzeppelin/contracts/access/IAccessControl.sol";
import { IHopComposer } from "src/contracts/interfaces/IHopComposer.sol";

// Simulates the destination-side execution of SetEthereumDefaultAdminRole
// forge test --match-contract SimulateEthereumDefaultAdminRole --fork-url https://ethereum-rpc.publicnode.com -vvvv
contract SimulateEthereumDefaultAdminRole is Test {
    address constant REMOTE_HOP = 0x0000006D38568b00B457580b734e0076C62de659;
    address constant REMOTE_ADMIN = 0x181EBC9deA868ED8e5EeeAef7f767D43BF390dFa;
    address constant FRXUSD_OFT = 0x566a6442A5A6e9895B9dCA97cC7879D632c6e4B0;
    address constant FRAXTAL_MSIG = 0x5f25218ed9474b721d6a38c115107428E832fA2E;
    address constant COMPTROLLER = 0xB1748C79709f4Ba2Dd82834B8c82D4a505003f27;
    uint32 constant FRAXTAL_EID = 30_255;

    function test_simulateGrantDefaultAdminRole() external {
        // 1. Verify preconditions
        assertTrue(
            IAccessControl(REMOTE_HOP).hasRole(bytes32(0), REMOTE_ADMIN),
            "RemoteAdmin should have DEFAULT_ADMIN_ROLE"
        );
        assertFalse(
            IAccessControl(REMOTE_HOP).hasRole(bytes32(0), COMPTROLLER),
            "Comptroller should NOT have DEFAULT_ADMIN_ROLE yet"
        );

        // 2. Build the compose data (same as the script)
        bytes memory remoteCall = abi.encodeCall(
            IAccessControl.grantRole,
            (bytes32(0), COMPTROLLER)
        );
        bytes memory composeData = abi.encode(REMOTE_HOP, remoteCall);

        // 3. Simulate HopV2._sendLocal() calling RemoteAdmin.hopCompose()
        //    In reality, RemoteHop calls this after receiving the LZ compose message
        vm.prank(REMOTE_HOP);
        IHopComposer(REMOTE_ADMIN).hopCompose({
            _srcEid: FRAXTAL_EID,
            _sender: bytes32(uint256(uint160(FRAXTAL_MSIG))),
            _oft: FRXUSD_OFT,
            _amount: 0,
            _data: composeData
        });

        // 4. Verify postconditions
        assertTrue(
            IAccessControl(REMOTE_HOP).hasRole(bytes32(0), COMPTROLLER),
            "Comptroller should now have DEFAULT_ADMIN_ROLE"
        );
    }
}
