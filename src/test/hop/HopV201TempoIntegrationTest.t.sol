// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

import { Test } from "forge-std/Test.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import { FeeMultipliers } from "src/contracts/interfaces/IHopV201.sol";
import { RemoteHopV201Tempo } from "src/contracts/hop/RemoteHopV201Tempo.sol";
import { deployRemoteHopV201Tempo } from "src/script/hop/upgrade/DeployRemoteHopV201Tempo.s.sol";

interface ISendLibraryTempo {
    function treasury() external view returns (address);
}

contract MockERC20TempoIntegration is ERC20 {
    constructor() ERC20("Mock Token", "MOCK") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract HopV201TempoIntegrationTest is Test {
    uint256 internal constant TEMPO_FORK_BLOCK = 9_234_969;

    uint32 internal constant TEMPO_EID = 30_410;
    uint32 internal constant FRAXTAL_EID = 30_255;
    uint32 internal constant ARBITRUM_EID = 30_110;
    uint32 internal constant ETHEREUM_EID = 30_101;

    address internal constant TEMPO_ENDPOINT = 0x20Bb7C2E2f4e5ca2B4c57060d1aE2615245dCc9C;
    address internal constant FRAXTAL_HOP = 0xe8Cd13de17CeC6FCd9dD5E0a1465Da240f951536;
    address internal constant SEND_LIBRARY = 0x572863d9247E52026E0892d9Cd2E519B41EdB73C;

    address internal constant EXECUTOR = 0xf851abCa1d0fD1Df8eAba6de466a102996b7d7B2;
    address internal constant DVN = 0x76FaFF60799021B301B45dC1BbEDE53F261F9961;

    address internal constant FRXUSD_OFT = 0x00000000D61733e7A393A10A5B48c311AbE8f1E5;
    address internal constant SFRXUSD_OFT = 0x00000000fD8C4B8A413A06821456801295921a71;
    address internal constant FRXETH_OFT = 0x000000008c3930dCA540bB9B3A5D0ee78FcA9A4c;
    address internal constant SFRXETH_OFT = 0x00000000883279097A49dB1f2af954EAd0C77E3c;
    address internal constant WFRAX_OFT = 0x00000000E9CE0f293D1Ce552768b187eBA8a56D4;
    address internal constant FPI_OFT = 0x00000000bC4aEF4bA6363a437455Cb1af19e2aEb;

    address internal proxyAdmin;
    RemoteHopV201Tempo internal tempoHop;
    MockERC20TempoIntegration internal mockToken;

    function setUpTempo() public {
        vm.createSelectFork(_tempoRpcUrl(), TEMPO_FORK_BLOCK);

        proxyAdmin = makeAddr("proxyAdmin");
        address[] memory approvedOfts = new address[](6);
        approvedOfts[0] = FRXUSD_OFT;
        approvedOfts[1] = SFRXUSD_OFT;
        approvedOfts[2] = FRXETH_OFT;
        approvedOfts[3] = SFRXETH_OFT;
        approvedOfts[4] = WFRAX_OFT;
        approvedOfts[5] = FPI_OFT;

        address treasury = ISendLibraryTempo(SEND_LIBRARY).treasury();

        vm.startPrank(0x54F9b12743A7DeeC0ea48721683cbebedC6E17bC);
        tempoHop = RemoteHopV201Tempo(
            deployRemoteHopV201Tempo(
                proxyAdmin,
                TEMPO_EID,
                TEMPO_ENDPOINT,
                _toBytes32(FRAXTAL_HOP),
                3,
                EXECUTOR,
                DVN,
                treasury,
                approvedOfts
            )
        );
        tempoHop.grantRole(bytes32(0), address(this));
        vm.stopPrank();

        mockToken = new MockERC20TempoIntegration();
    }

    function test_Integration_SetFeeMultipliers() public {
        setUpTempo();

        uint256 feeInitial = tempoHop.quoteHop(ARBITRUM_EID, 400_000, "");
        uint256 feeOtherEid = tempoHop.quoteHop(ETHEREUM_EID, 400_000, "");

        tempoHop.setFeeMultipliers(ARBITRUM_EID, 10_000, 10_000, 10_000);
        assertEq(tempoHop.quoteHop(ARBITRUM_EID, 400_000, ""), feeInitial, "1x multipliers should not change fee");

        tempoHop.setFeeMultipliers(ARBITRUM_EID, 20_000, 20_000, 20_000);
        uint256 feeMultiplied = tempoHop.quoteHop(ARBITRUM_EID, 400_000, "");
        assertGt(feeMultiplied, feeInitial, "2x multipliers should increase fee");

        FeeMultipliers memory multipliers = tempoHop.feeMultipliers(ARBITRUM_EID);
        assertEq(multipliers.dvn, 20_000, "dvn multiplier should be stored");
        assertEq(multipliers.executor, 20_000, "executor multiplier should be stored");
        assertEq(multipliers.treasury, 20_000, "treasury multiplier should be stored");

        assertEq(tempoHop.quoteHop(ETHEREUM_EID, 400_000, ""), feeOtherEid, "other EIDs should be unaffected");
    }

    function test_Integration_SetFeeMultipliers_Batch() public {
        setUpTempo();

        uint256 feeArbInitial = tempoHop.quoteHop(ARBITRUM_EID, 400_000, "");
        uint256 feeEthInitial = tempoHop.quoteHop(ETHEREUM_EID, 400_000, "");

        uint32[] memory eids = new uint32[](2);
        eids[0] = ARBITRUM_EID;
        eids[1] = ETHEREUM_EID;

        FeeMultipliers[] memory multipliers = new FeeMultipliers[](2);
        multipliers[0] = FeeMultipliers({ dvn: 20_000, executor: 20_000, treasury: 20_000 });
        multipliers[1] = FeeMultipliers({ dvn: 15_000, executor: 15_000, treasury: 15_000 });

        tempoHop.setFeeMultipliersBatch(eids, multipliers);

        assertEq(tempoHop.feeMultipliers(ARBITRUM_EID).dvn, 20_000, "arbitrum multipliers should be stored");
        assertEq(tempoHop.feeMultipliers(ETHEREUM_EID).dvn, 15_000, "ethereum multipliers should be stored");
        assertGt(tempoHop.quoteHop(ARBITRUM_EID, 400_000, ""), feeArbInitial, "arbitrum fee should increase");
        assertGt(tempoHop.quoteHop(ETHEREUM_EID, 400_000, ""), feeEthInitial, "ethereum fee should increase");
    }

    function test_Integration_SetFeeMultipliers_Batch_LengthMismatch() public {
        setUpTempo();

        uint32[] memory eids = new uint32[](2);
        eids[0] = ARBITRUM_EID;
        eids[1] = ETHEREUM_EID;

        FeeMultipliers[] memory multipliers = new FeeMultipliers[](1);
        multipliers[0] = FeeMultipliers({ dvn: 20_000, executor: 20_000, treasury: 20_000 });

        vm.expectRevert(abi.encodeWithSignature("LengthMismatch()"));
        tempoHop.setFeeMultipliersBatch(eids, multipliers);
    }

    function test_Integration_SetFeeMultipliers_NotAdmin() public {
        setUpTempo();

        vm.prank(address(0xdead));
        vm.expectRevert();
        tempoHop.setFeeMultipliers(ARBITRUM_EID, 20_000, 20_000, 20_000);

        uint32[] memory eids = new uint32[](1);
        eids[0] = ARBITRUM_EID;

        FeeMultipliers[] memory multipliers = new FeeMultipliers[](1);
        multipliers[0] = FeeMultipliers({ dvn: 20_000, executor: 20_000, treasury: 20_000 });

        vm.prank(address(0xdead));
        vm.expectRevert();
        tempoHop.setFeeMultipliersBatch(eids, multipliers);
    }

    function test_Integration_RecoverStuckTokens() public {
        setUpTempo();

        mockToken.mint(address(tempoHop), 100e18);

        uint256 balanceBefore = IERC20(address(mockToken)).balanceOf(address(this));
        tempoHop.recoverERC20(address(mockToken), 50e18);

        assertEq(IERC20(address(mockToken)).balanceOf(address(this)), balanceBefore + 50e18, "Should recover tokens");
    }

    function test_Integration_RecoverStuckETH_NotImplemented() public {
        setUpTempo();

        vm.expectRevert(abi.encodeWithSignature("NotImplemented()"));
        tempoHop.recoverETH(5 ether);
    }

    function _toBytes32(address account) internal pure returns (bytes32) {
        return bytes32(uint256(uint160(account)));
    }

    function _tempoRpcUrl() internal view returns (string memory rpcUrl) {
        rpcUrl = vm.envOr("TEMPO_RPC_URL", string(""));
        if (bytes(rpcUrl).length == 0) rpcUrl = vm.envOr("TEMPO_MAINNET_URL", string(""));
        if (bytes(rpcUrl).length == 0) rpcUrl = vm.envOr("RPC_URL", string(""));
        require(bytes(rpcUrl).length != 0, "Tempo RPC URL not found");
    }
}
