// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import { UpgradeHopV2 } from "src/script/hop/upgrade/UpgradeHopV2.sol";
import { RemoteHopV201Tempo } from "src/contracts/hop/RemoteHopV201Tempo.sol";

// ====================================================================
// ===================== UpgradeRemoteHopV2Tempo ======================
// ====================================================================
//
// Tempo cannot share the `RemoteHopV201` implementation the other spokes use
// because the Tempo variant has custom EndpointV2Alt / TIP20 fee semantics and
// its constructor takes `_endpoint`. The proxy at `0x0000006D38568b00B457580b734e0076C62de659`
// stays put; only the implementation behind it changes.
//
// The implementation is CREATE2-deployed under a constant salt with the endpoint as
// constructor argument, so its address follows from the artifact; a contract already
// at that address is reused and only the batch is regenerated.
//
// After this upgrade the proxy delegates to `RemoteHopV201Tempo` (inherits
// `HopV201Tempo`), which keeps `HopV201`'s DEFAULT_ADMIN_ROLE-gated `recoverERC20`
// and drops both the unbounded `recover(address,uint256,bytes)` from `HopV2` and
// the RECOVER_ETH_ROLE-gated `recoverETH` from `HopV201` (Tempo settles fees in
// TIP20 via EndpointV2Alt; there is no native ETH surface to recover, so the
// Tempo `recoverETH` reverts `NotImplemented`).
// Storage layout is unchanged because both versions share the same ERC-7201 slot.
//
// Generates the Safe batch JSON at:
//   src/script/hop/upgrade/txs/4217-0x1ba19a54a01ae967f5e3895764caaa6919fd2bee.json
//
// Usage (deploy + generate JSON in one run):
//   forge script src/script/hop/upgrade/UpgradeRemoteHopV2Tempo.s.sol \
//     --rpc-url https://rpc.tempo.xyz \
//     --gcp --sender 0x54f9b12743a7deec0ea48721683cbebedc6e17bc \
//     --broadcast --ffi \
//     --verify --verifier sourcify --verifier-url https://contracts.tempo.xyz
contract UpgradeRemoteHopV2Tempo is UpgradeHopV2 {
    /// @dev Tempo LZ EndpointV2Alt — same address consumed by `DeployRemoteHopV2Tempo`.
    address internal constant TEMPO_ENDPOINT = 0x20Bb7C2E2f4e5ca2B4c57060d1aE2615245dCc9C;

    function setUp() public override {
        // Tempo proxy address (vanity, identical to every other chain's RemoteHop).
        hop = 0x0000006D38568b00B457580b734e0076C62de659;
        super.setUp();
    }

    bytes32 internal constant SALT = 0x4e59b44847b379578588920ca78fbf26c0b4956c9f4ed96d14900e7523000004;

    function deployImplementation() internal virtual override {
        require(block.chainid == 4217, "Tempo only");

        newImplementation = _deployCreate2(
            SALT,
            abi.encodePacked(type(RemoteHopV201Tempo).creationCode, abi.encode(TEMPO_ENDPOINT))
        );
    }
}
