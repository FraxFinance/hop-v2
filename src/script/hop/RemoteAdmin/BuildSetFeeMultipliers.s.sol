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
///   - FEE_BUFFER_PCT: percent of the quoted fee to attach as msg.value
///     (default: 400 = 4x the quote).
///
///     A Safe tx sits in the queue for days before it is signed and executed,
///     and the quote tracks destination gas prices through the LZ price feeds.
///     That drift is fast: on 2026-07-31 the Fraxtal => Linea quote rose 25% in
///     twenty minutes, which alone would have eaten half of a 2x buffer.
///
///     The failure modes are wildly asymmetric, so the buffer is deliberately
///     generous. Undershooting reverts the tx with InsufficientFee and costs a
///     full re-generate / re-sign / re-queue cycle across the msig signers.
///     Overshooting costs nothing: HopV201._handleMsgValue() refunds
///     `msg.value - sendFee` to msg.sender (the Fraxtal msig) inside the same
///     transaction, so the only requirement is that the Safe holds the stated
///     value at execution time.
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
        uint256 feeBufferPct = _feeBufferPct();

        vm.createDir(outputDir, true);
        RemoteAdminRoute[] storage routes = _remoteAdminRoutes();

        console.log("=== BuildSetFeeMultipliers ===");
        console.log("input dir :", inputDir);
        console.log("output dir:", outputDir);
        console.log("fee buffer:", feeBufferPct, "% of quote");
        console.log("remote routes:", routes.length);

        // ---- Remote chains: sendOFT compose message to each RemoteAdmin ----
        // Tracks the last successful quote so blocked pathways (BlockedMessageLib)
        // can reuse it, matching the skipCall/lastFee pattern in SetExecutorOptionsBase.
        uint256 lastFee;
        uint256 totalValue;
        uint256 blockedCount;
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

            // Quote the Fraxtal-leg fee. Some pathways are configured with
            // BlockedMessageLib as the send library (Fraxtal => Scroll / Mode /
            // Berachain at the time of writing), which makes Endpoint.quote()
            // revert with LZ_NotImplemented(). Reuse the last successful fee so
            // the tx can still be queued — matches the skipCall/lastFee convention
            // in SetExecutorOptionsBase.
            uint256 fee;
            bool reused;
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
                fee = (q * feeBufferPct) / 100;
                lastFee = fee;
            } catch {
                console.log("  quote reverted for", target.name, "- reusing last fee");
                require(lastFee != 0, "no prior fee to reuse for blocked pathway");
                fee = lastFee;
                reused = true;
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
            totalValue += fee;
            console.log("Wrote:", filename, "fee=", fee);
            if (reused) {
                blockedCount++;
                console.log(
                    "  !! reused last fee - Fraxtal =>",
                    target.name,
                    "pathway is blocked, do NOT queue this file"
                );
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
        console.log("total msg.value across all files (wei):", totalValue);
        console.log("blocked pathways written with a reused fee:", blockedCount);
        console.log("The Fraxtal msig must hold at least that much FRAX; the surplus over the");
        console.log("live quote is refunded to the msig by HopV201._handleMsgValue().");
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

    /// @dev Percent (not bps) of the quote to attach as msg.value. 100 = exact quote,
    ///      200 = 2x. Bounded so a bps-shaped value (e.g. 10_000) cannot silently
    ///      overpay by 100x.
    function _feeBufferPct() internal view returns (uint256 pct) {
        pct = vm.envExists("FEE_BUFFER_PCT") ? vm.envUint("FEE_BUFFER_PCT") : 400;
        require(pct >= 100 && pct <= 1000, "FEE_BUFFER_PCT out of range (100..1000)");
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
