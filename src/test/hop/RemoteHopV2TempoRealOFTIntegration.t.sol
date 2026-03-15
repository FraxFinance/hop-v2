// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

import { TestHelperOz5 } from "@layerzerolabs/test-devtools-evm-foundry/contracts/TestHelperOz5.sol";
import { EndpointV2Mock } from "@layerzerolabs/test-devtools-evm-foundry/contracts/mocks/EndpointV2Mock.sol";
import { SimpleMessageLibMock } from "@layerzerolabs/test-devtools-evm-foundry/contracts/mocks/SimpleMessageLibMock.sol";
import { OFTMsgCodec } from "@layerzerolabs/oft-evm/contracts/libs/OFTMsgCodec.sol";
import { OFTComposeMsgCodec } from "@layerzerolabs/oft-evm/contracts/libs/OFTComposeMsgCodec.sol";
import { ILayerZeroComposer } from "@layerzerolabs/lz-evm-protocol-v2/contracts/interfaces/ILayerZeroComposer.sol";
import { EnforcedOptionParam as LzEnforcedOptionParam } from "@layerzerolabs/oapp-evm/contracts/oapp/interfaces/IOAppOptionsType3.sol";
import { TransparentUpgradeableProxy } from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import { FraxOFTMintableAdapterUpgradeableTIP20 } from "contracts/FraxOFTMintableAdapterUpgradeableTIP20.sol";
import { OptionsBuilder } from "@fraxfinance/layerzero-v2-upgradeable/oapp/contracts/oapp/libs/OptionsBuilder.sol";
import { EnforcedOptionParam } from "@fraxfinance/layerzero-v2-upgradeable/oapp/contracts/oapp/interfaces/IOAppOptionsType3.sol";

import { FraxtalHopV2 } from "src/contracts/hop/FraxtalHopV2.sol";
import { RemoteHopV2Tempo } from "src/contracts/hop/RemoteHopV2Tempo.sol";
import { HopMessage } from "src/contracts/interfaces/IHopV2.sol";

import { TempoTestHelpers } from "./helpers/TempoTestHelpers.sol";
import { MockDVN } from "./mocks/MockDVN.sol";
import { MockExecutor } from "./mocks/MockExecutor.sol";
import { MockTreasury } from "./mocks/MockTreasury.sol";
import { EndpointV2AltLzDollarMock } from "./mocks/EndpointV2AltLzDollarMock.sol";
import { MockERC20 } from "./mocks/MockERC20.sol";
import { ChainAOFTMock } from "./mocks/ChainAOFTMock.sol";
import { FraxtalOFTAdapterMock } from "./mocks/FraxtalOFTAdapterMock.sol";
import { FraxOFTUpgradeableTempoFlat } from "./mocks/FraxOFTUpgradeableTempoFlat.sol";

import { ITIP20 } from "tempo-std/interfaces/ITIP20.sol";
import { ITIP20RolesAuth } from "tempo-std/interfaces/ITIP20RolesAuth.sol";
import { StdPrecompiles } from "tempo-std/StdPrecompiles.sol";
import { StdTokens } from "tempo-std/StdTokens.sol";

/// @notice Integration coverage for the real Tempo `frxUSD` adapter with the real `RemoteHopV2Tempo`.
/// @dev Uses the real Tempo-side OFT implementation and production hop contract, while keeping
///      the non-Tempo peers lightweight so the test can run locally with deterministic endpoints.
contract RemoteHopV2TempoRealOFTIntegration is TestHelperOz5, TempoTestHelpers {
    using OptionsBuilder for bytes;

    uint32 internal constant CHAIN_A_EID = 30_101;
    uint32 internal constant FRAXTAL_EID = 30_255;
    uint32 internal constant TEMPO_EID = 30_410;
    uint32 internal constant NUM_DVNS = 1;

    uint256 internal constant INITIAL_TEMPO_FRXUSD = 1_000_000e6;
    uint256 internal constant INITIAL_TEMPO_FRAX = 1_000_000e18;
    uint256 internal constant INITIAL_PATH_USD = 1_000_000e6;

    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal proxyAdmin = makeAddr("proxyAdmin");

    MockDVN internal mockDVN;
    MockExecutor internal mockExecutor;
    MockTreasury internal mockTreasury;

    EndpointV2Mock internal chainAEndpoint;
    EndpointV2Mock internal fraxtalEndpoint;
    EndpointV2AltLzDollarMock internal tempoEndpoint;

    ChainAOFTMock internal chainAOft;
    MockERC20 internal fraxtalToken;
    FraxtalOFTAdapterMock internal fraxtalAdapter;
    MockERC20 internal fraxtalTempoToken;
    FraxtalOFTAdapterMock internal fraxtalTempoAdapter;
    ITIP20 internal tempoFrxUsdToken;
    FraxOFTMintableAdapterUpgradeableTIP20 internal tempoFrxUsdAdapter;
    FraxOFTUpgradeableTempoFlat internal tempoFraxOft;

    FraxtalHopV2 internal fraxtalHop;
    RemoteHopV2Tempo internal remoteHopTempo;

    function setUp() public virtual override {
        vm.deal(alice, 100 ether);
        vm.deal(bob, 100 ether);

        mockDVN = new MockDVN();
        mockExecutor = new MockExecutor();
        mockTreasury = new MockTreasury();

        super.setUp();
        _grantPathUsdIssuerRole(address(this));

        _deployEndpoints();
        _deployPeers();
        _deployHops();
        _wirePeers();
        _configureHops();
        _setupUsers();
    }

    function test_Tempo_frxUSD_Adapter_DirectToFraxtal_PathUsdGas() public {
        uint256 sendAmount = 10e6;

        vm.startPrank(alice);
        uint256 fee = remoteHopTempo.quote(
            address(tempoFrxUsdAdapter),
            FRAXTAL_EID,
            OFTMsgCodec.addressToBytes32(bob),
            sendAmount,
            0,
            ""
        );
        uint256 aliceFrxUsdBefore = tempoFrxUsdToken.balanceOf(alice);
        uint256 alicePathUsdBefore = StdTokens.PATH_USD.balanceOf(alice);
        uint256 hopWrappedBefore = IERC20(address(remoteHopTempo.nativeToken())).balanceOf(address(remoteHopTempo));

        IERC20(address(tempoFrxUsdToken)).approve(address(remoteHopTempo), type(uint256).max);
        IERC20(StdTokens.PATH_USD_ADDRESS).approve(address(remoteHopTempo), type(uint256).max);

        remoteHopTempo.sendOFT(
            address(tempoFrxUsdAdapter),
            FRAXTAL_EID,
            OFTMsgCodec.addressToBytes32(bob),
            sendAmount,
            0,
            ""
        );
        vm.stopPrank();

        assertEq(tempoFrxUsdToken.balanceOf(alice), aliceFrxUsdBefore - sendAmount, "Tempo frxUSD amount mismatch");
        assertEq(StdTokens.PATH_USD.balanceOf(alice), alicePathUsdBefore - fee, "PATH_USD fee mismatch");
        assertEq(
            IERC20(address(remoteHopTempo.nativeToken())).balanceOf(address(remoteHopTempo)),
            hopWrappedBefore,
            "Direct send should not retain wrapped hop fee"
        );

        verifyPackets(FRAXTAL_EID, addressToBytes32(address(fraxtalAdapter)));
        assertEq(fraxtalToken.balanceOf(bob), 10e18, "Fraxtal recipient mismatch");
    }

    function test_Tempo_frxUSD_Adapter_DirectToFraxtal_SameTokenGas() public {
        uint256 sendAmount = 10e6;

        StdPrecompiles.STABLECOIN_DEX.createPair(address(tempoFrxUsdToken));
        _addDexLiquidity(address(tempoFrxUsdToken), 1_000_000e6);
        _setUserGasToken(alice, address(tempoFrxUsdToken));

        vm.startPrank(alice);
        uint256 fee = remoteHopTempo.quote(
            address(tempoFrxUsdAdapter),
            FRAXTAL_EID,
            OFTMsgCodec.addressToBytes32(bob),
            sendAmount,
            0,
            ""
        );
        uint256 aliceFrxUsdBefore = tempoFrxUsdToken.balanceOf(alice);

        IERC20(address(tempoFrxUsdToken)).approve(address(remoteHopTempo), type(uint256).max);

        remoteHopTempo.sendOFT(
            address(tempoFrxUsdAdapter),
            FRAXTAL_EID,
            OFTMsgCodec.addressToBytes32(bob),
            sendAmount,
            0,
            ""
        );
        vm.stopPrank();

        assertEq(
            tempoFrxUsdToken.balanceOf(alice),
            aliceFrxUsdBefore - sendAmount - fee,
            "Same-token fee path should consume bridged token plus fee"
        );

        verifyPackets(FRAXTAL_EID, addressToBytes32(address(fraxtalAdapter)));
        assertEq(fraxtalToken.balanceOf(bob), 10e18, "Fraxtal recipient mismatch");

        _setUserGasToken(alice, StdTokens.PATH_USD_ADDRESS);
    }

    function test_Tempo_frxUSD_Adapter_ToChainA_viaFraxtal_PathUsdGas() public {
        uint256 sendAmount = 10e6;

        vm.startPrank(alice);
        uint256 fee = remoteHopTempo.quote(
            address(tempoFrxUsdAdapter),
            CHAIN_A_EID,
            OFTMsgCodec.addressToBytes32(bob),
            sendAmount,
            400_000,
            ""
        );
        uint256 alicePathUsdBefore = StdTokens.PATH_USD.balanceOf(alice);
        uint256 hopWrappedBefore = IERC20(address(remoteHopTempo.nativeToken())).balanceOf(address(remoteHopTempo));

        IERC20(address(tempoFrxUsdToken)).approve(address(remoteHopTempo), type(uint256).max);
        IERC20(StdTokens.PATH_USD_ADDRESS).approve(address(remoteHopTempo), type(uint256).max);

        remoteHopTempo.sendOFT(
            address(tempoFrxUsdAdapter),
            CHAIN_A_EID,
            OFTMsgCodec.addressToBytes32(bob),
            sendAmount,
            400_000,
            ""
        );
        vm.stopPrank();

        uint256 hopWrappedAfter = IERC20(address(remoteHopTempo.nativeToken())).balanceOf(address(remoteHopTempo));
        assertEq(StdTokens.PATH_USD.balanceOf(alice), alicePathUsdBefore - fee, "Multi-hop fee mismatch");
        assertGt(hopWrappedAfter, hopWrappedBefore, "Hop should retain wrapped fee revenue");
        assertLt(hopWrappedAfter - hopWrappedBefore, fee, "Retained fee should be less than total fee");

        verifyPackets(FRAXTAL_EID, addressToBytes32(address(fraxtalAdapter)));

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
        bytes memory oftComposeMsg = OFTComposeMsgCodec.encode(1, TEMPO_EID, 10e18, composeMsg);

        vm.prank(address(fraxtalEndpoint));
        ILayerZeroComposer(address(fraxtalHop)).lzCompose(
            address(fraxtalAdapter),
            bytes32(0),
            oftComposeMsg,
            address(this),
            ""
        );

        verifyPackets(CHAIN_A_EID, addressToBytes32(address(chainAOft)));
        assertEq(chainAOft.balanceOf(bob), 10e18, "Chain A recipient mismatch");
    }

    function test_Tempo_FraxOFTUpgradeableTempo_DirectToFraxtal_PathUsdGas() public {
        uint256 sendAmount = 10e18;

        vm.startPrank(alice);
        uint256 fee = remoteHopTempo.quote(
            address(tempoFraxOft),
            FRAXTAL_EID,
            OFTMsgCodec.addressToBytes32(bob),
            sendAmount,
            0,
            ""
        );
        uint256 aliceFraxBefore = tempoFraxOft.balanceOf(alice);
        uint256 alicePathUsdBefore = StdTokens.PATH_USD.balanceOf(alice);
        uint256 hopWrappedBefore = IERC20(address(remoteHopTempo.nativeToken())).balanceOf(address(remoteHopTempo));

        IERC20(address(tempoFraxOft)).approve(address(remoteHopTempo), type(uint256).max);
        IERC20(StdTokens.PATH_USD_ADDRESS).approve(address(remoteHopTempo), type(uint256).max);

        remoteHopTempo.sendOFT(
            address(tempoFraxOft),
            FRAXTAL_EID,
            OFTMsgCodec.addressToBytes32(bob),
            sendAmount,
            0,
            ""
        );
        vm.stopPrank();

        assertEq(tempoFraxOft.balanceOf(alice), aliceFraxBefore - sendAmount, "Tempo FRAX amount mismatch");
        assertEq(StdTokens.PATH_USD.balanceOf(alice), alicePathUsdBefore - fee, "PATH_USD fee mismatch");
        assertEq(
            IERC20(address(remoteHopTempo.nativeToken())).balanceOf(address(remoteHopTempo)),
            hopWrappedBefore,
            "Direct send should not retain wrapped hop fee"
        );

        verifyPackets(FRAXTAL_EID, addressToBytes32(address(fraxtalTempoAdapter)));
        assertEq(fraxtalTempoToken.balanceOf(bob), sendAmount, "Fraxtal recipient mismatch");
    }

    function test_Tempo_QuoteStatic_MatchesQuote_ForCallerResolvedToken() public {
        uint256 sendAmount = 10e6;
        bytes32 recipient = OFTMsgCodec.addressToBytes32(bob);

        vm.startPrank(alice);
        uint256 quoteFee = remoteHopTempo.quote(address(tempoFrxUsdAdapter), FRAXTAL_EID, recipient, sendAmount, 0, "");
        uint256 staticFee = remoteHopTempo.quoteStatic(
            address(tempoFrxUsdAdapter),
            FRAXTAL_EID,
            recipient,
            sendAmount,
            0,
            "",
            StdTokens.PATH_USD_ADDRESS
        );
        vm.stopPrank();

        assertEq(staticFee, quoteFee, "quoteStatic should match quote for caller's resolved gas token");
    }

    function test_Tempo_PreviewQuoteForUserToken_UsesExplicitToken() public {
        uint256 sendAmount = 10e6;
        bytes32 recipient = OFTMsgCodec.addressToBytes32(bob);

        ITIP20 altGasToken = _createTIP20(
            "RemoteHop Quote Alt Gas",
            "RQAG",
            keccak256("RemoteHopV2TempoRealOFTIntegration-alt-gas")
        );
        StdPrecompiles.STABLECOIN_DEX.createPair(address(altGasToken));
        _addDexLiquidity(address(altGasToken), 1_000_000e6);
        _setUserGasToken(alice, address(altGasToken));

        vm.startPrank(alice);
        uint256 staticAltFee = remoteHopTempo.quoteStatic(
            address(tempoFrxUsdAdapter),
            FRAXTAL_EID,
            recipient,
            sendAmount,
            0,
            "",
            address(altGasToken)
        );
        uint256 previewAltFee = remoteHopTempo.previewQuoteForUserToken(
            address(tempoFrxUsdAdapter),
            FRAXTAL_EID,
            recipient,
            sendAmount,
            0,
            "",
            address(altGasToken)
        );
        uint256 previewPathUsdFee = remoteHopTempo.previewQuoteForUserToken(
            address(tempoFrxUsdAdapter),
            FRAXTAL_EID,
            recipient,
            sendAmount,
            0,
            "",
            StdTokens.PATH_USD_ADDRESS
        );
        vm.stopPrank();

        assertEq(staticAltFee, previewAltFee, "explicit alt token preview should match quoteStatic");
        assertGe(previewAltFee, previewPathUsdFee, "non-whitelisted preview should be >= PATH_USD preview");

        _setUserGasToken(alice, StdTokens.PATH_USD_ADDRESS);
    }

    function _deployEndpoints() internal {
        chainAEndpoint = new EndpointV2Mock(CHAIN_A_EID, address(this));
        fraxtalEndpoint = new EndpointV2Mock(FRAXTAL_EID, address(this));
        tempoEndpoint = new EndpointV2AltLzDollarMock(TEMPO_EID, address(this), StdTokens.PATH_USD_ADDRESS);

        registerEndpoint(chainAEndpoint);
        registerEndpoint(fraxtalEndpoint);
        registerEndpoint(EndpointV2Mock(address(tempoEndpoint)));

        _configureSimpleLib(chainAEndpoint, FRAXTAL_EID);
        _configureSimpleLib(fraxtalEndpoint, CHAIN_A_EID);
        _configureSimpleLib(fraxtalEndpoint, TEMPO_EID);
        _configureSimpleLib(EndpointV2Mock(address(tempoEndpoint)), FRAXTAL_EID);
    }

    function _deployPeers() internal {
        chainAOft = ChainAOFTMock(
            _deployOApp(
                type(ChainAOFTMock).creationCode,
                abi.encode("FRAX on Chain A", "FRAX", address(chainAEndpoint), address(this))
            )
        );

        fraxtalToken = new MockERC20("FRAX on Fraxtal", "FRAX", 18);
        fraxtalAdapter = FraxtalOFTAdapterMock(
            _deployOApp(
                type(FraxtalOFTAdapterMock).creationCode,
                abi.encode(address(fraxtalToken), address(fraxtalEndpoint), address(this))
            )
        );
        _setFraxtalAdapterEnforcedOptions();

        fraxtalTempoToken = new MockERC20("Tempo FRAX on Fraxtal", "tFRAX", 18);
        fraxtalTempoAdapter = FraxtalOFTAdapterMock(
            _deployOApp(
                type(FraxtalOFTAdapterMock).creationCode,
                abi.encode(address(fraxtalTempoToken), address(fraxtalEndpoint), address(this))
            )
        );

        tempoFrxUsdToken = _createTIP20("Frax USD", "frxUSD", keccak256("RemoteHopV2TempoRealOFTIntegration-frxUSD"));
        tempoFrxUsdAdapter = FraxOFTMintableAdapterUpgradeableTIP20(
            address(
                new TransparentUpgradeableProxy(
                    address(
                        new FraxOFTMintableAdapterUpgradeableTIP20(address(tempoFrxUsdToken), address(tempoEndpoint))
                    ),
                    proxyAdmin,
                    abi.encodeWithSignature("initialize(address)", address(this))
                )
            )
        );

        ITIP20RolesAuth(address(tempoFrxUsdToken)).grantRole(
            tempoFrxUsdToken.ISSUER_ROLE(),
            address(tempoFrxUsdAdapter)
        );
        _setTempoAdapterEnforcedOptions();

        tempoFraxOft = FraxOFTUpgradeableTempoFlat(
            address(
                new TransparentUpgradeableProxy(
                    address(new FraxOFTUpgradeableTempoFlat(address(tempoEndpoint))),
                    proxyAdmin,
                    abi.encodeWithSignature("initialize(string,string,address)", "Frax", "FRAX", address(this))
                )
            )
        );
        _setTempoOftEnforcedOptions();

        fraxtalToken.mint(address(fraxtalAdapter), 1_000_000e18);
        fraxtalTempoToken.mint(address(fraxtalTempoAdapter), 1_000_000e18);
    }

    function _deployHops() internal {
        address[] memory tempoApprovedOfts = new address[](2);
        tempoApprovedOfts[0] = address(tempoFrxUsdAdapter);
        tempoApprovedOfts[1] = address(tempoFraxOft);

        remoteHopTempo = RemoteHopV2Tempo(
            payable(
                address(
                    new TransparentUpgradeableProxy(
                        address(new RemoteHopV2Tempo(address(tempoEndpoint))),
                        proxyAdmin,
                        abi.encodeWithSignature(
                            "initialize(uint32,address,bytes32,uint32,address,address,address,address[])",
                            TEMPO_EID,
                            address(tempoEndpoint),
                            bytes32(0),
                            NUM_DVNS,
                            address(mockExecutor),
                            address(mockDVN),
                            address(mockTreasury),
                            tempoApprovedOfts
                        )
                    )
                )
            )
        );

        address[] memory fraxtalApprovedOfts = new address[](1);
        fraxtalApprovedOfts[0] = address(fraxtalAdapter);

        fraxtalHop = FraxtalHopV2(
            payable(
                address(
                    new TransparentUpgradeableProxy(
                        address(new FraxtalHopV2()),
                        proxyAdmin,
                        abi.encodeWithSignature(
                            "initialize(uint32,address,uint32,address,address,address,address[])",
                            FRAXTAL_EID,
                            address(fraxtalEndpoint),
                            NUM_DVNS,
                            address(mockExecutor),
                            address(mockDVN),
                            address(mockTreasury),
                            fraxtalApprovedOfts
                        )
                    )
                )
            )
        );

        vm.deal(address(fraxtalHop), 10 ether);
    }

    function _wirePeers() internal {
        bytes32 chainAPeer = addressToBytes32(address(chainAOft));
        bytes32 fraxtalPeer = addressToBytes32(address(fraxtalAdapter));
        bytes32 fraxtalTempoPeer = addressToBytes32(address(fraxtalTempoAdapter));

        chainAOft.setPeer(FRAXTAL_EID, fraxtalPeer);
        fraxtalAdapter.setPeer(CHAIN_A_EID, chainAPeer);
        fraxtalAdapter.setPeer(TEMPO_EID, addressToBytes32(address(tempoFrxUsdAdapter)));
        fraxtalTempoAdapter.setPeer(TEMPO_EID, addressToBytes32(address(tempoFraxOft)));
        tempoFrxUsdAdapter.setPeer(FRAXTAL_EID, fraxtalPeer);
        tempoFraxOft.setPeer(FRAXTAL_EID, fraxtalTempoPeer);
    }

    function _configureHops() internal {
        remoteHopTempo.setRemoteHop(FRAXTAL_EID, address(fraxtalHop));
        fraxtalHop.setRemoteHop(TEMPO_EID, address(remoteHopTempo));
    }

    function _setupUsers() internal {
        tempoFrxUsdToken.mint(alice, INITIAL_TEMPO_FRXUSD);
        deal(address(tempoFraxOft), alice, INITIAL_TEMPO_FRAX);
        StdTokens.PATH_USD.mint(alice, INITIAL_PATH_USD);
        _setUserGasToken(alice, StdTokens.PATH_USD_ADDRESS);
    }

    function _setTempoAdapterEnforcedOptions() internal {
        EnforcedOptionParam[] memory enforcedOptions = new EnforcedOptionParam[](2);

        bytes memory directOptions = OptionsBuilder.newOptions().addExecutorLzReceiveOption(200_000, 0);
        bytes memory composeOptions = OptionsBuilder
            .newOptions()
            .addExecutorLzReceiveOption(200_000, 0)
            .addExecutorLzComposeOption(0, 1_000_000, 0);

        enforcedOptions[0] = EnforcedOptionParam(FRAXTAL_EID, 1, directOptions);
        enforcedOptions[1] = EnforcedOptionParam(FRAXTAL_EID, 2, composeOptions);

        tempoFrxUsdAdapter.setEnforcedOptions(enforcedOptions);
    }

    function _setTempoOftEnforcedOptions() internal {
        bytes memory directOptions = OptionsBuilder.newOptions().addExecutorLzReceiveOption(200_000, 0);
        bytes memory composeOptions = OptionsBuilder
            .newOptions()
            .addExecutorLzReceiveOption(200_000, 0)
            .addExecutorLzComposeOption(0, 1_000_000, 0);

        tempoFraxOft.setTempoEnforcedOptions(FRAXTAL_EID, directOptions, composeOptions);
    }

    function _setFraxtalAdapterEnforcedOptions() internal {
        LzEnforcedOptionParam[] memory enforcedOptions = new LzEnforcedOptionParam[](1);
        bytes memory directOptions = OptionsBuilder.newOptions().addExecutorLzReceiveOption(200_000, 0);
        enforcedOptions[0] = LzEnforcedOptionParam(CHAIN_A_EID, 1, directOptions);
        fraxtalAdapter.setEnforcedOptions(enforcedOptions);
    }

    function _configureSimpleLib(EndpointV2Mock endpoint, uint32 remoteEid) internal {
        SimpleMessageLibMock lib = new SimpleMessageLibMock(payable(address(this)), address(endpoint));
        endpoint.registerLibrary(address(lib));
        endpoint.setDefaultSendLibrary(remoteEid, address(lib));
        endpoint.setDefaultReceiveLibrary(remoteEid, address(lib), 0);
    }
}
