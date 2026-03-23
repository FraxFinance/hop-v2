// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

import { OptionsBuilder } from "@layerzerolabs/oapp-evm/contracts/oapp/libs/OptionsBuilder.sol";
import { OFTMsgCodec } from "@layerzerolabs/oft-evm/contracts/libs/OFTMsgCodec.sol";
import { OFTComposeMsgCodec } from "@layerzerolabs/oft-evm/contracts/libs/OFTComposeMsgCodec.sol";
import { TestHelperOz5 } from "@layerzerolabs/test-devtools-evm-foundry/contracts/TestHelperOz5.sol";
import { TransparentUpgradeableProxy } from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import { SendParam, MessagingFee, OFTReceipt } from "@layerzerolabs/oft-evm/contracts/interfaces/IOFT.sol";
import { MessagingReceipt } from "@layerzerolabs/lz-evm-protocol-v2/contracts/interfaces/ILayerZeroEndpointV2.sol";
import { ILayerZeroComposer } from "@layerzerolabs/lz-evm-protocol-v2/contracts/interfaces/ILayerZeroComposer.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";

import { HopMessage } from "src/contracts/interfaces/IHopV2.sol";
import { IHopComposer } from "src/contracts/interfaces/IHopComposer.sol";

import { ITIP20 } from "tempo-std/interfaces/ITIP20.sol";
import { ITIP20RolesAuth } from "tempo-std/interfaces/ITIP20RolesAuth.sol";
import { ITIP20Factory } from "tempo-std/interfaces/ITIP20Factory.sol";
import { StdPrecompiles } from "tempo-std/StdPrecompiles.sol";
import { StdTokens } from "tempo-std/StdTokens.sol";

import { TempoTestHelpers } from "./helpers/TempoTestHelpers.sol";

// Mock imports
import { MockERC20 } from "./mocks/MockERC20.sol";
import { ChainAOFTMock } from "./mocks/ChainAOFTMock.sol";
import { FraxtalOFTAdapterMock } from "./mocks/FraxtalOFTAdapterMock.sol";
import { TIP20OFTAdapterAltMock } from "./mocks/TIP20OFTAdapterAltMock.sol";
import { RemoteHopV2Mock } from "./mocks/RemoteHopV2Mock.sol";
import { FraxtalHopV2Mock } from "./mocks/FraxtalHopV2Mock.sol";
import { RemoteHopV2TempoMock } from "./mocks/RemoteHopV2TempoMock.sol";
import { MockDVN } from "./mocks/MockDVN.sol";
import { MockExecutor } from "./mocks/MockExecutor.sol";
import { MockTreasury } from "./mocks/MockTreasury.sol";

import "forge-std/console2.sol";

/// @title ThreeChainHopTest
/// @notice Tests 3-chain hub-and-spoke architecture: Chain A ↔ Fraxtal (hub) ↔ Tempo
/// @dev Tests compose message flows through FraxtalHopV2 hub
///
/// Architecture (using sequential mock EIDs):
/// - Chain A (EID 1): OFT + RemoteHopV2Mock - uses native ETH for gas
/// - Fraxtal (EID 2): OFTAdapter + FraxtalHopV2Mock (HUB) - uses native ETH for gas
/// - Tempo (EID 3): OFTAdapterAlt (wrapping TIP20) + RemoteHopV2TempoMock - uses ERC20 (PATH_USD) for gas
///
/// Note: Uses mock Hop contracts with configurable HUB_EID to match the sequential
/// EIDs created by TestHelperOz5 (1, 2, 3).
///
/// Flow A → Tempo:
/// 1. User calls RemoteHopV2Mock.sendOFT() on Chain A
/// 2. OFT bridges to FraxtalHopV2Mock with compose message
/// 3. Executor calls lzCompose on FraxtalHopV2Mock
/// 4. FraxtalHopV2Mock bridges to recipient on Tempo
///
/// Flow Tempo → A:
/// 1. User calls RemoteHopV2TempoMock.sendOFT() on Tempo
/// 2. OFT bridges to FraxtalHopV2Mock with compose message
/// 3. Executor calls lzCompose on FraxtalHopV2Mock
/// 4. FraxtalHopV2Mock bridges to recipient on Chain A
contract ThreeChainHopTest is TestHelperOz5, TempoTestHelpers {
    using OptionsBuilder for bytes;

    // ============ Chain EIDs (sequential mock EIDs from TestHelperOz5) ============
    // TestHelperOz5.createEndpoints() uses sequential EIDs starting from 1
    uint32 constant CHAIN_A_EID = 1; // Mock Chain A
    uint32 constant FRAXTAL_EID = 2; // Mock Fraxtal hub
    uint32 constant TEMPO_EID = 3; // Mock Tempo

    // ============ Chain A Contracts ============
    ChainAOFTMock chainAOft;
    RemoteHopV2Mock remoteHopA;

    // ============ Fraxtal Contracts (Hub) ============
    MockERC20 fraxtalToken;
    FraxtalOFTAdapterMock fraxtalAdapter;
    FraxtalHopV2Mock fraxtalHop;

    // ============ Tempo Contracts ============
    ITIP20 tempoToken; // Underlying TIP20 token on Tempo
    TIP20OFTAdapterAltMock tempoAdapter; // OFTAdapterAlt wrapping TIP20
    RemoteHopV2TempoMock remoteHopTempo;

    // ============ Test Users ============
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    address proxyAdmin = makeAddr("proxyAdmin");

    // ============ Mock LZ Infrastructure ============
    MockDVN mockDVN;
    MockExecutor mockExecutor;
    MockTreasury mockTreasury;
    uint32 constant NUM_DVNS = 1;

    uint256 initialBalance = 100e18; // For 18 decimal tokens (Chain A, Fraxtal)
    uint256 initialBalanceTempo = 100e6; // For 6 decimal TIP20 token (Tempo)

    function setUp() public virtual override {
        vm.deal(alice, 1000 ether);
        vm.deal(bob, 1000 ether);

        // Deploy mock LZ infrastructure
        mockDVN = new MockDVN();
        mockExecutor = new MockExecutor();
        mockTreasury = new MockTreasury();

        super.setUp();

        // Setup 3 LayerZero endpoints
        // TestHelperOz5.createEndpoints() creates endpoints with EIDs 1, 2, 3
        // Chain A (EID 1) uses native ETH
        // Fraxtal (EID 2) uses native ETH
        // Tempo (EID 3) uses PATH_USD (ERC20)
        address[] memory altTokens = new address[](3);
        altTokens[0] = address(0); // Chain A - native ETH
        altTokens[1] = address(0); // Fraxtal - native ETH
        altTokens[2] = StdTokens.PATH_USD_ADDRESS; // Tempo - PATH_USD

        // Create 3 endpoints with sequential EIDs (1, 2, 3)
        createEndpoints(3, LibraryType.UltraLightNode, altTokens);

        // Deploy contracts on each chain
        _deployChainAContracts();
        _deployFraxtalContracts();
        _deployTempoContracts();

        // Wire OFTs as peers across all 3 chains
        _wireOFTs();

        // Configure Hop contracts
        _configureHops();

        // Setup users with tokens
        _setupUsers();
    }

    // ═══════════════════════════════════════════════════════════════════════════════════════
    // DEPLOYMENT
    // ═══════════════════════════════════════════════════════════════════════════════════════

    function _deployChainAContracts() internal {
        // Deploy OFT on Chain A (EID 1 = endpoint index 1)
        chainAOft = ChainAOFTMock(
            _deployOApp(
                type(ChainAOFTMock).creationCode,
                abi.encode("FRAX on Chain A", "FRAX", address(endpoints[CHAIN_A_EID]), address(this))
            )
        );

        // Deploy RemoteHopV2Mock on Chain A with FRAXTAL_EID as hub
        address[] memory approvedOfts = new address[](1);
        approvedOfts[0] = address(chainAOft);

        RemoteHopV2Mock implementation = new RemoteHopV2Mock(FRAXTAL_EID);
        bytes memory initializeArgs = abi.encodeWithSignature(
            "initialize(uint32,address,bytes32,uint32,address,address,address,address[])",
            CHAIN_A_EID,
            address(endpoints[CHAIN_A_EID]),
            bytes32(0), // Will set fraxtalHop later
            NUM_DVNS,
            address(mockExecutor),
            address(mockDVN),
            address(mockTreasury),
            approvedOfts
        );

        TransparentUpgradeableProxy proxy = new TransparentUpgradeableProxy(
            address(implementation),
            proxyAdmin,
            initializeArgs
        );
        remoteHopA = RemoteHopV2Mock(payable(address(proxy)));

        // Fund the hop with ETH for refunds
        (bool remoteHopAFunded, ) = payable(address(remoteHopA)).call{ value: 10 ether }("");
        assertTrue(remoteHopAFunded, "Remote hop funding failed");
    }

    function _deployFraxtalContracts() internal {
        // Deploy underlying ERC20 on Fraxtal (EID 2 = endpoint index 2)
        fraxtalToken = new MockERC20("FRAX on Fraxtal", "FRAX", 18);

        // Deploy OFT Adapter on Fraxtal
        fraxtalAdapter = FraxtalOFTAdapterMock(
            _deployOApp(
                type(FraxtalOFTAdapterMock).creationCode,
                abi.encode(address(fraxtalToken), address(endpoints[FRAXTAL_EID]), address(this))
            )
        );

        // Deploy FraxtalHopV2Mock (the hub) with FRAXTAL_EID as its own hub EID
        address[] memory approvedOfts = new address[](1);
        approvedOfts[0] = address(fraxtalAdapter);

        FraxtalHopV2Mock implementation = new FraxtalHopV2Mock(FRAXTAL_EID);
        bytes memory initializeArgs = abi.encodeWithSignature(
            "initialize(uint32,address,uint32,address,address,address,address[])",
            FRAXTAL_EID,
            address(endpoints[FRAXTAL_EID]),
            NUM_DVNS,
            address(mockExecutor),
            address(mockDVN),
            address(mockTreasury),
            approvedOfts
        );

        TransparentUpgradeableProxy proxy = new TransparentUpgradeableProxy(
            address(implementation),
            proxyAdmin,
            initializeArgs
        );
        fraxtalHop = FraxtalHopV2Mock(payable(address(proxy)));

        // Fund the hop with ETH for gas
        (bool fraxtalHopFunded, ) = payable(address(fraxtalHop)).call{ value: 10 ether }("");
        assertTrue(fraxtalHopFunded, "Fraxtal hop funding failed");

        // Pre-fund adapter with tokens (for lock/unlock pattern)
        fraxtalToken.mint(address(fraxtalAdapter), 1_000_000e18);
    }

    function _deployTempoContracts() internal {
        // Grant PATH_USD issuer role for gas payments
        _grantPathUsdIssuerRole(address(this));

        // Create TIP20 token on Tempo via factory (EID 3 = endpoint index 3)
        tempoToken = ITIP20(
            ITIP20Factory(address(StdPrecompiles.TIP20_FACTORY)).createToken(
                "FRAX on Tempo",
                "frxUSD",
                "USD",
                ITIP20(StdTokens.PATH_USD_ADDRESS),
                address(this),
                keccak256("ThreeChainHopTest-tempoToken")
            )
        );

        // Grant ISSUER_ROLE to test contract for minting
        ITIP20RolesAuth(address(tempoToken)).grantRole(tempoToken.ISSUER_ROLE(), address(this));

        // Deploy TIP20OFTAdapterAlt wrapping the TIP20 token
        tempoAdapter = TIP20OFTAdapterAltMock(
            _deployOApp(
                type(TIP20OFTAdapterAltMock).creationCode,
                abi.encode(address(tempoToken), address(endpoints[TEMPO_EID]), address(this))
            )
        );

        // Grant ISSUER_ROLE to adapter for mint/burn operations
        ITIP20RolesAuth(address(tempoToken)).grantRole(tempoToken.ISSUER_ROLE(), address(tempoAdapter));

        // Deploy RemoteHopV2TempoMock with FRAXTAL_EID as hub
        address[] memory approvedOfts = new address[](1);
        approvedOfts[0] = address(tempoAdapter);

        RemoteHopV2TempoMock implementation = new RemoteHopV2TempoMock(address(endpoints[TEMPO_EID]), FRAXTAL_EID);
        bytes memory initializeArgs = abi.encodeWithSignature(
            "initialize(uint32,address,bytes32,uint32,address,address,address,address[])",
            TEMPO_EID,
            address(endpoints[TEMPO_EID]),
            bytes32(0), // Will set fraxtalHop later
            NUM_DVNS,
            address(mockExecutor),
            address(mockDVN),
            address(mockTreasury),
            approvedOfts
        );

        TransparentUpgradeableProxy proxy = new TransparentUpgradeableProxy(
            address(implementation),
            proxyAdmin,
            initializeArgs
        );
        remoteHopTempo = RemoteHopV2TempoMock(payable(address(proxy)));
    }

    function _wireOFTs() internal {
        // Set OFT peers using mock EIDs (1, 2, 3)
        bytes32 chainAOftPeer = addressToBytes32(address(chainAOft));
        bytes32 fraxtalAdapterPeer = addressToBytes32(address(fraxtalAdapter));
        bytes32 tempoAdapterPeer = addressToBytes32(address(tempoAdapter));

        // Chain A OFT peers (knows about Fraxtal and Tempo)
        chainAOft.setPeer(FRAXTAL_EID, fraxtalAdapterPeer);
        chainAOft.setPeer(TEMPO_EID, tempoAdapterPeer);

        // Fraxtal Adapter peers (knows about Chain A and Tempo)
        fraxtalAdapter.setPeer(CHAIN_A_EID, chainAOftPeer);
        fraxtalAdapter.setPeer(TEMPO_EID, tempoAdapterPeer);

        // Tempo Adapter peers (knows about Chain A and Fraxtal)
        tempoAdapter.setPeer(CHAIN_A_EID, chainAOftPeer);
        tempoAdapter.setPeer(FRAXTAL_EID, fraxtalAdapterPeer);
    }

    function _configureHops() internal {
        // Set FraxtalHop as the remote hop on Chain A
        remoteHopA.setRemoteHop(FRAXTAL_EID, address(fraxtalHop));

        // Set FraxtalHop as the remote hop on Tempo
        remoteHopTempo.setRemoteHop(FRAXTAL_EID, address(fraxtalHop));

        // Set remote hops on FraxtalHop (for forwarding)
        fraxtalHop.setRemoteHop(CHAIN_A_EID, address(remoteHopA));
        fraxtalHop.setRemoteHop(TEMPO_EID, address(remoteHopTempo));
    }

    function _setupUsers() internal {
        // Mint tokens on Chain A (OFT - mint/burn)
        chainAOft.mint(alice, initialBalance);
        chainAOft.mint(bob, initialBalance);

        // Mint tokens on Fraxtal (ERC20 for OFTAdapter - lock/unlock)
        fraxtalToken.mint(alice, initialBalance);
        fraxtalToken.mint(bob, initialBalance);

        // Mint underlying TIP20 tokens on Tempo (for OFTAdapterAlt - mint/burn)
        // TIP20 has 6 decimals, so use initialBalanceTempo
        tempoToken.mint(alice, initialBalanceTempo);
        tempoToken.mint(bob, initialBalanceTempo);

        // Mint PATH_USD for gas on Tempo
        StdTokens.PATH_USD.mint(alice, 1_000_000e6);
        StdTokens.PATH_USD.mint(bob, 1_000_000e6);

        // Set user gas tokens on Tempo
        _setUserGasToken(alice, StdTokens.PATH_USD_ADDRESS);
        _setUserGasToken(bob, StdTokens.PATH_USD_ADDRESS);
    }

    // ═══════════════════════════════════════════════════════════════════════════════════════
    // TEST: Chain A → Fraxtal → Tempo (Full hop)
    // ═══════════════════════════════════════════════════════════════════════════════════════

    /// @notice Test: Chain A → Tempo via Fraxtal hub
    function test_ChainA_to_Tempo_via_Fraxtal() public {
        // Chain A uses 18 decimals, Tempo uses 6 decimals
        uint256 sendAmountChainA = 10e18; // 10 tokens in Chain A (18 decimals)
        uint256 receiveAmountFraxtal = 10e18; // Fraxtal also has 18 decimals
        uint256 receiveAmountTempo = 10e6; // 10 tokens in Tempo (6 decimals)
        uint256 aliceChainABalanceBefore = chainAOft.balanceOf(alice);
        uint256 bobTempoBalanceBefore = tempoToken.balanceOf(bob);

        vm.startPrank(alice);

        // Get quote for the hop
        uint256 fee = remoteHopA.quote(
            address(chainAOft),
            TEMPO_EID,
            OFTMsgCodec.addressToBytes32(bob),
            sendAmountChainA,
            400_000,
            ""
        );

        // Approve OFT to RemoteHopV2
        chainAOft.approve(address(remoteHopA), sendAmountChainA);

        // Send via RemoteHopV2 on Chain A - destination is Tempo
        remoteHopA.sendOFT{ value: fee }(
            address(chainAOft),
            TEMPO_EID,
            OFTMsgCodec.addressToBytes32(bob),
            sendAmountChainA,
            400_000,
            ""
        );

        vm.stopPrank();

        // Verify burned on Chain A
        assertEq(
            chainAOft.balanceOf(alice),
            aliceChainABalanceBefore - sendAmountChainA,
            "Alice's tokens should be burned on Chain A"
        );

        // Step 1: Deliver lzReceive to Fraxtal (credits tokens to FraxtalHop)
        // This queues the compose message for FraxtalHop
        verifyPackets(FRAXTAL_EID, addressToBytes32(address(fraxtalAdapter)));

        // Step 2: Manually trigger lzCompose on FraxtalHop
        // Build the compose message in OFT format
        bytes memory hopMessage = abi.encode(
            HopMessage({
                srcEid: CHAIN_A_EID,
                dstEid: TEMPO_EID,
                dstGas: 400_000,
                sender: OFTMsgCodec.addressToBytes32(alice),
                recipient: OFTMsgCodec.addressToBytes32(bob),
                data: ""
            })
        );
        // Prepend the RemoteHop address as composeFrom
        bytes memory composeMsg = abi.encodePacked(OFTMsgCodec.addressToBytes32(address(remoteHopA)), hopMessage);
        // Wrap in OFT compose format
        bytes memory oftComposeMsg = OFTComposeMsgCodec.encode(
            1, // nonce
            CHAIN_A_EID, // srcEid
            receiveAmountFraxtal, // amountLD credited to FraxtalHop
            composeMsg
        );

        // Call lzCompose as if from endpoint
        vm.prank(address(endpoints[FRAXTAL_EID]));
        ILayerZeroComposer(address(fraxtalHop)).lzCompose(
            address(fraxtalAdapter), // _from (the OFT that called sendCompose)
            bytes32(0), // guid (not validated in our mock)
            oftComposeMsg,
            address(this), // executor
            ""
        );

        // Step 3: Deliver packets from Fraxtal to Tempo (second hop)
        verifyPackets(TEMPO_EID, addressToBytes32(address(tempoAdapter)));

        // Verify minted on Tempo (check underlying TIP20 balance)
        // TIP20 has 6 decimals, so 10e18 on Chain A = 10e6 on Tempo
        assertEq(
            tempoToken.balanceOf(bob),
            bobTempoBalanceBefore + receiveAmountTempo,
            "Bob should receive tokens on Tempo"
        );
    }

    /// @notice Test: Tempo → Chain A via Fraxtal hub
    function test_Tempo_to_ChainA_via_Fraxtal() public {
        // Tempo uses 6 decimals, but message converts to 18 decimal equivalent on destination
        uint256 sendAmountTempo = 10e6; // 10 tokens in TIP20 (6 decimals)
        uint256 receiveAmountFraxtal = 10e18; // Fraxtal has 18 decimals
        uint256 receiveAmountChainA = 10e18; // 10 tokens in Chain A (18 decimals)
        uint256 aliceTempoBalanceBefore = tempoToken.balanceOf(alice);
        uint256 bobChainABalanceBefore = chainAOft.balanceOf(bob);

        vm.startPrank(alice);

        uint256 nativeFee = remoteHopTempo.quote(
            address(tempoAdapter),
            CHAIN_A_EID,
            OFTMsgCodec.addressToBytes32(bob),
            sendAmountTempo,
            400_000,
            ""
        );
        uint256 fee = remoteHopTempo.quoteStatic(
            address(tempoAdapter),
            CHAIN_A_EID,
            OFTMsgCodec.addressToBytes32(bob),
            sendAmountTempo,
            400_000,
            "",
            StdTokens.PATH_USD_ADDRESS
        );
        assertEq(fee, nativeFee, "PATH_USD quoteStatic should be 1:1 with native quote");

        // Approve underlying TIP20 token to adapter (adapter pulls and burns)
        IERC20(address(tempoToken)).approve(address(tempoAdapter), sendAmountTempo);

        // Approve adapter to RemoteHopV2Tempo
        // Note: RemoteHopV2Tempo calls adapter.send(), which pulls from user
        IERC20(address(tempoToken)).approve(address(remoteHopTempo), sendAmountTempo);

        // Approve PATH_USD for gas payment
        IERC20(StdTokens.PATH_USD_ADDRESS).approve(address(remoteHopTempo), fee);

        // Send via RemoteHopV2Tempo on Tempo - destination is Chain A
        // Note: msg.value = 0 because Tempo uses ERC20 for gas
        remoteHopTempo.sendOFT(
            address(tempoAdapter),
            CHAIN_A_EID,
            OFTMsgCodec.addressToBytes32(bob),
            sendAmountTempo,
            400_000,
            ""
        );

        vm.stopPrank();

        // Verify burned on Tempo (check underlying TIP20 balance)
        assertEq(
            tempoToken.balanceOf(alice),
            aliceTempoBalanceBefore - sendAmountTempo,
            "Alice's tokens should be burned on Tempo"
        );

        // Step 1: Deliver lzReceive to Fraxtal (credits tokens to FraxtalHop)
        verifyPackets(FRAXTAL_EID, addressToBytes32(address(fraxtalAdapter)));

        // Step 2: Manually trigger lzCompose on FraxtalHop
        bytes memory hopMessage = abi.encode(
            HopMessage({
                srcEid: TEMPO_EID,
                dstEid: CHAIN_A_EID,
                dstGas: 400_000,
                sender: OFTMsgCodec.addressToBytes32(alice),
                recipient: OFTMsgCodec.addressToBytes32(bob),
                data: ""
            })
        );
        bytes memory composeMsg = abi.encodePacked(OFTMsgCodec.addressToBytes32(address(remoteHopTempo)), hopMessage);
        bytes memory oftComposeMsg = OFTComposeMsgCodec.encode(
            1, // nonce
            TEMPO_EID, // srcEid
            receiveAmountFraxtal, // amountLD credited to FraxtalHop
            composeMsg
        );

        vm.prank(address(endpoints[FRAXTAL_EID]));
        ILayerZeroComposer(address(fraxtalHop)).lzCompose(
            address(fraxtalAdapter),
            bytes32(0),
            oftComposeMsg,
            address(this),
            ""
        );

        // Step 3: Deliver packets from Fraxtal to Chain A (second hop)
        verifyPackets(CHAIN_A_EID, addressToBytes32(address(chainAOft)));

        // Verify minted on Chain A
        assertEq(
            chainAOft.balanceOf(bob),
            bobChainABalanceBefore + receiveAmountChainA,
            "Bob should receive tokens on Chain A"
        );
    }

    // ═══════════════════════════════════════════════════════════════════════════════════════
    // TEST: Direct sends (not through hop)
    // ═══════════════════════════════════════════════════════════════════════════════════════

    /// @notice Test: Chain A → Fraxtal direct (no hop to Tempo)
    function test_ChainA_to_Fraxtal_Direct() public {
        uint256 sendAmount = 10e18;
        uint256 aliceChainABalanceBefore = chainAOft.balanceOf(alice);
        uint256 bobFraxtalBalanceBefore = fraxtalToken.balanceOf(bob);

        vm.startPrank(alice);

        // Quote for direct send to Fraxtal (dstEid = FRAXTAL_EID)
        uint256 fee = remoteHopA.quote(
            address(chainAOft),
            FRAXTAL_EID,
            OFTMsgCodec.addressToBytes32(bob),
            sendAmount,
            0, // No compose needed for direct send
            ""
        );

        chainAOft.approve(address(remoteHopA), sendAmount);

        // Send to Fraxtal directly
        remoteHopA.sendOFT{ value: fee }(
            address(chainAOft),
            FRAXTAL_EID,
            OFTMsgCodec.addressToBytes32(bob),
            sendAmount,
            0,
            ""
        );

        vm.stopPrank();

        // Verify burned on Chain A
        assertEq(
            chainAOft.balanceOf(alice),
            aliceChainABalanceBefore - sendAmount,
            "Alice's tokens should be burned on Chain A"
        );

        // Deliver to Fraxtal
        verifyPackets(FRAXTAL_EID, addressToBytes32(address(fraxtalAdapter)));

        // Verify unlocked on Fraxtal
        assertEq(
            fraxtalToken.balanceOf(bob),
            bobFraxtalBalanceBefore + sendAmount,
            "Bob should receive tokens on Fraxtal"
        );
    }

    /// @notice Test: Tempo → Fraxtal direct
    function test_Tempo_to_Fraxtal_Direct() public {
        // Tempo uses 6 decimals, Fraxtal uses 18 decimals
        uint256 sendAmountTempo = 10e6; // 10 tokens in TIP20 (6 decimals)
        uint256 receiveAmountFraxtal = 10e18; // 10 tokens in Fraxtal (18 decimals)
        uint256 aliceTempoBalanceBefore = tempoToken.balanceOf(alice);
        uint256 bobFraxtalBalanceBefore = fraxtalToken.balanceOf(bob);

        vm.startPrank(alice);

        uint256 nativeFee = remoteHopTempo.quote(
            address(tempoAdapter),
            FRAXTAL_EID,
            OFTMsgCodec.addressToBytes32(bob),
            sendAmountTempo,
            0,
            ""
        );
        uint256 fee = remoteHopTempo.quoteStatic(
            address(tempoAdapter),
            FRAXTAL_EID,
            OFTMsgCodec.addressToBytes32(bob),
            sendAmountTempo,
            0,
            "",
            StdTokens.PATH_USD_ADDRESS
        );
        assertEq(fee, nativeFee, "PATH_USD quoteStatic should be 1:1 with native quote");

        // Approve underlying TIP20 token
        IERC20(address(tempoToken)).approve(address(tempoAdapter), sendAmountTempo);
        IERC20(address(tempoToken)).approve(address(remoteHopTempo), sendAmountTempo);
        IERC20(StdTokens.PATH_USD_ADDRESS).approve(address(remoteHopTempo), fee);

        remoteHopTempo.sendOFT(
            address(tempoAdapter),
            FRAXTAL_EID,
            OFTMsgCodec.addressToBytes32(bob),
            sendAmountTempo,
            0,
            ""
        );

        vm.stopPrank();

        // Verify burned on Tempo
        assertEq(
            tempoToken.balanceOf(alice),
            aliceTempoBalanceBefore - sendAmountTempo,
            "Alice's tokens should be burned on Tempo"
        );

        // Deliver to Fraxtal
        verifyPackets(FRAXTAL_EID, addressToBytes32(address(fraxtalAdapter)));

        // Verify unlocked on Fraxtal
        assertEq(
            fraxtalToken.balanceOf(bob),
            bobFraxtalBalanceBefore + receiveAmountFraxtal,
            "Bob should receive tokens on Fraxtal"
        );
    }

    // ═══════════════════════════════════════════════════════════════════════════════════════
    // TEST: Quote functions
    // ═══════════════════════════════════════════════════════════════════════════════════════

    function test_Quote_ChainA_to_Tempo() public view {
        uint256 fee = remoteHopA.quote(
            address(chainAOft),
            TEMPO_EID,
            OFTMsgCodec.addressToBytes32(bob),
            10e18,
            400_000,
            ""
        );
        assertGt(fee, 0, "Fee should be non-zero for cross-chain hop");
    }

    function test_Quote_Tempo_to_ChainA() public view {
        uint256 fee = remoteHopTempo.quote(
            address(tempoAdapter),
            CHAIN_A_EID,
            OFTMsgCodec.addressToBytes32(bob),
            10e18,
            400_000,
            ""
        );
        assertGt(fee, 0, "Fee should be non-zero for cross-chain hop");
    }

    // ═══════════════════════════════════════════════════════════════════════════════════════
    // TEST: Configuration
    // ═══════════════════════════════════════════════════════════════════════════════════════

    function test_RemoteHops_Configured() public view {
        // Chain A's remote hop should point to FraxtalHop
        assertEq(
            remoteHopA.remoteHop(FRAXTAL_EID),
            OFTMsgCodec.addressToBytes32(address(fraxtalHop)),
            "Chain A remote hop should be FraxtalHop"
        );

        // Tempo's remote hop should point to FraxtalHop
        assertEq(
            remoteHopTempo.remoteHop(FRAXTAL_EID),
            OFTMsgCodec.addressToBytes32(address(fraxtalHop)),
            "Tempo remote hop should be FraxtalHop"
        );

        // FraxtalHop should have remote hops to Chain A and Tempo
        assertEq(
            fraxtalHop.remoteHop(CHAIN_A_EID),
            OFTMsgCodec.addressToBytes32(address(remoteHopA)),
            "FraxtalHop should have Chain A remote hop"
        );
        assertEq(
            fraxtalHop.remoteHop(TEMPO_EID),
            OFTMsgCodec.addressToBytes32(address(remoteHopTempo)),
            "FraxtalHop should have Tempo remote hop"
        );
    }

    function test_OFT_Peers_Configured() public view {
        // Check Chain A OFT peers
        assertEq(
            chainAOft.peers(FRAXTAL_EID),
            OFTMsgCodec.addressToBytes32(address(fraxtalAdapter)),
            "Chain A OFT peer should be Fraxtal adapter"
        );
        assertEq(
            chainAOft.peers(TEMPO_EID),
            OFTMsgCodec.addressToBytes32(address(tempoAdapter)),
            "Chain A OFT peer should be Tempo adapter"
        );

        // Check Fraxtal adapter peers
        assertEq(
            fraxtalAdapter.peers(CHAIN_A_EID),
            OFTMsgCodec.addressToBytes32(address(chainAOft)),
            "Fraxtal adapter peer should be Chain A OFT"
        );
        assertEq(
            fraxtalAdapter.peers(TEMPO_EID),
            OFTMsgCodec.addressToBytes32(address(tempoAdapter)),
            "Fraxtal adapter peer should be Tempo adapter"
        );

        // Check Tempo adapter peers
        assertEq(
            tempoAdapter.peers(CHAIN_A_EID),
            OFTMsgCodec.addressToBytes32(address(chainAOft)),
            "Tempo adapter peer should be Chain A OFT"
        );
        assertEq(
            tempoAdapter.peers(FRAXTAL_EID),
            OFTMsgCodec.addressToBytes32(address(fraxtalAdapter)),
            "Tempo adapter peer should be Fraxtal adapter"
        );
    }

    // ═══════════════════════════════════════════════════════════════════════════════════════
    // TEST: Tempo sendOFT reverts when msg.value > 0
    // ═══════════════════════════════════════════════════════════════════════════════════════

    /// @notice sendOFT reverts with MsgValueNotZero when native ETH is sent on Tempo
    function test_Tempo_SendOFT_RevertsWhenMsgValueNonZero() public {
        uint256 sendAmountTempo = 10e6;
        vm.startPrank(alice);

        IERC20(address(tempoToken)).approve(address(tempoAdapter), sendAmountTempo);
        IERC20(address(tempoToken)).approve(address(remoteHopTempo), sendAmountTempo);
        IERC20(StdTokens.PATH_USD_ADDRESS).approve(address(remoteHopTempo), type(uint256).max);

        vm.expectRevert(abi.encodeWithSelector(RemoteHopV2TempoMock.MsgValueNotZero.selector, 1 ether));
        remoteHopTempo.sendOFT{ value: 1 ether }(
            address(tempoAdapter),
            FRAXTAL_EID,
            OFTMsgCodec.addressToBytes32(bob),
            sendAmountTempo,
            0,
            ""
        );

        vm.stopPrank();
    }

    // ═══════════════════════════════════════════════════════════════════════════════════════
    // TEST: Fee correctness — direct to Fraxtal (no hop fee)
    // ═══════════════════════════════════════════════════════════════════════════════════════

    /// @notice Verify fee accounting for Tempo → Fraxtal direct send (no hop fee expected)
    function test_Tempo_FeeCorrectness_DirectToFraxtal() public {
        uint256 sendAmountTempo = 10e6;

        vm.startPrank(alice);

        uint256 nativeFee = remoteHopTempo.quote(
            address(tempoAdapter),
            FRAXTAL_EID,
            OFTMsgCodec.addressToBytes32(bob),
            sendAmountTempo,
            0,
            ""
        );
        uint256 fee = remoteHopTempo.quoteStatic(
            address(tempoAdapter),
            FRAXTAL_EID,
            OFTMsgCodec.addressToBytes32(bob),
            sendAmountTempo,
            0,
            "",
            StdTokens.PATH_USD_ADDRESS
        );
        assertGt(fee, 0, "Fee should be non-zero");
        assertEq(fee, nativeFee, "PATH_USD quoteStatic should be 1:1 with native quote");

        // Record balances before
        uint256 alicePathUsdBefore = StdTokens.PATH_USD.balanceOf(alice);
        uint256 hopContractPathUsdBefore = StdTokens.PATH_USD.balanceOf(address(remoteHopTempo));

        // Approve and send
        IERC20(address(tempoToken)).approve(address(tempoAdapter), sendAmountTempo);
        IERC20(address(tempoToken)).approve(address(remoteHopTempo), sendAmountTempo);
        IERC20(StdTokens.PATH_USD_ADDRESS).approve(address(remoteHopTempo), fee);

        remoteHopTempo.sendOFT(
            address(tempoAdapter),
            FRAXTAL_EID,
            OFTMsgCodec.addressToBytes32(bob),
            sendAmountTempo,
            0,
            ""
        );

        vm.stopPrank();

        // Alice's PATH_USD should decrease by exactly the quoted fee
        uint256 alicePathUsdAfter = StdTokens.PATH_USD.balanceOf(alice);
        assertEq(alicePathUsdBefore - alicePathUsdAfter, fee, "Alice should pay exactly the quoted fee in PATH_USD");

        // Direct-to-hub = no hop fee, so hop contract should not retain protocol fee.
        uint256 hopContractPathUsdAfter = StdTokens.PATH_USD.balanceOf(address(remoteHopTempo));
        assertEq(
            hopContractPathUsdAfter,
            hopContractPathUsdBefore,
            "Hop contract should retain 0 protocol fee for direct-to-hub sends"
        );
    }

    // ═══════════════════════════════════════════════════════════════════════════════════════
    // TEST: Fee correctness — multi-hop Tempo → Fraxtal → Chain A (hop fee retained)
    // ═══════════════════════════════════════════════════════════════════════════════════════

    /// @notice Verify that hop fee is retained by contract as payment token and only LZ fee goes to endpoint
    function test_Tempo_FeeCorrectness_MultiHop() public {
        uint256 sendAmountTempo = 10e6;

        vm.startPrank(alice);

        uint256 nativeFee = remoteHopTempo.quote(
            address(tempoAdapter),
            CHAIN_A_EID,
            OFTMsgCodec.addressToBytes32(bob),
            sendAmountTempo,
            400_000,
            ""
        );
        uint256 fee = remoteHopTempo.quoteStatic(
            address(tempoAdapter),
            CHAIN_A_EID,
            OFTMsgCodec.addressToBytes32(bob),
            sendAmountTempo,
            400_000,
            "",
            StdTokens.PATH_USD_ADDRESS
        );
        assertGt(fee, 0, "Fee should be non-zero for multi-hop");
        assertEq(fee, nativeFee, "PATH_USD quoteStatic should be 1:1 with native quote");

        // Record balances before
        uint256 alicePathUsdBefore = StdTokens.PATH_USD.balanceOf(alice);
        uint256 hopContractPathUsdBefore = StdTokens.PATH_USD.balanceOf(address(remoteHopTempo));

        // Approve and send
        IERC20(address(tempoToken)).approve(address(tempoAdapter), sendAmountTempo);
        IERC20(address(tempoToken)).approve(address(remoteHopTempo), sendAmountTempo);
        IERC20(StdTokens.PATH_USD_ADDRESS).approve(address(remoteHopTempo), fee);

        remoteHopTempo.sendOFT(
            address(tempoAdapter),
            CHAIN_A_EID,
            OFTMsgCodec.addressToBytes32(bob),
            sendAmountTempo,
            400_000,
            ""
        );

        vm.stopPrank();

        // Alice's PATH_USD should decrease by exactly the quoted fee
        uint256 alicePathUsdAfter = StdTokens.PATH_USD.balanceOf(alice);
        assertEq(alicePathUsdBefore - alicePathUsdAfter, fee, "Alice should pay exactly the quoted fee in PATH_USD");

        // Hop contract should retain the hop-fee portion as protocol revenue in the payment token.
        uint256 hopContractPathUsdAfter = StdTokens.PATH_USD.balanceOf(address(remoteHopTempo));
        assertGt(
            hopContractPathUsdAfter - hopContractPathUsdBefore,
            0,
            "Hop contract should retain hop fee as protocol revenue"
        );

        // Verify fee breakdown: alice paid LZ fee + hop fee, contract kept hop fee
        uint256 retainedHopFee = hopContractPathUsdAfter - hopContractPathUsdBefore;
        assertLt(retainedHopFee, fee, "Retained hop fee should be less than total fee (LZ fee was forwarded)");
    }

    // ═══════════════════════════════════════════════════════════════════════════════════════
    // TEST: Quote returns correct units based on user's gas token
    // ═══════════════════════════════════════════════════════════════════════════════════════

    /// @notice Quote returns endpoint fee as-is when user's gas token is PATH_USD (whitelisted)
    function test_Tempo_Quote_WhitelistedGasToken() public {
        // Alice uses PATH_USD (whitelisted) — quote should return raw endpoint fee
        vm.prank(alice);
        uint256 fee = remoteHopTempo.quote(
            address(tempoAdapter),
            CHAIN_A_EID,
            OFTMsgCodec.addressToBytes32(bob),
            10e6,
            400_000,
            ""
        );
        assertGt(fee, 0, "Fee should be non-zero");

        // Bob also uses PATH_USD — should get same fee
        vm.prank(bob);
        uint256 feeBob = remoteHopTempo.quote(
            address(tempoAdapter),
            CHAIN_A_EID,
            OFTMsgCodec.addressToBytes32(alice),
            10e6,
            400_000,
            ""
        );
        assertEq(fee, feeBob, "Same gas token should yield same quote");
    }

    /// @notice Quote stays in native-LZ units regardless of configured gas token
    function test_Tempo_Quote_NonWhitelistedGasToken() public {
        // Create a non-whitelisted TIP20 with DEX liquidity
        ITIP20 altGasToken = _createTIP20WithDexPair(
            "AltGas",
            "AGAS",
            keccak256("test_Tempo_Quote_NonWhitelistedGasToken")
        );
        uint256 dexLiquidity = 1_000_000e6;
        _addDexLiquidity(address(altGasToken), dexLiquidity);

        // Set alice's gas token to the non-whitelisted token
        _setUserGasToken(alice, address(altGasToken));

        // Get raw native-LZ quote with non-whitelisted gas token configured
        vm.prank(alice);
        uint256 feeNonWhitelisted = remoteHopTempo.quote(
            address(tempoAdapter),
            CHAIN_A_EID,
            OFTMsgCodec.addressToBytes32(bob),
            10e6,
            400_000,
            ""
        );

        // Get quote with whitelisted gas token (PATH_USD) for comparison
        _setUserGasToken(bob, StdTokens.PATH_USD_ADDRESS);
        vm.prank(bob);
        uint256 feeWhitelisted = remoteHopTempo.quote(
            address(tempoAdapter),
            CHAIN_A_EID,
            OFTMsgCodec.addressToBytes32(alice),
            10e6,
            400_000,
            ""
        );

        assertGt(feeNonWhitelisted, 0, "Non-whitelisted fee should be non-zero");
        assertEq(feeNonWhitelisted, feeWhitelisted, "Raw native-LZ quote should not depend on gas token");

        // Restore alice's gas token for other tests
        _setUserGasToken(alice, StdTokens.PATH_USD_ADDRESS);
    }

    /// @notice Explicit-token quoteStatic depends on the requested token, not the caller's configured token
    function test_Tempo_QuoteStatic_IsCallerIndependent() public {
        ITIP20 altGasToken = _createTIP20WithDexPair(
            "PreviewGas",
            "PGAS",
            keccak256("test_Tempo_QuoteStatic_IsCallerIndependent")
        );
        _addDexLiquidity(address(altGasToken), 1_000_000e6);

        _setUserGasToken(alice, address(altGasToken));
        _setUserGasToken(bob, StdTokens.PATH_USD_ADDRESS);

        vm.prank(alice);
        uint256 nativeQuoteAlice = remoteHopTempo.quote(
            address(tempoAdapter),
            CHAIN_A_EID,
            OFTMsgCodec.addressToBytes32(bob),
            10e6,
            400_000,
            ""
        );

        vm.prank(alice);
        uint256 pathUsdQuoteAlice = remoteHopTempo.quoteStatic(
            address(tempoAdapter),
            CHAIN_A_EID,
            OFTMsgCodec.addressToBytes32(bob),
            10e6,
            400_000,
            "",
            StdTokens.PATH_USD_ADDRESS
        );

        vm.prank(bob);
        uint256 nativeQuoteBob = remoteHopTempo.quote(
            address(tempoAdapter),
            CHAIN_A_EID,
            OFTMsgCodec.addressToBytes32(alice),
            10e6,
            400_000,
            ""
        );

        vm.prank(bob);
        uint256 pathUsdQuoteBob = remoteHopTempo.quoteStatic(
            address(tempoAdapter),
            CHAIN_A_EID,
            OFTMsgCodec.addressToBytes32(alice),
            10e6,
            400_000,
            "",
            StdTokens.PATH_USD_ADDRESS
        );

        assertGt(pathUsdQuoteAlice, 0, "quoteStatic should be non-zero");
        assertEq(pathUsdQuoteAlice, nativeQuoteAlice, "PATH_USD quoteStatic should be 1:1 with native quote");
        assertEq(pathUsdQuoteBob, nativeQuoteBob, "PATH_USD quoteStatic should be 1:1 with native quote");
        assertEq(pathUsdQuoteAlice, pathUsdQuoteBob, "quoteStatic should not depend on caller token");

        _setUserGasToken(alice, StdTokens.PATH_USD_ADDRESS);
    }

    // ═══════════════════════════════════════════════════════════════════════════════════════
    // TEST: Full send with non-whitelisted gas token (swap path)
    // ═══════════════════════════════════════════════════════════════════════════════════════

    /// @notice Full Tempo → Fraxtal send using a non-whitelisted gas token via DEX swap
    function test_Tempo_SendOFT_NonWhitelistedGasToken() public {
        uint256 sendAmountTempo = 10e6;

        // Create a non-whitelisted TIP20 with DEX liquidity
        ITIP20 altGasToken = _createTIP20WithDexPair(
            "SwapGas",
            "SGAS",
            keccak256("test_Tempo_SendOFT_NonWhitelistedGasToken")
        );
        uint256 dexLiquidity = 1_000_000e6;
        _addDexLiquidity(address(altGasToken), dexLiquidity);

        // Mint gas tokens for alice
        altGasToken.mint(alice, 1_000_000e6);

        // Set alice's gas token to the non-whitelisted token
        _setUserGasToken(alice, address(altGasToken));

        vm.startPrank(alice);

        uint256 nativeFee = remoteHopTempo.quote(
            address(tempoAdapter),
            FRAXTAL_EID,
            OFTMsgCodec.addressToBytes32(bob),
            sendAmountTempo,
            0,
            ""
        );
        uint256 fee = remoteHopTempo.quoteStatic(
            address(tempoAdapter),
            FRAXTAL_EID,
            OFTMsgCodec.addressToBytes32(bob),
            sendAmountTempo,
            0,
            "",
            address(altGasToken)
        );
        assertGt(nativeFee, 0, "Native fee should be non-zero");

        // Record balances
        uint256 aliceAltGasBefore = altGasToken.balanceOf(alice);
        uint256 aliceTempoTokenBefore = tempoToken.balanceOf(alice);

        // Approve gas token (non-whitelisted) and OFT token
        IERC20(address(altGasToken)).approve(address(remoteHopTempo), fee);
        IERC20(address(tempoToken)).approve(address(tempoAdapter), sendAmountTempo);
        IERC20(address(tempoToken)).approve(address(remoteHopTempo), sendAmountTempo);

        // Send with msg.value = 0
        remoteHopTempo.sendOFT(
            address(tempoAdapter),
            FRAXTAL_EID,
            OFTMsgCodec.addressToBytes32(bob),
            sendAmountTempo,
            0,
            ""
        );

        vm.stopPrank();

        // Verify: TIP20 tokens burned
        assertEq(
            tempoToken.balanceOf(alice),
            aliceTempoTokenBefore - sendAmountTempo,
            "Alice's TIP20 tokens should be burned"
        );

        // Verify: alt gas token spent (exact match since quote and send use same DEX state)
        assertEq(
            aliceAltGasBefore - altGasToken.balanceOf(alice),
            fee,
            "Alice should spend exactly the quoted fee in alt gas token"
        );

        // Deliver to Fraxtal and verify receipt
        verifyPackets(FRAXTAL_EID, addressToBytes32(address(fraxtalAdapter)));
        assertGt(fraxtalToken.balanceOf(bob), 0, "Bob should receive tokens on Fraxtal");

        // Restore alice's gas token
        _setUserGasToken(alice, StdTokens.PATH_USD_ADDRESS);
    }

    /// @notice Tempo send works when the caller pays gas in the same token being bridged.
    function test_Tempo_SendOFT_GasTokenMatchesOFTToken() public {
        uint256 sendAmountTempo = 10e6;

        StdPrecompiles.STABLECOIN_DEX.createPair(address(tempoToken));
        _addDexLiquidity(address(tempoToken), 1_000_000e6);
        tempoToken.mint(alice, 1_000_000e6);
        _setUserGasToken(alice, address(tempoToken));

        vm.startPrank(alice);

        uint256 nativeFee = remoteHopTempo.quote(
            address(tempoAdapter),
            FRAXTAL_EID,
            OFTMsgCodec.addressToBytes32(bob),
            sendAmountTempo,
            0,
            ""
        );
        uint256 fee = remoteHopTempo.quoteStatic(
            address(tempoAdapter),
            FRAXTAL_EID,
            OFTMsgCodec.addressToBytes32(bob),
            sendAmountTempo,
            0,
            "",
            address(tempoToken)
        );
        assertGt(nativeFee, 0, "Native fee should be non-zero");
        assertGt(fee, 0, "Fee should be non-zero");

        uint256 aliceTempoBefore = tempoToken.balanceOf(alice);
        uint256 hopTempoBefore = tempoToken.balanceOf(address(remoteHopTempo));

        IERC20(address(tempoToken)).approve(address(remoteHopTempo), type(uint256).max);
        IERC20(address(tempoToken)).approve(address(tempoAdapter), type(uint256).max);

        remoteHopTempo.sendOFT(
            address(tempoAdapter),
            FRAXTAL_EID,
            OFTMsgCodec.addressToBytes32(bob),
            sendAmountTempo,
            0,
            ""
        );

        vm.stopPrank();

        assertEq(
            aliceTempoBefore - tempoToken.balanceOf(alice),
            sendAmountTempo + fee,
            "Alice should pay bridge amount plus quoted fee in the same TIP20"
        );
        assertEq(
            tempoToken.balanceOf(address(remoteHopTempo)),
            hopTempoBefore,
            "Hop contract should not retain the OFT token on direct sends"
        );

        verifyPackets(FRAXTAL_EID, addressToBytes32(address(fraxtalAdapter)));
        assertEq(
            fraxtalToken.balanceOf(bob),
            initialBalance + 10e18,
            "Bob should receive the bridged amount on Fraxtal"
        );

        _setUserGasToken(alice, StdTokens.PATH_USD_ADDRESS);
    }

    /// @notice Tempo send falls back to PATH_USD when no explicit user gas token is configured.
    function test_Tempo_SendOFT_DefaultGasTokenFallback() public {
        uint256 sendAmountTempo = 10e6;
        address charlie = makeAddr("charlie");

        tempoToken.mint(charlie, initialBalanceTempo);
        StdTokens.PATH_USD.mint(charlie, 1_000_000e6);

        vm.startPrank(charlie);

        uint256 nativeFee = remoteHopTempo.quote(
            address(tempoAdapter),
            FRAXTAL_EID,
            OFTMsgCodec.addressToBytes32(bob),
            sendAmountTempo,
            0,
            ""
        );
        uint256 fee = remoteHopTempo.quoteStatic(
            address(tempoAdapter),
            FRAXTAL_EID,
            OFTMsgCodec.addressToBytes32(bob),
            sendAmountTempo,
            0,
            "",
            StdTokens.PATH_USD_ADDRESS
        );
        assertGt(fee, 0, "Fee should be non-zero");
        assertEq(fee, nativeFee, "PATH_USD quoteStatic should be 1:1 with native quote");

        uint256 charliePathUsdBefore = StdTokens.PATH_USD.balanceOf(charlie);

        IERC20(address(tempoToken)).approve(address(remoteHopTempo), sendAmountTempo);
        IERC20(address(tempoToken)).approve(address(tempoAdapter), sendAmountTempo);
        IERC20(StdTokens.PATH_USD_ADDRESS).approve(address(remoteHopTempo), fee);

        remoteHopTempo.sendOFT(
            address(tempoAdapter),
            FRAXTAL_EID,
            OFTMsgCodec.addressToBytes32(bob),
            sendAmountTempo,
            0,
            ""
        );

        vm.stopPrank();

        assertEq(
            charliePathUsdBefore - StdTokens.PATH_USD.balanceOf(charlie),
            fee,
            "Unset user token should fall back to PATH_USD for execution"
        );

        verifyPackets(FRAXTAL_EID, addressToBytes32(address(fraxtalAdapter)));
    }

    /// @notice Repeated Tempo sends keep working when the OFT pulls fees from the hop contract.
    function test_Tempo_SendOFT_RepeatedSends_NonWhitelistedGasToken() public {
        uint256 sendAmountTempo = 10e6;

        ITIP20 altGasToken = _createTIP20WithDexPair(
            "RepeatGas",
            "RGAS",
            keccak256("test_Tempo_SendOFT_RepeatedSends_NonWhitelistedGasToken")
        );
        _addDexLiquidity(address(altGasToken), 1_000_000e6);
        altGasToken.mint(alice, 1_000_000e6);
        _setUserGasToken(alice, address(altGasToken));

        vm.startPrank(alice);
        IERC20(address(altGasToken)).approve(address(remoteHopTempo), type(uint256).max);
        IERC20(address(tempoToken)).approve(address(remoteHopTempo), type(uint256).max);
        IERC20(address(tempoToken)).approve(address(tempoAdapter), type(uint256).max);

        for (uint256 i = 0; i < 2; i++) {
            uint256 nativeFee = remoteHopTempo.quote(
                address(tempoAdapter),
                FRAXTAL_EID,
                OFTMsgCodec.addressToBytes32(bob),
                sendAmountTempo,
                0,
                ""
            );
            uint256 fee = remoteHopTempo.quoteStatic(
                address(tempoAdapter),
                FRAXTAL_EID,
                OFTMsgCodec.addressToBytes32(bob),
                sendAmountTempo,
                0,
                "",
                address(altGasToken)
            );
            assertGt(nativeFee, 0, "Native fee should be non-zero");
            uint256 aliceAltGasBefore = altGasToken.balanceOf(alice);

            remoteHopTempo.sendOFT(
                address(tempoAdapter),
                FRAXTAL_EID,
                OFTMsgCodec.addressToBytes32(bob),
                sendAmountTempo,
                0,
                ""
            );

            assertEq(
                aliceAltGasBefore - altGasToken.balanceOf(alice),
                fee,
                "Each send should consume the quoted non-whitelisted gas fee"
            );
            assertEq(
                altGasToken.balanceOf(address(remoteHopTempo)),
                0,
                "Hop contract should not retain user gas token after OFT fee pull"
            );

            verifyPackets(FRAXTAL_EID, addressToBytes32(address(fraxtalAdapter)));
        }
        vm.stopPrank();

        assertEq(
            fraxtalToken.balanceOf(bob),
            initialBalance + 20e18,
            "Bob should receive both repeated sends on Fraxtal"
        );

        _setUserGasToken(alice, StdTokens.PATH_USD_ADDRESS);
    }
}
