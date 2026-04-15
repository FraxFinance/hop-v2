// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import { BaseScript } from "frax-std/BaseScript.sol";
import { SafeTxHelper, SafeTx } from "frax-std/SafeTxHelper.sol";
import { IHopV2 } from "src/contracts/interfaces/IHopV2.sol";

// forge script src/script/hop/RemoteAdmin/SetTempoExecutorOptions.s.sol --rpc-url https://rpc.frax.com
contract SetTempoExecutorOptions is BaseScript {
    address public constant FRAXTAL_HOP = 0x00000000e18aFc20Afe54d4B2C8688bB60c06B36;
    address public constant FRAXTAL_MSIG = 0x5f25218ed9474b721d6a38c115107428E832fA2E;
    address public constant FRXUSD_LOCKBOX = 0x96A394058E2b84A89bac9667B19661Ed003cF5D4;
    address public constant REMOTE_HOP = 0x0000006D38568b00B457580b734e0076C62de659;

    uint32 public constant TEMPO_EID = 30_410;
    uint128 public constant COMPOSE_GAS = 400_000;
    uint128 public constant TEMPO_RECEIVE_GAS = 2_500_000;

    struct HopData {
        string name;
        uint32 eid;
        address hop;
        address remoteAdmin;
    }

    HopData[] public hopDatas;

    constructor() {
        _addHop("Arbitrum", 30_110, 0x954286118E93df807aB6f99aE0454f8710f0a8B9);
        _addHop("Aurora", 30_211, 0x954286118E93df807aB6f99aE0454f8710f0a8B9);
        _addHop("Avalanche", 30_106, 0x954286118E93df807aB6f99aE0454f8710f0a8B9);
        _addHop("Berachain", 30_362, 0x954286118E93df807aB6f99aE0454f8710f0a8B9);
        _addHop("BSC", 30_102, 0x954286118E93df807aB6f99aE0454f8710f0a8B9);
        _addHop("Hyperliquid", 30_367, 0x954286118E93df807aB6f99aE0454f8710f0a8B9);
        _addHop("Ink", 30_339, 0x954286118E93df807aB6f99aE0454f8710f0a8B9);
        _addHop("Katana", 30_375, 0x954286118E93df807aB6f99aE0454f8710f0a8B9);
        _addHop("Mode", 30_260, 0x954286118E93df807aB6f99aE0454f8710f0a8B9);
        _addHop("Optimism", 30_111, 0x954286118E93df807aB6f99aE0454f8710f0a8B9);
        _addHop("Sei", 30_280, 0x954286118E93df807aB6f99aE0454f8710f0a8B9);
        _addHop("Sonic", 30_332, 0x954286118E93df807aB6f99aE0454f8710f0a8B9);
        _addHop("Unichain", 30_320, 0x954286118E93df807aB6f99aE0454f8710f0a8B9);
        _addHop("Worldchain", 30_319, 0x954286118E93df807aB6f99aE0454f8710f0a8B9);
        _addHop("X-Layer", 30_274, 0x954286118E93df807aB6f99aE0454f8710f0a8B9);
        _addHop("Abstract", 30_324, 0x000000000E0E120FCAc7b4d98e9E35E1DE6fdadb);
        _addHop("Base", 30_184, 0x07dB789aD17573e5169eDEfe14df91CC305715AA);
        _addHop("Ethereum", 30_101, 0x181EBC9deA868ED8e5EeeAef7f767D43BF390dFa);
        _addHop("Linea", 30_183, 0xfa803b63DaACCa6CD953061BDBa4E3da6b177447);
        _addHop("Scroll", 30_214, 0x1dE5910A2b0f860A226a8a43148aeA91afbE3d01);
        _addHop("ZkSync", 30_165, 0x000000000E0E120FCAc7b4d98e9E35E1DE6fdadb);
    }

    function setUp() public override {}

    function run() external {
        bytes memory tempoOptions = _tempoExecutorOptions();
        string memory root = vm.projectRoot();

        for (uint256 i = 0; i < hopDatas.length; i++) {
            HopData memory hopData = hopDatas[i];

            bytes memory remoteCall = abi.encodeCall(IHopV2.setExecutorOptions, (TEMPO_EID, tempoOptions));
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

            SafeTx[] memory singleTx = new SafeTx[](1);
            singleTx[0] = SafeTx({
                name: string.concat("Set Tempo executor options on ", hopData.name),
                to: FRAXTAL_HOP,
                value: fee,
                data: localCall
            });

            string memory filename = string(
                abi.encodePacked(
                    root,
                    "/src/script/hop/RemoteAdmin/txs/SetTempoExecutorOptions-",
                    hopData.name,
                    ".json"
                )
            );
            new SafeTxHelper().writeTxs(singleTx, filename);
        }
    }

    function _addHop(string memory _name, uint32 _eid, address _remoteAdmin) internal {
        hopDatas.push(HopData({ name: _name, eid: _eid, hop: REMOTE_HOP, remoteAdmin: _remoteAdmin }));
    }

    function _tempoExecutorOptions() internal pure returns (bytes memory) {
        return abi.encodePacked(uint8(1), uint16(17), uint8(1), uint128(TEMPO_RECEIVE_GAS));
    }
}
