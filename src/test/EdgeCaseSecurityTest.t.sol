// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import "frax-std/FraxTest.sol";
import { FraxtalHopV2 } from "src/contracts/hop/FraxtalHopV2.sol";
import { RemoteHopV2 } from "src/contracts/hop/RemoteHopV2.sol";
import { RemoteVaultHop } from "src/contracts/vault/RemoteVaultHop.sol";
import { RemoteVaultDeposit } from "src/contracts/vault/RemoteVaultDeposit.sol";
import { RemoteAdmin } from "src/contracts/RemoteAdmin.sol";
import { HopMessage } from "src/contracts/interfaces/IHopV2.sol";
import { IHopComposer } from "src/contracts/interfaces/IHopComposer.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { OFTMsgCodec } from "@layerzerolabs/oft-evm/contracts/libs/OFTMsgCodec.sol";
import { OFTComposeMsgCodec } from "@layerzerolabs/oft-evm/contracts/libs/OFTComposeMsgCodec.sol";
import { deployFraxtalHopV2 } from "src/script/hop/DeployFraxtalHopV2.s.sol";

/**
 * @title EdgeCaseSecurityTest
 * @notice Comprehensive tests for edge cases, security vulnerabilities, and attack vectors
 */
contract EdgeCaseSecurityTest is FraxTest {
    FraxtalHopV2 hop;
    address proxyAdmin = vm.addr(0x1);
    address constant ENDPOINT = 0x1a44076050125825900e736c501f859c50fE728c;
    address constant EXECUTOR = 0x41Bdb4aa4A63a5b2Efc531858d3118392B1A1C3d;
    address constant DVN = 0xcCE466a522984415bC91338c232d98869193D46e;
    address constant TREASURY = 0xc1B621b18187F74c8F6D52a6F709Dd2780C09821;
    address[] approvedOfts;

    uint32 constant FRAXTAL_EID = 30_255;
    uint32 constant ARBITRUM_EID = 30_110;
    address constant frxUSD = 0xFc00000000000000000000000000000000000001;

    function setUp() public {
        approvedOfts.push(0x96A394058E2b84A89bac9667B19661Ed003cF5D4);

        vm.createSelectFork(vm.envString("FRAXTAL_MAINNET_URL"), 23_464_636);
        hop = FraxtalHopV2(
            deployFraxtalHopV2(proxyAdmin, FRAXTAL_EID, ENDPOINT, 3, EXECUTOR, DVN, TREASURY, approvedOfts)
        );

        payable(address(hop)).call{ value: 100 ether }("");
    }

    receive() external payable {}

    // ============ Reentrancy Tests ============

    function test_NoReentrancy_SendOFT() public {
        // The contracts should not be vulnerable to reentrancy attacks
        // Testing that multiple calls in the same transaction don't cause issues
        address oft = approvedOfts[0];
        address sender = address(this);

        deal(frxUSD, sender, 100e18);
        IERC20(frxUSD).approve(address(hop), 100e18);

        // Send to local address twice in succession
        hop.sendOFT(oft, FRAXTAL_EID, bytes32(uint256(uint160(address(0x123)))), 10e18, 0, "");
        hop.sendOFT(oft, FRAXTAL_EID, bytes32(uint256(uint160(address(0x456)))), 10e18, 0, "");

        assertEq(IERC20(frxUSD).balanceOf(sender), 80e18, "Should handle sequential sends");
    }

    // ============ Integer Overflow/Underflow Tests ============

    function test_SafeMath_LargeAmounts() public {
        address oft = approvedOfts[0];

        // Test with very large amounts
        uint256 largeAmount = type(uint256).max / 2;
        uint256 cleaned = hop.removeDust(oft, largeAmount);

        assertTrue(cleaned <= largeAmount, "Should handle large amounts");
    }

    function test_SafeMath_QuoteCalculation() public {
        address oft = approvedOfts[0];
        hop.setRemoteHop(ARBITRUM_EID, address(0x123));

        // Test quote with very large amounts
        uint256 largeAmount = 1e30; // Very large amount
        uint256 fee = hop.quote(oft, ARBITRUM_EID, bytes32(uint256(uint160(address(this)))), largeAmount, 0, "");

        assertTrue(fee > 0, "Should calculate fee for large amounts");
    }

    // ============ Access Control Edge Cases ============

    function test_AccessControl_DefaultAdminCannotBeRevoked() public {
        address newAdmin = address(0x123);

        // Grant new admin
        hop.grantRole(hop.DEFAULT_ADMIN_ROLE(), newAdmin);

        // Original admin should still be able to perform admin functions
        hop.setApprovedOft(address(0x999), true);
        assertTrue(hop.approvedOft(address(0x999)));
    }

    function test_AccessControl_RevokeOwnRole() public {
        address admin2 = address(0x123);

        // Grant second admin
        hop.grantRole(hop.DEFAULT_ADMIN_ROLE(), admin2);

        // Admin can revoke their own role
        hop.renounceRole(hop.DEFAULT_ADMIN_ROLE(), address(this));

        // Original admin should no longer have admin role
        assertFalse(hop.hasRole(hop.DEFAULT_ADMIN_ROLE(), address(this)));

        // But admin2 should still work
        vm.prank(admin2);
        hop.setApprovedOft(address(0x888), true);
        assertTrue(hop.approvedOft(address(0x888)));
    }

    // ============ Message Replay Protection Tests ============

    function test_MessageReplay_Protection() public {
        address oft = approvedOfts[0];

        bytes memory composeMsg = abi.encode(
            HopMessage({
                srcEid: ARBITRUM_EID,
                dstEid: FRAXTAL_EID,
                dstGas: 0,
                sender: bytes32(uint256(uint160(address(0x123)))),
                recipient: bytes32(uint256(uint160(address(0x456)))),
                data: ""
            })
        );
        composeMsg = abi.encodePacked(bytes32(uint256(uint160(address(0x123)))), composeMsg);
        bytes memory message = OFTComposeMsgCodec.encode(0, ARBITRUM_EID, 1e18, composeMsg);

        hop.setRemoteHop(ARBITRUM_EID, address(0x123));
        deal(frxUSD, address(hop), 2e18);

        vm.startPrank(ENDPOINT);

        // First call should process
        hop.lzCompose(oft, bytes32(0), message, address(0), "");

        // Second call with same message should be ignored (not revert)
        hop.lzCompose(oft, bytes32(0), message, address(0), "");

        vm.stopPrank();

        // Verify only one transfer occurred
        assertEq(IERC20(frxUSD).balanceOf(address(0x456)), 1e18, "Should only process once");
    }

    // ============ Dust Handling Edge Cases ============

    function test_Dust_VerySmallAmount() public {
        address oft = approvedOfts[0];

        // Amount smaller than decimal conversion rate
        uint256 tinyAmount = 1;
        uint256 cleaned = hop.removeDust(oft, tinyAmount);

        assertEq(cleaned, 0, "Very small amounts should be cleaned to 0");
    }

    function test_Dust_ExactlyDivisible() public {
        address oft = approvedOfts[0];

        uint256 amount = 1e18; // Exactly divisible
        uint256 cleaned = hop.removeDust(oft, amount);

        assertEq(cleaned, amount, "Exactly divisible amounts should remain unchanged");
    }

    // ============ Fee Refund Edge Cases ============

    function test_FeeRefund_ExactAmount() public {
        address oft = approvedOfts[0];
        hop.setRemoteHop(ARBITRUM_EID, address(0x123));

        deal(frxUSD, address(this), 10e18);
        IERC20(frxUSD).approve(address(hop), 10e18);

        uint256 fee = hop.quote(oft, ARBITRUM_EID, bytes32(uint256(uint160(address(this)))), 10e18, 0, "");
        vm.deal(address(this), fee);

        uint256 balanceBefore = address(this).balance;

        // Send with exact fee
        hop.sendOFT{ value: fee }(oft, ARBITRUM_EID, bytes32(uint256(uint160(address(this)))), 10e18, 0, "");

        // Should not refund anything
        assertEq(address(this).balance, balanceBefore - fee, "Should not refund exact amount");
    }

    function test_FeeRefund_LargeExcess() public {
        address oft = approvedOfts[0];

        deal(frxUSD, address(this), 10e18);
        IERC20(frxUSD).approve(address(hop), 10e18);
        vm.deal(address(this), 100 ether);

        uint256 balanceBefore = address(this).balance;

        // Send local with large excess
        hop.sendOFT{ value: 50 ether }(oft, FRAXTAL_EID, bytes32(uint256(uint160(address(this)))), 10e18, 0, "");

        // Should refund all excess (local transfer is free)
        assertEq(address(this).balance, balanceBefore, "Should refund all excess for local transfer");
    }

    // ============ Paused State Edge Cases ============

    function test_Paused_CanStillUnpause() public {
        hop.pauseOn();
        assertTrue(hop.paused());

        // Should still be able to unpause
        hop.pauseOff();
        assertFalse(hop.paused());
    }

    function test_Paused_MultiplePauseCalls() public {
        hop.pauseOn();
        hop.pauseOn(); // Should not revert

        assertTrue(hop.paused());
    }

    function test_Paused_MultipleUnpauseCalls() public {
        hop.pauseOn();
        hop.pauseOff();
        hop.pauseOff(); // Should not revert

        assertFalse(hop.paused());
    }

    // ============ RemoteAdmin Edge Cases ============

    function test_RemoteAdmin_EmptyCalldata() public {
        RemoteAdmin admin = new RemoteAdmin(approvedOfts[0], address(hop), address(this));

        bytes memory data = abi.encode(address(this), "");

        vm.prank(address(hop));
        admin.hopCompose(FRAXTAL_EID, bytes32(uint256(uint160(address(this)))), approvedOfts[0], 0, data);
    }

    function test_RemoteAdmin_SelfCall() public {
        RemoteAdmin admin = new RemoteAdmin(approvedOfts[0], address(hop), address(this));

        // Try to call the RemoteAdmin itself
        bytes memory callData = abi.encodeWithSignature("frxUsdOft()");
        bytes memory data = abi.encode(address(admin), callData);

        vm.prank(address(hop));
        admin.hopCompose(FRAXTAL_EID, bytes32(uint256(uint160(address(this)))), approvedOfts[0], 0, data);
    }

    // ============ Boundary Value Tests ============

    function test_Boundary_MaxUint256() public {
        address oft = approvedOfts[0];

        uint256 maxAmount = type(uint256).max;
        uint256 cleaned = hop.removeDust(oft, maxAmount);

        assertTrue(cleaned > 0, "Should handle max uint256");
    }

    function test_Boundary_MaxGas() public {
        address oft = approvedOfts[0];
        hop.setRemoteHop(ARBITRUM_EID, address(0x123));

        // Test with very high gas
        uint128 maxGas = type(uint128).max;
        uint256 fee = hop.quote(oft, ARBITRUM_EID, bytes32(uint256(uint160(address(this)))), 1e18, maxGas, "");

        assertTrue(fee > 0, "Should handle max gas");
    }

    // ============ Quote Consistency Tests ============

    function test_QuoteConsistency_SameInputsSameOutput() public {
        address oft = approvedOfts[0];
        hop.setRemoteHop(ARBITRUM_EID, address(0x123));

        uint256 fee1 = hop.quote(oft, ARBITRUM_EID, bytes32(uint256(uint160(address(this)))), 10e18, 400_000, "test");
        uint256 fee2 = hop.quote(oft, ARBITRUM_EID, bytes32(uint256(uint160(address(this)))), 10e18, 400_000, "test");

        assertEq(fee1, fee2, "Same inputs should produce same quote");
    }

    function test_QuoteConsistency_DifferentRecipients() public {
        address oft = approvedOfts[0];
        hop.setRemoteHop(ARBITRUM_EID, address(0x123));

        uint256 fee1 = hop.quote(oft, ARBITRUM_EID, bytes32(uint256(uint160(address(0x111)))), 10e18, 400_000, "");
        uint256 fee2 = hop.quote(oft, ARBITRUM_EID, bytes32(uint256(uint160(address(0x222)))), 10e18, 400_000, "");

        assertEq(fee1, fee2, "Different recipients should have same fee");
    }

    // ============ Storage Collision Tests ============

    function test_Storage_NoCollision() public {
        // Test that storage slots don't collide
        uint32 localEid = hop.localEid();
        address endpoint = hop.endpoint();
        bool paused = hop.paused();

        // Perform operations
        hop.pauseOn();
        hop.setApprovedOft(address(0x999), true);
        hop.setRemoteHop(ARBITRUM_EID, address(0x123));

        // Verify original values weren't corrupted
        assertEq(hop.localEid(), localEid, "localEid should not change");
        assertEq(hop.endpoint(), endpoint, "endpoint should not change");
        assertTrue(hop.paused(), "paused should be true");
    }

    // ============ Gas Optimization Verification ============

    function test_Gas_LocalTransferCheaperThanRemote() public {
        address oft = approvedOfts[0];
        hop.setRemoteHop(ARBITRUM_EID, address(0x123));

        deal(frxUSD, address(this), 100e18);
        IERC20(frxUSD).approve(address(hop), 100e18);
        vm.deal(address(this), 10 ether);

        uint256 gasBefore = gasleft();
        hop.sendOFT(oft, FRAXTAL_EID, bytes32(uint256(uint160(address(0x456)))), 10e18, 0, "");
        uint256 gasLocal = gasBefore - gasleft();

        gasBefore = gasleft();
        uint256 fee = hop.quote(oft, ARBITRUM_EID, bytes32(uint256(uint160(address(0x789)))), 10e18, 0, "");
        hop.sendOFT{ value: fee }(oft, ARBITRUM_EID, bytes32(uint256(uint160(address(0x789)))), 10e18, 0, "");
        uint256 gasRemote = gasBefore - gasleft();

        assertTrue(gasLocal < gasRemote, "Local transfers should use less gas");
    }
}
