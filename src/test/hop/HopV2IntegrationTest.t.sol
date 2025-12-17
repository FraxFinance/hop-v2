// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import "frax-std/FraxTest.sol";
import { FraxtalHopV2 } from "src/contracts/hop/FraxtalHopV2.sol";
import { RemoteHopV2 } from "src/contracts/hop/RemoteHopV2.sol";
import { HopMessage } from "src/contracts/interfaces/IHopV2.sol";
import { IHopComposer } from "src/contracts/interfaces/IHopComposer.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { OFTMsgCodec } from "@layerzerolabs/oft-evm/contracts/libs/OFTMsgCodec.sol";
import { OFTComposeMsgCodec } from "@layerzerolabs/oft-evm/contracts/libs/OFTComposeMsgCodec.sol";
import { deployFraxtalHopV2 } from "src/script/hop/DeployFraxtalHopV2.s.sol";
import { deployRemoteHopV2 } from "src/script/hop/DeployRemoteHopV2.s.sol";

contract HopComposer is IHopComposer {
    event Composed(uint32 srcEid, bytes32 srcAddress, address oft, uint256 amount, bytes data);
    
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

contract HopV2IntegrationTest is FraxTest {
    FraxtalHopV2 fraxtalHop;
    RemoteHopV2 arbitrumHop;
    RemoteHopV2 ethereumHop;
    
    address proxyAdmin = vm.addr(0x1);
    address constant ENDPOINT = 0x1a44076050125825900e736c501f859c50fE728c;
    address constant EXECUTOR = 0x41Bdb4aa4A63a5b2Efc531858d3118392B1A1C3d;
    address constant DVN = 0xcCE466a522984415bC91338c232d98869193D46e;
    address constant TREASURY = 0xc1B621b18187F74c8F6D52a6F709Dd2780C09821;
    
    address constant ARB_EXECUTOR = 0x31CAe3B7fB82d847621859fb1585353c5720660D;
    address constant ARB_DVN = 0x2f55C492897526677C5B68fb199ea31E2c126416;
    address constant ARB_TREASURY = 0x532410B245eB41f24Ed1179BA0f6ffD94738AE70;
    
    address constant ETH_EXECUTOR = 0x173272739Bd7Aa6e4e214714048a9fE699453059;
    address constant ETH_DVN = 0x589dEDbD617e0CBcB916A9223F4d1300c294236b;
    address constant ETH_TREASURY = 0x5ebB3f2feaA15271101a927869B3A56837e73056;
    
    address[] fraxtalOfts;
    address[] arbitrumOfts;
    address[] ethereumOfts;
    
    uint32 constant FRAXTAL_EID = 30_255;
    uint32 constant ARBITRUM_EID = 30_110;
    uint32 constant ETHEREUM_EID = 30_101;
    
    address constant FRAXTAL_FRXUSD = 0xFc00000000000000000000000000000000000001;
    address constant ARBITRUM_FRXUSD = 0x80Eede496655FB9047dd39d9f418d5483ED600df;
    address constant ETHEREUM_FRXUSD = 0x566a6442A5A6e9895B9dCA97cC7879D632c6e4B0; // Assuming address
    
    function setUpFraxtal() public {
        fraxtalOfts.push(0x96A394058E2b84A89bac9667B19661Ed003cF5D4);
        fraxtalOfts.push(0x88Aa7854D3b2dAA5e37E7Ce73A1F39669623a361);
        
        vm.createSelectFork(vm.envString("FRAXTAL_MAINNET_URL"), 23_464_636);
        fraxtalHop = FraxtalHopV2(deployFraxtalHopV2(proxyAdmin, FRAXTAL_EID, ENDPOINT, 3, EXECUTOR, DVN, TREASURY, fraxtalOfts));
        
        payable(address(fraxtalHop)).call{ value: 100 ether }("");
    }
    
    function setUpArbitrum() public {
        arbitrumOfts.push(0x80Eede496655FB9047dd39d9f418d5483ED600df);
        arbitrumOfts.push(0x5Bff88cA1442c2496f7E475E9e7786383Bc070c0);
        
        vm.createSelectFork(vm.envString("ARBITRUM_MAINNET_URL"), 316_670_752);
        arbitrumHop = RemoteHopV2(
            deployRemoteHopV2(
                proxyAdmin,
                ARBITRUM_EID,
                ENDPOINT,
                OFTMsgCodec.addressToBytes32(address(0x123)), // Placeholder
                2,
                ARB_EXECUTOR,
                ARB_DVN,
                ARB_TREASURY,
                arbitrumOfts
            )
        );
        
        payable(address(arbitrumHop)).call{ value: 100 ether }("");
    }
    
    receive() external payable {}
    
    // ============ Cross-Chain Flow Tests ============
    
    function test_Integration_FraxtalToArbitrum_SendOFT() public {
        setUpFraxtal();
        
        // Set up remote hop
        address mockArbitrumHop = address(0x999);
        fraxtalHop.setRemoteHop(ARBITRUM_EID, mockArbitrumHop);
        
        address oft = fraxtalOfts[0];
        address sender = address(0x123);
        address recipient = address(0x456);
        
        deal(FRAXTAL_FRXUSD, sender, 100e18);
        
        vm.startPrank(sender);
        IERC20(FRAXTAL_FRXUSD).approve(address(fraxtalHop), 100e18);
        
        uint256 fee = fraxtalHop.quote(oft, ARBITRUM_EID, bytes32(uint256(uint160(recipient))), 10e18, 0, "");
        vm.deal(sender, fee + 1 ether);
        
        fraxtalHop.sendOFT{ value: fee }(oft, ARBITRUM_EID, bytes32(uint256(uint160(recipient))), 10e18, 0, "");
        
        vm.stopPrank();
        
        assertEq(IERC20(FRAXTAL_FRXUSD).balanceOf(sender), 90e18, "Sender should have sent 10 tokens");
    }
    
    function test_Integration_LocalTransfer_WithCompose() public {
        setUpFraxtal();
        
        address oft = fraxtalOfts[0];
        address sender = address(0x123);
        HopComposer composer = new HopComposer();
        
        deal(FRAXTAL_FRXUSD, sender, 100e18);
        
        vm.startPrank(sender);
        IERC20(FRAXTAL_FRXUSD).approve(address(fraxtalHop), 100e18);
        
        bytes memory data = "Integration test data";
        uint256 fee = fraxtalHop.quote(oft, FRAXTAL_EID, bytes32(uint256(uint160(address(composer)))), 10e18, 0, data);
        assertEq(fee, 0, "Local transfer should have zero fee");
        
        vm.expectEmit(true, true, true, true);
        emit HopComposer.Composed(FRAXTAL_EID, bytes32(uint256(uint160(sender))), oft, 10e18, data);
        
        fraxtalHop.sendOFT(oft, FRAXTAL_EID, bytes32(uint256(uint160(address(composer)))), 10e18, 0, data);
        
        vm.stopPrank();
        
        assertEq(IERC20(FRAXTAL_FRXUSD).balanceOf(address(composer)), 10e18, "Composer should receive tokens");
    }
    
    function test_Integration_MultipleTransfers() public {
        setUpFraxtal();
        
        address oft = fraxtalOfts[0];
        address sender = address(0x123);
        address recipient1 = address(0x456);
        address recipient2 = address(0x789);
        address recipient3 = address(0xabc);
        
        deal(FRAXTAL_FRXUSD, sender, 1000e18);
        
        vm.startPrank(sender);
        IERC20(FRAXTAL_FRXUSD).approve(address(fraxtalHop), 1000e18);
        
        // Send to 3 different recipients locally
        fraxtalHop.sendOFT(oft, FRAXTAL_EID, bytes32(uint256(uint160(recipient1))), 100e18, 0, "");
        fraxtalHop.sendOFT(oft, FRAXTAL_EID, bytes32(uint256(uint160(recipient2))), 200e18, 0, "");
        fraxtalHop.sendOFT(oft, FRAXTAL_EID, bytes32(uint256(uint160(recipient3))), 300e18, 0, "");
        
        vm.stopPrank();
        
        assertEq(IERC20(FRAXTAL_FRXUSD).balanceOf(sender), 400e18, "Sender should have 400 tokens left");
        assertEq(IERC20(FRAXTAL_FRXUSD).balanceOf(recipient1), 100e18);
        assertEq(IERC20(FRAXTAL_FRXUSD).balanceOf(recipient2), 200e18);
        assertEq(IERC20(FRAXTAL_FRXUSD).balanceOf(recipient3), 300e18);
    }
    
    // ============ Edge Case Tests ============
    
    function test_Integration_ZeroAmountTransfer() public {
        setUpFraxtal();
        
        address oft = fraxtalOfts[0];
        address recipient = address(0x456);
        
        // Sending zero amount should work
        fraxtalHop.sendOFT(oft, FRAXTAL_EID, bytes32(uint256(uint160(recipient))), 0, 0, "");
        
        assertEq(IERC20(FRAXTAL_FRXUSD).balanceOf(recipient), 0, "Recipient should have 0 tokens");
    }
    
    function test_Integration_DustRemoval() public {
        setUpFraxtal();
        
        address oft = fraxtalOfts[0];
        address sender = address(0x123);
        address recipient = address(0x456);
        
        // Amount with dust
        uint256 amountWithDust = 10.123456789123456789e18;
        uint256 cleanAmount = fraxtalHop.removeDust(oft, amountWithDust);
        
        deal(FRAXTAL_FRXUSD, sender, amountWithDust);
        
        vm.startPrank(sender);
        IERC20(FRAXTAL_FRXUSD).approve(address(fraxtalHop), amountWithDust);
        
        fraxtalHop.sendOFT(oft, FRAXTAL_EID, bytes32(uint256(uint160(recipient))), amountWithDust, 0, "");
        
        vm.stopPrank();
        
        assertEq(IERC20(FRAXTAL_FRXUSD).balanceOf(recipient), cleanAmount, "Recipient should receive clean amount");
    }
    
    function test_Integration_PauseAndUnpause() public {
        setUpFraxtal();
        
        address oft = fraxtalOfts[0];
        address sender = address(0x123);
        
        deal(FRAXTAL_FRXUSD, sender, 100e18);
        
        // Pause the hop
        fraxtalHop.pauseOn();
        
        vm.startPrank(sender);
        IERC20(FRAXTAL_FRXUSD).approve(address(fraxtalHop), 100e18);
        
        // Should revert when paused
        vm.expectRevert(abi.encodeWithSignature("HopPaused()"));
        fraxtalHop.sendOFT(oft, FRAXTAL_EID, bytes32(uint256(uint160(address(this)))), 10e18, 0, "");
        
        vm.stopPrank();
        
        // Unpause
        fraxtalHop.pauseOff();
        
        vm.prank(sender);
        fraxtalHop.sendOFT(oft, FRAXTAL_EID, bytes32(uint256(uint160(address(this)))), 10e18, 0, "");
        
        assertEq(IERC20(FRAXTAL_FRXUSD).balanceOf(address(this)), 10e18, "Transfer should succeed after unpause");
    }
    
    function test_Integration_QuoteAccuracy() public {
        setUpFraxtal();
        
        address oft = fraxtalOfts[0];
        fraxtalHop.setRemoteHop(ARBITRUM_EID, address(0x999));
        
        // Quote for different scenarios
        uint256 feeNoData = fraxtalHop.quote(oft, ARBITRUM_EID, bytes32(uint256(uint160(address(this)))), 10e18, 0, "");
        uint256 feeWithData = fraxtalHop.quote(oft, ARBITRUM_EID, bytes32(uint256(uint160(address(this)))), 10e18, 500_000, "test");
        uint256 feeLocal = fraxtalHop.quote(oft, FRAXTAL_EID, bytes32(uint256(uint160(address(this)))), 10e18, 0, "");
        
        assertTrue(feeNoData > 0, "Remote transfer should have fee");
        assertTrue(feeWithData > feeNoData, "Transfer with data should cost more");
        assertEq(feeLocal, 0, "Local transfer should be free");
    }
    
    function test_Integration_SetHopFee() public {
        setUpFraxtal();
        
        address oft = fraxtalOfts[0];
        fraxtalHop.setRemoteHop(ARBITRUM_EID, address(0x999));
        
        uint256 feeInitial = fraxtalHop.quoteHop(ARBITRUM_EID, 400_000, "");
        
        // Set hop fee to 1% (100 basis points)
        fraxtalHop.setHopFee(100);
        
        uint256 feeWithHopFee = fraxtalHop.quoteHop(ARBITRUM_EID, 400_000, "");
        
        assertTrue(feeWithHopFee > feeInitial, "Fee with hop fee should be higher");
        assertApproxEqAbs(feeWithHopFee, feeInitial * 101 / 100, feeInitial / 100, "Hop fee should be ~1%");
    }
    
    // ============ Access Control Tests ============
    
    function test_Integration_AdminFunctions() public {
        setUpFraxtal();
        
        address newAdmin = address(0xadmin);
        
        // Grant admin role
        fraxtalHop.grantRole(fraxtalHop.DEFAULT_ADMIN_ROLE(), newAdmin);
        
        // New admin should be able to perform admin functions
        vm.prank(newAdmin);
        fraxtalHop.setApprovedOft(address(0x999), true);
        
        assertTrue(fraxtalHop.approvedOft(address(0x999)), "New admin should be able to set approved OFT");
    }
    
    function test_Integration_PauserRole() public {
        setUpFraxtal();
        
        address pauser = address(0xpauser);
        bytes32 pauserRole = 0x65d7a28e3265b37a6474929f336521b332c1681b933f6cb9f3376673440d862a;
        
        // Grant pauser role
        fraxtalHop.grantRole(pauserRole, pauser);
        
        // Pauser should be able to pause
        vm.prank(pauser);
        fraxtalHop.pauseOn();
        assertTrue(fraxtalHop.paused());
        
        // But pauser should not be able to unpause (only admin can)
        vm.prank(pauser);
        vm.expectRevert();
        fraxtalHop.pauseOff();
    }
    
    // ============ Error Recovery Tests ============
    
    function test_Integration_RecoverStuckETH() public {
        setUpFraxtal();
        
        // Send ETH to the hop contract
        payable(address(fraxtalHop)).call{ value: 10 ether }("");
        
        uint256 balanceBefore = address(this).balance;
        
        // Recover the stuck ETH
        fraxtalHop.recover(address(this), 5 ether, "");
        
        assertEq(address(this).balance, balanceBefore + 5 ether, "Should recover ETH");
    }
    
    function test_Integration_RecoverStuckTokens() public {
        setUpFraxtal();
        
        // Send tokens to the hop contract
        deal(FRAXTAL_FRXUSD, address(fraxtalHop), 100e18);
        
        uint256 balanceBefore = IERC20(FRAXTAL_FRXUSD).balanceOf(address(this));
        
        // Recover the stuck tokens
        bytes memory callData = abi.encodeWithSignature("transfer(address,uint256)", address(this), 50e18);
        fraxtalHop.recover(FRAXTAL_FRXUSD, 0, callData);
        
        assertEq(IERC20(FRAXTAL_FRXUSD).balanceOf(address(this)), balanceBefore + 50e18, "Should recover tokens");
    }
}
