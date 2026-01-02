// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import "frax-std/FraxTest.sol";
import { RemoteHopV2 } from "src/contracts/hop/RemoteHopV2.sol";
import { FraxtalHopV2 } from "src/contracts/hop/FraxtalHopV2.sol";
import { HopMessage } from "src/contracts/interfaces/IHopV2.sol";
import { IHopComposer } from "src/contracts/interfaces/IHopComposer.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { OFTMsgCodec } from "@layerzerolabs/oft-evm/contracts/libs/OFTMsgCodec.sol";
import { OFTComposeMsgCodec } from "@layerzerolabs/oft-evm/contracts/libs/OFTComposeMsgCodec.sol";
import { deployRemoteHopV2 } from "src/script/hop/DeployRemoteHopV2.s.sol";

contract TestHopComposer is IHopComposer {
    event Composed(uint32 srcEid, bytes32 srcAddress, address oft, uint256 amount, bytes composeMsg);

    function hopCompose(
        uint32 _srcEid,
        bytes32 _srcAddress,
        address _oft,
        uint256 _amount,
        bytes memory _data
    ) external override {
        emit Composed(_srcEid, _srcAddress, _oft, _amount, _data);
    }
}

contract RemoteHopV2Test is FraxTest {
    RemoteHopV2 remoteHop;
    address proxyAdmin = vm.addr(0x1);
    address constant ENDPOINT = 0x1a44076050125825900e736c501f859c50fE728c;
    address constant EXECUTOR = 0x31CAe3B7fB82d847621859fb1585353c5720660D;
    address constant DVN = 0x2f55C492897526677C5B68fb199ea31E2c126416;
    address constant TREASURY = 0x532410B245eB41f24Ed1179BA0f6ffD94738AE70;
    address[] approvedOfts;

    uint32 constant FRAXTAL_EID = 30_255;
    uint32 constant ARBITRUM_EID = 30_110;

    address constant frxUSD = 0x80Eede496655FB9047dd39d9f418d5483ED600df;
    address fraxtalHop;

    function setUp() public {
        approvedOfts.push(0x80Eede496655FB9047dd39d9f418d5483ED600df);
        approvedOfts.push(0x5Bff88cA1442c2496f7E475E9e7786383Bc070c0);

        vm.createSelectFork(vm.envString("ARBITRUM_MAINNET_URL"), 316_670_752);
        fraxtalHop = address(0x123); // Mock Fraxtal hop address
        remoteHop = RemoteHopV2(
            deployRemoteHopV2(
                proxyAdmin,
                ARBITRUM_EID,
                ENDPOINT,
                address(0),
                OFTMsgCodec.addressToBytes32(fraxtalHop),
                2,
                EXECUTOR,
                DVN,
                TREASURY,
                approvedOfts
            )
        );

        // Fund the remote hop contract
        payable(address(remoteHop)).call{ value: 100 ether }("");
    }

    receive() external payable {}

    // ============ Initialization Tests ============

    function test_Initialization() public {
        assertEq(remoteHop.localEid(), ARBITRUM_EID, "Local EID should be set");
        assertEq(remoteHop.endpoint(), ENDPOINT, "Endpoint should be set");
        assertEq(remoteHop.numDVNs(), 2, "NumDVNs should be set");
        assertEq(remoteHop.EXECUTOR(), EXECUTOR, "Executor should be set");
        assertEq(remoteHop.DVN(), DVN, "DVN should be set");
        assertEq(remoteHop.TREASURY(), TREASURY, "Treasury should be set");
        assertTrue(remoteHop.approvedOft(approvedOfts[0]), "First OFT should be approved");
        assertTrue(remoteHop.approvedOft(approvedOfts[1]), "Second OFT should be approved");
        assertEq(
            remoteHop.remoteHop(FRAXTAL_EID),
            OFTMsgCodec.addressToBytes32(fraxtalHop),
            "Fraxtal hop should be set"
        );
    }

    function test_Initialization_HasDefaultAdminRole() public {
        assertTrue(
            remoteHop.hasRole(remoteHop.DEFAULT_ADMIN_ROLE(), address(this)),
            "Deployer should have DEFAULT_ADMIN_ROLE"
        );
    }

    // ============ SendOFT Tests ============

    function test_SendOFT_ToFraxtal() public {
        address oft = approvedOfts[0];
        deal(frxUSD, address(this), 1e18);
        IERC20(frxUSD).approve(address(remoteHop), 1e18);
        vm.deal(address(this), 1 ether);

        uint256 fee = remoteHop.quote(oft, FRAXTAL_EID, bytes32(uint256(uint160(address(this)))), 1e18, 0, "");
        remoteHop.sendOFT{ value: fee }(oft, FRAXTAL_EID, bytes32(uint256(uint160(address(this)))), 1e18, 0, "");
    }

    function test_SendOFT_WithData() public {
        address oft = approvedOfts[0];
        deal(frxUSD, address(this), 1e18);
        IERC20(frxUSD).approve(address(remoteHop), 1e18);
        vm.deal(address(this), 1 ether);

        bytes memory data = "Hello Fraxtal";
        uint256 fee = remoteHop.quote(oft, FRAXTAL_EID, bytes32(uint256(uint160(address(this)))), 1e18, 500_000, data);
        remoteHop.sendOFT{ value: fee }(
            oft,
            FRAXTAL_EID,
            bytes32(uint256(uint160(address(this)))),
            1e18,
            500_000,
            data
        );
    }

    function test_SendOFT_LocalTransfer() public {
        address oft = approvedOfts[0];
        address recipient = address(0x456);

        deal(frxUSD, address(this), 1e18);
        IERC20(frxUSD).approve(address(remoteHop), 1e18);

        uint256 fee = remoteHop.quote(oft, ARBITRUM_EID, bytes32(uint256(uint160(recipient))), 1e18, 0, "");
        assertEq(fee, 0, "Local transfer should have zero fee");

        remoteHop.sendOFT(oft, ARBITRUM_EID, bytes32(uint256(uint160(recipient))), 1e18, 0, "");
        assertEq(IERC20(frxUSD).balanceOf(recipient), 1e18, "Recipient should receive tokens");
    }

    function test_SendOFT_LocalTransferWithCompose() public {
        address oft = approvedOfts[0];
        TestHopComposer composer = new TestHopComposer();

        deal(frxUSD, address(this), 1e18);
        IERC20(frxUSD).approve(address(remoteHop), 1e18);

        bytes memory data = "test data";
        uint256 fee = remoteHop.quote(oft, ARBITRUM_EID, bytes32(uint256(uint160(address(composer)))), 1e18, 0, data);
        assertEq(fee, 0, "Local transfer should have zero fee");

        vm.expectEmit(true, true, true, true);
        emit TestHopComposer.Composed(ARBITRUM_EID, bytes32(uint256(uint160(address(this)))), oft, 1e18, data);
        remoteHop.sendOFT(oft, ARBITRUM_EID, bytes32(uint256(uint160(address(composer)))), 1e18, 0, data);

        assertEq(IERC20(frxUSD).balanceOf(address(composer)), 1e18, "Composer should receive tokens");
    }

    function test_SendOFT_WhenPaused() public {
        remoteHop.pauseOn();

        address oft = approvedOfts[0];
        deal(frxUSD, address(this), 1e18);
        IERC20(frxUSD).approve(address(remoteHop), 1e18);

        vm.expectRevert(abi.encodeWithSignature("HopPaused()"));
        remoteHop.sendOFT(oft, FRAXTAL_EID, bytes32(uint256(uint160(address(this)))), 1e18, 0, "");
    }

    function test_SendOFT_InvalidOFT() public {
        address invalidOft = address(0x999);

        vm.expectRevert(abi.encodeWithSignature("InvalidOFT()"));
        remoteHop.sendOFT(invalidOft, FRAXTAL_EID, bytes32(uint256(uint160(address(this)))), 1e18, 0, "");
    }

    function test_SendOFT_InsufficientFee() public {
        address oft = approvedOfts[0];
        deal(frxUSD, address(this), 1e18);
        IERC20(frxUSD).approve(address(remoteHop), 1e18);

        vm.expectRevert(abi.encodeWithSignature("InsufficientFee()"));
        remoteHop.sendOFT{ value: 0 }(oft, FRAXTAL_EID, bytes32(uint256(uint160(address(this)))), 1e18, 0, "");
    }

    function test_SendOFT_RefundsExcessFee() public {
        address oft = approvedOfts[0];
        deal(frxUSD, address(this), 1e18);
        IERC20(frxUSD).approve(address(remoteHop), 1e18);
        vm.deal(address(this), 10 ether);

        uint256 fee = remoteHop.quote(oft, FRAXTAL_EID, bytes32(uint256(uint160(address(this)))), 1e18, 0, "");
        uint256 balanceBefore = address(this).balance;

        remoteHop.sendOFT{ value: fee + 1 ether }(
            oft,
            FRAXTAL_EID,
            bytes32(uint256(uint160(address(this)))),
            1e18,
            0,
            ""
        );

        assertEq(address(this).balance, balanceBefore - fee, "Excess fee should be refunded");
    }

    // ============ LzCompose Tests ============

    function test_LzCompose_SendLocal_WithoutData() public {
        address oft = approvedOfts[0];
        address recipient = address(0x456);

        deal(frxUSD, address(remoteHop), 1e18);

        bytes memory composeMsg = abi.encode(
            HopMessage({
                srcEid: FRAXTAL_EID,
                dstEid: ARBITRUM_EID,
                dstGas: 0,
                sender: bytes32(uint256(uint160(address(0x123)))),
                recipient: bytes32(uint256(uint160(recipient))),
                data: ""
            })
        );
        composeMsg = abi.encodePacked(OFTMsgCodec.addressToBytes32(fraxtalHop), composeMsg);
        bytes memory message = OFTComposeMsgCodec.encode(0, FRAXTAL_EID, 1e18, composeMsg);

        vm.prank(ENDPOINT);
        remoteHop.lzCompose(oft, bytes32(0), message, address(0), "");

        assertEq(IERC20(frxUSD).balanceOf(recipient), 1e18, "Recipient should receive tokens");
    }

    function test_LzCompose_SendLocal_WithData() public {
        address oft = approvedOfts[0];
        TestHopComposer composer = new TestHopComposer();

        deal(frxUSD, address(remoteHop), 1e18);

        bytes memory data = "Hello Remote";
        bytes memory composeMsg = abi.encode(
            HopMessage({
                srcEid: FRAXTAL_EID,
                dstEid: ARBITRUM_EID,
                dstGas: 0,
                sender: bytes32(uint256(uint160(address(0x123)))),
                recipient: bytes32(uint256(uint160(address(composer)))),
                data: data
            })
        );
        composeMsg = abi.encodePacked(OFTMsgCodec.addressToBytes32(fraxtalHop), composeMsg);
        bytes memory message = OFTComposeMsgCodec.encode(0, FRAXTAL_EID, 1e18, composeMsg);

        vm.expectEmit(true, true, true, true);
        emit TestHopComposer.Composed(FRAXTAL_EID, bytes32(uint256(uint160(address(0x123)))), oft, 1e18, data);

        vm.prank(ENDPOINT);
        remoteHop.lzCompose(oft, bytes32(0), message, address(0), "");

        assertEq(IERC20(frxUSD).balanceOf(address(composer)), 1e18, "Composer should receive tokens");
    }

    function test_LzCompose_UntrustedMessage() public {
        address oft = approvedOfts[0];
        address untrustedSender = address(0x789);
        address recipient = address(0x456);

        deal(frxUSD, address(remoteHop), 1e18);

        bytes memory composeMsg = abi.encode(
            HopMessage({
                srcEid: 999, // This will be overwritten
                dstEid: ARBITRUM_EID,
                dstGas: 0,
                sender: bytes32(uint256(uint160(address(0xbad)))), // This will be overwritten
                recipient: bytes32(uint256(uint160(recipient))),
                data: ""
            })
        );
        composeMsg = abi.encodePacked(OFTMsgCodec.addressToBytes32(untrustedSender), composeMsg);
        bytes memory message = OFTComposeMsgCodec.encode(0, FRAXTAL_EID, 1e18, composeMsg);

        vm.prank(ENDPOINT);
        remoteHop.lzCompose(oft, bytes32(0), message, address(0), "");

        assertEq(IERC20(frxUSD).balanceOf(recipient), 1e18, "Recipient should still receive tokens");
    }

    function test_LzCompose_DuplicateMessage() public {
        address oft = approvedOfts[0];
        address recipient = address(0x456);

        deal(frxUSD, address(remoteHop), 2e18);

        bytes memory composeMsg = abi.encode(
            HopMessage({
                srcEid: FRAXTAL_EID,
                dstEid: ARBITRUM_EID,
                dstGas: 0,
                sender: bytes32(uint256(uint160(address(0x123)))),
                recipient: bytes32(uint256(uint160(recipient))),
                data: ""
            })
        );
        composeMsg = abi.encodePacked(OFTMsgCodec.addressToBytes32(fraxtalHop), composeMsg);
        bytes memory message = OFTComposeMsgCodec.encode(0, FRAXTAL_EID, 1e18, composeMsg);

        vm.startPrank(ENDPOINT);
        remoteHop.lzCompose(oft, bytes32(0), message, address(0), "");
        assertEq(IERC20(frxUSD).balanceOf(recipient), 1e18, "First message should process");

        // Second call with same message should be ignored
        remoteHop.lzCompose(oft, bytes32(0), message, address(0), "");
        assertEq(IERC20(frxUSD).balanceOf(recipient), 1e18, "Duplicate message should be ignored");
        vm.stopPrank();
    }

    function test_LzCompose_NotEndpoint() public {
        address oft = approvedOfts[0];
        bytes memory message = _createComposeMessage(oft, 1e18);

        vm.expectRevert(abi.encodeWithSignature("NotEndpoint()"));
        remoteHop.lzCompose(oft, bytes32(0), message, address(0), "");
    }

    function test_LzCompose_InvalidOFT() public {
        address invalidOft = address(0x999);
        bytes memory message = _createComposeMessage(invalidOft, 1e18);

        vm.prank(ENDPOINT);
        vm.expectRevert(abi.encodeWithSignature("InvalidOFT()"));
        remoteHop.lzCompose(invalidOft, bytes32(0), message, address(0), "");
    }

    // ============ Admin Function Tests ============

    function test_SetFraxtalHop() public {
        address newFraxtalHop = address(0x999);
        remoteHop.setRemoteHop(FRAXTAL_EID, newFraxtalHop);
        assertEq(remoteHop.remoteHop(FRAXTAL_EID), bytes32(uint256(uint160(newFraxtalHop))));
    }

    // ============ Quote Tests ============

    function test_Quote_LocalDestination() public {
        address oft = approvedOfts[0];
        uint256 fee = remoteHop.quote(oft, ARBITRUM_EID, bytes32(uint256(uint160(address(this)))), 1e18, 0, "");
        assertEq(fee, 0, "Local transfers should have zero fee");
    }

    function test_Quote_RemoteDestination() public {
        address oft = approvedOfts[0];
        uint256 fee = remoteHop.quote(oft, FRAXTAL_EID, bytes32(uint256(uint160(address(this)))), 1e18, 0, "");
        assertTrue(fee > 0, "Remote transfers should have non-zero fee");
    }

    function test_Quote_WithData() public {
        address oft = approvedOfts[0];
        bytes memory data = "test data";
        uint256 fee = remoteHop.quote(oft, FRAXTAL_EID, bytes32(uint256(uint160(address(this)))), 1e18, 500_000, data);
        assertTrue(fee > 0, "Remote transfers with data should have non-zero fee");
    }

    // ============ RemoveDust Tests ============

    function test_RemoveDust() public {
        address oft = approvedOfts[0];
        uint256 amount = 1.123_456_789_123_456_789e18;
        uint256 cleaned = remoteHop.removeDust(oft, amount);
        assertTrue(cleaned <= amount, "Cleaned amount should be <= original");
    }

    // ============ Access Control Tests ============

    function test_PauseOn() public {
        assertFalse(remoteHop.paused());
        remoteHop.pauseOn();
        assertTrue(remoteHop.paused());
    }

    function test_PauseOff() public {
        remoteHop.pauseOn();
        remoteHop.pauseOff();
        assertFalse(remoteHop.paused());
    }

    function test_SetApprovedOft() public {
        address newOft = address(0x888);
        assertFalse(remoteHop.approvedOft(newOft));

        remoteHop.setApprovedOft(newOft, true);
        assertTrue(remoteHop.approvedOft(newOft));
    }

    // ============ Helper Functions ============

    function _createComposeMessage(address oft, uint256 amount) internal view returns (bytes memory) {
        bytes memory composeMsg = abi.encode(
            HopMessage({
                srcEid: FRAXTAL_EID,
                dstEid: ARBITRUM_EID,
                dstGas: 0,
                sender: bytes32(uint256(uint160(address(0x123)))),
                recipient: bytes32(uint256(uint160(address(this)))),
                data: ""
            })
        );
        composeMsg = abi.encodePacked(OFTMsgCodec.addressToBytes32(fraxtalHop), composeMsg);
        return OFTComposeMsgCodec.encode(0, FRAXTAL_EID, amount, composeMsg);
    }
}
