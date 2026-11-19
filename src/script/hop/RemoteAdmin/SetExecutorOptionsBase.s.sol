// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import { Script, console } from "forge-std/Script.sol";
import { SafeTxHelper, SafeTx } from "frax-std/SafeTxHelper.sol";
import { IHopV2 } from "src/contracts/interfaces/IHopV2.sol";
import { HopConstants, HopV2Target, RemoteAdminRoute } from "src/script/hop/HopConstants.sol";

/// @notice Base contract for broadcasting a single admin call to all remote HopV2 instances via Fraxtal Hop.
/// Child contracts only need to implement `_remoteCall()`, `_txLabel()`, `_outputDir()` and `_sourceEid()`.
///
/// Builds one Fraxtal msig batch per RemoteAdmin route in HopConstants, skipping the chain whose
/// executor options are being set (a chain never hops to itself). Each batch is simulated as the
/// msig against the Fraxtal fork before it is written.
///
/// Optional env vars:
/// - CHAIN_IDS: comma-separated chain ids to build for (default: every RemoteAdmin route)
/// - FEE_BUFFER_BPS: multiplier on the live LZ quote, in bps (default 40000 = 4x)
/// - FEE_MIN_HEADROOM: absolute FRAX (wei) added on top of the quote at minimum (default 5e18)
///
/// Inherits SafeTxHelper instead of deploying it: under forge 1.8.x on a Fraxtal fork a plain
/// CREATE from the script reverts.
abstract contract SetExecutorOptionsBase is Script, HopConstants, SafeTxHelper {
    address public constant FRAXTAL_HOP = 0x00000000e18aFc20Afe54d4B2C8688bB60c06B36;
    address public constant FRAXTAL_MSIG = 0x5f25218ed9474b721d6a38c115107428E832fA2E;
    address public constant FRXUSD_LOCKBOX = 0x96A394058E2b84A89bac9667B19661Ed003cF5D4;

    /// @notice The encoded call to execute on each remote hop (e.g. setExecutorOptions, setRemoteHop, etc.)
    function _remoteCall() internal virtual returns (bytes memory);

    /// @notice Human-readable label prefix for SafeTx entries (e.g. "Set Somnia executor options")
    function _txLabel() internal view virtual returns (string memory);

    /// @notice Output directory (relative to project root, e.g. "src/script/hop/RemoteAdmin/txs/SetFooOptions")
    function _outputDir() internal view virtual returns (string memory);

    /// @notice The EID whose executor options are set, also used in the filename (e.g. 30380 for Somnia)
    function _sourceEid() internal view virtual returns (uint32);

    function run() external {
        bytes memory remoteCall = _remoteCall();
        uint256[] memory chainIds = vm.envOr("CHAIN_IDS", ",", new uint256[](0));
        vm.createDir(_outputDir(), true);

        RemoteAdminRoute[] storage routes = _remoteAdminRoutes();
        uint256 written;
        uint256 maxFee;
        for (uint256 i = 0; i < routes.length; i++) {
            RemoteAdminRoute memory route = routes[i];
            if (route.eid == _sourceEid() || !_isSelected(route.chainId, chainIds)) continue;

            uint256 fee = _processRoute(route, remoteCall);
            if (fee > maxFee) maxFee = fee;
            written++;
        }

        require(written != 0, "no batches written");
        console.log("Batches written:", written);
        // HopV2._handleMsgValue refunds the unspent buffer to the msig inside each tx, so the
        // msig only needs the largest single value on hand, not the total.
        console.log("Largest single batch value (wei):", maxFee);
    }

    function _processRoute(RemoteAdminRoute memory route, bytes memory remoteCall) internal returns (uint256 fee) {
        HopV2Target storage target = _hopV2TargetFor(route.chainId);
        address remoteAdmin = _remoteAdminForEid(route.eid);
        bytes memory composeData = abi.encode(target.hop, remoteCall);

        // Gas the destination compose runs with. Chains with non-EVM gas metering need more
        // than the 400k default - see composeGasOverrides in HopConstants.
        uint128 composeGas = _composeGasFor(route.chainId);

        uint256 quoted = IHopV2(FRAXTAL_HOP).quote({
            _oft: FRXUSD_LOCKBOX,
            _dstEid: route.eid,
            _recipient: bytes32(uint256(uint160(remoteAdmin))),
            _amountLD: 0,
            _dstGas: composeGas,
            _data: composeData
        });
        fee = _bufferedFee(quoted);

        bytes memory localCall = abi.encodeWithSignature(
            "sendOFT(address,uint32,bytes32,uint256,uint128,bytes)",
            FRXUSD_LOCKBOX,
            route.eid,
            bytes32(uint256(uint160(remoteAdmin))),
            uint256(0),
            composeGas,
            composeData
        );

        vm.prank(FRAXTAL_MSIG);
        (bool success, ) = FRAXTAL_HOP.call{ value: fee }(localCall);
        require(success, string.concat("sendOFT failed for ", target.name));

        SafeTx[] memory txs = new SafeTx[](1);
        txs[0] = SafeTx({
            name: string.concat(_txLabel(), " on ", target.name),
            to: FRAXTAL_HOP,
            value: fee,
            data: localCall
        });

        string memory filename = string(
            abi.encodePacked(
                _outputDir(),
                "/",
                vm.toString(uint256(_sourceEid())),
                "-",
                vm.toString(uint256(route.eid)),
                "(",
                target.name,
                ")",
                ".json"
            )
        );
        writeTxs(txs, filename);
        console.log("Wrote:", filename);
        console.log("  composeGas:", composeGas);
        console.log("  fee (wei):", fee);
    }

    function _isSelected(uint256 chainId, uint256[] memory chainIds) internal pure returns (bool) {
        if (chainIds.length == 0) return true;
        for (uint256 i = 0; i < chainIds.length; i++) {
            if (chainIds[i] == chainId) return true;
        }
        return false;
    }

    /// @dev Same policy as BuildGrantRecoverEthRoleFraxtalPerChain: a batch that sits in the msig
    ///      queue while the quote rises reverts with `InsufficientFee()`, while overpaying is nearly
    ///      free because `HopV2._handleMsgValue` refunds the excess to the msig.
    function _bufferedFee(uint256 quoted) internal view returns (uint256 fee) {
        uint256 bufferBps = vm.envOr("FEE_BUFFER_BPS", uint256(40_000));
        require(bufferBps >= 10_000, "FEE_BUFFER_BPS must be at least 10000 (1x)");
        uint256 minHeadroom = vm.envOr("FEE_MIN_HEADROOM", uint256(5e18));

        uint256 scaledFee = (quoted * bufferBps) / 10_000;
        fee = scaledFee > quoted + minHeadroom ? scaledFee : quoted + minHeadroom;
    }
}
