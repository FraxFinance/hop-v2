// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import "frax-std/FraxTest.sol";
import { RemoteHopV201 } from "src/contracts/hop/RemoteHopV201.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { OFTMsgCodec } from "@layerzerolabs/oft-evm/contracts/libs/OFTMsgCodec.sol";
import { deployRemoteHopV201 } from "src/script/hop/upgrade/DeployRemoteHopV201.s.sol";

contract RemoteHopV201Test is FraxTest {
    RemoteHopV201 remoteHop;
    address proxyAdmin = vm.addr(0x1);
    address constant ENDPOINT = 0x1a44076050125825900e736c501f859c50fE728c;
    address constant EXECUTOR = 0x31CAe3B7fB82d847621859fb1585353c5720660D;
    address constant DVN = 0x2f55C492897526677C5B68fb199ea31E2c126416;
    address constant TREASURY = 0x532410B245eB41f24Ed1179BA0f6ffD94738AE70;
    address[] approvedOfts;

    uint32 constant FRAXTAL_EID = 30_255;
    uint32 constant ARBITRUM_EID = 30_110;

    /// @dev keccak256("RECOVER_ETH_ROLE")
    bytes32 constant RECOVER_ETH_ROLE = 0xfedd0e52ab05da04684e0bc204015ae57756f9c216de6f3af64eea1589a09b0e;

    address constant frxUSD = 0x80Eede496655FB9047dd39d9f418d5483ED600df;
    address fraxtalHop;

    function setUp() public {
        approvedOfts.push(0x80Eede496655FB9047dd39d9f418d5483ED600df);
        approvedOfts.push(0x5Bff88cA1442c2496f7E475E9e7786383Bc070c0);

        vm.createSelectFork(vm.envString("ARBITRUM_MAINNET_URL"), 316_670_752);
        vm.startPrank(0x54F9b12743A7DeeC0ea48721683cbebedC6E17bC);

        fraxtalHop = address(0x123);
        remoteHop = RemoteHopV201(
            deployRemoteHopV201(
                proxyAdmin,
                ARBITRUM_EID,
                ENDPOINT,
                OFTMsgCodec.addressToBytes32(fraxtalHop),
                2,
                EXECUTOR,
                DVN,
                TREASURY,
                approvedOfts
            )
        );

        remoteHop.grantRole(bytes32(0), address(this));
        vm.stopPrank();

        (bool success, ) = payable(address(remoteHop)).call{ value: 100 ether }("");
        assertTrue(success, "ETH funding failed");
    }

    receive() external payable {}

    function test_RecoverETH() public {
        deal(address(remoteHop), 10 ether);
        remoteHop.grantRole(RECOVER_ETH_ROLE, address(this));

        uint256 balanceBefore = address(this).balance;
        remoteHop.recoverETH(1 ether);
        assertEq(address(this).balance, balanceBefore + 1 ether);
    }

    function test_RecoverETH_NotAuthorized() public {
        deal(address(remoteHop), 10 ether);

        vm.expectRevert();
        remoteHop.recoverETH(1 ether);

        vm.prank(address(0xdead));
        vm.expectRevert();
        remoteHop.recoverETH(1 ether);
    }

    function test_RecoverERC20() public {
        deal(frxUSD, address(remoteHop), 10e18);

        uint256 balanceBefore = IERC20(frxUSD).balanceOf(address(this));
        remoteHop.recoverERC20(frxUSD, 1e18);
        assertEq(IERC20(frxUSD).balanceOf(address(this)), balanceBefore + 1e18);
    }

    function test_RecoverERC20_NotAuthorized() public {
        deal(frxUSD, address(remoteHop), 10e18);

        vm.prank(address(0xdead));
        vm.expectRevert();
        remoteHop.recoverERC20(frxUSD, 1e18);
    }
}
