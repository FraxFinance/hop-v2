// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import { UpgradeHopV2 } from "src/script/hop/upgrade/UpgradeHopV2.s.sol";
import { RemoteHopV201Tempo } from "src/contracts/hop/RemoteHopV201Tempo.sol";

// ====================================================================
// ===================== UpgradeRemoteHopV2Tempo ======================
// ====================================================================
//
// Tempo cannot share the salt-mined `RemoteHopV201` vanity implementation
// (`0xD3b7B923990000003500009264561127A87B00Bd`) because the Tempo variant has
// custom EndpointV2Alt / TIP20 fee semantics — its constructor takes
// `_endpoint`, so its bytecode is parameterized per chain and never on the
// vanity scheme. The proxy at `0x0000006D38568b00B457580b734e0076C62de659`
// stays put; only the implementation behind it changes.
//
// After this upgrade the proxy delegates to `RemoteHopV201Tempo` (inherits
// `HopV201Tempo`), which mirrors `HopV201`'s recover surface — `RECOVER_ROLE`
// + `recoverERC20` — and drops both the unbounded `recover(address,uint256,bytes)`
// from `HopV2` and the `recoverETH` from `HopV201` (Tempo settles fees in
// TIP20 via EndpointV2Alt; there is no native ETH surface to recover).
// Storage layout is unchanged because both versions share the same ERC-7201 slot.
//
// Generates the Safe batch JSON at:
//   src/script/hop/upgrade/txs/4217-0x1ba19a54a01ae967f5e3895764caaa6919fd2bee.json
//
// Usage (deploy + generate JSON in one run):
//   forge script src/script/hop/upgrade/UpgradeRemoteHopV2Tempo.s.sol \
//     --rpc-url https://rpc.tempo.xyz \
//     --gcp --sender 0x54f9b12743a7deec0ea48721683cbebedc6e17bc \
//     --broadcast --verify --ffi
contract UpgradeRemoteHopV2Tempo is UpgradeHopV2 {
    /// @dev Tempo LZ EndpointV2Alt — same address consumed by `DeployRemoteHopV2Tempo`.
    address internal constant TEMPO_ENDPOINT = 0x20Bb7C2E2f4e5ca2B4c57060d1aE2615245dCc9C;

    function setUp() public override {
        // Tempo proxy address (vanity, identical to every other chain's RemoteHop).
        hop = 0x0000006D38568b00B457580b734e0076C62de659;
        super.setUp();
    }

    function deployImplementation() internal virtual override {
        vm.startBroadcast();
        // Plain CREATE — Tempo impl is non-deterministic by design (constructor takes _endpoint).
        newImplementation = address(new RemoteHopV201Tempo(TEMPO_ENDPOINT));
        vm.stopBroadcast();
    }
}
