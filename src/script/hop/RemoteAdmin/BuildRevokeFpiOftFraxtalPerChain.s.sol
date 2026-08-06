// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import { Script, console } from "forge-std/Script.sol";
import { SafeTxHelper, SafeTx } from "frax-std/SafeTxHelper.sol";
import { IHopV2 } from "src/contracts/interfaces/IHopV2.sol";
import { HopConstants, HopV2Target, RemoteAdminRoute } from "src/script/hop/HopConstants.sol";

// Builds one Fraxtal msig batch per remote chain that hops a `setApprovedOft(fpiOft, false)`
// call to that chain's RemoteHopV2 via its RemoteAdmin.
//
// Each output file is a standalone Safe batch executed on Fraxtal (chainId 252) against the
// Fraxtal hub hop. The compose payload lands on the remote RemoteAdmin, which forwards the
// call to the remote hop. RemoteAdmin only accepts composes whose original sender is the
// Fraxtal msig, so these must be executed by 0x5f25218ed9474b721d6a38c115107428E832fA2E.
//
// Optional env vars:
// - OUTPUT_DIR: output directory for per-chain JSON files
// - INCLUDE_FRAXTAL: "true" to also emit the Fraxtal-local direct revoke (default false)
//
// OUTPUT_DIR=src/script/hop/RemoteAdmin/txs/RevokeFpiOftAllChains forge script src/script/hop/RemoteAdmin/BuildRevokeFpiOftFraxtalPerChain.s.sol --rpc-url https://rpc.frax.com --ffi
contract BuildRevokeFpiOftFraxtalPerChain is Script, HopConstants {
    address public constant FRAXTAL_HOP = 0x00000000e18aFc20Afe54d4B2C8688bB60c06B36;
    address public constant FRXUSD_LOCKBOX = 0x96A394058E2b84A89bac9667B19661Ed003cF5D4;
    address public constant FPI_LOCKBOX = 0x75c38D46001b0F8108c4136216bd2694982C20FC;
    uint32 public constant FRAXTAL_EID = 30_255;

    /// @dev FPI OFT per chainId. Unlike the other Frax OFTs these are not all deterministic,
    ///      so each is pinned explicitly. Every entry was verified onchain via
    ///      `HopV2.approvedOft(fpiOft) == true` on that chain's hop.
    mapping(uint256 chainId => address fpiOft) internal fpiOfts;

    constructor() {
        address deterministicFpiOft = 0x90581eCa9469D8D7F5D3B60f4715027aDFCf7927;

        fpiOfts[1] = 0x9033BAD7aA130a2466060A2dA71fAe2219781B4b; // Ethereum
        fpiOfts[10] = deterministicFpiOft; // Optimism
        fpiOfts[56] = deterministicFpiOft; // BSC
        fpiOfts[130] = deterministicFpiOft; // Unichain
        fpiOfts[137] = deterministicFpiOft; // Polygon
        fpiOfts[143] = 0xBa554F7A47f0792b9fa41A1256d4cf628Bb1D028; // Monad
        fpiOfts[146] = deterministicFpiOft; // Sonic
        fpiOfts[196] = deterministicFpiOft; // X-Layer
        fpiOfts[324] = 0x580F2ee1476eDF4B1760bd68f6AaBaD57dec420E; // ZkSync
        fpiOfts[480] = deterministicFpiOft; // Worldchain
        fpiOfts[988] = deterministicFpiOft; // Stable
        fpiOfts[999] = deterministicFpiOft; // Hyperliquid
        fpiOfts[1329] = deterministicFpiOft; // Sei
        fpiOfts[2741] = 0x580F2ee1476eDF4B1760bd68f6AaBaD57dec420E; // Abstract
        fpiOfts[4217] = 0x00000000bC4aEF4bA6363a437455Cb1af19e2aEb; // Tempo
        fpiOfts[5031] = 0x00000000bC4aEF4bA6363a437455Cb1af19e2aEb; // Somnia
        fpiOfts[8453] = 0xEEdd3A0DDDF977462A97C1F0eBb89C3fbe8D084B; // Base
        fpiOfts[34_443] = deterministicFpiOft; // Mode
        fpiOfts[42_161] = deterministicFpiOft; // Arbitrum
        fpiOfts[43_114] = deterministicFpiOft; // Avalanche
        fpiOfts[57_073] = deterministicFpiOft; // Ink
        fpiOfts[59_144] = 0xDaF72Aa849d3C4FAA8A9c8c99f240Cf33dA02fc4; // Linea
        fpiOfts[80_094] = deterministicFpiOft; // Berachain
        fpiOfts[98_866] = deterministicFpiOft; // Plume
        fpiOfts[534_352] = 0x93cDc5d29293Cb6983f059Fec6e4FFEb656b6a62; // Scroll
        fpiOfts[747_474] = deterministicFpiOft; // Katana
        fpiOfts[1_313_161_554] = deterministicFpiOft; // Aurora
    }

    function run() external {
        string memory outputDir = _outputDir();
        vm.createDir(outputDir, true);

        RemoteAdminRoute[] storage routes = _remoteAdminRoutes();
        uint256 totalFee;
        uint256 written;
        uint256 skipped;

        for (uint256 i = 0; i < routes.length; i++) {
            RemoteAdminRoute memory route = routes[i];
            HopV2Target storage target = _hopV2TargetFor(route.chainId);
            address remoteAdmin = _remoteAdminForEid(route.eid);
            address fpiOft = _fpiOftFor(route.chainId);

            bytes memory remoteCall = abi.encodeCall(IHopV2.setApprovedOft, (fpiOft, false));
            bytes memory composeData = abi.encode(target.hop, remoteCall);

            // Gas the destination compose runs with. Chains with non-EVM gas metering need more
            // than the 400k default - see composeGasOverrides in HopConstants.
            uint128 composeGas = _composeGasFor(route.chainId);

            // Routes whose LZ send config has been torn down (deprecated chains) revert here
            // with LZ_NotImplemented(). Skip them rather than aborting the whole run - a batch
            // for such a chain could never be delivered anyway.
            uint256 fee;
            try
                IHopV2(FRAXTAL_HOP).quote({
                    _oft: FRXUSD_LOCKBOX,
                    _dstEid: route.eid,
                    _recipient: bytes32(uint256(uint160(remoteAdmin))),
                    _amountLD: 0,
                    _dstGas: composeGas,
                    _data: composeData
                })
            returns (uint256 quoted) {
                fee = quoted;
            } catch {
                console.log("SKIPPED (quote reverted, route unreachable):", target.name);
                skipped++;
                continue;
            }

            fee = (fee * 150) / 100;
            totalFee += fee;
            written++;

            bytes memory localCall = abi.encodeWithSignature(
                "sendOFT(address,uint32,bytes32,uint256,uint128,bytes)",
                FRXUSD_LOCKBOX,
                route.eid,
                bytes32(uint256(uint160(remoteAdmin))),
                uint256(0),
                composeGas,
                composeData
            );

            SafeTx[] memory txs = new SafeTx[](1);
            txs[0] = SafeTx({
                name: string.concat("Revoke FPI approvedOft on ", target.name),
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
            console.log("Wrote:", filename);
            console.log("  fpiOft:", fpiOft);
            console.log("  composeGas:", composeGas);
            console.log("  fee (wei):", fee);
        }

        console.log("Routes total:", routes.length);
        console.log("Batches written:", written);
        console.log("Routes skipped (unreachable):", skipped);
        console.log("Total FRAX fee across all batches (wei):", totalFee);

        if (_includeFraxtal()) _writeFraxtalLocal(outputDir);
    }

    /// @notice Fraxtal's own hub hop is not reachable via RemoteAdmin - it is revoked by a
    ///         direct msig call on Fraxtal. Emitted separately so it is never confused with
    ///         the hop-delivered batches.
    function _writeFraxtalLocal(string memory outputDir) internal {
        SafeTx[] memory txs = new SafeTx[](1);
        txs[0] = SafeTx({
            name: "Revoke FPI approvedOft on Fraxtal (direct)",
            to: FRAXTAL_HOP,
            value: 0,
            data: abi.encodeCall(IHopV2.setApprovedOft, (FPI_LOCKBOX, false))
        });

        string memory filename = string(abi.encodePacked(outputDir, "/Fraxtal-Local(252).json"));
        new SafeTxHelper().writeTxs(txs, filename);
        console.log("Wrote:", filename);
    }

    function _fpiOftFor(uint256 chainId) internal view returns (address fpiOft) {
        fpiOft = fpiOfts[chainId];
        require(fpiOft != address(0), "missing FPI OFT for chainId");
    }

    function _outputDir() internal view returns (string memory dir) {
        dir = vm.envExists("OUTPUT_DIR")
            ? vm.envString("OUTPUT_DIR")
            : "src/script/hop/RemoteAdmin/txs/RevokeFpiOftAllChains";
    }

    function _includeFraxtal() internal view returns (bool include) {
        include = vm.envExists("INCLUDE_FRAXTAL") ? vm.envBool("INCLUDE_FRAXTAL") : false;
    }
}
