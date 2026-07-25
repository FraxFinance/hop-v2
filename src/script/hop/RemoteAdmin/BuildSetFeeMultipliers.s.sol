// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import { Script, console } from "forge-std/Script.sol";
import { Vm } from "forge-std/Vm.sol";
import { SafeTxHelper, SafeTx } from "frax-std/SafeTxHelper.sol";
import { IHopV2 } from "src/contracts/interfaces/IHopV2.sol";
import { HopConstants, HopV2Target, RemoteAdminRoute } from "src/script/hop/HopConstants.sol";

/// @notice Builds per-chain Safe multisig transactions that set the executor fee
///         multipliers on every RemoteHopV2 (and FraxtalHopV2) via the Fraxtal Hop
///         message-passing / RemoteAdmin pattern.
///
/// For each remote chain, the script:
///   1. Reads the per-chain JSON produced by `pnpm run generate:fee-multipliers`
///      (default: `out/feeMultipliers/<Chain>.json`) which contains the
///      `setFeeMultipliersBatchCalldata` for that chain's RemoteHop.
///   2. Wraps that calldata in a `sendOFT(...)` compose message addressed to the
///      chain's RemoteAdmin, quoting the Fraxtal-leg fee from FraxtalHopV2.
///   3. Writes a single-tx Safe JSON (one per remote chain) ready to be signed
///      and executed by the Fraxtal multisig (`FRAXTAL_MSIG`).
///
/// FraxtalHopV2 itself is handled separately with a direct `setFeeMultipliersBatch`
/// call (no message passing needed) read from `out/feeMultipliers/Fraxtal.json` if
/// present. Note: the generator script does not produce a Fraxtal.json because
/// Fraxtal is the source/quote chain, not a destination — FraxtalHopV2's own
/// multipliers are for inbound routes and are not generated here. If a Fraxtal.json
/// is supplied via INPUT_DIR, a direct-call Safe tx is emitted for it too.
///
/// Required env vars:
///   - none (uses defaults)
/// Optional env vars:
///   - INPUT_DIR: directory containing <Chain>.json files (default: out/feeMultipliers)
///   - OUTPUT_DIR: directory for per-chain Safe JSONs
///     (default: src/script/hop/RemoteAdmin/txs/SetFeeMultipliers)
///   - FEE_BUFFER_BPS: extra safety margin applied on top of the quoted fee
///     (default: 150 = +50%, matching the existing RemoteAdmin scripts)
///
/// Usage:
///   forge script src/script/hop/RemoteAdmin/BuildSetFeeMultipliers.s.sol \
///     --rpc-url https://rpc.frax.com --ffi
///
///   INPUT_DIR=out/feeMultipliers \
///   OUTPUT_DIR=src/script/hop/RemoteAdmin/txs/SetFeeMultipliers \
///   forge script src/script/hop/RemoteAdmin/BuildSetFeeMultipliers.s.sol \
///     --rpc-url https://rpc.frax.com --ffi
contract BuildSetFeeMultipliers is Script, HopConstants {
    address public constant FRAXTAL_HOP = 0x00000000e18aFc20Afe54d4B2C8688bB60c06B36;
    address public constant FRAXTAL_MSIG = 0x5f25218ed9474b721d6a38c115107428E832fA2E;
    address public constant FRXUSD_LOCKBOX = 0x96A394058E2b84A89bac9667B19661Ed003cF5D4;
    uint32 public constant FRAXTAL_EID = 30_255;
    uint128 public constant COMPOSE_GAS = 400_000;

    function run() external {
        string memory inputDir = _inputDir();
        string memory outputDir = _outputDir();
        uint256 feeBufferBps = _feeBufferBps();

        vm.createDir(outputDir, true);
        RemoteAdminRoute[] storage routes = _remoteAdminRoutes();

        console.log("=== BuildSetFeeMultipliers ===");
        console.log("input dir :", inputDir);
        console.log("output dir:", outputDir);
        console.log("fee buffer:", feeBufferBps, "bps");
        console.log("remote routes:", routes.length);

        // ---- Remote chains: sendOFT compose message to each RemoteAdmin ----
        for (uint256 i = 0; i < routes.length; i++) {
            RemoteAdminRoute memory route = routes[i];
            HopV2Target storage target = _hopV2TargetFor(route.chainId);
            address remoteAdmin = _remoteAdminForEid(route.eid);

            // Read the per-chain calldata JSON produced by generateFeeMultipliers.ts.
            // The TS script's chain names differ from HopConstants for a few chains,
            // so map the canonical HopConstants name to the TS filename stem.
            string memory tsName = _tsName(target.name);
            string memory jsonPath = string.concat(inputDir, "/", tsName, ".json");
            if (!_fileExists(jsonPath)) {
                console.log("SKIP", target.name);
                console.log("  (no input JSON at", jsonPath, ")");
                continue;
            }

            string memory json = vm.readFile(jsonPath);
            bytes memory batchCalldata = vm.parseJsonBytes(json, ".setFeeMultipliersBatchCalldata");

            // compose data = abi.encode(remoteHop, setFeeMultipliersBatch calldata)
            bytes memory composeData = abi.encode(target.hop, batchCalldata);

            // Quote the Fraxtal-leg fee. Some pathways revert (e.g. BlockedMessageLib
            // or unsupported eid) — skip those chains but still emit the tx so it can
            // be submitted later once the pathway is configured (matches the
            // skipCall pattern in SetExecutorOptionsBase).
            uint256 fee;
            bool quoted;
            try
                IHopV2(FRAXTAL_HOP).quote({
                    _oft: FRXUSD_LOCKBOX,
                    _dstEid: route.eid,
                    _recipient: bytes32(uint256(uint160(remoteAdmin))),
                    _amountLD: 0,
                    _dstGas: COMPOSE_GAS,
                    _data: composeData
                })
            returns (uint256 q) {
                fee = (q * feeBufferBps) / 100;
                quoted = true;
            } catch {
                console.log("  quote reverted for", target.name, "- emitting tx with fee=0 (submit later)");
            }

            bytes memory localCall = abi.encodeWithSignature(
                "sendOFT(address,uint32,bytes32,uint256,uint128,bytes)",
                FRXUSD_LOCKBOX,
                route.eid,
                bytes32(uint256(uint160(remoteAdmin))),
                uint256(0),
                COMPOSE_GAS,
                composeData
            );

            SafeTx[] memory txs = new SafeTx[](1);
            txs[0] = SafeTx({
                name: string.concat("Set fee multipliers on ", target.name),
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
                    vm.toString(uint256(route.eid)),
                    "(",
                    target.name,
                    ").json"
                )
            );

            new SafeTxHelper().writeTxs(txs, filename);
            if (quoted) {
                console.log("Wrote:", filename, "fee=", fee);
            } else {
                console.log("Wrote:", filename, "fee=0 (quote reverted - submit later)");
            }
        }

        // ---- FraxtalHopV2 itself: direct call (no message passing) ----
        string memory fraxtalJsonPath = string.concat(inputDir, "/Fraxtal.json");
        if (_fileExists(fraxtalJsonPath)) {
            string memory fjson = vm.readFile(fraxtalJsonPath);
            bytes memory fraxtalCalldata = vm.parseJsonBytes(fjson, ".setFeeMultipliersBatchCalldata");

            SafeTx[] memory txs = new SafeTx[](1);
            txs[0] = SafeTx({
                name: "Set fee multipliers on Fraxtal (direct)",
                to: FRAXTAL_HOP,
                value: 0,
                data: fraxtalCalldata
            });

            string memory filename = string.concat(outputDir, "/30255-Fraxtal(direct).json");
            new SafeTxHelper().writeTxs(txs, filename);
            console.log("Wrote:", filename, "(direct call, no message passing)");
        } else {
            console.log("NOTE: no Fraxtal.json found - FraxtalHopV2 direct call skipped");
            console.log("      (generateFeeMultipliers.ts does not emit one by default;");
            console.log("       Fraxtal is the quote source, not a destination)");
        }

        console.log("=== done ===");
    }

    // -----------------------------------------------------------------------
    // Env helpers
    // -----------------------------------------------------------------------

    function _inputDir() internal view returns (string memory dir) {
        dir = vm.envExists("INPUT_DIR") ? vm.envString("INPUT_DIR") : "out/feeMultipliers";
    }

    function _outputDir() internal view returns (string memory dir) {
        dir = vm.envExists("OUTPUT_DIR")
            ? vm.envString("OUTPUT_DIR")
            : "src/script/hop/RemoteAdmin/txs/SetFeeMultipliers";
    }

    function _feeBufferBps() internal view returns (uint256 bps) {
        bps = vm.envExists("FEE_BUFFER_BPS") ? vm.envUint("FEE_BUFFER_BPS") : 150;
    }

    /// @dev Maps HopConstants chain names to the filename stems used by
    ///      generateFeeMultipliers.ts (which differ for a few chains).
    function _tsName(string memory hopName) internal pure returns (string memory ts) {
        if (keccak256(bytes(hopName)) == keccak256(bytes("Hyperliquid"))) return "HyperEVM";
        if (keccak256(bytes(hopName)) == keccak256(bytes("X-Layer"))) return "XLayer";
        return hopName;
    }

    /// @dev Returns true if `path` exists. Uses `vm.tryFfi` on `test -f` to avoid
    ///      reverting on a missing file (vm.readFile reverts if the file is absent).
    function _fileExists(string memory path) internal returns (bool exists) {
        string[] memory cmds = new string[](3);
        cmds[0] = "test";
        cmds[1] = "-f";
        cmds[2] = path;
        Vm.FfiResult memory res = vm.tryFfi(cmds);
        exists = res.exitCode == 0;
    }
}
