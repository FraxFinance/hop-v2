// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

struct HopV2Target {
    string name;
    address hop;
    bool exists;
}

struct RemoteAdminRoute {
    uint256 chainId;
    uint32 eid;
}

contract HopConstants {
    /// @dev Compose gas forwarded to the destination for a RemoteAdmin hop. The compose path
    ///      (endpoint -> RemoteHopV2.lzCompose -> RemoteAdmin.hopCompose -> HopV2 admin call)
    ///      costs ~60k of execution on EVM-equivalent chains, so this leaves wide margin there.
    uint128 internal constant DEFAULT_COMPOSE_GAS = 400_000;

    /// @dev Chains whose gas metering makes DEFAULT_COMPOSE_GAS insufficient or too tight.
    ///      Simulated against live deployments (eth_call as the LZ endpoint, binary searched
    ///      for the minimum gas the compose survives, including tx intrinsic cost):
    ///        EVM-equivalent chains   ~88k   (Polygon ~112k, Sei ~142k, Monad ~151k)
    ///        Tempo                  ~327k   - only 18% margin under 400k
    ///        ZkSync / Abstract      ~390k   - EraVM metering, effectively no margin under 400k
    ///        Somnia               ~1_470k   - 400k would run out of gas
    mapping(uint256 chainId => uint128 composeGas) internal composeGasOverrides;

    mapping(uint256 chainId => HopV2Target target) internal hopV2Targets;
    mapping(uint32 eid => address remoteAdmin) internal remoteAdmins;
    mapping(uint256 chainId => uint32 eid) internal eidsByChainId;
    mapping(uint32 eid => uint256 chainId) internal chainIdsByEid;
    RemoteAdminRoute[] internal remoteAdminRoutes;

    constructor() {
        address defaultHop = 0x0000006D38568b00B457580b734e0076C62de659;

        _addHopV2Target(1, "Ethereum", defaultHop);
        _addHopV2Target(10, "Optimism", defaultHop);
        _addHopV2Target(56, "BSC", defaultHop);
        _addHopV2Target(130, "Unichain", defaultHop);
        _addHopV2Target(146, "Sonic", defaultHop);
        _addHopV2Target(137, "Polygon", defaultHop);
        _addHopV2Target(143, "Monad", defaultHop);
        _addHopV2Target(196, "X-Layer", defaultHop);
        _addHopV2Target(252, "Fraxtal", 0x00000000e18aFc20Afe54d4B2C8688bB60c06B36);
        _addHopV2Target(324, "ZkSync", defaultHop);
        _addHopV2Target(480, "Worldchain", defaultHop);
        _addHopV2Target(988, "Stable", defaultHop);
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
        _addRemoteAdminRoute(56, 30_102, commonRemoteAdmin); // BSC
        _addRemoteAdminRoute(43_114, 30_106, commonRemoteAdmin); // Avalanche
        _addRemoteAdminRoute(42_161, 30_110, commonRemoteAdmin); // Arbitrum
        _addRemoteAdminRoute(10, 30_111, commonRemoteAdmin); // Optimism
        _addRemoteAdminRoute(137, 30_109, commonRemoteAdmin); // Polygon
        _addRemoteAdminRoute(143, 30_390, 0x4bE0942c2CbFd741DB5906CF2831c1AF29fcEa55); // Monad
        _addRemoteAdminRoute(59_144, 30_183, 0xfa803b63DaACCa6CD953061BDBa4E3da6b177447); // Linea
        _addRemoteAdminRoute(8453, 30_184, 0x07dB789aD17573e5169eDEfe14df91CC305715AA); // Base
        _addRemoteAdminRoute(1_313_161_554, 30_211, commonRemoteAdmin); // Aurora
        _addRemoteAdminRoute(534_352, 30_214, 0x1dE5910A2b0f860A226a8a43148aeA91afbE3d01); // Scroll
        _addRemoteAdminRoute(34_443, 30_260, commonRemoteAdmin); // Mode
        _addRemoteAdminRoute(196, 30_274, commonRemoteAdmin); // X-Layer
        _addRemoteAdminRoute(1329, 30_280, commonRemoteAdmin); // Sei
        _addRemoteAdminRoute(480, 30_319, commonRemoteAdmin); // Worldchain
        _addRemoteAdminRoute(130, 30_320, commonRemoteAdmin); // Unichain
        _addRemoteAdminRoute(2741, 30_324, 0x000000000E0E120FCAc7b4d98e9E35E1DE6fdadb); // Abstract
        _addRemoteAdminRoute(146, 30_332, commonRemoteAdmin); // Sonic
        _addRemoteAdminRoute(57_073, 30_339, commonRemoteAdmin); // Ink
        _addRemoteAdminRoute(80_094, 30_362, commonRemoteAdmin); // Berachain
        _addRemoteAdminRoute(98_866, 30_370, commonRemoteAdmin); // Plume
        _addRemoteAdminRoute(999, 30_367, commonRemoteAdmin); // Hyperliquid
        _addRemoteAdminRoute(747_474, 30_375, commonRemoteAdmin); // Katana
        _addRemoteAdminRoute(988, 30_396, commonRemoteAdmin); // Stable
        _addRemoteAdminRoute(1, 30_101, 0x181EBC9deA868ED8e5EeeAef7f767D43BF390dFa); // Ethereum
        _addRemoteAdminRoute(324, 30_165, 0x000000000E0E120FCAc7b4d98e9E35E1DE6fdadb); // ZkSync
        _addRemoteAdminRoute(4217, 30_410, 0x05b4a311Aac6658C0FA1e0247Be898aae8a8581f); // Tempo
        _addRemoteAdminRoute(5031, 30_380, 0xbfCb6F2f811a0DA4D54386458bF888B769EbFc5F); // Somnia

        composeGasOverrides[324] = 1_500_000; // ZkSync
        composeGasOverrides[2741] = 1_500_000; // Abstract
        composeGasOverrides[4217] = 2_500_000; // Tempo
        composeGasOverrides[5031] = 3_000_000; // Somnia
    }

    /// @notice Compose gas to forward to `chainId` for a RemoteAdmin hop
    function _composeGasFor(uint256 chainId) internal view returns (uint128 composeGas) {
        composeGas = composeGasOverrides[chainId];
        if (composeGas == 0) composeGas = DEFAULT_COMPOSE_GAS;
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

    function _remoteAdminRoutes() internal view returns (RemoteAdminRoute[] storage routes) {
        routes = remoteAdminRoutes;
    }

    function _eidForChainId(uint256 chainId) internal view returns (uint32 eid) {
        eid = eidsByChainId[chainId];
        require(eid != 0, "missing eid for chainId");
    }

    function _chainIdForEid(uint32 eid) internal view returns (uint256 chainId) {
        chainId = chainIdsByEid[eid];
        require(chainId != 0, "missing chainId for eid");
    }

    function _addRemoteAdmin(uint32 eid, address remoteAdmin) internal {
        remoteAdmins[eid] = remoteAdmin;
    }

    function _addRemoteAdminRoute(uint256 chainId, uint32 eid, address remoteAdmin) internal {
        require(hopV2Targets[chainId].exists, "missing HopV2 target for remote admin route");
        require(chainIdsByEid[eid] == 0, "eid route already exists");
        require(eidsByChainId[chainId] == 0, "chainId route already exists");
        _addRemoteAdmin(eid, remoteAdmin);
        chainIdsByEid[eid] = chainId;
        eidsByChainId[chainId] = eid;
        remoteAdminRoutes.push(RemoteAdminRoute({ chainId: chainId, eid: eid }));
    }
}
