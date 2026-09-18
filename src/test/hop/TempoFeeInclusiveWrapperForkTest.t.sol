// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

import { Test, Vm } from "forge-std/Test.sol";
import { ITIP20 } from "@tempo/interfaces/ITIP20.sol";
import { StdPrecompiles } from "tempo-std/StdPrecompiles.sol";
import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { ERC1967Utils } from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Utils.sol";
import { ProxyAdmin } from "@openzeppelin/contracts/proxy/transparent/ProxyAdmin.sol";
import { ITransparentUpgradeableProxy } from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import { IOFT2 } from "src/contracts/interfaces/IOFT2.sol";
import { RemoteHopV201Tempo } from "src/contracts/hop/RemoteHopV201Tempo.sol";
import { TempoFeeInclusiveWrapper } from "src/contracts/hop/TempoFeeInclusiveWrapper.sol";
import { SetUserTokenCaller } from "src/test/hop/mocks/TempoFeeInclusiveMocks.sol";

/// @dev TIP20 role lookup uses Tempo's `(account, role)` argument order. The upstream
///      `ITIP20RolesAuth` declares the mutators only, so this view is declared here.
interface ITIP20Roles {
    function hasRole(address account, bytes32 role) external view returns (bool);
}

/// @title TempoFeeInclusiveWrapperForkTest
/// @notice Tempo MAINNET-FORK coverage for `TempoFeeInclusiveWrapper` against the real
///         deployed `RemoteHopV201Tempo`, the real Rust precompiles (FeeManager,
///         StablecoinDEX, TIP20), the real frxUSD OFT adapter and the real EndpointV2Alt.
///         Nothing is mocked.
/// @dev Run with `forge test --network tempo`. The Tempo precompiles are native code inside
///      forge's EVM and are only enabled under that network family; without the flag every
///      precompile call reverts. This file is therefore kept out of the default CI test step
///      and run in its own step (see .github/workflows/main.yml).
///
///      `deal()` cannot fund a TIP20 — its balances live in precompile storage. frxUSD is
///      minted by pranking the OFT adapter, which holds `ISSUER_ROLE` on mainnet.
///
///      frxUSD is not whitelisted by the endpoint dollar, so every remote send here settles
///      its fee through a StablecoinDEX swap. This suite runs against the implementation
///      that is live at `TEMPO_FORK_BLOCK` (2.0.1, which swaps with `maxAmountIn == quote`);
///      `TempoFeeInclusiveWrapperPaddedHopForkTest` below installs this branch's
///      `RemoteHopV201Tempo` behind the same proxy, whose swap carries headroom and refunds
///      the unspent part through the wrapper. The wrapper's accounting must hold for both,
///      so the settlement assertions here are the invariants shared by the two and the
///      padded suite tightens them.
contract TempoFeeInclusiveWrapperForkTest is Test {
    uint256 internal constant TEMPO_FORK_BLOCK = 39_508_000;

    /// @dev Deployed RemoteHopV201Tempo proxy (Tempo mainnet).
    address internal constant REMOTE_HOP_TEMPO = 0x0000006D38568b00B457580b734e0076C62de659;
    /// @dev frxUSD TIP20 (6 decimals) and its OFT adapter.
    address internal constant FRXUSD = 0x20C0000000000000000000003554d28269E0f3c2;
    address internal constant FRXUSD_OFT = 0x00000000D61733e7A393A10A5B48c311AbE8f1E5;
    /// @dev An OFT token that is NOT a TIP20 — the fee manager must reject it.
    address internal constant SFRXUSD_OFT = 0x00000000fD8C4B8A413A06821456801295921a71;
    /// @dev RemoteAdmin: holds DEFAULT_ADMIN_ROLE on the deployed hop.
    address internal constant HOP_ADMIN = 0x05b4a311Aac6658C0FA1e0247Be898aae8a8581f;

    uint32 internal constant FRAXTAL_EID = 30_255;
    uint32 internal constant TEMPO_EID = 30_410;
    uint128 internal constant DST_GAS = 400_000;
    uint256 internal constant GROSS = 100e6;

    TempoFeeInclusiveWrapper internal wrapper;
    address internal alice;
    bytes32 internal recipient;

    function setUp() public virtual {
        vm.createSelectFork(_tempoRpcUrl(), TEMPO_FORK_BLOCK);
        _installHopImplementation();

        wrapper = new TempoFeeInclusiveWrapper(REMOTE_HOP_TEMPO);
        alice = makeAddr("alice");
        recipient = bytes32(uint256(uint160(alice)));

        _mintFrxUsd(alice, 1000e6);
    }

    /// @dev The hop implementation the suite runs against. The base suite keeps whatever is
    ///      live at `TEMPO_FORK_BLOCK`; the padded suite swaps in this branch's build.
    function _installHopImplementation() internal virtual {}

    /// @dev Fee settlement invariants the wrapper guarantees whichever hop implementation is
    ///      behind the proxy: the hop never takes more than the wrapper quoted, and the caller
    ///      never pays more than the budget. The padded suite tightens both to strict.
    function _assertFeeSettlement(uint256 quotedFee, uint256 takenFee, uint256 paid) internal virtual {
        assertLe(takenFee, quotedFee, "fee taken never exceeds the quote");
        assertLe(paid, GROSS, "caller never pays more than the budget");
    }

    // ---------------------------------------------------
    // a. Precompile behaviour the wrapper depends on
    // ---------------------------------------------------

    /// @dev The wrapper calls `setUserToken` with itself as `msg.sender` and the user as
    ///      `tx.origin`. The deployed fee manager must accept that (it does — the hop makes the
    ///      same call on every send). If Tempo ever ships a direct-call-only guard, this fails
    ///      before mainnet does.
    function test_FeeManager_SetUserTokenFromContractContext_Succeeds() public {
        SetUserTokenCaller caller = new SetUserTokenCaller();

        caller.set(FRXUSD);

        assertEq(StdPrecompiles.TIP_FEE_MANAGER.userTokens(address(caller)), FRXUSD, "contract-context write landed");
    }

    /// @dev The fee manager only accepts factory-deployed USD TIP20s; a plain OFT token reverts.
    ///      This is the guard that makes non-frxUSD OFTs unsupported by the wrapper.
    function test_FeeManager_SetUserToken_RejectsNonTip20() public {
        SetUserTokenCaller caller = new SetUserTokenCaller();

        vm.expectRevert();
        caller.set(SFRXUSD_OFT);
    }

    // ---------------------------------------------------
    // b. Shape of the deployed OFT
    // ---------------------------------------------------

    /// @dev frxUSD is 6/6 decimals on Tempo, so `removeDust` is the identity: there is no
    ///      sub-dust refund band and every unit of `_maxAmountInLD - fee` is bridged.
    function test_FrxUsdOft_DecimalConversionRateIsOne() public view {
        assertEq(IOFT2(FRXUSD_OFT).decimalConversionRate(), 1, "frxUSD OFT dust granularity");
        assertEq(ITIP20(FRXUSD).decimals(), 6, "frxUSD local decimals");
    }

    // ---------------------------------------------------
    // c. End to end
    // ---------------------------------------------------

    function test_SendOFTFeeInclusive_EndToEnd() public {
        (address feeToken, uint256 fee, uint256 net) = wrapper.quoteFeeInclusive(
            FRXUSD_OFT,
            FRAXTAL_EID,
            recipient,
            GROSS,
            DST_GAS,
            ""
        );
        assertEq(feeToken, FRXUSD, "fee is taken in the bridged token");
        assertGt(fee, 0, "remote send has a non-zero fee");
        assertEq(net, GROSS - fee, "no dust: net is exactly gross minus the quoted fee");

        uint256 aliceBefore = ITIP20(FRXUSD).balanceOf(alice);
        uint256 hopBefore = ITIP20(FRXUSD).balanceOf(REMOTE_HOP_TEMPO);

        vm.prank(alice);
        ITIP20(FRXUSD).approve(address(wrapper), GROSS);

        vm.recordLogs();
        vm.prank(alice);
        wrapper.sendOFTFeeInclusive(FRXUSD_OFT, FRAXTAL_EID, recipient, GROSS, net, DST_GAS, "");
        (uint256 netTaken, uint256 feeTaken) = _sendEvent(vm.getRecordedLogs(), FRAXTAL_EID, recipient);
        uint256 paid = aliceBefore - ITIP20(FRXUSD).balanceOf(alice);

        assertEq(netTaken, net, "bridged exactly the quoted net");
        assertEq(paid, net + feeTaken, "caller paid the bridged amount plus the fee actually taken");
        _assertFeeSettlement(fee, feeTaken, paid);
        assertEq(ITIP20(FRXUSD).balanceOf(address(wrapper)), 0, "wrapper retains nothing");
        assertEq(
            ITIP20(FRXUSD).balanceOf(REMOTE_HOP_TEMPO),
            hopBefore,
            "hop keeps no frxUSD: the fee is swapped out and any unspent input comes back"
        );
        assertEq(ITIP20(FRXUSD).allowance(address(wrapper), REMOTE_HOP_TEMPO), 0, "no dangling allowance");
        assertEq(ITIP20(FRXUSD).allowance(alice, address(wrapper)), 0, "single approval fully consumed");
        assertEq(
            StdPrecompiles.TIP_FEE_MANAGER.userTokens(address(wrapper)),
            FRXUSD,
            "wrapper's fee-manager token was bound to the bridged token"
        );
    }

    /// @dev Tempo -> Tempo: the hop quotes no fee, so the wrapper must not bind its
    ///      fee-manager token (there is nothing to collect) and the full budget lands
    ///      with the recipient. Exercises the local branch of the real hop and the real
    ///      TIP20 transfer.
    function test_SendOFTFeeInclusive_LocalSend_NoFeeNoFeeManagerBinding() public {
        address bob = makeAddr("bob");
        bytes32 toBob = bytes32(uint256(uint160(bob)));

        (, uint256 fee, uint256 net) = wrapper.quoteFeeInclusive(FRXUSD_OFT, TEMPO_EID, toBob, GROSS, DST_GAS, "");
        assertEq(fee, 0, "no LayerZero fee on a local send");
        assertEq(net, GROSS, "whole budget is bridgeable");

        vm.prank(alice);
        ITIP20(FRXUSD).approve(address(wrapper), GROSS);
        vm.prank(alice);
        wrapper.sendOFTFeeInclusive(FRXUSD_OFT, TEMPO_EID, toBob, GROSS, net, DST_GAS, "");

        assertEq(ITIP20(FRXUSD).balanceOf(bob), GROSS, "recipient received the full budget, fee-free");
        assertEq(ITIP20(FRXUSD).balanceOf(address(wrapper)), 0, "wrapper retains nothing");
        assertEq(
            StdPrecompiles.TIP_FEE_MANAGER.userTokens(address(wrapper)),
            address(0),
            "fee-manager binding skipped when no fee is collected"
        );
    }

    /// @dev Stage an incident on the real hop: its admin pauses it. The quote must
    ///      fail closed (no healthy numbers for a send that cannot land) and the send
    ///      must reject before pulling, not from inside the hop afterwards.
    function test_HopPaused_QuoteAndSendFailClosed() public {
        vm.prank(HOP_ADMIN);
        RemoteHopV201Tempo(REMOTE_HOP_TEMPO).pauseOn();

        vm.expectRevert(TempoFeeInclusiveWrapper.HopPaused.selector);
        wrapper.quoteFeeInclusive(FRXUSD_OFT, FRAXTAL_EID, recipient, GROSS, DST_GAS, "");

        uint256 aliceBefore = ITIP20(FRXUSD).balanceOf(alice);
        vm.prank(alice);
        vm.expectRevert(TempoFeeInclusiveWrapper.HopPaused.selector);
        wrapper.sendOFTFeeInclusive(FRXUSD_OFT, FRAXTAL_EID, recipient, GROSS, GROSS / 2, DST_GAS, "");
        assertEq(ITIP20(FRXUSD).balanceOf(alice), aliceBefore, "rejected before any pull");
    }

    function test_UnapprovedOft_QuoteAndSendFailClosed() public {
        vm.prank(HOP_ADMIN);
        RemoteHopV201Tempo(REMOTE_HOP_TEMPO).setApprovedOft(FRXUSD_OFT, false);

        vm.expectRevert(TempoFeeInclusiveWrapper.InvalidOFT.selector);
        wrapper.quoteFeeInclusive(FRXUSD_OFT, FRAXTAL_EID, recipient, GROSS, DST_GAS, "");

        vm.prank(alice);
        vm.expectRevert(TempoFeeInclusiveWrapper.InvalidOFT.selector);
        wrapper.sendOFTFeeInclusive(FRXUSD_OFT, FRAXTAL_EID, recipient, GROSS, GROSS / 2, DST_GAS, "");
    }

    /// @dev A real-frxUSD balance parked in the wrapper before a send is invisible to
    ///      that send: not refunded to the caller, not pulled by the hop, left in place.
    ///      The caller's debit is exactly what the event accounts for, so a refunded
    ///      donation would show up as a shortfall here.
    function test_SendOFTFeeInclusive_PreExistingBalanceIsUntouched() public {
        uint256 donation = 3e6;
        _mintFrxUsd(address(wrapper), donation);
        (, uint256 fee, uint256 net) = wrapper.quoteFeeInclusive(
            FRXUSD_OFT,
            FRAXTAL_EID,
            recipient,
            GROSS,
            DST_GAS,
            ""
        );
        uint256 aliceBefore = ITIP20(FRXUSD).balanceOf(alice);

        vm.prank(alice);
        ITIP20(FRXUSD).approve(address(wrapper), GROSS);
        vm.recordLogs();
        vm.prank(alice);
        wrapper.sendOFTFeeInclusive(FRXUSD_OFT, FRAXTAL_EID, recipient, GROSS, net, DST_GAS, "");
        (, uint256 feeTaken) = _sendEvent(vm.getRecordedLogs(), FRAXTAL_EID, recipient);
        uint256 paid = aliceBefore - ITIP20(FRXUSD).balanceOf(alice);

        assertEq(paid, net + feeTaken, "caller paid bridged amount plus fee taken, no windfall");
        _assertFeeSettlement(fee, feeTaken, paid);
        assertEq(ITIP20(FRXUSD).balanceOf(address(wrapper)), donation, "donation untouched");
    }

    function test_SendOFTFeeInclusive_RevertsBelowMinNet() public {
        (, , uint256 net) = wrapper.quoteFeeInclusive(FRXUSD_OFT, FRAXTAL_EID, recipient, GROSS, DST_GAS, "");

        vm.prank(alice);
        ITIP20(FRXUSD).approve(address(wrapper), GROSS);

        vm.expectRevert(abi.encodeWithSelector(TempoFeeInclusiveWrapper.InsufficientNetAmount.selector, net, net + 1));
        vm.prank(alice);
        wrapper.sendOFTFeeInclusive(FRXUSD_OFT, FRAXTAL_EID, recipient, GROSS, net + 1, DST_GAS, "");

        assertEq(ITIP20(FRXUSD).allowance(alice, address(wrapper)), GROSS, "floor check runs before any pull");
    }

    // ---------------------------------------------------
    // helpers
    // ---------------------------------------------------

    /// @dev Reads the wrapper's `SendOFTFeeInclusive` out of the recorded logs and returns the
    ///      bridged amount and the fee it reports as actually taken. The fee is the figure the
    ///      wrapper measured after the send, not the quote, which is why the tests read it back
    ///      instead of matching the whole event with `expectEmit`.
    function _sendEvent(
        Vm.Log[] memory logs,
        uint32 expectedDstEid,
        bytes32 expectedRecipient
    ) internal view returns (uint256 netAmount, uint256 feeAmount) {
        bool found;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter != address(wrapper)) continue;
            if (logs[i].topics[0] != TempoFeeInclusiveWrapper.SendOFTFeeInclusive.selector) continue;
            assertFalse(found, "one send, one event");
            found = true;
            assertEq(logs[i].topics[1], bytes32(uint256(uint160(FRXUSD_OFT))), "event oft");
            assertEq(logs[i].topics[2], bytes32(uint256(uint160(alice))), "event sender");
            (uint32 dstEid, bytes32 to, address feeToken, uint256 net, uint256 fee, uint256 maxAmountIn) = abi.decode(
                logs[i].data,
                (uint32, bytes32, address, uint256, uint256, uint256)
            );
            assertEq(dstEid, expectedDstEid, "event dstEid");
            assertEq(to, expectedRecipient, "event recipient");
            assertEq(feeToken, FRXUSD, "event feeToken");
            assertEq(maxAmountIn, GROSS, "event maxAmountIn");
            (netAmount, feeAmount) = (net, fee);
        }
        assertTrue(found, "SendOFTFeeInclusive emitted");
    }

    function _mintFrxUsd(address _to, uint256 _amount) internal {
        bytes32 issuer = ITIP20(FRXUSD).ISSUER_ROLE();
        assertTrue(ITIP20Roles(FRXUSD).hasRole(FRXUSD_OFT, issuer), "OFT adapter must hold ISSUER_ROLE");
        vm.prank(FRXUSD_OFT);
        ITIP20(FRXUSD).mint(_to, _amount);
    }

    function _tempoRpcUrl() internal view returns (string memory rpcUrl) {
        rpcUrl = vm.envOr("TEMPO_RPC_URL", string(""));
        if (bytes(rpcUrl).length == 0) rpcUrl = vm.envOr("TEMPO_MAINNET_URL", string(""));
        if (bytes(rpcUrl).length == 0) rpcUrl = vm.envOr("RPC_URL", string(""));
        require(bytes(rpcUrl).length != 0, "Tempo RPC URL not found");
    }
}

/// @title TempoFeeInclusiveWrapperPaddedHopForkTest
/// @notice The same suite against this branch's `RemoteHopV201Tempo`, installed behind the live
///         proxy through the ProxyAdmin call the upgrade batch makes (`UpgradeRemoteHopV2Tempo`).
///         This is the hop the wrapper meets once that upgrade ships: its fee swap is quoted with
///         headroom, debited at that figure, and the part the swap does not consume is handed back
///         to the wrapper, which forwards it to the caller.
/// @dev Tightens the shared settlement invariants to strict inequalities so the refund path is
///      proven to have run, not merely to have been harmless.
contract TempoFeeInclusiveWrapperPaddedHopForkTest is TempoFeeInclusiveWrapperForkTest {
    function _installHopImplementation() internal override {
        address proxyAdmin = address(uint160(uint256(vm.load(REMOTE_HOP_TEMPO, ERC1967Utils.ADMIN_SLOT))));
        address endpoint = RemoteHopV201Tempo(REMOTE_HOP_TEMPO).endpoint();
        address implementation = address(new RemoteHopV201Tempo(endpoint));

        vm.prank(Ownable(proxyAdmin).owner());
        ProxyAdmin(proxyAdmin).upgradeAndCall(ITransparentUpgradeableProxy(REMOTE_HOP_TEMPO), implementation, "");

        assertEq(
            address(uint160(uint256(vm.load(REMOTE_HOP_TEMPO, ERC1967Utils.IMPLEMENTATION_SLOT)))),
            implementation,
            "padded implementation behind the live proxy"
        );
        assertEq(RemoteHopV201Tempo(REMOTE_HOP_TEMPO).feeSwapSlippageBps(), 50, "default headroom in force");
    }

    function _assertFeeSettlement(uint256 quotedFee, uint256 takenFee, uint256 paid) internal override {
        super._assertFeeSettlement(quotedFee, takenFee, paid);
        assertLt(takenFee, quotedFee, "the padded hop takes less than its padded quote");
        assertLt(paid, GROSS, "unspent swap headroom came back to the caller");
    }
}
