// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

import { Test } from "forge-std/Test.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import { RemoteHopV201Tempo } from "src/contracts/hop/RemoteHopV201Tempo.sol";
import { deployRemoteHopV201Tempo } from "src/script/hop/upgrade/DeployRemoteHopV201Tempo.s.sol";

contract MockERC20 is ERC20 {
    constructor() ERC20("Mock Token", "MOCK") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract RemoteHopV201TempoForkTest is Test {
    uint256 internal constant TEMPO_FORK_BLOCK = 9_234_969;

    uint32 internal constant TEMPO_EID = 30_410;
    address internal constant TEMPO_ENDPOINT = 0x20Bb7C2E2f4e5ca2B4c57060d1aE2615245dCc9C;
    address internal constant FRAXTAL_HOP = 0xe8Cd13de17CeC6FCd9dD5E0a1465Da240f951536;

    address internal constant FRXUSD_OFT = 0x00000000D61733e7A393A10A5B48c311AbE8f1E5;
    address internal constant SFRXUSD_OFT = 0x00000000fD8C4B8A413A06821456801295921a71;
    address internal constant FRXETH_OFT = 0x000000008c3930dCA540bB9B3A5D0ee78FcA9A4c;
    address internal constant SFRXETH_OFT = 0x00000000883279097A49dB1f2af954EAd0C77E3c;
    address internal constant WFRAX_OFT = 0x00000000E9CE0f293D1Ce552768b187eBA8a56D4;
    address internal constant FPI_OFT = 0x00000000bC4aEF4bA6363a437455Cb1af19e2aEb;

    address internal proxyAdmin;
    RemoteHopV201Tempo internal remoteHopTempo;
    MockERC20 internal mockToken;

    function setUp() public {
        vm.createSelectFork(_tempoRpcUrl(), TEMPO_FORK_BLOCK);

        proxyAdmin = makeAddr("proxyAdmin");
        address[] memory approvedOfts = new address[](6);
        approvedOfts[0] = FRXUSD_OFT;
        approvedOfts[1] = SFRXUSD_OFT;
        approvedOfts[2] = FRXETH_OFT;
        approvedOfts[3] = SFRXETH_OFT;
        approvedOfts[4] = WFRAX_OFT;
        approvedOfts[5] = FPI_OFT;

        vm.startPrank(0x54F9b12743A7DeeC0ea48721683cbebedC6E17bC);
        remoteHopTempo = RemoteHopV201Tempo(
            deployRemoteHopV201Tempo(
                proxyAdmin,
                TEMPO_EID,
                TEMPO_ENDPOINT,
                _toBytes32(FRAXTAL_HOP),
                1,
                address(0x1111),
                address(0x2222),
                address(0x3333),
                approvedOfts
            )
        );
        remoteHopTempo.grantRole(bytes32(0), address(this));
        vm.stopPrank();

        mockToken = new MockERC20();
    }

    function testFork_RecoverERC20() public {
        mockToken.mint(address(remoteHopTempo), 10e18);

        uint256 balanceBefore = IERC20(address(mockToken)).balanceOf(address(this));
        remoteHopTempo.recoverERC20(address(mockToken), 1e18);
        assertEq(IERC20(address(mockToken)).balanceOf(address(this)), balanceBefore + 1e18);
    }

    function testFork_RecoverERC20_NotAuthorized() public {
        mockToken.mint(address(remoteHopTempo), 10e18);

        vm.prank(address(0xdead));
        vm.expectRevert();
        remoteHopTempo.recoverERC20(address(mockToken), 1e18);
    }

    function testFork_RecoverETH_NotImplemented() public {
        vm.expectRevert(abi.encodeWithSignature("NotImplemented()"));
        remoteHopTempo.recoverETH(1 ether);
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
