// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import "frax-std/FraxTest.sol";
import { SendParam, MessagingFee, IOFT } from "@fraxfinance/layerzero-v2-upgradeable/oapp/contracts/oft/interfaces/IOFT.sol";
import { IHopV2 } from "src/contracts/interfaces/IHopV2.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { RemoteVaultHop } from "src/contracts/vault/RemoteVaultHop.sol";
import { RemoteVaultDeposit } from "src/contracts/vault/RemoteVaultDeposit.sol";
import { FraxUpgradeableProxy } from "frax-std/FraxUpgradeableProxy.sol";

contract RemoteVaultTest is FraxTest {
    RemoteVaultHop remoteVaultHop;
    address frxUSD;
    address oft;
    address hop;

    receive() external payable {}

    function setupBase() public {
        vm.createSelectFork(vm.envString("BASE_MAINNET_URL"), 39_600_910);
        frxUSD = 0xe5020A6d073a794B6E7f05678707dE47986Fb0b6;
        oft = frxUSD;
        hop = 0x22beDD55A0D29Eb31e75C70F54fADa7Ca94339B9;
        uint32 eid = 30_184;
        address rvdImpl = address(new RemoteVaultDeposit());
        bytes memory initializeArgs = abi.encodeCall(
            RemoteVaultHop.initialize,
            (frxUSD, oft, hop, eid, address(1), rvdImpl) // proxyAdmin
        );
        address implementation = address(new RemoteVaultHop());
        FraxUpgradeableProxy vaultHopProxy = new FraxUpgradeableProxy(
            implementation,
            address(1), // proxyAdmin
            initializeArgs
        );
        remoteVaultHop = RemoteVaultHop(payable(address(vaultHopProxy)));
        remoteVaultHop.setRemoteVaultHop(30_255, address(remoteVaultHop));
        remoteVaultHop.addRemoteVault(
            30_255,
            0x8EdA613EC96992D3C42BCd9aC2Ae58a92929Ceb2,
            "Fraxlend Interest Bearing frxUSD (Frax Share) - 9",
            "ffrxUSD(FXS)-9",
            18
        );
    }

    function setupFraxtal() public {
        vm.createSelectFork(vm.envString("FRAXTAL_MAINNET_URL"), 29_472_666);
        frxUSD = 0xFc00000000000000000000000000000000000001;
        oft = 0x96A394058E2b84A89bac9667B19661Ed003cF5D4;
        hop = 0xe8Cd13de17CeC6FCd9dD5E0a1465Da240f951536;
        uint32 eid = 30_255;
        address rvdImpl = address(new RemoteVaultDeposit());
        bytes memory initializeArgs = abi.encodeCall(
            RemoteVaultHop.initialize,
            (frxUSD, oft, hop, eid, address(1), rvdImpl) // proxyAdmin
        );
        address implementation = address(new RemoteVaultHop());
        FraxUpgradeableProxy vaultHopProxy = new FraxUpgradeableProxy(
            implementation,
            address(1), // proxyAdmin
            initializeArgs
        );
        remoteVaultHop = RemoteVaultHop(payable(address(vaultHopProxy)));
        remoteVaultHop.setRemoteVaultHop(30_184, address(remoteVaultHop));
        remoteVaultHop.setRemoteVaultHop(30_255, address(remoteVaultHop));
        remoteVaultHop.addLocalVault(
            0x8EdA613EC96992D3C42BCd9aC2Ae58a92929Ceb2,
            0x8EdA613EC96992D3C42BCd9aC2Ae58a92929Ceb2
        );
    }

    function test_depositRedeem() public {
        setupBase();
        deal(frxUSD, address(this), 10e18);
        RemoteVaultDeposit depositToken = RemoteVaultDeposit(
            remoteVaultHop.depositToken(30_255, 0x8EdA613EC96992D3C42BCd9aC2Ae58a92929Ceb2)
        );
        vm.deal(address(this), 1e18);
        IERC20(frxUSD).approve(address(depositToken), type(uint256).max);
        uint256 fee = remoteVaultHop.quote(10e18, 30_255, 0x8EdA613EC96992D3C42BCd9aC2Ae58a92929Ceb2);
        depositToken.deposit{ value: fee }(10e18);
        uint256 balance = IERC20(depositToken).balanceOf(address(this));
        console.log("Balance of deposit tokens:", balance);

        RemoteVaultHop.RemoteVaultMessage memory message = RemoteVaultHop.RemoteVaultMessage({
            action: RemoteVaultHop.Action.DepositReturn,
            userEid: 30_184,
            userAddress: address(this),
            remoteEid: 30_255,
            remoteVault: 0x8EdA613EC96992D3C42BCd9aC2Ae58a92929Ceb2,
            amount: 8.85458600678413454e18,
            remoteTimestamp: 1_759_756_961,
            pricePerShare: 885_458_600_678_000_000
        });
        vm.prank(hop);
        remoteVaultHop.hopCompose(
            30_255,
            bytes32(uint256(uint160(address(remoteVaultHop)))),
            oft,
            10e18,
            abi.encode(message)
        );

        assertEq(
            RemoteVaultDeposit(remoteVaultHop.depositToken(30_255, 0x8EdA613EC96992D3C42BCd9aC2Ae58a92929Ceb2))
                .pricePerShare(),
            885_458_600_678_000_000,
            "Price per share should be updated"
        );
        console.log(
            "Price per share:",
            RemoteVaultDeposit(remoteVaultHop.depositToken(30_255, 0x8EdA613EC96992D3C42BCd9aC2Ae58a92929Ceb2))
                .pricePerShare()
        );

        balance = IERC20(remoteVaultHop.depositToken(30_255, 0x8EdA613EC96992D3C42BCd9aC2Ae58a92929Ceb2)).balanceOf(
            address(this)
        );
        console.log("Balance of deposit tokens:", balance);

        depositToken.redeem{ value: fee }(balance);

        balance = IERC20(remoteVaultHop.depositToken(30_255, 0x8EdA613EC96992D3C42BCd9aC2Ae58a92929Ceb2)).balanceOf(
            address(this)
        );
        console.log("Balance of deposit tokens:", balance);

        message = RemoteVaultHop.RemoteVaultMessage({
            action: RemoteVaultHop.Action.RedeemReturn,
            userEid: 30_184,
            userAddress: address(this),
            remoteEid: 30_255,
            remoteVault: 0x8EdA613EC96992D3C42BCd9aC2Ae58a92929Ceb2,
            amount: 10e18,
            remoteTimestamp: 1_759_756_962,
            pricePerShare: 885_458_600_679_000_000
        });
        deal(frxUSD, address(remoteVaultHop), 10e18);
        vm.prank(hop);
        remoteVaultHop.hopCompose(
            30_255,
            bytes32(uint256(uint160(address(remoteVaultHop)))),
            oft,
            10e18,
            abi.encode(message)
        );

        assertEq(
            RemoteVaultDeposit(remoteVaultHop.depositToken(30_255, 0x8EdA613EC96992D3C42BCd9aC2Ae58a92929Ceb2))
                .pricePerShare(),
            885_458_600_678_000_000,
            "Price per share not yet updated"
        );

        balance = IERC20(frxUSD).balanceOf(address(this));
        console.log("Balance of frxUSD:", balance);

        // forward 50 blocks
        vm.roll(block.number + 50);
        assertEq(
            RemoteVaultDeposit(remoteVaultHop.depositToken(30_255, 0x8EdA613EC96992D3C42BCd9aC2Ae58a92929Ceb2))
                .pricePerShare(),
            885_458_600_678_500_000,
            "Price per share should be halfway updated"
        );

        // forward another 60 blocks
        vm.roll(block.number + 60);
        assertEq(
            RemoteVaultDeposit(remoteVaultHop.depositToken(30_255, 0x8EdA613EC96992D3C42BCd9aC2Ae58a92929Ceb2))
                .pricePerShare(),
            885_458_600_679_000_000,
            "Price per share should be fully updated"
        );
    }

    function test_remote_hopCompose() public {
        setupFraxtal();
        vm.deal(address(remoteVaultHop), 1e18);

        RemoteVaultHop.RemoteVaultMessage memory message = RemoteVaultHop.RemoteVaultMessage({
            action: RemoteVaultHop.Action.Deposit,
            userEid: 30_184,
            userAddress: address(this),
            remoteEid: 30_255,
            remoteVault: 0x8EdA613EC96992D3C42BCd9aC2Ae58a92929Ceb2,
            amount: 10e18,
            remoteTimestamp: 0,
            pricePerShare: 0
        });

        deal(frxUSD, address(remoteVaultHop), 10e18);
        vm.prank(hop);
        remoteVaultHop.hopCompose(
            30_255,
            bytes32(uint256(uint160(address(remoteVaultHop)))),
            oft,
            10e18,
            abi.encode(message)
        );

        uint256 vaultTokens = IERC20(0x8EdA613EC96992D3C42BCd9aC2Ae58a92929Ceb2).balanceOf(address(remoteVaultHop));
        console.log("vaultTokens", vaultTokens);

        message = RemoteVaultHop.RemoteVaultMessage({
            action: RemoteVaultHop.Action.Redeem,
            userEid: 30_184,
            userAddress: address(this),
            remoteEid: 30_255,
            remoteVault: 0x8EdA613EC96992D3C42BCd9aC2Ae58a92929Ceb2,
            amount: vaultTokens,
            remoteTimestamp: 0,
            pricePerShare: 0
        });
        vm.prank(hop);
        remoteVaultHop.hopCompose(
            30_255,
            bytes32(uint256(uint160(address(remoteVaultHop)))),
            oft,
            0,
            abi.encode(message)
        );

        vaultTokens = IERC20(0x8EdA613EC96992D3C42BCd9aC2Ae58a92929Ceb2).balanceOf(address(remoteVaultHop));
        console.log("vaultTokens", vaultTokens);
    }
}
