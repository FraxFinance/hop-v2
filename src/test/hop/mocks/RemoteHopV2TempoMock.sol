// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { SendParam, MessagingFee, IOFT } from "@fraxfinance/layerzero-v2-upgradeable/oapp/contracts/oft/interfaces/IOFT.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { IOAppComposer } from "@layerzerolabs/oapp-evm/contracts/oapp/interfaces/IOAppComposer.sol";
import { OFTComposeMsgCodec } from "@layerzerolabs/oft-evm/contracts/libs/OFTComposeMsgCodec.sol";
import { OptionsBuilder } from "@fraxfinance/layerzero-v2-upgradeable/oapp/contracts/oapp/libs/OptionsBuilder.sol";

import { ITIP20 } from "@tempo/interfaces/ITIP20.sol";
import { StdPrecompiles } from "tempo-std/StdPrecompiles.sol";
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

        HopV2Storage storage $ = _getHopV2StorageMock();
        if ($.paused) revert HopPaused();
        if (!$.approvedOft[_oft]) revert InvalidOFT();

        // generate hop message
        HopMessage memory hopMessage = HopMessage({
            srcEid: $.localEid,
            dstEid: _dstEid,
            dstGas: _dstGas,
            sender: bytes32(uint256(uint160(msg.sender))),
            recipient: _recipient,
            data: _data
        });

        // Transfer the OFT token to the hop
        _amountLD = removeDust(_oft, _amountLD);
        if (_amountLD > 0) SafeERC20.safeTransferFrom(IERC20(IOFT(_oft).token()), msg.sender, address(this), _amountLD);

        if (_dstEid == $.localEid) {
            _sendLocal({ _oft: _oft, _amount: _amountLD, _hopMessage: hopMessage });
        } else {
            _sendToDestinationTempo({
                _oft: _oft,
                _amountLD: _amountLD,
                _isTrustedHopMessage: true,
                _hopMessage: hopMessage
            });
        }

        emit SendOFT(_oft, msg.sender, _dstEid, _recipient, _amountLD);
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

    /// @dev Send the OFT to execute hopCompose on a destination chain using ERC20 gas payment
    function _sendToDestinationTempo(
        address _oft,
        uint256 _amountLD,
        bool _isTrustedHopMessage,
        HopMessage memory _hopMessage
    ) internal {
        SendParam memory sendParam = _generateSendParam({
            _amountLD: removeDust(_oft, _amountLD),
            _hopMessage: _hopMessage
        });

        MessagingFee memory fee;
        if (_isTrustedHopMessage) {
            fee = IOFT(_oft).quoteSend(sendParam, false);
        } else {
            fee.nativeFee = 0;
        }

        // Pay for LZ gas using ERC20 (Tempo's EndpointV2Alt)
        // The Hop pulls gas from the user and pays to the endpoint
        if (fee.nativeFee > 0) {
            _payNativeFee(fee.nativeFee);
        }

        // Send the OFT to the recipient
        if (_amountLD > 0) SafeERC20.forceApprove(IERC20(IOFT(_oft).token()), _oft, _amountLD);
        IOFT(_oft).send{ value: 0 }(sendParam, fee, address(this));
    }

    /// @dev Handles gas payment for EndpointV2Alt which uses ERC20 as native token
    function _payNativeFee(uint256 _amount) internal {
        address userToken = StdPrecompiles.TIP_FEE_MANAGER.userTokens(msg.sender);
        HopV2Storage storage $ = _getHopV2StorageMock();
        address endpointAddr = $.endpoint;

        if (userToken == nativeToken) {
            // User's gas token is the endpoint's native token, transfer directly
            ITIP20(nativeToken).transferFrom(msg.sender, endpointAddr, _amount);
        } else {
            // User's gas token is different, need to swap
            uint128 amountIn = StdPrecompiles.STABLECOIN_DEX.quoteSwapExactAmountOut({
                tokenIn: userToken,
                tokenOut: nativeToken,
                amountOut: uint128(_amount)
            });

            ITIP20(userToken).transferFrom(msg.sender, address(this), amountIn);
            ITIP20(userToken).approve(address(StdPrecompiles.STABLECOIN_DEX), amountIn);
            StdPrecompiles.STABLECOIN_DEX.swapExactAmountOut({
                tokenIn: userToken,
                tokenOut: nativeToken,
                amountOut: uint128(_amount),
                maxAmountIn: amountIn
            });
            // Transfer endpoint native token to endpoint
            ITIP20(nativeToken).transfer(endpointAddr, _amount);
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

    /// @dev Access storage - duplicate of parent's private function with different name
    function _getHopV2StorageMock() private pure returns (HopV2Storage storage $) {
        bytes32 slot = 0x6f2b5e4a4e4e1ee6e84aeabd150e6bcb39c4b05494d47809c3cd3d998f859100;
        assembly {
            $.slot := slot
        }
    }
}
