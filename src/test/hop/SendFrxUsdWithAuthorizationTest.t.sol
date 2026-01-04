// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import "frax-std/FraxTest.sol";
import { SendParam, MessagingFee, IOFT } from "@fraxfinance/layerzero-v2-upgradeable/oapp/contracts/oft/interfaces/IOFT.sol";
import { OptionsBuilder } from "@fraxfinance/layerzero-v2-upgradeable/oapp/contracts/oapp/libs/OptionsBuilder.sol";
import { OFTMsgCodec } from "@layerzerolabs/oft-evm/contracts/libs/OFTMsgCodec.sol";
import { OFTComposeMsgCodec } from "@layerzerolabs/oft-evm/contracts/libs/OFTComposeMsgCodec.sol";
import { HopV2 } from "src/contracts/hop/HopV2.sol";
import { IHopComposer } from "src/contracts/interfaces/IHopComposer.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import { HopMessage, BridgeTx, Signature } from "src/contracts/interfaces/IHopV2.sol";

import { deployRemoteHopV2 } from "src/script/hop/DeployRemoteHopV2.s.sol";
import { deployFraxtalHopV2 } from "src/script/hop/DeployFraxtalHopV2.s.sol";

import { SigUtils } from "src/test/utils/SigUtils.sol";

interface IERC712 {
    function DOMAIN_SEPARATOR() external view returns (bytes32);
}

contract SendFrxUsdWithAuthorizationTest is FraxTest {
    uint256 authorizerPrivateKey = 0x41;
    address authorizer = vm.addr(authorizerPrivateKey);
    address sender = vm.addr(0xb0b);
    uint256 amount = 100e18;
    uint256 validAfter;
    uint256 validBefore;
    bytes32 nonce;
    bytes32 salt = keccak256("some salt");
    uint32 srcEid;
    uint32 dstEid;
    bytes data = "mock data string";

    address hop;
    address oft;
    address frxUsd;
    SigUtils sigUtils;

    address[] approvedOfts;

    function setUpFraxtal() public virtual {
        // TODO: update block number post frxUSD 3009 upgrade
        vm.createSelectFork(vm.envString("FRAXTAL_MAINNET_URL"), 23_464_636);

        validAfter = block.timestamp - 1;
        validBefore = block.timestamp + 1 days;
        srcEid = 30_255;
        dstEid = 30_110;

        oft = 0x96A394058E2b84A89bac9667B19661Ed003cF5D4;
        approvedOfts.push(oft); // frxUSD Lockbox
        frxUsd = 0xFc00000000000000000000000000000000000001;
        sigUtils = new SigUtils(IERC712(frxUsd).DOMAIN_SEPARATOR());
        hop = deployFraxtalHopV2(
            address(1), // proxyAdmin
            30_255, // localEid
            0x1a44076050125825900e736c501f859c50fE728c, // endpoint
            0xbf228a9131AB3BB8ca8C7a4Ad574932253D99Cd1, // gasPriceOracle
            3, // num DVNs
            0x41Bdb4aa4A63a5b2Efc531858d3118392B1A1C3d, // executor
            0xcCE466a522984415bC91338c232d98869193D46e, // dvn
            0xc1B621b18187F74c8F6D52a6F709Dd2780C09821, // treasury
            approvedOfts
        );

        // set mock remote hop
        HopV2(hop).setRemoteHop(dstEid, address(1));
        // fund sender
        deal(sender, 100 ether);
        // fund authorizer with frxUSD
        deal(frxUsd, authorizer, amount);
    }

    function setUpArbitrum() public virtual {
        vm.createSelectFork(vm.envString("ARBITRUM_MAINNET_URL"), 400_000_000);

        validAfter = block.timestamp - 1;
        validBefore = block.timestamp + 1 days;
        srcEid = 30_110;
        dstEid = 30_255;

        oft = 0x80Eede496655FB9047dd39d9f418d5483ED600df;
        approvedOfts.push(oft); // frxUSD OFT
        frxUsd = 0x80Eede496655FB9047dd39d9f418d5483ED600df;
        sigUtils = new SigUtils(IERC712(frxUsd).DOMAIN_SEPARATOR());
        hop = deployRemoteHopV2(
            address(1), // proxyAdmin
            30_110, // localEid
            0x1a44076050125825900e736c501f859c50fE728c, // endpoint
            0x639Fe6ab55C921f74e7fac1ee960C0B6293ba612, // gasPriceOracle
            bytes32(uint256(uint160(address(1)))), // mock fraxtalHop
            3, // num DVNs
            0x31CAe3B7fB82d847621859fb1585353c5720660D, // executor
            0x2f55C492897526677C5B68fb199ea31E2c126416, // dvn
            0x532410B245eB41f24Ed1179BA0f6ffD94738AE70, // treasury
            approvedOfts
        );

        // fund sender
        deal(sender, 100 ether);
        // fund authorizer with frxUSD
        deal(frxUsd, authorizer, amount);
    }

    function test_sendFrxUsdWithAuthorizationWithData_Fraxtal() public {
        setUpFraxtal();
        // sendFrxUsdWithAuthorization(data);
    }

    function test_sendFrxUsdWithAuthorizationWithoutData_Fraxtal() public {
        setUpFraxtal();
        // sendFrxUsdWithAuthorization("");
    }

    function test_sendFrxUsdWithAuthorizationWithData_Arbitrum() public {
        setUpArbitrum();
        sendFrxUsdWithAuthorization(data);
    }

    function test_sendFrxUsdWithAuthorizationWithoutData_Arbitrum() public {
        setUpArbitrum();
        sendFrxUsdWithAuthorization("");
    }

    function sendFrxUsdWithAuthorization(bytes memory _data) public {
        // build the bridge tx
        BridgeTx memory bridgeTx = BridgeTx({
            from: authorizer,
            to: hop,
            value: amount,
            validAfter: validAfter,
            validBefore: validBefore,
            salt: salt,
            srcEid: srcEid,
            dstEid: dstEid,
            dstGas: 0,
            data: _data,
            minAmountLD: 0
        });

        // generate signature
        nonce = keccak256(abi.encode(bridgeTx));
        SigUtils.Authorization memory authorization = SigUtils.Authorization({
            from: authorizer,
            to: hop,
            value: amount,
            validAfter: validAfter,
            validBefore: validBefore,
            nonce: nonce
        });
        Signature memory signature;
        (signature.v, signature.r, signature.s) = vm.sign(
            authorizerPrivateKey,
            sigUtils.getReceiveWithAuthorizationTypedDataHash(authorization)
        );

        uint256 fee = HopV2(hop).quote(oft, dstEid, bytes32(uint256(uint160(sender))), amount, 0, _data);

        vm.prank(sender);
        HopV2(hop).sendFrxUsdWithAuthorization{ value: fee }(oft, bridgeTx, signature);

        // verify balances
        assertEq(IERC20(frxUsd).balanceOf(authorizer), 0);
        assertGt(IERC20(frxUsd).balanceOf(sender), 0);
    }
}
