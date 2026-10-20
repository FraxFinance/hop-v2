// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { OFTMsgCodec } from "@layerzerolabs/oft-evm/contracts/libs/OFTMsgCodec.sol";
import { ITIP20 } from "tempo-std/interfaces/ITIP20.sol";
import { StdPrecompiles } from "tempo-std/StdPrecompiles.sol";
import { StdTokens } from "tempo-std/StdTokens.sol";

import { RemoteHopV201Tempo } from "src/contracts/hop/RemoteHopV201Tempo.sol";
import { RemoteHopV2TempoRealOFTIntegration } from "./RemoteHopV2TempoRealOFTIntegration.t.sol";

/// @notice Runs the real-OFT Tempo integration suite against `RemoteHopV201Tempo`, the implementation behind the
///         deployed Tempo proxy, so the fee-swap headroom fix is exercised on the code that actually ships.
/// @dev Both hops share `initialize(uint32,address,bytes32,uint32,address,address,address,address[])` and the
///      public surface the suite calls, so only the implementation differs. The 2.1.0 cases below use the
///      seven-argument `sendOFT`, which only the V201 implementation has.
contract RemoteHopV201TempoRealOFTIntegration is RemoteHopV2TempoRealOFTIntegration {
    function _deployTempoHopImplementation() internal override returns (address) {
        return address(new RemoteHopV201Tempo(address(tempoEndpoint)));
    }

    function _v201() internal view returns (RemoteHopV201Tempo) {
        return RemoteHopV201Tempo(payable(address(remoteHopTempo)));
    }

    function test_V210_Version() public view {
        assertEq(_v201().version(), "2.1.0");
    }

    /// @dev On the DEX path the payer is debited the padded pull; with the seven-argument form the headroom the
    ///      swap does not consume goes to `refundTo`, not back to the payer.
    function test_V210_NonWhitelisted_HeadroomRefundedToRefundTo() public {
        uint256 sendAmount = 10e6;
        bytes32 recipient = OFTMsgCodec.addressToBytes32(bob);
        address refundTo = makeAddr("refundTo");

        ITIP20 altGasToken = _createTIP20(
            "RemoteHop RefundTo Alt Gas",
            "RTAG",
            keccak256("RemoteHopV201TempoRealOFTIntegration-refund-to-alt-gas")
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
        uint256 aliceBefore = IERC20(address(altGasToken)).balanceOf(alice);

        IERC20(address(tempoFrxUsdToken)).approve(address(remoteHopTempo), type(uint256).max);
        IERC20(address(altGasToken)).approve(address(remoteHopTempo), type(uint256).max);

        _v201().sendOFT(address(tempoFrxUsdAdapter), CHAIN_A_EID, recipient, sendAmount, 400_000, "", refundTo);
        vm.stopPrank();

        assertEq(fee, _padded(rawQuote), "quoteStatic is the DEX quote plus headroom");
        assertEq(aliceBefore - IERC20(address(altGasToken)).balanceOf(alice), fee, "payer debited the padded pull");
        assertEq(IERC20(address(altGasToken)).balanceOf(refundTo), fee - rawQuote, "headroom lands on refundTo");
        assertEq(IERC20(address(altGasToken)).balanceOf(address(remoteHopTempo)), 0, "nothing stranded on the hop");
    }

    /// @dev The six-argument form keeps refunding the payer, byte for byte the 2.0.x behaviour.
    function test_V210_NonWhitelisted_SixArg_RefundsPayer() public {
        uint256 sendAmount = 10e6;
        bytes32 recipient = OFTMsgCodec.addressToBytes32(bob);

        ITIP20 altGasToken = _createTIP20(
            "RemoteHop SixArg Alt Gas",
            "SAAG",
            keccak256("RemoteHopV201TempoRealOFTIntegration-six-arg-alt-gas")
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
        (, uint128 rawQuote) = _rawSwapQuote(address(altGasToken), uint128(nativeQuote));
        uint256 aliceBefore = IERC20(address(altGasToken)).balanceOf(alice);
        IERC20(address(tempoFrxUsdToken)).approve(address(remoteHopTempo), type(uint256).max);
        IERC20(address(altGasToken)).approve(address(remoteHopTempo), type(uint256).max);
        _v201().sendOFT(address(tempoFrxUsdAdapter), CHAIN_A_EID, recipient, sendAmount, 400_000, "");
        vm.stopPrank();

        assertEq(aliceBefore - IERC20(address(altGasToken)).balanceOf(alice), rawQuote, "net debit is the raw quote");
        assertEq(IERC20(address(altGasToken)).balanceOf(address(remoteHopTempo)), 0);
    }

    function test_V210_ZeroRefundTo_Reverts() public {
        bytes32 recipient = OFTMsgCodec.addressToBytes32(bob);
        vm.startPrank(alice);
        IERC20(address(tempoFrxUsdToken)).approve(address(remoteHopTempo), type(uint256).max);
        vm.expectRevert(abi.encodeWithSignature("ZeroRefundAddress()"));
        _v201().sendOFT(address(tempoFrxUsdAdapter), CHAIN_A_EID, recipient, 10e6, 400_000, "", address(0));
        vm.stopPrank();
    }

    /// @dev A whitelisted gas token is collected 1:1, so there is nothing to refund on either form.
    function test_V210_Whitelisted_NoRefund() public {
        bytes32 recipient = OFTMsgCodec.addressToBytes32(bob);
        address refundTo = makeAddr("refundTo");
        _setUserGasToken(alice, StdTokens.PATH_USD_ADDRESS);

        vm.startPrank(alice);
        uint256 nativeQuote = remoteHopTempo.quote(
            address(tempoFrxUsdAdapter),
            CHAIN_A_EID,
            recipient,
            10e6,
            400_000,
            ""
        );
        uint256 before = StdTokens.PATH_USD.balanceOf(alice);
        IERC20(address(tempoFrxUsdToken)).approve(address(remoteHopTempo), type(uint256).max);
        StdTokens.PATH_USD.approve(address(remoteHopTempo), type(uint256).max);
        _v201().sendOFT(address(tempoFrxUsdAdapter), CHAIN_A_EID, recipient, 10e6, 400_000, "", refundTo);
        vm.stopPrank();

        assertEq(before - StdTokens.PATH_USD.balanceOf(alice), nativeQuote, "exact 1:1 debit");
        assertEq(StdTokens.PATH_USD.balanceOf(refundTo), 0, "nothing to refund");
    }
}
