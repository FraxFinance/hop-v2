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
import { IExecutor } from "@fraxfinance/layerzero-v2-upgradeable/messagelib/contracts/interfaces/IExecutor.sol";

contract HopV2DirectTest is FraxTest {
    FraxtalHopV2 hop = FraxtalHopV2(payable(0xA6e5d568Fd930A70034Ee74afd22C49950047573));

    function setupBase() public {
        vm.createSelectFork(vm.envString("BASE_MAINNET_URL"), 36_233_708);
    }

    function send(
        uint32 _dstEid,
        bytes32 _to,
        uint256 _amount,
        uint256 _composeGas,
        bytes memory _composeMsg,
        uint128 _lzComposeValue
    ) public {
        IOFT frxUSD = IOFT(0xe5020A6d073a794B6E7f05678707dE47986Fb0b6);
        bytes memory options = OptionsBuilder.newOptions();
        options = OptionsBuilder.addExecutorLzComposeOption(options, 0, 1_000_000, _lzComposeValue);
        bytes memory composeMsg;
        if (_composeMsg.length == 0) {
            composeMsg = abi.encode(_to, _dstEid, 0, "");
        } else {
            if (_composeGas < 400_000) _composeGas = 400_000;
            composeMsg = abi.encode(_to, _dstEid, _composeGas, _composeMsg);
        }

        SendParam memory sendParams = SendParam({
            dstEid: 30_255, // Fraxtal Mainnet
            to: bytes32(uint256(uint160(address(hop)))),
            amountLD: _amount,
            minAmountLD: _amount,
            extraOptions: options,
            composeMsg: composeMsg,
            oftCmd: hex""
        });
        // Encode the struct to bytes for Tenderly
        MessagingFee memory fee = frxUSD.quoteSend(sendParams, false);
        console.log("fee:", fee.nativeFee);
        console.log("extraOptions");
        console.logBytes(sendParams.extraOptions);
        console.log("composeMsg");
        console.logBytes(sendParams.composeMsg);
        frxUSD.send{ value: fee.nativeFee }(sendParams, fee, address(this));
    }

    function test_sendDirect() public {
        setupBase();
        send(30_110, 0x000000000000000000000000ef387fd954e0Fd6297f2bBA7996E9D79A0d826bC, 0, 400_000, "Hello", 0.1e18);
    }

    function setupFraxtal() public {
        vm.createSelectFork(vm.envString("FRAXTAL_MAINNET_URL"), 26_211_760);
    }

    function logConfig(uint32 _eid) public view {
        IExecutor executor = IExecutor(0x2CCA08ae69E0C44b18a57Ab2A87644234dAebaE4);
        (uint64 baseGas, uint16 multiplierBps, uint128 floorMarginUSD, uint128 nativeCap) = executor.dstConfig(_eid);
        console.log("eid:", _eid);
        //console.log("baseGas:", baseGas);
        //console.log("multiplierBps:", multiplierBps);
        //console.log("floorMarginUSD:", floorMarginUSD);
        console.log("nativeCap:", nativeCap);
    }

    function test_dstConfig() public {
        setupBase();
        logConfig(30_101); // Ethereum
        logConfig(30_102); // BSC
        logConfig(30_106); // Avalanche
        logConfig(30_110); // Arbitrum
        logConfig(30_111); // Optimism
        logConfig(30_109); // Polygon
        logConfig(30_255); // Fraxtal
    }
}
