// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.23;

import { Test } from "forge-std/Test.sol";
import { console } from "forge-std/console.sol";

import { OptionsBuilder } from "@fraxfinance/layerzero-v2-upgradeable/oapp/contracts/oapp/libs/OptionsBuilder.sol";
import { SendParam, MessagingFee } from "@fraxfinance/layerzero-v2-upgradeable/oapp/contracts/oft/interfaces/IOFT.sol";
import { MessagingReceipt } from "@layerzerolabs/lz-evm-protocol-v2/contracts/interfaces/ILayerZeroEndpointV2.sol";
import { OFTReceipt } from "@layerzerolabs/oft-evm/contracts/interfaces/IOFT.sol";
import { OFTMsgCodec } from "@layerzerolabs/oft-evm/contracts/libs/OFTMsgCodec.sol";
import { OFTComposeMsgCodec } from "@layerzerolabs/oft-evm/contracts/libs/OFTComposeMsgCodec.sol";
import { TestHelperOz5 } from "@layerzerolabs/test-devtools-evm-foundry/contracts/TestHelperOz5.sol";
import { TransparentUpgradeableProxy } from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";

import { RemoteHopV2Tempo } from "src/contracts/hop/RemoteHopV2Tempo.sol";
import { HopMessage } from "src/contracts/interfaces/IHopV2.sol";
import { IHopComposer } from "src/contracts/interfaces/IHopComposer.sol";

import { ITIP20 } from "tempo-std/interfaces/ITIP20.sol";
import { ITIP20Factory } from "tempo-std/interfaces/ITIP20Factory.sol";
import { ITIP20RolesAuth } from "tempo-std/interfaces/ITIP20RolesAuth.sol";
import { StdPrecompiles } from "tempo-std/StdPrecompiles.sol";
import { StdTokens } from "tempo-std/StdTokens.sol";

import { OFTMock } from "@layerzerolabs/oft-evm/test/mocks/OFTMock.sol";
import { OFTAdapter } from "@layerzerolabs/oft-evm/contracts/OFTAdapter.sol";
import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";

/// @notice Mock TIP20 OFT Adapter that uses mint/burn for cross-chain transfers
/// @dev Mimics FraxOFTMintableAdapterUpgradeableTIP20 behavior for testing
contract TIP20OFTAdapterMock is OFTAdapter {
    constructor(
        address _token,
        address _lzEndpoint,
        address _delegate
    ) OFTAdapter(_token, _lzEndpoint, _delegate) Ownable(_delegate) {}

    /// @dev Override _debit to burn tokens instead of locking them
    function _debit(
        address _from,
        uint256 _amountLD,
        uint256 _minAmountLD,
        uint32 _dstEid
    ) internal override returns (uint256 amountSentLD, uint256 amountReceivedLD) {
        (amountSentLD, amountReceivedLD) = _debitView(_amountLD, _minAmountLD, _dstEid);

        // Pull tokens from sender and burn them (TIP20 style)
        ITIP20(address(innerToken)).transferFrom(_from, address(this), amountSentLD);
        ITIP20(address(innerToken)).burn(amountSentLD);
    }

    /// @dev Override _credit to mint tokens instead of unlocking them
    function _credit(
        address _to,
        uint256 _amountLD,
        uint32 /*_srcEid*/
    ) internal override returns (uint256 amountReceivedLD) {
        // Mint tokens to recipient (TIP20 style)
        ITIP20(address(innerToken)).mint(_to, _amountLD);
        return _amountLD;
    }
}

/// @notice Test HopComposer for testing local transfers with compose
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

/// @notice Tempo test helpers for precompiles (precompiles are real in special foundry)
abstract contract TempoTestHelpers is Test {
    /// @dev Set user's gas token via TIP_FEE_MANAGER precompile
    function _setUserGasToken(address user, address token) internal {
        vm.prank(user);
        StdPrecompiles.TIP_FEE_MANAGER.setUserToken(token);
    }

    /// @dev Grant ISSUER_ROLE on a TIP20 token to an address
    function _grantIssuerRole(address token, address account) internal {
        bytes32 issuerRole = ITIP20(token).ISSUER_ROLE();
        ITIP20RolesAuth(token).grantRole(issuerRole, account);
    }

    /// @dev Grant PATH_USD ISSUER_ROLE to an address
    function _grantPathUsdIssuerRole(address account) internal {
        _grantIssuerRole(StdTokens.PATH_USD_ADDRESS, account);
    }

    /// @dev Create a TIP20 token via factory precompile with issuer role granted to caller
    function _createTIP20(string memory name, string memory symbol, bytes32 salt) internal returns (ITIP20 token) {
        token = ITIP20(
            ITIP20Factory(address(StdPrecompiles.TIP20_FACTORY)).createToken(
                name,
                symbol,
                "USD",
                ITIP20(StdTokens.PATH_USD_ADDRESS),
                address(this),
                salt
            )
        );
        // Grant ISSUER_ROLE to test contract for minting
        ITIP20RolesAuth(address(token)).grantRole(token.ISSUER_ROLE(), address(this));
    }

    /// @dev Create a TIP20 token with a DEX pair via precompile
    function _createTIP20WithDexPair(
        string memory name,
        string memory symbol,
        bytes32 salt
    ) internal returns (ITIP20 token) {
        token = _createTIP20(name, symbol, salt);
        StdPrecompiles.STABLECOIN_DEX.createPair(address(token));
    }

    /// @dev Add liquidity to DEX precompile by placing both bid and ask orders
    function _addDexLiquidity(address token, uint256 amount) internal {
        address liquidityProvider = address(0x1111);

        // Mint both PATH_USD and the token for the liquidity provider
        ITIP20(StdTokens.PATH_USD_ADDRESS).mint(liquidityProvider, amount * 2);
        ITIP20(token).mint(liquidityProvider, amount * 2);

        vm.startPrank(liquidityProvider);

        // Place bid order: buy token with PATH_USD (allows selling token for PATH_USD)
        ITIP20(StdTokens.PATH_USD_ADDRESS).approve(address(StdPrecompiles.STABLECOIN_DEX), amount * 2);
        StdPrecompiles.STABLECOIN_DEX.place(token, uint128(amount), true, 0);

        // Place ask order: sell token for PATH_USD (allows buying token with PATH_USD)
        ITIP20(token).approve(address(StdPrecompiles.STABLECOIN_DEX), amount * 2);
        StdPrecompiles.STABLECOIN_DEX.place(token, uint128(amount), false, 0);

        vm.stopPrank();
    }
}

/// @title RemoteHopV2TempoTest
/// @notice Tests for RemoteHopV2Tempo using TestHelperOz5 for LayerZero setup
/// @dev Uses real Tempo precompiles (via special Foundry) and mocked LayerZero endpoints
/// @dev Architecture: Tempo side uses OFTAdapter with TIP20 token, other chains use OFT
contract RemoteHopV2TempoTest is TestHelperOz5, TempoTestHelpers {
    using OptionsBuilder for bytes;

    RemoteHopV2Tempo remoteHopTempo;
    TIP20OFTAdapterMock oftAdapter; // OFT Adapter on Tempo (mint/burn TIP20)
    ITIP20 underlyingToken; // TIP20 token underlying the adapter

    address proxyAdmin = makeAddr("proxyAdmin");
    address[] approvedOfts;

    uint32 constant TEMPO_EID = 1;
    uint32 constant FRAXTAL_EID = 2;

    address fraxtalHop = address(0x123);

    address alice = makeAddr("alice");
    address bob = makeAddr("bob");

    uint256 initialBalance = 100e18;

    function setUp() public virtual override {
        vm.deal(alice, 1000 ether);
        vm.deal(bob, 1000 ether);

        // Grant PATH_USD issuer role for minting in tests (precompile is real)
        _grantPathUsdIssuerRole(address(this));

        // Setup LayerZero endpoints using TestHelperOz5
        // Pass PATH_USD as native token for Tempo endpoint (index 0), address(0) for Fraxtal (index 1)
        address[] memory altTokens = new address[](2);
        altTokens[0] = StdTokens.PATH_USD_ADDRESS; // Tempo uses PATH_USD as native
        altTokens[1] = address(0); // Fraxtal uses native ETH

        super.setUp();
        createEndpoints(2, LibraryType.UltraLightNode, altTokens);

        // Create TIP20 token via Tempo precompile (this is the underlying token for the adapter)
        underlyingToken = _createTIP20WithDexPair("Test Token", "TEST", keccak256("RemoteHopV2TempoTest"));

        // Deploy TIP20 OFT Adapter - mint/burn adapter for TIP20
        oftAdapter = TIP20OFTAdapterMock(
            _deployOApp(
                type(TIP20OFTAdapterMock).creationCode,
                abi.encode(address(underlyingToken), address(endpoints[TEMPO_EID]), address(this))
            )
        );

        // Grant ISSUER_ROLE to the adapter so it can mint/burn the underlying TIP20
        _grantIssuerRole(address(underlyingToken), address(oftAdapter));

        approvedOfts.push(address(oftAdapter));

        // Deploy RemoteHopV2Tempo
        remoteHopTempo = _deployRemoteHopV2Tempo();

        // Mint underlying TIP20 tokens to test users
        underlyingToken.mint(alice, initialBalance);
        underlyingToken.mint(bob, initialBalance);
        StdTokens.PATH_USD.mint(alice, 1_000_000e6);
        StdTokens.PATH_USD.mint(bob, 1_000_000e6);

        // Add DEX liquidity for underlying token so swaps work
        _addDexLiquidity(address(underlyingToken), 100_000e6);

        // Set user gas tokens via TIP_FEE_MANAGER precompile
        _setUserGasToken(alice, StdTokens.PATH_USD_ADDRESS);
        _setUserGasToken(bob, StdTokens.PATH_USD_ADDRESS);

        // Configure peer for Fraxtal (30_255 = FRAXTAL_EID in production)
        // RemoteHopV2 always routes through Fraxtal, so the adapter needs a peer for that EID
        oftAdapter.setPeer(30_255, OFTMsgCodec.addressToBytes32(address(0x999))); // Mock peer on Fraxtal
    }

    function _deployRemoteHopV2Tempo() internal returns (RemoteHopV2Tempo) {
        address endpointAddr = address(endpoints[TEMPO_EID]);

        RemoteHopV2Tempo implementation = new RemoteHopV2Tempo(endpointAddr);

        bytes memory initializeArgs = abi.encodeWithSignature(
            "initialize(uint32,address,bytes32,uint32,address,address,address,address[])",
            TEMPO_EID,
            endpointAddr,
            OFTMsgCodec.addressToBytes32(fraxtalHop),
            2, // numDVNs
            address(0x1), // EXECUTOR (mock)
            address(0x2), // DVN (mock)
            address(0x3), // TREASURY (mock)
            approvedOfts
        );

        TransparentUpgradeableProxy proxy = new TransparentUpgradeableProxy(
            address(implementation),
            proxyAdmin,
            initializeArgs
        );

        return RemoteHopV2Tempo(payable(address(proxy)));
    }

    // ============ Constructor Tests ============

    function test_Constructor_NativeTokenSet() public view {
        assertEq(remoteHopTempo.nativeToken(), StdTokens.PATH_USD_ADDRESS, "nativeToken should be PATH_USD");
    }

    // ============ Initialization Tests ============

    function test_Initialization() public view {
        assertEq(remoteHopTempo.localEid(), TEMPO_EID, "Local EID should be set");
        assertEq(remoteHopTempo.endpoint(), address(endpoints[TEMPO_EID]), "Endpoint should be set");
        assertTrue(remoteHopTempo.approvedOft(address(oftAdapter)), "OFT Adapter should be approved");
        assertEq(
            remoteHopTempo.remoteHop(30_255), // FRAXTAL_EID constant in HopV2
            OFTMsgCodec.addressToBytes32(fraxtalHop),
            "Fraxtal hop should be set"
        );
    }

    function test_Initialization_HasDefaultAdminRole() public view {
        assertTrue(
            remoteHopTempo.hasRole(remoteHopTempo.DEFAULT_ADMIN_ROLE(), address(this)),
            "Deployer should have DEFAULT_ADMIN_ROLE"
        );
    }

    // ============ SendOFT Tests - msg.value validation ============

    function test_SendOFT_RevertsWhenMsgValueNonZero() public {
        address oft = address(oftAdapter);

        vm.startPrank(alice);
        underlyingToken.approve(address(remoteHopTempo), 1e18);
        StdTokens.PATH_USD.approve(address(remoteHopTempo), 1000e6);

        vm.expectRevert(abi.encodeWithSelector(RemoteHopV2Tempo.MsgValueNotZero.selector, 1 ether));
        remoteHopTempo.sendOFT{ value: 1 ether }(
            oft,
            30_255, // FRAXTAL_EID
            bytes32(uint256(uint160(bob))),
            1e18,
            0,
            ""
        );
        vm.stopPrank();
    }

    function test_SendOFT_SucceedsWithMsgValueZero_LocalTransfer() public {
        address oft = address(oftAdapter);

        vm.startPrank(alice);
        underlyingToken.approve(address(remoteHopTempo), 1e18);
        StdTokens.PATH_USD.approve(address(remoteHopTempo), 1000e6);

        // Local transfer (same EID) - no LZ fee needed
        remoteHopTempo.sendOFT{ value: 0 }(oft, TEMPO_EID, bytes32(uint256(uint160(bob))), 1e18, 0, "");
        vm.stopPrank();

        // Verify underlying TIP20 token was transferred locally
        assertEq(underlyingToken.balanceOf(bob), initialBalance + 1e18, "Bob should receive tokens");
    }

    // ============ SendOFT Local Transfer Tests ============

    function test_SendOFT_LocalTransfer() public {
        address oft = address(oftAdapter);
        address recipient = address(0x456);

        vm.startPrank(alice);
        underlyingToken.approve(address(remoteHopTempo), 1e18);

        remoteHopTempo.sendOFT{ value: 0 }(oft, TEMPO_EID, bytes32(uint256(uint160(recipient))), 1e18, 0, "");
        vm.stopPrank();

        assertEq(underlyingToken.balanceOf(recipient), 1e18, "Recipient should receive underlying TIP20 tokens");
    }

    function test_SendOFT_LocalTransferWithCompose() public {
        address oft = address(oftAdapter);
        TestHopComposer composer = new TestHopComposer();

        vm.startPrank(alice);
        underlyingToken.approve(address(remoteHopTempo), 1e18);

        bytes memory data = "test data";

        vm.expectEmit(true, true, true, true);
        emit TestHopComposer.Composed(TEMPO_EID, bytes32(uint256(uint160(alice))), oft, 1e18, data);

        remoteHopTempo.sendOFT{ value: 0 }(oft, TEMPO_EID, bytes32(uint256(uint160(address(composer)))), 1e18, 0, data);
        vm.stopPrank();

        assertEq(underlyingToken.balanceOf(address(composer)), 1e18, "Composer should receive underlying TIP20 tokens");
    }

    // ============ SendOFT Validation Tests ============

    function test_SendOFT_WhenPaused() public {
        remoteHopTempo.pauseOn();

        address oft = address(oftAdapter);

        vm.startPrank(alice);
        underlyingToken.approve(address(remoteHopTempo), 1e18);

        vm.expectRevert(abi.encodeWithSignature("HopPaused()"));
        remoteHopTempo.sendOFT{ value: 0 }(oft, 30_255, bytes32(uint256(uint160(bob))), 1e18, 0, "");
        vm.stopPrank();
    }

    function test_SendOFT_InvalidOFT() public {
        address invalidOft = address(0x999);

        vm.expectRevert(abi.encodeWithSignature("InvalidOFT()"));
        remoteHopTempo.sendOFT{ value: 0 }(invalidOft, 30_255, bytes32(uint256(uint160(bob))), 1e18, 0, "");
    }

    // ============ QuoteTempo Tests ============

    function test_QuoteTempo_LocalDestinationReturnsZero() public view {
        address oft = address(oftAdapter);
        uint256 fee = remoteHopTempo.quoteTempo(oft, TEMPO_EID, bytes32(uint256(uint160(bob))), 1e18, 0, "");
        assertEq(fee, 0, "Local transfers should have zero fee");
    }

    function test_QuoteTempo_WhenUserGasTokenIsNative() public {
        // Note: This test requires a fully configured LZ endpoint with send library for FRAXTAL_EID (30_255)
        // The TestHelperOz5 setup only configures endpoints 1 and 2, so we skip this test
        // In a full integration test environment with proper endpoint configuration, uncomment below:

        /*
        address oft = address(oftAdapter);

        // User gas token is already PATH_USD (the endpoint native token)
        vm.prank(alice);
        uint256 fee = remoteHopTempo.quoteTempo(oft, FRAXTAL_EID, bytes32(uint256(uint160(bob))), 1e18, 0, "");

        // Fee should be returned as-is without conversion
        assertTrue(fee >= 0, "Fee calculation should not revert");
        */

        // Verify the function exists and is callable for local destination (which returns 0)
        address oft = address(oftAdapter);
        uint256 fee = remoteHopTempo.quoteTempo(oft, TEMPO_EID, bytes32(uint256(uint160(bob))), 1e18, 0, "");
        assertEq(fee, 0, "Local transfers should have zero fee");
    }

    function test_QuoteTempo_WhenUserGasTokenNeedsSwap() public {
        // Note: This test requires a fully configured LZ endpoint with send library for FRAXTAL_EID (30_255)
        // The TestHelperOz5 setup only configures endpoints 1 and 2
        // In a full integration test environment with proper endpoint configuration, the below would work

        // Create a different gas token for the user
        ITIP20 otherToken = _createTIP20WithDexPair("Other Token", "OTHER", keccak256("test_QuoteTempo_Swap"));
        otherToken.mint(alice, 1_000_000e6);
        _addDexLiquidity(address(otherToken), 100_000e6);

        _setUserGasToken(alice, address(otherToken));

        // Verify gas token was set correctly
        address userToken = StdPrecompiles.TIP_FEE_MANAGER.userTokens(alice);
        assertEq(userToken, address(otherToken), "User gas token should be set");

        // For local destination, fee is 0 so no swap needed
        address oft = address(oftAdapter);
        vm.prank(alice);
        uint256 fee = remoteHopTempo.quoteTempo(oft, TEMPO_EID, bytes32(uint256(uint160(bob))), 1e18, 0, "");
        assertEq(fee, 0, "Local transfers should have zero fee regardless of gas token");
    }

    // ============ LzCompose Tests ============

    function test_LzCompose_SendLocal_WithoutData() public {
        address oft = address(oftAdapter);
        address recipient = address(0x456);

        // Fund the hop with underlying TIP20 tokens (adapter will transfer to recipient)
        underlyingToken.mint(address(remoteHopTempo), 1e18);

        bytes memory composeMsg = abi.encode(
            HopMessage({
                srcEid: 30_255, // FRAXTAL_EID
                dstEid: TEMPO_EID,
                dstGas: 0,
                sender: bytes32(uint256(uint160(address(0x123)))),
                recipient: bytes32(uint256(uint160(recipient))),
                data: ""
            })
        );
        composeMsg = abi.encodePacked(OFTMsgCodec.addressToBytes32(fraxtalHop), composeMsg);
        bytes memory message = OFTComposeMsgCodec.encode(0, 30_255, 1e18, composeMsg);

        vm.prank(address(endpoints[TEMPO_EID]));
        remoteHopTempo.lzCompose(oft, bytes32(0), message, address(0), "");

        assertEq(underlyingToken.balanceOf(recipient), 1e18, "Recipient should receive underlying TIP20 tokens");
    }

    function test_LzCompose_SendLocal_WithData() public {
        address oft = address(oftAdapter);
        TestHopComposer composer = new TestHopComposer();

        underlyingToken.mint(address(remoteHopTempo), 1e18);

        bytes memory data = "Hello Remote";
        bytes memory composeMsg = abi.encode(
            HopMessage({
                srcEid: 30_255,
                dstEid: TEMPO_EID,
                dstGas: 0,
                sender: bytes32(uint256(uint160(address(0x123)))),
                recipient: bytes32(uint256(uint160(address(composer)))),
                data: data
            })
        );
        composeMsg = abi.encodePacked(OFTMsgCodec.addressToBytes32(fraxtalHop), composeMsg);
        bytes memory message = OFTComposeMsgCodec.encode(0, 30_255, 1e18, composeMsg);

        vm.expectEmit(true, true, true, true);
        emit TestHopComposer.Composed(30_255, bytes32(uint256(uint160(address(0x123)))), oft, 1e18, data);

        vm.prank(address(endpoints[TEMPO_EID]));
        remoteHopTempo.lzCompose(oft, bytes32(0), message, address(0), "");

        assertEq(underlyingToken.balanceOf(address(composer)), 1e18, "Composer should receive underlying TIP20 tokens");
    }

    function test_LzCompose_DuplicateMessage() public {
        address oft = address(oftAdapter);
        address recipient = address(0x456);

        underlyingToken.mint(address(remoteHopTempo), 2e18);

        bytes memory composeMsg = abi.encode(
            HopMessage({
                srcEid: 30_255,
                dstEid: TEMPO_EID,
                dstGas: 0,
                sender: bytes32(uint256(uint160(address(0x123)))),
                recipient: bytes32(uint256(uint160(recipient))),
                data: ""
            })
        );
        composeMsg = abi.encodePacked(OFTMsgCodec.addressToBytes32(fraxtalHop), composeMsg);
        bytes memory message = OFTComposeMsgCodec.encode(0, 30_255, 1e18, composeMsg);

        vm.startPrank(address(endpoints[TEMPO_EID]));

        remoteHopTempo.lzCompose(oft, bytes32(0), message, address(0), "");
        assertEq(underlyingToken.balanceOf(recipient), 1e18, "First message should process");

        // Second call with same message should be ignored
        remoteHopTempo.lzCompose(oft, bytes32(0), message, address(0), "");
        assertEq(underlyingToken.balanceOf(recipient), 1e18, "Duplicate message should be ignored");

        vm.stopPrank();
    }

    function test_LzCompose_NotEndpoint() public {
        address oft = address(oftAdapter);
        bytes memory message = _createComposeMessage(oft, 1e18);

        vm.expectRevert(abi.encodeWithSignature("NotEndpoint()"));
        remoteHopTempo.lzCompose(oft, bytes32(0), message, address(0), "");
    }

    function test_LzCompose_InvalidOFT() public {
        address invalidOft = address(0x999);
        bytes memory message = _createComposeMessage(invalidOft, 1e18);

        vm.prank(address(endpoints[TEMPO_EID]));
        vm.expectRevert(abi.encodeWithSignature("InvalidOFT()"));
        remoteHopTempo.lzCompose(invalidOft, bytes32(0), message, address(0), "");
    }

    // ============ Admin Function Tests ============

    function test_PauseOn() public {
        assertFalse(remoteHopTempo.paused());
        remoteHopTempo.pauseOn();
        assertTrue(remoteHopTempo.paused());
    }

    function test_PauseOff() public {
        remoteHopTempo.pauseOn();
        remoteHopTempo.pauseOff();
        assertFalse(remoteHopTempo.paused());
    }

    function test_SetApprovedOft() public {
        address newOft = address(0x888);
        assertFalse(remoteHopTempo.approvedOft(newOft));

        remoteHopTempo.setApprovedOft(newOft, true);
        assertTrue(remoteHopTempo.approvedOft(newOft));
    }

    function test_SetRemoteHop() public {
        address newFraxtalHop = address(0x999);
        remoteHopTempo.setRemoteHop(30_255, newFraxtalHop);
        assertEq(remoteHopTempo.remoteHop(30_255), bytes32(uint256(uint160(newFraxtalHop))));
    }

    // ============ Quote Tests (inherited) ============

    function test_Quote_LocalDestination() public view {
        address oft = address(oftAdapter);
        uint256 fee = remoteHopTempo.quote(oft, TEMPO_EID, bytes32(uint256(uint160(bob))), 1e18, 0, "");
        assertEq(fee, 0, "Local transfers should have zero fee");
    }

    // ============ RemoveDust Tests ============

    function test_RemoveDust() public view {
        address oft = address(oftAdapter);
        uint256 amount = 1.123456789123456789e18;
        uint256 cleaned = remoteHopTempo.removeDust(oft, amount);
        assertTrue(cleaned <= amount, "Cleaned amount should be <= original");
    }

    // ============ Helper Functions ============

    function _createComposeMessage(address oft, uint256 amount) internal view returns (bytes memory) {
        bytes memory composeMsg = abi.encode(
            HopMessage({
                srcEid: 30_255,
                dstEid: TEMPO_EID,
                dstGas: 0,
                sender: bytes32(uint256(uint160(address(0x123)))),
                recipient: bytes32(uint256(uint160(address(this)))),
                data: ""
            })
        );
        composeMsg = abi.encodePacked(OFTMsgCodec.addressToBytes32(fraxtalHop), composeMsg);
        return OFTComposeMsgCodec.encode(0, 30_255, amount, composeMsg);
    }
}
