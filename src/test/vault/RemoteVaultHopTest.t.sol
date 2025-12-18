// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import "frax-std/FraxTest.sol";
import { RemoteVaultHop } from "src/contracts/vault/RemoteVaultHop.sol";
import { RemoteVaultDeposit } from "src/contracts/vault/RemoteVaultDeposit.sol";
import { FraxUpgradeableProxy } from "frax-std/FraxUpgradeableProxy.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { IHopV2 } from "src/contracts/interfaces/IHopV2.sol";

contract RemoteVaultHopTest is FraxTest {
    RemoteVaultHop remoteVaultHop;
    address frxUSD;
    address oft;
    address hop;
    uint32 eid;

    uint32 constant FRAXTAL_EID = 30_255;
    address constant VAULT_ADDRESS = 0x8EdA613EC96992D3C42BCd9aC2Ae58a92929Ceb2;

    function setUp() public {
        vm.createSelectFork(vm.envString("BASE_MAINNET_URL"), 36_482_910);

        frxUSD = 0xe5020A6d073a794B6E7f05678707dE47986Fb0b6;
        oft = frxUSD;
        hop = 0x22beDD55A0D29Eb31e75C70F54fADa7Ca94339B9;
        eid = 30_184;

        bytes memory initializeArgs = abi.encodeCall(RemoteVaultHop.initialize, (frxUSD, oft, hop, eid, address(1)));
        address implementation = address(new RemoteVaultHop());
        FraxUpgradeableProxy vaultHopProxy = new FraxUpgradeableProxy(implementation, address(1), initializeArgs);
        remoteVaultHop = RemoteVaultHop(payable(address(vaultHopProxy)));

        // Set up remote vault hop
        remoteVaultHop.setRemoteVaultHop(FRAXTAL_EID, address(remoteVaultHop));

        // Add remote vault
        remoteVaultHop.addRemoteVault(FRAXTAL_EID, VAULT_ADDRESS, "Test Vault", "TV");
    }

    receive() external payable {}

    // ============ Initialization Tests ============

    function test_Initialization() public {
        assertEq(address(remoteVaultHop.TOKEN()), frxUSD, "TOKEN should be set");
        assertEq(remoteVaultHop.OFT(), oft, "OFT should be set");
        assertEq(address(remoteVaultHop.HOP()), hop, "HOP should be set");
        assertEq(remoteVaultHop.EID(), eid, "EID should be set");
        assertTrue(
            remoteVaultHop.hasRole(remoteVaultHop.DEFAULT_ADMIN_ROLE(), address(this)),
            "Should have admin role"
        );
    }

    function test_CannotReinitialize() public {
        vm.expectRevert();
        remoteVaultHop.initialize(frxUSD, oft, hop, eid, address(1));
    }

    // ============ Remote Vault Management Tests ============

    function test_AddRemoteVault() public {
        uint32 testEid = 30_110;
        address testVault = address(0x789);

        remoteVaultHop.setRemoteVaultHop(testEid, address(remoteVaultHop));
        remoteVaultHop.addRemoteVault(testEid, testVault, "Test Vault 2", "TV2");

        RemoteVaultDeposit depositToken = remoteVaultHop.depositToken(testEid, testVault);
        assertTrue(address(depositToken) != address(0), "Deposit token should be created");
        assertEq(depositToken.name(), "Test Vault 2");
        assertEq(depositToken.symbol(), "TV2");
    }

    function test_AddRemoteVault_OnlyAdmin() public {
        vm.prank(address(0xdead));
        vm.expectRevert();
        remoteVaultHop.addRemoteVault(30_110, address(0x789), "Test", "TST");
    }

    function test_AddRemoteVault_AlreadyExists() public {
        vm.expectRevert(RemoteVaultHop.VaultExists.selector);
        remoteVaultHop.addRemoteVault(FRAXTAL_EID, VAULT_ADDRESS, "Duplicate", "DUP");
    }

    function test_AddRemoteVault_EmitsEvent() public {
        uint32 testEid = 30_110;
        address testVault = address(0x789);
        string memory name = "Test Vault";
        string memory symbol = "TV";

        remoteVaultHop.setRemoteVaultHop(testEid, address(remoteVaultHop));

        vm.expectEmit(true, true, true, true);
        emit RemoteVaultHop.RemoteVaultAdded(testEid, testVault, name, symbol);
        remoteVaultHop.addRemoteVault(testEid, testVault, name, symbol);
    }

    function test_SetRemoteVaultHop() public {
        uint32 testEid = 30_110;
        address remoteHop = address(0x999);

        remoteVaultHop.setRemoteVaultHop(testEid, remoteHop);
        assertEq(remoteVaultHop.remoteVaultHops(testEid), remoteHop);
    }

    function test_SetRemoteVaultHop_OnlyAdmin() public {
        vm.prank(address(0xdead));
        vm.expectRevert();
        remoteVaultHop.setRemoteVaultHop(30_110, address(0x999));
    }

    function test_SetRemoteVaultHop_EmitsEvent() public {
        uint32 testEid = 30_110;
        address remoteHop = address(0x999);

        vm.expectEmit(true, true, true, true);
        emit RemoteVaultHop.RemoteVaultHopSet(testEid, remoteHop);
        remoteVaultHop.setRemoteVaultHop(testEid, remoteHop);
    }

    function test_SetRemoteVaultGas() public {
        uint128 customGas = 600_000;
        remoteVaultHop.setRemoteVaultGas(FRAXTAL_EID, VAULT_ADDRESS, customGas);
        assertEq(remoteVaultHop.remoteGas(FRAXTAL_EID, VAULT_ADDRESS), customGas);
    }

    function test_SetRemoteVaultGas_OnlyAdmin() public {
        vm.prank(address(0xdead));
        vm.expectRevert();
        remoteVaultHop.setRemoteVaultGas(FRAXTAL_EID, VAULT_ADDRESS, 600_000);
    }

    function test_SetRemoteVaultGas_InvalidVault() public {
        address invalidVault = address(0x999);
        vm.expectRevert(RemoteVaultHop.InvalidVault.selector);
        remoteVaultHop.setRemoteVaultGas(FRAXTAL_EID, invalidVault, 600_000);
    }

    function test_SetRemoteVaultGas_EmitsEvent() public {
        uint128 customGas = 600_000;

        vm.expectEmit(true, true, true, true);
        emit RemoteVaultHop.RemoteGasSet(FRAXTAL_EID, VAULT_ADDRESS, customGas);
        remoteVaultHop.setRemoteVaultGas(FRAXTAL_EID, VAULT_ADDRESS, customGas);
    }

    function test_GetRemoteVaultGas_Default() public {
        uint128 gas = remoteVaultHop.getRemoteVaultGas(FRAXTAL_EID, VAULT_ADDRESS);
        assertEq(gas, remoteVaultHop.DEFAULT_REMOTE_GAS(), "Should return default gas");
    }

    function test_GetRemoteVaultGas_Custom() public {
        uint128 customGas = 600_000;
        remoteVaultHop.setRemoteVaultGas(FRAXTAL_EID, VAULT_ADDRESS, customGas);

        uint128 gas = remoteVaultHop.getRemoteVaultGas(FRAXTAL_EID, VAULT_ADDRESS);
        assertEq(gas, customGas, "Should return custom gas");
    }

    // ============ Deposit Tests ============

    function test_Deposit_InvalidCaller() public {
        vm.expectRevert(RemoteVaultHop.InvalidCaller.selector);
        remoteVaultHop.deposit{ value: 0.1 ether }(10e18, FRAXTAL_EID, VAULT_ADDRESS, address(this));
    }

    function test_Deposit_InsufficientFee() public {
        RemoteVaultDeposit depositToken = remoteVaultHop.depositToken(FRAXTAL_EID, VAULT_ADDRESS);

        deal(frxUSD, address(this), 10e18);
        IERC20(frxUSD).approve(address(depositToken), 10e18);

        vm.expectRevert();
        vm.prank(address(depositToken));
        remoteVaultHop.deposit{ value: 0 }(10e18, FRAXTAL_EID, VAULT_ADDRESS, address(this));
    }

    // ============ Redeem Tests ============

    function test_Redeem_InvalidCaller() public {
        vm.expectRevert(RemoteVaultHop.InvalidCaller.selector);
        remoteVaultHop.redeem{ value: 0.1 ether }(10e18, FRAXTAL_EID, VAULT_ADDRESS, address(this));
    }

    function test_Redeem_InsufficientFee() public {
        RemoteVaultDeposit depositToken = remoteVaultHop.depositToken(FRAXTAL_EID, VAULT_ADDRESS);

        vm.expectRevert();
        vm.prank(address(depositToken));
        remoteVaultHop.redeem{ value: 0 }(10e18, FRAXTAL_EID, VAULT_ADDRESS, address(this));
    }

    // ============ Quote Tests ============

    function test_Quote_LocalVault() public {
        uint256 fee = remoteVaultHop.quote(10e18, eid, VAULT_ADDRESS);
        assertEq(fee, 0, "Local vault should have zero fee");
    }

    // ============ HopCompose Tests ============

    function test_HopCompose_NotHop() public {
        RemoteVaultHop.RemoteVaultMessage memory message = RemoteVaultHop.RemoteVaultMessage({
            action: RemoteVaultHop.Action.Deposit,
            userEid: eid,
            userAddress: address(this),
            remoteEid: FRAXTAL_EID,
            remoteVault: VAULT_ADDRESS,
            amount: 10e18,
            remoteTimestamp: 0,
            pricePerShare: 0
        });

        vm.expectRevert(RemoteVaultHop.NotHop.selector);
        remoteVaultHop.hopCompose(
            FRAXTAL_EID,
            bytes32(uint256(uint160(address(remoteVaultHop)))),
            oft,
            10e18,
            abi.encode(message)
        );
    }

    function test_HopCompose_InvalidOFT() public {
        RemoteVaultHop.RemoteVaultMessage memory message = RemoteVaultHop.RemoteVaultMessage({
            action: RemoteVaultHop.Action.Deposit,
            userEid: eid,
            userAddress: address(this),
            remoteEid: FRAXTAL_EID,
            remoteVault: VAULT_ADDRESS,
            amount: 10e18,
            remoteTimestamp: 0,
            pricePerShare: 0
        });

        vm.prank(hop);
        vm.expectRevert(RemoteVaultHop.InvalidOFT.selector);
        remoteVaultHop.hopCompose(
            FRAXTAL_EID,
            bytes32(uint256(uint160(address(remoteVaultHop)))),
            address(0x999),
            10e18,
            abi.encode(message)
        );
    }

    function test_HopCompose_InvalidChain() public {
        uint32 invalidEid = 999;
        RemoteVaultHop.RemoteVaultMessage memory message = RemoteVaultHop.RemoteVaultMessage({
            action: RemoteVaultHop.Action.Deposit,
            userEid: eid,
            userAddress: address(this),
            remoteEid: FRAXTAL_EID,
            remoteVault: VAULT_ADDRESS,
            amount: 10e18,
            remoteTimestamp: 0,
            pricePerShare: 0
        });

        vm.prank(hop);
        vm.expectRevert(RemoteVaultHop.InvalidChain.selector);
        remoteVaultHop.hopCompose(
            invalidEid,
            bytes32(uint256(uint160(address(remoteVaultHop)))),
            oft,
            10e18,
            abi.encode(message)
        );
    }

    function test_HopCompose_Deposit_InvalidAmount() public {
        RemoteVaultHop.RemoteVaultMessage memory message = RemoteVaultHop.RemoteVaultMessage({
            action: RemoteVaultHop.Action.Deposit,
            userEid: eid,
            userAddress: address(this),
            remoteEid: FRAXTAL_EID,
            remoteVault: VAULT_ADDRESS,
            amount: 10e18,
            remoteTimestamp: 0,
            pricePerShare: 0
        });

        vm.prank(hop);
        vm.expectRevert(RemoteVaultHop.InvalidAmount.selector);
        remoteVaultHop.hopCompose(
            FRAXTAL_EID,
            bytes32(uint256(uint160(address(remoteVaultHop)))),
            oft,
            5e18, // Different amount
            abi.encode(message)
        );
    }

    function test_HopCompose_RedeemReturn_InvalidAmount() public {
        RemoteVaultHop.RemoteVaultMessage memory message = RemoteVaultHop.RemoteVaultMessage({
            action: RemoteVaultHop.Action.RedeemReturn,
            userEid: eid,
            userAddress: address(this),
            remoteEid: FRAXTAL_EID,
            remoteVault: VAULT_ADDRESS,
            amount: 10e18,
            remoteTimestamp: uint64(block.timestamp),
            pricePerShare: 1e18
        });

        vm.prank(hop);
        vm.expectRevert(RemoteVaultHop.InvalidAmount.selector);
        remoteVaultHop.hopCompose(
            FRAXTAL_EID,
            bytes32(uint256(uint160(address(remoteVaultHop)))),
            oft,
            5e18, // Different amount
            abi.encode(message)
        );
    }

    // ============ Admin Function Tests ============

    function test_Recover() public {
        deal(address(remoteVaultHop), 10 ether);

        uint256 balanceBefore = address(this).balance;
        remoteVaultHop.recover(address(this), 1 ether, "");
        assertEq(address(this).balance, balanceBefore + 1 ether);
    }

    function test_Recover_OnlyAdmin() public {
        vm.prank(address(0xdead));
        vm.expectRevert();
        remoteVaultHop.recover(address(this), 1 ether, "");
    }

    // ============ View Function Tests ============

    function test_ViewFunctions() public {
        assertEq(remoteVaultHop.remoteVaultHops(FRAXTAL_EID), address(remoteVaultHop));
        assertTrue(address(remoteVaultHop.depositToken(FRAXTAL_EID, VAULT_ADDRESS)) != address(0));
    }

    function test_RemoveDust() public view {
        // This is an internal function, but we can test it via the public interface
        // by checking that amounts are properly cleaned in deposit/redeem operations
    }

    // ============ Receive ETH Tests ============

    function test_ReceiveETH() public {
        payable(address(remoteVaultHop)).call{ value: 1 ether }("");
        assertEq(address(remoteVaultHop).balance, 1 ether);
    }
}
