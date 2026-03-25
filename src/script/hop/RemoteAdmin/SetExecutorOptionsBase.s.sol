// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import { BaseScript } from "frax-std/BaseScript.sol";
import { SafeTxHelper, SafeTx } from "frax-std/SafeTxHelper.sol";
import { IHopV2 } from "src/contracts/interfaces/IHopV2.sol";

/// @notice Base contract for broadcasting a single admin call to all remote HopV2 instances via Fraxtal Hop.
/// Child contracts only need to implement `_remoteCall()`, `_txLabel()`, and `_outputFilename()`.
abstract contract SetExecutorOptionsBase is BaseScript {
    address public constant FRAXTAL_HOP = 0x00000000e18aFc20Afe54d4B2C8688bB60c06B36;
    address public constant FRAXTAL_MSIG = 0x5f25218ed9474b721d6a38c115107428E832fA2E;
    address public constant FRXUSD_LOCKBOX = 0x96A394058E2b84A89bac9667B19661Ed003cF5D4;
    uint128 public constant COMPOSE_GAS = 400_000;

    struct HopData {
        string name;
        uint32 eid;
        address hop;
        address remoteAdmin;
    }

    HopData[] public hopDatas;
    SafeTx[] public txs;

    // EIDs for which quote() / sendOFT() will revert (pathway not yet configured).
    // The tx is still added to the SafeTx JSON so it can be submitted later.
    mapping(uint32 => bool) public skipCall;

    constructor() {
        address DEFAULT_HOP = 0x0000006D38568b00B457580b734e0076C62de659;

        _addHop("Arbitrum", 30_110, DEFAULT_HOP, 0x954286118E93df807aB6f99aE0454f8710f0a8B9);
        _addHop("Aurora", 30_211, DEFAULT_HOP, 0x954286118E93df807aB6f99aE0454f8710f0a8B9);
        _addHop("Avalanche", 30_106, DEFAULT_HOP, 0x954286118E93df807aB6f99aE0454f8710f0a8B9);
        _addHop("Berachain", 30_362, DEFAULT_HOP, 0x954286118E93df807aB6f99aE0454f8710f0a8B9);
        _addHop("BSC", 30_102, DEFAULT_HOP, 0x954286118E93df807aB6f99aE0454f8710f0a8B9);
        _addHop("Hyperliquid", 30_367, DEFAULT_HOP, 0x954286118E93df807aB6f99aE0454f8710f0a8B9);
        _addHop("Ink", 30_339, DEFAULT_HOP, 0x954286118E93df807aB6f99aE0454f8710f0a8B9);
        _addHop("Katana", 30_375, DEFAULT_HOP, 0x954286118E93df807aB6f99aE0454f8710f0a8B9);
        _addHop("Mode", 30_260, DEFAULT_HOP, 0x954286118E93df807aB6f99aE0454f8710f0a8B9);
        _addHop("Optimism", 30_111, DEFAULT_HOP, 0x954286118E93df807aB6f99aE0454f8710f0a8B9);
        _addHop("Sei", 30_280, DEFAULT_HOP, 0x954286118E93df807aB6f99aE0454f8710f0a8B9);
        _addHop("Sonic", 30_332, DEFAULT_HOP, 0x954286118E93df807aB6f99aE0454f8710f0a8B9);
        _addHop("Unichain", 30_320, DEFAULT_HOP, 0x954286118E93df807aB6f99aE0454f8710f0a8B9);
        _addHop("Worldchain", 30_319, DEFAULT_HOP, 0x954286118E93df807aB6f99aE0454f8710f0a8B9);
        _addHop("X-Layer", 30_274, DEFAULT_HOP, 0x954286118E93df807aB6f99aE0454f8710f0a8B9);
        _addHop("Abstract", 30_324, DEFAULT_HOP, 0x000000000E0E120FCAc7b4d98e9E35E1DE6fdadb);
        _addHop("Base", 30_184, DEFAULT_HOP, 0x07dB789aD17573e5169eDEfe14df91CC305715AA);
        _addHop("Ethereum", 30_101, DEFAULT_HOP, 0x181EBC9deA868ED8e5EeeAef7f767D43BF390dFa);
        _addHop("Linea", 30_183, DEFAULT_HOP, 0xfa803b63DaACCa6CD953061BDBa4E3da6b177447);
        _addHop("Scroll", 30_214, DEFAULT_HOP, 0x1dE5910A2b0f860A226a8a43148aeA91afbE3d01);
        _addHop("ZkSync", 30_165, DEFAULT_HOP, 0x000000000E0E120FCAc7b4d98e9E35E1DE6fdadb);
        _addHop("Tempo", 30_410, DEFAULT_HOP, 0x05b4a311Aac6658C0FA1e0247Be898aae8a8581f);
    }

    function setUp() public override {}

    /// @notice The encoded call to execute on each remote hop (e.g. setExecutorOptions, setRemoteHop, etc.)
    function _remoteCall() internal virtual returns (bytes memory);

    /// @notice Human-readable label prefix for SafeTx entries (e.g. "Set Somnia executor options")
    function _txLabel() internal view virtual returns (string memory);

    /// @notice Output JSON filename (relative to project root, e.g. "src/script/hop/RemoteAdmin/txs/Foo.json")
    function _outputFilename() internal view virtual returns (string memory);

    function run() external {
        bytes memory remoteCall = _remoteCall();
        uint256 lastFee;

        for (uint256 i = 0; i < hopDatas.length; i++) {
            HopData memory hopData = hopDatas[i];
            bytes memory data = abi.encode(hopData.hop, remoteCall);
            bool skip = skipCall[hopData.eid];

            uint256 fee;
            if (!skip) {
                fee = IHopV2(FRAXTAL_HOP).quote({
                    _oft: FRXUSD_LOCKBOX,
                    _dstEid: hopData.eid,
                    _recipient: bytes32(uint256(uint160(hopData.remoteAdmin))),
                    _amountLD: 0,
                    _dstGas: COMPOSE_GAS,
                    _data: data
                });
                fee = (fee * 150) / 100;
                lastFee = fee;
            } else {
                fee = lastFee;
            }

            bytes memory localCall = abi.encodeWithSignature(
                "sendOFT(address,uint32,bytes32,uint256,uint128,bytes)",
                FRXUSD_LOCKBOX,
                hopData.eid,
                bytes32(uint256(uint160(hopData.remoteAdmin))),
                uint256(0),
                COMPOSE_GAS,
                data
            );

            if (!skip) {
                vm.prank(FRAXTAL_MSIG);
                (bool success, ) = FRAXTAL_HOP.call{ value: fee }(localCall);
                require(success, string.concat("sendOFT failed for ", hopData.name));
            }

            txs.push(
                SafeTx({
                    name: string.concat(_txLabel(), " on ", hopData.name),
                    to: FRAXTAL_HOP,
                    value: fee,
                    data: localCall
                })
            );
        }

        string memory root = vm.projectRoot();
        string memory filename = string(abi.encodePacked(root, "/", _outputFilename()));
        new SafeTxHelper().writeTxs(txs, filename);
    }

    function _addHop(string memory _name, uint32 _eid, address _hop, address _remoteAdmin) internal {
        hopDatas.push(HopData({ name: _name, eid: _eid, hop: _hop, remoteAdmin: _remoteAdmin }));
    }
}
