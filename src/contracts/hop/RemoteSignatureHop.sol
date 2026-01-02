// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import { HopMessage } from "src/contracts/interfaces/IHopV2.sol";

import { RemoteHopV2 } from "src/contracts/hop/RemoteHopV2.sol";
import { AggregatorV3Interface } from "src/contracts/interfaces/AggregatorV3Interface.sol";
import { IERC20Metadata } from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { IERC3009 } from "src/contracts/interfaces/IERC3009.sol";
import { IOFT } from "@fraxfinance/layerzero-v2-upgradeable/oapp/contracts/oft/interfaces/IOFT.sol";

// ====================================================================
// |     ______                   _______                             |
// |    / _____________ __  __   / ____(_____  ____ _____  ________   |
// |   / /_  / ___/ __ `| |/_/  / /_  / / __ \/ __ `/ __ \/ ___/ _ \  |
// |  / __/ / /  / /_/ _>  <   / __/ / / / / / /_/ / / / / /__/  __/  |
// | /_/   /_/   \__,_/_/|_|  /_/   /_/_/ /_/\__,_/_/ /_/\___/\___/   |
// |                                                                  |
// ====================================================================
// ====================== RemoteSignatureHop ==========================
// ====================================================================

struct Authorization {
    address from;
    uint256 validAfter;
    uint256 validBefore;
    bytes32 nonce;
    uint8 v;
    bytes32 r;
    bytes32 s;
}

/// @author Frax Finance: https://github.com/FraxFinance
contract RemoteSignatureHop is RemoteHopV2 {
    struct RemoteSignatureHopStorage {
        /// @notice Chainlink ETH/USD price feed oracle
        AggregatorV3Interface chainlinkEthOracle;
    }

    // keccak256(abi.encode(uint256(keccak256("frax.storage.RemoteSignatureHop")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant RemoteSignatureHopStorageLocation =
        0x198a27b6fba199c47102057070302afae6b0c068f272844477f66692f665b200;

    function _getRemoteSignatureHopStorage() private pure returns (RemoteSignatureHopStorage storage $) {
        assembly {
            $.slot := RemoteSignatureHopStorageLocation
        }
    }

    constructor() {
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
        address[] memory _approvedOfts,
        address chainlinkEthOracle
    ) external initializer {
        __init_RemoteHopV2({
            _localEid: _localEid,
            _endpoint: _endpoint,
            _fraxtalHop: _fraxtalHop,
            _numDVNs: _numDVNs,
            _EXECUTOR: _EXECUTOR,
            _DVN: _DVN,
            _TREASURY: _TREASURY,
            _approvedOfts: _approvedOfts
        });

        RemoteSignatureHopStorage storage $ = _getRemoteSignatureHopStorage();
        $.chainlinkEthOracle = AggregatorV3Interface(chainlinkEthOracle);
    }

    function sendFrxUsdWithAuthorization(
        Authorization memory _authorization,
        address _oft,
        uint32 _dstEid,
        bytes32 _recipient,
        uint256 _amountLD
    ) external {
        sendFrxUsdWithAuthorization({
            _authorization: _authorization,
            _oft: _oft,
            _dstEid: _dstEid,
            _recipient: _recipient,
            _amountLD: _amountLD,
            _dstGas: 0,
            _data: ""
        });
    }

    function sendFrxUsdWithAuthorization(
        Authorization memory _authorization,
        address _oft,
        uint32 _dstEid,
        bytes32 _recipient,
        uint256 _amountLD,
        uint128 _dstGas,
        bytes memory _data
    ) public {
        if (paused()) revert HopPaused();
        if (!approvedOft(_oft)) revert InvalidOFT();
        if (keccak256(abi.encodePacked(IERC20Metadata(_oft).symbol())) != keccak256(abi.encodePacked("frxUSD"))) {
            revert InvalidOFT();
        }

        // generate hop message
        HopMessage memory hopMessage = HopMessage({
            srcEid: localEid(),
            dstEid: _dstEid,
            dstGas: _dstGas,
            sender: bytes32(uint256(uint160(msg.sender))),
            recipient: _recipient,
            data: _data
        });

        // receive frxUSD with authorization
        address underlying = IOFT(_oft).token();
        _handleReceiveWithAuthorization(underlying, _authorization, _amountLD);

        // calculate fee in frxUSD
        uint256 feeInUsd = quoteInUsd(_oft, _dstEid, _recipient, _amountLD, _dstGas, _data);

        // subtract fee from amount and clean up dust
        _amountLD = removeDust(_oft, _amountLD - feeInUsd);

        // send with amount less fees
        uint256 sendFee;
        if (_dstEid == localEid()) {
            _sendLocal({ _oft: _oft, _amount: _amountLD, _hopMessage: hopMessage });
        } else {
            sendFee = _sendToDestination({
                _oft: _oft,
                _amountLD: _amountLD,
                _isTrustedHopMessage: true,
                _hopMessage: hopMessage
            });
        }

        // validate the msg.value
        _handleMsgValue(sendFee);

        // give the remaining balance of frxUSD back to the caller as the fee
        IERC20(underlying).transfer(msg.sender, IERC20(underlying).balanceOf(address(this)));

        emit SendOFT(_oft, _authorization.from, _dstEid, _recipient, _amountLD);
    }

    /// @dev helper to avoid stack too deep
    function _handleReceiveWithAuthorization(
        address _underlying,
        Authorization memory _authorization,
        uint256 _amountLD
    ) internal {
        IERC3009(_underlying).receiveWithAuthorization(
            _authorization.from,
            address(this),
            _amountLD,
            _authorization.validAfter,
            _authorization.validBefore,
            _authorization.nonce,
            _authorization.v,
            _authorization.r,
            _authorization.s
        );
    }

    function quoteInUsd(
        address _oft,
        uint32 _dstEid,
        bytes32 _recipient,
        uint256 _amountLD,
        uint128 _dstGas,
        bytes memory _data
    ) public view returns (uint256) {
        uint256 feeInEth = quote(_oft, _dstEid, _recipient, _amountLD, _dstGas, _data);

        RemoteSignatureHopStorage storage $ = _getRemoteSignatureHopStorage();
        (, int256 ethPrice, , , ) = $.chainlinkEthOracle.latestRoundData();
        uint8 ethPriceDecimals = $.chainlinkEthOracle.decimals();
        uint256 feeInUsd = (feeInEth * uint256(ethPrice)) / (10 ** ethPriceDecimals);

        return feeInUsd;
    }
}
