// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import { IOFT } from "@fraxfinance/layerzero-v2-upgradeable/oapp/contracts/oft/interfaces/IOFT.sol";
import { ITIP20 } from "@tempo/interfaces/ITIP20.sol";
import { StdPrecompiles } from "tempo-std/StdPrecompiles.sol";
import { ReentrancyGuard } from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @dev Minimal view of the *already deployed* `RemoteHopV201Tempo`
///      (`0x0000006D38568b00B457580b734e0076C62de659`). Only the members the
///      wrapper needs are declared so this file stays decoupled from the hop's
///      full inheritance graph.
interface IRemoteHopTempo {
    function sendOFT(
        address _oft,
        uint32 _dstEid,
        bytes32 _recipient,
        uint256 _amountLD,
        uint128 _dstGas,
        bytes memory _data
    ) external payable;

    /// @notice Simulated LayerZero fee for a send, denominated in `_userToken`.
    /// @dev Reverts (`NoSwappableWhitelistedToken`) when `_userToken` can neither
    ///      pay the EndpointV2Alt fee directly nor be swapped to a whitelisted
    ///      stablecoin — this is what makes the wrapper fee-token aware.
    function quoteStatic(
        address _oft,
        uint32 _dstEid,
        bytes32 _recipient,
        uint256 _amount,
        uint128 _dstGas,
        bytes memory _data,
        address _userToken
    ) external view returns (uint256);

    /// @notice Floors `_amountLD` to the OFT's `decimalConversionRate`.
    /// @dev The hop applies this to every send, so anything below the OFT's
    ///      shared-decimal granularity would be charged a fee but never bridged.
    ///      The wrapper pre-cleans with it so the amount it checks and emits is
    ///      exactly the amount that crosses.
    function removeDust(address _oft, uint256 _amountLD) external view returns (uint256);

    /// @notice True while the hop's admin has paused all sends.
    function paused() external view returns (bool);

    /// @notice True for OFTs the hop's admin has allow-listed for bridging.
    function approvedOft(address _oft) external view returns (bool);
}

// ====================================================================
// |     ______                   _______                             |
// |    / _____________ __  __   / ____(_____  ____ _____  ________   |
// |   / /_  / ___/ __ `| |/_/  / /_  / / __ \/ __ `/ __ \/ ___/ _ \  |
// |  / __/ / /  / /_/ _>  <   / __/ / / / / / /_/ / / / / /__/  __/  |
// | /_/   /_/   \__,_/_/|_|  /_/   /_/_/ /_/\__,_/_/ /_/\___/\___/   |
// |                                                                  |
// ====================================================================
// ===================== TempoFeeInclusiveWrapper =====================
// ====================================================================

/// @title TempoFeeInclusiveWrapper
/// @notice Fee-inclusive entrypoint layered over the *already deployed*
///         `RemoteHopV201Tempo`, without any hop upgrade.
///
///         It lets an integrator (e.g. LI.FI) treat `fromAmount` as the total
///         source-token budget: the caller grants ONE approval of the bridged
///         token for exactly `fromAmount`, `msg.value` is zero, the LayerZero
///         fee is deducted from that same token, and only the net remainder is
///         bridged. Plain transfers only — compose payloads are rejected
///         (see `_data`).
///
///         This contract is immutable, ownerless and holds no balance between
///         calls. There is no recovery function: tokens transferred to it
///         directly, outside `sendOFTFeeInclusive`, cannot be retrieved.
///
///         Flow (all atomic):
///           1. Quote the fee in the bridged token via `hop.quoteStatic`.
///              Reverts fast for tokens that cannot source their own fee.
///           2. Dust-clean the remainder and enforce the caller's
///              `_minNetAmountLD` floor against it. Because the fee is re-quoted
///              live here rather than fixed in calldata, this floor is the
///              caller's only protection against the fee moving between quote
///              and execution — pass the quote's `toAmountMin` (converted back
///              to source units). A zero floor is rejected.
///           3. Point THIS wrapper's Fee-Manager token at the bridged token so
///              the hop pulls the fee from the wrapper in that same token.
///              Skipped when the fee is zero (local sends). Runs before any
///              funds move, so the fee manager's own rejection of an
///              unsupported token also lands before the pull.
///           4. Pull exactly `fromAmount` of the bridged token from the caller.
///           5. Call the deployed `hop.sendOFT` with the net amount; the hop
///              pulls `net` (bridge) + `fee` (fee) — both from the wrapper.
///           6. Refund any sub-dust remainder to the caller.
///
///         Scope: the bridged token must satisfy two independent checks.
///           - Step 1: its LayerZero fee can be settled in a whitelisted
///             EndpointV2Alt stablecoin, directly or via a StablecoinDEX swap.
///           - Step 3: it is a factory-deployed USD TIP20, which is what the
///             fee manager requires of any token it is bound to.
///         On Tempo today only `frxUSD` passes both; other Frax OFTs (sfrxUSD,
///         frxETH, sfrxETH, WFRAX, FPI) fail step 1 for remote sends and step 3
///         for local ones. Either way the revert precedes the pull.
///
///         Step 3 calls `TIP_FEE_MANAGER.setUserToken` from contract context.
///         The deployed fee manager permits that — the deployed
///         `RemoteHopV201Tempo` makes the same call on every send. Both
///         behaviours, and the full send path, are pinned against a Tempo
///         mainnet fork in `TempoFeeInclusiveWrapperForkTest`
///         (`forge test --network tempo`).
/// @author Frax Finance: https://github.com/FraxFinance
contract TempoFeeInclusiveWrapper is ReentrancyGuard {
    /// @notice The deployed Tempo hop this wrapper forwards to.
    IRemoteHopTempo public immutable HOP;

    error InvalidHop(address hop);
    error MsgValueNotZero(uint256 value);
    error ComposeNotSupported();
    /// @dev Same selectors as the hop's own errors, so a decoder built for the
    ///      hop reads the wrapper's pre-checks identically.
    error HopPaused();
    error InvalidOFT();
    error ZeroAmount();
    error ZeroMinNetAmount();
    error FeeExceedsInput(uint256 fee, uint256 maxAmountIn);
    error NetAmountZero();
    error InsufficientNetAmount(uint256 netAmount, uint256 minNetAmount);
    /// @dev Raised when a token call returns `false`. A TIP20 never does — it
    ///      returns `true` or reverts, so on Tempo these are unreachable. They
    ///      guard the `if (!...)` checks below, kept as belt-and-braces for a
    ///      non-precompile token a hop admin might allow-list in future.
    error TransferFailed();
    error ApproveFailed();

    /// @param oft The OFT (adapter) bridged.
    /// @param sender The caller whose single approval funded the send.
    /// @param feeToken The bridged token the fee was taken from.
    /// @param netAmount The dust-cleaned amount actually bridged.
    /// @param feeAmount The fee actually taken by the hop, measured as
    ///        `maxAmountIn - netAmount - refund` after the send — not the
    ///        step-1 quote. Today the two are equal by construction.
    /// @param maxAmountIn The gross source-token budget (`fromAmount`).
    event SendOFTFeeInclusive(
        address indexed oft,
        address indexed sender,
        uint32 dstEid,
        bytes32 recipient,
        address feeToken,
        uint256 netAmount,
        uint256 feeAmount,
        uint256 maxAmountIn
    );

    /// @param _hop The deployed `RemoteHopV201Tempo` proxy. Immutable and unrepointable,
    ///        so a zero or codeless address is refused here rather than discovered on
    ///        the first send.
    constructor(address _hop) {
        if (_hop == address(0) || _hop.code.length == 0) revert InvalidHop(_hop);
        HOP = IRemoteHopTempo(_hop);
    }

    /// @notice Bridge `fromAmount` of an OFT with the LayerZero fee deducted from
    ///         that same token, requiring a single approval of the bridged token
    ///         for exactly `_maxAmountInLD` and `msg.value == 0`.
    /// @param _oft The approved OFT (adapter) to bridge.
    /// @param _dstEid Destination LayerZero EID.
    /// @param _recipient Destination recipient (bytes32).
    /// @param _maxAmountInLD Gross source-token budget = `fromAmount`. The sum of
    ///        bridged amount and fee is capped at this value.
    /// @param _minNetAmountLD Minimum amount that must actually be bridged after
    ///        the fee is deducted. The fee is re-quoted live inside this call, so
    ///        the bridged amount is not fixed in calldata the way a plain
    ///        `sendOFT` is; this floor is what makes the delivered amount
    ///        enforceable. Must be non-zero: derive it from a quote (the route's
    ///        `toAmountMin` in source units). Zero reverts with `ZeroMinNetAmount`
    ///        — it would let the fee consume the whole budget, and it is also
    ///        what `quoteFeeInclusive` returns when nothing is bridgeable.
    /// @param _dstGas Destination gas for the delivery (the hub-to-destination
    ///        leg when `_dstEid` is not Fraxtal).
    /// @param _data Must be empty. Compose is not supported through this
    ///        entrypoint: the hop records `msg.sender` — this contract, not the
    ///        caller — as the message sender, so a destination composer would
    ///        see every user as the same address and could not attribute,
    ///        authenticate or refund correctly. Kept in the signature so the
    ///        ABI matches the hop's `sendOFT` shape. Callers needing compose
    ///        should use the hop directly.
    function sendOFTFeeInclusive(
        address _oft,
        uint32 _dstEid,
        bytes32 _recipient,
        uint256 _maxAmountInLD,
        uint256 _minNetAmountLD,
        uint128 _dstGas,
        bytes memory _data
    ) external payable nonReentrant {
        if (msg.value != 0) revert MsgValueNotZero(msg.value);
        if (_maxAmountInLD == 0) revert ZeroAmount();
        // A zero floor would disable the only protection against the live fee
        // eating the budget (see the `_minNetAmountLD` NatSpec). It is also what
        // `quoteFeeInclusive` returns when nothing is bridgeable, so refusing it
        // here turns a mistaken echo of that quote into a revert.
        if (_minNetAmountLD == 0) revert ZeroMinNetAmount();

        // 1-2. Fee and net, from the same derivation `quoteFeeInclusive` serves.
        //      The send is stricter about the answer: where the quote reports
        //      "nothing bridgeable" as zero, the send refuses.
        (address feeToken, uint256 feeAmount, uint256 netAmount) = _previewFeeInclusive(
            _oft,
            _dstEid,
            _recipient,
            _maxAmountInLD,
            _dstGas,
            _data
        );
        if (feeAmount >= _maxAmountInLD) revert FeeExceedsInput(feeAmount, _maxAmountInLD);
        if (netAmount == 0) revert NetAmountZero();
        if (netAmount < _minNetAmountLD) revert InsufficientNetAmount(netAmount, _minNetAmountLD);

        // 3. Make the hop pull the fee from THIS wrapper in `feeToken` (not the
        //    default PATH_USD). Done before any funds move: the fee manager only
        //    accepts factory-deployed USD TIP20s, a stricter test than the quote
        //    in step 1, so its rejection must also land before the pull. Skipped
        //    when no fee is collected (local sends) — the binding would be dead
        //    state, and on that path step 1 never inspects the token at all.
        //    Idempotent — only writes when it would change.
        if (feeAmount != 0 && StdPrecompiles.TIP_FEE_MANAGER.userTokens(address(this)) != feeToken) {
            StdPrecompiles.TIP_FEE_MANAGER.setUserToken(feeToken);
        }

        // 4. Single pull of the source token for exactly `fromAmount`. Every
        //    precondition the wrapper can check has passed by this point.
        //    The return-value checks here and below cannot fire for a TIP20
        //    (it returns `true` or reverts; the deployed hop does not check at
        //    all). They are cheap insurance, not a code path to rely on.
        uint256 balanceBefore = ITIP20(feeToken).balanceOf(address(this));
        if (!ITIP20(feeToken).transferFrom(msg.sender, address(this), _maxAmountInLD)) revert TransferFailed();

        // 5. Approve the gross budget and send. The hop pulls `netAmount` first,
        //    then the fee it re-derives, so after the first pull the allowance
        //    left is exactly `_maxAmountInLD - netAmount`: the quoted fee plus
        //    whatever `removeDust` shaved off (nothing, for a 6/6-decimal OFT).
        //    The quote is therefore a hard cap, not an estimate — a fee that
        //    comes out even one unit above it fails the hop's second
        //    `transferFrom` on allowance and the whole call reverts. It cannot
        //    be absorbed by the refund, and it can never shrink the bridged
        //    amount below the floor checked in step 2.
        if (!ITIP20(feeToken).approve(address(HOP), _maxAmountInLD)) revert ApproveFailed();
        HOP.sendOFT(_oft, _dstEid, _recipient, netAmount, _dstGas, _data);

        // 6. Clear the allowance and refund this call's remainder. Everything
        //    the hop did not pull is still here, so the fee actually taken is
        //    what is missing from the budget once the bridged amount and the
        //    refund are accounted for — read it back rather than trusting the
        //    step-1 quote, so the event reports what happened even if a future
        //    hop implementation priced the fee differently at execution.
        if (!ITIP20(feeToken).approve(address(HOP), 0)) revert ApproveFailed();
        uint256 residual = ITIP20(feeToken).balanceOf(address(this)) - balanceBefore;
        if (residual != 0 && !ITIP20(feeToken).transfer(msg.sender, residual)) revert TransferFailed();
        uint256 actualFee = _maxAmountInLD - netAmount - residual;

        emit SendOFTFeeInclusive(_oft, msg.sender, _dstEid, _recipient, feeToken, netAmount, actualFee, _maxAmountInLD);
    }

    /// @notice Off-chain preview of a fee-inclusive send.
    /// @return feeToken The bridged token the fee is taken from.
    /// @return feeAmount The LayerZero fee (in `feeToken`) deducted from `fromAmount`.
    /// @return netAmount The dust-cleaned amount that will be bridged at the
    ///         current fee. Zero means nothing is bridgeable at this budget (fee
    ///         >= `_maxAmountInLD`): do not send, and never pass it through as
    ///         `_minNetAmountLD` — the send rejects a zero floor. For a
    ///         non-zero result, the floor to pass is this value less the
    ///         caller's slippage allowance, not the value itself.
    function quoteFeeInclusive(
        address _oft,
        uint32 _dstEid,
        bytes32 _recipient,
        uint256 _maxAmountInLD,
        uint128 _dstGas,
        bytes memory _data
    ) external view returns (address feeToken, uint256 feeAmount, uint256 netAmount) {
        return _previewFeeInclusive(_oft, _dstEid, _recipient, _maxAmountInLD, _dstGas, _data);
    }

    /// @dev The single derivation behind both entrypoints, so a floor an
    ///      integrator takes from the quote is by construction the number the
    ///      send checks it against — the two cannot drift apart.
    ///
    ///      Admission first (same input contract for quote and send: a quote for
    ///      a call the send would reject would be misleading), then:
    ///        - Fee in the bridged token via `hop.quoteStatic`. Reverts fast for
    ///          tokens that cannot source their own LayerZero fee. Quoting on the
    ///          gross budget is safe because the LayerZero fee does not vary with
    ///          the amount: it enters the send only as a fixed-width uint64 in the
    ///          OFT payload, so this equals the fee the hop re-derives for `net`.
    ///        - Net, dust-cleaned up front so the amount checked, bridged and
    ///          emitted are one number. Without this, a remainder below the OFT's
    ///          decimalConversionRate would be silently floored to zero by the
    ///          hop, charging the full fee to deliver nothing.
    ///      Reports "nothing bridgeable" (fee >= budget) as `netAmount == 0`
    ///      rather than reverting; the send turns that into `FeeExceedsInput`.
    function _previewFeeInclusive(
        address _oft,
        uint32 _dstEid,
        bytes32 _recipient,
        uint256 _maxAmountInLD,
        uint128 _dstGas,
        bytes memory _data
    ) internal view returns (address feeToken, uint256 feeAmount, uint256 netAmount) {
        if (_data.length != 0) revert ComposeNotSupported();
        _requireHopAccepts(_oft);
        feeToken = IOFT(_oft).token();
        feeAmount = HOP.quoteStatic(_oft, _dstEid, _recipient, _maxAmountInLD, _dstGas, _data, feeToken);
        netAmount = _maxAmountInLD > feeAmount ? HOP.removeDust(_oft, _maxAmountInLD - feeAmount) : 0;
    }

    /// @dev The two hop-side gates `hop.sendOFT` applies first. Mirrored here so
    ///      the quote fails closed during an incident instead of serving numbers
    ///      for a send that cannot land, and so the send surfaces them before any
    ///      external call rather than from inside the hop after the pull.
    function _requireHopAccepts(address _oft) internal view {
        if (HOP.paused()) revert HopPaused();
        if (!HOP.approvedOft(_oft)) revert InvalidOFT();
    }
}
