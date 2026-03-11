// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { SendParam, MessagingFee, IOFT } from "@fraxfinance/layerzero-v2-upgradeable/oapp/contracts/oft/interfaces/IOFT.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeCast } from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import { IOAppComposer } from "@layerzerolabs/oapp-evm/contracts/oapp/interfaces/IOAppComposer.sol";
import { OFTComposeMsgCodec } from "@layerzerolabs/oft-evm/contracts/libs/OFTComposeMsgCodec.sol";
import { OptionsBuilder } from "@fraxfinance/layerzero-v2-upgradeable/oapp/contracts/oapp/libs/OptionsBuilder.sol";

import { ITIP20 } from "@tempo/interfaces/ITIP20.sol";
import { StdPrecompiles } from "tempo-std/StdPrecompiles.sol";
import { StdTokens } from "tempo-std/StdTokens.sol";
import { HopV2, HopMessage } from "src/contracts/hop/HopV2.sol";
import { IHopComposer } from "src/contracts/interfaces/IHopComposer.sol";

/// @dev Interface for EndpointV2Alt's nativeToken function
interface IEndpointV2Alt {
    function nativeToken() external view returns (address);
}

/// @title RemoteHopV2TempoMock
/// @notice Mock version of RemoteHopV2Tempo with configurable hub EID for testing
/// @dev Allows overriding FRAXTAL_EID so tests can use mock endpoint EIDs (1, 2, 3)
contract RemoteHopV2TempoMock is HopV2, IOAppComposer {
    using SafeERC20 for IERC20;
    using OptionsBuilder for bytes;

    /// @notice Configurable hub EID (production uses hardcoded 30255)
    uint32 public immutable HUB_EID;

    /// @notice The ERC20 token used as native gas by EndpointV2Alt
    address public immutable nativeToken;

    event Hop(address oft, address indexed recipient, uint256 amount);

    error NativeTokenUnavailable();
    error MsgValueNotZero(uint256 msgValue);

    constructor(address _endpoint, uint32 _hubEid) {
        HUB_EID = _hubEid;
        nativeToken = IEndpointV2Alt(_endpoint).nativeToken();
        _disableInitializers();
    }

    function initialize(
        uint32 _localEid,
        address _endpoint,
        bytes32 _fraxtalHop,
        uint32 _numDVNs,
        address _EXECUTOR,
        address _DVN,
        address _TREASURY,
        address[] memory _approvedOfts
    ) external initializer {
        __init_HopV2(_localEid, _endpoint, _numDVNs, _EXECUTOR, _DVN, _TREASURY, _approvedOfts);
        _setRemoteHop(HUB_EID, _fraxtalHop);
    }

    // receive ETH (shouldn't be used on Tempo but keeping for interface compatibility)
    receive() external payable {}

    /// @notice Override quote to return fees in the caller's resolved user-token units.
    /// @dev Cannot use super.quote() because the base HopV2 has hardcoded FRAXTAL_EID (30255)
    ///      while the mock uses configurable HUB_EID. Replicates the logic with HUB_EID.
    function quote(
        address _oft,
        uint32 _dstEid,
        bytes32 _recipient,
        uint256 _amount,
        uint128 _dstGas,
        bytes memory _data
    ) public view override returns (uint256) {
        uint32 localEid_ = localEid();
        if (_dstEid == localEid_) return 0;

        // Build hop message and send param using mock's HUB_EID
        HopMessage memory hopMessage = HopMessage({
            srcEid: localEid_,
            dstEid: _dstEid,
            dstGas: _dstGas,
            sender: bytes32(uint256(uint160(msg.sender))),
            recipient: _recipient,
            data: _data
        });

        SendParam memory sendParam = _generateSendParam({
            _amountLD: removeDust(_oft, _amount),
            _hopMessage: hopMessage
        });
        MessagingFee memory fee = IOFT(_oft).quoteSend(sendParam, false);

        // Use HUB_EID instead of hardcoded FRAXTAL_EID
        uint256 hopFeeOnHub = (_dstEid == HUB_EID || localEid_ == HUB_EID) ? 0 : quoteHop(_dstEid, _dstGas, _data);

        uint256 endpointFee = fee.nativeFee + hopFeeOnHub;
        if (endpointFee == 0) return 0;

        // Translate to user-token units (handle unset gas token as whitelisted)
        address userToken = StdPrecompiles.TIP_FEE_MANAGER.userTokens(msg.sender);
        if (userToken == address(0) || userToken == nativeToken) {
            return endpointFee;
        }
        uint128 amountIn = StdPrecompiles.STABLECOIN_DEX.quoteSwapExactAmountOut({
            tokenIn: userToken,
            tokenOut: nativeToken,
            amountOut: SafeCast.toUint128(endpointFee)
        });
        return amountIn;
    }

    /// @notice Quote with an explicit user gas token (for contract integrators).
    function quote(
        address _oft,
        uint32 _dstEid,
        bytes32 _recipient,
        uint256 _amount,
        uint128 _dstGas,
        bytes memory _data,
        address _userToken
    ) public view returns (uint256) {
        uint32 localEid_ = localEid();
        if (_dstEid == localEid_) return 0;

        HopMessage memory hopMessage = HopMessage({
            srcEid: localEid_,
            dstEid: _dstEid,
            dstGas: _dstGas,
            sender: bytes32(uint256(uint160(msg.sender))),
            recipient: _recipient,
            data: _data
        });

        SendParam memory sendParam = _generateSendParam({
            _amountLD: removeDust(_oft, _amount),
            _hopMessage: hopMessage
        });
        MessagingFee memory fee = IOFT(_oft).quoteSend(sendParam, false);

        uint256 hopFeeOnHub = (_dstEid == HUB_EID || localEid_ == HUB_EID) ? 0 : quoteHop(_dstEid, _dstGas, _data);

        uint256 endpointFee = fee.nativeFee + hopFeeOnHub;
        if (endpointFee == 0) return 0;

        if (_userToken == address(0)) _userToken = StdTokens.PATH_USD_ADDRESS;
        if (_userToken == nativeToken) {
            return endpointFee;
        }
        uint128 amountIn = StdPrecompiles.STABLECOIN_DEX.quoteSwapExactAmountOut({
            tokenIn: _userToken,
            tokenOut: nativeToken,
            amountOut: SafeCast.toUint128(endpointFee)
        });
        return amountIn;
    }

    /// @notice Send an OFT to a destination with encoded data
    /// @dev Uses ERC20 gas payment instead of msg.value
    function sendOFT(
        address _oft,
        uint32 _dstEid,
        bytes32 _recipient,
        uint256 _amountLD,
        uint128 _dstGas,
        bytes memory _data
    ) public payable override {
        // EndpointV2Alt uses ERC20 for gas, not native ETH
        if (msg.value > 0) revert MsgValueNotZero(msg.value);
        super.sendOFT(_oft, _dstEid, _recipient, _amountLD, _dstGas, _data);
    }

    function _generateSendParam(
        uint256 _amountLD,
        HopMessage memory _hopMessage
    ) internal view override returns (SendParam memory sendParam) {
        sendParam.dstEid = HUB_EID;
        sendParam.amountLD = _amountLD;
        sendParam.minAmountLD = _amountLD;

        // Always add lzReceive gas (required by executor)
        bytes memory options = OptionsBuilder.newOptions();
        uint128 lzReceiveGas = 200_000; // Base gas for lzReceive
        options = options.addExecutorLzReceiveOption(lzReceiveGas, 0);

        if (_hopMessage.dstEid == HUB_EID && _hopMessage.data.length == 0) {
            // Send directly to hub, no compose needed
            sendParam.to = _hopMessage.recipient;
            sendParam.extraOptions = options;
        } else {
            sendParam.to = remoteHop(HUB_EID);

            if (_hopMessage.dstGas < 400_000) _hopMessage.dstGas = 400_000;
            uint128 hubGas = 1_000_000;
            if (_hopMessage.dstGas > hubGas && _hopMessage.dstEid == HUB_EID) hubGas = _hopMessage.dstGas;
            options = options.addExecutorLzComposeOption(0, hubGas, 0);
            sendParam.extraOptions = options;

            sendParam.composeMsg = abi.encode(_hopMessage);
        }
    }

    /// @dev Override to pay LZ fee in ERC20 via EndpointV2Alt instead of forwarding native ETH.
    ///      Hop-fee revenue stays in the contract.
    function _sendToDestination(
        address _oft,
        uint256 _amountLD,
        bool,
        HopMessage memory _hopMessage
    ) internal override returns (uint256) {
        HopV2Storage storage $ = _getHopV2Storage();

        SendParam memory sendParam = _generateSendParam({ _amountLD: _amountLD, _hopMessage: _hopMessage });

        // Always quote — this is a spoke, only called from sendOFT() (always trusted)
        MessagingFee memory fee = IOFT(_oft).quoteSend(sendParam, false);

        // Account for hop fee if multi-hop (Tempo → Fraxtal → final dest).
        uint256 hopFeeOnFraxtal = (_hopMessage.dstEid == HUB_EID || $.localEid == HUB_EID)
            ? 0
            : quoteHop(_hopMessage.dstEid, _hopMessage.dstGas, _hopMessage.data);

        // Single pull from user into this contract, then split: endpoint gets fee.nativeFee, contract retains hopFee
        uint256 totalFee = fee.nativeFee + hopFeeOnFraxtal;
        if (totalFee > 0) {
            _payNativeFee(totalFee, address(this));
            // Forward only the LZ send fee to the endpoint; hop fee stays as protocol revenue
            SafeERC20.safeTransfer(IERC20(nativeToken), $.endpoint, fee.nativeFee);
        }

        // Approve and send the OFT to Fraxtal hub
        if (_amountLD > 0) SafeERC20.forceApprove(IERC20(IOFT(_oft).token()), _oft, _amountLD);
        IOFT(_oft).send{ value: 0 }(sendParam, fee, address(this));

        // Return 0 — fee already paid via ERC20, _handleMsgValue(0) is a no-op when msg.value == 0
        return 0;
    }

    /// @dev Handles gas payment for EndpointV2Alt which uses ERC20 as native token.
    ///      Pulls user's gas token, swaps if needed, and sends wrapped LZEndpointDollar to `_recipient`.
    function _payNativeFee(uint256 _amount, address _recipient) internal {
        address userToken = StdPrecompiles.TIP_FEE_MANAGER.userTokens(msg.sender);

        if (userToken == nativeToken) {
            // User's gas token is the endpoint's native token, transfer directly to recipient
            ITIP20(nativeToken).transferFrom(msg.sender, _recipient, _amount);
        } else {
            // User's gas token is different, need to swap
            uint128 amountIn = StdPrecompiles.STABLECOIN_DEX.quoteSwapExactAmountOut({
                tokenIn: userToken,
                tokenOut: nativeToken,
                amountOut: SafeCast.toUint128(_amount)
            });

            ITIP20(userToken).transferFrom(msg.sender, address(this), amountIn);
            ITIP20(userToken).approve(address(StdPrecompiles.STABLECOIN_DEX), amountIn);
            StdPrecompiles.STABLECOIN_DEX.swapExactAmountOut({
                tokenIn: userToken,
                tokenOut: nativeToken,
                amountOut: SafeCast.toUint128(_amount),
                maxAmountIn: amountIn
            });
            // Transfer swapped native token to recipient
            ITIP20(nativeToken).transfer(_recipient, _amount);
        }
    }

    /// @notice Handles incoming composed messages from LayerZero
    function lzCompose(
        address _oft,
        bytes32, // _guid
        bytes calldata _message,
        address, // _executor
        bytes calldata // _extraData
    ) external payable override {
        (bool isTrustedHopMessage, bool isDuplicateMessage) = _validateComposeMessage(_oft, _message);
        if (isDuplicateMessage) return;

        uint256 amount = OFTComposeMsgCodec.amountLD(_message);
        bytes memory composeMsg = OFTComposeMsgCodec.composeMsg(_message);
        HopMessage memory hopMessage = abi.decode(composeMsg, (HopMessage));
        address recipient = address(uint160(uint256(hopMessage.recipient)));

        if (isTrustedHopMessage && hopMessage.data.length > 0) {
            IHopComposer(recipient).hopCompose(
                OFTComposeMsgCodec.srcEid(_message),
                OFTComposeMsgCodec.composeFrom(_message),
                _oft,
                amount,
                hopMessage.data
            );
        }

        emit Hop(_oft, recipient, amount);
    }
}
