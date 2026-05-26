// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

struct HopV2Target {
    string name;
    address hop;
    bool exists;
}

contract HopConstants {
    mapping(uint256 chainId => HopV2Target target) internal hopV2Targets;

    constructor() {
        address defaultHop = 0x0000006D38568b00B457580b734e0076C62de659;

        _addHopV2Target(1, "Ethereum", defaultHop);
        _addHopV2Target(10, "Optimism", defaultHop);
        _addHopV2Target(56, "BSC", defaultHop);
        _addHopV2Target(130, "Unichain", defaultHop);
        _addHopV2Target(146, "Sonic", defaultHop);
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
        _addHopV2Target(34_443, "Mode", defaultHop);
        _addHopV2Target(42_161, "Arbitrum", defaultHop);
        _addHopV2Target(43_114, "Avalanche", defaultHop);
        _addHopV2Target(57_073, "Ink", defaultHop);
        _addHopV2Target(59_144, "Linea", defaultHop);
        _addHopV2Target(747_474, "Katana", defaultHop);
        _addHopV2Target(80_094, "Berachain", defaultHop);
        _addHopV2Target(534_352, "Scroll", defaultHop);
        _addHopV2Target(1_313_161_554, "Aurora", defaultHop);
    }

    function _hopV2TargetFor(uint256 chainId) internal view returns (HopV2Target storage target) {
        target = hopV2Targets[chainId];
        require(target.exists, "missing HopV2 target");
    }

    function _addHopV2Target(uint256 chainId, string memory name, address hop) internal {
        hopV2Targets[chainId] = HopV2Target({ name: name, hop: hop, exists: true });
    }
}
