pragma solidity ^0.8.0;

import { AccessControlEnumerableUpgradeable } from "@openzeppelin/contracts-upgradeable/access/extensions/AccessControlEnumerableUpgradeable.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import { OFTComposeMsgCodec } from "@layerzerolabs/oft-evm/contracts/libs/OFTComposeMsgCodec.sol";

import { ILayerZeroDVN } from "src/contracts/interfaces/ILayerZeroDVN.sol";
import { ILayerZeroTreasury } from "src/contracts/interfaces/ILayerZeroTreasury.sol";
import { IExecutor } from "src/contracts/interfaces/IExecutor.sol";

import { SendParam, MessagingFee, IOFT } from "@fraxfinance/layerzero-v2-upgradeable/oapp/contracts/oft/interfaces/IOFT.sol";
import { IOFT2 } from "src/contracts/interfaces/IOFT2.sol";
import { IHopV2, HopMessage } from "src/contracts/interfaces/IHopV2.sol";
import { IHopComposer } from "src/contracts/interfaces/IHopComposer.sol";

contract HopV2 is AccessControlEnumerableUpgradeable, IHopV2 {
    uint32 internal constant FRAXTAL_EID = 30_255;
    /// @dev keccak256("PAUSER_ROLE")
    bytes32 internal constant PAUSER_ROLE = 0x65d7a28e3265b37a6474929f336521b332c1681b933f6cb9f3376673440d862a;

    struct HopV2Storage {
        /// @dev EID of this chain
        uint32 localEid;
        /// @dev LZ endpoint on this chain
        address endpoint;
        /// @dev Admin-controlled boolean to pause hops
        bool paused;
        /// @dev Mapping to validate only trusted OFTs
        mapping(address oft => bool isApproved) approvedOft;
        /// @dev Mapping to track messages to prevent replays / duplicate messages
        mapping(bytes32 message => bool isProcessed) messageProcessed;
        /// @dev Mapping to track the Hop on a remote chain
        mapping(uint32 eid => bytes32 hop) remoteHop;
        /// @dev number of DVNs used to verify a message
        uint32 numDVNs;
        /// @dev Hop fee charged to users to use the Hop service
        uint256 hopFee; // 10_000 based so 1 = 0.01%
        /// @dev Configuration of executor options by chain EID
        mapping(uint32 eid => bytes options) executorOptions;
        /// @dev Address of LZ executor
        address EXECUTOR;
        /// @dev Address of LZ DVN
        address DVN;
        /// @dev Address of LZ treasury
        address TREASURY;
    }

    // keccak256(abi.encode(uint256(keccak256("frax.storage.HopV2")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant HopV2StorageLocation = 0x6f2b5e4a4e4e1ee6e84aeabd150e6bcb39c4b05494d47809c3cd3d998f859100;

    function _getHopV2Storage() private pure returns (HopV2Storage storage $) {
        assembly {
            $.slot := HopV2StorageLocation
        }
    }

    event SendOFT(address oft, address indexed sender, uint32 indexed dstEid, bytes32 indexed to, uint256 amount);
    event MessageHash(address oft, uint32 indexed srcEid, uint64 indexed nonce, bytes32 indexed composeFrom);

    error InvalidOFT();
    error HopPaused();
    error NotEndpoint();
    error NotAuthorized();
    error InsufficientFee();
    error RefundFailed();

    modifier onlyAuthorized() {
        if (!(hasRole(DEFAULT_ADMIN_ROLE, msg.sender) || hasRole(PAUSER_ROLE, msg.sender))) {
            revert NotAuthorized();
        }
        _;
    }

    constructor() {
        _disableInitializers();
    }

    function __init_HopV2(
        uint32 _localEid,
        address _endpoint,
        uint32 _numDVNs,
        address _EXECUTOR,
        address _DVN,
        address _TREASURY,
        address[] memory _approvedOfts
    ) internal {
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);

        HopV2Storage storage $ = _getHopV2Storage();
        $.localEid = _localEid;
        $.endpoint = _endpoint;
        for (uint256 i = 0; i < _approvedOfts.length; i++) {
            $.approvedOft[_approvedOfts[i]] = true;
        }
        $.numDVNs = _numDVNs;
        $.EXECUTOR = _EXECUTOR;
        $.DVN = _DVN;
        $.TREASURY = _TREASURY;
    }

    // Public methods

    /// @notice Send an OFT to a destination without encoded data
    /// @param _oft Address of OFT
    /// @param _dstEid Destination EID
    /// @param _recipient bytes32 representation of recipient
    /// @param _amountLD Amount of OFT to send
    function sendOFT(address _oft, uint32 _dstEid, bytes32 _recipient, uint256 _amountLD) external payable {
        sendOFT(_oft, _dstEid, _recipient, _amountLD, 0, "");
    }

    /// @notice Send an OFT to a destination with encoded data
    /// @dev Check the FraxtalHopV2.remoteHop(_dstEid) to ensure the destination chain is supported.  If the destination
    ///      is not supported, tokens/messages would be stuck on Fraxtal and require a team intervention to recover.
    /// @param _oft Address of OFT
    /// @param _dstEid Destination EID
    /// @param _recipient bytes32 representation of recipient
    /// @param _amountLD Amount of OFT to send
    /// @param _data Encoded data to pass
    function sendOFT(
        address _oft,
        uint32 _dstEid,
        bytes32 _recipient,
        uint256 _amountLD,
        uint128 _dstGas,
        bytes memory _data
    ) public payable virtual {
        HopV2Storage storage $ = _getHopV2Storage();
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

        // Transfer the OFT token to the hop. Clean off dust for the sender that would otherwise be lost through LZ.
        _amountLD = removeDust(_oft, _amountLD);
        if (_amountLD > 0) SafeERC20.safeTransferFrom(IERC20(IOFT(_oft).token()), msg.sender, address(this), _amountLD);

        uint256 sendFee;
        if (_dstEid == $.localEid) {
            // Sending from src => src - no LZ send needed (sendFee remains 0)
            _sendLocal({ _oft: _oft, _amount: _amountLD, _hopMessage: hopMessage });
        } else {
            sendFee = _sendToDestination({
                _oft: _oft,
                _amountLD: _amountLD,
                _isTrustedHopMessage: true,
                _hopMessage: hopMessage
            });
        }

        // Validate the msg.value
        _handleMsgValue(sendFee);

        emit SendOFT(_oft, msg.sender, _dstEid, _recipient, _amountLD);
    }

    // Helper functions

    /// @notice Get the gas cost estimate of going from this chain to a destination chain
    /// @param _oft Address of OFT to send
    /// @param _dstEid Destination EID
    /// @param _recipient Address of recipient upon destination
    /// @param _amount Amount to transfer (dust will be removed)
    /// @param _dstGas Amount of gas to forward to the destination
    /// @param _data Encoded data to pass to the destination
    function quote(
        address _oft,
        uint32 _dstEid,
        bytes32 _recipient,
        uint256 _amount,
        uint128 _dstGas,
        bytes memory _data
    ) public view returns (uint256) {
        uint32 localEid_ = localEid();
        if (_dstEid == localEid_) return 0;

        // generate hop message
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
        uint256 hopFeeOnFraxtal = (_dstEid == FRAXTAL_EID || localEid_ == FRAXTAL_EID)
            ? 0
            : quoteHop(_dstEid, _dstGas, _data);
        return fee.nativeFee + hopFeeOnFraxtal;
    }

    /// @notice Get a gas cost estimate of executing a hop on Fraxtal to a destination chain
    /// @param _dstEid Destination EID
    /// @param _dstGas Amount of gas to forward to the destination
    /// @param _data Encoded data to pass to the destination
    function quoteHop(
        uint32 _dstEid,
        uint128 _dstGas,
        bytes memory _data
    ) public view override returns (uint256 finalFee) {
        HopV2Storage storage $ = _getHopV2Storage();

        uint256 dvnFee = ILayerZeroDVN($.DVN).getFee(_dstEid, 5, address(this), "");
        bytes memory options = $.executorOptions[_dstEid];
        if (options.length == 0) options = hex"01001101000000000000000000000000000493E0";
        if (_data.length != 0) {
            if (_dstGas < 400_000) _dstGas = 400_000;
            options = abi.encodePacked(options, hex"010013030000", _dstGas);
        }
        // msg length = OFTCore._buildMsgAndOptions() =>
        //                OFTMsgCodec.encode() =>
        //                  abi.encodePacked(_sendTo, _amountShared, addressToBytes32(msg.sender), _composeMsg)
        // _sendTo = 32, _amountShared = 8 (uint64), addressToBytes32(msg.sender) = 32,
        // _composeMsg = 96 (abi.encodePacked(HopMessage[srcEid, dstEid, dstGas, sender, recipient])) + _data.length
        //     word 1 (bytes32 chunk): abi.encodePacked(srcEid, dstEid, dstGas)
        //     word 2: sender
        //     word 3: recipient
        // total = 32 + 8 + 32 + 96 + _data.length = 168 + _data.length
        uint256 executorFee = IExecutor($.EXECUTOR).getFee(_dstEid, address(this), 168 + _data.length, options);
        uint256 totalFee = dvnFee * $.numDVNs + executorFee;
        uint256 treasuryFee = ILayerZeroTreasury($.TREASURY).getFee(address(this), _dstEid, totalFee, false);
        finalFee = totalFee + treasuryFee;
        finalFee = (finalFee * (10_000 + $.hopFee)) / 10_000;
    }

    /// @notice Remove the dust amount of OFT so that the message passed is the message received
    function removeDust(address oft, uint256 _amountLD) public view returns (uint256) {
        uint256 decimalConversionRate = IOFT2(oft).decimalConversionRate();
        return (_amountLD / decimalConversionRate) * decimalConversionRate;
    }

    // internal methods

    /// @dev Send the OFT and execute hopCompose on this chain (locally)
    function _sendLocal(address _oft, uint256 _amount, HopMessage memory _hopMessage) internal {
        // transfer the OFT to the recipient
        address recipient = address(uint160(uint256(_hopMessage.recipient)));
        if (_amount > 0) SafeERC20.safeTransfer(IERC20(IOFT(_oft).token()), recipient, _amount);

        // call the compose if there is data
        if (_hopMessage.data.length != 0) {
            IHopComposer(recipient).hopCompose({
                _srcEid: _hopMessage.srcEid,
                _sender: _hopMessage.sender,
                _oft: _oft,
                _amount: _amount,
                _data: _hopMessage.data
            });
        }
    }

    /// @dev Send the OFT to execute hopCompose on a destination chain
    function _sendToDestination(
        address _oft,
        uint256 _amountLD,
        bool _isTrustedHopMessage,
        HopMessage memory _hopMessage
    ) internal returns (uint256) {
        // generate sendParam
        SendParam memory sendParam = _generateSendParam({
            _amountLD: removeDust(_oft, _amountLD),
            _hopMessage: _hopMessage
        });

        MessagingFee memory fee;
        if (_isTrustedHopMessage) {
            // Executes in:
            // - sendOFT()
            // - Fraxtal lzCompose() when remote hop is sender
            fee = IOFT(_oft).quoteSend(sendParam, false);
        } else {
            // Executes when:
            // - Fraxtal lzCompose() from unregistered sender
            fee.nativeFee = msg.value;
        }

        // Send the OFT to the recipient
        if (_amountLD > 0) SafeERC20.forceApprove(IERC20(IOFT(_oft).token()), _oft, _amountLD);
        IOFT(_oft).send{ value: fee.nativeFee }(sendParam, fee, address(this));

        // Return the total amount charged in the send.  On fraxtal, this is only the native fee as there is no hop needed.
        uint256 hopFeeOnFraxtal = (_hopMessage.dstEid == FRAXTAL_EID || localEid() == FRAXTAL_EID)
            ? 0
            : quoteHop(_hopMessage.dstEid, _hopMessage.dstGas, _hopMessage.data);
        return fee.nativeFee + hopFeeOnFraxtal;
    }

    /// @dev Check the incoming message integrity
    function _validateComposeMessage(
        address _oft,
        bytes calldata _message
    ) internal returns (bool isTrustedHopMessage, bool isDuplicateMessage) {
        HopV2Storage storage $ = _getHopV2Storage();

        if (msg.sender != $.endpoint) revert NotEndpoint();
        if ($.paused) revert HopPaused();
        if (!$.approvedOft[_oft]) revert InvalidOFT();

        // Decode message
        uint32 srcEid = OFTComposeMsgCodec.srcEid(_message);
        bytes32 composeFrom = OFTComposeMsgCodec.composeFrom(_message);
        uint64 nonce = OFTComposeMsgCodec.nonce(_message);

        // Encode the unique message data to prevent replays
        bytes32 messageHash = keccak256(abi.encode(_oft, srcEid, nonce, composeFrom));

        // True if the composer is a registered RemoteHop, otherwise false
        isTrustedHopMessage = $.remoteHop[srcEid] == composeFrom;

        if ($.messageProcessed[messageHash]) {
            // The message is a duplicate, we end execution early
            return (isTrustedHopMessage, true);
        } else {
            // We process the message and continue execution
            $.messageProcessed[messageHash] = true;
            emit MessageHash(_oft, srcEid, nonce, composeFrom);
            return (isTrustedHopMessage, false);
        }
    }

    /// @dev Check the msg value of the tx
    function _handleMsgValue(uint256 _sendFee) internal {
        if (msg.value < _sendFee) {
            revert InsufficientFee();
        } else if (msg.value > _sendFee) {
            // refund redundant fee to sender
            (bool success, ) = payable(msg.sender).call{ value: msg.value - _sendFee }("");
            if (!success) revert RefundFailed();
        }
    }

    // Admin functions
    function pauseOn() external onlyAuthorized {
        HopV2Storage storage $ = _getHopV2Storage();
        $.paused = true;
    }

    function pauseOff() external onlyRole(DEFAULT_ADMIN_ROLE) {
        HopV2Storage storage $ = _getHopV2Storage();
        $.paused = false;
    }

    function setApprovedOft(address _oft, bool _isApproved) external onlyRole(DEFAULT_ADMIN_ROLE) {
        HopV2Storage storage $ = _getHopV2Storage();
        $.approvedOft[_oft] = _isApproved;
    }

    function setRemoteHop(uint32 _eid, address _remoteHop) external onlyRole(DEFAULT_ADMIN_ROLE) {
        _setRemoteHop(_eid, bytes32(uint256(uint160(_remoteHop))));
    }

    function setRemoteHop(uint32 _eid, bytes32 _remoteHop) external onlyRole(DEFAULT_ADMIN_ROLE) {
        _setRemoteHop(_eid, _remoteHop);
    }

    function _setRemoteHop(uint32 _eid, bytes32 _remoteHop) internal {
        HopV2Storage storage $ = _getHopV2Storage();
        $.remoteHop[_eid] = _remoteHop;
    }

    function setNumDVNs(uint32 _numDVNs) public onlyRole(DEFAULT_ADMIN_ROLE) {
        HopV2Storage storage $ = _getHopV2Storage();
        $.numDVNs = _numDVNs;
    }

    function setHopFee(uint256 _hopFee) public onlyRole(DEFAULT_ADMIN_ROLE) {
        HopV2Storage storage $ = _getHopV2Storage();
        $.hopFee = _hopFee;
    }

    function setExecutorOptions(uint32 eid, bytes memory _options) public onlyRole(DEFAULT_ADMIN_ROLE) {
        HopV2Storage storage $ = _getHopV2Storage();
        $.executorOptions[eid] = _options;
    }

    function recover(address _target, uint256 _value, bytes memory _data) external onlyRole(DEFAULT_ADMIN_ROLE) {
        (bool success, ) = _target.call{ value: _value }(_data);
        require(success);
    }

    function setMessageProcessed(
        address _oft,
        uint32 _srcEid,
        uint64 _nonce,
        bytes32 _composeFrom
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        HopV2Storage storage $ = _getHopV2Storage();

        bytes32 messageHash = keccak256(abi.encode(_oft, _srcEid, _nonce, _composeFrom));
        $.messageProcessed[messageHash] = true;
        emit MessageHash(_oft, _srcEid, _nonce, _composeFrom);
    }

    // Storage views
    function localEid() public view returns (uint32) {
        HopV2Storage storage $ = _getHopV2Storage();
        return $.localEid;
    }

    function endpoint() external view returns (address) {
        HopV2Storage storage $ = _getHopV2Storage();
        return $.endpoint;
    }

    function paused() public view returns (bool) {
        HopV2Storage storage $ = _getHopV2Storage();
        return $.paused;
    }

    function approvedOft(address oft) external view returns (bool isApproved) {
        HopV2Storage storage $ = _getHopV2Storage();
        return $.approvedOft[oft];
    }

    function messageProcessed(bytes32 message) external view returns (bool isProcessed) {
        HopV2Storage storage $ = _getHopV2Storage();
        return $.messageProcessed[message];
    }

    function remoteHop(uint32 eid) public view returns (bytes32 hop) {
        HopV2Storage storage $ = _getHopV2Storage();
        return $.remoteHop[eid];
    }

    function numDVNs() external view returns (uint32) {
        HopV2Storage storage $ = _getHopV2Storage();
        return $.numDVNs;
    }

    function hopFee() external view returns (uint256) {
        HopV2Storage storage $ = _getHopV2Storage();
        return $.hopFee;
    }

    function executorOptions(uint32 eid) external view returns (bytes memory) {
        HopV2Storage storage $ = _getHopV2Storage();
        return $.executorOptions[eid];
    }

    function EXECUTOR() external view returns (address) {
        HopV2Storage storage $ = _getHopV2Storage();
        return $.EXECUTOR;
    }

    function DVN() external view returns (address) {
        HopV2Storage storage $ = _getHopV2Storage();
        return $.DVN;
    }

    function TREASURY() external view returns (address) {
        HopV2Storage storage $ = _getHopV2Storage();
        return $.TREASURY;
    }

    // virtual functions to override
    function _generateSendParam(
        uint256 _amountLD,
        HopMessage memory _hopMessage
    ) internal view virtual returns (SendParam memory) {}
}
