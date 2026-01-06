// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import "frax-std/FraxTest.sol";
import { FraxtalHopV2 } from "src/contracts/hop/FraxtalHopV2.sol";
import { RemoteHopV2 } from "src/contracts/hop/RemoteHopV2.sol";
import { HopMessage } from "src/contracts/interfaces/IHopV2.sol";
import { IHopComposer } from "src/contracts/interfaces/IHopComposer.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { OFTMsgCodec } from "@layerzerolabs/oft-evm/contracts/libs/OFTMsgCodec.sol";
import { OFTComposeMsgCodec } from "@layerzerolabs/oft-evm/contracts/libs/OFTComposeMsgCodec.sol";
import { deployFraxtalHopV2 } from "src/script/hop/DeployFraxtalHopV2.s.sol";

contract FraxtalHopV2ExtendedTest is FraxTest {
    FraxtalHopV2 hop;
    address proxyAdmin = vm.addr(0x1);
    address constant ENDPOINT = 0x1a44076050125825900e736c501f859c50fE728c;
    address constant EXECUTOR = 0x41Bdb4aa4A63a5b2Efc531858d3118392B1A1C3d;
    address constant DVN = 0xcCE466a522984415bC91338c232d98869193D46e;
    address constant TREASURY = 0xc1B621b18187F74c8F6D52a6F709Dd2780C09821;
    address[] approvedOfts;

    uint32 constant FRAXTAL_EID = 30_255;
    uint32 constant ARBITRUM_EID = 30_110;
    uint32 constant ETHEREUM_EID = 30_101;

    address constant frxUSD = 0xFc00000000000000000000000000000000000001;

    function setUp() public {
        approvedOfts.push(0x96A394058E2b84A89bac9667B19661Ed003cF5D4);
        approvedOfts.push(0x88Aa7854D3b2dAA5e37E7Ce73A1F39669623a361);

        vm.createSelectFork(vm.envString("FRAXTAL_MAINNET_URL"), 23_464_636);
        hop = FraxtalHopV2(
            deployFraxtalHopV2(proxyAdmin, FRAXTAL_EID, ENDPOINT, 3, EXECUTOR, DVN, TREASURY, approvedOfts)
        );

        // Fund the hop contract
        payable(address(hop)).call{ value: 100 ether }("");
    }

    receive() external payable {}

    // ============ Initialization Tests ============

    function test_Initialization() public {
        assertEq(hop.localEid(), FRAXTAL_EID, "Local EID should be set");
        assertEq(hop.endpoint(), ENDPOINT, "Endpoint should be set");
        assertEq(hop.numDVNs(), 3, "NumDVNs should be set");
        assertEq(hop.EXECUTOR(), EXECUTOR, "Executor should be set");
        assertEq(hop.DVN(), DVN, "DVN should be set");
        assertEq(hop.TREASURY(), TREASURY, "Treasury should be set");
        assertTrue(hop.approvedOft(approvedOfts[0]), "First OFT should be approved");
        assertTrue(hop.approvedOft(approvedOfts[1]), "Second OFT should be approved");
        assertFalse(hop.paused(), "Should not be paused initially");
    }

    function test_Initialization_HasDefaultAdminRole() public {
        assertTrue(hop.hasRole(hop.DEFAULT_ADMIN_ROLE(), address(this)), "Deployer should have DEFAULT_ADMIN_ROLE");
    }

    // ============ SendOFT Tests ============

    function test_SendOFT_InvalidDestinationChain() public {
        address oft = approvedOfts[0];
        uint32 invalidEid = 12_345;

        deal(frxUSD, address(this), 1e18);
        IERC20(frxUSD).approve(address(hop), 1e18);

        vm.expectRevert(FraxtalHopV2.InvalidDestinationChain.selector);
        hop.sendOFT(oft, invalidEid, bytes32(uint256(uint160(address(this)))), 1e18, 0, "");
    }

    function test_SendOFT_ValidDestinationWithRemoteHop() public {
        address oft = approvedOfts[0];
        hop.setRemoteHop(ARBITRUM_EID, address(0x123));

        deal(frxUSD, address(this), 1e18);
        IERC20(frxUSD).approve(address(hop), 1e18);
        vm.deal(address(this), 1 ether);

        uint256 fee = hop.quote(oft, ARBITRUM_EID, bytes32(uint256(uint160(address(this)))), 1e18, 0, "");
        hop.sendOFT{ value: fee }(oft, ARBITRUM_EID, bytes32(uint256(uint160(address(this)))), 1e18, 0, "");
    }

    function test_SendOFT_ToFraxtalIsValid() public {
        address oft = approvedOfts[0];

        deal(frxUSD, address(this), 1e18);
        IERC20(frxUSD).approve(address(hop), 1e18);

        hop.sendOFT(oft, FRAXTAL_EID, bytes32(uint256(uint160(address(this)))), 1e18, 0, "");
        assertEq(IERC20(frxUSD).balanceOf(address(this)), 1e18, "Tokens should be transferred locally");
    }

    // ============ Admin Function Tests ============

    function test_PauseOn() public {
        assertFalse(hop.paused());
        hop.pauseOn();
        assertTrue(hop.paused());
    }

    function test_PauseOff() public {
        hop.pauseOn();
        assertTrue(hop.paused());
        hop.pauseOff();
        assertFalse(hop.paused());
    }

    function test_PauseOn_NotAuthorized() public {
        vm.prank(address(0xdead));
        vm.expectRevert(abi.encodeWithSignature("NotAuthorized()"));
        hop.pauseOn();
    }

    function test_PauseOff_OnlyAdmin() public {
        hop.pauseOn();

        vm.prank(address(0xdead));
        vm.expectRevert();
        hop.pauseOff();
    }

    function test_SetApprovedOft() public {
        address newOft = address(0x999);
        assertFalse(hop.approvedOft(newOft));

        hop.setApprovedOft(newOft, true);
        assertTrue(hop.approvedOft(newOft));

        hop.setApprovedOft(newOft, false);
        assertFalse(hop.approvedOft(newOft));
    }

    function test_SetApprovedOft_NotAuthorized() public {
        vm.prank(address(0xdead));
        vm.expectRevert();
        hop.setApprovedOft(address(0x999), true);
    }

    function test_SetRemoteHop_Address() public {
        address remoteHop = address(0x123);
        hop.setRemoteHop(ARBITRUM_EID, remoteHop);
        assertEq(hop.remoteHop(ARBITRUM_EID), bytes32(uint256(uint160(remoteHop))));
    }

    function test_SetRemoteHop_Bytes32() public {
        bytes32 remoteHop = bytes32(uint256(0x456));
        hop.setRemoteHop(ARBITRUM_EID, remoteHop);
        assertEq(hop.remoteHop(ARBITRUM_EID), remoteHop);
    }

    function test_SetRemoteHop_NotAuthorized() public {
        vm.prank(address(0xdead));
        vm.expectRevert();
        hop.setRemoteHop(ARBITRUM_EID, address(0x123));
    }

    function test_SetNumDVNs() public {
        assertEq(hop.numDVNs(), 3);
        hop.setNumDVNs(5);
        assertEq(hop.numDVNs(), 5);
    }

    function test_SetNumDVNs_NotAuthorized() public {
        vm.prank(address(0xdead));
        vm.expectRevert();
        hop.setNumDVNs(5);
    }

    function test_SetHopFee() public {
        assertEq(hop.hopFee(), 0);
        hop.setHopFee(100); // 1%
        assertEq(hop.hopFee(), 100);
    }

    function test_SetHopFee_NotAuthorized() public {
        vm.prank(address(0xdead));
        vm.expectRevert();
        hop.setHopFee(100);
    }

    function test_SetExecutorOptions() public {
        bytes memory options = hex"01001101000000000000000000000000000493E0";
        hop.setExecutorOptions(ARBITRUM_EID, options);
        assertEq(hop.executorOptions(ARBITRUM_EID), options);
    }

    function test_SetExecutorOptions_NotAuthorized() public {
        vm.prank(address(0xdead));
        vm.expectRevert();
        hop.setExecutorOptions(ARBITRUM_EID, hex"01");
    }

    function test_SetMessageProcessed() public {
        address oft = approvedOfts[0];
        uint32 srcEid = ARBITRUM_EID;
        uint64 nonce = 1;
        bytes32 composeFrom = bytes32(uint256(0x123));

        bytes32 messageHash = keccak256(abi.encode(oft, srcEid, nonce, composeFrom));
        assertFalse(hop.messageProcessed(messageHash));

        hop.setMessageProcessed(oft, srcEid, nonce, composeFrom);
        assertTrue(hop.messageProcessed(messageHash));
    }

    function test_SetMessageProcessed_NotAuthorized() public {
        vm.prank(address(0xdead));
        vm.expectRevert();
        hop.setMessageProcessed(approvedOfts[0], ARBITRUM_EID, 1, bytes32(uint256(0x123)));
    }

    function test_Recover() public {
        // Send some ETH to the hop contract
        deal(address(hop), 10 ether);

        uint256 balanceBefore = address(this).balance;
        hop.recover(address(this), 1 ether, "");
        assertEq(address(this).balance, balanceBefore + 1 ether);
    }

    function test_Recover_NotAuthorized() public {
        vm.prank(address(0xdead));
        vm.expectRevert();
        hop.recover(address(this), 1 ether, "");
    }

    // ============ Paused State Tests ============

    function test_SendOFT_WhenPaused() public {
        hop.pauseOn();

        address oft = approvedOfts[0];
        deal(frxUSD, address(this), 1e18);
        IERC20(frxUSD).approve(address(hop), 1e18);

        vm.expectRevert(abi.encodeWithSignature("HopPaused()"));
        hop.sendOFT(oft, FRAXTAL_EID, bytes32(uint256(uint160(address(this)))), 1e18, 0, "");
    }

    function test_LzCompose_WhenPaused() public {
        hop.pauseOn();

        address oft = approvedOfts[0];
        bytes memory message = _createComposeMessage(oft, 1e18, ARBITRUM_EID, address(0x123));

        vm.prank(ENDPOINT);
        vm.expectRevert(abi.encodeWithSignature("HopPaused()"));
        hop.lzCompose(oft, bytes32(0), message, address(0), "");
    }

    // ============ Quote Tests ============

    function test_Quote_LocalDestination() public {
        address oft = approvedOfts[0];
        uint256 fee = hop.quote(oft, FRAXTAL_EID, bytes32(uint256(uint160(address(this)))), 1e18, 0, "");
        assertEq(fee, 0, "Local transfers should have zero fee");
    }

    function test_Quote_RemoteDestination() public {
        address oft = approvedOfts[0];
        hop.setRemoteHop(ARBITRUM_EID, address(0x123));
        uint256 fee = hop.quote(oft, ARBITRUM_EID, bytes32(uint256(uint160(address(this)))), 1e18, 0, "");
        assertTrue(fee > 0, "Remote transfers should have non-zero fee");
    }

    function test_QuoteHop() public {
        uint256 fee = hop.quoteHop(ARBITRUM_EID, 400_000, "");
        assertTrue(fee > 0, "Hop fee should be non-zero");
    }

    function test_QuoteHop_WithData() public {
        bytes memory data = "Hello World";
        uint256 fee = hop.quoteHop(ARBITRUM_EID, 400_000, data);
        assertTrue(fee > 0, "Hop fee with data should be non-zero");
    }

    // ============ RemoveDust Tests ============

    function test_RemoveDust() public {
        address oft = approvedOfts[0];
        uint256 amount = 1.123_456_789_123_456_789e18;
        uint256 cleaned = hop.removeDust(oft, amount);
        assertTrue(cleaned <= amount, "Cleaned amount should be <= original");
        assertTrue(cleaned % 1e12 == 0, "Cleaned amount should have no dust");
    }

    function test_RemoveDust_ZeroAmount() public {
        address oft = approvedOfts[0];
        uint256 cleaned = hop.removeDust(oft, 0);
        assertEq(cleaned, 0, "Zero amount should remain zero");
    }

    // ============ LzCompose Tests ============

    function test_LzCompose_InvalidRemoteHop() public {
        address oft = approvedOfts[0];

        bytes memory data;
        bytes memory composeMsg = abi.encode(
            HopMessage({
                srcEid: ARBITRUM_EID,
                dstEid: ETHEREUM_EID,
                dstGas: 400_000,
                sender: bytes32(uint256(uint160(address(0x123)))),
                recipient: bytes32(uint256(uint160(address(0x456)))),
                data: "test"
            })
        );
        composeMsg = abi.encodePacked(bytes32(uint256(uint160(address(0x789)))), composeMsg);
        bytes memory message = OFTComposeMsgCodec.encode(0, ARBITRUM_EID, 1e18, composeMsg);

        deal(frxUSD, address(hop), 1e18);
        vm.deal(ENDPOINT, 100 ether);

        vm.prank(ENDPOINT);
        vm.expectRevert(FraxtalHopV2.InvalidRemoteHop.selector);
        hop.lzCompose{ value: 1 ether }(oft, bytes32(0), message, address(0), "");
    }

    function test_LzCompose_NotEndpoint() public {
        address oft = approvedOfts[0];
        bytes memory message = _createComposeMessage(oft, 1e18, ARBITRUM_EID, address(0x123));

        vm.expectRevert(abi.encodeWithSignature("NotEndpoint()"));
        hop.lzCompose(oft, bytes32(0), message, address(0), "");
    }

    function test_LzCompose_InvalidOFT() public {
        address invalidOft = address(0x999);
        bytes memory message = _createComposeMessage(invalidOft, 1e18, ARBITRUM_EID, address(0x123));

        vm.prank(ENDPOINT);
        vm.expectRevert(abi.encodeWithSignature("InvalidOFT()"));
        hop.lzCompose(invalidOft, bytes32(0), message, address(0), "");
    }

    function test_LzCompose_DuplicateMessage() public {
        address oft = approvedOfts[0];
        bytes memory message = _createComposeMessage(oft, 1e18, ARBITRUM_EID, address(0x123));

        hop.setRemoteHop(ARBITRUM_EID, address(0x123));
        deal(frxUSD, address(hop), 2e18);

        vm.startPrank(ENDPOINT);
        hop.lzCompose(oft, bytes32(0), message, address(0), "");
        // Second call with same message should be ignored (no revert)
        hop.lzCompose(oft, bytes32(0), message, address(0), "");
        vm.stopPrank();
    }

    // ============ Role-Based Access Control Tests ============

    function test_GrantPauserRole() public {
        address pauser = address(0xdead);
        bytes32 pauserRole = 0x65d7a28e3265b37a6474929f336521b332c1681b933f6cb9f3376673440d862a;

        hop.grantRole(pauserRole, pauser);
        assertTrue(hop.hasRole(pauserRole, pauser));

        vm.prank(pauser);
        hop.pauseOn();
        assertTrue(hop.paused());
    }

    function test_RevokePauserRole() public {
        address pauser = address(0xdead);
        bytes32 pauserRole = 0x65d7a28e3265b37a6474929f336521b332c1681b933f6cb9f3376673440d862a;

        hop.grantRole(pauserRole, pauser);
        hop.revokeRole(pauserRole, pauser);
        assertFalse(hop.hasRole(pauserRole, pauser));

        vm.prank(pauser);
        vm.expectRevert(abi.encodeWithSignature("NotAuthorized()"));
        hop.pauseOn();
    }

    // ============ Helper Functions ============

    function _createComposeMessage(
        address oft,
        uint256 amount,
        uint32 srcEid,
        address sender
    ) internal view returns (bytes memory) {
        bytes memory composeMsg = abi.encode(
            HopMessage({
                srcEid: srcEid,
                dstEid: FRAXTAL_EID,
                dstGas: 0,
                sender: bytes32(uint256(uint160(sender))),
                recipient: bytes32(uint256(uint160(address(this)))),
                data: ""
            })
        );
        composeMsg = abi.encodePacked(bytes32(uint256(uint160(sender))), composeMsg);
        return OFTComposeMsgCodec.encode(0, srcEid, amount, composeMsg);
    }
}
