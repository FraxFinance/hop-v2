// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import { BaseScript } from "frax-std/BaseScript.sol";
import { SafeTxHelper, SafeTx } from "frax-std/SafeTxHelper.sol";
import { IAccessControl } from "@openzeppelin/contracts/access/IAccessControl.sol";
import { IHopV2 } from "src/contracts/interfaces/IHopV2.sol";

// forge script src/script/hop/RemoteAdmin/SetEthereumDefaultAdminRole.s.sol --rpc-url https://rpc.frax.com --ffi
contract SetEthereumDefaultAdminRole is BaseScript {
    address public constant FRAXTAL_HOP = 0x00000000e18aFc20Afe54d4B2C8688bB60c06B36;
    address public constant FRAXTAL_MSIG = 0x5f25218ed9474b721d6a38c115107428E832fA2E;
    address public constant FRXUSD_LOCKBOX = 0x96A394058E2b84A89bac9667B19661Ed003cF5D4;
    address public constant REMOTE_HOP = 0x0000006D38568b00B457580b734e0076C62de659;
    uint128 public constant COMPOSE_GAS = 400_000;

    struct HopData {
        string name;
        uint32 eid;
        address hop;
        address remoteAdmin;
    }

    HopData public hopData;
    SafeTx[] public txs;

    constructor() {
        hopData = HopData({
            name: "Ethereum",
            eid: 30_101,
            hop: REMOTE_HOP,
            remoteAdmin: 0x181EBC9deA868ED8e5EeeAef7f767D43BF390dFa
        });
    }

    function setUp() public override {}

    function run() external {
        bytes memory remoteCall = abi.encodeCall(
            IAccessControl.grantRole,
            (bytes32(0), 0xB1748C79709f4Ba2Dd82834B8c82D4a505003f27)
        );
        bytes memory data = abi.encode(hopData.hop, remoteCall);

        uint256 fee = IHopV2(FRAXTAL_HOP).quote({
            _oft: FRXUSD_LOCKBOX,
            _dstEid: hopData.eid,
            _recipient: bytes32(uint256(uint160(hopData.remoteAdmin))),
            _amountLD: 0,
            _dstGas: COMPOSE_GAS,
            _data: data
        });
        fee = (fee * 150) / 100;

        bytes memory localCall = abi.encodeWithSignature(
            "sendOFT(address,uint32,bytes32,uint256,uint128,bytes)",
            FRXUSD_LOCKBOX,
            hopData.eid,
            bytes32(uint256(uint160(hopData.remoteAdmin))),
            uint256(0),
            COMPOSE_GAS,
            data
        );

        vm.prank(FRAXTAL_MSIG);
        (bool success, ) = FRAXTAL_HOP.call{ value: fee }(localCall);
        require(success, string.concat("sendOFT failed for ", hopData.name));

        txs.push(
            SafeTx({
                name: string.concat("Set DEFAULT_ADMIN_ROLE on ", hopData.name),
                to: FRAXTAL_HOP,
                value: fee,
                data: localCall
            })
        );

        string memory root = vm.projectRoot();
        string memory filename = string(
            abi.encodePacked(root, "/src/script/hop/RemoteAdmin/txs/SetEthereumDefaultAdminRole.json")
        );
        new SafeTxHelper().writeTxs(txs, filename);
    }
}
