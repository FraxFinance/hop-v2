// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import { SendParam, MessagingFee, IOFT } from "@fraxfinance/layerzero-v2-upgradeable/oapp/contracts/oft/interfaces/IOFT.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeCast } from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import { RemoteHopV2 } from "src/contracts/hop/RemoteHopV2.sol";
import { HopMessage } from "src/contracts/hop/HopV2.sol";
import { TempoAltTokenBase } from "src/contracts/base/TempoAltTokenBase.sol";
import { StdTokens } from "tempo-std/StdTokens.sol";

// ====================================================================
// |     ______                   _______                             |
// |    / _____________ __  __   / ____(_____  ____ _____  ________   |
// |   / /_  / ___/ __ `| |/_/  / /_  / / __ \/ __ `/ __ \/ ___/ _ \  |
// |  / __/ / /  / /_/ _>  <   / __/ / / / / / /_/ / / / / /__/  __/  |
// | /_/   /_/   \__,_/_/|_|  /_/   /_/_/ /_/\__,_/_/ /_/\___/\___/   |
// |                                                                  |
// ====================================================================
// ========================= RemoteHopV2Tempo =========================
// ====================================================================

/// @title RemoteHopV2Tempo
/// @notice Tempo chain variant of RemoteHopV2 that uses ERC20 for gas payment via EndpointV2Alt
/// @author Frax Finance: https://github.com/FraxFinance
contract RemoteHopV2Tempo is RemoteHopV2, TempoAltTokenBase {
    constructor(address _endpoint) TempoAltTokenBase(_endpoint) {
        _disableInitializers();
    }

    /// @notice Send an OFT to a destination with encoded data
    /// @dev Overrides base to reject native ETH (Tempo uses ERC20 gas via EndpointV2Alt).
    function sendOFT(
        address _oft,
        uint32 _dstEid,
        bytes32 _recipient,
        uint256 _amountLD,
        uint128 _dstGas,
        bytes memory _data
    ) public payable override {
        // EndpointV2Alt uses ERC20 for gas, not native ETH
        if (msg.value > 0) revert OFTAltCore__msg_value_not_zero(msg.value);
        super.sendOFT(_oft, _dstEid, _recipient, _amountLD, _dstGas, _data);
    }

    /// @notice Override quote to return fees in the caller's resolved user-token units.
    /// @dev On Tempo, the user's gas token may require a DEX swap to obtain a whitelisted
    ///      stablecoin.  This override translates the endpoint-native fee so that integrators
    ///      get a single-step quote() → approve() → sendOFT() UX matching ETH chains.
    /// @dev For contract integrators: msg.sender is used to resolve the gas token, which may
    ///      differ from the end-user's token. Use the 7-parameter overload with an explicit
    ///      _userToken, or call quoteUserTokenFee() for finer control.
    function quote(
        address _oft,
        uint32 _dstEid,
        bytes32 _recipient,
        uint256 _amount,
        uint128 _dstGas,
        bytes memory _data
    ) public view override returns (uint256) {
        uint256 endpointFee = super.quote(_oft, _dstEid, _recipient, _amount, _dstGas, _data);
        if (endpointFee == 0) return 0;

        address userToken = _resolveUserToken();
        if (nativeToken.isWhitelistedToken(userToken)) {
            return endpointFee;
        }
        (, uint128 amountIn) = _findSwapTarget(userToken, SafeCast.toUint128(endpointFee));
        return amountIn;
    }

    /// @notice Quote with an explicit user gas token (for contract integrators).
    /// @dev Use this overload when msg.sender differs from the end-user (e.g. routers, multisigs).
    function quote(
        address _oft,
        uint32 _dstEid,
        bytes32 _recipient,
        uint256 _amount,
        uint128 _dstGas,
        bytes memory _data,
        address _userToken
    ) public view returns (uint256) {
        uint256 endpointFee = super.quote(_oft, _dstEid, _recipient, _amount, _dstGas, _data);
        if (endpointFee == 0) return 0;
        if (_userToken == address(0)) _userToken = StdTokens.PATH_USD_ADDRESS;
        if (nativeToken.isWhitelistedToken(_userToken)) {
            return endpointFee;
        }
        (, uint128 amountIn) = _findSwapTarget(_userToken, SafeCast.toUint128(endpointFee));
        return amountIn;
    }

    /// @dev Override to pay LZ fee in ERC20 via EndpointV2Alt instead of forwarding native ETH.
    ///      Hop-fee revenue stays in the contract as wrapped LZEndpointDollar.
    function _sendToDestination(
        address _oft,
        uint256 _amountLD,
        bool,
        /*_isTrustedHopMessage*/
        HopMessage memory _hopMessage
    ) internal override returns (uint256) {
        HopV2Storage storage $ = _getHopV2Storage();

        // Generate sendParam (always targets Fraxtal hub)
        SendParam memory sendParam = _generateSendParam({ _amountLD: _amountLD, _hopMessage: _hopMessage });

        // Always quote — this is a spoke, only called from sendOFT() (always trusted)
        MessagingFee memory fee = IOFT(_oft).quoteSend(sendParam, false);

        // Account for hop fee if multi-hop (Tempo → Fraxtal → final dest).
        // When dstEid == FRAXTAL_EID the message lands directly on hub; no second hop needed.
        uint256 hopFeeOnFraxtal = (_hopMessage.dstEid == FRAXTAL_EID || $.localEid == FRAXTAL_EID)
            ? 0
            : quoteHop(_hopMessage.dstEid, _hopMessage.dstGas, _hopMessage.data);

        // Pull total fee from user as ERC20, wrap to LZEndpointDollar held by this contract
        _payNativeAltToken(fee.nativeFee + hopFeeOnFraxtal, address(this));

        // Forward only the LZ send fee to the endpoint; hop fee stays as protocol revenue
        SafeERC20.safeTransfer(IERC20(address(nativeToken)), $.endpoint, fee.nativeFee);

        // Approve and send the OFT to Fraxtal hub
        if (_amountLD > 0) SafeERC20.forceApprove(IERC20(IOFT(_oft).token()), _oft, _amountLD);
        IOFT(_oft).send{ value: 0 }(sendParam, fee, address(this));

        // Return 0 — fee already paid via ERC20, _handleMsgValue(0) is a no-op when msg.value == 0
        return 0;
    }
}
