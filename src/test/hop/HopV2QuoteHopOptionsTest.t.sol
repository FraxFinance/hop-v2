// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import "frax-std/FraxTest.sol";
import { TransparentUpgradeableProxy } from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";

import { FraxtalHopV2Mock } from "./mocks/FraxtalHopV2Mock.sol";
import { MockDVN } from "./mocks/MockDVN.sol";
import { MockExecutor } from "./mocks/MockExecutor.sol";
import { MockTreasury } from "./mocks/MockTreasury.sol";

contract HopV2QuoteHopOptionsTest is FraxTest {
    uint32 internal constant FRAXTAL_EID = 2;
    uint32 internal constant TEMPO_EID = 30_410;
    uint128 internal constant TEMPO_RECEIVE_GAS = 2_500_000;

    FraxtalHopV2Mock internal hop;
    MockDVN internal mockDVN;
    MockExecutor internal mockExecutor;
    MockTreasury internal mockTreasury;

    function setUp() public {
        mockDVN = new MockDVN();
        mockExecutor = new MockExecutor();
        mockTreasury = new MockTreasury();

        address[] memory approvedOfts;
        FraxtalHopV2Mock implementation = new FraxtalHopV2Mock(FRAXTAL_EID);
        bytes memory initializeArgs = abi.encodeWithSignature(
            "initialize(uint32,address,uint32,address,address,address,address[])",
            FRAXTAL_EID,
            address(0x1234),
            uint32(1),
            address(mockExecutor),
            address(mockDVN),
            address(mockTreasury),
            approvedOfts
        );

        TransparentUpgradeableProxy proxy = new TransparentUpgradeableProxy(
            address(implementation),
            address(this),
            initializeArgs
        );
        hop = FraxtalHopV2Mock(payable(address(proxy)));
    }

    function test_QuoteHop_WithStoredTempoExecutorOptions_AndData() public {
        bytes memory tempoOptions = _tempoExecutorOptions();
        bytes memory data = "tempo admin payload";

        hop.setExecutorOptions(TEMPO_EID, tempoOptions);

        assertEq(hop.executorOptions(TEMPO_EID), tempoOptions, "Stored tempo options should match");
        assertGt(hop.quoteHop(TEMPO_EID, 400_000, data), 0, "quoteHop should price stored tempo options with data");
    }

    function test_QuoteHop_WithStoredTempoExecutorOptions_WithoutData() public {
        bytes memory tempoOptions = _tempoExecutorOptions();

        hop.setExecutorOptions(TEMPO_EID, tempoOptions);

        assertEq(hop.executorOptions(TEMPO_EID), tempoOptions, "Stored tempo options should match");
        assertGt(hop.quoteHop(TEMPO_EID, 0, ""), 0, "quoteHop should price stored tempo options without data");
    }

    function _tempoExecutorOptions() internal pure returns (bytes memory) {
        return abi.encodePacked(uint8(1), uint16(17), uint8(1), uint128(TEMPO_RECEIVE_GAS));
    }
}
