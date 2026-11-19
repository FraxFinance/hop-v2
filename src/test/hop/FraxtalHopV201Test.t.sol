// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import "frax-std/FraxTest.sol";
import { FraxtalHopV201 } from "src/contracts/hop/FraxtalHopV201.sol";
import { HopMessage } from "src/contracts/interfaces/IHopV201.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { OFTComposeMsgCodec } from "@layerzerolabs/oft-evm/contracts/libs/OFTComposeMsgCodec.sol";
import { IMessagingComposer } from "@layerzerolabs/lz-evm-protocol-v2/contracts/interfaces/IMessagingComposer.sol";
import { deployFraxtalHopV201 } from "src/script/hop/upgrade/DeployFraxtalHopV201.s.sol";

contract FraxtalHopV201ExtendedTest is FraxTest {
    FraxtalHopV201 hop;
    address proxyAdmin = vm.addr(0x1);
    address constant ENDPOINT = 0x1a44076050125825900e736c501f859c50fE728c;
    address constant EXECUTOR = 0x41Bdb4aa4A63a5b2Efc531858d3118392B1A1C3d;
    address constant DVN = 0xcCE466a522984415bC91338c232d98869193D46e;
    address constant TREASURY = 0xc1B621b18187F74c8F6D52a6F709Dd2780C09821;
    address[] approvedOfts;

    uint32 constant FRAXTAL_EID = 30_255;
    uint32 constant ARBITRUM_EID = 30_110;
    uint32 constant ETHEREUM_EID = 30_101;

    /// @dev keccak256("RECOVER_ETH_ROLE")
    bytes32 constant RECOVER_ETH_ROLE = 0xfedd0e52ab05da04684e0bc204015ae57756f9c216de6f3af64eea1589a09b0e;

    address constant frxUSD = 0xFc00000000000000000000000000000000000001;

    function setUp() public {
        approvedOfts.push(0x96A394058E2b84A89bac9667B19661Ed003cF5D4);
        approvedOfts.push(0x88Aa7854D3b2dAA5e37E7Ce73A1F39669623a361);

        vm.createSelectFork(vm.envString("FRAXTAL_MAINNET_URL"), 23_464_636);
        vm.startPrank(0x54F9b12743A7DeeC0ea48721683cbebedC6E17bC);
        hop = FraxtalHopV201(
            deployFraxtalHopV201(proxyAdmin, FRAXTAL_EID, ENDPOINT, 3, EXECUTOR, DVN, TREASURY, approvedOfts)
        );
        hop.grantRole(bytes32(0), address(this));
        vm.stopPrank();

        // Fund the hop contract
        (bool success, ) = payable(address(hop)).call{ value: 100 ether }("");
        assertTrue(success, "ETH funding failed");
    }

    receive() external payable {}

    function test_RecoverETH() public {
        // Send some ETH to the hop contract
        deal(address(hop), 10 ether);
        hop.grantRole(RECOVER_ETH_ROLE, address(this));

        uint256 balanceBefore = address(this).balance;
        hop.recoverETH(1 ether);
        assertEq(address(this).balance, balanceBefore + 1 ether);
    }

    function test_RecoverETH_NotAuthorized() public {
        deal(address(hop), 10 ether);

        // Admin does not hold RECOVER_ETH_ROLE by default
        vm.expectRevert();
        hop.recoverETH(1 ether);

        vm.prank(address(0xdead));
        vm.expectRevert();
        hop.recoverETH(1 ether);
    }

    function test_RecoverERC20() public {
        // Send some tokens to the hop contract
        deal(frxUSD, address(hop), 10e18);

        uint256 balanceBefore = IERC20(frxUSD).balanceOf(address(this));
        hop.recoverERC20(frxUSD, 1e18);
        assertEq(IERC20(frxUSD).balanceOf(address(this)), balanceBefore + 1e18);
    }

    function test_RecoverERC20_NotAuthorized() public {
        deal(frxUSD, address(hop), 10e18);

        vm.prank(address(0xdead));
        vm.expectRevert();
        hop.recoverERC20(frxUSD, 1e18);
    }

    // ============ Zero recipient ============

    /// @dev A recipient that narrows to address(0) is refused before any token is pulled, on both
    ///      entrypoints, for the local and the forwarded destination.
    function test_SendOFT_ZeroRecipient() public {
        address oft = approvedOfts[0];
        hop.setRemoteHop(ARBITRUM_EID, address(0x123));
        deal(frxUSD, address(this), 1e18);
        IERC20(frxUSD).approve(address(hop), 1e18);

        vm.expectRevert(abi.encodeWithSignature("ZeroRecipient()"));
        hop.sendOFT(oft, FRAXTAL_EID, bytes32(0), 1e18, 0, "");

        vm.expectRevert(abi.encodeWithSignature("ZeroRecipient()"));
        hop.sendOFT(oft, ARBITRUM_EID, bytes32(0), 1e18);

        vm.expectRevert(abi.encodeWithSignature("ZeroRecipient()"));
        hop.sendOFT(oft, ARBITRUM_EID, bytes32(uint256(type(uint96).max) << 160), 1e18, 400_000, hex"01");

        assertEq(IERC20(frxUSD).allowance(address(this), address(hop)), 1e18, "allowance untouched");
    }

    /// @dev The quote fails closed on the same input as the send.
    function test_Quote_ZeroRecipient() public {
        address oft = approvedOfts[0];
        hop.setRemoteHop(ARBITRUM_EID, address(0x123));

        vm.expectRevert(abi.encodeWithSignature("ZeroRecipient()"));
        hop.quote(oft, ARBITRUM_EID, bytes32(0), 1e18, 0, "");

        vm.expectRevert(abi.encodeWithSignature("ZeroRecipient()"));
        hop.quote(oft, FRAXTAL_EID, bytes32(uint256(type(uint96).max) << 160), 1e18, 0, "");
    }

    /// @dev A zero recipient inside a delivered compose is refused before the hub routes it, whether the
    ///      message came from the registered spoke or from an arbitrary composer, for the forwarded,
    ///      data-bearing and local shapes. The revert leaves the message unprocessed, so a retry takes the
    ///      same path instead of the duplicate early return, and the funds stay on the hub.
    function test_LzCompose_ZeroRecipient_StaysRetryable() public {
        address oft = approvedOfts[0];
        address remoteSpoke = address(0x456);
        hop.setRemoteHop(ARBITRUM_EID, remoteSpoke);
        hop.setRemoteHop(ETHEREUM_EID, address(0x789));
        deal(frxUSD, address(hop), 10e18);
        uint256 hopBalance = IERC20(frxUSD).balanceOf(address(hop));

        bytes32[2] memory bad = [bytes32(0), bytes32(uint256(type(uint96).max) << 160)];
        for (uint256 i; i < bad.length; ++i) {
            uint64 nonce = uint64(10 * (i + 1));
            // registered spoke: forwarded without data, forwarded with data, delivered locally
            _expectZeroRecipientCompose(
                oft,
                _composeMessage(ETHEREUM_EID, bad[i], "", remoteSpoke, nonce),
                remoteSpoke,
                nonce
            );
            _expectZeroRecipientCompose(
                oft,
                _composeMessage(ETHEREUM_EID, bad[i], hex"01", remoteSpoke, nonce + 1),
                remoteSpoke,
                nonce + 1
            );
            _expectZeroRecipientCompose(
                oft,
                _composeMessage(FRAXTAL_EID, bad[i], "", remoteSpoke, nonce + 2),
                remoteSpoke,
                nonce + 2
            );
            // arbitrary composer: the hub overwrites srcEid and sender, the recipient is still the caller's
            _expectZeroRecipientCompose(
                oft,
                _composeMessage(ETHEREUM_EID, bad[i], "", address(0xABCD), nonce + 3),
                address(0xABCD),
                nonce + 3
            );
        }

        assertEq(IERC20(frxUSD).balanceOf(address(hop)), hopBalance, "funds stay on the hub");
    }

    /// @dev The same message with a real recipient delivers, so the check above is the only thing between
    ///      a zero recipient and the funds.
    function test_LzCompose_ValidRecipient_DeliversLocally() public {
        address oft = approvedOfts[0];
        address remoteSpoke = address(0x456);
        address recipient = address(0xBEEF);
        hop.setRemoteHop(ARBITRUM_EID, remoteSpoke);
        deal(frxUSD, address(hop), 1e18);

        bytes memory message = _composeMessage(FRAXTAL_EID, bytes32(uint256(uint160(recipient))), "", remoteSpoke, 1);
        vm.prank(ENDPOINT);
        hop.lzCompose(oft, bytes32(0), message, address(0), "");

        assertEq(IERC20(frxUSD).balanceOf(recipient), 1e18, "recipient credited");
        assertTrue(hop.messageProcessed(_messageHash(oft, 1, remoteSpoke)), "message marked processed");
    }

    /// @dev A compose the endpoint holds as pending can be retired: the mark sets the replay key derived
    ///      from the queued bytes, and the endpoint's later delivery takes the duplicate early return, so
    ///      the funds stay on the hub for recovery and the queue entry closes.
    function test_SetMessageProcessed_PendingCompose_RetiresIt() public {
        address oft = approvedOfts[0];
        address remoteSpoke = address(0x456);
        address recipient = address(0xBEEF);
        hop.setRemoteHop(ARBITRUM_EID, remoteSpoke);
        deal(frxUSD, address(hop), 1e18);

        bytes32 guid = keccak256("pending");
        bytes memory message = _composeMessage(FRAXTAL_EID, bytes32(uint256(uint160(recipient))), "", remoteSpoke, 7);
        _queueCompose(oft, guid, 0, message);

        vm.expectEmit(address(hop));
        emit MessageHash(oft, ARBITRUM_EID, 7, bytes32(uint256(uint160(remoteSpoke))));
        hop.setMessageProcessed(oft, guid, 0, message);
        assertTrue(hop.messageProcessed(_messageHash(oft, 7, remoteSpoke)), "replay key set from the queued bytes");

        IMessagingComposer(ENDPOINT).lzCompose(oft, address(hop), guid, 0, message, "");

        assertEq(IERC20(frxUSD).balanceOf(recipient), 0, "retired compose pays nothing");
        assertEq(IERC20(frxUSD).balanceOf(address(hop)), 1e18, "funds stay on the hub");
        assertEq(
            IMessagingComposer(ENDPOINT).composeQueue(oft, address(hop), guid, 0),
            bytes32(uint256(1)),
            "queue entry closed"
        );
    }

    /// @dev Nothing the endpoint does not hold as pending can be marked: a message that was never queued,
    ///      or one that differs from the queued bytes in any field of the queue key or the payload.
    function test_SetMessageProcessed_NotQueued_Reverts() public {
        address oft = approvedOfts[0];
        address remoteSpoke = address(0x456);
        bytes32 guid = keccak256("pending");
        bytes memory message = _composeMessage(FRAXTAL_EID, bytes32(uint256(0xBEEF)), "", remoteSpoke, 7);

        vm.expectRevert(abi.encodeWithSignature("ComposeNotPending()"));
        hop.setMessageProcessed(oft, guid, 0, message);

        _queueCompose(oft, guid, 0, message);
        bytes memory otherNonce = _composeMessage(FRAXTAL_EID, bytes32(uint256(0xBEEF)), "", remoteSpoke, 8);

        vm.expectRevert(abi.encodeWithSignature("ComposeNotPending()"));
        hop.setMessageProcessed(oft, guid, 0, otherNonce);
        vm.expectRevert(abi.encodeWithSignature("ComposeNotPending()"));
        hop.setMessageProcessed(oft, guid, 1, message);
        vm.expectRevert(abi.encodeWithSignature("ComposeNotPending()"));
        hop.setMessageProcessed(oft, keccak256("other"), 0, message);
        vm.expectRevert(abi.encodeWithSignature("ComposeNotPending()"));
        hop.setMessageProcessed(approvedOfts[1], guid, 0, message);

        assertFalse(hop.messageProcessed(_messageHash(oft, 7, remoteSpoke)), "nothing marked");
        assertFalse(hop.messageProcessed(_messageHash(oft, 8, remoteSpoke)), "future nonce not pre-empted");
    }

    /// @dev Once the endpoint has delivered a compose it is no longer pending, so it cannot be marked.
    function test_SetMessageProcessed_Delivered_Reverts() public {
        address oft = approvedOfts[0];
        address remoteSpoke = address(0x456);
        address recipient = address(0xBEEF);
        hop.setRemoteHop(ARBITRUM_EID, remoteSpoke);
        deal(frxUSD, address(hop), 1e18);

        bytes32 guid = keccak256("delivered");
        bytes memory message = _composeMessage(FRAXTAL_EID, bytes32(uint256(uint160(recipient))), "", remoteSpoke, 9);
        _queueCompose(oft, guid, 0, message);
        IMessagingComposer(ENDPOINT).lzCompose(oft, address(hop), guid, 0, message, "");
        assertEq(IERC20(frxUSD).balanceOf(recipient), 1e18, "delivered normally");

        vm.expectRevert(abi.encodeWithSignature("ComposeNotPending()"));
        hop.setMessageProcessed(oft, guid, 0, message);
    }

    function test_SetMessageProcessed_NotAuthorized() public {
        address oft = approvedOfts[0];
        bytes32 guid = keccak256("pending");
        bytes memory message = _composeMessage(FRAXTAL_EID, bytes32(uint256(0xBEEF)), "", address(0x456), 7);
        _queueCompose(oft, guid, 0, message);

        vm.prank(address(0xdead));
        vm.expectRevert();
        hop.setMessageProcessed(oft, guid, 0, message);
    }

    event MessageHash(address oft, uint32 indexed srcEid, uint64 indexed nonce, bytes32 indexed composeFrom);

    /// @dev Queues `message` at the real endpoint exactly as the OFT does after crediting the hop.
    function _queueCompose(address oft, bytes32 guid, uint16 index, bytes memory message) internal {
        vm.prank(oft);
        IMessagingComposer(ENDPOINT).sendCompose(address(hop), guid, index, message);
    }

    function _composeMessage(
        uint32 dstEid,
        bytes32 recipient,
        bytes memory data,
        address composeFrom,
        uint64 nonce
    ) internal pure returns (bytes memory) {
        bytes memory composeMsg = abi.encode(
            HopMessage({
                srcEid: ARBITRUM_EID,
                dstEid: dstEid,
                dstGas: 400_000,
                sender: bytes32(uint256(uint160(address(0x123)))),
                recipient: recipient,
                data: data
            })
        );
        return
            OFTComposeMsgCodec.encode(
                nonce,
                ARBITRUM_EID,
                1e18,
                abi.encodePacked(bytes32(uint256(uint160(composeFrom))), composeMsg)
            );
    }

    function _messageHash(address oft, uint64 nonce, address composeFrom) internal pure returns (bytes32) {
        return keccak256(abi.encode(oft, ARBITRUM_EID, nonce, bytes32(uint256(uint160(composeFrom)))));
    }

    function _expectZeroRecipientCompose(
        address oft,
        bytes memory message,
        address composeFrom,
        uint64 nonce
    ) internal {
        vm.prank(ENDPOINT);
        vm.expectRevert(abi.encodeWithSignature("ZeroRecipient()"));
        hop.lzCompose(oft, bytes32(0), message, address(0), "");
        assertFalse(hop.messageProcessed(_messageHash(oft, nonce, composeFrom)), "revert leaves it unprocessed");

        // A retry takes the same path, not the duplicate early return.
        vm.prank(ENDPOINT);
        vm.expectRevert(abi.encodeWithSignature("ZeroRecipient()"));
        hop.lzCompose(oft, bytes32(0), message, address(0), "");
    }
}
