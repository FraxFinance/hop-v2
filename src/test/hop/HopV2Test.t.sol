// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import "frax-std/FraxTest.sol";
import { SendParam, MessagingFee, IOFT } from "@fraxfinance/layerzero-v2-upgradeable/oapp/contracts/oft/interfaces/IOFT.sol";
import { OptionsBuilder } from "@fraxfinance/layerzero-v2-upgradeable/oapp/contracts/oapp/libs/OptionsBuilder.sol";
import { OFTMsgCodec } from "@layerzerolabs/oft-evm/contracts/libs/OFTMsgCodec.sol";
import { OFTComposeMsgCodec } from "@layerzerolabs/oft-evm/contracts/libs/OFTComposeMsgCodec.sol";
import { FraxtalHopV2 } from "src/contracts/hop/FraxtalHopV2.sol";
import { RemoteHopV2 } from "src/contracts/hop/RemoteHopV2.sol";
import { IHopComposer } from "src/contracts/interfaces/IHopComposer.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import { HopMessage } from "src/contracts/interfaces/IHopV2.sol";

import { deployRemoteHopV2 } from "src/script/hop/DeployRemoteHopV2.s.sol";
import { deployFraxtalHopV2 } from "src/script/hop/DeployFraxtalHopV2.s.sol";

contract TestHopComposer is IHopComposer {
    event Composed(uint32 srcEid, bytes32 srcAddress, address oft, uint256 amount, bytes composeMsg);

    function hopCompose(
        uint32 _srcEid,
        bytes32 _srcAddress,
        address _oft,
        uint256 _amount,
        bytes memory _data
    ) external override {
        emit Composed(_srcEid, _srcAddress, _oft, _amount, _data);
    }
}

contract HopV2Test is FraxTest {
    FraxtalHopV2 hop;
    RemoteHopV2 remoteHop;
    address proxyAdmin = vm.addr(0x1);
    address constant ENDPOINT = 0x1a44076050125825900e736c501f859c50fE728c;
    address constant EXECUTOR = 0x41Bdb4aa4A63a5b2Efc531858d3118392B1A1C3d;
    address constant DVN = 0xcCE466a522984415bC91338c232d98869193D46e;
    address constant TREASURY = 0xc1B621b18187F74c8F6D52a6F709Dd2780C09821;
    address[] approvedOfts;

    // receive ETH
    receive() external payable {}

    event Composed(uint32 srcEid, bytes32 srcAddress, address oft, uint256 amount, bytes data);

    function setUpFraxtal() public virtual {
        approvedOfts.push(0x96A394058E2b84A89bac9667B19661Ed003cF5D4);
        approvedOfts.push(0x88Aa7854D3b2dAA5e37E7Ce73A1F39669623a361);
        approvedOfts.push(0x9aBFE1F8a999B0011ecD6116649AEe8D575F5604);
        approvedOfts.push(0x999dfAbe3b1cc2EF66eB032Eea42FeA329bBa168);
        approvedOfts.push(0xd86fBBd0c8715d2C1f40e451e5C3514e65E7576A);
        approvedOfts.push(0x75c38D46001b0F8108c4136216bd2694982C20FC);

        vm.createSelectFork(vm.envString("FRAXTAL_MAINNET_URL"), 23_464_636);
        hop = FraxtalHopV2(
            deployFraxtalHopV2(
                proxyAdmin,
                30_255,
                ENDPOINT,
                0xbf228a9131AB3BB8ca8C7a4Ad574932253D99Cd1,
                3,
                EXECUTOR,
                DVN,
                TREASURY,
                approvedOfts
            )
        );
        remoteHop = RemoteHopV2(
            deployRemoteHopV2(
                proxyAdmin,
                30_110,
                ENDPOINT,
                address(0),
                OFTMsgCodec.addressToBytes32(address(hop)),
                2,
                EXECUTOR,
                DVN,
                TREASURY,
                approvedOfts
            )
        );
        hop.setRemoteHop(30_110, address(remoteHop));
        payable(address(hop)).call{ value: 100 ether }("");
    }

    function setupArbitrum() public {
        approvedOfts.push(0x80Eede496655FB9047dd39d9f418d5483ED600df);
        approvedOfts.push(0x5Bff88cA1442c2496f7E475E9e7786383Bc070c0);
        approvedOfts.push(0x43eDD7f3831b08FE70B7555ddD373C8bF65a9050);
        approvedOfts.push(0x3Ec3849C33291a9eF4c5dB86De593EB4A37fDe45);
        approvedOfts.push(0x64445f0aecC51E94aD52d8AC56b7190e764E561a);
        approvedOfts.push(0x90581eCa9469D8D7F5D3B60f4715027aDFCf7927);

        vm.createSelectFork(vm.envString("ARBITRUM_MAINNET_URL"), 316_670_752);
        hop = FraxtalHopV2(
            deployFraxtalHopV2(proxyAdmin, 30_255, ENDPOINT, address(0), 3, EXECUTOR, DVN, TREASURY, approvedOfts)
        );
        remoteHop = RemoteHopV2(
            deployRemoteHopV2(
                proxyAdmin,
                30_110,
                ENDPOINT,
                address(0),
                OFTMsgCodec.addressToBytes32(address(hop)),
                2,
                0x31CAe3B7fB82d847621859fb1585353c5720660D,
                0x2f55C492897526677C5B68fb199ea31E2c126416,
                0x532410B245eB41f24Ed1179BA0f6ffD94738AE70,
                approvedOfts
            )
        );
    }

    function setupEthereum() public {
        approvedOfts.push(0x566a6442A5A6e9895B9dCA97cC7879D632c6e4B0);
        approvedOfts.push(0x7311CEA93ccf5f4F7b789eE31eBA5D9B9290E126);
        approvedOfts.push(0x1c1649A38f4A3c5A0c4a24070f688C525AB7D6E6);
        approvedOfts.push(0xbBc424e58ED38dd911309611ae2d7A23014Bd960);
        approvedOfts.push(0xC6F59a4fD50cAc677B51558489E03138Ac1784EC);
        approvedOfts.push(0x9033BAD7aA130a2466060A2dA71fAe2219781B4b);

        vm.createSelectFork(vm.envString("ETHEREUM_MAINNET_URL"), 22_124_047);
        hop = FraxtalHopV2(
            deployFraxtalHopV2(proxyAdmin, 30_255, ENDPOINT, address(0), 3, EXECUTOR, DVN, TREASURY, approvedOfts)
        );
        remoteHop = RemoteHopV2(
            deployRemoteHopV2(
                proxyAdmin,
                30_101,
                ENDPOINT,
                address(0),
                OFTMsgCodec.addressToBytes32(address(hop)),
                2,
                0x173272739Bd7Aa6e4e214714048a9fE699453059,
                0x589dEDbD617e0CBcB916A9223F4d1300c294236b,
                0x5ebB3f2feaA15271101a927869B3A56837e73056,
                approvedOfts
            )
        );
    }

    function test_FraxtalHop_lzCompose_SendLocal_WithoutData() public {
        setUpFraxtal();
        address _oApp = address(0x96A394058E2b84A89bac9667B19661Ed003cF5D4);
        address frxUSD = address(0xFc00000000000000000000000000000000000001);
        address sender = address(0x1234);
        address reciever = address(0x1234);
        deal(frxUSD, address(hop), 1e18);

        bytes memory data;
        bytes memory composeMsg = abi.encode(
            HopMessage({
                srcEid: remoteHop.localEid(),
                dstEid: hop.localEid(),
                dstGas: 0,
                sender: bytes32(uint256(uint160(sender))),
                recipient: OFTComposeMsgCodec.addressToBytes32(reciever),
                data: data
            })
        );
        composeMsg = abi.encodePacked(OFTComposeMsgCodec.addressToBytes32(address(remoteHop)), composeMsg);
        bytes memory message = OFTComposeMsgCodec.encode(
            0, // nonce of the origin tx (TODO: can this somehow be called?)
            remoteHop.localEid(), // source endpoint id of the transaction
            1e18, // the token amount in local decimals to credit
            composeMsg // The composed message
        );

        vm.startPrank(ENDPOINT);
        hop.lzCompose(_oApp, bytes32(0), message, address(0), "");
        vm.stopPrank();

        assertEq(IERC20(frxUSD).balanceOf(reciever), 1e18);
    }

    function test_FraxtalHop_lzCompose_SendLocal_WithData() public {
        setUpFraxtal();
        address _oApp = address(0x96A394058E2b84A89bac9667B19661Ed003cF5D4);
        address frxUSD = address(0xFc00000000000000000000000000000000000001);
        address sender = address(0x1234);
        TestHopComposer testComposer = new TestHopComposer();
        deal(frxUSD, address(hop), 1e18);

        bytes memory data = "Hello";
        bytes memory composeMsg = abi.encode(
            HopMessage({
                srcEid: remoteHop.localEid(),
                dstEid: hop.localEid(),
                dstGas: 0,
                sender: bytes32(uint256(uint160(sender))),
                recipient: OFTComposeMsgCodec.addressToBytes32(address(testComposer)),
                data: data
            })
        );
        composeMsg = abi.encodePacked(OFTComposeMsgCodec.addressToBytes32(address(remoteHop)), composeMsg);
        bytes memory message = OFTComposeMsgCodec.encode(
            0, // nonce of the origin tx (TODO: can this somehow be called?)
            remoteHop.localEid(), // source endpoint id of the transaction
            1e18, // the token amount in local decimals to credit
            composeMsg // The composed message
        );

        vm.startPrank(ENDPOINT);
        vm.expectEmit(true, true, true, true);
        emit Composed(30_110, OFTMsgCodec.addressToBytes32(address(sender)), address(_oApp), 1e18, "Hello");
        hop.lzCompose(_oApp, bytes32(0), message, address(0), "");
        vm.stopPrank();

        assertEq(IERC20(frxUSD).balanceOf(address(testComposer)), 1e18);
    }

    function test_FraxtalHop_lzCompose_SendToDestination() public {
        setUpFraxtal();
        address _oApp = address(0x96A394058E2b84A89bac9667B19661Ed003cF5D4);
        address frxUSD = address(0xFc00000000000000000000000000000000000001);
        address sender = address(0x1234);
        TestHopComposer testComposer = new TestHopComposer();
        deal(frxUSD, address(hop), 1e18);

        bytes memory data;
        bytes memory composeMsg = abi.encode(
            HopMessage({
                srcEid: hop.localEid(),
                dstEid: remoteHop.localEid(),
                dstGas: 0,
                sender: bytes32(uint256(uint160(sender))),
                recipient: OFTComposeMsgCodec.addressToBytes32(address(testComposer)),
                data: data
            })
        );
        composeMsg = abi.encodePacked(OFTComposeMsgCodec.addressToBytes32(address(remoteHop)), composeMsg);
        bytes memory message = OFTComposeMsgCodec.encode(
            0, // nonce of the origin tx (TODO: can this somehow be called?)
            remoteHop.localEid(), // source endpoint id of the transaction
            1e18, // the token amount in local decimals to credit
            composeMsg // The composed message
        );

        vm.startPrank(ENDPOINT);
        hop.lzCompose(_oApp, bytes32(0), message, address(0), "");
        vm.stopPrank();

        assertEq(IERC20(frxUSD).balanceOf(address(testComposer)), 0e18); // tokens send to other chain
    }

    function test_RemoteHop_lzCompose_SendLocal_WithoutData() public {
        setupArbitrum();
        address _oApp = address(0x80Eede496655FB9047dd39d9f418d5483ED600df);
        address frxUSD = address(0x80Eede496655FB9047dd39d9f418d5483ED600df);
        address sender = address(0x1234);
        address reciever = address(0x1234);
        deal(frxUSD, address(remoteHop), 1e18);

        bytes memory data;
        bytes memory composeMsg = abi.encode(
            HopMessage({
                srcEid: hop.localEid(),
                dstEid: remoteHop.localEid(),
                dstGas: 0,
                sender: bytes32(uint256(uint160(sender))),
                recipient: OFTComposeMsgCodec.addressToBytes32(reciever),
                data: data
            })
        );
        composeMsg = abi.encodePacked(OFTComposeMsgCodec.addressToBytes32(address(hop)), composeMsg);
        bytes memory message = OFTComposeMsgCodec.encode(
            0, // nonce of the origin tx (TODO: can this somehow be called?)
            hop.localEid(), // source endpoint id of the transaction
            1e18, // the token amount in local decimals to credit
            composeMsg // The composed message
        );

        vm.startPrank(ENDPOINT);
        remoteHop.lzCompose(_oApp, bytes32(0), message, address(0), "");
        vm.stopPrank();

        assertEq(IERC20(frxUSD).balanceOf(address(reciever)), 1e18);
    }

    function test_RemoteHop_lzCompose_SendLocal_WithData() public {
        setupArbitrum();
        address _oApp = address(0x80Eede496655FB9047dd39d9f418d5483ED600df);
        address frxUSD = address(0x80Eede496655FB9047dd39d9f418d5483ED600df);
        address sender = address(0x1234);
        TestHopComposer testComposer = new TestHopComposer();
        deal(frxUSD, address(remoteHop), 1e18);

        bytes memory data = "Hello";
        bytes memory composeMsg = abi.encode(
            HopMessage({
                srcEid: hop.localEid(),
                dstEid: remoteHop.localEid(),
                dstGas: 0,
                sender: bytes32(uint256(uint160(sender))),
                recipient: OFTComposeMsgCodec.addressToBytes32(address(testComposer)),
                data: data
            })
        );
        composeMsg = abi.encodePacked(OFTComposeMsgCodec.addressToBytes32(address(hop)), composeMsg);
        bytes memory message = OFTComposeMsgCodec.encode(
            0, // nonce of the origin tx (TODO: can this somehow be called?)
            hop.localEid(), // source endpoint id of the transaction
            1e18, // the token amount in local decimals to credit
            composeMsg // The composed message
        );

        vm.startPrank(ENDPOINT);
        vm.expectEmit(true, true, true, true);
        emit Composed(30_255, OFTMsgCodec.addressToBytes32(address(sender)), address(_oApp), 1e18, "Hello");
        remoteHop.lzCompose(_oApp, bytes32(0), message, address(0), "");
        vm.stopPrank();

        assertEq(IERC20(frxUSD).balanceOf(address(testComposer)), 1e18);
    }

    function test_FraxtalHop_lzCompose_SendLocal_UntrustedMessage() public {
        setUpFraxtal();
        address _oApp = address(0x96A394058E2b84A89bac9667B19661Ed003cF5D4);
        address frxUSD = address(0xFc00000000000000000000000000000000000001);
        address sender = address(0x1234);
        address reciever = address(0x4321);
        deal(frxUSD, address(hop), 1e18);

        bytes memory data;
        bytes memory composeMsg = abi.encode(
            HopMessage({
                srcEid: 1, // bad srcEid
                dstEid: hop.localEid(),
                dstGas: 0,
                sender: bytes32(uint256(uint160(address(0xabcde)))), // bad sender
                recipient: OFTComposeMsgCodec.addressToBytes32(reciever),
                data: data
            })
        );
        composeMsg = abi.encodePacked(OFTComposeMsgCodec.addressToBytes32(sender), composeMsg); // leads to !isTrustedHopMessage
        bytes memory message = OFTComposeMsgCodec.encode(
            0, // nonce of the origin tx (TODO: can this somehow be called?)
            remoteHop.localEid(), // source endpoint id of the transaction
            1e18, // the token amount in local decimals to credit
            composeMsg // The composed message
        );

        vm.startPrank(ENDPOINT);
        hop.lzCompose(_oApp, bytes32(0), message, address(0), "");
        vm.stopPrank();

        assertEq(IERC20(frxUSD).balanceOf(address(reciever)), 1e18);
    }

    function test_FraxtalHop_lzCompose_SendLocal_WithData_UntrustedMessage() public {
        setUpFraxtal();
        address _oApp = address(0x96A394058E2b84A89bac9667B19661Ed003cF5D4);
        address frxUSD = address(0xFc00000000000000000000000000000000000001);
        address sender = address(0x1234);
        TestHopComposer testComposer = new TestHopComposer();
        deal(frxUSD, address(hop), 1e18);

        bytes memory data = "Hello";
        bytes memory composeMsg = abi.encode(
            HopMessage({
                srcEid: 1, // bad srcEid
                dstEid: hop.localEid(),
                dstGas: 0,
                sender: bytes32(uint256(uint160(address(0xabcde)))), // bad sender
                recipient: OFTComposeMsgCodec.addressToBytes32(address(testComposer)),
                data: data
            })
        );
        composeMsg = abi.encodePacked(OFTComposeMsgCodec.addressToBytes32(sender), composeMsg); // leads to !isTrustedHopMessage
        bytes memory message = OFTComposeMsgCodec.encode(
            0, // nonce of the origin tx (TODO: can this somehow be called?)
            remoteHop.localEid(), // source endpoint id of the transaction
            1e18, // the token amount in local decimals to credit
            composeMsg // The composed message
        );

        vm.startPrank(ENDPOINT);
        vm.expectEmit(true, true, true, true);
        emit Composed(remoteHop.localEid(), OFTMsgCodec.addressToBytes32(sender), address(_oApp), 1e18, "Hello");
        hop.lzCompose(_oApp, bytes32(0), message, address(0), "");
        vm.stopPrank();

        assertEq(IERC20(frxUSD).balanceOf(address(testComposer)), 1e18);
    }

    function test_FraxtalHop_lzCompose_SendToDestination_WithData_UntrustedMessage() public {
        setUpFraxtal();
        address _oApp = address(0x96A394058E2b84A89bac9667B19661Ed003cF5D4);
        address frxUSD = address(0xFc00000000000000000000000000000000000001);
        address sender = address(0x1234);
        TestHopComposer testComposer = new TestHopComposer();
        deal(frxUSD, address(hop), 1e18);
        vm.deal(address(ENDPOINT), 100 ether);

        bytes memory data = "Hello";
        bytes memory composeMsg = abi.encode(
            HopMessage({
                srcEid: 1, // bad srcEid
                dstEid: remoteHop.localEid(),
                dstGas: 150_000,
                sender: bytes32(uint256(uint160(address(0xabcde)))), // bad sender
                recipient: OFTComposeMsgCodec.addressToBytes32(address(testComposer)),
                data: data
            })
        );
        composeMsg = abi.encodePacked(OFTComposeMsgCodec.addressToBytes32(sender), composeMsg); // leads to !isTrustedHopMessage
        bytes memory message = OFTComposeMsgCodec.encode(
            0, // nonce of the origin tx (TODO: can this somehow be called?)
            remoteHop.localEid(), // source endpoint id of the transaction
            1e18, // the token amount in local decimals to credit
            composeMsg // The composed message
        );

        vm.startPrank(ENDPOINT);
        hop.lzCompose{ value: 0.3e18 }(_oApp, bytes32(0), message, address(0), "");
        vm.stopPrank();

        assertEq(IERC20(frxUSD).balanceOf(address(hop)), 0e18); // tokens send to other chain
    }

    function test_FraxtalSendOft() public {
        setUpFraxtal();
        address _oApp = address(0x96A394058E2b84A89bac9667B19661Ed003cF5D4);
        address frxUSD = address(0xFc00000000000000000000000000000000000001);
        address sender = address(0x1234);
        address reciever = address(0x1234);
        deal(frxUSD, address(sender), 1e18);
        vm.deal(sender, 1 ether);
        vm.startPrank(sender);
        IERC20(frxUSD).approve(address(hop), 1e18);
        uint256 fee = hop.quote(_oApp, 30_110, OFTMsgCodec.addressToBytes32(address(reciever)), 1e18, 0, "");
        hop.sendOFT{ value: fee + 0.1e18 }(_oApp, 30_110, OFTMsgCodec.addressToBytes32(address(reciever)), 1e18, 0, "");
        vm.stopPrank();
        console.log("tokens:", IERC20(frxUSD).balanceOf(address(sender)));
        assertEq(IERC20(frxUSD).balanceOf(address(sender)), 0);
    }

    function test_FraxtalSendOftWithHopCompose() public {
        setUpFraxtal();
        address _oApp = address(0x96A394058E2b84A89bac9667B19661Ed003cF5D4);
        address frxUSD = address(0xFc00000000000000000000000000000000000001);
        address sender = address(0x1234);
        address reciever = address(0x1234);
        deal(frxUSD, address(sender), 1e18);
        vm.deal(sender, 1 ether);
        vm.startPrank(sender);
        IERC20(frxUSD).approve(address(hop), 1e18);
        uint256 fee = hop.quote(
            _oApp,
            30_110,
            OFTMsgCodec.addressToBytes32(address(reciever)),
            1e18,
            1_000_000,
            "Hello"
        );
        console.log("fee:", fee);
        hop.sendOFT{ value: fee + 0.1e18 }(
            _oApp,
            30_110,
            OFTMsgCodec.addressToBytes32(address(reciever)),
            1e18,
            1_000_000,
            "Hello"
        );
        vm.stopPrank();
        console.log("tokens:", IERC20(frxUSD).balanceOf(address(sender)));
        assertEq(IERC20(frxUSD).balanceOf(address(sender)), 0);
    }

    function test_ArbitrumSendOft() public {
        setupArbitrum();
        address _oApp = address(0x80Eede496655FB9047dd39d9f418d5483ED600df);
        address frxUSD = address(0x80Eede496655FB9047dd39d9f418d5483ED600df);
        address sender = address(0x1234);
        address reciever = address(0x1234);
        deal(frxUSD, address(sender), 1e18);
        vm.deal(sender, 1 ether);
        vm.startPrank(sender);
        IERC20(frxUSD).approve(address(remoteHop), 1e18);
        uint256 fee = remoteHop.quote(_oApp, 30_101, OFTMsgCodec.addressToBytes32(address(reciever)), 1e18, 0, "");
        remoteHop.sendOFT{ value: fee + 0.1e18 }(
            _oApp,
            30_101,
            OFTMsgCodec.addressToBytes32(address(reciever)),
            1e18,
            0,
            ""
        );
        vm.stopPrank();
        console.log("tokens:", IERC20(frxUSD).balanceOf(address(sender)));
        assertEq(IERC20(frxUSD).balanceOf(address(sender)), 0);
    }

    function test_ArbitrumSendOftWithHopCompose() public {
        setupArbitrum();
        address _oApp = address(0x80Eede496655FB9047dd39d9f418d5483ED600df);
        address frxUSD = address(0x80Eede496655FB9047dd39d9f418d5483ED600df);
        address sender = address(0x1234);
        address reciever = address(0x1234);
        deal(frxUSD, address(sender), 1e18);
        vm.deal(sender, 1 ether);
        vm.startPrank(sender);
        IERC20(frxUSD).approve(address(remoteHop), 1e18);
        uint256 fee = remoteHop.quote(
            _oApp,
            30_101,
            OFTMsgCodec.addressToBytes32(address(reciever)),
            1e18,
            1_000_000,
            "Hello"
        );
        remoteHop.sendOFT{ value: fee + 0.1e18 }(
            _oApp,
            30_101,
            OFTMsgCodec.addressToBytes32(address(reciever)),
            1e18,
            1_000_000,
            "Hello"
        );
        vm.stopPrank();
        console.log("tokens:", IERC20(frxUSD).balanceOf(address(sender)));
        assertEq(IERC20(frxUSD).balanceOf(address(sender)), 0);
    }

    function test_FraxtalSendOftLocal() public {
        setUpFraxtal();
        address _oApp = address(0x96A394058E2b84A89bac9667B19661Ed003cF5D4);
        address frxUSD = address(0xFc00000000000000000000000000000000000001);
        address sender = address(0x1234);
        address reciever = address(0x4321);
        deal(frxUSD, address(sender), 1e18);
        vm.deal(sender, 1 ether);
        vm.startPrank(sender);
        IERC20(frxUSD).approve(address(hop), 1e18);
        uint256 fee = hop.quote(_oApp, 30_255, OFTMsgCodec.addressToBytes32(address(reciever)), 1e18, 0, "");
        assertEq(fee, 0);
        hop.sendOFT{ value: fee + 0.1e18 }(_oApp, 30_255, OFTMsgCodec.addressToBytes32(address(reciever)), 1e18, 0, "");
        vm.stopPrank();
        console.log("tokens:", IERC20(frxUSD).balanceOf(address(sender)));
        assertEq(IERC20(frxUSD).balanceOf(address(sender)), 0);
        assertEq(IERC20(frxUSD).balanceOf(address(reciever)), 1e18);
    }

    function test_FraxtalSendOftWithHopComposeLocal() public {
        setUpFraxtal();
        address _oApp = address(0x96A394058E2b84A89bac9667B19661Ed003cF5D4);
        address frxUSD = address(0xFc00000000000000000000000000000000000001);
        address sender = address(0x1234);
        TestHopComposer testComposer = new TestHopComposer();
        deal(frxUSD, address(sender), 1e18);
        vm.deal(sender, 1 ether);
        vm.startPrank(sender);
        IERC20(frxUSD).approve(address(hop), 1e18);
        uint256 fee = hop.quote(_oApp, 30_255, OFTMsgCodec.addressToBytes32(address(testComposer)), 1e18, 0, "Hello");
        assertEq(fee, 0);
        vm.expectEmit(true, true, true, true);
        emit Composed(30_255, OFTMsgCodec.addressToBytes32(address(sender)), address(_oApp), 1e18, "Hello");
        hop.sendOFT{ value: fee + 0.1e18 }(
            _oApp,
            30_255,
            OFTMsgCodec.addressToBytes32(address(testComposer)),
            1e18,
            0,
            "Hello"
        );
        vm.stopPrank();
        console.log("tokens:", IERC20(frxUSD).balanceOf(address(sender)));
        assertEq(IERC20(frxUSD).balanceOf(address(sender)), 0);
        assertEq(IERC20(frxUSD).balanceOf(address(testComposer)), 1e18);
    }

    function test_ArbitrumSendOftLocal() public {
        setupArbitrum();
        address _oApp = address(0x80Eede496655FB9047dd39d9f418d5483ED600df);
        address frxUSD = address(0x80Eede496655FB9047dd39d9f418d5483ED600df);
        address sender = address(0x1234);
        address reciever = address(0x4321);
        deal(frxUSD, address(sender), 1e18);
        vm.deal(sender, 1 ether);
        vm.startPrank(sender);
        IERC20(frxUSD).approve(address(remoteHop), 1e18);
        uint256 fee = remoteHop.quote(_oApp, 30_110, OFTMsgCodec.addressToBytes32(address(reciever)), 1e18, 0, "");
        assertEq(fee, 0);
        remoteHop.sendOFT{ value: fee + 0.1e18 }(
            _oApp,
            30_110,
            OFTMsgCodec.addressToBytes32(address(reciever)),
            1e18,
            0,
            ""
        );
        vm.stopPrank();
        console.log("tokens:", IERC20(frxUSD).balanceOf(address(sender)));
        assertEq(IERC20(frxUSD).balanceOf(address(sender)), 0);
        assertEq(IERC20(frxUSD).balanceOf(address(reciever)), 1e18);
    }

    function test_ArbitrumSendOftWithHopComposeLocal() public {
        setupArbitrum();
        address _oApp = address(0x80Eede496655FB9047dd39d9f418d5483ED600df);
        address frxUSD = address(0x80Eede496655FB9047dd39d9f418d5483ED600df);
        address sender = address(0x1234);
        TestHopComposer testComposer = new TestHopComposer();
        deal(frxUSD, address(sender), 1e18);
        vm.deal(sender, 1 ether);
        vm.startPrank(sender);
        IERC20(frxUSD).approve(address(remoteHop), 1e18);
        uint256 fee = remoteHop.quote(
            _oApp,
            30_110,
            OFTMsgCodec.addressToBytes32(address(testComposer)),
            1e18,
            1_000_000,
            "Hello"
        );
        assertEq(fee, 0);
        vm.expectEmit(true, true, true, true);
        emit Composed(30_110, OFTMsgCodec.addressToBytes32(address(sender)), address(_oApp), 1e18, "Hello");
        remoteHop.sendOFT{ value: fee + 0.1e18 }(
            _oApp,
            30_110,
            OFTMsgCodec.addressToBytes32(address(testComposer)),
            1e18,
            1_000_000,
            "Hello"
        );
        vm.stopPrank();
        console.log("tokens:", IERC20(frxUSD).balanceOf(address(sender)));
        assertEq(IERC20(frxUSD).balanceOf(address(sender)), 0);
        assertEq(IERC20(frxUSD).balanceOf(address(testComposer)), 1e18);
    }
}
