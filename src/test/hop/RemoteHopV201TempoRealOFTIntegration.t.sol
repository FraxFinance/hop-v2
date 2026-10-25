// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { OFTMsgCodec } from "@layerzerolabs/oft-evm/contracts/libs/OFTMsgCodec.sol";
import { ITIP20 } from "tempo-std/interfaces/ITIP20.sol";
import { StdPrecompiles } from "tempo-std/StdPrecompiles.sol";
import { StdTokens } from "tempo-std/StdTokens.sol";

import { RemoteHopV201Tempo } from "src/contracts/hop/RemoteHopV201Tempo.sol";
import { TempoGasTokenBase } from "src/contracts/base/TempoGasTokenBase.sol";
import { RemoteHopV2TempoRealOFTIntegration } from "./RemoteHopV2TempoRealOFTIntegration.t.sol";

/// @notice Runs the real-OFT Tempo integration suite against `RemoteHopV201Tempo`, the implementation behind the
///         deployed Tempo proxy, so the fee-swap headroom fix is exercised on the code that actually ships — and
///         covers the fee-capped `sendOFT` overload that only V201 has.
/// @dev Both hops share `initialize(uint32,address,bytes32,uint32,address,address,address,address[])` and the
///      public surface the inherited suite calls, so only the implementation differs.
contract RemoteHopV201TempoRealOFTIntegration is RemoteHopV2TempoRealOFTIntegration {
    function _deployTempoHopImplementation() internal override returns (address) {
        return address(new RemoteHopV201Tempo(address(tempoEndpoint)));
    }

    function _hop() internal view returns (RemoteHopV201Tempo) {
        return RemoteHopV201Tempo(payable(address(remoteHopTempo)));
    }

    // ───────────────────────── fee-capped sendOFT (V201 only) ─────────────────────────

    /// @dev feeTokenOf is the token the six-argument sendOFT pulls, so integrators can quote and name it.
    function test_Tempo_FeeTokenOf_DefaultsToPathUsdAndFollowsFeeManager() public {
        assertEq(_hop().feeTokenOf(makeAddr("never-set")), StdTokens.PATH_USD_ADDRESS, "unset -> pathUSD");
        _setUserGasToken(alice, address(tempoFrxUsdToken));
        assertEq(_hop().feeTokenOf(alice), address(tempoFrxUsdToken), "set -> that token");
        _setUserGasToken(alice, StdTokens.PATH_USD_ADDRESS);
    }

    /// @dev Whitelisted fee token: the cap is checked against the exact fee. One unit under it reverts the
    ///      whole call with nothing kept; at it the send goes through and the debit is exactly the quote.
    function test_Tempo_SendOFT_FeeCap_WhitelistedToken() public {
        uint256 sendAmount = 10e6;
        bytes32 recipient = OFTMsgCodec.addressToBytes32(bob);

        vm.startPrank(alice);
        uint256 fee = _hop().quoteStatic(
            address(tempoFrxUsdAdapter),
            FRAXTAL_EID,
            recipient,
            sendAmount,
            0,
            "",
            StdTokens.PATH_USD_ADDRESS
        );
        assertGt(fee, 0, "fee should be non-zero");
        IERC20(address(tempoFrxUsdToken)).approve(address(remoteHopTempo), type(uint256).max);
        StdTokens.PATH_USD.approve(address(remoteHopTempo), type(uint256).max);
        uint256 frx0 = tempoFrxUsdToken.balanceOf(alice);
        uint256 path0 = StdTokens.PATH_USD.balanceOf(alice);

        vm.expectRevert(abi.encodeWithSelector(TempoGasTokenBase.FeeAboveCap.selector, fee, fee - 1));
        _hop().sendOFT(
            address(tempoFrxUsdAdapter),
            FRAXTAL_EID,
            recipient,
            sendAmount,
            0,
            "",
            StdTokens.PATH_USD_ADDRESS,
            fee - 1
        );
        assertEq(tempoFrxUsdToken.balanceOf(alice), frx0, "nothing kept on revert: principal");
        assertEq(StdTokens.PATH_USD.balanceOf(alice), path0, "nothing kept on revert: fee");

        _hop().sendOFT(
            address(tempoFrxUsdAdapter),
            FRAXTAL_EID,
            recipient,
            sendAmount,
            0,
            "",
            StdTokens.PATH_USD_ADDRESS,
            fee
        );
        vm.stopPrank();

        assertEq(frx0 - tempoFrxUsdToken.balanceOf(alice), sendAmount, "principal debited");
        assertEq(path0 - StdTokens.PATH_USD.balanceOf(alice), fee, "debited exactly the quoted fee");

        verifyPackets(FRAXTAL_EID, addressToBytes32(address(fraxtalAdapter)));
        assertEq(fraxtalToken.balanceOf(bob), 10e18, "Fraxtal recipient mismatch");
    }

    /// @dev DEX-routed fee token: the cap is checked against the padded quote, which is what quoteStatic
    ///      reports; the unspent headroom comes back. The named token pays even though the caller's
    ///      FeeManager token is pathUSD.
    function test_Tempo_SendOFT_FeeCap_DexRoutedToken_NamedTokenPays() public {
        uint256 sendAmount = 10e6;
        bytes32 recipient = OFTMsgCodec.addressToBytes32(bob);

        ITIP20 altGasToken = _createTIP20(
            "Capped Alt Gas",
            "CAPG",
            keccak256("RemoteHopV201TempoRealOFTIntegration-capped-alt-gas")
        );
        StdPrecompiles.STABLECOIN_DEX.createPair(address(altGasToken));
        _addDexLiquidity(address(altGasToken), 1_000_000e6);
        altGasToken.mint(alice, INITIAL_PATH_USD);
        assertEq(_hop().feeTokenOf(alice), StdTokens.PATH_USD_ADDRESS, "setup: FeeManager token is pathUSD");

        vm.startPrank(alice);
        uint256 nativeQuote = _hop().quote(
            address(tempoFrxUsdAdapter),
            CHAIN_A_EID,
            recipient,
            sendAmount,
            400_000,
            ""
        );
        uint256 fee = _hop().quoteStatic(
            address(tempoFrxUsdAdapter),
            CHAIN_A_EID,
            recipient,
            sendAmount,
            400_000,
            "",
            address(altGasToken)
        );
        (, uint128 rawQuote) = _rawSwapQuote(address(altGasToken), uint128(nativeQuote));
        assertEq(fee, _padded(rawQuote), "quoteStatic is the DEX quote plus headroom");

        IERC20(address(tempoFrxUsdToken)).approve(address(remoteHopTempo), type(uint256).max);
        IERC20(address(altGasToken)).approve(address(remoteHopTempo), type(uint256).max);
        uint256 alt0 = altGasToken.balanceOf(alice);
        uint256 path0 = StdTokens.PATH_USD.balanceOf(alice);
        uint256 retained0 = StdTokens.PATH_USD.balanceOf(address(remoteHopTempo));

        vm.expectRevert(abi.encodeWithSelector(TempoGasTokenBase.FeeAboveCap.selector, fee, fee - 1));
        _hop().sendOFT(
            address(tempoFrxUsdAdapter),
            CHAIN_A_EID,
            recipient,
            sendAmount,
            400_000,
            "",
            address(altGasToken),
            fee - 1
        );
        assertEq(altGasToken.balanceOf(alice), alt0, "nothing kept on revert");

        _hop().sendOFT(
            address(tempoFrxUsdAdapter),
            CHAIN_A_EID,
            recipient,
            sendAmount,
            400_000,
            "",
            address(altGasToken),
            fee
        );
        vm.stopPrank();

        uint256 spent = alt0 - altGasToken.balanceOf(alice);
        assertEq(spent, rawQuote, "single-order book settles at the raw quote");
        assertLe(spent, fee, "net debit never exceeds the cap");
        assertEq(StdTokens.PATH_USD.balanceOf(alice), path0, "FeeManager token untouched: the named token paid");
        assertEq(altGasToken.balanceOf(address(remoteHopTempo)), 0, "unspent headroom refunded");
        assertEq(
            StdTokens.PATH_USD.balanceOf(address(remoteHopTempo)) - retained0,
            remoteHopTempo.quoteHop(CHAIN_A_EID, 400_000, ""),
            "hop retains exactly the hop fee in the payment token"
        );
    }

    function test_Tempo_SendOFT_FeeCap_RejectsZeroFeeToken() public {
        vm.prank(alice);
        vm.expectRevert(RemoteHopV201Tempo.InvalidFeeToken.selector);
        _hop().sendOFT(
            address(tempoFrxUsdAdapter),
            FRAXTAL_EID,
            OFTMsgCodec.addressToBytes32(bob),
            10e6,
            0,
            "",
            address(0),
            type(uint256).max
        );
    }

    // ───────────────────────── zero recipient (V201 entrypoints) ─────────────────────────

    /// @dev The recipient check runs before the fee cap and before either pull: with a zero cap and no
    ///      allowance granted, a cap-first or pull-first ordering would surface FeeAboveCap or the token's
    ///      allowance error instead.
    function test_Tempo_SendOFT_FeeCap_ZeroRecipient_RefusedBeforeCapAndPulls() public {
        bytes32[2] memory bad = [bytes32(0), bytes32(uint256(type(uint96).max) << 160)];
        uint32[3] memory dsts = [FRAXTAL_EID, CHAIN_A_EID, TEMPO_EID];
        uint256 frx0 = tempoFrxUsdToken.balanceOf(alice);
        uint256 path0 = StdTokens.PATH_USD.balanceOf(alice);
        assertEq(IERC20(address(tempoFrxUsdToken)).allowance(alice, address(remoteHopTempo)), 0, "setup: no allowance");

        vm.startPrank(alice);
        for (uint256 i; i < bad.length; ++i) {
            for (uint256 j; j < dsts.length; ++j) {
                vm.expectRevert(abi.encodeWithSignature("ZeroRecipient()"));
                _hop().sendOFT(
                    address(tempoFrxUsdAdapter),
                    dsts[j],
                    bad[i],
                    10e6,
                    400_000,
                    "",
                    StdTokens.PATH_USD_ADDRESS,
                    0
                );
            }
        }
        vm.stopPrank();

        assertEq(tempoFrxUsdToken.balanceOf(alice), frx0, "no principal pulled");
        assertEq(StdTokens.PATH_USD.balanceOf(alice), path0, "no fee pulled");
    }

    /// @dev Both quote views fail closed on the input the send refuses.
    function test_Tempo_Quote_ZeroRecipient() public {
        vm.expectRevert(abi.encodeWithSignature("ZeroRecipient()"));
        _hop().quote(address(tempoFrxUsdAdapter), FRAXTAL_EID, bytes32(0), 10e6, 0, "");

        vm.expectRevert(abi.encodeWithSignature("ZeroRecipient()"));
        _hop().quoteStatic(
            address(tempoFrxUsdAdapter),
            CHAIN_A_EID,
            bytes32(uint256(type(uint96).max) << 160),
            10e6,
            400_000,
            "",
            StdTokens.PATH_USD_ADDRESS
        );
    }
}
