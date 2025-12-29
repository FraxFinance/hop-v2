// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import "frax-std/FraxTest.sol";
import { RemoteVaultDeposit } from "src/contracts/vault/RemoteVaultDeposit.sol";
import { RemoteVaultHop } from "src/contracts/vault/RemoteVaultHop.sol";
import { FraxUpgradeableProxy } from "frax-std/FraxUpgradeableProxy.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract RemoteVaultDepositTest is FraxTest {
    RemoteVaultDeposit vaultDeposit;
    RemoteVaultHop remoteVaultHop;

    uint32 constant VAULT_CHAIN_ID = 30_255;
    address constant VAULT_ADDRESS = 0x8EdA613EC96992D3C42BCd9aC2Ae58a92929Ceb2;
    address constant ASSET = 0xFc00000000000000000000000000000000000001;
    string constant NAME = "Test Vault Deposit";
    string constant SYMBOL = "TVD";

    address constant frxUSD = 0xe5020A6d073a794B6E7f05678707dE47986Fb0b6;

    function setUp() public {
        // Deploy RemoteVaultHop as the owner
        vm.createSelectFork(vm.envString("BASE_MAINNET_URL"), 40_000_000);

        address oft = frxUSD;
        address hop = 0x22beDD55A0D29Eb31e75C70F54fADa7Ca94339B9;
        uint32 eid = 30_184;

        bytes memory initializeArgs = abi.encodeCall(RemoteVaultHop.initialize, (frxUSD, oft, hop, eid, address(1)));
        address implementation = address(new RemoteVaultHop());
        FraxUpgradeableProxy vaultHopProxy = new FraxUpgradeableProxy(implementation, address(1), initializeArgs);
        remoteVaultHop = RemoteVaultHop(payable(address(vaultHopProxy)));

        // Deploy RemoteVaultDeposit
        address vaultDepositAddress = remoteVaultHop.addRemoteVault(VAULT_CHAIN_ID, VAULT_ADDRESS, NAME, SYMBOL);
        vaultDeposit = RemoteVaultDeposit(payable(vaultDepositAddress));

        // add mock address of Fraxtal RemoteVaultHop
        remoteVaultHop.setRemoteVaultHop(30_255, address(1));
    }

    receive() external payable {}

    // ============ Initialization Tests ============

    function test_Initialization() public {
        assertEq(vaultDeposit.name(), NAME, "Name should be set");
        assertEq(vaultDeposit.symbol(), SYMBOL, "Symbol should be set");
        assertEq(vaultDeposit.owner(), address(remoteVaultHop), "Owner should be RemoteVaultHop");
    }

    function test_CannotReinitialize() public {
        vm.expectRevert();
        vaultDeposit.initialize(VAULT_CHAIN_ID, VAULT_ADDRESS, ASSET, "New Name", "NEW");
    }

    // ============ Minting Tests ============

    function test_Mint() public {
        address recipient = address(0x123);
        uint256 amount = 100e18;

        vm.prank(address(remoteVaultHop));
        vaultDeposit.mint(recipient, amount);
        assertEq(vaultDeposit.balanceOf(recipient), amount, "Recipient should receive minted tokens");
    }

    function test_Mint_MultipleRecipients() public {
        address recipient1 = address(0x123);
        address recipient2 = address(0x456);

        vm.startPrank(address(remoteVaultHop));
        vaultDeposit.mint(recipient1, 100e18);
        vaultDeposit.mint(recipient2, 200e18);
        vm.stopPrank();
        assertEq(vaultDeposit.balanceOf(recipient1), 100e18);
        assertEq(vaultDeposit.balanceOf(recipient2), 200e18);
        assertEq(vaultDeposit.totalSupply(), 300e18);
    }

    function test_Mint_OnlyOwner() public {
        vm.prank(address(0xdead));
        vm.expectRevert();
        vaultDeposit.mint(address(0x123), 100e18);
    }

    function test_Mint_EmitsEvent() public {
        address recipient = address(0x123);
        uint256 amount = 100e18;

        vm.prank(address(remoteVaultHop));

        vm.expectEmit(true, true, true, true);
        emit RemoteVaultDeposit.Mint(recipient, amount);
        vaultDeposit.mint(recipient, amount);
    }

    // ============ Price Per Share Tests ============

    function test_PricePerShare_Initial() public {
        assertEq(vaultDeposit.pricePerShare(), 0, "Initial price per share should be 0");
    }

    function test_SetPricePerShare() public {
        uint64 timestamp = uint64(block.timestamp);
        uint128 pps = 1.1e18;

        vm.prank(vaultDeposit.owner());
        vaultDeposit.setPricePerShare(timestamp, pps);
        assertEq(vaultDeposit.pricePerShare(), pps, "Price per share should be updated");
    }

    function test_SetPricePerShare_OnlyOwner() public {
        vm.prank(address(0xdead));
        vm.expectRevert();
        vaultDeposit.setPricePerShare(uint64(block.timestamp), 1.1e18);
    }

    function test_SetPricePerShare_EmitsEvent() public {
        uint64 timestamp = uint64(block.timestamp);
        uint128 pps = 1.1e18;

        vm.prank(vaultDeposit.owner());

        vm.expectEmit(true, true, true, true);
        emit RemoteVaultDeposit.PricePerShareUpdated(timestamp, pps);
        vaultDeposit.setPricePerShare(timestamp, pps);
    }

    function test_SetPricePerShare_IgnoresOldTimestamp() public {
        uint64 timestamp1 = uint64(block.timestamp);
        uint128 pps1 = 1.1e18;
        vm.prank(vaultDeposit.owner());
        vaultDeposit.setPricePerShare(timestamp1, pps1);

        // Try to set with older timestamp
        uint64 timestamp2 = timestamp1 - 100;
        uint128 pps2 = 1.2e18;
        vm.prank(vaultDeposit.owner());
        vaultDeposit.setPricePerShare(timestamp2, pps2);

        assertEq(vaultDeposit.pricePerShare(), pps1, "Should not update with older timestamp");
    }

    function test_SetPricePerShare_IgnoresZeroPrice() public {
        vm.prank(vaultDeposit.owner());
        vaultDeposit.setPricePerShare(uint64(block.timestamp), 0);
        assertEq(vaultDeposit.pricePerShare(), 0, "Should not update with zero price");
    }

    function test_PricePerShare_Interpolation() public {
        // Set initial price
        vm.prank(vaultDeposit.owner());
        vaultDeposit.setPricePerShare(uint64(block.timestamp), 1e18);

        // Move to block 50 and set new price
        vm.roll(block.number + 50);
        vm.prank(vaultDeposit.owner());
        vaultDeposit.setPricePerShare(uint64(block.timestamp + 50), 1.1e18);

        uint256 pps = vaultDeposit.pricePerShare();
        assertEq(pps, 1e18, "Should be at previous price at update block");

        // Move to block 100 (halfway through interpolation)
        vm.roll(block.number + 50);
        pps = vaultDeposit.pricePerShare();
        assertApproxEqAbs(pps, 1.05e18, 0.01e18, "Should be halfway interpolated");

        // Move past interpolation period
        vm.roll(block.number + 100);
        pps = vaultDeposit.pricePerShare();
        assertEq(pps, 1.1e18, "Should be at new price after interpolation");
    }

    function test_PricePerShare_NegativeInterpolation() public {
        // Set initial price
        vm.prank(vaultDeposit.owner());
        vaultDeposit.setPricePerShare(uint64(block.timestamp), 1.1e18);

        // Move forward and set lower price
        vm.roll(block.number + 50);
        vm.prank(vaultDeposit.owner());
        vaultDeposit.setPricePerShare(uint64(block.timestamp + 50), 1e18);

        // Move to halfway point
        vm.roll(block.number + 50);
        uint256 pps = vaultDeposit.pricePerShare();
        assertApproxEqAbs(pps, 1.05e18, 0.01e18, "Should interpolate downward");
    }

    // ============ Transfer Tests ============

    function test_Transfer() public {
        address recipient = address(0x456);
        vm.prank(address(remoteVaultHop));
        vaultDeposit.mint(address(this), 100e18);

        vaultDeposit.transfer(recipient, 50e18);
        assertEq(vaultDeposit.balanceOf(address(this)), 50e18);
        assertEq(vaultDeposit.balanceOf(recipient), 50e18);
    }

    function test_TransferFrom() public {
        address owner = address(0x123);
        address spender = address(this);
        address recipient = address(0x456);

        vm.prank(address(remoteVaultHop));
        vaultDeposit.mint(owner, 100e18);

        vm.prank(owner);
        vaultDeposit.approve(spender, 50e18);

        vaultDeposit.transferFrom(owner, recipient, 50e18);
        assertEq(vaultDeposit.balanceOf(owner), 50e18);
        assertEq(vaultDeposit.balanceOf(recipient), 50e18);
    }

    // ============ Receive ETH Tests ============

    function test_ReceiveETH() public {
        payable(address(vaultDeposit)).call{ value: 1 ether }("");
        assertEq(address(vaultDeposit).balance, 1 ether);
    }

    // =========== lzDust Tests ============
    function test_Deposit_TrimsLzDust() public {
        // Mint some asset to this contract
        deal(frxUSD, address(this), 1e18 + 1234);
        deal(address(this), 1e18); // ETH for fees

        uint256 depositAmount = 1e18 + 1234; // include lzDust

        // Approve and deposit
        IERC20(frxUSD).approve(address(vaultDeposit), depositAmount);
        vaultDeposit.deposit{ value: 1e18 }(depositAmount, address(this));

        // Check that the dust remains with the sender
        assertEq(IERC20(frxUSD).balanceOf(address(this)), 1234, "Dust should remain with sender after deposit");
    }

    function test_Redeem_TrimsLzDust() public {
        deal(address(this), 1e18); // ETH for fees

        // Mint some vault deposit tokens to this contract
        vm.prank(address(remoteVaultHop));
        vaultDeposit.mint(address(this), 1e18 + 5678);

        uint256 redeemAmount = 1e18 + 5678; // include lzDust

        // Redeem
        vaultDeposit.redeem{ value: 1e18 }(redeemAmount, address(this));

        // Check that the correct amount of vault deposit tokens were burned
        assertEq(vaultDeposit.balanceOf(address(this)), 5678, "Correct amount of tokens should be burned");
    }
}
