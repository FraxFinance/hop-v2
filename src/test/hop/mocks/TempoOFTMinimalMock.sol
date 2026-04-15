// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { OFTMsgCodec } from "@layerzerolabs/oft-evm/contracts/libs/OFTMsgCodec.sol";
import { SendParam, MessagingFee, OFTReceipt } from "@layerzerolabs/oft-evm/contracts/interfaces/IOFT.sol";
import { MessagingReceipt, Origin, ILayerZeroEndpointV2, MessagingParams } from "@layerzerolabs/lz-evm-protocol-v2/contracts/interfaces/ILayerZeroEndpointV2.sol";

/// @title TempoOFTMinimalMock
/// @notice Minimal OFT mock for Tempo that uses ERC20 for gas (no OFTAlt inheritance)
/// @dev Avoids stack-too-deep issues from OFTAlt's deep inheritance chain
contract TempoOFTMinimalMock is ERC20, Ownable {
    using OFTMsgCodec for bytes;
    using OFTMsgCodec for bytes32;

    ILayerZeroEndpointV2 public immutable endpoint;
    uint32 public immutable localEid;

    mapping(uint32 eid => bytes32 peer) public peers;

    uint256 public constant DECIMAL_CONVERSION_RATE = 1e12; // 18 - 6 shared decimals

    event OFTSent(
        bytes32 indexed guid,
        uint32 dstEid,
        address indexed fromAddress,
        uint256 amountSentLD,
        uint256 amountReceivedLD
    );
    event OFTReceived(bytes32 indexed guid, uint32 srcEid, address indexed toAddress, uint256 amountReceivedLD);

    constructor(
        string memory _name,
        string memory _symbol,
        address _lzEndpoint,
        address _delegate
    ) ERC20(_name, _symbol) Ownable(_delegate) {
        endpoint = ILayerZeroEndpointV2(_lzEndpoint);
        localEid = endpoint.eid();
        endpoint.setDelegate(_delegate);
    }

    function mint(address _to, uint256 _amount) external {
        _mint(_to, _amount);
    }

    function burn(address _from, uint256 _amount) external {
        _burn(_from, _amount);
    }

    function setPeer(uint32 _eid, bytes32 _peer) external onlyOwner {
        peers[_eid] = _peer;
    }

    function sharedDecimals() public pure returns (uint8) {
        return 6;
    }

    function token() external view returns (address) {
        return address(this);
    }

    /// @notice Quote the messaging fee for a send operation
    function quoteSend(
        SendParam calldata _sendParam,
        bool /*_payInLzToken*/
    ) external view returns (MessagingFee memory msgFee) {
        (bytes memory message, ) = OFTMsgCodec.encode(
            _sendParam.to,
            uint64(_removeDust(_sendParam.amountLD) / DECIMAL_CONVERSION_RATE),
            _sendParam.composeMsg
        );

        msgFee = endpoint.quote(
            MessagingParams({
                dstEid: _sendParam.dstEid,
                receiver: peers[_sendParam.dstEid],
                message: message,
                options: _sendParam.extraOptions,
                payInLzToken: false
            }),
            address(this)
        );
    }

    /// @notice Send tokens cross-chain
    /// @dev For Tempo, msg.value must be 0 - gas is paid via ERC20
    function send(
        SendParam calldata _sendParam,
        MessagingFee calldata _fee,
        address _refundAddress
    ) external payable returns (MessagingReceipt memory msgReceipt, OFTReceipt memory oftReceipt) {
        // Tempo uses ERC20 for gas, not native
        require(msg.value == 0, "msg.value must be 0");

        uint256 amountSentLD = _removeDust(_sendParam.amountLD);
        uint256 amountReceivedLD = amountSentLD;

        // Burn tokens
        _burn(msg.sender, amountSentLD);

        // Build message
        (bytes memory message, ) = OFTMsgCodec.encode(
            _sendParam.to,
            uint64(amountReceivedLD / DECIMAL_CONVERSION_RATE),
            _sendParam.composeMsg
        );

        // Pay native fee with ERC20 (transfer to endpoint)
        address nativeToken_ = _getNativeToken();
        if (_fee.nativeFee > 0 && nativeToken_ != address(0)) {
            IERC20(nativeToken_).transferFrom(msg.sender, address(endpoint), _fee.nativeFee);
        }

        // Send via endpoint
        msgReceipt = endpoint.send{ value: 0 }(
            MessagingParams({
                dstEid: _sendParam.dstEid,
                receiver: peers[_sendParam.dstEid],
                message: message,
                options: _sendParam.extraOptions,
                payInLzToken: false
            }),
            _refundAddress
        );

        oftReceipt = OFTReceipt({ amountSentLD: amountSentLD, amountReceivedLD: amountReceivedLD });

        emit OFTSent(msgReceipt.guid, _sendParam.dstEid, msg.sender, amountSentLD, amountReceivedLD);
    }

    /// @notice Receive tokens from another chain
    function lzReceive(
        Origin calldata _origin,
        bytes32 _guid,
        bytes calldata _message,
        address,
        /*_executor*/
        bytes calldata /*_extraData*/
    ) external payable {
        require(msg.sender == address(endpoint), "!endpoint");
        require(peers[_origin.srcEid] == _origin.sender, "!peer");

        address toAddress = _message.sendTo().bytes32ToAddress();
        uint256 amountReceivedLD = _message.amountSD() * DECIMAL_CONVERSION_RATE;

        _mint(toAddress, amountReceivedLD);

        emit OFTReceived(_guid, _origin.srcEid, toAddress, amountReceivedLD);
    }

    function allowInitializePath(Origin calldata) external pure returns (bool) {
        return true;
    }

    function nextNonce(uint32, bytes32) external pure returns (uint64) {
        return 0;
    }

    function _removeDust(uint256 _amountLD) internal pure returns (uint256) {
        return (_amountLD / DECIMAL_CONVERSION_RATE) * DECIMAL_CONVERSION_RATE;
    }

    function _getNativeToken() internal view returns (address) {
        // Try to get native token from alt endpoint, fallback to address(0)
        try IEndpointV2Alt(address(endpoint)).nativeToken() returns (address nativeToken_) {
            return nativeToken_;
        } catch {
            return address(0);
        }
    }
}

/// @dev Interface for EndpointV2Alt's nativeToken getter
interface IEndpointV2Alt {
    function nativeToken() external view returns (address);
}
