// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import { IOAppComposer } from "@layerzerolabs/oapp-evm/contracts/oapp/interfaces/IOAppComposer.sol";
import { OFTComposeMsgCodec } from "@layerzerolabs/oft-evm/contracts/libs/OFTComposeMsgCodec.sol";
import { OptionsBuilder } from "@fraxfinance/layerzero-v2-upgradeable/oapp/contracts/oapp/libs/OptionsBuilder.sol";
import { SendParam, IOFT } from "@fraxfinance/layerzero-v2-upgradeable/oapp/contracts/oft/interfaces/IOFT.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import { HopV201, HopMessage } from "src/contracts/hop/HopV201.sol";
import { HopActions } from "src/contracts/libraries/HopActions.sol";
import { IHopActionModule } from "src/contracts/interfaces/IHopActionModule.sol";
import { IFraxtalHopV201 } from "src/contracts/interfaces/IFraxtalHopV201.sol";

// ====================================================================
// |     ______                   _______                             |
// |    / _____________ __  __   / ____(_____  ____ _____  ________   |
// |   / /_  / ___/ __ `| |/_/  / /_  / / __ \/ __ `/ __ \/ ___/ _ \  |
// |  / __/ / /  / /_/ _>  <   / __/ / / / / / /_/ / / / / /__/  __/  |
// | /_/   /_/   \__,_/_/|_|  /_/   /_/_/ /_/\__,_/_/ /_/\___/\___/   |
// |                                                                  |
// ====================================================================
// ========================= FraxtalHopV201 ===========================
// ====================================================================

/// @author Frax Finance: https://github.com/FraxFinance
contract FraxtalHopV201 is HopV201, IOAppComposer, IFraxtalHopV201 {
    event Hop(address oft, uint32 indexed srcEid, uint32 indexed dstEid, bytes32 indexed recipient, uint256 amount);

    error InvalidDestinationChain();
    error InvalidRemoteHop();

    /// @dev Hub-only state lives in its own namespace so `HopV2Storage`, shared with every spoke, never changes.
    struct FraxtalHopV201Storage {
        /// @dev Executes tagged `HopMessage.data` (see `HopActions`); zero disables every action
        address actionModule;
    }

    // keccak256(abi.encode(uint256(keccak256("frax.storage.FraxtalHopV201")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant FraxtalHopV201StorageLocation =
        0x082f264becc2542cd02d6f434db51b13ff6e3d25f7cc50107c0660951e19af00;

    function _getFraxtalHopV201Storage() private pure returns (FraxtalHopV201Storage storage $) {
        assembly {
            $.slot := FraxtalHopV201StorageLocation
        }
    }

    constructor() {
        _disableInitializers();
    }

    function initialize(
        uint32 _localEid,
        address _endpoint,
        uint32 _numDVNs,
        address _EXECUTOR,
        address _DVN,
        address _TREASURY,
        address[] memory _approvedOfts
    ) external initializer {
        __init_HopV201(_localEid, _endpoint, _numDVNs, _EXECUTOR, _DVN, _TREASURY, _approvedOfts);
    }

    // receive ETH
    receive() external payable {}

    // Admin

    /// @inheritdoc IFraxtalHopV201
    function setActionModule(address _module) external onlyRole(DEFAULT_ADMIN_ROLE) {
        _getFraxtalHopV201Storage().actionModule = _module;
        emit ActionModuleSet(_module);
    }

    /// @inheritdoc IFraxtalHopV201
    function actionModule() public view returns (address) {
        return _getFraxtalHopV201Storage().actionModule;
    }

    // Public methods

    function sendOFT(
        address _oft,
        uint32 _dstEid,
        bytes32 _recipient,
        uint256 _amountLD,
        uint128 _dstGas,
        bytes memory _data,
        address _refundTo
    ) public payable override {
        if (_dstEid != FRAXTAL_EID && remoteHop(_dstEid) == bytes32(0)) revert InvalidDestinationChain();

        super.sendOFT(_oft, _dstEid, _recipient, _amountLD, _dstGas, _data, _refundTo);
    }

    /// @notice Fee for a Fraxtal-originated send. A tagged action is priced on what actually leaves the hub:
    ///         the output OFT, as a plain send, since the hub clears `data` after converting.
    function quote(
        address _oft,
        uint32 _dstEid,
        bytes32 _recipient,
        uint256 _amount,
        uint128 _dstGas,
        bytes memory _data
    ) public view override returns (uint256) {
        if (HopActions.isMintRedeem(_data)) {
            address module = actionModule();
            if (module == address(0)) revert ActionUnavailable();
            _oft = IHopActionModule(module).outputOft(HopActions.MINT_REDEEM, _oft);
            _data = "";
            _dstGas = 0;
        }
        return super.quote(_oft, _dstEid, _recipient, _amount, _dstGas, _data);
    }

    /// @notice Handles incoming composed messages from LayerZero.
    /// @dev Decodes the message payload to perform a token swap.
    ///      This method expects the encoded compose message to contain the swap amount and recipient address.
    /// @dev source: https://docs.layerzero.network/v2/developers/evm/protocol-gas-settings/options#lzcompose-option
    /// @param _oft The address of the originating OApp/Token.
    /// @param /*_guid*/ The globally unique identifier of the message
    /// @param _message The encoded message content in the format of the OFTComposeMsgCodec.
    /// @param /*Executor*/ Executor address
    /// @param /*Executor Data*/ Additional data for checking for a specific executor
    function lzCompose(
        address _oft,
        bytes32,
        /*_guid*/
        bytes calldata _message,
        address,
        /*Executor*/
        bytes calldata /*Executor Data*/
    ) external payable override {
        if (paused()) revert HopPaused();

        (bool isTrustedHopMessage, bool isDuplicateMessage) = _validateComposeMessage(_oft, _message);
        if (isDuplicateMessage) return;

        _composeRoute(_oft, _message, isTrustedHopMessage);
    }

    /// @dev Decode, sanitise, apply a tagged action and route. Split from `lzCompose` to keep each frame shallow
    ///      enough for non-via-IR builds.
    function _composeRoute(address _oft, bytes calldata _message, bool _isTrustedHopMessage) internal {
        // Extract the composed message from the delivered message using the MsgCodec
        HopMessage memory hopMessage = abi.decode(OFTComposeMsgCodec.composeMsg(_message), (HopMessage));
        uint256 amountLD = OFTComposeMsgCodec.amountLD(_message);

        // An untrusted hop message means that the composer on the source chain is not the RemoteHop.  When the composer
        // is not the RemoteHop, they can craft any arbitrary HopMessage.  In these cases, overwrite the srcEid and sender
        // to ensure the HopMessage data is legitimate when passed to IHopComposer.hopCompose().
        if (!_isTrustedHopMessage) {
            hopMessage.srcEid = OFTComposeMsgCodec.srcEid(_message);
            hopMessage.sender = OFTComposeMsgCodec.composeFrom(_message);
        }

        // Spokes refuse a zero recipient at the source, but an untrusted composer can still craft one here.
        // Delivering to it would strand the final leg on the destination, so refuse and leave the compose replayable.
        if (address(uint160(uint256(hopMessage.recipient))) == address(0)) revert ZeroRecipient();

        // Execute a tagged action (frxUSD <-> sfrxUSD) before routing; the result is forwarded as a plain send.
        (_oft, amountLD, hopMessage) = _applyAction(_oft, amountLD, hopMessage);

        if (hopMessage.dstEid == FRAXTAL_EID) {
            _sendLocal({ _oft: _oft, _amount: amountLD, _hopMessage: hopMessage });
        } else {
            _sendToDestination({
                _oft: _oft,
                _amountLD: removeDust(_oft, amountLD),
                _isTrustedHopMessage: _isTrustedHopMessage,
                _hopMessage: hopMessage
            });
            emit Hop(_oft, hopMessage.srcEid, hopMessage.dstEid, hopMessage.recipient, amountLD);
        }
    }

    // internal methods

    /// @dev Fraxtal-originated sends get the same action hook as composed ones.
    function _beforeRoute(
        address _oft,
        uint256 _amountLD,
        HopMessage memory _hopMessage
    ) internal override returns (address, uint256, HopMessage memory) {
        return _applyAction(_oft, _amountLD, _hopMessage);
    }

    /// @dev If `data` carries a known action tag, convert through the action module and clear the tag so the
    ///      final leg is a plain OFT send that any recipient, EOA included, can receive. The module's answer is
    ///      trusted only after the hub sees the output on its own balance and the output OFT is approved.
    ///      Anything that fails here reverts the whole compose, which LayerZero keeps replayable.
    function _applyAction(
        address _oft,
        uint256 _amountLD,
        HopMessage memory _hopMessage
    ) internal returns (address, uint256, HopMessage memory) {
        if (!HopActions.isMintRedeem(_hopMessage.data)) return (_oft, _amountLD, _hopMessage);

        address module = actionModule();
        if (module == address(0)) revert ActionUnavailable();

        address oftOut = IHopActionModule(module).outputOft(HopActions.MINT_REDEEM, _oft);
        if (!approvedOft(oftOut)) revert InvalidOFT();
        uint256 balanceBefore = IERC20(IOFT(oftOut).token()).balanceOf(address(this));

        SafeERC20.forceApprove(IERC20(IOFT(_oft).token()), module, _amountLD);
        (address convertedOft, uint256 amountOut) = IHopActionModule(module).convert(
            HopActions.MINT_REDEEM,
            _oft,
            _amountLD
        );
        if (
            convertedOft != oftOut || IERC20(IOFT(oftOut).token()).balanceOf(address(this)) < balanceBefore + amountOut
        ) {
            revert ActionOutputMismatch();
        }

        _emitActionApplied(_oft, oftOut, _amountLD, amountOut, _hopMessage);

        _hopMessage.data = "";
        _hopMessage.dstGas = 0;
        return (oftOut, amountOut, _hopMessage);
    }

    /// @dev Split out to keep `_applyAction` within the stack limit of non-via-IR builds.
    function _emitActionApplied(
        address _oftIn,
        address _oftOut,
        uint256 _amountIn,
        uint256 _amountOut,
        HopMessage memory _hopMessage
    ) internal {
        emit ActionApplied(
            HopActions.MINT_REDEEM,
            _oftIn,
            _oftOut,
            _amountIn,
            _amountOut,
            _hopMessage.srcEid,
            _hopMessage.dstEid,
            _hopMessage.recipient
        );
    }

    function _generateSendParam(
        uint256 _amountLD,
        HopMessage memory _hopMessage
    ) internal view override returns (SendParam memory sendParam) {
        sendParam.dstEid = _hopMessage.dstEid;
        sendParam.amountLD = _amountLD;
        sendParam.minAmountLD = _amountLD;

        if (_hopMessage.data.length == 0) {
            // There is no compose message to execute, therefore we know the recipeint should directly receive the tokens.
            sendParam.to = _hopMessage.recipient;
        } else {
            bytes32 to = remoteHop(_hopMessage.dstEid);

            // In sending from A => Fraxtal => B, A does not know if B has a remoteHop.
            // Therefore, revert on Fraxtal lzCompose() when there is no remoteHop to allow replays
            // rather than sending to address(0) on destination
            if (to == bytes32(0)) revert InvalidRemoteHop();
            sendParam.to = to;

            bytes memory options = OptionsBuilder.newOptions();
            options = OptionsBuilder.addExecutorLzComposeOption(options, 0, _hopMessage.dstGas, 0);
            sendParam.extraOptions = options;

            sendParam.composeMsg = abi.encode(_hopMessage);
        }
    }
}
