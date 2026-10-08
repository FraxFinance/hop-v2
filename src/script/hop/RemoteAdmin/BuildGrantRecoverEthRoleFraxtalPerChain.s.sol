// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import { Script, console } from "forge-std/Script.sol";
import { SafeTxHelper, SafeTx } from "frax-std/SafeTxHelper.sol";
import { IAccessControl } from "@openzeppelin/contracts/access/IAccessControl.sol";
import { IHopV2 } from "src/contracts/interfaces/IHopV2.sol";
import { HopConstants, HopV2Target, RemoteAdminRoute } from "src/script/hop/HopConstants.sol";

// Builds one Fraxtal msig batch per remote chain that hops a `grantRole(RECOVER_ETH_ROLE, account)`
// call to that chain's RemoteHopV2 via its RemoteAdmin.
//
// Each output file is a standalone Safe batch executed on Fraxtal (chainId 252) against the
// Fraxtal hub hop. The compose payload lands on the remote RemoteAdmin, which forwards the
// call to the remote hop. RemoteAdmin only accepts composes whose original sender is the
// Fraxtal msig, so these must be executed by 0x5f25218ed9474b721d6a38c115107428E832fA2E.
//
// Tempo is skipped: HopV201Tempo pays gas in an ERC20, has no RECOVER_ETH_ROLE and its
// `recoverETH()` always reverts with NotImplemented(), so a grant there would do nothing.
// TIP20s on the Tempo hop come out through `recoverERC20`, which is DEFAULT_ADMIN_ROLE-gated.
//
// Required env vars:
// - ACCOUNT: address to grant RECOVER_ETH_ROLE to
// Optional env vars:
// - ACCOUNT_LABEL: human label used in Safe tx names, e.g. "thomas.frax"
// - OUTPUT_DIR: output directory for per-chain JSON files
// - INCLUDE_FRAXTAL: "true" to also emit the Fraxtal-local direct grant (default false)
// - FEE_BUFFER_BPS: multiplier on the live LZ quote, in bps (default 40000 = 4x)
// - FEE_MIN_HEADROOM: absolute FRAX (wei) added on top of the quote at minimum (default 5e18)
//
// ACCOUNT=0x381e2495e683868F693AA5B1414F712f21d34b40 ACCOUNT_LABEL=thomas.frax INCLUDE_FRAXTAL=true OUTPUT_DIR=src/script/hop/RemoteAdmin/txs/GrantThomasRecoverEthAllChains forge script src/script/hop/RemoteAdmin/BuildGrantRecoverEthRoleFraxtalPerChain.s.sol --rpc-url https://rpc.frax.com --ffi
//
// Inherits SafeTxHelper instead of deploying it: under forge 1.8.1 on a Fraxtal fork a plain
// CREATE from the script reverts, and calls into a CREATE2-deployed helper revert at 0 gas.
contract BuildGrantRecoverEthRoleFraxtalPerChain is Script, HopConstants, SafeTxHelper {
    address public constant FRAXTAL_HOP = 0x00000000e18aFc20Afe54d4B2C8688bB60c06B36;
    address public constant FRXUSD_LOCKBOX = 0x96A394058E2b84A89bac9667B19661Ed003cF5D4;
    uint32 public constant FRAXTAL_EID = 30_255;
    uint256 public constant TEMPO_CHAIN_ID = 4217;

    /// @dev keccak256("RECOVER_ETH_ROLE")
    bytes32 public constant RECOVER_ETH_ROLE = 0xfedd0e52ab05da04684e0bc204015ae57756f9c216de6f3af64eea1589a09b0e;

    function run() external {
        address account = _account();
        string memory accountLabel = _accountLabel(account);
        string memory outputDir = _outputDir();
        vm.createDir(outputDir, true);

        uint256 feeBufferBps = _feeBufferBps();
        console.log("Account:", account);
        uint256 feeMinHeadroom = _feeMinHeadroom();
        console.log("Fee buffer (bps):", feeBufferBps);
        console.log("Fee min headroom (wei):", feeMinHeadroom);

        bytes memory remoteCall = abi.encodeCall(IAccessControl.grantRole, (RECOVER_ETH_ROLE, account));
        RemoteAdminRoute[] storage routes = _remoteAdminRoutes();
        uint256 totalFee;
        uint256 maxFee;
        uint256 written;
        uint256 skipped;

        for (uint256 i = 0; i < routes.length; i++) {
            RemoteAdminRoute memory route = routes[i];
            HopV2Target storage target = _hopV2TargetFor(route.chainId);
            address remoteAdmin = _remoteAdminForEid(route.eid);

            if (route.chainId == TEMPO_CHAIN_ID) {
                console.log("SKIPPED (HopV201Tempo has no recoverETH):", target.name);
                skipped++;
                continue;
            }

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

            uint256 scaledFee = (fee * feeBufferBps) / 10_000;
            fee = scaledFee > fee + feeMinHeadroom ? scaledFee : fee + feeMinHeadroom;
            totalFee += fee;
            if (fee > maxFee) maxFee = fee;
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
                name: string.concat("Grant RECOVER_ETH_ROLE to ", accountLabel, " on ", target.name),
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

            writeTxs(txs, filename);
            console.log("Wrote:", filename);
            console.log("  composeGas:", composeGas);
            console.log("  fee (wei):", fee);
        }

        console.log("Routes total:", routes.length);
        console.log("Batches written:", written);
        console.log("Routes skipped:", skipped);
        console.log("Total FRAX attached across all batches (wei):", totalFee);
        // HopV2._handleMsgValue refunds the unspent buffer to the msig inside each tx, so the
        // msig only needs the largest single value on hand, not the total.
        console.log("Largest single batch value (wei):", maxFee);

        if (_includeFraxtal()) _writeFraxtalLocal(account, accountLabel, outputDir);
    }

    /// @notice Fraxtal's own hub hop is not reachable via RemoteAdmin - the role is granted by a
    ///         direct msig call on Fraxtal. Emitted separately so it is never confused with
    ///         the hop-delivered batches.
    function _writeFraxtalLocal(address account, string memory accountLabel, string memory outputDir) internal {
        SafeTx[] memory txs = new SafeTx[](1);
        txs[0] = SafeTx({
            name: string.concat("Grant RECOVER_ETH_ROLE to ", accountLabel, " on Fraxtal (direct)"),
            to: FRAXTAL_HOP,
            value: 0,
            data: abi.encodeCall(IAccessControl.grantRole, (RECOVER_ETH_ROLE, account))
        });

        string memory filename = string(abi.encodePacked(outputDir, "/Fraxtal-Local(252).json"));
        writeTxs(txs, filename);
        console.log("Wrote:", filename);
    }

    function _account() internal view returns (address account) {
        require(vm.envExists("ACCOUNT"), "missing ACCOUNT env");
        account = vm.envAddress("ACCOUNT");
        require(account != address(0), "ACCOUNT is zero");
    }

    function _accountLabel(address account) internal view returns (string memory label) {
        label = vm.envExists("ACCOUNT_LABEL") ? vm.envString("ACCOUNT_LABEL") : vm.toString(account);
    }

    function _outputDir() internal view returns (string memory dir) {
        dir = vm.envExists("OUTPUT_DIR")
            ? vm.envString("OUTPUT_DIR")
            : "src/script/hop/RemoteAdmin/txs/GrantRecoverEthRoleAllChains";
    }

    function _includeFraxtal() internal view returns (bool include) {
        include = vm.envExists("INCLUDE_FRAXTAL") ? vm.envBool("INCLUDE_FRAXTAL") : false;
    }

    /// @notice Multiplier applied to the live LayerZero quote, in basis points.
    /// @dev The quote is a snapshot of destination gas pricing. A batch that sits in the msig
    ///      queue while that price rises reverts with `InsufficientFee()` - 1.5x was not enough
    ///      for Ethereum in the FPI revoke, whose quote rose ~4.4x over 13 queued days. Overpaying
    ///      is nearly free: `HopV2._handleMsgValue` refunds the excess to the sender, so the only
    ///      cost of a wide buffer is the FRAX the msig must hold at execution time.
    function _feeBufferBps() internal view returns (uint256 bps) {
        bps = vm.envExists("FEE_BUFFER_BPS") ? vm.envUint("FEE_BUFFER_BPS") : 40_000;
        require(bps >= 10_000, "FEE_BUFFER_BPS must be at least 10000 (1x)");
    }

    /// @notice Absolute headroom added to the live quote when it beats the multiplier.
    /// @dev A multiplier cannot absorb an additive jump on a cheap route. On 2026-10-07 the
    ///      Canary DVN's Fraxtal-origin fee went from 0.0009 to 3.36 FRAX for a few hours, which
    ///      took a 0.85 FRAX quote to 4.21 FRAX - past a 4x buffer (3.40 FRAX). The surplus is
    ///      refunded like the multiplier's, so this only raises what the msig must hold.
    function _feeMinHeadroom() internal view returns (uint256 headroom) {
        headroom = vm.envExists("FEE_MIN_HEADROOM") ? vm.envUint("FEE_MIN_HEADROOM") : 5e18;
    }
}
