// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import { ITIP20 } from "@tempo/interfaces/ITIP20.sol";
import { StdPrecompiles } from "tempo-std/StdPrecompiles.sol";
import { StdTokens } from "tempo-std/StdTokens.sol";
import { ILZEndpointDollar } from "src/contracts/interfaces/vendor/layerzero/ILZEndpointDollar.sol";
import { SafeCast } from "@openzeppelin/contracts/utils/math/SafeCast.sol";

/// @dev Interface for EndpointV2Alt's nativeToken function
interface IEndpointV2Alt {
    function nativeToken() external view returns (address);
}

/// @title TempoGasTokenBase
/// @notice Shared base for Tempo hop variants that collect LayerZero fees via ERC20 (EndpointV2Alt).
///         Provides the swap-routing logic for converting any user TIP20 gas token into
///         an LZEndpointDollar-whitelisted stablecoin.
/// @dev Inherited by upgradeable hops, so the only mutable state lives in an ERC-7201 namespaced
///      slot: adding it to an already deployed proxy leaves the hop's own storage untouched.
abstract contract TempoGasTokenBase {
    error NativeTokenUnavailable();
    error OFTAltCore__msg_value_not_zero(uint256 _msg_value);
    error NoSwappableWhitelistedToken(address userToken);
    error FeeSwapSlippageTooHigh(uint16 bps);

    /// @notice Emitted when the fee-swap slippage allowance changes.
    event FeeSwapSlippageBpsSet(uint16 bps);

    /// @dev Applied to the quoted input of a fee swap. The DEX quotes per tick but settles per order,
    ///      and each order rounds its input up, so a fill that crosses an order boundary can need more
    ///      input than was quoted; with no headroom the swap reverts `MaxInputExceeded`. Whatever the
    ///      swap does not consume is refunded to the payer in the same call. Mirrors
    ///      frax-oft-upgradeable v1.2.0 (`TempoAltTokenLib`) and fraxtal-lz-hop's copy of this base.
    uint16 internal constant DEFAULT_FEE_SWAP_SLIPPAGE_BPS = 50;
    uint16 internal constant MAX_FEE_SWAP_SLIPPAGE_BPS = 200;

    /// @custom:storage-location erc7201:frax.storage.TempoGasTokenBase
    struct TempoGasTokenStorage {
        /// @dev 0 means "use the default"; read through `feeSwapSlippageBps()`.
        uint16 feeSwapSlippageBps;
    }

    /// @dev keccak256(abi.encode(uint256(keccak256("frax.storage.TempoGasTokenBase")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant TEMPO_GAS_TOKEN_STORAGE_LOCATION =
        0xdde8387d01cc878517f663dabc81b0226de49746c19eb5f56ad6bbacf74af000;

    function _getTempoGasTokenStorage() private pure returns (TempoGasTokenStorage storage $) {
        assembly {
            $.slot := TEMPO_GAS_TOKEN_STORAGE_LOCATION
        }
    }

    ILZEndpointDollar public immutable nativeToken;

    /// @dev Fails the implementation deploy, not the first send, if `_lzEndpoint` is not an EndpointV2Alt.
    constructor(address _lzEndpoint) {
        nativeToken = ILZEndpointDollar(IEndpointV2Alt(_lzEndpoint).nativeToken());
        if (address(nativeToken) == address(0)) revert NativeTokenUnavailable();
    }

    // ─── Fee-Swap Slippage ───────────────────────────────────────────────

    /// @notice Slippage allowance applied to a quoted fee swap, in basis points.
    function feeSwapSlippageBps() public view returns (uint16) {
        uint16 configured = _getTempoGasTokenStorage().feeSwapSlippageBps;
        return configured == 0 ? DEFAULT_FEE_SWAP_SLIPPAGE_BPS : configured;
    }

    /// @dev Pass 0 to fall back to DEFAULT_FEE_SWAP_SLIPPAGE_BPS.
    function _setFeeSwapSlippageBps(uint16 _bps) internal {
        if (_bps > MAX_FEE_SWAP_SLIPPAGE_BPS) revert FeeSwapSlippageTooHigh(_bps);
        _getTempoGasTokenStorage().feeSwapSlippageBps = _bps;
        emit FeeSwapSlippageBpsSet(_bps);
    }

    /// @dev Always adds at least one unit: the quote/settlement divergence is a rounding artefact,
    ///      so a percentage allowance alone rounds away on small amounts.
    function _withSlippage(uint128 _amountIn) internal view returns (uint128) {
        uint256 padded = (uint256(_amountIn) * (10_000 + uint256(feeSwapSlippageBps()))) / 10_000;
        if (padded <= uint256(_amountIn)) padded = uint256(_amountIn) + 1;
        return padded > type(uint128).max ? type(uint128).max : uint128(padded);
    }

    // ─── Token Resolution ────────────────────────────────────────────────

    /// @dev Resolves the caller's TIP20 fee token using Tempo's cascading selection:
    ///      1. `TIP_FEE_MANAGER.userTokens(msg.sender)` — user's explicit choice
    ///      2. Falls back to `PATH_USD` if no token is set (address(0))
    ///      Mirrors the FeeManager spec's `collectFeePreTx` / `collectFeePostTx` fallback.
    function _resolveUserToken() internal view returns (address userToken) {
        userToken = StdPrecompiles.TIP_FEE_MANAGER.userTokens(msg.sender);
        if (userToken == address(0)) {
            userToken = StdTokens.PATH_USD_ADDRESS;
        }
    }

    // ─── Swap Routing ────────────────────────────────────────────────────

    /// @dev Finds the best whitelisted token that can be swapped to from `_userToken`.
    ///      Returns the whitelisted token address and the quoted input amount.
    ///      Reverts if no viable swap path exists.
    function _findSwapTarget(
        address _userToken,
        uint128 _amountOut
    ) internal view returns (address whitelistedToken, uint128 amountIn) {
        address[] memory _tokens = nativeToken.getWhitelistedTokens();
        uint128 _bestAmountIn = type(uint128).max;
        address _bestToken;

        uint256 _tokenCount = _tokens.length;

        for (uint256 i = 0; i < _tokenCount; i++) {
            // Skip the userToken itself (handled by direct collection path)
            if (_tokens[i] == _userToken) continue;

            // Try to quote a swap; if it reverts, skip this token
            try
                StdPrecompiles.STABLECOIN_DEX.quoteSwapExactAmountOut({
                    tokenIn: _userToken,
                    tokenOut: _tokens[i],
                    amountOut: _amountOut
                })
            returns (uint128 _quoted) {
                if (_quoted < _bestAmountIn) {
                    _bestAmountIn = _quoted;
                    _bestToken = _tokens[i];
                }
            } catch {
                continue;
            }
        }

        if (_bestToken == address(0)) revert NoSwappableWhitelistedToken(_userToken);
        return (_bestToken, _bestAmountIn);
    }

    // ─── Quote Helpers ───────────────────────────────────────────────────

    /// @notice Estimates the amount of a given gas token needed for a given endpoint-native fee.
    /// @dev UIs should call this after quoteSend() to determine the token approval amount and
    ///      display the cost in the user's chosen gas token. The caller passes the token address
    ///      explicitly so the quote works even before `setUserToken` is called on-chain.
    /// @param _userToken The TIP20 gas token to quote for.
    /// @param _endpointFee The fee in endpoint-native (LZEndpointDollar) units, as returned by quoteSend().
    /// @return The estimated amount of `_userToken` required, including the slippage allowance
    ///         applied when the fee must be swapped. Approve at least this much; the unspent part
    ///         of the allowance is refunded in the same call.
    function quoteUserTokenFee(address _userToken, uint256 _endpointFee) external view returns (uint256) {
        return _quoteUserTokenFee(_userToken, _endpointFee);
    }

    /// @dev Internal quote helper shared by execution-matching quotes and off-chain previews.
    function _quoteUserTokenFee(address _userToken, uint256 _endpointFee) internal view returns (uint256) {
        if (_endpointFee == 0) return 0;
        if (_userToken == address(0)) _userToken = StdTokens.PATH_USD_ADDRESS;
        if (nativeToken.isWhitelistedToken(_userToken)) {
            return _endpointFee; // collected 1:1, no swap and therefore no slippage
        }
        (, uint128 _amountIn) = _findSwapTarget(_userToken, SafeCast.toUint128(_endpointFee));
        return _withSlippage(_amountIn);
    }

    // ─── Fee Collection ──────────────────────────────────────────────────

    /// @dev Collects `_nativeFee` worth of gas payment into this contract as a single whitelisted token.
    ///      This is useful for callers that need to split one collected payment across multiple consumers.
    ///      On the DEX path the caller is debited `quoteUserTokenFee` (quote plus headroom); whatever the
    ///      swap does not consume is refunded in the same call, so the net debit is at most that figure.
    function _collectNativeAltToken(uint256 _nativeFee) internal returns (address paymentToken) {
        if (_nativeFee == 0) return _resolveUserToken();

        address userToken = _resolveUserToken();

        // If the user's token is already whitelisted, collect it directly.
        if (nativeToken.isWhitelistedToken(userToken)) {
            ITIP20(userToken).transferFrom(msg.sender, address(this), _nativeFee);
            return userToken;
        }

        // Find the cheapest whitelisted token to swap to. The cap carries a slippage allowance
        // because settlement may require marginally more input than the quote returned; the DEX
        // debits only what it consumes and the remainder is refunded below.
        (address targetToken, uint128 quotedAmountIn) = _findSwapTarget(userToken, SafeCast.toUint128(_nativeFee));
        uint128 maxAmountIn = _withSlippage(quotedAmountIn);

        ITIP20(userToken).transferFrom(msg.sender, address(this), maxAmountIn);
        ITIP20(userToken).approve(address(StdPrecompiles.STABLECOIN_DEX), maxAmountIn);
        uint128 spentAmountIn = StdPrecompiles.STABLECOIN_DEX.swapExactAmountOut({
            tokenIn: userToken,
            tokenOut: targetToken,
            amountOut: SafeCast.toUint128(_nativeFee),
            maxAmountIn: maxAmountIn
        });

        // The DEX pulls tokenIn without consuming the allowance, so clear it rather than leave it dangling.
        ITIP20(userToken).approve(address(StdPrecompiles.STABLECOIN_DEX), 0);
        if (maxAmountIn > spentAmountIn) {
            ITIP20(userToken).transfer(msg.sender, maxAmountIn - spentAmountIn);
        }

        return targetToken;
    }
}
