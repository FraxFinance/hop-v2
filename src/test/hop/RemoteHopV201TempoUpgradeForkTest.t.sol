// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

import { Test } from "forge-std/Test.sol";
import { ProxyAdmin } from "@openzeppelin/contracts/proxy/transparent/ProxyAdmin.sol";
import { ITransparentUpgradeableProxy } from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import { ERC1967Utils } from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Utils.sol";

import { RemoteHopV201Tempo } from "src/contracts/hop/RemoteHopV201Tempo.sol";

/// @notice Rehearses the fee-inclusive implementation upgrade against the live Tempo proxy state.
contract RemoteHopV201TempoUpgradeForkTest is Test {
    uint256 internal constant TEMPO_FORK_BLOCK = 36_468_369;

    uint32 internal constant FRAXTAL_EID = 30_255;
    uint32 internal constant ETHEREUM_EID = 30_101;
    uint32 internal constant ARBITRUM_EID = 30_110;

    address internal constant TEMPO_ENDPOINT = 0x20Bb7C2E2f4e5ca2B4c57060d1aE2615245dCc9C;
    address internal constant REMOTE_HOP = 0x0000006D38568b00B457580b734e0076C62de659;

    address internal constant FRXUSD_OFT = 0x00000000D61733e7A393A10A5B48c311AbE8f1E5;
    address internal constant SFRXUSD_OFT = 0x00000000fD8C4B8A413A06821456801295921a71;
    address internal constant FRXETH_OFT = 0x000000008c3930dCA540bB9B3A5D0ee78FcA9A4c;
    address internal constant SFRXETH_OFT = 0x00000000883279097A49dB1f2af954EAd0C77E3c;
    address internal constant WFRAX_OFT = 0x00000000E9CE0f293D1Ce552768b187eBA8a56D4;
    address internal constant FPI_OFT = 0x00000000bC4aEF4bA6363a437455Cb1af19e2aEb;

    RemoteHopV201Tempo internal hop;

    function setUp() public {
        vm.createSelectFork(_tempoRpcUrl(), TEMPO_FORK_BLOCK);
        hop = RemoteHopV201Tempo(payable(REMOTE_HOP));
    }

    function testFork_UpgradePreservesLiveStateAndExposesFeeInclusiveQuote() public {
        bytes32 configurationBefore = _configurationHash();
        address adminBefore = _slotAddress(vm.load(REMOTE_HOP, ERC1967Utils.ADMIN_SLOT));
        address implementationBefore = _slotAddress(vm.load(REMOTE_HOP, ERC1967Utils.IMPLEMENTATION_SLOT));

        address implementationAfter = address(new RemoteHopV201Tempo(TEMPO_ENDPOINT));
        address proxyAdminOwner = ProxyAdmin(adminBefore).owner();

        vm.prank(proxyAdminOwner);
        ProxyAdmin(adminBefore).upgradeAndCall(ITransparentUpgradeableProxy(REMOTE_HOP), implementationAfter, "");

        assertEq(_slotAddress(vm.load(REMOTE_HOP, ERC1967Utils.ADMIN_SLOT)), adminBefore, "proxy admin changed");
        assertEq(
            _slotAddress(vm.load(REMOTE_HOP, ERC1967Utils.IMPLEMENTATION_SLOT)),
            implementationAfter,
            "implementation was not upgraded"
        );
        assertNotEq(implementationAfter, implementationBefore, "test must install a new implementation");
        assertEq(_configurationHash(), configurationBefore, "live proxy configuration changed across upgrade");

        (
            uint256 amountToBridgeLD,
            address feeToken,
            address paymentToken,
            uint256 feeAmountLD,
            uint256 totalAmountInLD
        ) = hop.quoteFeeInclusive(
                FRXUSD_OFT,
                hop.localEid(),
                bytes32(uint256(uint160(makeAddr("recipient")))),
                1e6,
                0,
                ""
            );

        assertGt(amountToBridgeLD, 0, "local quote removed the full amount as dust");
        assertEq(paymentToken, feeToken, "local quote should not swap the source token");
        assertEq(feeAmountLD, 0, "local quote should not charge a LayerZero fee");
        assertEq(totalAmountInLD, amountToBridgeLD, "local quote total should equal its bridge amount");
    }

    function _configurationHash() internal view returns (bytes32 digest) {
        digest = keccak256(
            abi.encode(
                hop.localEid(),
                hop.endpoint(),
                address(hop.nativeToken()),
                hop.paused(),
                hop.remoteHop(FRAXTAL_EID),
                hop.numDVNs(),
                hop.hopFee(),
                hop.EXECUTOR(),
                hop.DVN(),
                hop.TREASURY()
            )
        );
        digest = keccak256(
            abi.encode(
                digest,
                hop.feeMultipliers(ETHEREUM_EID),
                hop.feeMultipliers(ARBITRUM_EID),
                hop.executorOptions(ETHEREUM_EID),
                hop.executorOptions(ARBITRUM_EID),
                hop.getRoleMembers(hop.DEFAULT_ADMIN_ROLE()),
                hop.getRoleMembers(hop.PAUSER_ROLE())
            )
        );

        address[6] memory ofts = [FRXUSD_OFT, SFRXUSD_OFT, FRXETH_OFT, SFRXETH_OFT, WFRAX_OFT, FPI_OFT];
        for (uint256 i = 0; i < ofts.length; i++) {
            digest = keccak256(abi.encode(digest, ofts[i], hop.approvedOft(ofts[i])));
        }
    }

    function _slotAddress(bytes32 value) internal pure returns (address) {
        return address(uint160(uint256(value)));
    }

    function _tempoRpcUrl() internal view returns (string memory rpcUrl) {
        rpcUrl = vm.envOr("TEMPO_RPC_URL", string(""));
        if (bytes(rpcUrl).length == 0) rpcUrl = vm.envOr("TEMPO_MAINNET_URL", string(""));
        if (bytes(rpcUrl).length == 0) rpcUrl = vm.envOr("RPC_URL", string(""));
        require(bytes(rpcUrl).length != 0, "Tempo RPC URL not found");
    }
}
