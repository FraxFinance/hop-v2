// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

import { Test } from "forge-std/Test.sol";
import { StdPrecompiles } from "tempo-std/StdPrecompiles.sol";
import { StdTokens } from "tempo-std/StdTokens.sol";
import { TempoFeeInclusiveWrapper } from "src/contracts/hop/TempoFeeInclusiveWrapper.sol";

// ====================================================================
// |                          Test doubles                            |
// ====================================================================

/// @dev Minimal view of the OFT surface the wrapper and the hop touch.
interface IOftView {
    function token() external view returns (address);

    function decimalConversionRate() external view returns (uint256);
}

/// @dev Minimal TIP20 surface used by the hop mock.
interface ITIP20Minimal {
    function transfer(address to, uint256 amount) external returns (bool);

    function transferFrom(address from, address to, uint256 amount) external returns (bool);
}

/// @dev Minimal fee-manager surface used by the hop mock.
interface IFeeManagerMinimal {
    function userTokens(address user) external view returns (address);
}

/// @notice Bool-returning TIP20 stand-in.
/// @dev TIP20 reverts on insufficient allowance/balance (it does not return `false`),
///      so the mock mirrors that. The `*ReturnsFalse` switches exist purely to drive
///      the wrapper's explicit `if (!...) revert` branches, which a reverting token
///      can never reach.
contract TIP20Mock {
    error InsufficientAllowance(address owner, address spender, uint256 requested, uint256 available);
    error InsufficientBalance(address account, uint256 requested, uint256 available);

    event Transfer(address indexed from, address indexed to, uint256 amount);
    event Approval(address indexed owner, address indexed spender, uint256 amount);

    string public name;
    string public symbol;
    uint8 public constant decimals = 18;
    uint256 public totalSupply;

    mapping(address account => uint256 amount) public balanceOf;
    mapping(address owner => mapping(address spender => uint256 amount)) public allowance;

    bool public transferReturnsFalse;
    bool public transferFromReturnsFalse;
    bool public approveReturnsFalse;

    constructor(string memory _name, string memory _symbol) {
        name = _name;
        symbol = _symbol;
    }

    function setTransferReturnsFalse(bool _value) external {
        transferReturnsFalse = _value;
    }

    function setTransferFromReturnsFalse(bool _value) external {
        transferFromReturnsFalse = _value;
    }

    function setApproveReturnsFalse(bool _value) external {
        approveReturnsFalse = _value;
    }

    function mint(address _to, uint256 _amount) external {
        balanceOf[_to] += _amount;
        totalSupply += _amount;
        emit Transfer(address(0), _to, _amount);
    }

    function approve(address _spender, uint256 _amount) external returns (bool) {
        if (approveReturnsFalse) return false;
        allowance[msg.sender][_spender] = _amount;
        emit Approval(msg.sender, _spender, _amount);
        return true;
    }

    function transfer(address _to, uint256 _amount) external returns (bool) {
        if (transferReturnsFalse) return false;
        _transfer(msg.sender, _to, _amount);
        return true;
    }

    function transferFrom(address _from, address _to, uint256 _amount) external returns (bool) {
        if (transferFromReturnsFalse) return false;
        uint256 allowed = allowance[_from][msg.sender];
        if (allowed < _amount) revert InsufficientAllowance(_from, msg.sender, _amount, allowed);
        if (allowed != type(uint256).max) allowance[_from][msg.sender] = allowed - _amount;
        _transfer(_from, _to, _amount);
        return true;
    }

    function _transfer(address _from, address _to, uint256 _amount) internal {
        uint256 balance = balanceOf[_from];
        if (balance < _amount) revert InsufficientBalance(_from, _amount, balance);
        unchecked {
            balanceOf[_from] = balance - _amount;
        }
        balanceOf[_to] += _amount;
        emit Transfer(_from, _to, _amount);
    }
}

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
/// @dev Mirrors the deployed hop's fund flow for a spoke send: dust-clean the amount,
///      `transferFrom` the bridged amount off `msg.sender`, then collect the LayerZero
///      fee off that same `msg.sender` in the token `TIP_FEE_MANAGER.userTokens`
///      resolves to (falling back to PATH_USD, as `_resolveUserToken` does).
contract RemoteHopFeeInclusiveMock {
    error HopSendReverted();

    event SendOFT(address indexed oft, address indexed sender, uint32 dstEid, bytes32 recipient, uint256 amountLD);

    uint256 public feeAmount;
    bool public revertOnSend;

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
        uint256 rate = IOftView(_oft).decimalConversionRate();
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
        address oftToken = IOftView(_oft).token();
        if (amount > 0) ITIP20Minimal(oftToken).transferFrom(msg.sender, address(this), amount);

        uint256 fee = feeAmount;
        address feeToken;
        if (fee > 0) {
            feeToken = IFeeManagerMinimal(StdPrecompiles.TIP_FEE_MANAGER_ADDRESS).userTokens(msg.sender);
            if (feeToken == address(0)) feeToken = StdTokens.PATH_USD_ADDRESS;
            ITIP20Minimal(feeToken).transferFrom(msg.sender, address(this), fee);
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
///      would change" branch can be asserted.
contract TipFeeManagerMock {
    event UserTokenSet(address indexed user, address indexed token);

    mapping(address user => address token) public userTokens;
    mapping(address user => uint256 count) public setUserTokenCalls;

    function setUserToken(address _token) external {
        userTokens[msg.sender] = _token;
        setUserTokenCalls[msg.sender] += 1;
        emit UserTokenSet(msg.sender, _token);
    }
}

// ====================================================================
// |                              Tests                               |
// ====================================================================

/// @title TempoFeeInclusiveWrapperTest
/// @notice Self-contained unit coverage for `TempoFeeInclusiveWrapper`.
/// @dev Deliberately fork-free: the Tempo precompile the wrapper touches
///      (`TIP_FEE_MANAGER`) is etched, so this file runs in CI alongside the
///      non-fork suite rather than in the RPC-gated Tempo set.
contract TempoFeeInclusiveWrapperTest is Test {
    /// @dev Mirrors `TempoFeeInclusiveWrapper.SendOFTFeeInclusive` for `expectEmit`.
    event SendOFTFeeInclusive(
        address indexed oft,
        address indexed sender,
        uint32 dstEid,
        bytes32 recipient,
        address feeToken,
        uint256 netAmount,
        uint256 feeAmount,
        uint256 maxAmountIn
    );

    uint32 internal constant DST_EID = 30_255;
    uint128 internal constant DST_GAS = 400_000;

    uint256 internal constant GROSS = 100e18;
    uint256 internal constant FEE = 2e18;
    uint256 internal constant NET = GROSS - FEE;

    /// @dev 18 local decimals against 6 shared decimals — the frxUSD OFT's granularity.
    uint256 internal constant DUST_RATE = 1e12;

    TIP20Mock internal frxUsd;
    OFTMock internal oft;
    OFTMock internal dustOft;
    RemoteHopFeeInclusiveMock internal hop;
    TempoFeeInclusiveWrapper internal wrapper;
    TipFeeManagerMock internal feeManager;

    address internal alice;
    bytes32 internal recipient;

    function setUp() public {
        alice = makeAddr("alice");
        recipient = bytes32(uint256(uint160(alice)));

        frxUsd = new TIP20Mock("Frax USD", "frxUSD");
        oft = new OFTMock(address(frxUsd), 1);
        dustOft = new OFTMock(address(frxUsd), DUST_RATE);
        hop = new RemoteHopFeeInclusiveMock();
        wrapper = new TempoFeeInclusiveWrapper(address(hop));

        // Stand the Tempo fee-manager precompile up in-memory so no fork is needed.
        vm.etch(StdPrecompiles.TIP_FEE_MANAGER_ADDRESS, address(new TipFeeManagerMock()).code);
        feeManager = TipFeeManagerMock(StdPrecompiles.TIP_FEE_MANAGER_ADDRESS);

        hop.setFeeAmount(FEE);
        frxUsd.mint(alice, 1000e18);
    }

    // ---------------------------------------------------
    // a. Happy path
    // ---------------------------------------------------

    function test_SendOFTFeeInclusive_HappyPath() public {
        uint256 aliceBefore = frxUsd.balanceOf(alice);

        vm.prank(alice);
        frxUsd.approve(address(wrapper), GROSS);

        vm.expectEmit(true, true, false, true, address(wrapper));
        emit SendOFTFeeInclusive(address(oft), alice, DST_EID, recipient, address(frxUsd), NET, FEE, GROSS);

        vm.prank(alice);
        wrapper.sendOFTFeeInclusive(address(oft), DST_EID, recipient, GROSS, 0, DST_GAS, "");

        assertEq(hop.sendCount(), 1, "hop was called once");
        assertEq(hop.lastAmountLD(), NET, "hop bridged gross - fee");
        assertEq(hop.lastOft(), address(oft), "oft forwarded");
        assertEq(hop.lastDstEid(), DST_EID, "dstEid forwarded");
        assertEq(hop.lastRecipient(), recipient, "recipient forwarded");
        assertEq(hop.lastDstGas(), DST_GAS, "dstGas forwarded");
        assertEq(hop.lastFeeTokenPulled(), address(frxUsd), "fee pulled in the bridged token");

        assertEq(frxUsd.balanceOf(address(hop)), NET + FEE, "hop received net + fee");
        assertEq(aliceBefore - frxUsd.balanceOf(alice), GROSS, "caller paid exactly gross");
        assertEq(frxUsd.balanceOf(address(wrapper)), 0, "wrapper retains nothing");
    }

    // ---------------------------------------------------
    // b. A single approval of exactly `fromAmount` suffices
    // ---------------------------------------------------

    function test_SendOFTFeeInclusive_SingleApprovalOfGrossIsSufficient() public {
        vm.startPrank(alice);

        frxUsd.approve(address(wrapper), GROSS - 1);
        vm.expectRevert(
            abi.encodeWithSelector(TIP20Mock.InsufficientAllowance.selector, alice, address(wrapper), GROSS, GROSS - 1)
        );
        wrapper.sendOFTFeeInclusive(address(oft), DST_EID, recipient, GROSS, 0, DST_GAS, "");

        frxUsd.approve(address(wrapper), GROSS);
        wrapper.sendOFTFeeInclusive(address(oft), DST_EID, recipient, GROSS, 0, DST_GAS, "");

        vm.stopPrank();

        assertEq(hop.sendCount(), 1, "only the fully approved call went through");
        assertEq(frxUsd.allowance(alice, address(wrapper)), 0, "the single approval was fully consumed");
        assertEq(frxUsd.balanceOf(address(hop)), NET + FEE, "hop received net + fee off one approval");
    }

    // ---------------------------------------------------
    // c. msg.value must be zero
    // ---------------------------------------------------

    function test_SendOFTFeeInclusive_RevertsWhenMsgValueNotZero() public {
        vm.deal(alice, 1 ether);

        vm.startPrank(alice);
        frxUsd.approve(address(wrapper), GROSS);
        vm.expectRevert(abi.encodeWithSelector(TempoFeeInclusiveWrapper.MsgValueNotZero.selector, 1 wei));
        wrapper.sendOFTFeeInclusive{ value: 1 wei }(address(oft), DST_EID, recipient, GROSS, 0, DST_GAS, "");
        vm.stopPrank();

        assertEq(hop.sendCount(), 0, "nothing was sent");
    }

    // ---------------------------------------------------
    // d. Zero gross budget
    // ---------------------------------------------------

    function test_SendOFTFeeInclusive_RevertsOnZeroAmount() public {
        vm.startPrank(alice);
        frxUsd.approve(address(wrapper), GROSS);
        vm.expectRevert(TempoFeeInclusiveWrapper.ZeroAmount.selector);
        wrapper.sendOFTFeeInclusive(address(oft), DST_EID, recipient, 0, 0, DST_GAS, "");
        vm.stopPrank();

        assertEq(hop.sendCount(), 0, "nothing was sent");
    }

    // ---------------------------------------------------
    // e. Fee swallows the whole budget
    // ---------------------------------------------------

    function test_SendOFTFeeInclusive_RevertsWhenFeeExceedsInput() public {
        uint256 aliceBefore = frxUsd.balanceOf(alice);

        vm.prank(alice);
        frxUsd.approve(address(wrapper), GROSS);

        // fee > gross
        hop.setFeeAmount(GROSS + 1);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(TempoFeeInclusiveWrapper.FeeExceedsInput.selector, GROSS + 1, GROSS));
        wrapper.sendOFTFeeInclusive(address(oft), DST_EID, recipient, GROSS, 0, DST_GAS, "");

        // fee == gross (the boundary is inclusive: nothing would be left to bridge)
        hop.setFeeAmount(GROSS);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(TempoFeeInclusiveWrapper.FeeExceedsInput.selector, GROSS, GROSS));
        wrapper.sendOFTFeeInclusive(address(oft), DST_EID, recipient, GROSS, 0, DST_GAS, "");

        assertEq(hop.sendCount(), 0, "nothing was sent");
        assertEq(frxUsd.balanceOf(alice), aliceBefore, "the fee is never pulled when it exceeds the budget");
    }

    // ---------------------------------------------------
    // f. minNet floor
    // ---------------------------------------------------

    function test_SendOFTFeeInclusive_RevertsWhenFeeRisesBelowMinNet() public {
        // The integrator quotes at the current fee and passes the resulting net as its floor.
        (, , uint256 quotedNet) = wrapper.quoteFeeInclusive(address(oft), DST_EID, recipient, GROSS, DST_GAS, "");
        assertEq(quotedNet, NET, "quote matches the current fee");

        // The fee moves between quote and execution.
        hop.setFeeAmount(FEE * 2);
        uint256 aliceBefore = frxUsd.balanceOf(alice);

        vm.startPrank(alice);
        frxUsd.approve(address(wrapper), GROSS);
        vm.expectRevert(
            abi.encodeWithSelector(TempoFeeInclusiveWrapper.InsufficientNetAmount.selector, GROSS - FEE * 2, quotedNet)
        );
        wrapper.sendOFTFeeInclusive(address(oft), DST_EID, recipient, GROSS, quotedNet, DST_GAS, "");
        vm.stopPrank();

        assertEq(hop.sendCount(), 0, "nothing was sent");
        assertEq(frxUsd.balanceOf(alice), aliceBefore, "no funds moved");
    }

    function test_SendOFTFeeInclusive_SucceedsWhenNetEqualsMinNet() public {
        vm.startPrank(alice);
        frxUsd.approve(address(wrapper), GROSS);
        wrapper.sendOFTFeeInclusive(address(oft), DST_EID, recipient, GROSS, NET, DST_GAS, "");
        vm.stopPrank();

        assertEq(hop.sendCount(), 1, "net == minNet is accepted");
        assertEq(hop.lastAmountLD(), NET, "the floor amount is exactly what bridged");
    }

    // ---------------------------------------------------
    // g. Sub-dust remainder is refunded
    // ---------------------------------------------------

    function test_SendOFTFeeInclusive_RefundsSubDustRemainder() public {
        uint256 fee = 1e18 + 123;
        hop.setFeeAmount(fee);

        uint256 expectedNet = ((GROSS - fee) / DUST_RATE) * DUST_RATE;
        uint256 expectedRefund = (GROSS - fee) - expectedNet;
        assertGt(expectedRefund, 0, "the fixture must actually leave dust");

        uint256 aliceBefore = frxUsd.balanceOf(alice);

        vm.prank(alice);
        frxUsd.approve(address(wrapper), GROSS);

        vm.expectEmit(true, true, false, true, address(wrapper));
        emit SendOFTFeeInclusive(address(dustOft), alice, DST_EID, recipient, address(frxUsd), expectedNet, fee, GROSS);

        vm.prank(alice);
        wrapper.sendOFTFeeInclusive(address(dustOft), DST_EID, recipient, GROSS, 0, DST_GAS, "");

        assertEq(hop.lastAmountLD(), expectedNet, "the floored amount is what bridged");
        assertEq(frxUsd.balanceOf(address(hop)), expectedNet + fee, "hop received floored net + fee");
        assertEq(frxUsd.balanceOf(alice), aliceBefore - expectedNet - fee, "the dust came back to the caller");
        assertEq(aliceBefore - frxUsd.balanceOf(alice), GROSS - expectedRefund, "net spend excludes the refund");
        assertEq(frxUsd.balanceOf(address(wrapper)), 0, "no dust stranded in the wrapper");
    }

    // ---------------------------------------------------
    // h. Remainder that floors to zero is rejected, fee unpaid
    // ---------------------------------------------------

    function test_SendOFTFeeInclusive_RevertsWhenNetFloorsToZero() public {
        uint256 fee = 1e18;
        uint256 gross = fee + 500; // 500 wei survives the fee but is below one dust unit
        hop.setFeeAmount(fee);

        uint256 aliceBefore = frxUsd.balanceOf(alice);

        vm.startPrank(alice);
        frxUsd.approve(address(wrapper), gross);
        vm.expectRevert(TempoFeeInclusiveWrapper.NetAmountZero.selector);
        wrapper.sendOFTFeeInclusive(address(dustOft), DST_EID, recipient, gross, 0, DST_GAS, "");
        vm.stopPrank();

        assertEq(hop.sendCount(), 0, "nothing was sent");
        assertEq(frxUsd.balanceOf(alice), aliceBefore, "the fee is not charged for a zero-value bridge");
        assertEq(frxUsd.balanceOf(address(hop)), 0, "the hop collected nothing");
    }

    // ---------------------------------------------------
    // i. Allowance hygiene
    // ---------------------------------------------------

    function test_SendOFTFeeInclusive_LeavesNoAllowanceToTheHop() public {
        vm.startPrank(alice);
        frxUsd.approve(address(wrapper), GROSS);
        wrapper.sendOFTFeeInclusive(address(oft), DST_EID, recipient, GROSS, 0, DST_GAS, "");
        vm.stopPrank();

        assertEq(frxUsd.allowance(address(wrapper), address(hop)), 0, "wrapper -> hop allowance is cleared");

        // And again on a path that leaves an unspent remainder of the approval.
        hop.setFeeAmount(1e18 + 123);
        vm.startPrank(alice);
        frxUsd.approve(address(wrapper), GROSS);
        wrapper.sendOFTFeeInclusive(address(dustOft), DST_EID, recipient, GROSS, 0, DST_GAS, "");
        vm.stopPrank();

        assertEq(frxUsd.allowance(address(wrapper), address(hop)), 0, "leftover allowance is zeroed too");
    }

    // ---------------------------------------------------
    // j. Fee-manager write is idempotent
    // ---------------------------------------------------

    function test_SendOFTFeeInclusive_SetsUserTokenOnlyWhenItChanges() public {
        assertEq(feeManager.userTokens(address(wrapper)), address(0), "wrapper starts unbound");

        vm.startPrank(alice);
        frxUsd.approve(address(wrapper), GROSS);
        wrapper.sendOFTFeeInclusive(address(oft), DST_EID, recipient, GROSS, 0, DST_GAS, "");
        vm.stopPrank();

        assertEq(feeManager.userTokens(address(wrapper)), address(frxUsd), "wrapper bound to the bridged token");
        assertEq(feeManager.setUserTokenCalls(address(wrapper)), 1, "written once when it differed");

        // Second send with the same fee token must not touch the precompile again.
        vm.startPrank(alice);
        frxUsd.approve(address(wrapper), GROSS);
        wrapper.sendOFTFeeInclusive(address(oft), DST_EID, recipient, GROSS, 0, DST_GAS, "");
        vm.stopPrank();

        assertEq(hop.sendCount(), 2, "the second send still went through");
        assertEq(feeManager.setUserTokenCalls(address(wrapper)), 1, "not rewritten when already set");
    }

    function test_SendOFTFeeInclusive_SetsUserTokenWhenBoundToAnotherToken() public {
        TIP20Mock other = new TIP20Mock("Other", "OTHER");
        vm.prank(address(wrapper));
        feeManager.setUserToken(address(other));
        assertEq(feeManager.setUserTokenCalls(address(wrapper)), 1, "seeded with a different token");

        vm.startPrank(alice);
        frxUsd.approve(address(wrapper), GROSS);
        wrapper.sendOFTFeeInclusive(address(oft), DST_EID, recipient, GROSS, 0, DST_GAS, "");
        vm.stopPrank();

        assertEq(feeManager.setUserTokenCalls(address(wrapper)), 2, "rebound to the bridged token");
        assertEq(feeManager.userTokens(address(wrapper)), address(frxUsd), "bridged token is now the fee token");
    }

    // ---------------------------------------------------
    // k. quoteFeeInclusive agrees with the send path
    // ---------------------------------------------------

    function test_QuoteFeeInclusive_MatchesTheAmountTheSendPathBridges() public {
        uint256 fee = 1e18 + 123;
        hop.setFeeAmount(fee);

        (address feeToken, uint256 feeAmount, uint256 netAmount) = wrapper.quoteFeeInclusive(
            address(dustOft),
            DST_EID,
            recipient,
            GROSS,
            DST_GAS,
            ""
        );

        assertEq(feeToken, address(frxUsd), "fee token is the bridged token");
        assertEq(feeAmount, fee, "fee mirrors the hop quote");
        assertEq(netAmount, ((GROSS - fee) / DUST_RATE) * DUST_RATE, "quote is dust-cleaned");

        vm.startPrank(alice);
        frxUsd.approve(address(wrapper), GROSS);
        wrapper.sendOFTFeeInclusive(address(dustOft), DST_EID, recipient, GROSS, netAmount, DST_GAS, "");
        vm.stopPrank();

        assertEq(hop.lastAmountLD(), netAmount, "the quoted net is exactly what bridged");
    }

    function test_QuoteFeeInclusive_ReturnsZeroNetWhenFeeExceedsInput() public {
        hop.setFeeAmount(GROSS);
        (, uint256 feeAtParity, uint256 netAtParity) = wrapper.quoteFeeInclusive(
            address(oft),
            DST_EID,
            recipient,
            GROSS,
            DST_GAS,
            ""
        );
        assertEq(feeAtParity, GROSS, "fee reported as quoted");
        assertEq(netAtParity, 0, "nothing bridgeable when fee == gross");

        hop.setFeeAmount(GROSS + 1);
        (, , uint256 netAboveParity) = wrapper.quoteFeeInclusive(address(oft), DST_EID, recipient, GROSS, DST_GAS, "");
        assertEq(netAboveParity, 0, "nothing bridgeable when fee > gross");
    }

    // ---------------------------------------------------
    // l. A hop revert unwinds everything
    // ---------------------------------------------------

    function test_SendOFTFeeInclusive_HopRevertRollsBackEverything() public {
        hop.setRevertOnSend(true);
        uint256 aliceBefore = frxUsd.balanceOf(alice);

        vm.startPrank(alice);
        frxUsd.approve(address(wrapper), GROSS);
        vm.expectRevert(RemoteHopFeeInclusiveMock.HopSendReverted.selector);
        wrapper.sendOFTFeeInclusive(address(oft), DST_EID, recipient, GROSS, 0, DST_GAS, "");
        vm.stopPrank();

        assertEq(frxUsd.balanceOf(alice), aliceBefore, "caller was made whole");
        assertEq(frxUsd.balanceOf(address(wrapper)), 0, "no funds stranded in the wrapper");
        assertEq(frxUsd.balanceOf(address(hop)), 0, "the hop kept nothing");
        assertEq(frxUsd.allowance(alice, address(wrapper)), GROSS, "the caller's approval is untouched");
        assertEq(frxUsd.allowance(address(wrapper), address(hop)), 0, "no dangling allowance to the hop");
        assertEq(feeManager.setUserTokenCalls(address(wrapper)), 0, "the precompile write rolled back too");
    }

    // ---------------------------------------------------
    // Bool-returning token failures
    // ---------------------------------------------------

    function test_SendOFTFeeInclusive_RevertsTransferFailedWhenPullReturnsFalse() public {
        frxUsd.setTransferFromReturnsFalse(true);

        vm.startPrank(alice);
        vm.expectRevert(TempoFeeInclusiveWrapper.TransferFailed.selector);
        wrapper.sendOFTFeeInclusive(address(oft), DST_EID, recipient, GROSS, 0, DST_GAS, "");
        vm.stopPrank();

        assertEq(hop.sendCount(), 0, "nothing was sent");
    }

    function test_SendOFTFeeInclusive_RevertsApproveFailedWhenApproveReturnsFalse() public {
        vm.prank(alice);
        frxUsd.approve(address(wrapper), GROSS);

        frxUsd.setApproveReturnsFalse(true);

        vm.prank(alice);
        vm.expectRevert(TempoFeeInclusiveWrapper.ApproveFailed.selector);
        wrapper.sendOFTFeeInclusive(address(oft), DST_EID, recipient, GROSS, 0, DST_GAS, "");

        assertEq(hop.sendCount(), 0, "nothing was sent");
    }

    function test_SendOFTFeeInclusive_RevertsTransferFailedWhenRefundReturnsFalse() public {
        hop.setFeeAmount(1e18 + 123); // leaves a sub-dust refund

        vm.prank(alice);
        frxUsd.approve(address(wrapper), GROSS);

        frxUsd.setTransferReturnsFalse(true);

        vm.prank(alice);
        vm.expectRevert(TempoFeeInclusiveWrapper.TransferFailed.selector);
        wrapper.sendOFTFeeInclusive(address(dustOft), DST_EID, recipient, GROSS, 0, DST_GAS, "");

        assertEq(frxUsd.balanceOf(address(wrapper)), 0, "the failed refund unwound the whole call");
    }

    // ---------------------------------------------------
    // Fund-conservation invariant
    // ---------------------------------------------------

    /// @dev Across arbitrary budgets, fees and OFT granularities, the caller is debited
    ///      exactly `net + fee` (never more than the stated budget), the wrapper keeps
    ///      nothing and leaves no allowance behind.
    function testFuzz_SendOFTFeeInclusive_ConservesCallerFunds(
        uint256 _gross,
        uint256 _fee,
        uint8 _rateExponent
    ) public {
        uint256 rate = 10 ** _bound(uint256(_rateExponent), 0, 12);
        uint256 gross = _bound(_gross, rate * 2, 1000e18);
        // Keeping at least one dust unit above the fee guarantees a non-zero net,
        // which is the region where the send is expected to succeed.
        uint256 fee = _bound(_fee, 0, gross - rate);

        OFTMock fuzzOft = new OFTMock(address(frxUsd), rate);
        hop.setFeeAmount(fee);

        uint256 expectedNet = ((gross - fee) / rate) * rate;
        uint256 aliceBefore = frxUsd.balanceOf(alice);

        vm.startPrank(alice);
        frxUsd.approve(address(wrapper), gross);
        wrapper.sendOFTFeeInclusive(address(fuzzOft), DST_EID, recipient, gross, 0, DST_GAS, "");
        vm.stopPrank();

        uint256 spent = aliceBefore - frxUsd.balanceOf(alice);

        assertGt(expectedNet, 0, "the fuzz region must produce a bridgeable amount");
        assertEq(hop.lastAmountLD(), expectedNet, "bridged the dust-cleaned net");
        assertEq(spent, expectedNet + fee, "caller paid exactly net + fee");
        assertLe(spent, gross, "caller never paid more than the stated budget");
        assertEq(frxUsd.balanceOf(address(wrapper)), 0, "wrapper never retains funds");
        assertEq(frxUsd.allowance(address(wrapper), address(hop)), 0, "wrapper leaves no allowance behind");
    }
}
