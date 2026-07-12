// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import "frax-std/FraxTest.sol";
import { FraxtalHopV201 } from "src/contracts/hop/FraxtalHopV201.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { deployFraxtalHopV201 } from "src/script/hop/upgrade/DeployFraxtalHopV201.s.sol";

contract FraxtalHopV201ExtendedTest is FraxTest {
    FraxtalHopV201 hop;
    address proxyAdmin = vm.addr(0x1);
    address constant ENDPOINT = 0x1a44076050125825900e736c501f859c50fE728c;
    address constant EXECUTOR = 0x41Bdb4aa4A63a5b2Efc531858d3118392B1A1C3d;
    address constant DVN = 0xcCE466a522984415bC91338c232d98869193D46e;
    address constant TREASURY = 0xc1B621b18187F74c8F6D52a6F709Dd2780C09821;
    address[] approvedOfts;

    uint32 constant FRAXTAL_EID = 30_255;
    uint32 constant ARBITRUM_EID = 30_110;
    uint32 constant ETHEREUM_EID = 30_101;

    /// @dev keccak256("RECOVER_ETH_ROLE")
    bytes32 constant RECOVER_ETH_ROLE = 0xfedd0e52ab05da04684e0bc204015ae57756f9c216de6f3af64eea1589a09b0e;

    address constant frxUSD = 0xFc00000000000000000000000000000000000001;

    function setUp() public {
        approvedOfts.push(0x96A394058E2b84A89bac9667B19661Ed003cF5D4);
        approvedOfts.push(0x88Aa7854D3b2dAA5e37E7Ce73A1F39669623a361);

        vm.createSelectFork(vm.envString("FRAXTAL_MAINNET_URL"), 23_464_636);
        vm.startPrank(0x54F9b12743A7DeeC0ea48721683cbebedC6E17bC);
        hop = FraxtalHopV201(
            deployFraxtalHopV201(proxyAdmin, FRAXTAL_EID, ENDPOINT, 3, EXECUTOR, DVN, TREASURY, approvedOfts)
        );
        hop.grantRole(bytes32(0), address(this));
        vm.stopPrank();

        // Fund the hop contract
        (bool success, ) = payable(address(hop)).call{ value: 100 ether }("");
        assertTrue(success, "ETH funding failed");
    }

    receive() external payable {}

    function test_RecoverETH() public {
        // Send some ETH to the hop contract
        deal(address(hop), 10 ether);
        hop.grantRole(RECOVER_ETH_ROLE, address(this));

        uint256 balanceBefore = address(this).balance;
        hop.recoverETH(1 ether);
        assertEq(address(this).balance, balanceBefore + 1 ether);
    }

    function test_RecoverETH_NotAuthorized() public {
        deal(address(hop), 10 ether);

        // Admin does not hold RECOVER_ETH_ROLE by default
        vm.expectRevert();
        hop.recoverETH(1 ether);

        vm.prank(address(0xdead));
        vm.expectRevert();
        hop.recoverETH(1 ether);
    }

    function test_RecoverERC20() public {
        // Send some tokens to the hop contract
        deal(frxUSD, address(hop), 10e18);

        uint256 balanceBefore = IERC20(frxUSD).balanceOf(address(this));
        hop.recoverERC20(frxUSD, 1e18);
        assertEq(IERC20(frxUSD).balanceOf(address(this)), balanceBefore + 1e18);
    }

    function test_RecoverERC20_NotAuthorized() public {
        deal(frxUSD, address(hop), 10e18);

        vm.prank(address(0xdead));
        vm.expectRevert();
        hop.recoverERC20(frxUSD, 1e18);
    }
}
