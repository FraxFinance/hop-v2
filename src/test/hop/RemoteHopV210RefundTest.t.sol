// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import { Test } from "forge-std/Test.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { OFTMsgCodec } from "@layerzerolabs/oft-evm/contracts/libs/OFTMsgCodec.sol";

import { RemoteHopV201 } from "src/contracts/hop/RemoteHopV201.sol";
import { HopActions } from "src/contracts/libraries/HopActions.sol";
import { deployRemoteHopV201 } from "src/script/hop/upgrade/DeployRemoteHopV201.s.sol";

/// @notice Hop 2.1.0 spoke behaviour on an Arbitrum fork: the refund address and the mint/redeem tag's routing
///         and gas budget. Run with ARBITRUM_MAINNET_URL set.
contract RemoteHopV210RefundTest is Test {
    RemoteHopV201 remoteHop;
    address proxyAdmin = vm.addr(0x1);
    address constant DEPLOYER = 0x54F9b12743A7DeeC0ea48721683cbebedC6E17bC;
    address constant ENDPOINT = 0x1a44076050125825900e736c501f859c50fE728c;
    address constant EXECUTOR = 0x31CAe3B7fB82d847621859fb1585353c5720660D;
    address constant DVN = 0x2f55C492897526677C5B68fb199ea31E2c126416;
    address constant TREASURY = 0x532410B245eB41f24Ed1179BA0f6ffD94738AE70;
    address constant frxUSD = 0x80Eede496655FB9047dd39d9f418d5483ED600df; // mintable OFT: token() == itself
    address constant sfrxUSD = 0x5Bff88cA1442c2496f7E475E9e7786383Bc070c0;

    uint32 constant FRAXTAL_EID = 30_255;
    uint32 constant ARBITRUM_EID = 30_110;
    uint32 constant ETHEREUM_EID = 30_101;
    bytes constant TAG = hex"d71e9971";

    address user = makeAddr("user");
    address refundTo = makeAddr("refundTo");
    bytes32 userB32;

    receive() external payable {}

    function setUp() public {
        userB32 = OFTMsgCodec.addressToBytes32(user);
        address[] memory approvedOfts = new address[](2);
        approvedOfts[0] = frxUSD;
        approvedOfts[1] = sfrxUSD;

        vm.createSelectFork(vm.envString("ARBITRUM_MAINNET_URL"), 316_670_752);
        vm.startPrank(DEPLOYER);
        remoteHop = RemoteHopV201(
            deployRemoteHopV201(
                proxyAdmin,
                ARBITRUM_EID,
                ENDPOINT,
                OFTMsgCodec.addressToBytes32(address(0x123)),
                2,
                EXECUTOR,
                DVN,
                TREASURY,
                approvedOfts
            )
        );
        remoteHop.grantRole(bytes32(0), address(this));
        vm.stopPrank();

        deal(frxUSD, address(this), 100e18);
        IERC20(frxUSD).approve(address(remoteHop), type(uint256).max);

        // Live spokes hold retained hop fees; fund this one so an underpaid send reaches the msg.value check
        // instead of running the hop out of balance mid-send.
        vm.deal(address(remoteHop), 10 ether);
    }

    function test_Version() public view {
        assertEq(remoteHop.version(), "2.1.0");
    }

    // ───────────────────────────── refund address ─────────────────────────────

    function test_SendOFT_RefundTo() public {
        uint256 fee = remoteHop.quote(frxUSD, FRAXTAL_EID, userB32, 1e18, 0, "");
        uint256 balBefore = address(this).balance;

        remoteHop.sendOFT{ value: fee + 0.3 ether }(frxUSD, FRAXTAL_EID, userB32, 1e18, 0, "", refundTo);

        assertEq(refundTo.balance, 0.3 ether, "excess to refundTo");
        assertEq(balBefore - address(this).balance, fee + 0.3 ether, "caller paid fee plus the excess that moved");
        assertEq(IERC20(frxUSD).balanceOf(address(this)), 99e18);
    }

    function test_SendOFT_SixArg_RefundsCaller() public {
        uint256 fee = remoteHop.quote(frxUSD, FRAXTAL_EID, userB32, 1e18, 0, "");
        uint256 balBefore = address(this).balance;

        remoteHop.sendOFT{ value: fee + 0.3 ether }(frxUSD, FRAXTAL_EID, userB32, 1e18, 0, "");

        assertEq(balBefore - address(this).balance, fee, "only the fee is kept");
        assertEq(refundTo.balance, 0);
    }

    function test_SendOFT_FourArg_RefundsCaller() public {
        uint256 fee = remoteHop.quote(frxUSD, FRAXTAL_EID, userB32, 1e18, 0, "");
        uint256 balBefore = address(this).balance;
        remoteHop.sendOFT{ value: fee + 0.3 ether }(frxUSD, FRAXTAL_EID, userB32, 1e18);
        assertEq(balBefore - address(this).balance, fee);
    }

    function test_SendOFT_ExactQuote_NoRefund() public {
        uint256 fee = remoteHop.quote(frxUSD, FRAXTAL_EID, userB32, 1e18, 0, "");
        remoteHop.sendOFT{ value: fee }(frxUSD, FRAXTAL_EID, userB32, 1e18, 0, "", refundTo);
        assertEq(refundTo.balance, 0, "same-transaction quote leaves nothing to refund");
    }

    function test_SendOFT_ZeroRefundTo_Reverts() public {
        vm.expectRevert(abi.encodeWithSignature("ZeroRefundAddress()"));
        remoteHop.sendOFT{ value: 1 ether }(frxUSD, FRAXTAL_EID, userB32, 1e18, 0, "", address(0));
        assertEq(IERC20(frxUSD).balanceOf(address(this)), 100e18, "nothing pulled");
    }

    function test_SendOFT_RefundTo_NonPayable_Reverts() public {
        uint256 fee = remoteHop.quote(frxUSD, FRAXTAL_EID, userB32, 1e18, 0, "");
        vm.expectRevert(abi.encodeWithSignature("RefundFailed()"));
        remoteHop.sendOFT{ value: fee + 1 }(frxUSD, FRAXTAL_EID, userB32, 1e18, 0, "", frxUSD);
    }

    function test_SendOFT_InsufficientFee_Reverts() public {
        uint256 fee = remoteHop.quote(frxUSD, FRAXTAL_EID, userB32, 1e18, 0, "");
        vm.expectRevert(abi.encodeWithSignature("InsufficientFee()"));
        remoteHop.sendOFT{ value: fee - 1 }(frxUSD, FRAXTAL_EID, userB32, 1e18, 0, "", refundTo);
    }

    // ───────────────────────────── mint/redeem tag ─────────────────────────────

    function test_Quote_Tag_BooksHubComposeGas() public view {
        // same destination, same message size: the tag books 1.5M compose gas on Fraxtal, a 4-byte non-tag 1M
        uint256 tagged = remoteHop.quote(frxUSD, FRAXTAL_EID, userB32, 1e18, 0, TAG);
        uint256 other = remoteHop.quote(frxUSD, FRAXTAL_EID, userB32, 1e18, 0, hex"d71e9972");
        assertGt(tagged, other, "tagged message pays for the larger hub budget");
        assertTrue(HopActions.isMintRedeem(TAG));
        assertFalse(HopActions.isMintRedeem(hex"d71e9972"));
        assertFalse(HopActions.isMintRedeem(abi.encode(bytes4(TAG))));
    }

    function test_Quote_Tag_SameChain_IsARoundTrip() public view {
        // untagged A -> A is a free local transfer; tagged A -> A travels to Fraxtal and back and is priced as such
        assertEq(remoteHop.quote(frxUSD, ARBITRUM_EID, userB32, 1e18, 0, ""), 0);
        uint256 roundTrip = remoteHop.quote(frxUSD, ARBITRUM_EID, userB32, 1e18, 0, TAG);
        uint256 oneLeg = remoteHop.quote(frxUSD, FRAXTAL_EID, userB32, 1e18, 0, TAG);
        assertGt(roundTrip, oneLeg, "return leg priced in via quoteHop(own eid)");
        assertEq(roundTrip - oneLeg, remoteHop.quoteHop(ARBITRUM_EID, 0, TAG));
    }

    function test_SendOFT_Tag_SameChain_GoesThroughFraxtal() public {
        uint256 fee = remoteHop.quote(frxUSD, ARBITRUM_EID, userB32, 1e18, 0, TAG);
        uint256 hopBalBefore = IERC20(frxUSD).balanceOf(address(remoteHop));
        uint256 hopNativeBefore = address(remoteHop).balance;

        remoteHop.sendOFT{ value: fee }(frxUSD, ARBITRUM_EID, userB32, 1e18, 0, TAG, refundTo);

        assertEq(IERC20(frxUSD).balanceOf(user), 0, "not delivered locally");
        assertEq(IERC20(frxUSD).balanceOf(address(remoteHop)), hopBalBefore, "burned by the OFT send, not parked");
        assertEq(IERC20(frxUSD).balanceOf(address(this)), 99e18);
        assertEq(
            address(remoteHop).balance - hopNativeBefore,
            remoteHop.quoteHop(ARBITRUM_EID, 0, TAG),
            "return-leg fee retained on the spoke"
        );
    }

    function test_SendOFT_Untagged_SameChain_StaysLocal() public {
        remoteHop.sendOFT(frxUSD, ARBITRUM_EID, userB32, 1e18, 0, "", refundTo);
        assertEq(IERC20(frxUSD).balanceOf(user), 1e18, "local transfer, no LayerZero");
    }

    function test_SendOFT_Tag_ToThirdChain() public {
        uint256 fee = remoteHop.quote(frxUSD, ETHEREUM_EID, userB32, 1e18, 0, TAG);
        uint256 hopNativeBefore = address(remoteHop).balance;
        remoteHop.sendOFT{ value: fee + 0.1 ether }(frxUSD, ETHEREUM_EID, userB32, 1e18, 0, TAG, refundTo);
        assertEq(refundTo.balance, 0.1 ether);
        assertEq(address(remoteHop).balance - hopNativeBefore, remoteHop.quoteHop(ETHEREUM_EID, 0, TAG));
    }
}
