// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import "frax-std/FraxTest.sol";
import { RemoteAdmin } from "src/contracts/RemoteAdmin.sol";
import { IHopComposer } from "src/contracts/interfaces/IHopComposer.sol";

contract RemoteAdminTest is FraxTest {
    RemoteAdmin remoteAdmin;
    address frxUsdOft = address(0x96A394058E2b84A89bac9667B19661Ed003cF5D4);
    address hopV2 = address(0xe8Cd13de17CeC6FCd9dD5E0a1465Da240f951536);
    address fraxtalMsig = address(0x1234567890123456789012345678901234567890);

    uint32 constant FRAXTAL_EID = 30_255;
    uint32 constant ARBITRUM_EID = 30_110;

    function setUp() public {
        remoteAdmin = new RemoteAdmin(frxUsdOft, hopV2, fraxtalMsig);
    }

    // Test constructor initialization
    function test_Constructor() public {
        assertEq(remoteAdmin.frxUsdOft(), frxUsdOft, "frxUsdOft should be set correctly");
        assertEq(remoteAdmin.hopV2(), hopV2, "hopV2 should be set correctly");
        assertEq(
            remoteAdmin.fraxtalMsig(),
            bytes32(uint256(uint160(fraxtalMsig))),
            "fraxtalMsig should be set correctly"
        );
    }

    // Test successful hopCompose execution
    function test_HopCompose_Success() public {
        address targetContract = address(this);
        bytes memory callData = abi.encodeWithSignature("mockFunction()");
        bytes memory data = abi.encode(targetContract, callData);

        vm.prank(hopV2);
        remoteAdmin.hopCompose(FRAXTAL_EID, bytes32(uint256(uint160(fraxtalMsig))), frxUsdOft, 100e18, data);
    }

    // Test hopCompose with unauthorized caller (not hopV2)
    function test_HopCompose_NotAuthorized_WrongCaller() public {
        address wrongCaller = address(0xdead);
        bytes memory data = abi.encode(address(this), "");

        vm.prank(wrongCaller);
        vm.expectRevert(RemoteAdmin.NotAuthorized.selector);
        remoteAdmin.hopCompose(FRAXTAL_EID, bytes32(uint256(uint160(fraxtalMsig))), frxUsdOft, 100e18, data);
    }

    // Test hopCompose with unauthorized sender
    function test_HopCompose_NotAuthorized_WrongSender() public {
        address wrongSender = address(0xbeef);
        bytes memory data = abi.encode(address(this), "");

        vm.prank(hopV2);
        vm.expectRevert(RemoteAdmin.NotAuthorized.selector);
        remoteAdmin.hopCompose(FRAXTAL_EID, bytes32(uint256(uint160(wrongSender))), frxUsdOft, 100e18, data);
    }

    // Test hopCompose with invalid source EID
    function test_HopCompose_InvalidSourceEid() public {
        bytes memory data = abi.encode(address(this), "");

        vm.prank(hopV2);
        vm.expectRevert(RemoteAdmin.InvalidSourceEid.selector);
        remoteAdmin.hopCompose(ARBITRUM_EID, bytes32(uint256(uint160(fraxtalMsig))), frxUsdOft, 100e18, data);
    }

    // Test hopCompose with invalid OFT
    function test_HopCompose_InvalidOFT() public {
        address wrongOft = address(0xcafe);
        bytes memory data = abi.encode(address(this), "");

        vm.prank(hopV2);
        vm.expectRevert(RemoteAdmin.InvalidOFT.selector);
        remoteAdmin.hopCompose(FRAXTAL_EID, bytes32(uint256(uint160(fraxtalMsig))), wrongOft, 100e18, data);
    }

    // Test hopCompose with failed remote call
    function test_HopCompose_FailedRemoteCall() public {
        address targetContract = address(this); // Invalid contract
        bytes memory callData = abi.encodeWithSignature("nonexistentFunction()");
        bytes memory data = abi.encode(targetContract, callData);

        vm.prank(hopV2);
        vm.expectRevert(RemoteAdmin.FailedRemoteCall.selector);
        remoteAdmin.hopCompose(FRAXTAL_EID, bytes32(uint256(uint160(fraxtalMsig))), frxUsdOft, 100e18, data);
    }

    // Test hopCompose with zero amount
    function test_HopCompose_ZeroAmount() public {
        address targetContract = address(this);
        bytes memory callData = abi.encodeWithSignature("mockFunction()");
        bytes memory data = abi.encode(targetContract, callData);

        vm.prank(hopV2);
        remoteAdmin.hopCompose(FRAXTAL_EID, bytes32(uint256(uint160(fraxtalMsig))), frxUsdOft, 0, data);
    }

    // Mock function for successful call
    function mockFunction() external pure returns (bool) {
        return true;
    }
}
