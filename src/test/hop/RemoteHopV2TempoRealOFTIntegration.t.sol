// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

import { console2 } from "forge-std/Test.sol";
import { TestHelperOz5 } from "@layerzerolabs/test-devtools-evm-foundry/contracts/TestHelperOz5.sol";
import { EndpointV2Mock } from "@layerzerolabs/test-devtools-evm-foundry/contracts/mocks/EndpointV2Mock.sol";
import { SimpleMessageLibMock } from "@layerzerolabs/test-devtools-evm-foundry/contracts/mocks/SimpleMessageLibMock.sol";
import { OFTMsgCodec } from "@layerzerolabs/oft-evm/contracts/libs/OFTMsgCodec.sol";
import { OFTComposeMsgCodec } from "@layerzerolabs/oft-evm/contracts/libs/OFTComposeMsgCodec.sol";
import { ILayerZeroComposer } from "@layerzerolabs/lz-evm-protocol-v2/contracts/interfaces/ILayerZeroComposer.sol";
import { EnforcedOptionParam as LzEnforcedOptionParam } from "@layerzerolabs/oapp-evm/contracts/oapp/interfaces/IOAppOptionsType3.sol";
import { TransparentUpgradeableProxy } from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { IAccessControl } from "@openzeppelin/contracts/access/IAccessControl.sol";

import { FraxOFTMintableAdapterUpgradeableTIP20 } from "contracts/FraxOFTMintableAdapterUpgradeableTIP20.sol";
import { OptionsBuilder } from "@fraxfinance/layerzero-v2-upgradeable/oapp/contracts/oapp/libs/OptionsBuilder.sol";
import { EnforcedOptionParam } from "@fraxfinance/layerzero-v2-upgradeable/oapp/contracts/oapp/interfaces/IOAppOptionsType3.sol";

import { FraxtalHopV2 } from "src/contracts/hop/FraxtalHopV2.sol";
import { RemoteHopV2Tempo } from "src/contracts/hop/RemoteHopV2Tempo.sol";
import { TempoGasTokenBase } from "src/contracts/base/TempoGasTokenBase.sol";
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
import { IStablecoinDEX } from "tempo-std/interfaces/IStablecoinDEX.sol";
import { StdPrecompiles } from "tempo-std/StdPrecompiles.sol";
import { StdTokens } from "tempo-std/StdTokens.sol";

/// @notice Integration coverage for the real Tempo OFTs with the production `RemoteHopV2Tempo`.
/// @dev Uses the real Tempo-side OFT implementations and production hop contract, while keeping
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

    /// @dev Mirror of TempoGasTokenBase.DEFAULT_FEE_SWAP_SLIPPAGE_BPS / MAX_FEE_SWAP_SLIPPAGE_BPS.
    uint256 internal constant DEFAULT_FEE_SWAP_SLIPPAGE_BPS = 50;
    uint16 internal constant MAX_FEE_SWAP_SLIPPAGE_BPS = 200;
    /// @dev keccak256(abi.encode(uint256(keccak256("frax.storage.TempoGasTokenBase")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 internal constant TEMPO_GAS_TOKEN_STORAGE_LOCATION =
        0xdde8387d01cc878517f663dabc81b0226de49746c19eb5f56ad6bbacf74af000;

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
        uint256 nativeFee = remoteHopTempo.quote(
            address(tempoFrxUsdAdapter),
            FRAXTAL_EID,
            OFTMsgCodec.addressToBytes32(bob),
            sendAmount,
            0,
            ""
        );
        uint256 fee = remoteHopTempo.quoteStatic(
            address(tempoFrxUsdAdapter),
            FRAXTAL_EID,
            OFTMsgCodec.addressToBytes32(bob),
            sendAmount,
            0,
            "",
            StdTokens.PATH_USD_ADDRESS
        );
        uint256 aliceFrxUsdBefore = tempoFrxUsdToken.balanceOf(alice);
        uint256 alicePathUsdBefore = StdTokens.PATH_USD.balanceOf(alice);
        uint256 hopPathUsdBefore = StdTokens.PATH_USD.balanceOf(address(remoteHopTempo));

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

        assertEq(fee, nativeFee, "PATH_USD quoteStatic should be 1:1 with native quote");

        assertEq(tempoFrxUsdToken.balanceOf(alice), aliceFrxUsdBefore - sendAmount, "Tempo frxUSD amount mismatch");
        assertEq(StdTokens.PATH_USD.balanceOf(alice), alicePathUsdBefore - fee, "PATH_USD fee mismatch");
        assertEq(
            StdTokens.PATH_USD.balanceOf(address(remoteHopTempo)),
            hopPathUsdBefore,
            "Direct send should not retain protocol fee"
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
        uint256 nativeFee = remoteHopTempo.quote(
            address(tempoFrxUsdAdapter),
            FRAXTAL_EID,
            OFTMsgCodec.addressToBytes32(bob),
            sendAmount,
            0,
            ""
        );
        uint256 fee = remoteHopTempo.quoteStatic(
            address(tempoFrxUsdAdapter),
            FRAXTAL_EID,
            OFTMsgCodec.addressToBytes32(bob),
            sendAmount,
            0,
            "",
            address(tempoFrxUsdToken)
        );
        assertGt(nativeFee, 0, "Native fee should be non-zero");
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

        // The quote carries the DEX headroom; on a single-order book the swap settles at the raw quote and
        // the headroom comes straight back, so the net debit is bridged amount plus the raw DEX quote.
        (, uint128 rawQuote) = _rawSwapQuote(address(tempoFrxUsdToken), uint128(nativeFee));
        assertEq(fee, _padded(rawQuote), "Same-token quoteStatic should be the DEX quote plus headroom");
        assertEq(
            tempoFrxUsdToken.balanceOf(alice),
            aliceFrxUsdBefore - sendAmount - rawQuote,
            "Same-token fee path should consume bridged token plus the settled fee"
        );
        assertLe(aliceFrxUsdBefore - tempoFrxUsdToken.balanceOf(alice) - sendAmount, fee, "net fee within the quote");

        verifyPackets(FRAXTAL_EID, addressToBytes32(address(fraxtalAdapter)));
        assertEq(fraxtalToken.balanceOf(bob), 10e18, "Fraxtal recipient mismatch");

        _setUserGasToken(alice, StdTokens.PATH_USD_ADDRESS);
    }

    function test_Tempo_frxUSD_Adapter_ToChainA_viaFraxtal_PathUsdGas() public {
        uint256 sendAmount = 10e6;

        vm.startPrank(alice);
        uint256 nativeFee = remoteHopTempo.quote(
            address(tempoFrxUsdAdapter),
            CHAIN_A_EID,
            OFTMsgCodec.addressToBytes32(bob),
            sendAmount,
            400_000,
            ""
        );
        uint256 fee = remoteHopTempo.quoteStatic(
            address(tempoFrxUsdAdapter),
            CHAIN_A_EID,
            OFTMsgCodec.addressToBytes32(bob),
            sendAmount,
            400_000,
            "",
            StdTokens.PATH_USD_ADDRESS
        );
        uint256 alicePathUsdBefore = StdTokens.PATH_USD.balanceOf(alice);
        uint256 hopPathUsdBefore = StdTokens.PATH_USD.balanceOf(address(remoteHopTempo));

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

        assertEq(fee, nativeFee, "PATH_USD quoteStatic should be 1:1 with native quote");

        uint256 hopPathUsdAfter = StdTokens.PATH_USD.balanceOf(address(remoteHopTempo));
        assertEq(StdTokens.PATH_USD.balanceOf(alice), alicePathUsdBefore - fee, "Multi-hop fee mismatch");
        assertGt(hopPathUsdAfter, hopPathUsdBefore, "Hop should retain payment-token fee revenue");
        assertLt(hopPathUsdAfter - hopPathUsdBefore, fee, "Retained fee should be less than total fee");

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
        uint256 nativeFee = remoteHopTempo.quote(
            address(tempoFraxOft),
            FRAXTAL_EID,
            OFTMsgCodec.addressToBytes32(bob),
            sendAmount,
            0,
            ""
        );
        uint256 fee = remoteHopTempo.quoteStatic(
            address(tempoFraxOft),
            FRAXTAL_EID,
            OFTMsgCodec.addressToBytes32(bob),
            sendAmount,
            0,
            "",
            StdTokens.PATH_USD_ADDRESS
        );
        uint256 aliceFraxBefore = tempoFraxOft.balanceOf(alice);
        uint256 alicePathUsdBefore = StdTokens.PATH_USD.balanceOf(alice);
        uint256 hopPathUsdBefore = StdTokens.PATH_USD.balanceOf(address(remoteHopTempo));

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

        assertEq(fee, nativeFee, "PATH_USD quoteStatic should be 1:1 with native quote");

        assertEq(tempoFraxOft.balanceOf(alice), aliceFraxBefore - sendAmount, "Tempo FRAX amount mismatch");
        assertEq(StdTokens.PATH_USD.balanceOf(alice), alicePathUsdBefore - fee, "PATH_USD fee mismatch");
        assertEq(
            StdTokens.PATH_USD.balanceOf(address(remoteHopTempo)),
            hopPathUsdBefore,
            "Direct send should not retain protocol fee"
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

        assertEq(staticFee, quoteFee, "quoteStatic should match quote for PATH_USD");
    }

    function test_Tempo_QuoteStatic_UsesExplicitToken() public {
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
        uint256 nativeQuote = remoteHopTempo.quote(
            address(tempoFrxUsdAdapter),
            FRAXTAL_EID,
            recipient,
            sendAmount,
            0,
            ""
        );
        uint256 staticAltFee = remoteHopTempo.quoteStatic(
            address(tempoFrxUsdAdapter),
            FRAXTAL_EID,
            recipient,
            sendAmount,
            0,
            "",
            address(altGasToken)
        );
        uint256 quotedAltFee = remoteHopTempo.quoteUserTokenFee(address(altGasToken), nativeQuote);
        uint256 pathUsdNativeQuote = remoteHopTempo.quote(
            address(tempoFrxUsdAdapter),
            FRAXTAL_EID,
            recipient,
            sendAmount,
            0,
            ""
        );
        uint256 pathUsdFee = remoteHopTempo.quoteStatic(
            address(tempoFrxUsdAdapter),
            FRAXTAL_EID,
            recipient,
            sendAmount,
            0,
            "",
            StdTokens.PATH_USD_ADDRESS
        );
        vm.stopPrank();

        assertEq(staticAltFee, quotedAltFee, "quoteStatic should mirror quoteUserTokenFee(nativeQuote)");
        assertEq(pathUsdFee, pathUsdNativeQuote, "PATH_USD quoteStatic should be 1:1 with native quote");
        assertGe(staticAltFee, pathUsdFee, "non-whitelisted fee should be >= PATH_USD fee");

        _setUserGasToken(alice, StdTokens.PATH_USD_ADDRESS);
    }

    /// @dev quoteStatic is the amount the caller must approve and the most they can be debited; on a book with a
    ///      single resting order the swap settles at the raw DEX quote and the headroom is refunded in the same call.
    function test_Tempo_NonWhitelistedMultiHop_QuoteStaticIsCapAndHeadroomRefunded() public {
        uint256 sendAmount = 10e6;
        bytes32 recipient = OFTMsgCodec.addressToBytes32(bob);

        ITIP20 altGasToken = _createTIP20(
            "RemoteHop Exact Debit Alt Gas",
            "REDAG",
            keccak256("RemoteHopV2TempoRealOFTIntegration-exact-debit-alt-gas")
        );
        StdPrecompiles.STABLECOIN_DEX.createPair(address(altGasToken));
        _addDexLiquidity(address(altGasToken), 1_000_000e6);
        altGasToken.mint(alice, INITIAL_PATH_USD);
        _setUserGasToken(alice, address(altGasToken));

        vm.startPrank(alice);
        uint256 nativeQuote = remoteHopTempo.quote(
            address(tempoFrxUsdAdapter),
            CHAIN_A_EID,
            recipient,
            sendAmount,
            400_000,
            ""
        );
        uint256 fee = remoteHopTempo.quoteStatic(
            address(tempoFrxUsdAdapter),
            CHAIN_A_EID,
            recipient,
            sendAmount,
            400_000,
            "",
            address(altGasToken)
        );
        (, uint128 rawQuote) = _rawSwapQuote(address(altGasToken), uint128(nativeQuote));
        uint256 altGasBefore = IERC20(address(altGasToken)).balanceOf(alice);
        uint256 retainedBefore = StdTokens.PATH_USD.balanceOf(address(remoteHopTempo));

        IERC20(address(tempoFrxUsdToken)).approve(address(remoteHopTempo), type(uint256).max);
        IERC20(address(altGasToken)).approve(address(remoteHopTempo), type(uint256).max);

        remoteHopTempo.sendOFT(address(tempoFrxUsdAdapter), CHAIN_A_EID, recipient, sendAmount, 400_000, "");
        vm.stopPrank();

        uint256 altGasAfter = IERC20(address(altGasToken)).balanceOf(alice);
        uint256 retainedAfter = StdTokens.PATH_USD.balanceOf(address(remoteHopTempo));

        assertGt(fee, 0, "Fee should be non-zero");
        assertEq(fee, _padded(rawQuote), "quoteStatic should be the DEX quote plus headroom");
        assertEq(altGasBefore - altGasAfter, rawQuote, "Single-order book settles at the raw quote");
        assertLe(altGasBefore - altGasAfter, fee, "Net debit never exceeds quoteStatic");
        assertEq(IERC20(address(altGasToken)).balanceOf(address(remoteHopTempo)), 0, "Unspent headroom refunded");
        assertEq(
            IERC20(address(altGasToken)).allowance(address(remoteHopTempo), StdPrecompiles.STABLECOIN_DEX_ADDRESS),
            0,
            "Hop->DEX allowance cleared after the swap"
        );
        assertEq(
            retainedAfter - retainedBefore,
            remoteHopTempo.quoteHop(CHAIN_A_EID, 400_000, ""),
            "Multi-hop send should retain exactly the hop fee as payment-token revenue"
        );

        _setUserGasToken(alice, StdTokens.PATH_USD_ADDRESS);
    }

    // ───────────────────────── fee-swap headroom (quote-vs-fill divergence fix) ─────────────────────────

    /// @dev DEX-routed quotes include the slippage allowance so a UI approving the quoted figure never under-approves;
    ///      whitelisted tokens stay 1:1. The allowance is admin-tunable and the quote follows it.
    function test_Tempo_QuoteStatic_NonWhitelisted_IncludesSwapHeadroom() public {
        bytes32 recipient = OFTMsgCodec.addressToBytes32(bob);
        ITIP20 altGasToken = _createTIP20WithDexPair(
            "Headroom Gas",
            "HGAS",
            keccak256("RemoteHopV2TempoRealOFTIntegration-headroom-gas")
        );
        _addDexLiquidity(address(altGasToken), 1_000_000e6);

        uint256 nativeQuote = remoteHopTempo.quote(
            address(tempoFrxUsdAdapter),
            CHAIN_A_EID,
            recipient,
            10e6,
            400_000,
            ""
        );
        (address target, uint128 rawQuote) = _rawSwapQuote(address(altGasToken), uint128(nativeQuote));
        assertEq(target, StdTokens.PATH_USD_ADDRESS, "only pathUSD is whitelisted in this fixture");

        uint256 altFee = remoteHopTempo.quoteStatic(
            address(tempoFrxUsdAdapter),
            CHAIN_A_EID,
            recipient,
            10e6,
            400_000,
            "",
            address(altGasToken)
        );
        assertEq(altFee, _padded(rawQuote), "default headroom is 50 bps (min +1 unit)");
        assertGt(altFee, rawQuote, "quote strictly above the raw DEX quote");
        assertEq(
            remoteHopTempo.quoteUserTokenFee(address(altGasToken), nativeQuote),
            altFee,
            "quoteUserTokenFee mirrors quoteStatic"
        );
        assertEq(
            remoteHopTempo.quoteStatic(
                address(tempoFrxUsdAdapter),
                CHAIN_A_EID,
                recipient,
                10e6,
                400_000,
                "",
                StdTokens.PATH_USD_ADDRESS
            ),
            nativeQuote,
            "whitelisted token quotes 1:1, no headroom"
        );

        remoteHopTempo.setFeeSwapSlippageBps(MAX_FEE_SWAP_SLIPPAGE_BPS);
        assertEq(
            remoteHopTempo.quoteStatic(
                address(tempoFrxUsdAdapter),
                CHAIN_A_EID,
                recipient,
                10e6,
                400_000,
                "",
                address(altGasToken)
            ),
            _paddedBps(rawQuote, MAX_FEE_SWAP_SLIPPAGE_BPS),
            "quote follows the configured headroom"
        );
        remoteHopTempo.setFeeSwapSlippageBps(0);
        assertEq(remoteHopTempo.feeSwapSlippageBps(), DEFAULT_FEE_SWAP_SLIPPAGE_BPS, "0 restores the default");
    }

    /// @dev The headroom setting lives in an ERC-7201 slot of its own (the hops are upgradeable proxies), is bounded,
    ///      admin-only, and 0 means "default".
    function test_Tempo_SetFeeSwapSlippageBps_AdminOnlyBoundedNamespaced() public {
        assertEq(remoteHopTempo.feeSwapSlippageBps(), DEFAULT_FEE_SWAP_SLIPPAGE_BPS, "default headroom");
        assertEq(
            TEMPO_GAS_TOKEN_STORAGE_LOCATION,
            keccak256(abi.encode(uint256(keccak256("frax.storage.TempoGasTokenBase")) - 1)) & ~bytes32(uint256(0xff)),
            "namespaced slot formula"
        );
        assertEq(
            vm.load(address(remoteHopTempo), TEMPO_GAS_TOKEN_STORAGE_LOCATION),
            bytes32(0),
            "slot untouched by default"
        );

        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, alice, bytes32(0))
        );
        remoteHopTempo.setFeeSwapSlippageBps(100);

        vm.expectRevert(
            abi.encodeWithSelector(
                TempoGasTokenBase.FeeSwapSlippageTooHigh.selector,
                uint16(MAX_FEE_SWAP_SLIPPAGE_BPS + 1)
            )
        );
        remoteHopTempo.setFeeSwapSlippageBps(MAX_FEE_SWAP_SLIPPAGE_BPS + 1);

        vm.expectEmit(true, true, true, true, address(remoteHopTempo));
        emit TempoGasTokenBase.FeeSwapSlippageBpsSet(MAX_FEE_SWAP_SLIPPAGE_BPS);
        remoteHopTempo.setFeeSwapSlippageBps(MAX_FEE_SWAP_SLIPPAGE_BPS);
        assertEq(remoteHopTempo.feeSwapSlippageBps(), MAX_FEE_SWAP_SLIPPAGE_BPS, "max accepted");
        assertEq(
            uint256(vm.load(address(remoteHopTempo), TEMPO_GAS_TOKEN_STORAGE_LOCATION)),
            uint256(MAX_FEE_SWAP_SLIPPAGE_BPS),
            "value stored in the namespaced slot"
        );

        remoteHopTempo.setFeeSwapSlippageBps(0);
        assertEq(remoteHopTempo.feeSwapSlippageBps(), DEFAULT_FEE_SWAP_SLIPPAGE_BPS, "0 restores the default");
    }

    /// @dev Regression for the quote-vs-fill divergence: the DEX quotes an exact-out swap per tick but settles it per
    ///      order, so a fill that crosses an order boundary can need one unit more input than the quote. A hop that
    ///      swapped with `maxAmountIn == quote` reverted `MaxInputExceeded` on such a book (griefable: anyone can place
    ///      the two orders). The book here is the shape reproduced against Tempo mainnet in the fraxtal-lz-hop review:
    ///      two bids at tick 30 sized 100,000,007 and 100,000,011, and an exact-out just past the first order.
    function test_Tempo_SendOFT_NonWhitelisted_SurvivesQuoteFillDivergence() public {
        bytes32 recipient = OFTMsgCodec.addressToBytes32(bob);
        ITIP20 altGasToken = _createTIP20WithDexPair(
            "Divergent Gas",
            "DGAS",
            keccak256("RemoteHopV2TempoRealOFTIntegration-divergent-gas")
        );
        altGasToken.mint(alice, INITIAL_PATH_USD);
        _setUserGasToken(alice, address(altGasToken));

        // Two odd-sized bids at the best tick, nothing else on the book.
        address maker = makeAddr("maker");
        StdTokens.PATH_USD.mint(maker, 300e6);
        vm.startPrank(maker);
        StdTokens.PATH_USD.approve(StdPrecompiles.STABLECOIN_DEX_ADDRESS, type(uint256).max);
        StdPrecompiles.STABLECOIN_DEX.place(address(altGasToken), 100_000_007, true, 30);
        StdPrecompiles.STABLECOIN_DEX.place(address(altGasToken), 100_000_011, true, 30);
        vm.stopPrank();

        // Steer the total fee (endpoint fee + hop fee) to an exact-out that straddles the first order, and confirm on
        // the live DEX code that the un-padded swap the pre-fix hop performed reverts for that size.
        uint256 hopFee = remoteHopTempo.quoteHop(CHAIN_A_EID, 400_000, "");
        SimpleMessageLibMock sendLib = SimpleMessageLibMock(
            payable(EndpointV2Mock(address(tempoEndpoint)).defaultSendLibrary(FRAXTAL_EID))
        );
        uint32[4] memory pastFirstOrder = [uint32(3333), 3334, 6668, 13_337];
        bool found;
        uint128 rawQuote;
        uint256 nativeQuote;
        for (uint256 i; i < pastFirstOrder.length && !found; ++i) {
            uint256 target = 100_030_007 + pastFirstOrder[i];
            sendLib.setMessagingFee(target - hopFee, 0);
            nativeQuote = remoteHopTempo.quote(address(tempoFrxUsdAdapter), CHAIN_A_EID, recipient, 10e6, 400_000, "");
            assertEq(nativeQuote, target, "fee steered to the straddling exact-out");
            (, rawQuote) = _rawSwapQuote(address(altGasToken), uint128(target));
            found = _unpaddedSwapReverts(altGasToken, uint128(target), rawQuote);
        }
        // The guard is only worth something on a book where the DEX quote and the fill disagree. If no probed
        // size diverges, the padded path has nothing to prove against: fail here rather than report a pass that
        // exercised nothing (CI relies on this test as the headroom regression).
        assertTrue(
            found,
            "no probed exact-out diverged from its quote; re-derive the book shape before trusting this guard"
        );
        console2.log("divergent exact-out", nativeQuote, "raw quote", rawQuote);

        vm.startPrank(alice);
        uint256 fee = remoteHopTempo.quoteStatic(
            address(tempoFrxUsdAdapter),
            CHAIN_A_EID,
            recipient,
            10e6,
            400_000,
            "",
            address(altGasToken)
        );
        assertEq(fee, _padded(rawQuote), "quote carries headroom");
        uint256 altGasBefore = altGasToken.balanceOf(alice);
        uint256 retainedBefore = StdTokens.PATH_USD.balanceOf(address(remoteHopTempo));
        IERC20(address(tempoFrxUsdToken)).approve(address(remoteHopTempo), type(uint256).max);
        IERC20(address(altGasToken)).approve(address(remoteHopTempo), fee);

        // Reverted MaxInputExceeded before the fix.
        remoteHopTempo.sendOFT(address(tempoFrxUsdAdapter), CHAIN_A_EID, recipient, 10e6, 400_000, "");
        vm.stopPrank();

        uint256 spent = altGasBefore - altGasToken.balanceOf(alice);
        console2.log("settled", spent);
        assertGt(spent, rawQuote, "settlement needed more input than the per-tick quote");
        assertLe(spent, fee, "net debit within the padded quote");
        assertEq(altGasToken.balanceOf(address(remoteHopTempo)), 0, "unspent headroom refunded, nothing stranded");
        assertEq(
            IERC20(address(altGasToken)).allowance(address(remoteHopTempo), StdPrecompiles.STABLECOIN_DEX_ADDRESS),
            0,
            "hop->DEX allowance cleared"
        );
        assertEq(
            IERC20(address(altGasToken)).allowance(alice, address(remoteHopTempo)),
            0,
            "caller allowance consumed"
        );
        assertEq(
            StdTokens.PATH_USD.balanceOf(address(remoteHopTempo)) - retainedBefore,
            hopFee,
            "hop retains exactly the hop fee in the payment token"
        );

        _setUserGasToken(alice, StdTokens.PATH_USD_ADDRESS);
    }

    /// @dev Dry-runs the swap the pre-fix hop performed (`maxAmountIn == quote`) on the current book and reports
    ///      whether the DEX rejects it, leaving the book untouched.
    function _unpaddedSwapReverts(ITIP20 tokenIn, uint128 amountOut, uint128 maxAmountIn) internal returns (bool) {
        address sweeper = makeAddr("sweeper");
        tokenIn.mint(sweeper, uint256(maxAmountIn) + 1e6);
        uint256 snapshot = vm.snapshotState();
        vm.startPrank(sweeper);
        tokenIn.approve(StdPrecompiles.STABLECOIN_DEX_ADDRESS, type(uint256).max);
        (bool ok, bytes memory data) = StdPrecompiles.STABLECOIN_DEX_ADDRESS.call(
            abi.encodeCall(
                IStablecoinDEX.swapExactAmountOut,
                (address(tokenIn), StdTokens.PATH_USD_ADDRESS, amountOut, maxAmountIn)
            )
        );
        vm.stopPrank();
        vm.revertToState(snapshot);
        return !ok && data.length >= 4 && bytes4(data) == IStablecoinDEX.MaxInputExceeded.selector;
    }

    /// @dev Mirror of TempoGasTokenBase._findSwapTarget: the target the hop will pick and the un-padded DEX quote.
    function _rawSwapQuote(
        address tokenIn,
        uint128 amountOut
    ) internal view returns (address target, uint128 amountIn) {
        address[] memory whitelisted = remoteHopTempo.nativeToken().getWhitelistedTokens();
        amountIn = type(uint128).max;
        for (uint256 i; i < whitelisted.length; ++i) {
            if (whitelisted[i] == tokenIn) continue;
            try StdPrecompiles.STABLECOIN_DEX.quoteSwapExactAmountOut(tokenIn, whitelisted[i], amountOut) returns (
                uint128 quoted
            ) {
                if (quoted < amountIn) {
                    amountIn = quoted;
                    target = whitelisted[i];
                }
            } catch {}
        }
        require(target != address(0), "no swap route");
    }

    /// @dev Mirror of TempoGasTokenBase._withSlippage at the default allowance.
    function _padded(uint256 amountIn) internal pure returns (uint256) {
        return _paddedBps(amountIn, DEFAULT_FEE_SWAP_SLIPPAGE_BPS);
    }

    function _paddedBps(uint256 amountIn, uint256 bps) internal pure returns (uint256 padded) {
        padded = (amountIn * (10_000 + bps)) / 10_000;
        if (padded <= amountIn) padded = amountIn + 1;
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
                        _deployTempoHopImplementation(),
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

    /// @dev The Tempo hop implementation under test; `RemoteHopV201TempoRealOFTIntegration` swaps in V201.
    function _deployTempoHopImplementation() internal virtual returns (address) {
        return address(new RemoteHopV2Tempo(address(tempoEndpoint)));
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

    /// @dev Under `--network tempo` (the only mode whose EVM carries the TIP20 / DEX precompiles this suite needs)
    ///      a mock delivery costs 540k-800k gas, so the 200k budget the production options carry runs out at the
    ///      receiving endpoint's `lzReceive`. The figure only sizes the mock executor's call; it is not under test.
    uint128 internal constant RECEIVE_GAS = 2_000_000;

    function _setTempoAdapterEnforcedOptions() internal {
        EnforcedOptionParam[] memory enforcedOptions = new EnforcedOptionParam[](2);

        bytes memory directOptions = OptionsBuilder.newOptions().addExecutorLzReceiveOption(RECEIVE_GAS, 0);
        bytes memory composeOptions = OptionsBuilder
            .newOptions()
            .addExecutorLzReceiveOption(RECEIVE_GAS, 0)
            .addExecutorLzComposeOption(0, 1_000_000, 0);

        enforcedOptions[0] = EnforcedOptionParam(FRAXTAL_EID, 1, directOptions);
        enforcedOptions[1] = EnforcedOptionParam(FRAXTAL_EID, 2, composeOptions);

        tempoFrxUsdAdapter.setEnforcedOptions(enforcedOptions);
    }

    function _setTempoOftEnforcedOptions() internal {
        bytes memory directOptions = OptionsBuilder.newOptions().addExecutorLzReceiveOption(RECEIVE_GAS, 0);
        bytes memory composeOptions = OptionsBuilder
            .newOptions()
            .addExecutorLzReceiveOption(RECEIVE_GAS, 0)
            .addExecutorLzComposeOption(0, 1_000_000, 0);

        tempoFraxOft.setTempoEnforcedOptions(FRAXTAL_EID, directOptions, composeOptions);
    }

    function _setFraxtalAdapterEnforcedOptions() internal {
        LzEnforcedOptionParam[] memory enforcedOptions = new LzEnforcedOptionParam[](1);
        bytes memory directOptions = OptionsBuilder.newOptions().addExecutorLzReceiveOption(RECEIVE_GAS, 0);
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
