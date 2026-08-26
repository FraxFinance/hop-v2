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
///         bridged.
///
///         Flow (all atomic):
///           1. Quote the fee in the bridged token via `hop.quoteStatic`.
///              Reverts fast for tokens that cannot source their own fee.
///           2. Pull exactly `fromAmount` of the bridged token from the caller.
///           3. Point THIS wrapper's Fee-Manager token at the bridged token so
///              the hop pulls the fee from the wrapper in that same token.
///           4. Call the deployed `hop.sendOFT` with the net amount; the hop
///              pulls `net` (bridge) + `fee` (fee) — both from the wrapper.
///           5. Refund any sub-dust remainder to the caller.
///
///         Scope: viable only for bridged tokens whose LayerZero fee can be
///         settled in a whitelisted EndpointV2Alt stablecoin. On Tempo today
///         that is `frxUSD` only; other Frax OFTs (sfrxUSD, frxETH, sfrxETH,
///         WFRAX, FPI) have no StablecoinDEX path and revert in step 1.
///
///         NOTE (verify on fork): step 3 calls `TIP_FEE_MANAGER.setUserToken`
///         from contract context. The Tempo Solidity spec (the docs/specs copy)
///         guards it with `onlyDirectCall` (`msg.sender == tx.origin`), but the
///         deployed `RemoteHopV201Tempo` already calls `setUserToken` from
///         contract context on every send, so the running precompile permits it.
///         This must be confirmed against a Tempo fork before mainnet use.
/// @author Frax Finance: https://github.com/FraxFinance
contract TempoFeeInclusiveWrapper is ReentrancyGuard {
    /// @notice The deployed Tempo hop this wrapper forwards to.
    IRemoteHopTempo public immutable HOP;

    error MsgValueNotZero(uint256 value);
    error ZeroAmount();
    error FeeExceedsInput(uint256 fee, uint256 maxAmountIn);
    error NetAmountZero();
    error TransferFailed();

    /// @param oft The OFT (adapter) bridged.
    /// @param sender The caller whose single approval funded the send.
    /// @param feeToken The bridged token the fee was taken from.
    /// @param netAmount The amount handed to `hop.sendOFT` (pre-dust-clean).
    /// @param feeAmount The LayerZero fee deducted from `maxAmountIn`.
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

    constructor(address _hop) {
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
    /// @param _dstGas Destination gas for the (composed) delivery.
    /// @param _data Optional compose payload forwarded to the hop.
    function sendOFTFeeInclusive(
        address _oft,
        uint32 _dstEid,
        bytes32 _recipient,
        uint256 _maxAmountInLD,
        uint128 _dstGas,
        bytes memory _data
    ) external payable nonReentrant {
        if (msg.value != 0) revert MsgValueNotZero(msg.value);
        if (_maxAmountInLD == 0) revert ZeroAmount();

        address feeToken = IOFT(_oft).token();

        // 1. Quote the fee in the bridged token. This reverts fast (before any
        //    transferFrom) for tokens that cannot source their own LayerZero fee.
        uint256 feeAmount = HOP.quoteStatic(_oft, _dstEid, _recipient, _maxAmountInLD, _dstGas, _data, feeToken);
        if (feeAmount >= _maxAmountInLD) revert FeeExceedsInput(feeAmount, _maxAmountInLD);

        uint256 netAmount = _maxAmountInLD - feeAmount;
        if (netAmount == 0) revert NetAmountZero();

        // 2. Single pull of the source token for exactly `fromAmount`.
        uint256 balanceBefore = ITIP20(feeToken).balanceOf(address(this));
        if (!ITIP20(feeToken).transferFrom(msg.sender, address(this), _maxAmountInLD)) revert TransferFailed();

        // 3. Make the hop pull the fee from THIS wrapper in `feeToken` (not the
        //    default PATH_USD). Idempotent — only writes when it would change.
        if (StdPrecompiles.TIP_FEE_MANAGER.userTokens(address(this)) != feeToken) {
            StdPrecompiles.TIP_FEE_MANAGER.setUserToken(feeToken);
        }

        // 4. Approve net + fee (both in `feeToken`) and bridge the net amount.
        ITIP20(feeToken).approve(address(HOP), _maxAmountInLD);
        HOP.sendOFT(_oft, _dstEid, _recipient, netAmount, _dstGas, _data);

        // 5. Clear the allowance and refund this call's sub-dust remainder.
        ITIP20(feeToken).approve(address(HOP), 0);
        uint256 residual = ITIP20(feeToken).balanceOf(address(this)) - balanceBefore;
        if (residual != 0 && !ITIP20(feeToken).transfer(msg.sender, residual)) revert TransferFailed();

        emit SendOFTFeeInclusive(_oft, msg.sender, _dstEid, _recipient, feeToken, netAmount, feeAmount, _maxAmountInLD);
    }

    /// @notice Off-chain preview of a fee-inclusive send.
    /// @return feeToken The bridged token the fee is taken from.
    /// @return feeAmount The LayerZero fee (in `feeToken`) deducted from `fromAmount`.
    /// @return netAmount The amount that will be bridged (pre-dust-clean).
    function quoteFeeInclusive(
        address _oft,
        uint32 _dstEid,
        bytes32 _recipient,
        uint256 _maxAmountInLD,
        uint128 _dstGas,
        bytes memory _data
    ) external view returns (address feeToken, uint256 feeAmount, uint256 netAmount) {
        feeToken = IOFT(_oft).token();
        feeAmount = HOP.quoteStatic(_oft, _dstEid, _recipient, _maxAmountInLD, _dstGas, _data, feeToken);
        netAmount = _maxAmountInLD > feeAmount ? _maxAmountInLD - feeAmount : 0;
    }
}
