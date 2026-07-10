// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import "frax-std/FraxTest.sol";
import { FraxtalHopV201 } from "src/contracts/hop/FraxtalHopV201.sol";
import { RemoteHopV201 } from "src/contracts/hop/RemoteHopV201.sol";
import { ITransparentUpgradeableProxy } from "frax-std/FraxUpgradeableProxy.sol";
import { IAccessControl } from "@openzeppelin/contracts/access/IAccessControl.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { OFTMsgCodec } from "@layerzerolabs/oft-evm/contracts/libs/OFTMsgCodec.sol";
import { deployFraxtalHopV2 } from "src/script/hop/DeployFraxtalHopV2.s.sol";
import { deployRemoteHopV2 } from "src/script/hop/DeployRemoteHopV2.s.sol";

contract HopV201RecoverTest is FraxTest {
    address constant DEPLOYER = 0x54F9b12743A7DeeC0ea48721683cbebedC6E17bC;
    address constant ENDPOINT = 0x1a44076050125825900e736c501f859c50fE728c;
    address constant EXECUTOR_FRAXTAL = 0x41Bdb4aa4A63a5b2Efc531858d3118392B1A1C3d;
    address constant DVN_FRAXTAL = 0xcCE466a522984415bC91338c232d98869193D46e;
    address constant TREASURY_FRAXTAL = 0xc1B621b18187F74c8F6D52a6F709Dd2780C09821;
    address constant EXECUTOR_ARB = 0x31CAe3B7fB82d847621859fb1585353c5720660D;
    address constant DVN_ARB = 0x2f55C492897526677C5B68fb199ea31E2c126416;
    address constant TREASURY_ARB = 0x532410B245eB41f24Ed1179BA0f6ffD94738AE70;

    address constant frxUSD_FRAXTAL = 0xFc00000000000000000000000000000000000001;
    address constant frxUSD_ARB = 0x80Eede496655FB9047dd39d9f418d5483ED600df;

    address proxyAdmin = vm.addr(0x1);
    address[] approvedOfts;

    function setUpFraxtalV201() internal returns (FraxtalHopV201) {
        approvedOfts.push(0x96A394058E2b84A89bac9667B19661Ed003cF5D4);
        approvedOfts.push(0x88Aa7854D3b2dAA5e37E7Ce73A1F39669623a361);
        approvedOfts.push(0x9aBFE1F8a999B0011ecD6116649AEe8D575F5604);
        approvedOfts.push(0x999dfAbe3b1cc2EF66eB032Eea42FeA329bBa168);
        approvedOfts.push(0xd86fBBd0c8715d2C1f40e451e5C3514e65E7576A);
        approvedOfts.push(0x75c38D46001b0F8108c4136216bd2694982C20FC);

        vm.createSelectFork(vm.envString("FRAXTAL_MAINNET_URL"), 23_464_636);

        vm.startPrank(DEPLOYER);
        address payable proxy = deployFraxtalHopV2(
            proxyAdmin,
            30_255,
            ENDPOINT,
            3,
            EXECUTOR_FRAXTAL,
            DVN_FRAXTAL,
            TREASURY_FRAXTAL,
            approvedOfts
        );
        vm.stopPrank();

        FraxtalHopV201 impl = new FraxtalHopV201();
        vm.prank(proxyAdmin);
        ITransparentUpgradeableProxy(proxy).upgradeToAndCall(address(impl), "");

        FraxtalHopV201 hop = FraxtalHopV201(proxy);
        vm.startPrank(DEPLOYER);
        hop.grantRole(hop.RECOVER_ROLE(), DEPLOYER);
        vm.stopPrank();

        return hop;
    }

    function setUpArbitrumV201() internal returns (RemoteHopV201) {
        approvedOfts.push(0x80Eede496655FB9047dd39d9f418d5483ED600df);
        approvedOfts.push(0x5Bff88cA1442c2496f7E475E9e7786383Bc070c0);
        approvedOfts.push(0x43eDD7f3831b08FE70B7555ddD373C8bF65a9050);
        approvedOfts.push(0x3Ec3849C33291a9eF4c5dB86De593EB4A37fDe45);
        approvedOfts.push(0x64445f0aecC51E94aD52d8AC56b7190e764E561a);
        approvedOfts.push(0x90581eCa9469D8D7F5D3B60f4715027aDFCf7927);

        vm.createSelectFork(vm.envString("ARBITRUM_MAINNET_URL"), 316_670_752);

        vm.startPrank(DEPLOYER);
        address payable proxy = deployRemoteHopV2(
            proxyAdmin,
            30_110,
            ENDPOINT,
            OFTMsgCodec.addressToBytes32(vm.addr(0x2)), // placeholder fraxtalHop
            2,
            EXECUTOR_ARB,
            DVN_ARB,
            TREASURY_ARB,
            approvedOfts
        );
        vm.stopPrank();

        RemoteHopV201 hop = RemoteHopV201(proxy);
        vm.startPrank(DEPLOYER);
        hop.grantRole(hop.RECOVER_ROLE(), DEPLOYER);
        vm.stopPrank();

        return hop;
    }

    // recoverERC20

    function test_FraxtalHopV201_recoverERC20() public {
        FraxtalHopV201 fraxtalHop = setUpFraxtalV201();

        address recipient = address(0xBEEF);
        uint256 amount = 1e18;
        deal(frxUSD_FRAXTAL, address(fraxtalHop), amount);

        vm.prank(DEPLOYER);
        fraxtalHop.recoverERC20(frxUSD_FRAXTAL, recipient, amount);

        assertEq(IERC20(frxUSD_FRAXTAL).balanceOf(recipient), amount);
        assertEq(IERC20(frxUSD_FRAXTAL).balanceOf(address(fraxtalHop)), 0);
    }

    function test_FraxtalHopV201_recoverERC20_nonAdmin_reverts() public {
        FraxtalHopV201 fraxtalHop = setUpFraxtalV201();

        address nonAdmin = address(0xBEEF);
        uint256 amount = 1e18;
        deal(frxUSD_FRAXTAL, address(fraxtalHop), amount);

        vm.startPrank(nonAdmin);
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector,
                nonAdmin,
                fraxtalHop.RECOVER_ROLE()
            )
        );
        fraxtalHop.recoverERC20(frxUSD_FRAXTAL, nonAdmin, amount);
        vm.stopPrank();
    }

    function test_RemoteHopV201_recoverERC20() public {
        RemoteHopV201 remoteHop = setUpArbitrumV201();

        address recipient = address(0xBEEF);
        uint256 amount = 1e18;
        deal(frxUSD_ARB, address(remoteHop), amount);

        vm.prank(DEPLOYER);
        remoteHop.recoverERC20(frxUSD_ARB, recipient, amount);

        assertEq(IERC20(frxUSD_ARB).balanceOf(recipient), amount);
        assertEq(IERC20(frxUSD_ARB).balanceOf(address(remoteHop)), 0);
    }

    function test_RemoteHopV201_recoverERC20_nonAdmin_reverts() public {
        RemoteHopV201 remoteHop = setUpArbitrumV201();

        address nonAdmin = address(0xBEEF);
        uint256 amount = 1e18;
        deal(frxUSD_ARB, address(remoteHop), amount);

        vm.startPrank(nonAdmin);
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector,
                nonAdmin,
                remoteHop.RECOVER_ROLE()
            )
        );
        remoteHop.recoverERC20(frxUSD_ARB, nonAdmin, amount);
        vm.stopPrank();
    }

    // recoverETH

    function test_FraxtalHopV201_recoverETH() public {
        FraxtalHopV201 fraxtalHop = setUpFraxtalV201();

        address recipient = address(0xBEEF);
        uint256 amount = 1 ether;
        vm.deal(address(fraxtalHop), amount);

        uint256 recipientBefore = recipient.balance;

        vm.prank(DEPLOYER);
        fraxtalHop.recoverETH(recipient, amount);

        assertEq(recipient.balance, recipientBefore + amount);
        assertEq(address(fraxtalHop).balance, 0);
    }

    function test_FraxtalHopV201_recoverETH_nonAdmin_reverts() public {
        FraxtalHopV201 fraxtalHop = setUpFraxtalV201();

        address nonAdmin = address(0xBEEF);
        uint256 amount = 1 ether;
        vm.deal(address(fraxtalHop), amount);

        vm.startPrank(nonAdmin);
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector,
                nonAdmin,
                fraxtalHop.RECOVER_ROLE()
            )
        );
        fraxtalHop.recoverETH(nonAdmin, amount);
        vm.stopPrank();
    }

    function test_RemoteHopV201_recoverETH() public {
        RemoteHopV201 remoteHop = setUpArbitrumV201();

        address recipient = address(0xBEEF);
        uint256 amount = 1 ether;
        vm.deal(address(remoteHop), amount);

        uint256 recipientBefore = recipient.balance;

        vm.prank(DEPLOYER);
        remoteHop.recoverETH(recipient, amount);

        assertEq(recipient.balance, recipientBefore + amount);
        assertEq(address(remoteHop).balance, 0);
    }

    function test_RemoteHopV201_recoverETH_nonAdmin_reverts() public {
        RemoteHopV201 remoteHop = setUpArbitrumV201();

        address nonAdmin = address(0xBEEF);
        uint256 amount = 1 ether;
        vm.deal(address(remoteHop), amount);

        vm.startPrank(nonAdmin);
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector,
                nonAdmin,
                remoteHop.RECOVER_ROLE()
            )
        );
        remoteHop.recoverETH(nonAdmin, amount);
        vm.stopPrank();
    }
}
