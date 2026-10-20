pragma solidity ^0.8.0;

import { AggregatorV3Interface } from "src/contracts/interfaces/AggregatorV3Interface.sol";
import { IERC3009 } from "src/contracts/interfaces/IERC3009.sol";
import { IHopV2 } from "src/contracts/interfaces/IHopV2.sol";
import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";

struct Tx {
    address oft;
    address from;
    bytes32 recipient;
    uint256 value;
    uint256 minAmountLD;
    uint256 validAfter;
    uint256 validBefore;
    bytes32 salt;
    uint32 srcEid;
    uint32 dstEid;
    uint128 dstGas;
    bytes data;
}

interface IOFT {
    function token() external view returns (address);
}

contract GaslessSend is Ownable {
    IERC3009 public immutable frxUsd;
    IHopV2 public immutable hopV2;
    AggregatorV3Interface public gasPriceOracle;

    error UnsupportedBridgeToken();
    error InsufficientAmountAfterFees();
    error RefundFailed();

    constructor(address _frxUsdOft, address _gasPriceOracle, address _hopV2) Ownable(msg.sender) {
        frxUsd = IERC3009(IOFT(_frxUsdOft).token());
        hopV2 = IHopV2(_hopV2);
        gasPriceOracle = AggregatorV3Interface(_gasPriceOracle);
    }

    function quoteInFrxUsd(
        address _oft,
        uint32 _dstEid,
        bytes32 _recipient,
        uint256 _amountLD,
        uint128 _dstGas,
        bytes memory _data
    ) public view returns (uint256 feeInFrxUsd) {
        uint256 fee = hopV2.quote(_oft, _dstEid, _recipient, _amountLD, _dstGas, _data);

        // Zero fee means the send is local and remains on this chain
        if (fee == 0) return 0;

        (, int256 answer, , , ) = gasPriceOracle.latestRoundData();
        uint8 decimals = gasPriceOracle.decimals();
        feeInFrxUsd = (fee * uint256(answer)) / (10 ** decimals);

        return feeInFrxUsd;
    }

    function gaslessSend(Tx calldata _tx, uint8 v, bytes32 r, bytes32 s) external payable {
        // transfer the OFT underlying token from the user to this contract
        address underlying = IOFT(_tx.oft).token();
        bytes32 nonce = keccak256(abi.encode(_tx));
        IERC3009(underlying).receiveWithAuthorization(
            _tx.from,
            address(this),
            _tx.value,
            _tx.validAfter,
            _tx.validBefore,
            nonce,
            v,
            r,
            s
        );

        // calculate fee in frxUSD
        uint256 feeInFrxUsd = quoteInFrxUsd(_tx.oft, _tx.dstEid, _tx.recipient, _tx.value, _tx.dstGas, _tx.data);

        // if there is a fee, revert if the underlying is not frxUSD as only frxUSD can be used
        // to pay gas fees for crosschain sends
        if (feeInFrxUsd > 0 && underlying != address(frxUsd)) revert UnsupportedBridgeToken();

        // clean up and validate the amount sent after fees meets the signers requirement
        uint256 amountLD = hopV2.removeDust(_tx.oft, _tx.value - feeInFrxUsd);
        if (amountLD < _tx.minAmountLD) revert InsufficientAmountAfterFees();

        // approve HopV2 to transfer the OFT underlying token
        IERC3009(underlying).approve(address(hopV2), amountLD);

        // send the OFT to destination
        hopV2.sendOFT{ value: msg.value }(_tx.oft, _tx.dstEid, _tx.recipient, amountLD, _tx.dstGas, _tx.data);

        // refund any leftover frxUSD to the user
        if (underlying == address(frxUsd)) {
            uint256 frxUsdBalance = frxUsd.balanceOf(address(this));
            if (frxUsdBalance > 0) {
                frxUsd.transfer(msg.sender, frxUsdBalance);
            }
        }

        // refund leftover gas to the user
        uint256 gasLeftover = address(this).balance;
        if (gasLeftover > 0) {
            (bool success, ) = payable(msg.sender).call{ value: gasLeftover }("");
            if (!success) revert RefundFailed();
        }
    }

    // allow owner to update gas price oracle
    function setGasPriceOracle(address _newGasPriceOracle) external onlyOwner {
        gasPriceOracle = AggregatorV3Interface(_newGasPriceOracle);
    }
}
