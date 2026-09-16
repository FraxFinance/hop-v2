// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import { Test, console } from "forge-std/Test.sol";
import { IHopComposer } from "src/contracts/interfaces/IHopComposer.sol";
import { IHopV2 } from "src/contracts/interfaces/IHopV2.sol";

interface IRemoteAdmin {
    function frxUsdOft() external view returns (address);

    function hopV2() external view returns (address);

    function fraxtalMsig() external view returns (bytes32);
}

/// @dev Forked check that the compose payload built by BuildRevokeFpiOftFraxtalPerChain
///      actually flips approvedOft to false once it lands on the destination chain.
///      forge test --match-contract RevokeFpiOftDelivery -vv
contract RevokeFpiOftDeliveryTest is Test {
    uint32 internal constant FRAXTAL_EID = 30_255;

    function _assertRevokeLands(string memory rpc, address remoteAdmin, address hop, address fpiOft) internal {
        vm.createSelectFork(rpc);

        assertTrue(IHopV2(hop).approvedOft(fpiOft), "FPI not approved before");

        IRemoteAdmin admin = IRemoteAdmin(remoteAdmin);
        assertEq(admin.hopV2(), hop, "hop mismatch");

        // Exactly the composeData the builder encodes.
        bytes memory composeData = abi.encode(hop, abi.encodeCall(IHopV2.setApprovedOft, (fpiOft, false)));

        // Resolve before pranking - a view call here would otherwise consume the prank.
        bytes32 fraxtalMsig = admin.fraxtalMsig();
        address frxUsdOft = admin.frxUsdOft();

        vm.prank(hop);
        IHopComposer(remoteAdmin).hopCompose({
            _srcEid: FRAXTAL_EID,
            _sender: fraxtalMsig,
            _oft: frxUsdOft,
            _amount: 0,
            _data: composeData
        });

        assertFalse(IHopV2(hop).approvedOft(fpiOft), "FPI still approved after");
    }

    function test_ethereum() public {
        _assertRevokeLands({
            rpc: "https://eth-mainnet.public.blastapi.io",
            remoteAdmin: 0x181EBC9deA868ED8e5EeeAef7f767D43BF390dFa,
            hop: 0x0000006D38568b00B457580b734e0076C62de659,
            fpiOft: 0x9033BAD7aA130a2466060A2dA71fAe2219781B4b
        });
    }

    function test_base() public {
        _assertRevokeLands({
            rpc: "https://base-rpc.publicnode.com",
            remoteAdmin: 0x07dB789aD17573e5169eDEfe14df91CC305715AA,
            hop: 0x0000006D38568b00B457580b734e0076C62de659,
            fpiOft: 0xEEdd3A0DDDF977462A97C1F0eBb89C3fbe8D084B
        });
    }

    function test_arbitrum() public {
        _assertRevokeLands({
            rpc: "https://arb1.arbitrum.io/rpc",
            remoteAdmin: 0x954286118E93df807aB6f99aE0454f8710f0a8B9,
            hop: 0x0000006D38568b00B457580b734e0076C62de659,
            fpiOft: 0x90581eCa9469D8D7F5D3B60f4715027aDFCf7927
        });
    }
}
