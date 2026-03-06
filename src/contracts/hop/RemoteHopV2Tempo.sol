// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import { SendParam, MessagingFee, IOFT } from "@fraxfinance/layerzero-v2-upgradeable/oapp/contracts/oft/interfaces/IOFT.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { RemoteHopV2 } from "src/contracts/hop/RemoteHopV2.sol";
import { HopMessage } from "src/contracts/hop/HopV2.sol";
import { TempoAltTokenBase } from "src/contracts/base/TempoAltTokenBase.sol";

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
    /// @dev Overrides base to use ERC20 gas payment instead of msg.value
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

        HopV2Storage storage $ = _getHopV2StorageTempo();
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

        if (_dstEid == $.localEid) {
            // Sending from src => src - no LZ send needed
            _sendLocal({ _oft: _oft, _amount: _amountLD, _hopMessage: hopMessage });
        } else {
            // Generate sendParam
            SendParam memory sendParam = _generateSendParam({
                _amountLD: removeDust(_oft, _amountLD),
                _hopMessage: hopMessage
            });

            MessagingFee memory fee = IOFT(_oft).quoteSend(sendParam, false);

            // Pay for LZ gas using ERC20 via TempoAltTokenBase
            _payNativeAltToken(fee.nativeFee, $.endpoint);

            // Send the OFT to the recipient
            if (_amountLD > 0) SafeERC20.forceApprove(IERC20(IOFT(_oft).token()), _oft, _amountLD);
            IOFT(_oft).send{ value: 0 }(sendParam, fee, address(this));
        }

        emit SendOFT(_oft, msg.sender, _dstEid, _recipient, _amountLD);
    }

    /// @dev Access HopV2 namespaced storage (parent's accessor is private)
    function _getHopV2StorageTempo() private pure returns (HopV2Storage storage $) {
        bytes32 slot = 0x6f2b5e4a4e4e1ee6e84aeabd150e6bcb39c4b05494d47809c3cd3d998f859100;
        assembly {
            $.slot := slot
        }
    }
}
