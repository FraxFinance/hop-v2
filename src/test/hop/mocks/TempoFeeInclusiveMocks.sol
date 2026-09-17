// SPDX-License-Identifier: UNLICENSED
pragma solidity >=0.8.23;

import { IOFT } from "@fraxfinance/layerzero-v2-upgradeable/oapp/contracts/oft/interfaces/IOFT.sol";
import { ITIP20 } from "@tempo/interfaces/ITIP20.sol";
import { StdPrecompiles } from "tempo-std/StdPrecompiles.sol";
import { StdTokens } from "tempo-std/StdTokens.sol";
import { IOFT2 } from "src/contracts/interfaces/IOFT2.sol";

/// @notice Test doubles for `TempoFeeInclusiveWrapper`.
/// @dev Shared by the fork-free unit suite (which etches `TipFeeManagerMock` at the
///      precompile address) and the mainnet-fork suite (which only needs
///      `SetUserTokenCaller`). The bridged token is the plain `MockERC20`.

/// @notice OFT (adapter) stand-in exposing only what the wrapper and hop read.
contract OFTMock {
    address public immutable token;
    uint256 public immutable decimalConversionRate;

    constructor(address _token, uint256 _decimalConversionRate) {
        token = _token;
        decimalConversionRate = _decimalConversionRate;
    }
}

/// @notice `RemoteHopV201Tempo` stand-in.
/// @dev Mirrors the deployed hop's fund flow for a spoke send: check pause and the
///      OFT allow-list, dust-clean the amount, `transferFrom` the bridged amount off
///      `msg.sender`, then collect the LayerZero fee off that same `msg.sender` in
///      the token `TIP_FEE_MANAGER.userTokens` resolves to (falling back to
///      PATH_USD, as `_resolveUserToken` does).
contract RemoteHopFeeInclusiveMock {
    error HopSendReverted();

    event SendOFT(address indexed oft, address indexed sender, uint32 dstEid, bytes32 recipient, uint256 amountLD);

    uint256 public feeAmount;
    bool public revertOnSend;
    bool public paused;
    mapping(address oft => bool isApproved) public approvedOft;
    /// @dev When set, the fee actually pulled on send differs from the quoted one —
    ///      the only way to observe that the wrapper reports what was taken, not
    ///      what was quoted, and that an over-collection cannot slip through.
    bool public overrideCollectedFee;
    uint256 public collectedFee;

    uint256 public sendCount;
    address public lastOft;
    uint32 public lastDstEid;
    bytes32 public lastRecipient;
    uint256 public lastAmountLD;
    uint128 public lastDstGas;
    address public lastFeeTokenPulled;
    bytes public lastData;

    function setFeeAmount(uint256 _feeAmount) external {
        feeAmount = _feeAmount;
    }

    function setRevertOnSend(bool _value) external {
        revertOnSend = _value;
    }

    function setPaused(bool _value) external {
        paused = _value;
    }

    function setCollectedFee(uint256 _fee) external {
        overrideCollectedFee = true;
        collectedFee = _fee;
    }

    function setApprovedOft(address _oft, bool _isApproved) external {
        approvedOft[_oft] = _isApproved;
    }

    /// @dev The LayerZero fee does not vary with the bridged amount, so the mock
    ///      returns the configured fee regardless of the quoted amount — matching
    ///      the assumption the wrapper documents when it quotes on the gross budget.
    function quoteStatic(
        address,
        uint32,
        bytes32,
        uint256,
        uint128,
        bytes memory,
        address
    ) external view returns (uint256) {
        return feeAmount;
    }

    function removeDust(address _oft, uint256 _amountLD) public view returns (uint256) {
        uint256 rate = IOFT2(_oft).decimalConversionRate();
        return (_amountLD / rate) * rate;
    }

    function sendOFT(
        address _oft,
        uint32 _dstEid,
        bytes32 _recipient,
        uint256 _amountLD,
        uint128 _dstGas,
        bytes memory _data
    ) external payable {
        if (revertOnSend) revert HopSendReverted();

        uint256 amount = removeDust(_oft, _amountLD);
        address oftToken = IOFT(_oft).token();
        if (amount > 0) ITIP20(oftToken).transferFrom(msg.sender, address(this), amount);

        uint256 fee = overrideCollectedFee ? collectedFee : feeAmount;
        address feeToken;
        if (fee > 0) {
            feeToken = StdPrecompiles.TIP_FEE_MANAGER.userTokens(msg.sender);
            if (feeToken == address(0)) feeToken = StdTokens.PATH_USD_ADDRESS;
            ITIP20(feeToken).transferFrom(msg.sender, address(this), fee);
        }

        sendCount += 1;
        lastOft = _oft;
        lastDstEid = _dstEid;
        lastRecipient = _recipient;
        lastAmountLD = amount;
        lastDstGas = _dstGas;
        lastFeeTokenPulled = feeToken;
        lastData = _data;

        emit SendOFT(_oft, msg.sender, _dstEid, _recipient, amount);
    }
}

/// @notice `TIP_FEE_MANAGER` precompile stand-in, etched at the precompile address.
/// @dev Counts `setUserToken` calls per account so the wrapper's "only write when it
///      would change" branch can be asserted. `rejectedToken` mirrors the real
///      precompile refusing a token that is not a factory-deployed USD TIP20.
contract TipFeeManagerMock {
    error InvalidToken();

    event UserTokenSet(address indexed user, address indexed token);

    mapping(address user => address token) public userTokens;
    mapping(address user => uint256 count) public setUserTokenCalls;
    address public rejectedToken;

    function setRejectedToken(address _token) external {
        rejectedToken = _token;
    }

    function setUserToken(address _token) external {
        if (_token == rejectedToken) revert InvalidToken();
        userTokens[msg.sender] = _token;
        setUserTokenCalls[msg.sender] += 1;
        emit UserTokenSet(msg.sender, _token);
    }
}

/// @dev Stand-in for "any contract" calling the fee manager: `msg.sender` is this
///      contract, `tx.origin` is whoever sent the transaction — the wrapper's frame.
contract SetUserTokenCaller {
    function set(address _token) external {
        StdPrecompiles.TIP_FEE_MANAGER.setUserToken(_token);
    }
}
