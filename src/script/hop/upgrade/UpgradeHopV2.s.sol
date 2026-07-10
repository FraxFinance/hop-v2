pragma solidity ^0.8.0;

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

    function generateMsigTx() internal {
        vm.startPrank(msig);

        // upgrade implementation
        bytes memory data = abi.encodeWithSignature(
            "upgradeAndCall(address,address,bytes)",
            hop,
            newImplementation,
            bytes("")
        );
        (bool success, ) = proxyAdmin.call(data);
        require(success, "Upgrade failed");
        safeTxs.push(SafeTx({ name: "upgrade", to: proxyAdmin, value: 0, data: data }));

        // grant RECOVER_ROLE to multisig when the target exposes it (HopV201 variants)
        bytes32 recoverRole;
        (success, data) = hop.staticcall(abi.encodeWithSignature("RECOVER_ROLE()"));
        if (success && data.length == 32) {
            recoverRole = abi.decode(data, (bytes32));
            data = abi.encodeWithSignature("grantRole(bytes32,address)", recoverRole, msig);
            (success, ) = hop.call(data);
            require(success, "Grant role failed");
            safeTxs.push(SafeTx({ name: "grant recover role", to: hop, value: 0, data: data }));
        }

        string memory filepath = string(
            abi.encodePacked(
                vm.projectRoot(),
                "/src/script/hop/upgrade/txs/",
                block.chainid.toString(),
                "-",
                msig.toHexString(),
                ".json"
            )
        );

        safeTxHelper.writeTxs(safeTxs, filepath);
    }
}
