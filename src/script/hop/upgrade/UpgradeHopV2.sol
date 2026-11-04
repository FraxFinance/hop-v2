pragma solidity 0.8.23;

import { ERC1967Utils } from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Utils.sol";
import { FraxtalHopV201 } from "src/contracts/hop/FraxtalHopV201.sol";
import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { Strings } from "@openzeppelin/contracts/utils/Strings.sol";
import { Script } from "forge-std/Script.sol";
import { SafeTx, SafeTxHelper } from "frax-std/SafeTxHelper.sol";

abstract contract UpgradeHopV2 is Script {
    using Strings for address;
    using Strings for uint256;

    address hop;

    address proxyAdmin;
    address msig;
    address newImplementation;
    SafeTx[] safeTxs;
    SafeTxHelper safeTxHelper;

    function setUp() public virtual {
        bytes32 adminSlot = vm.load(hop, ERC1967Utils.ADMIN_SLOT);
        proxyAdmin = address(uint160(uint256(adminSlot)));
        msig = Ownable(proxyAdmin).owner();

        safeTxHelper = new SafeTxHelper();
    }

    function run() public {
        deployImplementation();
        generateMsigTx();
    }

    function deployImplementation() internal virtual {}

    /// @dev Chain-specific calls appended to the batch after the simulated upgrade, e.g. the hub's setActionModule.
    function _appendExtraTxs() internal virtual {}

    /// @dev Split into small steps on purpose: each piece keeps its frame shallow enough for via-IR codegen even
    ///      when the implementation constructor takes arguments (the Tempo variant).
    function generateMsigTx() internal virtual {
        if (block.chainid == 1) {
            _generateEthereumTx();
            return;
        }

        vm.startPrank(msig);
        _pushUpgrade();
        _pushRecoverRoleGrant();
        _appendExtraTxs();
        vm.stopPrank();

        safeTxHelper.writeTxs(safeTxs, _batchPath(msig, ".json"));
    }

    /// @dev Simulates and records the proxy upgrade.
    function _pushUpgrade() internal {
        bytes memory data = abi.encodeWithSignature(
            "upgradeAndCall(address,address,bytes)",
            hop,
            newImplementation,
            bytes("")
        );
        (bool success, ) = proxyAdmin.call(data);
        require(success, "Upgrade failed");
        safeTxs.push(SafeTx({ name: "upgrade", to: proxyAdmin, value: 0, data: data }));
    }

    /// @dev Grants RECOVER_ETH_ROLE to the multisig when the (now upgraded) target exposes it.
    function _pushRecoverRoleGrant() internal {
        (bool success, bytes memory data) = hop.staticcall(abi.encodeWithSignature("RECOVER_ETH_ROLE()"));
        if (!success || data.length != 32) return;

        data = abi.encodeWithSignature("grantRole(bytes32,address)", abi.decode(data, (bytes32)), msig);
        (success, ) = hop.call(data);
        require(success, "grantRole(RECOVER_ETH_ROLE, msig) failed");
        safeTxs.push(SafeTx({ name: "grant recover role", to: hop, value: 0, data: data }));
    }

    /// @dev `<root>/src/script/hop/upgrade/txs/<chainid>-<signer><suffix>`
    function _batchPath(address _signer, string memory _suffix) internal view returns (string memory) {
        return
            string(
                abi.encodePacked(
                    vm.projectRoot(),
                    "/src/script/hop/upgrade/txs/",
                    block.chainid.toString(),
                    "-",
                    _signer.toHexString(),
                    _suffix
                )
            );
    }

    function _generateEthereumTx() internal {
        // On Ethereum the proxy admin is a Compound-style Timelock,
        // not a multisig.  The admin of the timelock (0xfFFffF...) is the
        // actual governor Safe.  Produce two txn files:
        //   1. queue + execute upgrade via the timelock (by the governor)
        //   2. grant RECOVER_ETH_ROLE to the timelock (by a DEFAULT_ADMIN_ROLE holder)

        address timelock = msig; // 0xb898Ad... (returned by proxyAdmin.owner())
        (bool ok, bytes memory raw) = timelock.staticcall(abi.encodeWithSignature("admin()"));
        require(ok, "Timelock admin() call failed");
        address governor = abi.decode(raw, (address)); // 0xfFFffF...

        // --- File 1: queue the upgrade (sign now, eta = now + 1 day) ---
        vm.startPrank(governor);

        bytes memory upgradeCalldata = abi.encodeWithSignature(
            "upgradeAndCall(address,address,bytes)",
            hop,
            newImplementation,
            bytes("")
        );

        bytes memory queueData = abi.encodeWithSignature(
            "queueTransaction(address,uint256,string,bytes,uint256)",
            proxyAdmin,
            0,
            "",
            upgradeCalldata,
            block.timestamp + 1 days // timelock delay is 1 day on-chain
        );
        (bool success, ) = timelock.call(queueData);
        require(success, "Timelock queue failed");
        vm.stopPrank();

        SafeTx[] memory queueTxs = new SafeTx[](1);
        queueTxs[0] = SafeTx({ name: "timelock queue upgrade", to: timelock, value: 0, data: queueData });

        safeTxHelper.writeTxs(queueTxs, _batchPath(governor, "-queue.json"));

        // --- File 2: execute the upgrade (sign after eta has passed) ---
        bytes memory executeData = abi.encodeWithSignature(
            "executeTransaction(address,uint256,string,bytes,uint256)",
            proxyAdmin,
            0,
            "",
            upgradeCalldata,
            block.timestamp + 1 days
        );

        SafeTx[] memory executeTxs = new SafeTx[](1);
        executeTxs[0] = SafeTx({ name: "timelock execute upgrade", to: timelock, value: 0, data: executeData });

        safeTxHelper.writeTxs(executeTxs, _batchPath(governor, "-execute.json"));

        // --- File 3: grant RECOVER_ETH_ROLE to the timelock ---
        // The upgrade hasn't executed yet, so the proxy still runs old code
        // that doesn't expose RECOVER_ETH_ROLE. Use the known keccak256 value.
        bytes32 recoverRole = 0xfedd0e52ab05da04684e0bc204015ae57756f9c216de6f3af64eea1589a09b0e;
        _grantRecoverRoleViaRoleHolder(recoverRole, 0x6cCF3F2Ca29591F90ADB403D67E4dcB49cEcC634);
    }

    function _grantRecoverRoleViaRoleHolder(bytes32 recoverRole, address grantee) internal {
        bytes32 defaultAdminRole = 0x0000000000000000000000000000000000000000000000000000000000000000;

        (bool ok, bytes memory raw) = hop.staticcall(
            abi.encodeWithSignature("getRoleMemberCount(bytes32)", defaultAdminRole)
        );
        require(ok, "getRoleMemberCount failed");
        uint256 count = abi.decode(raw, (uint256));

        address roleHolder;
        for (uint256 i = 0; i < count; i++) {
            (ok, raw) = hop.staticcall(abi.encodeWithSignature("getRoleMember(bytes32,uint256)", defaultAdminRole, i));
            require(ok, "getRoleMember failed");
            address member = abi.decode(raw, (address));
            // Prefer the deploy-script msig (0x6cCF3F...) if present
            if (member == 0x6cCF3F2Ca29591F90ADB403D67E4dcB49cEcC634) {
                roleHolder = member;
                break;
            }
            if (roleHolder == address(0)) roleHolder = member;
        }
        require(roleHolder != address(0), "No DEFAULT_ADMIN_ROLE holder found");

        bytes memory grantData = abi.encodeWithSignature("grantRole(bytes32,address)", recoverRole, grantee);

        vm.stopPrank();
        vm.startPrank(roleHolder);
        (bool success, ) = hop.call(grantData);
        require(success, "Grant role via role holder failed");
        vm.stopPrank();
        vm.startPrank(msig); // restore original prank for the caller

        SafeTx[] memory grantTxs = new SafeTx[](1);
        grantTxs[0] = SafeTx({ name: "grant recover role", to: hop, value: 0, data: grantData });

        string memory grantFilepath = string(
            abi.encodePacked(
                vm.projectRoot(),
                "/src/script/hop/upgrade/txs/",
                block.chainid.toString(),
                "-",
                roleHolder.toHexString(),
                ".json"
            )
        );
        safeTxHelper.writeTxs(grantTxs, grantFilepath);
    }
}
