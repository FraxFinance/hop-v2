// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { OFTMsgCodec } from "@layerzerolabs/oft-evm/contracts/libs/OFTMsgCodec.sol";
import { ITIP20 } from "tempo-std/interfaces/ITIP20.sol";
import { StdPrecompiles } from "tempo-std/StdPrecompiles.sol";
import { StdTokens } from "tempo-std/StdTokens.sol";
import { IFeeManager } from "tempo-std/interfaces/IFeeManager.sol";
import { MockERC20 } from "./mocks/MockERC20.sol";

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

    // ───────────────────────── hop fee-token binding ─────────────────────────

    /// @dev Regression for the stale-binding wedge. The OFT's quote validates the hop's own FeeManager binding,
    ///      which is whatever the previous send paid with. Once that token is no longer LZD-whitelisted and the
    ///      DEX has no route out of it, every quote -- and so every send -- used to revert before the hop could
    ///      re-bind, and no admin function resets the binding. The hop now binds the sender's token first.
    ///      The quote views cannot re-bind (they are views), so while the binding is bad they keep reverting and a
    ///      quote-first caller -- the fee-inclusive wrapper, a UI building a cap -- stays blocked until a state-changing
    ///      call heals it: `rebindFeeTokenIfDelisted()` (no funds), or one direct send. Anyone can make that send
    ///      without a quote: the six-argument form, as here, or the capped form with a cap worked out off-hop.
    function test_Tempo_SendOFT_DelistedBindingCannotBlockNextSender() public {
        bytes32 recipient = OFTMsgCodec.addressToBytes32(bob);
        uint256 expectedFee = _quotePathUsd(FRAXTAL_EID, recipient);
        address dead = _boundToDelistedToken();

        vm.expectRevert(abi.encodeWithSelector(TempoGasTokenBase.NoSwappableWhitelistedToken.selector, dead));
        _hop().quote(address(tempoFrxUsdAdapter), FRAXTAL_EID, recipient, 10e6, 0, "");
        vm.expectRevert(abi.encodeWithSelector(TempoGasTokenBase.NoSwappableWhitelistedToken.selector, dead));
        _quotePathUsd(FRAXTAL_EID, recipient);

        // Alice's FeeManager token is pathUSD; the six-argument send pays in it and needs no quote.
        uint256 path0 = StdTokens.PATH_USD.balanceOf(alice);
        vm.startPrank(alice);
        IERC20(address(tempoFrxUsdToken)).approve(address(remoteHopTempo), type(uint256).max);
        StdTokens.PATH_USD.approve(address(remoteHopTempo), type(uint256).max);
        _hop().sendOFT(address(tempoFrxUsdAdapter), FRAXTAL_EID, recipient, 10e6, 0, "");
        vm.stopPrank();

        assertEq(StdPrecompiles.TIP_FEE_MANAGER.userTokens(address(remoteHopTempo)), StdTokens.PATH_USD_ADDRESS);
        assertEq(path0 - StdTokens.PATH_USD.balanceOf(alice), expectedFee, "charged the healthy-state fee in pathUSD");
        verifyPackets(FRAXTAL_EID, addressToBytes32(address(fraxtalAdapter)));
        assertEq(fraxtalToken.balanceOf(bob), 10e18, "Fraxtal recipient mismatch");
        assertEq(_quotePathUsd(FRAXTAL_EID, recipient), expectedFee, "quote views healed for everyone");
    }

    /// @dev A binding that was never set falls back to pathUSD, which is whitelisted, so the hop quotes through it
    ///      instead of binding the sender's token first. The only write is the bind to the token collected.
    function test_Tempo_SendOFT_UnsetBindingIsNotReboundBeforeQuote() public {
        assertEq(StdPrecompiles.TIP_FEE_MANAGER.userTokens(address(remoteHopTempo)), address(0), "setup: unset");
        address alt = _routedAltGasToken("unset");

        vm.expectCall(StdPrecompiles.TIP_FEE_MANAGER_ADDRESS, abi.encodeCall(IFeeManager.setUserToken, (alt)), 0);
        vm.expectCall(
            StdPrecompiles.TIP_FEE_MANAGER_ADDRESS,
            abi.encodeWithSelector(IFeeManager.setUserToken.selector),
            1
        );
        _sendPayingIn(alt, _quoteIn(alt));

        assertEq(StdPrecompiles.TIP_FEE_MANAGER.userTokens(address(remoteHopTempo)), StdTokens.PATH_USD_ADDRESS);
    }

    /// @dev A whitelisted binding is left alone, and re-binding to the token already bound is skipped: a send
    ///      paid in another token that the DEX routes back to the bound one makes no FeeManager write at all.
    function test_Tempo_SendOFT_WhitelistedBindingIsNotRebound() public {
        vm.prank(address(remoteHopTempo));
        StdPrecompiles.TIP_FEE_MANAGER.setUserToken(StdTokens.PATH_USD_ADDRESS);
        address alt = _routedAltGasToken("whitelisted");

        vm.expectCall(
            StdPrecompiles.TIP_FEE_MANAGER_ADDRESS,
            abi.encodeWithSelector(IFeeManager.setUserToken.selector),
            0
        );
        _sendPayingIn(alt, _quoteIn(alt));

        assertEq(StdPrecompiles.TIP_FEE_MANAGER.userTokens(address(remoteHopTempo)), StdTokens.PATH_USD_ADDRESS);
    }

    /// @dev A quote failure unrelated to the binding -- here a missing peer -- reverts with the OFT's own error
    ///      and never touches the FeeManager.
    function test_Tempo_SendOFT_UnrelatedQuoteFailureLeavesBindingAlone() public {
        address alt = _routedAltGasToken("unrelated");
        tempoFrxUsdAdapter.setPeer(FRAXTAL_EID, bytes32(0));

        vm.expectCall(
            StdPrecompiles.TIP_FEE_MANAGER_ADDRESS,
            abi.encodeWithSelector(IFeeManager.setUserToken.selector),
            0
        );
        vm.startPrank(alice);
        IERC20(address(tempoFrxUsdToken)).approve(address(remoteHopTempo), type(uint256).max);
        IERC20(alt).approve(address(remoteHopTempo), type(uint256).max);
        vm.expectRevert(abi.encodeWithSignature("NoPeer(uint32)", FRAXTAL_EID));
        _hop().sendOFT(
            address(tempoFrxUsdAdapter),
            FRAXTAL_EID,
            OFTMsgCodec.addressToBytes32(bob),
            10e6,
            0,
            "",
            alt,
            type(uint256).max
        );
        vm.stopPrank();

        assertEq(StdPrecompiles.TIP_FEE_MANAGER.userTokens(address(remoteHopTempo)), address(0), "binding untouched");
    }

    /// @dev The same unrelated failure with a delisted binding: the hop does bind the sender's token before
    ///      quoting, and the OFT's own error then reverts the whole send, binding included.
    function test_Tempo_SendOFT_UnrelatedQuoteFailureOnDelistedBindingRollsBack() public {
        address alt = _routedAltGasToken("unrelated-delisted");
        address dead = _boundToDelistedToken();
        tempoFrxUsdAdapter.setPeer(FRAXTAL_EID, bytes32(0));

        vm.startPrank(alice);
        IERC20(address(tempoFrxUsdToken)).approve(address(remoteHopTempo), type(uint256).max);
        IERC20(alt).approve(address(remoteHopTempo), type(uint256).max);
        vm.expectRevert(abi.encodeWithSignature("NoPeer(uint32)", FRAXTAL_EID));
        _hop().sendOFT(
            address(tempoFrxUsdAdapter),
            FRAXTAL_EID,
            OFTMsgCodec.addressToBytes32(bob),
            10e6,
            0,
            "",
            alt,
            type(uint256).max
        );
        vm.stopPrank();

        assertEq(StdPrecompiles.TIP_FEE_MANAGER.userTokens(address(remoteHopTempo)), dead, "binding rolled back");
    }

    /// @dev Delisted binding, sender paying in a token that is itself swapped: the hop binds that token so the
    ///      OFT's quote can price through it, collects via the DEX, then re-binds to the whitelisted token bought.
    function test_Tempo_SendOFT_DelistedBindingWithSwappedFeeToken() public {
        address alt = _routedAltGasToken("delisted-swapped");
        uint256 cap = _quoteIn(alt);
        _boundToDelistedToken();

        vm.expectCall(StdPrecompiles.TIP_FEE_MANAGER_ADDRESS, abi.encodeCall(IFeeManager.setUserToken, (alt)), 1);
        _sendPayingIn(alt, cap);

        assertEq(StdPrecompiles.TIP_FEE_MANAGER.userTokens(address(remoteHopTempo)), StdTokens.PATH_USD_ADDRESS);
        assertEq(IERC20(alt).balanceOf(address(remoteHopTempo)), 0, "no fee token stranded on hop");
    }

    // ───────────────────────── rebindFeeTokenIfDelisted ─────────────────────────

    /// @dev While the binding is whitelisted -- or unset, which resolves to whitelisted pathUSD -- the public
    ///      reset does nothing and makes no FeeManager write.
    function test_Tempo_RebindIsNoOpWhileWhitelisted() public {
        vm.prank(makeAddr("anyone"));
        assertFalse(_hop().rebindFeeTokenIfDelisted(), "unset binding: nothing to do");
        assertEq(StdPrecompiles.TIP_FEE_MANAGER.userTokens(address(remoteHopTempo)), address(0), "still unset");

        vm.prank(address(remoteHopTempo));
        StdPrecompiles.TIP_FEE_MANAGER.setUserToken(StdTokens.PATH_USD_ADDRESS);
        vm.expectCall(
            StdPrecompiles.TIP_FEE_MANAGER_ADDRESS,
            abi.encodeWithSelector(IFeeManager.setUserToken.selector),
            0
        );
        vm.prank(makeAddr("anyone"));
        assertFalse(_hop().rebindFeeTokenIfDelisted(), "whitelisted binding: nothing to do");
        assertEq(StdPrecompiles.TIP_FEE_MANAGER.userTokens(address(remoteHopTempo)), StdTokens.PATH_USD_ADDRESS);
    }

    /// @dev Delisted, unroutable binding: the quote views revert, and anyone holding nothing can clear it with one
    ///      call. The hop lands on the first whitelisted token and every quote works again.
    function test_Tempo_RebindClearsDelistedBindingWithoutFunds() public {
        bytes32 recipient = OFTMsgCodec.addressToBytes32(bob);
        uint256 expectedFee = _quotePathUsd(FRAXTAL_EID, recipient);
        address dead = _boundToDelistedToken();

        // Two accepted entries, the non-default one first, so "first" is distinguishable from pathUSD.
        address second = _routedAltGasToken("rebind-first");
        address lzd = address(remoteHopTempo.nativeToken());
        vm.prank(address(tempoEndpoint));
        (bool ok, ) = lzd.call(abi.encodeWithSignature("whitelistToken(address)", second));
        require(ok, "whitelist");
        address[] memory list = new address[](2);
        list[0] = second;
        list[1] = StdTokens.PATH_USD_ADDRESS;
        vm.mockCall(lzd, abi.encodeWithSignature("getWhitelistedTokens()"), abi.encode(list));

        vm.expectRevert(abi.encodeWithSelector(TempoGasTokenBase.NoSwappableWhitelistedToken.selector, dead));
        _quotePathUsd(FRAXTAL_EID, recipient);

        address keeper = makeAddr("keeper");
        assertEq(StdTokens.PATH_USD.balanceOf(keeper) + IERC20(second).balanceOf(keeper), 0, "keeper holds nothing");
        vm.prank(keeper);
        assertTrue(_hop().rebindFeeTokenIfDelisted(), "rebound");

        assertEq(StdPrecompiles.TIP_FEE_MANAGER.userTokens(address(remoteHopTempo)), second, "first whitelisted token");
        assertEq(_quotePathUsd(FRAXTAL_EID, recipient), expectedFee, "quote views work again");

        vm.prank(keeper);
        assertFalse(_hop().rebindFeeTokenIfDelisted(), "second call does nothing");
        vm.clearMockedCalls();
    }

    /// @dev A whitelist entry the FeeManager refuses (not a USD TIP20) is skipped; with nothing bindable the call
    ///      reverts NoBindableWhitelistedToken instead of reporting success.
    function test_Tempo_RebindSkipsTokensFeeManagerRejects() public {
        address dead = _boundToDelistedToken();
        address lzd = address(remoteHopTempo.nativeToken());
        // A deployed contract, not a TIP20: the FeeManager refuses it even though it has code.
        address notTip20 = address(new MockERC20("Not TIP20", "NT20", 6));

        address[] memory list = new address[](2);
        list[0] = notTip20;
        list[1] = StdTokens.PATH_USD_ADDRESS;
        vm.mockCall(lzd, abi.encodeWithSignature("getWhitelistedTokens()"), abi.encode(list));
        assertTrue(_hop().rebindFeeTokenIfDelisted(), "rebound past the rejected entry");
        assertEq(StdPrecompiles.TIP_FEE_MANAGER.userTokens(address(remoteHopTempo)), StdTokens.PATH_USD_ADDRESS);

        vm.prank(address(remoteHopTempo));
        StdPrecompiles.TIP_FEE_MANAGER.setUserToken(dead);
        address[] memory onlyBad = new address[](1);
        onlyBad[0] = notTip20;
        vm.mockCall(lzd, abi.encodeWithSignature("getWhitelistedTokens()"), abi.encode(onlyBad));
        vm.expectRevert(TempoGasTokenBase.NoBindableWhitelistedToken.selector);
        _hop().rebindFeeTokenIfDelisted();
        vm.clearMockedCalls();
    }

    /// @dev Binds the hop to a fresh USD TIP20 that is neither LZD-whitelisted nor paired on the DEX: the state a
    ///      delisted, unroutable token leaves behind.
    function _boundToDelistedToken() internal returns (address dead) {
        dead = address(
            _createTIP20("Delisted Gas", "DLST", keccak256("RemoteHopV201TempoRealOFTIntegration-delisted"))
        );
        assertFalse(remoteHopTempo.nativeToken().isWhitelistedToken(dead), "setup: not whitelisted");
        vm.prank(address(remoteHopTempo));
        StdPrecompiles.TIP_FEE_MANAGER.setUserToken(dead);
    }

    /// @dev A non-whitelisted TIP20 the DEX routes to pathUSD, funded for alice.
    function _routedAltGasToken(string memory _tag) internal returns (address alt) {
        ITIP20 token = _createTIP20(
            "Routed Alt Gas",
            "RALT",
            keccak256(abi.encodePacked("RemoteHopV201TempoRealOFTIntegration-routed-", _tag))
        );
        StdPrecompiles.STABLECOIN_DEX.createPair(address(token));
        _addDexLiquidity(address(token), 1_000_000e6);
        token.mint(alice, INITIAL_PATH_USD);
        alt = address(token);
    }

    function _quotePathUsd(uint32 _dstEid, bytes32 _recipient) internal view returns (uint256) {
        return
            _hop().quoteStatic(
                address(tempoFrxUsdAdapter),
                _dstEid,
                _recipient,
                10e6,
                0,
                "",
                StdTokens.PATH_USD_ADDRESS
            );
    }

    function _quoteIn(address _token) internal view returns (uint256) {
        return
            _hop().quoteStatic(
                address(tempoFrxUsdAdapter),
                FRAXTAL_EID,
                OFTMsgCodec.addressToBytes32(bob),
                10e6,
                0,
                "",
                _token
            );
    }

    /// @dev Sends 10 frxUSD to bob on Fraxtal, paying the fee in `_feeToken` capped at `_cap`.
    function _sendPayingIn(address _feeToken, uint256 _cap) internal {
        vm.startPrank(alice);
        IERC20(address(tempoFrxUsdToken)).approve(address(remoteHopTempo), type(uint256).max);
        IERC20(_feeToken).approve(address(remoteHopTempo), type(uint256).max);
        _hop().sendOFT(
            address(tempoFrxUsdAdapter),
            FRAXTAL_EID,
            OFTMsgCodec.addressToBytes32(bob),
            10e6,
            0,
            "",
            _feeToken,
            _cap
        );
        vm.stopPrank();
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
