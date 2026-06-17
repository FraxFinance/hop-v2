// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

import { ProxyAdmin } from "@openzeppelin/contracts/proxy/transparent/ProxyAdmin.sol";
import { ITransparentUpgradeableProxy } from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import { IAccessControl } from "@openzeppelin/contracts/access/IAccessControl.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import { RemoteHopV2Tempo } from "src/contracts/hop/RemoteHopV2Tempo.sol";
import { RemoteHopV201Tempo } from "src/contracts/hop/RemoteHopV201Tempo.sol";

import { RemoteHopV2TempoForkTest } from "./RemoteHopV2TempoForkTest.t.sol";
import { MockERC20 } from "./mocks/MockERC20.sol";

/// @notice Re-runs the entire `RemoteHopV2TempoForkTest` suite against the V201 implementation
///         (`RemoteHopV201Tempo`) and adds `recoverERC20` coverage on top.
/// @dev Inheriting the V2 fork test means every quote, approvedOft, msg.value-rejection check
///      runs unchanged against the V201 contract — proving ABI parity for all V2 selectors.
///      Only the proxy implementation differs, deployed via the overridden `_deployRemoteHopV2Tempo`.
contract RemoteHopV201TempoForkTest is RemoteHopV2TempoForkTest {
    /// @dev Deploys `RemoteHopV201Tempo` behind the standard Tempo hop proxy. The returned
    ///      handle is cast to `RemoteHopV2Tempo` so all inherited tests work as-is — both
    ///      implementations share every external selector and the V201 proxy responds to
    ///      `quote`, `quoteStatic`, `sendOFT`, `approvedOft`, `removeDust`, `nativeToken`, etc.
    function _deployRemoteHopV2Tempo() internal override returns (RemoteHopV2Tempo deployed) {
        deployed = RemoteHopV2Tempo(payable(_deployHopProxy(address(new RemoteHopV201Tempo(TEMPO_ENDPOINT)))));
    }

    // ─── recoverERC20 (only V201 surface) ────────────────────────────────────

    function testFork_RemoteHopV201Tempo_RecoverERC20_Sweeps() public {
        RemoteHopV201Tempo hop = _hopV201();
        address recipient = makeAddr("recover-recipient");
        uint256 amount = 1e6;

        // Use a plain ERC20 mock — Tempo's TIP20 alt-tokens behind real OFTs are
        // precompile-flavored and don't expose a standard EVM `balanceOf`, which is
        // unrelated to the AccessControl-gated recover surface under test here.
        MockERC20 token = new MockERC20("recover", "REC", 6);
        deal(address(token), address(hop), amount);

        address recoverer = makeAddr("recoverer");
        bytes32 recoverRole = hop.RECOVER_ROLE();
        vm.prank(_defaultAdmin());
        hop.grantRole(recoverRole, recoverer);

        vm.prank(recoverer);
        hop.recoverERC20(address(token), recipient, amount);

        assertEq(token.balanceOf(recipient), amount, "recipient balance");
        assertEq(token.balanceOf(address(hop)), 0, "hop drained");
    }

    function testFork_RemoteHopV201Tempo_RecoverERC20_NonRecoverer_Reverts() public {
        RemoteHopV201Tempo hop = _hopV201();
        address attacker = makeAddr("attacker");
        bytes32 recoverRole = hop.RECOVER_ROLE();
        MockERC20 token = new MockERC20("recover", "REC", 6);

        vm.prank(attacker);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, attacker, recoverRole)
        );
        hop.recoverERC20(address(token), attacker, 1);
    }

    // ─── Storage-compat smoke test: upgrade V2 → V201 mid-fixture ─────────────

    /// @notice Verifies the V2 → V201 upgrade preserves the namespaced HopV2 storage slot:
    ///         all approvedOft/remoteHop/localEid state survives, and the V201 surface
    ///         (RECOVER_ROLE, recoverERC20) becomes available on the same proxy address.
    function testFork_RemoteHopV2_UpgradeTo_V201_PreservesState() public {
        // `setUp()` (inherited) deployed V201 already; deploy a fresh V2 proxy here so we can
        // observe the upgrade transition explicitly.
        address payable v2Proxy = payable(_deployHopProxy(address(new RemoteHopV2Tempo(TEMPO_ENDPOINT))));
        RemoteHopV2Tempo v2Hop = RemoteHopV2Tempo(v2Proxy);

        // Snapshot a few storage views before the upgrade.
        bool approvedBefore = v2Hop.approvedOft(FRXUSD_OFT);
        uint32 localEidBefore = v2Hop.localEid();

        // Perform the in-place upgrade. OZ v5 TransparentUpgradeableProxy stores the admin as
        // a freshly-deployed ProxyAdmin contract (owned by the EOA we passed in), so the
        // upgrade call must be routed through `ProxyAdmin.upgradeAndCall` from that owner.
        RemoteHopV201Tempo newImpl = new RemoteHopV201Tempo(TEMPO_ENDPOINT);
        ProxyAdmin admin = ProxyAdmin(_readAdmin(v2Proxy));
        vm.prank(proxyAdmin);
        admin.upgradeAndCall(ITransparentUpgradeableProxy(v2Proxy), address(newImpl), "");

        RemoteHopV201Tempo upgraded = RemoteHopV201Tempo(v2Proxy);

        // Storage carries through unchanged (same ERC-7201 slot).
        assertEq(upgraded.approvedOft(FRXUSD_OFT), approvedBefore, "approvedOft drift");
        assertEq(upgraded.localEid(), localEidBefore, "localEid drift");

        // V201 surface is now live on the same proxy.
        assertEq(
            upgraded.RECOVER_ROLE(),
            0x62b337eaefec74dadf1a62e856bf9db4f14a0f27d4f48156a95a9f98e7d5e066,
            "RECOVER_ROLE selector mismatch"
        );
    }

    // ─── helpers ─────────────────────────────────────────────────────────────

    function _hopV201() internal view returns (RemoteHopV201Tempo) {
        return RemoteHopV201Tempo(payable(address(remoteHopTempo)));
    }

    /// @dev DEFAULT_ADMIN_ROLE was granted to `address(this)` (the test contract) at proxy
    ///      construction because `_deployHopProxy` calls `initialize` from the test's stack
    ///      via the proxy constructor.
    function _defaultAdmin() internal view returns (address) {
        return address(this);
    }

    /// @dev Reads the ERC-1967 admin slot to recover the ProxyAdmin contract that OZ v5's
    ///      TransparentUpgradeableProxy auto-deploys in its constructor.
    function _readAdmin(address proxy) internal view returns (address adminAddr) {
        bytes32 adminSlot = 0xb53127684a568b3173ae13b9f8a6016e243e63b6e8ee1178d6a717850b5d6103;
        adminAddr = address(uint160(uint256(vm.load(proxy, adminSlot))));
    }
}
