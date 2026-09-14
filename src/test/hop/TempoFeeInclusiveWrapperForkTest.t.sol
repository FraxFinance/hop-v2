// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

import { Test } from "forge-std/Test.sol";
import { ITIP20 } from "@tempo/interfaces/ITIP20.sol";
import { StdPrecompiles } from "tempo-std/StdPrecompiles.sol";
import { TempoFeeInclusiveWrapper } from "src/contracts/hop/TempoFeeInclusiveWrapper.sol";

/// @dev TIP20 role lookup uses Tempo's `(account, role)` argument order, not OpenZeppelin's.
interface ITIP20Roles {
    function hasRole(address account, bytes32 role) external view returns (bool);
}

interface IOFTView {
    function decimalConversionRate() external view returns (uint256);
}

/// @dev Stand-in for "any contract" calling the fee manager: `msg.sender` is this contract,
///      `tx.origin` is whoever sent the transaction — exactly the wrapper's frame.
contract SetUserTokenCaller {
    function set(address _token) external {
        StdPrecompiles.TIP_FEE_MANAGER.setUserToken(_token);
    }
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
contract TempoFeeInclusiveWrapperForkTest is Test {
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

    uint256 internal constant TEMPO_FORK_BLOCK = 39_508_000;

    /// @dev Deployed RemoteHopV201Tempo proxy (Tempo mainnet).
    address internal constant REMOTE_HOP_TEMPO = 0x0000006D38568b00B457580b734e0076C62de659;
    /// @dev frxUSD TIP20 (6 decimals) and its OFT adapter.
    address internal constant FRXUSD = 0x20C0000000000000000000003554d28269E0f3c2;
    address internal constant FRXUSD_OFT = 0x00000000D61733e7A393A10A5B48c311AbE8f1E5;
    /// @dev An OFT token that is NOT a TIP20 — the fee manager must reject it.
    address internal constant SFRXUSD_OFT = 0x00000000fD8C4B8A413A06821456801295921a71;

    uint32 internal constant FRAXTAL_EID = 30_255;
    uint128 internal constant DST_GAS = 400_000;
    uint256 internal constant GROSS = 100e6;

    TempoFeeInclusiveWrapper internal wrapper;
    address internal alice;
    bytes32 internal recipient;

    function setUp() public {
        vm.createSelectFork(_tempoRpcUrl(), TEMPO_FORK_BLOCK);

        wrapper = new TempoFeeInclusiveWrapper(REMOTE_HOP_TEMPO);
        alice = makeAddr("alice");
        recipient = bytes32(uint256(uint160(alice)));

        _mintFrxUsd(alice, 1000e6);
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
        assertEq(IOFTView(FRXUSD_OFT).decimalConversionRate(), 1, "frxUSD OFT dust granularity");
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
        assertEq(net, GROSS - fee, "no dust: net is exactly gross minus fee");

        uint256 aliceBefore = ITIP20(FRXUSD).balanceOf(alice);

        vm.prank(alice);
        ITIP20(FRXUSD).approve(address(wrapper), GROSS);

        vm.expectEmit(true, true, false, true, address(wrapper));
        emit SendOFTFeeInclusive(FRXUSD_OFT, alice, FRAXTAL_EID, recipient, FRXUSD, net, fee, GROSS);

        vm.prank(alice);
        wrapper.sendOFTFeeInclusive(FRXUSD_OFT, FRAXTAL_EID, recipient, GROSS, net, DST_GAS, "");

        assertEq(aliceBefore - ITIP20(FRXUSD).balanceOf(alice), GROSS, "caller paid exactly net + fee");
        assertEq(ITIP20(FRXUSD).balanceOf(address(wrapper)), 0, "wrapper retains nothing");
        assertEq(ITIP20(FRXUSD).allowance(address(wrapper), REMOTE_HOP_TEMPO), 0, "no dangling allowance");
        assertEq(ITIP20(FRXUSD).allowance(alice, address(wrapper)), 0, "single approval fully consumed");
        assertEq(
            StdPrecompiles.TIP_FEE_MANAGER.userTokens(address(wrapper)),
            FRXUSD,
            "wrapper's fee-manager token was bound to the bridged token"
        );
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
