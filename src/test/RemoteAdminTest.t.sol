// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import "frax-std/FraxTest.sol";
import { RemoteAdmin } from "src/contracts/RemoteAdmin.sol";
import { IHopComposer } from "src/contracts/interfaces/IHopComposer.sol";
import { HopMessage } from "src/contracts/interfaces/IHopV2.sol";

contract MockExecutorOptionsTarget {
    uint32 public lastEid;
    bytes public lastOptions;

    function setExecutorOptions(uint32 _eid, bytes memory _options) external {
        lastEid = _eid;
        lastOptions = _options;
    }
}

contract RemoteAdminTest is FraxTest {
    RemoteAdmin remoteAdmin;
    address frxUsdOft = address(0x96A394058E2b84A89bac9667B19661Ed003cF5D4);
    address hopV2 = address(0xe8Cd13de17CeC6FCd9dD5E0a1465Da240f951536);
    address fraxtalMsig = address(0x1234567890123456789012345678901234567890);

    uint32 constant FRAXTAL_EID = 30_255;
    uint32 constant ARBITRUM_EID = 30_110;
    uint32 constant TEMPO_EID = 30_410;
    uint128 constant TEMPO_RECEIVE_GAS = 2_500_000;

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

    function test_HopCompose_SetExecutorOptionsPayload_RoundTripsThroughHopMessage() public {
        MockExecutorOptionsTarget target = new MockExecutorOptionsTarget();
        bytes memory tempoOptions = abi.encodePacked(uint8(1), uint16(17), uint8(1), uint128(TEMPO_RECEIVE_GAS));
        bytes memory remoteCall = abi.encodeCall(
            MockExecutorOptionsTarget.setExecutorOptions,
            (TEMPO_EID, tempoOptions)
        );
        bytes memory remoteAdminData = abi.encode(address(target), remoteCall);

        HopMessage memory hopMessage = HopMessage({
            srcEid: FRAXTAL_EID,
            dstEid: TEMPO_EID,
            dstGas: 400_000,
            sender: bytes32(uint256(uint160(fraxtalMsig))),
            recipient: bytes32(uint256(uint160(address(remoteAdmin)))),
            data: remoteAdminData
        });

        HopMessage memory decodedHopMessage = abi.decode(abi.encode(hopMessage), (HopMessage));
        (address decodedTarget, bytes memory decodedCall) = abi.decode(decodedHopMessage.data, (address, bytes));

        assertEq(decodedTarget, address(target), "Target should survive HopMessage encoding");
        assertEq(decodedCall, remoteCall, "Nested call data should survive HopMessage encoding");

        vm.prank(hopV2);
        remoteAdmin.hopCompose(FRAXTAL_EID, decodedHopMessage.sender, frxUsdOft, 0, decodedHopMessage.data);

        assertEq(target.lastEid(), TEMPO_EID, "Executor options EID should match");
        assertEq(target.lastOptions(), tempoOptions, "Executor options bytes should match");
    }

    // Mock function for successful call
    function mockFunction() external pure returns (bool) {
        return true;
    }
}
