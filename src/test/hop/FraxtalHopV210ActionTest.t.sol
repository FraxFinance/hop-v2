// SPDX-License-Identifier: UNLICENSED
// 0.8.26+: the fork fixtures below overflow the stack under 0.8.23's via-IR pipeline
pragma solidity ^0.8.26;

import { Test, Vm } from "forge-std/Test.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { OFTComposeMsgCodec } from "@layerzerolabs/oft-evm/contracts/libs/OFTComposeMsgCodec.sol";
import { IOFT } from "@fraxfinance/layerzero-v2-upgradeable/oapp/contracts/oft/interfaces/IOFT.sol";

import { FraxtalHopV201 } from "src/contracts/hop/FraxtalHopV201.sol";
import { MintRedeemModule } from "src/contracts/hop/MintRedeemModule.sol";
import { IHopActionModule } from "src/contracts/interfaces/IHopActionModule.sol";
import { IHopV201, HopMessage, FeeMultipliers } from "src/contracts/interfaces/IHopV201.sol";
import { IFraxtalERC4626MintRedeemer } from "src/contracts/interfaces/IFraxtalERC4626MintRedeemer.sol";
import { HopActions } from "src/contracts/libraries/HopActions.sol";
import { deployMintRedeemModule } from "src/script/hop/upgrade/MintRedeemModuleDeployer.s.sol";

/// @dev Returns a plausible answer but delivers nothing: the hub must catch it by balance.
contract LyingModuleMock is IHopActionModule {
    address public immutable OUT;

    constructor(address _out) {
        OUT = _out;
    }

    function outputOft(bytes4, address) external view returns (address) {
        return OUT;
    }

    function convert(bytes4, address, uint256 _amountIn) external view returns (address, uint256) {
        return (OUT, _amountIn * 1000);
    }
}

/// @notice Hop 2.1.0 on the LIVE Fraxtal hub proxy: upgrade in place, bolt on the mint/redeem module, and run the
///         real mint-redeemer and OFT adapters. Run with FRAXTAL_MAINNET_URL set (archive RPC).
/// @dev Test bodies stay small and route external calls through helpers so the file also compiles without via-IR.
contract FraxtalHopV210ActionTest is Test {
    uint256 constant FORK_BLOCK = 42_828_705;

    address payable constant HUB = payable(0x00000000e18aFc20Afe54d4B2C8688bB60c06B36);
    address constant PROXY_ADMIN = 0x223a681fc5c5522c85C96157c0efA18cd6c5405c;
    address constant SAFE = 0xC4EB45d80DC1F079045E75D5d55de8eD1c1090E6; // ProxyAdmin owner + hub DEFAULT_ADMIN
    address constant ENDPOINT = 0x1a44076050125825900e736c501f859c50fE728c;
    address constant MINT_REDEEMER = 0xBFc4D34Db83553725eC6c768da71D2D9c1456B55;
    address constant FRXUSD_LOCKBOX = 0x96A394058E2b84A89bac9667B19661Ed003cF5D4;
    address constant SFRXUSD_LOCKBOX = 0x88Aa7854D3b2dAA5e37E7Ce73A1F39669623a361;
    address constant FRXETH_LOCKBOX = 0x9aBFE1F8a999B0011ecD6116649AEe8D575F5604;
    address constant FRXUSD = 0xFc00000000000000000000000000000000000001;
    address constant SFRXUSD = 0xfc00000000000000000000000000000000000008;
    address constant SPOKE = 0x0000006D38568b00B457580b734e0076C62de659; // every spoke's vanity proxy

    uint32 constant FRAXTAL_EID = 30_255;
    uint32 constant ARBITRUM_EID = 30_110;
    uint32 constant SONIC_EID = 30_332;

    bytes32 constant ACTION_SLOT = 0x082f264becc2542cd02d6f434db51b13ff6e3d25f7cc50107c0660951e19af00;
    bytes constant TAG = hex"d71e9971";

    FraxtalHopV201 hop;
    MintRedeemModule module;
    address user = makeAddr("user");
    address refundTo = makeAddr("refundTo");
    uint64 nonce = 1;

    // live state captured before the upgrade
    bytes32 preRemoteArb;
    bytes32 preRemoteSonic;
    uint32 preNumDVNs;
    uint256 preHopFee;
    FeeMultipliers preMultipliers;
    bytes preExecutorOptions;
    uint256 preAdminCount;

    struct ActionLog {
        bool found;
        address oftIn;
        address oftOut;
        uint256 amountIn;
        uint256 amountOut;
    }

    struct HopLog {
        bool found;
        address oft;
        uint32 dstEid;
        uint256 amount;
    }

    receive() external payable {}

    function setUp() public {
        vm.createSelectFork(vm.envString("FRAXTAL_MAINNET_URL"), FORK_BLOCK);
        _snapshotLiveState();

        // 1. upgrade the live proxy in place, exactly as the Safe batch does
        address impl = address(new FraxtalHopV201());
        vm.prank(SAFE);
        (bool ok, ) = PROXY_ADMIN.call(
            abi.encodeWithSignature("upgradeAndCall(address,address,bytes)", HUB, impl, bytes(""))
        );
        require(ok, "upgrade failed");
        hop = FraxtalHopV201(HUB);

        // 2. module behind the same ProxyAdmin, initialised in its constructor, 3. point the hub at it
        module = MintRedeemModule(
            deployMintRedeemModule(PROXY_ADMIN, SAFE, HUB, MINT_REDEEMER, FRXUSD_LOCKBOX, SFRXUSD_LOCKBOX)
        );
        vm.prank(SAFE);
        hop.setActionModule(address(module));

        vm.deal(ENDPOINT, 100 ether);
    }

    function _snapshotLiveState() internal {
        IHopV201 live = IHopV201(HUB);
        preRemoteArb = live.remoteHop(ARBITRUM_EID);
        preRemoteSonic = live.remoteHop(SONIC_EID);
        preNumDVNs = live.numDVNs();
        preHopFee = live.hopFee();
        preMultipliers = live.feeMultipliers(ARBITRUM_EID);
        preExecutorOptions = live.executorOptions(ARBITRUM_EID);
        preAdminCount = FraxtalHopV201(HUB).getRoleMemberCount(bytes32(0));
    }

    // ───────────────────────────── helpers ─────────────────────────────

    function _userB32() internal view returns (bytes32) {
        return bytes32(uint256(uint160(user)));
    }

    function _hopMessage(
        uint32 _dstEid,
        address _recipient,
        bytes memory _data
    ) internal pure returns (HopMessage memory) {
        return
            HopMessage({
                srcEid: ARBITRUM_EID,
                dstEid: _dstEid,
                dstGas: 0,
                sender: bytes32(uint256(uint160(0xA11CE))),
                recipient: bytes32(uint256(uint160(_recipient))),
                data: _data
            });
    }

    function _message(uint256 _amount, HopMessage memory _hop, address _composeFrom) internal returns (bytes memory) {
        return OFTComposeMsgCodec.encode(nonce++, _hop.srcEid, _amount, _composeMsg(_hop, _composeFrom));
    }

    function _composeMsg(HopMessage memory _hop, address _composeFrom) internal pure returns (bytes memory) {
        return abi.encodePacked(bytes32(uint256(uint160(_composeFrom))), abi.encode(_hop));
    }

    /// @dev Simulates the adapter credit that lzReceive performs before lzCompose.
    function _credit(address _oft, uint256 _amount) internal {
        address token = IOFT(_oft).token();
        deal(token, HUB, IERC20(token).balanceOf(HUB) + _amount);
    }

    /// @dev Credit, then deliver the compose from the endpoint. Returns the gas the hub used.
    function _compose(
        address _oft,
        uint256 _amount,
        HopMessage memory _hop,
        address _composeFrom
    ) internal returns (uint256 gasUsed) {
        _credit(_oft, _amount);
        bytes memory message = _message(_amount, _hop, _composeFrom);
        vm.prank(ENDPOINT);
        uint256 g = gasleft();
        hop.lzCompose(_oft, bytes32(0), message, address(0), "");
        gasUsed = g - gasleft();
    }

    /// @dev Deliver a compose that is expected to revert with `_err`, without crediting first.
    function _composeExpectRevert(
        address _oft,
        HopMessage memory _hop,
        address _composeFrom,
        bytes memory _err
    ) internal {
        bytes memory message = _message(1e18, _hop, _composeFrom);
        vm.prank(ENDPOINT);
        vm.expectRevert(_err);
        hop.lzCompose(_oft, bytes32(0), message, address(0), "");
    }

    function _quote(address _oft, uint32 _dstEid, uint256 _amount, bytes memory _data) internal view returns (uint256) {
        return hop.quote(_oft, _dstEid, _userB32(), _amount, 0, _data);
    }

    function _send(
        address _oft,
        uint32 _dstEid,
        uint256 _amount,
        bytes memory _data,
        uint256 _value,
        address _refund
    ) internal {
        hop.sendOFT{ value: _value }(_oft, _dstEid, _userB32(), _amount, 0, _data, _refund);
    }

    function _sendSix(address _oft, uint32 _dstEid, uint256 _amount, uint256 _value) internal {
        hop.sendOFT{ value: _value }(_oft, _dstEid, _userB32(), _amount, 0, "");
    }

    function _decodeAmounts(bytes memory data) internal pure returns (uint256 amountIn, uint256 amountOut) {
        (amountIn, amountOut, , , ) = abi.decode(data, (uint256, uint256, uint32, uint32, bytes32));
    }

    function _findActionApplied(Vm.Log[] memory logs) internal pure returns (ActionLog memory a) {
        bytes32 sig = keccak256("ActionApplied(bytes4,address,address,uint256,uint256,uint32,uint32,bytes32)");
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] == sig && logs[i].emitter == HUB) {
                a.found = true;
                a.oftIn = address(uint160(uint256(logs[i].topics[2])));
                a.oftOut = address(uint160(uint256(logs[i].topics[3])));
                (a.amountIn, a.amountOut) = _decodeAmounts(logs[i].data);
                return a;
            }
        }
    }

    function _findHop(Vm.Log[] memory logs) internal pure returns (HopLog memory h) {
        bytes32 sig = keccak256("Hop(address,uint32,uint32,bytes32,uint256)");
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] == sig && logs[i].emitter == HUB) {
                h.found = true;
                h.dstEid = uint32(uint256(logs[i].topics[2]));
                (h.oft, h.amount) = abi.decode(logs[i].data, (address, uint256));
                return h;
            }
        }
    }

    function _pps() internal view returns (uint256) {
        return IFraxtalERC4626MintRedeemer(MINT_REDEEMER).pricePerShare();
    }

    /// @dev The converted amount matches the redeemer price (its 1e-7 fee is inside the tolerance).
    function _assertAction(
        ActionLog memory a,
        address oftIn,
        address oftOut,
        uint256 amountIn,
        uint256 expectedOut
    ) internal pure {
        assertTrue(a.found, "ActionApplied emitted");
        assertEq(a.oftIn, oftIn);
        assertEq(a.oftOut, oftOut);
        assertEq(a.amountIn, amountIn);
        assertApproxEqRel(a.amountOut, expectedOut, 0.001e18, "amount at the redeemer price");
    }

    /// @dev The Fraxtal frxUSD/sfrxUSD OFTs are mintable adapters: the dust-free output is burned on send, dust stays.
    function _assertOnlyDustLeft(address token, address oft, uint256 balBefore, uint256 amountOut) internal view {
        uint256 sent = hop.removeDust(oft, amountOut);
        assertEq(IERC20(token).balanceOf(HUB) - balBefore, amountOut - sent, "only dust stays on the hub");
        assertEq(IERC20(token).balanceOf(address(module)), 0, "module keeps nothing");
    }

    // ───────────────────────────── upgrade ─────────────────────────────

    function test_Upgrade_PreservesLiveState() public view {
        assertEq(hop.version(), "2.1.0");
        assertEq(hop.remoteHop(ARBITRUM_EID), preRemoteArb);
        assertEq(hop.remoteHop(SONIC_EID), preRemoteSonic);
        assertEq(address(uint160(uint256(preRemoteArb))), SPOKE, "spoke vanity address registered");
        assertTrue(hop.approvedOft(FRXUSD_LOCKBOX));
        assertTrue(hop.approvedOft(SFRXUSD_LOCKBOX));
        assertEq(hop.numDVNs(), preNumDVNs);
        assertEq(hop.hopFee(), preHopFee);
        FeeMultipliers memory m = hop.feeMultipliers(ARBITRUM_EID);
        assertEq(m.dvn, preMultipliers.dvn);
        assertEq(m.executor, preMultipliers.executor);
        assertEq(m.treasury, preMultipliers.treasury);
        assertEq(hop.executorOptions(ARBITRUM_EID), preExecutorOptions);
        assertEq(hop.getRoleMemberCount(bytes32(0)), preAdminCount);
        assertTrue(hop.hasRole(bytes32(0), SAFE));
        assertFalse(hop.paused());
    }

    function test_ActionModule_StorageSlot() public view {
        assertEq(hop.actionModule(), address(module));
        assertEq(vm.load(HUB, ACTION_SLOT), bytes32(uint256(uint160(address(module)))));
        // the shared HopV2 namespace is untouched by the new slot
        assertEq(
            ACTION_SLOT,
            keccak256(abi.encode(uint256(keccak256("frax.storage.FraxtalHopV201")) - 1)) & ~bytes32(uint256(0xff))
        );
    }

    function test_SetActionModule_OnlyAdmin() public {
        vm.prank(user);
        vm.expectRevert();
        hop.setActionModule(address(0));
    }

    // ───────────────────────── compose: mint / redeem ─────────────────────────

    function test_Compose_FrxUsdToSfrxUsd_BackToArbitrum() public {
        uint256 hubFrxBefore = IERC20(FRXUSD).balanceOf(HUB);
        uint256 hubSfrxBefore = IERC20(SFRXUSD).balanceOf(HUB);
        uint256 nativeBefore = HUB.balance;

        vm.recordLogs();
        uint256 gasUsed = _compose(FRXUSD_LOCKBOX, 1000e18, _hopMessage(ARBITRUM_EID, user, TAG), SPOKE);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        ActionLog memory a = _findActionApplied(logs);
        _assertAction(a, FRXUSD_LOCKBOX, SFRXUSD_LOCKBOX, 1000e18, (1000e18 * 1e18) / _pps());

        HopLog memory h = _findHop(logs);
        assertTrue(h.found, "Hop emitted");
        assertEq(h.oft, SFRXUSD_LOCKBOX, "forwarded the output OFT");
        assertEq(h.dstEid, ARBITRUM_EID);
        assertEq(h.amount, a.amountOut);

        assertEq(IERC20(FRXUSD).balanceOf(HUB), hubFrxBefore, "input fully consumed");
        _assertOnlyDustLeft(SFRXUSD, SFRXUSD_LOCKBOX, hubSfrxBefore, a.amountOut);
        assertLt(HUB.balance, nativeBefore, "return leg paid from the hub float");

        emit log_named_uint("hub lzCompose gas (frxUSD -> sfrxUSD -> Arbitrum)", gasUsed);
        assertLt(gasUsed, 1_050_000, "stay under 70% of the 1.5M compose budget");
    }

    function test_Compose_SfrxUsdToFrxUsd_BackToArbitrum() public {
        uint256 hubSfrxBefore = IERC20(SFRXUSD).balanceOf(HUB);
        uint256 hubFrxBefore = IERC20(FRXUSD).balanceOf(HUB);

        vm.recordLogs();
        uint256 gasUsed = _compose(SFRXUSD_LOCKBOX, 1000e18, _hopMessage(ARBITRUM_EID, user, TAG), SPOKE);
        ActionLog memory a = _findActionApplied(vm.getRecordedLogs());
        _assertAction(a, SFRXUSD_LOCKBOX, FRXUSD_LOCKBOX, 1000e18, (1000e18 * _pps()) / 1e18);

        assertEq(IERC20(SFRXUSD).balanceOf(HUB), hubSfrxBefore, "input fully consumed");
        _assertOnlyDustLeft(FRXUSD, FRXUSD_LOCKBOX, hubFrxBefore, a.amountOut);

        emit log_named_uint("hub lzCompose gas (sfrxUSD -> frxUSD -> Arbitrum)", gasUsed);
        assertLt(gasUsed, 1_050_000);
    }

    function test_Compose_MintRedeem_DeliveredOnFraxtal() public {
        uint256 nativeBefore = HUB.balance;

        vm.recordLogs();
        _compose(FRXUSD_LOCKBOX, 500e18, _hopMessage(FRAXTAL_EID, user, TAG), SPOKE);
        ActionLog memory a = _findActionApplied(vm.getRecordedLogs());

        assertEq(IERC20(SFRXUSD).balanceOf(user), a.amountOut, "local delivery of the full output, no dust removal");
        assertEq(HUB.balance, nativeBefore, "no LayerZero send for a Fraxtal recipient");
    }

    function test_Compose_MintRedeem_ToThirdChain() public {
        // frxUSD from Arbitrum, sfrxUSD delivered on Sonic: the destination need not be the source
        vm.recordLogs();
        _compose(FRXUSD_LOCKBOX, 100e18, _hopMessage(SONIC_EID, user, TAG), SPOKE);
        HopLog memory h = _findHop(vm.getRecordedLogs());
        assertTrue(h.found);
        assertEq(h.oft, SFRXUSD_LOCKBOX);
        assertEq(h.dstEid, SONIC_EID);
    }

    function test_Compose_Untagged_Unchanged() public {
        // a plain relay still forwards the input OFT untouched
        vm.recordLogs();
        _compose(FRXUSD_LOCKBOX, 100e18, _hopMessage(SONIC_EID, user, ""), SPOKE);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertFalse(_findActionApplied(logs).found, "no action for untagged data");
        HopLog memory h = _findHop(logs);
        assertEq(h.oft, FRXUSD_LOCKBOX);
        assertEq(h.amount, 100e18);
    }

    function test_NearMissTags_AreNotActions() public pure {
        // a 4-byte non-tag or a 32-byte payload that happens to start with the tag is composer data, not an action
        assertFalse(HopActions.isMintRedeem(hex"d71e9972"));
        assertFalse(HopActions.isMintRedeem(abi.encode(bytes4(TAG))));
        assertTrue(HopActions.isMintRedeem(TAG));
    }

    // ───────────────────────── compose: failure modes ─────────────────────────

    function test_Compose_Tag_ModuleUnset_Reverts() public {
        vm.prank(SAFE);
        hop.setActionModule(address(0));
        _credit(FRXUSD_LOCKBOX, 1e18);
        _composeExpectRevert(
            FRXUSD_LOCKBOX,
            _hopMessage(ARBITRUM_EID, user, TAG),
            SPOKE,
            abi.encodeWithSignature("ActionUnavailable()")
        );
    }

    function test_Compose_Tag_ModulePaused_Reverts() public {
        vm.prank(SAFE);
        module.setPaused(true);
        _credit(FRXUSD_LOCKBOX, 1e18);
        _composeExpectRevert(
            FRXUSD_LOCKBOX,
            _hopMessage(ARBITRUM_EID, user, TAG),
            SPOKE,
            abi.encodeWithSignature("ModulePaused()")
        );
    }

    function test_Compose_Tag_UnsupportedOft_Reverts() public {
        vm.prank(SAFE);
        hop.setApprovedOft(FRXETH_LOCKBOX, true);
        _composeExpectRevert(
            FRXETH_LOCKBOX,
            _hopMessage(ARBITRUM_EID, user, TAG),
            SPOKE,
            abi.encodeWithSignature("UnsupportedOFT()")
        );
    }

    function test_Compose_Tag_LyingModule_Reverts() public {
        LyingModuleMock liar = new LyingModuleMock(SFRXUSD_LOCKBOX);
        vm.prank(SAFE);
        hop.setActionModule(address(liar));
        _credit(FRXUSD_LOCKBOX, 1e18);
        _composeExpectRevert(
            FRXUSD_LOCKBOX,
            _hopMessage(ARBITRUM_EID, user, TAG),
            SPOKE,
            abi.encodeWithSignature("ActionOutputMismatch()")
        );
    }

    function test_Compose_ZeroRecipient_Reverts() public {
        // only an untrusted composer can craft this; spokes refuse it at the source
        _composeExpectRevert(
            FRXUSD_LOCKBOX,
            _hopMessage(ARBITRUM_EID, address(0), TAG),
            address(0xBEEF),
            abi.encodeWithSignature("ZeroRecipient()")
        );
    }

    function test_Compose_Tag_Untrusted_NeedsComposeValue() public {
        // an unregistered composer funds the second leg with compose value or the send reverts atomically
        _credit(FRXUSD_LOCKBOX, 100e18);
        uint256 hubFrxBefore = IERC20(FRXUSD).balanceOf(HUB);
        bytes memory message = _message(100e18, _hopMessage(ARBITRUM_EID, user, TAG), address(0xBEEF));

        vm.prank(ENDPOINT);
        vm.expectRevert();
        hop.lzCompose(FRXUSD_LOCKBOX, bytes32(0), message, address(0), "");
        assertEq(IERC20(FRXUSD).balanceOf(HUB), hubFrxBefore, "nothing converted on a failed compose");

        // the Fraxtal -> Arbitrum lane costs more than 5 FRAX at this block; the endpoint refunds the excess to the hub
        vm.recordLogs();
        vm.prank(ENDPOINT);
        hop.lzCompose{ value: 50 ether }(FRXUSD_LOCKBOX, bytes32(0), message, address(0), "");
        ActionLog memory a = _findActionApplied(vm.getRecordedLogs());
        assertTrue(a.found);
        assertEq(a.oftOut, SFRXUSD_LOCKBOX);
    }

    // ───────────────────────── Fraxtal-originated sends ─────────────────────────

    function test_SendOFT_Tag_FromFraxtal_RefundsToRefundTo() public {
        deal(FRXUSD, address(this), 1000e18);
        IERC20(FRXUSD).approve(HUB, 1000e18);
        uint256 hubSfrxBefore = IERC20(SFRXUSD).balanceOf(HUB);
        uint256 fee = _quote(FRXUSD_LOCKBOX, ARBITRUM_EID, 1000e18, TAG);
        assertGt(fee, 0);
        uint256 balBefore = address(this).balance;

        vm.recordLogs();
        _send(FRXUSD_LOCKBOX, ARBITRUM_EID, 1000e18, TAG, fee + 1 ether, refundTo);
        ActionLog memory a = _findActionApplied(vm.getRecordedLogs());

        _assertAction(a, FRXUSD_LOCKBOX, SFRXUSD_LOCKBOX, 1000e18, (1000e18 * 1e18) / _pps());
        assertEq(refundTo.balance, 1 ether, "excess goes to refundTo, not the caller");
        assertEq(balBefore - address(this).balance, fee + 1 ether, "caller paid quote + excess");
        assertEq(IERC20(FRXUSD).balanceOf(address(this)), 0);
        _assertOnlyDustLeft(SFRXUSD, SFRXUSD_LOCKBOX, hubSfrxBefore, a.amountOut);
    }

    function test_SendOFT_Tag_FromFraxtal_LocalConversion() public {
        deal(FRXUSD, address(this), 100e18);
        IERC20(FRXUSD).approve(HUB, 100e18);
        assertEq(_quote(FRXUSD_LOCKBOX, FRAXTAL_EID, 100e18, TAG), 0, "local, no LZ fee");

        vm.recordLogs();
        _send(FRXUSD_LOCKBOX, FRAXTAL_EID, 100e18, TAG, 0, refundTo);
        assertEq(IERC20(SFRXUSD).balanceOf(user), _findActionApplied(vm.getRecordedLogs()).amountOut);
    }

    function test_Quote_Tag_ModuleUnset_Reverts() public {
        vm.prank(SAFE);
        hop.setActionModule(address(0));
        vm.expectRevert(abi.encodeWithSignature("ActionUnavailable()"));
        _quote(FRXUSD_LOCKBOX, ARBITRUM_EID, 1e18, TAG);
    }

    function test_SendOFT_RefundTo_PlainSend() public {
        deal(FRXUSD, address(this), 20e18);
        IERC20(FRXUSD).approve(HUB, 20e18);
        uint256 fee = _quote(FRXUSD_LOCKBOX, ARBITRUM_EID, 10e18, "");

        // seven-argument form: excess to refundTo
        uint256 balBefore = address(this).balance;
        _send(FRXUSD_LOCKBOX, ARBITRUM_EID, 10e18, "", fee + 0.5 ether, refundTo);
        assertEq(refundTo.balance, 0.5 ether);
        assertEq(balBefore - address(this).balance, fee + 0.5 ether);

        // six-argument form: excess back to the caller, byte-for-byte the old behaviour
        balBefore = address(this).balance;
        _sendSix(FRXUSD_LOCKBOX, ARBITRUM_EID, 10e18, fee + 0.5 ether);
        assertEq(balBefore - address(this).balance, fee);
    }

    function test_SendOFT_ZeroRefundTo_Reverts() public {
        deal(FRXUSD, address(this), 1e18);
        IERC20(FRXUSD).approve(HUB, 1e18);
        vm.expectRevert(abi.encodeWithSignature("ZeroRefundAddress()"));
        _send(FRXUSD_LOCKBOX, ARBITRUM_EID, 1e18, "", 1 ether, address(0));
        assertEq(IERC20(FRXUSD).balanceOf(address(this)), 1e18, "nothing pulled");
    }

    function test_SendOFT_RefundTo_NonPayable_Reverts() public {
        deal(FRXUSD, address(this), 1e18);
        IERC20(FRXUSD).approve(HUB, 1e18);
        uint256 fee = _quote(FRXUSD_LOCKBOX, ARBITRUM_EID, 1e18, "");
        vm.expectRevert(abi.encodeWithSignature("RefundFailed()"));
        _send(FRXUSD_LOCKBOX, ARBITRUM_EID, 1e18, "", fee + 1, MINT_REDEEMER);
    }

    // ───────────────────────────── module ─────────────────────────────

    function test_Module_Config() public view {
        assertEq(module.hub(), HUB);
        assertEq(module.mintRedeemer(), MINT_REDEEMER);
        assertEq(module.assetOft(), FRXUSD_LOCKBOX);
        assertEq(module.shareOft(), SFRXUSD_LOCKBOX);
        assertEq(module.outputOft(HopActions.MINT_REDEEM, FRXUSD_LOCKBOX), SFRXUSD_LOCKBOX);
        assertEq(module.outputOft(HopActions.MINT_REDEEM, SFRXUSD_LOCKBOX), FRXUSD_LOCKBOX);
        assertTrue(module.hasRole(bytes32(0), SAFE));
        assertEq(module.version(), "1.0.0");
    }

    function test_Module_OnlyHub() public {
        vm.expectRevert(abi.encodeWithSignature("NotHub()"));
        module.convert(HopActions.MINT_REDEEM, FRXUSD_LOCKBOX, 1e18);
    }

    function test_Module_UnknownAction() public {
        vm.expectRevert(abi.encodeWithSignature("UnknownAction()"));
        module.outputOft(0xdeadbeef, FRXUSD_LOCKBOX);
    }

    function test_Module_HoldsNothingBetweenCalls() public {
        _compose(FRXUSD_LOCKBOX, 250e18, _hopMessage(ARBITRUM_EID, user, TAG), SPOKE);
        _compose(SFRXUSD_LOCKBOX, 250e18, _hopMessage(ARBITRUM_EID, user, TAG), SPOKE);
        assertEq(IERC20(FRXUSD).balanceOf(address(module)), 0);
        assertEq(IERC20(SFRXUSD).balanceOf(address(module)), 0);
        assertEq(IERC20(FRXUSD).allowance(HUB, address(module)), 0, "hub allowance fully consumed");
        assertEq(IERC20(SFRXUSD).allowance(HUB, address(module)), 0);
    }

    function test_Module_AdminOnly() public {
        vm.startPrank(user);
        vm.expectRevert();
        module.setPaused(true);
        vm.expectRevert();
        module.setMintRedeemer(user);
        vm.expectRevert();
        module.setOfts(FRXUSD_LOCKBOX, SFRXUSD_LOCKBOX);
        vm.stopPrank();
    }
}
