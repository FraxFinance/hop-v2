// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import "frax-std/FraxTest.sol";
import { FraxtalHopV201 } from "src/contracts/hop/FraxtalHopV201.sol";
import { FeeMultipliers } from "src/contracts/interfaces/IHopV201.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { deployFraxtalHopV201 } from "src/script/hop/upgrade/DeployFraxtalHopV201.s.sol";

contract HopV201IntegrationTest is FraxTest {
    FraxtalHopV201 fraxtalHop;

    address proxyAdmin = vm.addr(0x1);
    address constant ENDPOINT = 0x1a44076050125825900e736c501f859c50fE728c;
    address constant EXECUTOR = 0x41Bdb4aa4A63a5b2Efc531858d3118392B1A1C3d;
    address constant DVN = 0xcCE466a522984415bC91338c232d98869193D46e;
    address constant TREASURY = 0xc1B621b18187F74c8F6D52a6F709Dd2780C09821;

    address[] fraxtalOfts;

    uint32 constant FRAXTAL_EID = 30_255;
    uint32 constant ARBITRUM_EID = 30_110;
    uint32 constant ETHEREUM_EID = 30_101;

    address constant FRAXTAL_FRXUSD = 0xFc00000000000000000000000000000000000001;

    /// @dev keccak256("RECOVER_ETH_ROLE")
    bytes32 constant RECOVER_ETH_ROLE = 0xfedd0e52ab05da04684e0bc204015ae57756f9c216de6f3af64eea1589a09b0e;

    function setUpFraxtal() public {
        fraxtalOfts.push(0x96A394058E2b84A89bac9667B19661Ed003cF5D4);
        fraxtalOfts.push(0x88Aa7854D3b2dAA5e37E7Ce73A1F39669623a361);

        vm.createSelectFork(vm.envString("FRAXTAL_MAINNET_URL"), 23_464_636);
        vm.startPrank(0x54F9b12743A7DeeC0ea48721683cbebedC6E17bC);
        fraxtalHop = FraxtalHopV201(
            deployFraxtalHopV201(proxyAdmin, FRAXTAL_EID, ENDPOINT, 3, EXECUTOR, DVN, TREASURY, fraxtalOfts)
        );
        fraxtalHop.grantRole(bytes32(0), address(this));
        vm.stopPrank();

        (bool success, ) = payable(address(fraxtalHop)).call{ value: 100 ether }("");
        assertTrue(success, "ETH funding failed");
    }

    receive() external payable {}

    function test_Integration_SetFeeMultipliers() public {
        setUpFraxtal();

        uint256 feeInitial = fraxtalHop.quoteHop(ARBITRUM_EID, 400_000, "");
        uint256 feeOtherEid = fraxtalHop.quoteHop(ETHEREUM_EID, 400_000, "");

        // Explicit 1x multipliers should leave the quote unchanged (same as unset)
        fraxtalHop.setFeeMultipliers(ARBITRUM_EID, 10_000, 10_000, 10_000);
        assertEq(fraxtalHop.quoteHop(ARBITRUM_EID, 400_000, ""), feeInitial, "1x multipliers should not change fee");

        // 2x multipliers on all components should increase the quote
        fraxtalHop.setFeeMultipliers(ARBITRUM_EID, 20_000, 20_000, 20_000);
        uint256 feeMultiplied = fraxtalHop.quoteHop(ARBITRUM_EID, 400_000, "");
        assertGt(feeMultiplied, feeInitial, "2x multipliers should increase fee");

        FeeMultipliers memory multipliers = fraxtalHop.feeMultipliers(ARBITRUM_EID);
        assertEq(multipliers.dvn, 20_000, "dvn multiplier should be stored");
        assertEq(multipliers.executor, 20_000, "executor multiplier should be stored");
        assertEq(multipliers.treasury, 20_000, "treasury multiplier should be stored");

        // Multipliers are keyed per remote EID and should not affect other chains
        assertEq(fraxtalHop.quoteHop(ETHEREUM_EID, 400_000, ""), feeOtherEid, "other EIDs should be unaffected");
    }

    function test_Integration_SetFeeMultipliers_Batch() public {
        setUpFraxtal();

        uint256 feeArbInitial = fraxtalHop.quoteHop(ARBITRUM_EID, 400_000, "");
        uint256 feeEthInitial = fraxtalHop.quoteHop(ETHEREUM_EID, 400_000, "");

        uint32[] memory eids = new uint32[](2);
        eids[0] = ARBITRUM_EID;
        eids[1] = ETHEREUM_EID;
        FeeMultipliers[] memory multipliers = new FeeMultipliers[](2);
        multipliers[0] = FeeMultipliers({ dvn: 20_000, executor: 20_000, treasury: 20_000 });
        multipliers[1] = FeeMultipliers({ dvn: 15_000, executor: 15_000, treasury: 15_000 });

        fraxtalHop.setFeeMultipliersBatch(eids, multipliers);

        assertEq(fraxtalHop.feeMultipliers(ARBITRUM_EID).dvn, 20_000, "arbitrum multipliers should be stored");
        assertEq(fraxtalHop.feeMultipliers(ETHEREUM_EID).dvn, 15_000, "ethereum multipliers should be stored");
        assertGt(fraxtalHop.quoteHop(ARBITRUM_EID, 400_000, ""), feeArbInitial, "arbitrum fee should increase");
        assertGt(fraxtalHop.quoteHop(ETHEREUM_EID, 400_000, ""), feeEthInitial, "ethereum fee should increase");
    }

    function test_Integration_SetFeeMultipliers_Batch_LengthMismatch() public {
        setUpFraxtal();

        uint32[] memory eids = new uint32[](2);
        eids[0] = ARBITRUM_EID;
        eids[1] = ETHEREUM_EID;
        FeeMultipliers[] memory multipliers = new FeeMultipliers[](1);
        multipliers[0] = FeeMultipliers({ dvn: 20_000, executor: 20_000, treasury: 20_000 });

        vm.expectRevert(abi.encodeWithSignature("LengthMismatch()"));
        fraxtalHop.setFeeMultipliersBatch(eids, multipliers);
    }

    function test_Integration_SetFeeMultipliers_NotAdmin() public {
        setUpFraxtal();

        vm.prank(address(0xdead));
        vm.expectRevert();
        fraxtalHop.setFeeMultipliers(ARBITRUM_EID, 20_000, 20_000, 20_000);

        uint32[] memory eids = new uint32[](1);
        eids[0] = ARBITRUM_EID;
        FeeMultipliers[] memory multipliers = new FeeMultipliers[](1);
        multipliers[0] = FeeMultipliers({ dvn: 20_000, executor: 20_000, treasury: 20_000 });

        vm.prank(address(0xdead));
        vm.expectRevert();
        fraxtalHop.setFeeMultipliersBatch(eids, multipliers);
    }

    function test_Integration_RecoverStuckETH() public {
        setUpFraxtal();

        // Send ETH to the hop contract
        (bool success, ) = payable(address(fraxtalHop)).call{ value: 10 ether }("");
        assertTrue(success, "ETH transfer failed");

        // Admin does not hold RECOVER_ETH_ROLE by default and must grant it explicitly
        vm.expectRevert();
        fraxtalHop.recoverETH(5 ether);
        fraxtalHop.grantRole(RECOVER_ETH_ROLE, address(this));

        uint256 balanceBefore = address(this).balance;

        // Recover the stuck ETH to the caller
        fraxtalHop.recoverETH(5 ether);

        assertEq(address(this).balance, balanceBefore + 5 ether, "Should recover ETH");
    }

    function test_Integration_RecoverStuckTokens() public {
        setUpFraxtal();

        // Send tokens to the hop contract
        deal(FRAXTAL_FRXUSD, address(fraxtalHop), 100e18);

        uint256 balanceBefore = IERC20(FRAXTAL_FRXUSD).balanceOf(address(this));

        // Recover the stuck tokens to the caller
        fraxtalHop.recoverERC20(FRAXTAL_FRXUSD, 50e18);

        assertEq(IERC20(FRAXTAL_FRXUSD).balanceOf(address(this)), balanceBefore + 50e18, "Should recover tokens");
    }
}
