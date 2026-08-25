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
import { RemoteHopV201Tempo } from "src/contracts/hop/RemoteHopV201Tempo.sol";
import { HopMessage } from "src/contracts/interfaces/IHopV2.sol";
import { IRemoteHopV201Tempo } from "src/contracts/interfaces/IRemoteHopV201Tempo.sol";

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

/// @notice Integration coverage for the real Tempo OFTs with the production `RemoteHopV201Tempo`.
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
    RemoteHopV201Tempo internal remoteHopTempo;

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

        assertEq(
            tempoFrxUsdToken.balanceOf(alice),
            aliceFrxUsdBefore - sendAmount - fee,
            "Same-token fee path should consume bridged token plus fee"
        );

        verifyPackets(FRAXTAL_EID, addressToBytes32(address(fraxtalAdapter)));
        assertEq(fraxtalToken.balanceOf(bob), 10e18, "Fraxtal recipient mismatch");

        _setUserGasToken(alice, StdTokens.PATH_USD_ADDRESS);
    }

    function test_Tempo_FeeInclusive_DirectFrxUsd_UsesOneExactAllowanceAndNoPathApproval() public {
        _enableFrxUsdFeePayment();

        uint256 amountToBridge = 10e6;
        bytes32 recipient = OFTMsgCodec.addressToBytes32(bob);
        uint256 fee = _quoteFrxUsdFee(alice, FRAXTAL_EID, recipient, amountToBridge, 0);
        uint256 maxAmountIn = amountToBridge + fee;

        uint256 aliceFrxUsdBefore = tempoFrxUsdToken.balanceOf(alice);
        uint256 alicePathUsdBefore = StdTokens.PATH_USD.balanceOf(alice);

        vm.startPrank(alice);
        tempoFrxUsdToken.approve(address(remoteHopTempo), maxAmountIn);
        assertEq(
            StdTokens.PATH_USD.allowance(alice, address(remoteHopTempo)),
            0,
            "fee-inclusive send must not require PATH approval"
        );

        remoteHopTempo.sendOFTFeeInclusive(
            address(tempoFrxUsdAdapter),
            FRAXTAL_EID,
            recipient,
            amountToBridge,
            maxAmountIn,
            0,
            ""
        );
        vm.stopPrank();

        assertEq(
            aliceFrxUsdBefore - tempoFrxUsdToken.balanceOf(alice),
            maxAmountIn,
            "one frxUSD allowance should cover amount and exact fee"
        );
        assertEq(tempoFrxUsdToken.allowance(alice, address(remoteHopTempo)), 0, "exact allowance should be consumed");
        assertEq(StdTokens.PATH_USD.balanceOf(alice), alicePathUsdBefore, "PATH_USD must not be pulled from sender");

        verifyPackets(FRAXTAL_EID, addressToBytes32(address(fraxtalAdapter)));
        assertEq(fraxtalToken.balanceOf(bob), 10e18, "Fraxtal recipient should receive the net bridge amount");
    }

    function test_Tempo_FeeInclusive_TwoHop_CollectsCombinedFeeFromFrxUsd() public {
        _enableFrxUsdFeePayment();

        uint256 amountToBridge = 10e6;
        bytes32 recipient = OFTMsgCodec.addressToBytes32(bob);
        uint128 dstGas = 400_000;
        uint256 directFee = _quoteFrxUsdFee(alice, FRAXTAL_EID, recipient, amountToBridge, 0);
        uint256 combinedFee = _quoteFrxUsdFee(alice, CHAIN_A_EID, recipient, amountToBridge, dstGas);
        uint256 maxAmountIn = amountToBridge + combinedFee;

        assertGt(combinedFee, directFee, "two-hop quote should include the Fraxtal onward fee");

        uint256 aliceFrxUsdBefore = tempoFrxUsdToken.balanceOf(alice);
        uint256 alicePathUsdBefore = StdTokens.PATH_USD.balanceOf(alice);
        uint256 retainedPathUsdBefore = StdTokens.PATH_USD.balanceOf(address(remoteHopTempo));

        vm.startPrank(alice);
        tempoFrxUsdToken.approve(address(remoteHopTempo), maxAmountIn);
        remoteHopTempo.sendOFTFeeInclusive(
            address(tempoFrxUsdAdapter),
            CHAIN_A_EID,
            recipient,
            amountToBridge,
            maxAmountIn,
            dstGas,
            ""
        );
        vm.stopPrank();

        assertEq(
            aliceFrxUsdBefore - tempoFrxUsdToken.balanceOf(alice),
            maxAmountIn,
            "one frxUSD allowance should cover both route legs"
        );
        assertEq(StdTokens.PATH_USD.balanceOf(alice), alicePathUsdBefore, "two-hop send must not pull sender PATH_USD");
        assertGt(
            StdTokens.PATH_USD.balanceOf(address(remoteHopTempo)),
            retainedPathUsdBefore,
            "Hop should retain the converted onward fee"
        );

        _deliverFrxUsdTwoHop(amountToBridge, recipient, dstGas, alice);
        assertEq(chainAOft.balanceOf(bob), 10e18, "final recipient should receive the net bridge amount");
    }

    function test_Tempo_FeeInclusive_WrongFeeManagerTokenDoesNotMatter() public {
        _enableFrxUsdFeePayment();
        ITIP20 wrongFeeToken = _createTIP20(
            "Wrong Fee Token",
            "WRONG",
            keccak256("RemoteHopV201Tempo-fee-inclusive-wrong-token")
        );
        _setUserGasToken(alice, address(wrongFeeToken));

        uint256 amountToBridge = 10e6;
        bytes32 recipient = OFTMsgCodec.addressToBytes32(bob);
        uint256 fee = _quoteFrxUsdFee(alice, FRAXTAL_EID, recipient, amountToBridge, 0);
        uint256 maxAmountIn = amountToBridge + fee;

        vm.startPrank(alice);
        tempoFrxUsdToken.approve(address(remoteHopTempo), maxAmountIn);
        assertEq(wrongFeeToken.allowance(alice, address(remoteHopTempo)), 0, "wrong token must not be approved");
        remoteHopTempo.sendOFTFeeInclusive(
            address(tempoFrxUsdAdapter),
            FRAXTAL_EID,
            recipient,
            amountToBridge,
            maxAmountIn,
            0,
            ""
        );
        vm.stopPrank();

        assertEq(wrongFeeToken.balanceOf(alice), 0, "configured FeeManager token must not be debited");
        verifyPackets(FRAXTAL_EID, addressToBytes32(address(fraxtalAdapter)));
        assertEq(fraxtalToken.balanceOf(bob), 10e18, "fee-inclusive send should ignore the wrong preference");
    }

    function test_Tempo_FeeInclusive_UnsetFeeManagerTokenDoesNotMatter() public {
        _enableFrxUsdFeePayment();
        address senderWithNoPreference = makeAddr("senderWithNoFeePreference");
        tempoFrxUsdToken.mint(senderWithNoPreference, INITIAL_TEMPO_FRXUSD);

        assertEq(
            StdPrecompiles.TIP_FEE_MANAGER.userTokens(senderWithNoPreference),
            address(0),
            "test sender should have no FeeManager preference"
        );

        uint256 amountToBridge = 10e6;
        bytes32 recipient = OFTMsgCodec.addressToBytes32(bob);
        uint256 fee = _quoteFrxUsdFee(senderWithNoPreference, FRAXTAL_EID, recipient, amountToBridge, 0);
        uint256 maxAmountIn = amountToBridge + fee;

        vm.startPrank(senderWithNoPreference);
        tempoFrxUsdToken.approve(address(remoteHopTempo), maxAmountIn);
        remoteHopTempo.sendOFTFeeInclusive(
            address(tempoFrxUsdAdapter),
            FRAXTAL_EID,
            recipient,
            amountToBridge,
            maxAmountIn,
            0,
            ""
        );
        vm.stopPrank();

        assertEq(
            StdTokens.PATH_USD.allowance(senderWithNoPreference, address(remoteHopTempo)),
            0,
            "unset preference must not create a PATH approval requirement"
        );
        verifyPackets(FRAXTAL_EID, addressToBytes32(address(fraxtalAdapter)));
        assertEq(fraxtalToken.balanceOf(bob), 10e18, "fee-inclusive send should not use PATH fallback");
    }

    function test_Tempo_FeeInclusive_CapIsAtomicAndHeadroomRemainsInAllowance() public {
        _enableFrxUsdFeePayment();

        uint256 amountToBridge = 10e6;
        bytes32 recipient = OFTMsgCodec.addressToBytes32(bob);
        uint256 fee = _quoteFrxUsdFee(alice, FRAXTAL_EID, recipient, amountToBridge, 0);
        uint256 exactAmountIn = amountToBridge + fee;
        uint256 approvalHeadroom = 123;
        uint256 approvedAmount = exactAmountIn + approvalHeadroom;

        vm.prank(alice);
        tempoFrxUsdToken.approve(address(remoteHopTempo), approvedAmount);

        uint256 aliceFrxUsdBefore = tempoFrxUsdToken.balanceOf(alice);
        uint256 hopFrxUsdBefore = tempoFrxUsdToken.balanceOf(address(remoteHopTempo));
        uint256 hopPathUsdBefore = StdTokens.PATH_USD.balanceOf(address(remoteHopTempo));

        vm.startPrank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(
                IRemoteHopV201Tempo.FeeInclusiveAmountExceedsMaximum.selector,
                amountToBridge,
                fee,
                exactAmountIn - 1
            )
        );
        remoteHopTempo.sendOFTFeeInclusive(
            address(tempoFrxUsdAdapter),
            FRAXTAL_EID,
            recipient,
            amountToBridge,
            exactAmountIn - 1,
            0,
            ""
        );
        vm.stopPrank();

        assertEq(tempoFrxUsdToken.balanceOf(alice), aliceFrxUsdBefore, "failed cap check must not debit sender");
        assertEq(
            tempoFrxUsdToken.balanceOf(address(remoteHopTempo)),
            hopFrxUsdBefore,
            "failed cap check must not leave principal in Hop"
        );
        assertEq(
            StdTokens.PATH_USD.balanceOf(address(remoteHopTempo)),
            hopPathUsdBefore,
            "failed cap check must not execute the fee swap"
        );
        assertEq(
            tempoFrxUsdToken.allowance(alice, address(remoteHopTempo)),
            approvedAmount,
            "failed cap check must preserve the gross allowance"
        );

        vm.prank(alice);
        remoteHopTempo.sendOFTFeeInclusive(
            address(tempoFrxUsdAdapter),
            FRAXTAL_EID,
            recipient,
            amountToBridge,
            approvedAmount,
            0,
            ""
        );

        assertEq(
            tempoFrxUsdToken.allowance(alice, address(remoteHopTempo)),
            approvalHeadroom,
            "remaining allowance must equal gross cap minus actual principal and fee"
        );
        assertEq(
            StdTokens.PATH_USD.allowance(alice, address(remoteHopTempo)),
            0,
            "cap headroom must not introduce a PATH approval"
        );
    }

    function test_Tempo_FeeInclusive_RevertsOnNonzeroMsgValueBeforePull() public {
        uint256 amountToBridge = 10e6;
        uint256 maxAmountIn = 20e6;
        bytes32 recipient = OFTMsgCodec.addressToBytes32(bob);

        vm.prank(alice);
        tempoFrxUsdToken.approve(address(remoteHopTempo), maxAmountIn);
        uint256 balanceBefore = tempoFrxUsdToken.balanceOf(alice);

        vm.startPrank(alice);
        vm.expectRevert(abi.encodeWithSignature("OFTAltCore__msg_value_not_zero(uint256)", 1));
        remoteHopTempo.sendOFTFeeInclusive{ value: 1 }(
            address(tempoFrxUsdAdapter),
            FRAXTAL_EID,
            recipient,
            amountToBridge,
            maxAmountIn,
            0,
            ""
        );
        vm.stopPrank();

        assertEq(tempoFrxUsdToken.balanceOf(alice), balanceBefore, "msg.value rejection must happen before pull");
        assertEq(
            tempoFrxUsdToken.allowance(alice, address(remoteHopTempo)),
            maxAmountIn,
            "msg.value rejection must preserve allowance"
        );
    }

    function test_Tempo_FeeInclusive_ZeroAmountRevertsAtomically() public {
        bytes32 recipient = OFTMsgCodec.addressToBytes32(bob);
        uint256 maxAmountIn = 1e6;

        vm.prank(alice);
        tempoFrxUsdToken.approve(address(remoteHopTempo), maxAmountIn);
        uint256 balanceBefore = tempoFrxUsdToken.balanceOf(alice);

        vm.startPrank(alice);
        vm.expectRevert(IRemoteHopV201Tempo.FeeInclusiveZeroAmount.selector);
        remoteHopTempo.sendOFTFeeInclusive(address(tempoFrxUsdAdapter), FRAXTAL_EID, recipient, 0, maxAmountIn, 0, "");
        vm.stopPrank();

        assertEq(tempoFrxUsdToken.balanceOf(alice), balanceBefore, "zero amount must not debit sender");
        assertEq(
            tempoFrxUsdToken.allowance(alice, address(remoteHopTempo)),
            maxAmountIn,
            "zero amount must not consume allowance"
        );
    }

    function test_Tempo_FeeInclusive_DustOnlyAmountRevertsAtomically() public {
        uint256 decimalConversionRate = tempoFraxOft.decimalConversionRate();
        assertGt(decimalConversionRate, 1, "self-token OFT fixture must have removable dust");
        uint256 dustOnlyAmount = decimalConversionRate - 1;
        bytes32 recipient = OFTMsgCodec.addressToBytes32(bob);

        vm.prank(alice);
        tempoFraxOft.approve(address(remoteHopTempo), dustOnlyAmount);
        uint256 balanceBefore = tempoFraxOft.balanceOf(alice);

        vm.startPrank(alice);
        vm.expectRevert(IRemoteHopV201Tempo.FeeInclusiveZeroAmount.selector);
        remoteHopTempo.sendOFTFeeInclusive(
            address(tempoFraxOft),
            FRAXTAL_EID,
            recipient,
            dustOnlyAmount,
            dustOnlyAmount,
            0,
            ""
        );
        vm.stopPrank();

        assertEq(tempoFraxOft.balanceOf(alice), balanceBefore, "dust-only amount must not debit sender");
        assertEq(
            tempoFraxOft.allowance(alice, address(remoteHopTempo)),
            dustOnlyAmount,
            "dust-only amount must not consume allowance"
        );
    }

    function test_Tempo_FeeInclusive_UnsupportedSelfTokenOftFailsBeforePull() public {
        assertEq(tempoFraxOft.token(), address(tempoFraxOft), "fixture should be a self-token OFT");
        uint256 amountToBridge = 10e18;
        bytes32 recipient = OFTMsgCodec.addressToBytes32(bob);

        vm.prank(alice);
        tempoFraxOft.approve(address(remoteHopTempo), amountToBridge);
        uint256 balanceBefore = tempoFraxOft.balanceOf(alice);

        vm.startPrank(alice);
        vm.expectRevert(abi.encodeWithSignature("NoSwappableWhitelistedToken(address)", address(tempoFraxOft)));
        remoteHopTempo.sendOFTFeeInclusive(
            address(tempoFraxOft),
            FRAXTAL_EID,
            recipient,
            amountToBridge,
            amountToBridge,
            0,
            ""
        );
        vm.stopPrank();

        assertEq(
            tempoFraxOft.balanceOf(alice),
            balanceBefore,
            "OFT without a source-token fee route must fail before token pull"
        );
        assertEq(
            tempoFraxOft.allowance(alice, address(remoteHopTempo)),
            amountToBridge,
            "missing source-token fee route must preserve source allowance"
        );
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

    function test_Tempo_NonWhitelistedMultiHop_QuoteStaticMatchesActualDebit() public {
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
        uint256 fee = remoteHopTempo.quoteStatic(
            address(tempoFrxUsdAdapter),
            CHAIN_A_EID,
            recipient,
            sendAmount,
            400_000,
            "",
            address(altGasToken)
        );
        uint256 altGasBefore = IERC20(address(altGasToken)).balanceOf(alice);
        uint256 retainedBefore = StdTokens.PATH_USD.balanceOf(address(remoteHopTempo));

        IERC20(address(tempoFrxUsdToken)).approve(address(remoteHopTempo), type(uint256).max);
        IERC20(address(altGasToken)).approve(address(remoteHopTempo), type(uint256).max);

        remoteHopTempo.sendOFT(address(tempoFrxUsdAdapter), CHAIN_A_EID, recipient, sendAmount, 400_000, "");
        vm.stopPrank();

        uint256 altGasAfter = IERC20(address(altGasToken)).balanceOf(alice);
        uint256 retainedAfter = StdTokens.PATH_USD.balanceOf(address(remoteHopTempo));

        assertGt(fee, 0, "Fee should be non-zero");
        assertEq(altGasBefore - altGasAfter, fee, "Execution should debit exactly the quoteStatic fee");
        assertGt(retainedAfter, retainedBefore, "Multi-hop send should retain payment-token hop fee revenue");

        _setUserGasToken(alice, StdTokens.PATH_USD_ADDRESS);
    }

    function _enableFrxUsdFeePayment() internal {
        StdPrecompiles.STABLECOIN_DEX.createPair(address(tempoFrxUsdToken));
        _addDexLiquidity(address(tempoFrxUsdToken), 1_000_000e6);
    }

    function _quoteFrxUsdFee(
        address caller,
        uint32 dstEid,
        bytes32 recipient,
        uint256 amountToBridge,
        uint128 dstGas
    ) internal returns (uint256 feeAmount) {
        vm.prank(caller);
        (
            uint256 quotedBridgeAmount,
            address feeToken,
            address paymentToken,
            uint256 quotedFeeAmount,
            uint256 totalAmountIn
        ) = remoteHopTempo.quoteFeeInclusive(
                address(tempoFrxUsdAdapter),
                dstEid,
                recipient,
                amountToBridge,
                dstGas,
                ""
            );

        assertEq(quotedBridgeAmount, amountToBridge, "fixture amount should not contain dust");
        assertEq(feeToken, address(tempoFrxUsdToken), "fee-inclusive quote must bind the source token");
        assertEq(paymentToken, StdTokens.PATH_USD_ADDRESS, "frxUSD fee should convert to PATH_USD");
        assertEq(totalAmountIn, quotedBridgeAmount + quotedFeeAmount, "quote total must equal principal plus fee");
        return quotedFeeAmount;
    }

    function _deliverFrxUsdTwoHop(uint256 amountToBridge, bytes32 recipient, uint128 dstGas, address sender) internal {
        verifyPackets(FRAXTAL_EID, addressToBytes32(address(fraxtalAdapter)));

        bytes memory hopMessage = abi.encode(
            HopMessage({
                srcEid: TEMPO_EID,
                dstEid: CHAIN_A_EID,
                dstGas: dstGas,
                sender: OFTMsgCodec.addressToBytes32(sender),
                recipient: recipient,
                data: ""
            })
        );
        bytes memory composeMsg = abi.encodePacked(OFTMsgCodec.addressToBytes32(address(remoteHopTempo)), hopMessage);
        uint256 amountOnFraxtal = amountToBridge * 1e12;
        bytes memory oftComposeMsg = OFTComposeMsgCodec.encode(1, TEMPO_EID, amountOnFraxtal, composeMsg);

        vm.prank(address(fraxtalEndpoint));
        ILayerZeroComposer(address(fraxtalHop)).lzCompose(
            address(fraxtalAdapter),
            bytes32(0),
            oftComposeMsg,
            address(this),
            ""
        );

        verifyPackets(CHAIN_A_EID, addressToBytes32(address(chainAOft)));
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

        remoteHopTempo = RemoteHopV201Tempo(
            payable(
                address(
                    new TransparentUpgradeableProxy(
                        address(new RemoteHopV201Tempo(address(tempoEndpoint))),
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
