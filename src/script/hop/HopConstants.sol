// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

struct HopV2Target {
    string name;
    address hop;
    bool exists;
}

contract HopConstants {
    mapping(uint256 chainId => HopV2Target target) internal hopV2Targets;
    mapping(uint32 eid => address remoteAdmin) internal remoteAdmins;

    constructor() {
        address defaultHop = 0x0000006D38568b00B457580b734e0076C62de659;

        _addHopV2Target(1, "Ethereum", defaultHop);
        _addHopV2Target(10, "Optimism", defaultHop);
        _addHopV2Target(56, "BSC", defaultHop);
        _addHopV2Target(130, "Unichain", defaultHop);
        _addHopV2Target(146, "Sonic", defaultHop);
        _addHopV2Target(137, "Polygon", defaultHop);
        _addHopV2Target(196, "X-Layer", defaultHop);
        _addHopV2Target(252, "Fraxtal", 0x00000000e18aFc20Afe54d4B2C8688bB60c06B36);
        _addHopV2Target(324, "ZkSync", defaultHop);
        _addHopV2Target(480, "Worldchain", defaultHop);
        _addHopV2Target(999, "Hyperliquid", defaultHop);
        _addHopV2Target(1329, "Sei", defaultHop);
        _addHopV2Target(2741, "Abstract", defaultHop);
        _addHopV2Target(4217, "Tempo", defaultHop);
        _addHopV2Target(5031, "Somnia", defaultHop);
        _addHopV2Target(8453, "Base", defaultHop);
        _addHopV2Target(98_866, "Plume", defaultHop);
        _addHopV2Target(34_443, "Mode", defaultHop);
        _addHopV2Target(42_161, "Arbitrum", defaultHop);
        _addHopV2Target(43_114, "Avalanche", defaultHop);
        _addHopV2Target(57_073, "Ink", defaultHop);
        _addHopV2Target(59_144, "Linea", defaultHop);
        _addHopV2Target(747_474, "Katana", defaultHop);
        _addHopV2Target(80_094, "Berachain", defaultHop);
        _addHopV2Target(534_352, "Scroll", defaultHop);
        _addHopV2Target(1_313_161_554, "Aurora", defaultHop);

        address commonRemoteAdmin = 0x954286118E93df807aB6f99aE0454f8710f0a8B9;
        _addRemoteAdmin(30_102, commonRemoteAdmin); // BSC
        _addRemoteAdmin(30_106, commonRemoteAdmin); // Avalanche
        _addRemoteAdmin(30_110, commonRemoteAdmin); // Arbitrum
        _addRemoteAdmin(30_111, commonRemoteAdmin); // Optimism
        _addRemoteAdmin(30_183, 0xfa803b63DaACCa6CD953061BDBa4E3da6b177447); // Linea
        _addRemoteAdmin(30_184, 0x07dB789aD17573e5169eDEfe14df91CC305715AA); // Base
        _addRemoteAdmin(30_211, commonRemoteAdmin); // Aurora
        _addRemoteAdmin(30_214, 0x1dE5910A2b0f860A226a8a43148aeA91afbE3d01); // Scroll
        _addRemoteAdmin(30_260, commonRemoteAdmin); // Mode
        _addRemoteAdmin(30_274, commonRemoteAdmin); // X-Layer
        _addRemoteAdmin(30_280, commonRemoteAdmin); // Sei
        _addRemoteAdmin(30_319, commonRemoteAdmin); // Worldchain
        _addRemoteAdmin(30_320, commonRemoteAdmin); // Unichain
        _addRemoteAdmin(30_324, 0x000000000E0E120FCAc7b4d98e9E35E1DE6fdadb); // Abstract
        _addRemoteAdmin(30_332, commonRemoteAdmin); // Sonic
        _addRemoteAdmin(30_339, commonRemoteAdmin); // Ink
        _addRemoteAdmin(30_362, commonRemoteAdmin); // Berachain
        _addRemoteAdmin(30_367, commonRemoteAdmin); // Hyperliquid
        _addRemoteAdmin(30_375, commonRemoteAdmin); // Katana
        _addRemoteAdmin(30_101, 0x181EBC9deA868ED8e5EeeAef7f767D43BF390dFa); // Ethereum
        _addRemoteAdmin(30_165, 0x000000000E0E120FCAc7b4d98e9E35E1DE6fdadb); // ZkSync
        _addRemoteAdmin(30_410, 0x05b4a311Aac6658C0FA1e0247Be898aae8a8581f); // Tempo
    }

    function _hopV2TargetFor(uint256 chainId) internal view returns (HopV2Target storage target) {
        target = hopV2Targets[chainId];
        require(target.exists, "missing HopV2 target");
    }

    function _addHopV2Target(uint256 chainId, string memory name, address hop) internal {
        hopV2Targets[chainId] = HopV2Target({ name: name, hop: hop, exists: true });
    }

    function _remoteAdminForEid(uint32 eid) internal view returns (address remoteAdmin) {
        remoteAdmin = remoteAdmins[eid];
        require(remoteAdmin != address(0), "missing remote admin");
    }

    function _addRemoteAdmin(uint32 eid, address remoteAdmin) internal {
        remoteAdmins[eid] = remoteAdmin;
    }
}
