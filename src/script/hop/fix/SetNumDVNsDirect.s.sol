// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import { Script, console } from "forge-std/Script.sol";
import { SafeTxHelper, SafeTx } from "frax-std/SafeTxHelper.sol";
import { IHopV2 } from "src/contracts/interfaces/IHopV2.sol";
import { HopConstants, HopV2Target } from "src/script/hop/HopConstants.sol";

// Generates one direct local Safe transaction for HopV2.setNumDVNs().
// Intended to be called by run-set-num-dvns-msigs.sh for every chain.
contract SetNumDVNsDirect is Script, HopConstants {
    function run() external {
        uint32 numDvns = uint32(vm.envOr("NUM_DVNS", uint256(5)));
        string memory outputDir = vm.envOr("OUTPUT_DIR", string("src/script/hop/fix/generated/set-num-dvns"));
        HopV2Target storage target = _hopV2TargetFor(block.chainid);

        vm.createDir(outputDir, true);

        SafeTx[] memory txs = new SafeTx[](1);
        txs[0] = SafeTx({
            name: string.concat("Set ", target.name, " HopV2 numDVNs"),
            to: target.hop,
            value: 0,
            data: abi.encodeCall(IHopV2.setNumDVNs, (numDvns))
        });

        string memory filename = string(
            abi.encodePacked(outputDir, "/", vm.toString(block.chainid), "-HopV2-", target.name, ".json")
        );
        new SafeTxHelper().writeTxs(txs, filename);
        console.log("Safe tx JSON written to:", filename);
    }
}
