// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import { Script, console } from "forge-std/Script.sol";
import { SafeTxHelper, SafeTx } from "frax-std/SafeTxHelper.sol";
import { IAccessControl } from "@openzeppelin/contracts/access/IAccessControl.sol";
import { IHopV2 } from "src/contracts/interfaces/IHopV2.sol";
import { HopConstants, HopV2Target } from "src/script/hop/HopConstants.sol";

// forge script src/script/hop/RemoteAdmin/BuildRevokeCarterPauserFraxtalPerChain.s.sol --rpc-url https://rpc.frax.com --ffi
contract BuildRevokeCarterPauserFraxtalPerChain is Script, HopConstants {
    address public constant FRAXTAL_HOP = 0x00000000e18aFc20Afe54d4B2C8688bB60c06B36;
    address public constant FRXUSD_LOCKBOX = 0x96A394058E2b84A89bac9667B19661Ed003cF5D4;
    uint32 public constant FRAXTAL_EID = 30_255;
    uint128 public constant COMPOSE_GAS = 400_000;

    bytes32 public constant PAUSER_ROLE = 0x65d7a28e3265b37a6474929f336521b332c1681b933f6cb9f3376673440d862a;
    address public constant CARTER = 0x54C5Ef136D02b95C4Ff217aF93FA63F9E4119919;

    struct HopData {
        uint256 chainId;
        uint32 eid;
    }

    HopData[] public hopDatas;

    constructor() {
        _addHop(42_161, 30_110); // Arbitrum
        _addHop(1_313_161_554, 30_211); // Aurora
        _addHop(43_114, 30_106); // Avalanche
        _addHop(80_094, 30_362); // Berachain
        _addHop(56, 30_102); // BSC
        _addHop(999, 30_367); // Hyperliquid
        _addHop(57_073, 30_339); // Ink
        _addHop(747_474, 30_375); // Katana
        _addHop(34_443, 30_260); // Mode
        _addHop(10, 30_111); // Optimism
        _addHop(1329, 30_280); // Sei
        _addHop(146, 30_332); // Sonic
        _addHop(130, 30_320); // Unichain
        _addHop(480, 30_319); // Worldchain
        _addHop(196, 30_274); // X-Layer
        _addHop(2741, 30_324); // Abstract
        _addHop(8453, 30_184); // Base
        _addHop(1, 30_101); // Ethereum
        _addHop(59_144, 30_183); // Linea
        _addHop(534_352, 30_214); // Scroll
        _addHop(324, 30_165); // ZkSync
        _addHop(4217, 30_410); // Tempo
    }

    function run() external {
        bytes memory remoteCall = abi.encodeCall(IAccessControl.revokeRole, (PAUSER_ROLE, CARTER));
        string memory outputDir = "src/script/hop/RemoteAdmin/txs/RevokeCarterPauserAllChains";
        vm.createDir(outputDir, true);

        for (uint256 i = 0; i < hopDatas.length; i++) {
            HopData memory hopData = hopDatas[i];
            HopV2Target storage target = _hopV2TargetFor(hopData.chainId);
            address remoteAdmin = _remoteAdminForEid(hopData.eid);

            bytes memory composeData = abi.encode(target.hop, remoteCall);
            uint256 fee = IHopV2(FRAXTAL_HOP).quote({
                _oft: FRXUSD_LOCKBOX,
                _dstEid: hopData.eid,
                _recipient: bytes32(uint256(uint160(remoteAdmin))),
                _amountLD: 0,
                _dstGas: COMPOSE_GAS,
                _data: composeData
            });
            fee = (fee * 150) / 100;

            bytes memory localCall = abi.encodeWithSignature(
                "sendOFT(address,uint32,bytes32,uint256,uint128,bytes)",
                FRXUSD_LOCKBOX,
                hopData.eid,
                bytes32(uint256(uint160(remoteAdmin))),
                uint256(0),
                COMPOSE_GAS,
                composeData
            );

            SafeTx[] memory txs = new SafeTx[](1);
            txs[0] = SafeTx({
                name: string.concat("Revoke Carter PAUSER_ROLE on ", target.name),
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
                    vm.toString(uint256(hopData.eid)),
                    "(",
                    target.name,
                    ").json"
                )
            );

            new SafeTxHelper().writeTxs(txs, filename);
            console.log("Wrote:", filename);
        }
    }

    function _addHop(uint256 _chainId, uint32 _eid) internal {
        hopDatas.push(HopData({ chainId: _chainId, eid: _eid }));
    }
}
