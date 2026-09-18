// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

import { Test } from "forge-std/Test.sol";
import { IERC20Errors } from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import { StdPrecompiles } from "tempo-std/StdPrecompiles.sol";
import { TempoFeeInclusiveWrapper } from "src/contracts/hop/TempoFeeInclusiveWrapper.sol";
import { MockERC20 } from "src/test/hop/mocks/MockERC20.sol";
import { OFTMock, RemoteHopFeeInclusiveMock, TipFeeManagerMock } from "src/test/hop/mocks/TempoFeeInclusiveMocks.sol";

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
    /// @dev Smallest floor the wrapper accepts. Used by tests where the floor is not
    ///      under test; the floor itself is covered in section f.
    uint256 internal constant ANY_NET = 1;

    /// @dev A synthetic 18-local / 6-shared OFT, to exercise the dust path. This is NOT
    ///      the deployed Tempo frxUSD OFT, which is 6/6 with `decimalConversionRate == 1`
    ///      (see `TempoFeeInclusiveWrapperForkTest`); that configuration is `oft` below.
    uint256 internal constant DUST_RATE = 1e12;

    MockERC20 internal frxUsd;
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

        frxUsd = new MockERC20("Frax USD", "frxUSD", 18);
        oft = new OFTMock(address(frxUsd), 1);
        dustOft = new OFTMock(address(frxUsd), DUST_RATE);
        hop = new RemoteHopFeeInclusiveMock();
        hop.setApprovedOft(address(oft), true);
        hop.setApprovedOft(address(dustOft), true);
        wrapper = new TempoFeeInclusiveWrapper(address(hop));

        // Stand the Tempo fee-manager precompile up in-memory so no fork is needed.
        vm.etch(StdPrecompiles.TIP_FEE_MANAGER_ADDRESS, address(new TipFeeManagerMock()).code);
        feeManager = TipFeeManagerMock(StdPrecompiles.TIP_FEE_MANAGER_ADDRESS);

        hop.setFeeAmount(FEE);
        frxUsd.mint(alice, 1000e18);
    }

    // ---------------------------------------------------
    // 0. Construction
    // ---------------------------------------------------

    /// @dev `HOP` is immutable with no setter; a bad address would surface only on the
    ///      first send. Refuse it at construction.
    function test_Constructor_RejectsZeroOrCodelessHop() public {
        vm.expectRevert(abi.encodeWithSelector(TempoFeeInclusiveWrapper.InvalidHop.selector, address(0)));
        new TempoFeeInclusiveWrapper(address(0));

        address eoa = makeAddr("not-a-contract");
        vm.expectRevert(abi.encodeWithSelector(TempoFeeInclusiveWrapper.InvalidHop.selector, eoa));
        new TempoFeeInclusiveWrapper(eoa);

        assertEq(address(wrapper.HOP()), address(hop), "a contract address is accepted");
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
        wrapper.sendOFTFeeInclusive(address(oft), DST_EID, recipient, GROSS, ANY_NET, DST_GAS, "");

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
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, address(wrapper), GROSS - 1, GROSS)
        );
        wrapper.sendOFTFeeInclusive(address(oft), DST_EID, recipient, GROSS, ANY_NET, DST_GAS, "");

        frxUsd.approve(address(wrapper), GROSS);
        wrapper.sendOFTFeeInclusive(address(oft), DST_EID, recipient, GROSS, ANY_NET, DST_GAS, "");

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
        wrapper.sendOFTFeeInclusive{ value: 1 wei }(address(oft), DST_EID, recipient, GROSS, ANY_NET, DST_GAS, "");
        vm.stopPrank();

        assertEq(hop.sendCount(), 0, "nothing was sent");
    }

    // ---------------------------------------------------
    // c2. Compose payloads are refused
    // ---------------------------------------------------

    /// @dev The hop stamps `msg.sender` — this wrapper — as the message sender, so a
    ///      destination composer would see every user as one address. Rather than
    ///      document that hazard, the wrapper closes the path. Proven to run before any
    ///      pull: alice grants no allowance, so a pull-first ordering would surface the
    ///      token's allowance error instead.
    function test_SendOFTFeeInclusive_RevertsOnComposeData() public {
        uint256 aliceBefore = frxUsd.balanceOf(alice);

        vm.prank(alice);
        vm.expectRevert(TempoFeeInclusiveWrapper.ComposeNotSupported.selector);
        wrapper.sendOFTFeeInclusive(address(oft), DST_EID, recipient, GROSS, ANY_NET, DST_GAS, hex"01");

        assertEq(hop.sendCount(), 0, "nothing was sent");
        assertEq(frxUsd.balanceOf(alice), aliceBefore, "no funds moved");
    }

    function test_QuoteFeeInclusive_RevertsOnComposeData() public {
        vm.expectRevert(TempoFeeInclusiveWrapper.ComposeNotSupported.selector);
        wrapper.quoteFeeInclusive(address(oft), DST_EID, recipient, GROSS, DST_GAS, hex"01");
    }

    // ---------------------------------------------------
    // c3. Hop-side gates are mirrored: paused hop, unlisted OFT
    // ---------------------------------------------------

    /// @dev The hop checks these first in `sendOFT`, after the wrapper has already
    ///      pulled. Mirroring them lets the quote fail closed during an incident and
    ///      moves the send's revert ahead of the pull (ordering proven by granting no
    ///      allowance: a pull-first path would surface the token's error instead).
    function test_SendOFTFeeInclusive_RevertsWhenHopPaused() public {
        hop.setPaused(true);
        uint256 aliceBefore = frxUsd.balanceOf(alice);

        vm.prank(alice);
        vm.expectRevert(TempoFeeInclusiveWrapper.HopPaused.selector);
        wrapper.sendOFTFeeInclusive(address(oft), DST_EID, recipient, GROSS, ANY_NET, DST_GAS, "");

        assertEq(hop.sendCount(), 0, "nothing was sent");
        assertEq(frxUsd.balanceOf(alice), aliceBefore, "no funds moved");
    }

    function test_QuoteFeeInclusive_RevertsWhenHopPaused() public {
        hop.setPaused(true);

        vm.expectRevert(TempoFeeInclusiveWrapper.HopPaused.selector);
        wrapper.quoteFeeInclusive(address(oft), DST_EID, recipient, GROSS, DST_GAS, "");
    }

    function test_SendOFTFeeInclusive_RevertsOnUnapprovedOft() public {
        OFTMock unlisted = new OFTMock(address(frxUsd), 1);
        uint256 aliceBefore = frxUsd.balanceOf(alice);

        vm.prank(alice);
        vm.expectRevert(TempoFeeInclusiveWrapper.InvalidOFT.selector);
        wrapper.sendOFTFeeInclusive(address(unlisted), DST_EID, recipient, GROSS, ANY_NET, DST_GAS, "");

        assertEq(hop.sendCount(), 0, "nothing was sent");
        assertEq(frxUsd.balanceOf(alice), aliceBefore, "no funds moved");
    }

    /// @dev The allow-list is checked before `IOFT(_oft).token()`, so an address that
    ///      is not an OFT at all gets the same clean error rather than a raw revert.
    function test_QuoteFeeInclusive_RevertsOnUnapprovedOft() public {
        vm.expectRevert(TempoFeeInclusiveWrapper.InvalidOFT.selector);
        wrapper.quoteFeeInclusive(makeAddr("not-an-oft"), DST_EID, recipient, GROSS, DST_GAS, "");
    }

    // ---------------------------------------------------
    // d. Zero gross budget
    // ---------------------------------------------------

    function test_SendOFTFeeInclusive_RevertsOnZeroAmount() public {
        vm.startPrank(alice);
        frxUsd.approve(address(wrapper), GROSS);
        vm.expectRevert(TempoFeeInclusiveWrapper.ZeroAmount.selector);
        wrapper.sendOFTFeeInclusive(address(oft), DST_EID, recipient, 0, ANY_NET, DST_GAS, "");
        vm.stopPrank();

        assertEq(hop.sendCount(), 0, "nothing was sent");
    }

    // ---------------------------------------------------
    // d2. Zero floor is refused
    // ---------------------------------------------------

    /// @dev A zero floor would let the live fee consume the whole budget, and it is
    ///      exactly what `quoteFeeInclusive` returns when nothing is bridgeable — so
    ///      an integrator echoing that quote must hit a revert, not a silent send.
    function test_SendOFTFeeInclusive_RevertsOnZeroMinNet() public {
        uint256 aliceBefore = frxUsd.balanceOf(alice);

        vm.startPrank(alice);
        frxUsd.approve(address(wrapper), GROSS);
        vm.expectRevert(TempoFeeInclusiveWrapper.ZeroMinNetAmount.selector);
        wrapper.sendOFTFeeInclusive(address(oft), DST_EID, recipient, GROSS, 0, DST_GAS, "");
        vm.stopPrank();

        assertEq(hop.sendCount(), 0, "nothing was sent");
        assertEq(frxUsd.balanceOf(alice), aliceBefore, "rejected before any pull");
    }

    /// @dev The full F2 scenario: fee spikes above the budget, the quote reports
    ///      `netAmount == 0`, the integrator passes that straight through as the floor,
    ///      and the fee then recedes before the send lands. Previously this bridged a
    ///      sliver and charged the rest as fee; now it reverts.
    function test_SendOFTFeeInclusive_EchoedZeroQuoteCannotDisableTheFloor() public {
        hop.setFeeAmount(GROSS + 1);
        (, , uint256 quotedNet) = wrapper.quoteFeeInclusive(address(oft), DST_EID, recipient, GROSS, DST_GAS, "");
        assertEq(quotedNet, 0, "nothing bridgeable at quote time");

        // Fee drops back to almost the whole budget before execution.
        hop.setFeeAmount(GROSS - 1);

        vm.startPrank(alice);
        frxUsd.approve(address(wrapper), GROSS);
        vm.expectRevert(TempoFeeInclusiveWrapper.ZeroMinNetAmount.selector);
        wrapper.sendOFTFeeInclusive(address(oft), DST_EID, recipient, GROSS, quotedNet, DST_GAS, "");
        vm.stopPrank();

        assertEq(hop.sendCount(), 0, "the echoed zero quote did not become an unprotected send");
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
        wrapper.sendOFTFeeInclusive(address(oft), DST_EID, recipient, GROSS, ANY_NET, DST_GAS, "");

        // fee == gross (the boundary is inclusive: nothing would be left to bridge)
        hop.setFeeAmount(GROSS);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(TempoFeeInclusiveWrapper.FeeExceedsInput.selector, GROSS, GROSS));
        wrapper.sendOFTFeeInclusive(address(oft), DST_EID, recipient, GROSS, ANY_NET, DST_GAS, "");

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
        wrapper.sendOFTFeeInclusive(address(dustOft), DST_EID, recipient, GROSS, ANY_NET, DST_GAS, "");

        assertEq(hop.lastAmountLD(), expectedNet, "the floored amount is what bridged");
        assertEq(frxUsd.balanceOf(address(hop)), expectedNet + fee, "hop received floored net + fee");
        assertEq(frxUsd.balanceOf(alice), aliceBefore - expectedNet - fee, "the dust came back to the caller");
        assertEq(aliceBefore - frxUsd.balanceOf(alice), GROSS - expectedRefund, "net spend excludes the refund");
        assertEq(frxUsd.balanceOf(address(wrapper)), 0, "no dust stranded in the wrapper");
    }

    // ---------------------------------------------------
    // g2. Quote and collection diverge: the event reports what was taken,
    //     and an over-collection cannot slip through
    // ---------------------------------------------------

    /// @dev The hop is an upgradeable proxy; nothing structural forces the fee it
    ///      pulls to equal the one it quoted. If it pulls less, the difference is
    ///      refunded and the event must carry the fee actually taken — a consumer
    ///      reconciling off the event needs the fact, not the step-1 estimate.
    function test_SendOFTFeeInclusive_EmitsTheFeeActuallyTaken() public {
        uint256 collected = FEE - 0.5e18;
        hop.setCollectedFee(collected);
        uint256 aliceBefore = frxUsd.balanceOf(alice);

        vm.prank(alice);
        frxUsd.approve(address(wrapper), GROSS);

        vm.expectEmit(true, true, false, true, address(wrapper));
        emit SendOFTFeeInclusive(address(oft), alice, DST_EID, recipient, address(frxUsd), NET, collected, GROSS);

        vm.prank(alice);
        wrapper.sendOFTFeeInclusive(address(oft), DST_EID, recipient, GROSS, ANY_NET, DST_GAS, "");

        assertEq(hop.lastAmountLD(), NET, "bridged the net computed from the quote");
        assertEq(frxUsd.balanceOf(address(hop)), NET + collected, "hop took net + the fee it actually charged");
        assertEq(aliceBefore - frxUsd.balanceOf(alice), NET + collected, "caller paid only what was taken");
        assertEq(frxUsd.balanceOf(address(wrapper)), 0, "the unused fee went back, not stranded");
    }

    /// @dev After the hop pulls `netAmount`, the allowance left is exactly the quoted
    ///      fee (dust is zero on a 6/6-decimal OFT). The quote is a hard cap: one unit
    ///      more and the hop's fee pull fails on allowance, unwinding everything. This
    ///      is the behaviour the step-5 comment describes; it used to claim the opposite.
    function test_SendOFTFeeInclusive_RevertsWhenHopCollectsMoreThanQuoted() public {
        hop.setCollectedFee(FEE + 1);
        uint256 aliceBefore = frxUsd.balanceOf(alice);

        vm.startPrank(alice);
        frxUsd.approve(address(wrapper), GROSS);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, address(hop), FEE, FEE + 1)
        );
        wrapper.sendOFTFeeInclusive(address(oft), DST_EID, recipient, GROSS, ANY_NET, DST_GAS, "");
        vm.stopPrank();

        assertEq(hop.sendCount(), 0, "nothing was sent");
        assertEq(frxUsd.balanceOf(alice), aliceBefore, "over-collection cannot eat into the budget");
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
        wrapper.sendOFTFeeInclusive(address(dustOft), DST_EID, recipient, gross, ANY_NET, DST_GAS, "");
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
        wrapper.sendOFTFeeInclusive(address(oft), DST_EID, recipient, GROSS, ANY_NET, DST_GAS, "");
        vm.stopPrank();

        assertEq(frxUsd.allowance(address(wrapper), address(hop)), 0, "wrapper -> hop allowance is cleared");

        // And again on a path that leaves an unspent remainder of the approval.
        hop.setFeeAmount(1e18 + 123);
        vm.startPrank(alice);
        frxUsd.approve(address(wrapper), GROSS);
        wrapper.sendOFTFeeInclusive(address(dustOft), DST_EID, recipient, GROSS, ANY_NET, DST_GAS, "");
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
        wrapper.sendOFTFeeInclusive(address(oft), DST_EID, recipient, GROSS, ANY_NET, DST_GAS, "");
        vm.stopPrank();

        assertEq(feeManager.userTokens(address(wrapper)), address(frxUsd), "wrapper bound to the bridged token");
        assertEq(feeManager.setUserTokenCalls(address(wrapper)), 1, "written once when it differed");

        // Second send with the same fee token must not touch the precompile again.
        vm.startPrank(alice);
        frxUsd.approve(address(wrapper), GROSS);
        wrapper.sendOFTFeeInclusive(address(oft), DST_EID, recipient, GROSS, ANY_NET, DST_GAS, "");
        vm.stopPrank();

        assertEq(hop.sendCount(), 2, "the second send still went through");
        assertEq(feeManager.setUserTokenCalls(address(wrapper)), 1, "not rewritten when already set");
    }

    function test_SendOFTFeeInclusive_SetsUserTokenWhenBoundToAnotherToken() public {
        MockERC20 other = new MockERC20("Other", "OTHER", 18);
        vm.prank(address(wrapper));
        feeManager.setUserToken(address(other));
        assertEq(feeManager.setUserTokenCalls(address(wrapper)), 1, "seeded with a different token");

        vm.startPrank(alice);
        frxUsd.approve(address(wrapper), GROSS);
        wrapper.sendOFTFeeInclusive(address(oft), DST_EID, recipient, GROSS, ANY_NET, DST_GAS, "");
        vm.stopPrank();

        assertEq(feeManager.setUserTokenCalls(address(wrapper)), 2, "rebound to the bridged token");
        assertEq(feeManager.userTokens(address(wrapper)), address(frxUsd), "bridged token is now the fee token");
    }

    // ---------------------------------------------------
    // j2. Fee-manager binding is ordered before the pull and skipped when unneeded
    // ---------------------------------------------------

    /// @dev With no fee there is nothing for the hop to pull in `feeToken`, so binding
    ///      the wrapper's fee-manager token would be dead state — and on a local send
    ///      the quote never inspects the token, so the binding is also the only place
    ///      an unsupported token could still revert. It must not run.
    function test_SendOFTFeeInclusive_SkipsUserTokenWriteWhenFeeIsZero() public {
        hop.setFeeAmount(0);

        vm.startPrank(alice);
        frxUsd.approve(address(wrapper), GROSS);
        wrapper.sendOFTFeeInclusive(address(oft), DST_EID, recipient, GROSS, ANY_NET, DST_GAS, "");
        vm.stopPrank();

        assertEq(hop.sendCount(), 1, "sent");
        assertEq(hop.lastAmountLD(), GROSS, "whole budget bridged when there is no fee");
        assertEq(feeManager.setUserTokenCalls(address(wrapper)), 0, "no fee-manager write");
        assertEq(feeManager.userTokens(address(wrapper)), address(0), "wrapper left unbound");
    }

    /// @dev The fee manager is stricter than the quote (factory USD TIP20 vs. "has a fee
    ///      path"). Its rejection must land before `transferFrom`, so the wrapper's
    ///      "reverts fast, before any pull" promise holds for that gate too. Proven by
    ///      ordering: alice grants NO allowance, so if the pull ran first the revert
    ///      would be the token's `InsufficientAllowance`, not the fee manager's.
    function test_SendOFTFeeInclusive_FeeManagerRejectionPrecedesThePull() public {
        feeManager.setRejectedToken(address(frxUsd));
        uint256 aliceBefore = frxUsd.balanceOf(alice);

        vm.prank(alice);
        vm.expectRevert(TipFeeManagerMock.InvalidToken.selector);
        wrapper.sendOFTFeeInclusive(address(oft), DST_EID, recipient, GROSS, ANY_NET, DST_GAS, "");

        assertEq(hop.sendCount(), 0, "nothing was sent");
        assertEq(frxUsd.balanceOf(alice), aliceBefore, "no funds moved");
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
        wrapper.sendOFTFeeInclusive(address(oft), DST_EID, recipient, GROSS, ANY_NET, DST_GAS, "");
        vm.stopPrank();

        assertEq(frxUsd.balanceOf(alice), aliceBefore, "caller was made whole");
        assertEq(frxUsd.balanceOf(address(wrapper)), 0, "no funds stranded in the wrapper");
        assertEq(frxUsd.balanceOf(address(hop)), 0, "the hop kept nothing");
        assertEq(frxUsd.allowance(alice, address(wrapper)), GROSS, "the caller's approval is untouched");
        assertEq(frxUsd.allowance(address(wrapper), address(hop)), 0, "no dangling allowance to the hop");
        assertEq(feeManager.setUserTokenCalls(address(wrapper)), 0, "the precompile write rolled back too");
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
        hop.setApprovedOft(address(fuzzOft), true);
        hop.setFeeAmount(fee);

        uint256 expectedNet = ((gross - fee) / rate) * rate;
        // Guard the fixture before the call it protects: if the bounds ever stop
        // producing a bridgeable amount, fail here with the reason, not inside the
        // send with `NetAmountZero`.
        assertGt(expectedNet, 0, "the fuzz region must produce a bridgeable amount");
        uint256 aliceBefore = frxUsd.balanceOf(alice);

        vm.startPrank(alice);
        frxUsd.approve(address(wrapper), gross);
        wrapper.sendOFTFeeInclusive(address(fuzzOft), DST_EID, recipient, gross, ANY_NET, DST_GAS, "");
        vm.stopPrank();

        uint256 spent = aliceBefore - frxUsd.balanceOf(alice);

        assertEq(hop.lastAmountLD(), expectedNet, "bridged the dust-cleaned net");
        assertEq(spent, expectedNet + fee, "caller paid exactly net + fee");
        assertLe(spent, gross, "caller never paid more than the stated budget");
        assertEq(frxUsd.balanceOf(address(wrapper)), 0, "wrapper never retains funds");
        assertEq(frxUsd.allowance(address(wrapper), address(hop)), 0, "wrapper leaves no allowance behind");
    }

    /// @dev The floor is the caller's only protection against the live fee. Across
    ///      the same budget / fee / granularity space, any floor strictly above the
    ///      achievable net must be refused — and refused before any funds move.
    function testFuzz_SendOFTFeeInclusive_FloorAboveNetAlwaysReverts(
        uint256 _gross,
        uint256 _fee,
        uint8 _rateExponent,
        uint256 _floorExcess
    ) public {
        uint256 rate = 10 ** _bound(uint256(_rateExponent), 0, 12);
        uint256 gross = _bound(_gross, rate * 2, 1000e18);
        uint256 fee = _bound(_fee, 0, gross - rate);
        uint256 net = ((gross - fee) / rate) * rate;
        assertGt(net, 0, "the fuzz region must produce a bridgeable amount");
        uint256 floor = net + _bound(_floorExcess, 1, type(uint256).max - net);

        OFTMock fuzzOft = new OFTMock(address(frxUsd), rate);
        hop.setApprovedOft(address(fuzzOft), true);
        hop.setFeeAmount(fee);
        uint256 aliceBefore = frxUsd.balanceOf(alice);

        vm.startPrank(alice);
        frxUsd.approve(address(wrapper), gross);
        vm.expectRevert(abi.encodeWithSelector(TempoFeeInclusiveWrapper.InsufficientNetAmount.selector, net, floor));
        wrapper.sendOFTFeeInclusive(address(fuzzOft), DST_EID, recipient, gross, floor, DST_GAS, "");
        vm.stopPrank();

        assertEq(hop.sendCount(), 0, "nothing was sent");
        assertEq(frxUsd.balanceOf(alice), aliceBefore, "refused before any pull");
    }

    // ---------------------------------------------------
    // Donation safety
    // ---------------------------------------------------

    /// @dev Tokens sitting in the wrapper before a call — sent there by mistake, or
    ///      by an attacker hoping the next caller's refund picks them up — are
    ///      excluded from that call's accounting by the `balanceBefore` snapshot.
    ///      They are neither refunded to the caller nor pulled by the hop; the
    ///      wrapper has no rescue path, so they simply stay. Both halves matter:
    ///      the caller cannot be enriched, and the donation cannot distort the send.
    function test_SendOFTFeeInclusive_PreExistingBalanceIsNeitherRefundedNorDrained() public {
        uint256 donation = 7e18;
        frxUsd.mint(address(wrapper), donation);
        uint256 aliceBefore = frxUsd.balanceOf(alice);

        vm.prank(alice);
        frxUsd.approve(address(wrapper), GROSS);

        vm.expectEmit(true, true, false, true, address(wrapper));
        emit SendOFTFeeInclusive(address(oft), alice, DST_EID, recipient, address(frxUsd), NET, FEE, GROSS);

        vm.prank(alice);
        wrapper.sendOFTFeeInclusive(address(oft), DST_EID, recipient, GROSS, ANY_NET, DST_GAS, "");

        assertEq(aliceBefore - frxUsd.balanceOf(alice), GROSS, "caller paid exactly the budget, no windfall");
        assertEq(frxUsd.balanceOf(address(hop)), NET + FEE, "hop took exactly net + fee, not the donation");
        assertEq(frxUsd.balanceOf(address(wrapper)), donation, "donation untouched and unrecoverable");
    }

    /// @dev Same property on the dust path, where a refund actually happens: the
    ///      refund is this call's remainder only, never the pre-existing balance.
    function test_SendOFTFeeInclusive_RefundExcludesPreExistingBalance() public {
        uint256 donation = 7e18;
        frxUsd.mint(address(wrapper), donation);
        uint256 fee = 1e18 + 123;
        hop.setFeeAmount(fee);
        uint256 expectedNet = ((GROSS - fee) / DUST_RATE) * DUST_RATE;
        uint256 expectedRefund = (GROSS - fee) - expectedNet;
        uint256 aliceBefore = frxUsd.balanceOf(alice);

        vm.prank(alice);
        frxUsd.approve(address(wrapper), GROSS);
        vm.prank(alice);
        wrapper.sendOFTFeeInclusive(address(dustOft), DST_EID, recipient, GROSS, ANY_NET, DST_GAS, "");

        assertEq(aliceBefore - frxUsd.balanceOf(alice), GROSS - expectedRefund, "only this call's dust came back");
        assertEq(frxUsd.balanceOf(address(wrapper)), donation, "the donation stayed put");
    }
}
