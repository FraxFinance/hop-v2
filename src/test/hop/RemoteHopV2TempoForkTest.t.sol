// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

import { Test } from "forge-std/Test.sol";
import { TransparentUpgradeableProxy } from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import { IERC20Metadata } from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import { SendParam, IOFT } from "@fraxfinance/layerzero-v2-upgradeable/oapp/contracts/oft/interfaces/IOFT.sol";
import { RemoteHopV2Tempo } from "src/contracts/hop/RemoteHopV2Tempo.sol";
import { TempoGasTokenBase } from "src/contracts/base/TempoGasTokenBase.sol";
import { StdTokens } from "tempo-std/StdTokens.sol";

interface IEndpointV2AltLike {
    function nativeToken() external view returns (address);
}

contract RemoteHopV2TempoForkTest is Test {
    uint256 internal constant TEMPO_FORK_BLOCK = 9_234_969;

    uint32 internal constant TEMPO_EID = 30_410;
    uint32 internal constant FRAXTAL_EID = 30_255;

    address internal constant TEMPO_ENDPOINT = 0x20Bb7C2E2f4e5ca2B4c57060d1aE2615245dCc9C;
    address internal constant FRAXTAL_HOP = 0xe8Cd13de17CeC6FCd9dD5E0a1465Da240f951536;

    address internal constant FRXUSD_OFT = 0x00000000D61733e7A393A10A5B48c311AbE8f1E5;
    address internal constant SFRXUSD_OFT = 0x00000000fD8C4B8A413A06821456801295921a71;
    address internal constant FRXETH_OFT = 0x000000008c3930dCA540bB9B3A5D0ee78FcA9A4c;
    address internal constant SFRXETH_OFT = 0x00000000883279097A49dB1f2af954EAd0C77E3c;
    address internal constant WFRAX_OFT = 0x00000000E9CE0f293D1Ce552768b187eBA8a56D4;
    address internal constant FPI_OFT = 0x00000000bC4aEF4bA6363a437455Cb1af19e2aEb;

    address internal proxyAdmin;
    RemoteHopV2Tempo internal remoteHopTempo;

    function setUp() public {
        vm.createSelectFork(_tempoRpcUrl(), TEMPO_FORK_BLOCK);

        proxyAdmin = makeAddr("proxyAdmin");
        remoteHopTempo = _deployRemoteHopV2Tempo();
    }

    function testFork_RemoteHopV2Tempo_UsesTempoEndpointNativeToken() public view {
        assertEq(
            address(remoteHopTempo.nativeToken()),
            IEndpointV2AltLike(TEMPO_ENDPOINT).nativeToken(),
            "native token mismatch"
        );
    }

    function testFork_RemoteHopV2Tempo_ApprovesExpectedTempoOfts() public view {
        assertTrue(remoteHopTempo.approvedOft(FRXUSD_OFT), "frxUSD OFT not approved");
        assertTrue(remoteHopTempo.approvedOft(SFRXUSD_OFT), "sfrxUSD OFT not approved");
        assertTrue(remoteHopTempo.approvedOft(FRXETH_OFT), "frxETH OFT not approved");
        assertTrue(remoteHopTempo.approvedOft(SFRXETH_OFT), "sfrxETH OFT not approved");
        assertTrue(remoteHopTempo.approvedOft(WFRAX_OFT), "WFRAX OFT not approved");
        assertTrue(remoteHopTempo.approvedOft(FPI_OFT), "FPI OFT not approved");
    }

    function testFork_RemoteHopV2Tempo_DirectQuotesMatchRealOftQuotes() public {
        _assertDirectQuoteMatchesOftQuote(FRXUSD_OFT);
        _assertDirectQuoteMatchesOftQuote(SFRXUSD_OFT);
        _assertDirectQuoteMatchesOftQuote(FRXETH_OFT);
        _assertDirectQuoteMatchesOftQuote(SFRXETH_OFT);
        _assertDirectQuoteMatchesOftQuote(WFRAX_OFT);
        _assertDirectQuoteMatchesOftQuote(FPI_OFT);
    }

    function testFork_RemoteHopV2Tempo_QuoteStaticMatchesPathUsdQuote() public {
        _assertQuoteStaticMatchesPathUsdQuote(FRXUSD_OFT);
        _assertQuoteStaticMatchesPathUsdQuote(SFRXUSD_OFT);
        _assertQuoteStaticMatchesPathUsdQuote(FRXETH_OFT);
        _assertQuoteStaticMatchesPathUsdQuote(SFRXETH_OFT);
        _assertQuoteStaticMatchesPathUsdQuote(WFRAX_OFT);
        _assertQuoteStaticMatchesPathUsdQuote(FPI_OFT);
    }

    function testFork_RemoteHopV2Tempo_SendOFTRejectsMsgValue() public {
        address user = makeAddr("msgValueUser");
        bytes32 recipient = _toBytes32(makeAddr("recipient"));
        vm.deal(user, 1 ether);

        vm.prank(user);
        (bool success, bytes memory revertData) = address(remoteHopTempo).call{ value: 1 }(
            abi.encodeCall(RemoteHopV2Tempo.sendOFT, (FRXUSD_OFT, FRAXTAL_EID, recipient, 1, 0, ""))
        );

        assertFalse(success, "sendOFT should revert when msg.value is non-zero");
        assertEq(
            revertData,
            abi.encodeWithSelector(TempoGasTokenBase.OFTAltCore__msg_value_not_zero.selector, 1),
            "unexpected revert data"
        );
    }

    function _assertDirectQuoteMatchesOftQuote(address oft) internal {
        address user = makeAddr(string.concat("quote-user-", vm.toString(oft)));
        bytes32 recipient = _toBytes32(makeAddr(string.concat("recipient-", vm.toString(oft))));
        uint256 amount = _sampleAmount(oft);
        uint256 cleanedAmount = remoteHopTempo.removeDust(oft, amount);

        SendParam memory sendParam = SendParam({
            dstEid: FRAXTAL_EID,
            to: recipient,
            amountLD: cleanedAmount,
            minAmountLD: cleanedAmount,
            extraOptions: bytes(""),
            composeMsg: bytes(""),
            oftCmd: bytes("")
        });

        uint256 oftQuote = IOFT(oft).quoteSend(sendParam, false).nativeFee;

        vm.prank(user);
        uint256 remoteHopQuote = remoteHopTempo.quote(oft, FRAXTAL_EID, recipient, amount, 0, "");

        assertGt(remoteHopQuote, 0, "direct quote should be non-zero");
        assertEq(remoteHopQuote, oftQuote, "RemoteHopV2Tempo quote mismatch");
    }

    function _assertQuoteStaticMatchesPathUsdQuote(address oft) internal {
        address user = makeAddr(string.concat("quote-static-user-", vm.toString(oft)));
        bytes32 recipient = _toBytes32(makeAddr(string.concat("quote-static-recipient-", vm.toString(oft))));
        uint256 amount = _sampleAmount(oft);

        vm.prank(user);
        uint256 nativeQuote = remoteHopTempo.quote(oft, FRAXTAL_EID, recipient, amount, 0, "");

        vm.prank(user);
        uint256 staticQuote = remoteHopTempo.quoteStatic(
            oft,
            FRAXTAL_EID,
            recipient,
            amount,
            0,
            "",
            StdTokens.PATH_USD_ADDRESS
        );

        assertEq(staticQuote, nativeQuote, "PATH_USD conversion should be 1:1 with native quote");
    }

    function _sampleAmount(address oft) internal view returns (uint256) {
        uint8 decimals = IERC20Metadata(IOFT(oft).token()).decimals();
        return 10 * (10 ** decimals);
    }

    function _deployRemoteHopV2Tempo() internal returns (RemoteHopV2Tempo deployed) {
        address[] memory approvedOfts = new address[](6);
        approvedOfts[0] = FRXUSD_OFT;
        approvedOfts[1] = SFRXUSD_OFT;
        approvedOfts[2] = FRXETH_OFT;
        approvedOfts[3] = SFRXETH_OFT;
        approvedOfts[4] = WFRAX_OFT;
        approvedOfts[5] = FPI_OFT;

        RemoteHopV2Tempo implementation = new RemoteHopV2Tempo(TEMPO_ENDPOINT);
        bytes memory initializeArgs = abi.encodeWithSignature(
            "initialize(uint32,address,bytes32,uint32,address,address,address,address[])",
            TEMPO_EID,
            TEMPO_ENDPOINT,
            _toBytes32(FRAXTAL_HOP),
            1,
            address(0x1111),
            address(0x2222),
            address(0x3333),
            approvedOfts
        );

        TransparentUpgradeableProxy proxy = new TransparentUpgradeableProxy(
            address(implementation),
            proxyAdmin,
            initializeArgs
        );

        deployed = RemoteHopV2Tempo(payable(address(proxy)));
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
