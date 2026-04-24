// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import { Script, console } from "forge-std/Script.sol";
import { SafeTxHelper, SafeTx } from "frax-std/SafeTxHelper.sol";
import { IAccessControl } from "@openzeppelin/contracts/access/IAccessControl.sol";

/// @notice Re-queues every Tempo HopV2 governance action that was sitting in
///         the previous Safe UI before it got taken down, **plus** the newly
///         discovered phantom-admin revocation.
///
///         One JSON per Safe tx, written under
///         `src/script/hop/fix/txs/RequeueTempoMsig/`.
///
/// ====================================================================
/// THE 0xF866Bb...5d50 SAGA  (read this before changing tx6)
/// ====================================================================
/// On a fresh `cast call hasRole(DEFAULT_ADMIN_ROLE, *)` against the Tempo
/// `RemoteHopV2` proxy (0x0000006D...de659) the role-holders are:
///   - 0x1Ba19a54...2bEe  Tempo team Safe   (legitimate)
///   - 0xF866Bb64...5d50  no-code phantom   (must be revoked - tx6)
/// and NOT:
///   - 0x05b4a311...581f  the real, correctly-configured RemoteAdminV2
///   - 0xe764367b...4a2a  the contract that was actually CREATEd at deploy
///   - 0x954286...0a8B9   the standard mesh-wide RemoteAdmin
///
/// Walking `broadcast/DeployRemoteHopV2Tempo.s.sol/4217/run-latest.json`
/// (deployer 0x54F9b1...17bC):
///
///   nonce 0x5a  CREATE RemoteAdmin                    -> 0xe764367b...4a2a
///   nonce 0x62  grantRole(DEFAULT_ADMIN, msig)        -> 0x1Ba19a54...2bEe
///   nonce 0x63  grantRole(DEFAULT_ADMIN, remoteAdmin) -> 0xF866Bb64...5d50  (!)
///   nonce 0x64  renounceRole(DEFAULT_ADMIN, deployer)
///
/// The deploy script does:
///     new RemoteAdmin{salt: bytes32(uint256(1))}(frxUsdOft, remoteHop, FRAXTAL_MSIG)
/// i.e. CREATE2 through the deterministic `CREATE2_DEPLOYER`. In the Foundry
/// SIMULATION the CREATE2 address resolved to 0xF866Bb...5d50 and that value
/// got captured in the local `remoteAdmin` variable, then baked into the
/// downstream `grantRole(...)` call.
///
/// On BROADCAST the CREATE2 deployer wasn't available on Tempo (fresh chain
/// at the time), so `new X{salt:..}(...)` fell through to a plain CREATE
/// from the deployer at the current EOA nonce, producing 0xe764367b...4a2a.
/// The script never re-read its variable, so the grantRole at nonce 0x63
/// still targeted the simulated 0xF866Bb...5d50 - an address where no
/// contract was ever deployed.
///
/// Consequences:
///   - 0xF866Bb...5d50 is NOT a contract, has never been a contract, and
///     did NOT selfdestruct. `eth_getCode` returns `0x` because nothing was
///     ever there. The role mapping just got set to true on a vacant slot.
///   - 0xe764367b...4a2a was deployed but never received the role and is
///     irrelevant - hence the "Old (non-deterministic) RemoteAdmin" label
///     in the team HackMD.
///   - The "0x4242..." balance on 0xF866Bb...5d50 is unrelated sentinel
///     dust someone sent to the phantom address.
///
/// FixRemoteAdminTempo.s.sol later deployed the proper RemoteAdminV2 at
/// 0x05b4a311...581f (correct frxUsdOft / hopV2 / msig getters). Tx4 below
/// grants it the role; tx6 revokes the phantom.
/// ====================================================================
///
/// Tx ordering (slimmed; on-chain check showed only 0x1Ba1... and the
/// phantom hold DEFAULT_ADMIN, so the original tx1 revoke of 0xe7643,
/// tx2 grant of 0x9542, and tx4b revoke of 0x9542 are all no-ops and
/// have been dropped):
///   1. ProxyAdmin.upgrade(RemoteHopV2 -> RemoteHopV2Tempo)  (NO reinit; see note below)
///   2. grant DEFAULT_ADMIN to correct RemoteAdminV2 (0x05b4...581f)
///        - was the multiSend in the original plan; collapsed to a single
///          grant because the paired revoke of 0x9542 is unnecessary (role
///          was never granted on-chain).
///   3. setExecutorOptions(Somnia eid=30380, dstGas=1_000_000)
///   4. revoke DEFAULT_ADMIN from phantom 0xF866Bb...5d50  (NEW)
///
/// NOTE on tx1 (no reinit):
///   The original team plan called for `upgradeAndCall(..., initialize(...))`,
///   but the proxy was already initialized at original deploy time and
///   `RemoteHopV2Tempo` inherits `RemoteHopV2.initialize` which uses the
///   single-shot `initializer` modifier (no `reinitializer(N)` override and
///   no new storage to seed). On-chain simulation from the Tempo msig
///   confirms `upgradeAndCall(..., initialize(...))` reverts with
///   `InvalidInitialization() (0xf92ee8a9)`. We therefore use plain
///   `ProxyAdmin.upgrade(proxy, impl)` (selector 0x99a88ec4).
///
/// Run:
///   forge script src/script/hop/fix/RequeueTempoMsig.s.sol --rpc-url https://rpc.tempo.xyz --ffi
interface IProxyAdmin {
    function upgrade(address proxy, address impl) external;
}

interface IHopV2SetExecutorOptions {
    function setExecutorOptions(uint32 eid, bytes calldata options) external;
}

contract RequeueTempoMsig is Script {
    uint256 public constant TEMPO_CHAIN_ID = 4217;

    // Core
    address public constant TEMPO_MSIG = 0x1Ba19a54a01AE967f5E3895764Caaa6919FD2bEe;
    address public constant REMOTE_HOP = 0x0000006D38568b00B457580b734e0076C62de659;
    address public constant PROXY_ADMIN = 0x000000dbfaA1Fb91ca46867cE6D41aB6da4f7428;
    address public constant LZ_ENDPOINT = 0x20Bb7C2E2f4e5ca2B4c57060d1aE2615245dCc9C;
    address public constant FRAXTAL_HOP = 0x00000000e18aFc20Afe54d4B2C8688bB60c06B36;

    // RemoteAdmin set
    address public constant CORRECT_REMOTE_ADMIN_V2 = 0x05b4a311Aac6658C0FA1e0247Be898aae8a8581f; // tx2 grant
    address public constant PHANTOM_ADMIN = 0xF866Bb647CB051F17C2cd1FBE71EDF17Df5C5d50; // tx4

    // New RemoteHopV2Tempo implementation
    address public constant NEW_IMPL = 0xa4dCb15E851cC4F14498cc9B0158c317672Df7b5;

    // initialize args
    uint32 public constant LOCAL_EID = 30_410;
    uint32 public constant NUM_DVNS = 3;
    address public constant EXECUTOR = 0xf851abCa1d0fD1Df8eAba6de466a102996b7d7B2;
    address public constant DVN = 0x76FaFF60799021B301B45dC1BbEDE53F261F9961;
    address public constant TREASURY = 0x1deB70e45c2399a4aBEf19E9B1643F2670f892d0;

    address public constant FRXUSD_OFT = 0x00000000D61733e7A393A10A5B48c311AbE8f1E5;
    address public constant SFRXUSD_OFT = 0x00000000fD8C4B8A413A06821456801295921a71;
    address public constant FRXETH_OFT = 0x000000008c3930dCA540bB9B3A5D0ee78FcA9A4c;
    address public constant SFRXETH_OFT = 0x00000000883279097A49dB1f2af954EAd0C77E3c;
    address public constant WFRAX_OFT = 0x00000000E9CE0f293D1Ce552768b187eBA8a56D4;
    address public constant FPI_OFT = 0x00000000bC4aEF4bA6363a437455Cb1af19e2aEb;

    // Somnia executor options: type=1, len=17, workerId=1, gas=1_000_000
    uint32 public constant SOMNIA_EID = 30_380;
    uint128 public constant SOMNIA_GAS = 1_000_000;

    function run() public {
        require(block.chainid == TEMPO_CHAIN_ID, "must run against Tempo");

        string memory root = vm.projectRoot();
        string memory dir = string(abi.encodePacked(root, "/src/script/hop/fix/txs/RequeueTempoMsig"));

        // ---- 1. ProxyAdmin.upgrade(RemoteHopV2 -> RemoteHopV2Tempo) ----
        // Reinit dropped: proxy is already initialized; on-chain simulation
        // of upgradeAndCall(..., initialize(...)) reverts with
        // InvalidInitialization() (0xf92ee8a9). RemoteHopV2Tempo introduces
        // no new storage, so plain upgrade() is sufficient and safe.
        _writeOne(
            SafeTx({
                name: "1. ProxyAdmin.upgrade -> RemoteHopV2Tempo (no reinit; proxy already initialized)",
                to: PROXY_ADMIN,
                value: 0,
                data: abi.encodeCall(IProxyAdmin.upgrade, (REMOTE_HOP, NEW_IMPL))
            }),
            dir,
            "1-upgrade-RemoteHopV2Tempo.json"
        );

        // ---- 2. grant correct RemoteAdminV2 ----
        // Originally a multiSend that ALSO revoked 0x9542; on-chain check
        // showed 0x9542 never held the role (the prior tx2 grant was never
        // executed because the queue went down), so the paired revoke is
        // unnecessary. Collapsed to a single grant.
        _writeOne(
            SafeTx({
                name: "2. Grant DEFAULT_ADMIN_ROLE to correct RemoteAdminV2 (0x05b4...581f)",
                to: REMOTE_HOP,
                value: 0,
                data: abi.encodeCall(IAccessControl.grantRole, (bytes32(0), CORRECT_REMOTE_ADMIN_V2))
            }),
            dir,
            "2-grantRole-CorrectRemoteAdminV2.json"
        );

        // ---- 3. setExecutorOptions(Somnia, gas=1_000_000) - direct local call ----
        bytes memory somniaOptions = abi.encodePacked(uint8(1), uint16(17), uint8(1), uint128(SOMNIA_GAS));
        require(somniaOptions.length == 20, "options len");

        _writeOne(
            SafeTx({
                name: "3. setExecutorOptions(Somnia eid=30380, options=0x01001101...0f4240) - dstGas=1_000_000",
                to: REMOTE_HOP,
                value: 0,
                data: abi.encodeCall(IHopV2SetExecutorOptions.setExecutorOptions, (SOMNIA_EID, somniaOptions))
            }),
            dir,
            "3-setExecutorOptions-Somnia.json"
        );

        // ---- 4. revoke DEFAULT_ADMIN from phantom 0xF866Bb...5d50 (NEW) ----
        _writeOne(
            SafeTx({
                name: "4. Revoke DEFAULT_ADMIN_ROLE from phantom 0xF866Bb...5d50 (see SAGA in script NatSpec)",
                to: REMOTE_HOP,
                value: 0,
                data: abi.encodeCall(IAccessControl.revokeRole, (bytes32(0), PHANTOM_ADMIN))
            }),
            dir,
            "4-revokeRole-PhantomAdmin.json"
        );

        console.log("Safe batches written to:", dir);
        console.log("Upload via Tx Builder on:");
        console.log(
            string.concat(
                "https://app.safe.global/apps/open?safe=tempo:",
                vm.toString(TEMPO_MSIG),
                "&appUrl=https://apps-portal.safe.global/tx-builder"
            )
        );
        console.log("Somnia options bytes:");
        console.logBytes(somniaOptions);
    }

    function _writeOne(SafeTx memory t, string memory dir, string memory name) internal {
        SafeTx[] memory arr = new SafeTx[](1);
        arr[0] = t;
        new SafeTxHelper().writeTxs(arr, string(abi.encodePacked(dir, "/", name)));
    }
}
