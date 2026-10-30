// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import "frax-std/FraxTest.sol";
import { Initializable } from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import { FraxUpgradeableProxy, ITransparentUpgradeableProxy } from "frax-std/FraxUpgradeableProxy.sol";

import { RemoteHopV201 } from "src/contracts/hop/RemoteHopV201.sol";
import { FraxtalHopV201 } from "src/contracts/hop/FraxtalHopV201.sol";
import { RemoteHopV201Tempo } from "src/contracts/hop/RemoteHopV201Tempo.sol";
import { deployRemoteHopV201 } from "src/script/hop/upgrade/DeployRemoteHopV201.s.sol";
import { deployFraxtalHopV201 } from "src/script/hop/upgrade/DeployFraxtalHopV201.s.sol";
import { deployRemoteHopV201Tempo } from "src/script/hop/upgrade/DeployRemoteHopV201Tempo.s.sol";

/// @dev The views and init surface the three V201 hops share.
interface IHopInitSurface {
    function DEFAULT_ADMIN_ROLE() external view returns (bytes32);
    function hasRole(bytes32 role, address account) external view returns (bool);
    function localEid() external view returns (uint32);
    function endpoint() external view returns (address);
    function numDVNs() external view returns (uint32);
    function EXECUTOR() external view returns (address);
    function DVN() external view returns (address);
    function TREASURY() external view returns (address);
    function approvedOft(address oft) external view returns (bool);
    function remoteHop(uint32 eid) external view returns (bytes32);
    function exposedInitHopV201(
        uint32 _localEid,
        address _endpoint,
        uint32 _numDVNs,
        address _EXECUTOR,
        address _DVN,
        address _TREASURY,
        address[] memory _approvedOfts
    ) external;
}

/// @dev Only what the TempoGasTokenBase constructor reads from an EndpointV2Alt.
contract StubEndpointV2Alt {
    function nativeToken() external pure returns (address) {
        return address(0xD011A12);
    }
}

// Derived contracts that expose the internal init helper through an ordinary external function,
// the shape the onlyInitializing guard on `__init_HopV201` exists to stop.

contract RemoteHopV201InitHarness is RemoteHopV201 {
    function exposedInitHopV201(
        uint32 _localEid,
        address _endpoint,
        uint32 _numDVNs,
        address _EXECUTOR,
        address _DVN,
        address _TREASURY,
        address[] memory _approvedOfts
    ) external {
        __init_HopV201(_localEid, _endpoint, _numDVNs, _EXECUTOR, _DVN, _TREASURY, _approvedOfts);
    }
}

contract FraxtalHopV201InitHarness is FraxtalHopV201 {
    function exposedInitHopV201(
        uint32 _localEid,
        address _endpoint,
        uint32 _numDVNs,
        address _EXECUTOR,
        address _DVN,
        address _TREASURY,
        address[] memory _approvedOfts
    ) external {
        __init_HopV201(_localEid, _endpoint, _numDVNs, _EXECUTOR, _DVN, _TREASURY, _approvedOfts);
    }
}

contract RemoteHopV201TempoInitHarness is RemoteHopV201Tempo {
    constructor(address _endpoint) RemoteHopV201Tempo(_endpoint) {}

    function exposedInitHopV201(
        uint32 _localEid,
        address _endpoint,
        uint32 _numDVNs,
        address _EXECUTOR,
        address _DVN,
        address _TREASURY,
        address[] memory _approvedOfts
    ) external {
        __init_HopV201(_localEid, _endpoint, _numDVNs, _EXECUTOR, _DVN, _TREASURY, _approvedOfts);
    }
}

abstract contract HopV201InitTestBase is FraxTest {
    address constant DEPLOYER = 0x54F9b12743A7DeeC0ea48721683cbebedC6E17bC;
    address constant PROXY_ADMIN = address(0xAD);
    address constant ATTACKER = address(0xBAD);
    address constant ROGUE_OFT = address(0xE11);
    uint32 constant FRAXTAL_EID = 30_255;
    uint32 constant NUM_DVNS = 5;
    address constant EXECUTOR = address(0x1111);
    address constant DVN = address(0x2222);
    address constant TREASURY = address(0x3333);
    bytes32 constant FRAXTAL_HOP = bytes32(uint256(0xF4A7));

    address endpoint = address(0xE9D);
    address oft = address(0x0F7);
    address[] approvedOfts;

    function setUp() public virtual {
        approvedOfts.push(oft);
    }

    // ---- per-variant hooks ----

    function _localEid() internal view virtual returns (uint32);

    /// @dev Remote hops register the Fraxtal hop in `initialize`; the hub does not.
    function _registersFraxtalHop() internal view virtual returns (bool);

    /// @dev Deploys through the production free function in src/script, pranked as the deployer.
    function _deployViaScriptAsDeployer() internal virtual returns (address);

    /// @dev Calls the variant's `initialize` again with attacker-chosen values.
    function _initializeAgain(address hop) internal virtual;

    function _newHarnessImplementation() internal virtual returns (address);

    function _initializeCalldata() internal view virtual returns (bytes memory);

    // ---- helpers ----

    function _deployViaScript() internal returns (IHopInitSurface hop) {
        vm.startPrank(DEPLOYER);
        hop = IHopInitSurface(_deployViaScriptAsDeployer());
        vm.stopPrank();
    }

    function _deployHarnessProxy() internal returns (IHopInitSurface) {
        address impl = _newHarnessImplementation();
        vm.startPrank(DEPLOYER);
        FraxUpgradeableProxy proxy = new FraxUpgradeableProxy(impl, DEPLOYER, "");
        ITransparentUpgradeableProxy(address(proxy)).upgradeToAndCall(impl, _initializeCalldata());
        ITransparentUpgradeableProxy(address(proxy)).changeAdmin(PROXY_ADMIN);
        vm.stopPrank();
        return IHopInitSurface(address(proxy));
    }

    function _assertConfigured(IHopInitSurface hop) internal view {
        assertTrue(hop.hasRole(hop.DEFAULT_ADMIN_ROLE(), DEPLOYER), "deployer is admin");
        assertFalse(hop.hasRole(hop.DEFAULT_ADMIN_ROLE(), ATTACKER), "attacker is not admin");
        assertEq(hop.localEid(), _localEid(), "localEid");
        assertEq(hop.endpoint(), endpoint, "endpoint");
        assertEq(hop.numDVNs(), NUM_DVNS, "numDVNs");
        assertEq(hop.EXECUTOR(), EXECUTOR, "executor");
        assertEq(hop.DVN(), DVN, "dvn");
        assertEq(hop.TREASURY(), TREASURY, "treasury");
        assertTrue(hop.approvedOft(oft), "oft approved");
        assertFalse(hop.approvedOft(ROGUE_OFT), "rogue oft not approved");
        if (_registersFraxtalHop()) assertEq(hop.remoteHop(FRAXTAL_EID), FRAXTAL_HOP, "fraxtal hop");
    }

    function _rogueOfts() internal pure returns (address[] memory rogue) {
        rogue = new address[](1);
        rogue[0] = ROGUE_OFT;
    }

    // ---- tests ----

    function test_Initialize_ViaDeployScript_SetsConfig() public {
        _assertConfigured(_deployViaScript());
    }

    function test_Initialize_Twice_Reverts() public {
        IHopInitSurface hop = _deployViaScript();

        vm.prank(ATTACKER);
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        _initializeAgain(address(hop));

        _assertConfigured(hop);
    }

    function test_InitHelper_OutsideInitialization_RevertsThroughProxy() public {
        IHopInitSurface hop = _deployHarnessProxy();

        vm.prank(ATTACKER);
        vm.expectRevert(Initializable.NotInitializing.selector);
        hop.exposedInitHopV201(1, ATTACKER, 1, ATTACKER, ATTACKER, ATTACKER, _rogueOfts());

        _assertConfigured(hop);
    }

    function test_InitHelper_OutsideInitialization_RevertsOnImplementation() public {
        IHopInitSurface impl = IHopInitSurface(_newHarnessImplementation());

        vm.prank(ATTACKER);
        vm.expectRevert(Initializable.NotInitializing.selector);
        impl.exposedInitHopV201(1, ATTACKER, 1, ATTACKER, ATTACKER, ATTACKER, _rogueOfts());

        assertFalse(impl.hasRole(impl.DEFAULT_ADMIN_ROLE(), ATTACKER), "no admin grant");
        assertFalse(impl.approvedOft(ROGUE_OFT), "no rogue oft");
    }
}

contract RemoteHopV201InitTest is HopV201InitTestBase {
    uint32 constant ARBITRUM_EID = 30_110;

    function _localEid() internal pure override returns (uint32) {
        return ARBITRUM_EID;
    }

    function _registersFraxtalHop() internal pure override returns (bool) {
        return true;
    }

    function _deployViaScriptAsDeployer() internal override returns (address) {
        return
            deployRemoteHopV201(
                PROXY_ADMIN,
                ARBITRUM_EID,
                endpoint,
                FRAXTAL_HOP,
                NUM_DVNS,
                EXECUTOR,
                DVN,
                TREASURY,
                approvedOfts
            );
    }

    function _initializeAgain(address hop) internal override {
        RemoteHopV201(payable(hop)).initialize(1, ATTACKER, bytes32(0), 1, ATTACKER, ATTACKER, ATTACKER, _rogueOfts());
    }

    function _newHarnessImplementation() internal override returns (address) {
        return address(new RemoteHopV201InitHarness());
    }

    function _initializeCalldata() internal view override returns (bytes memory) {
        return
            abi.encodeCall(
                RemoteHopV201.initialize,
                (ARBITRUM_EID, endpoint, FRAXTAL_HOP, NUM_DVNS, EXECUTOR, DVN, TREASURY, approvedOfts)
            );
    }
}

contract FraxtalHopV201InitTest is HopV201InitTestBase {
    function _localEid() internal pure override returns (uint32) {
        return FRAXTAL_EID;
    }

    function _registersFraxtalHop() internal pure override returns (bool) {
        return false;
    }

    function _deployViaScriptAsDeployer() internal override returns (address) {
        return
            deployFraxtalHopV201(PROXY_ADMIN, FRAXTAL_EID, endpoint, NUM_DVNS, EXECUTOR, DVN, TREASURY, approvedOfts);
    }

    function _initializeAgain(address hop) internal override {
        FraxtalHopV201(payable(hop)).initialize(1, ATTACKER, 1, ATTACKER, ATTACKER, ATTACKER, _rogueOfts());
    }

    function _newHarnessImplementation() internal override returns (address) {
        return address(new FraxtalHopV201InitHarness());
    }

    function _initializeCalldata() internal view override returns (bytes memory) {
        return
            abi.encodeCall(
                FraxtalHopV201.initialize,
                (FRAXTAL_EID, endpoint, NUM_DVNS, EXECUTOR, DVN, TREASURY, approvedOfts)
            );
    }
}

contract RemoteHopV201TempoInitTest is HopV201InitTestBase {
    uint32 constant TEMPO_EID = 30_410;

    function setUp() public override {
        super.setUp();
        // The Tempo constructor reads nativeToken() from the endpoint, so it needs a contract there.
        endpoint = address(new StubEndpointV2Alt());
    }

    function _localEid() internal pure override returns (uint32) {
        return TEMPO_EID;
    }

    function _registersFraxtalHop() internal pure override returns (bool) {
        return true;
    }

    function _deployViaScriptAsDeployer() internal override returns (address) {
        return
            deployRemoteHopV201Tempo(
                PROXY_ADMIN,
                TEMPO_EID,
                endpoint,
                FRAXTAL_HOP,
                NUM_DVNS,
                EXECUTOR,
                DVN,
                TREASURY,
                approvedOfts
            );
    }

    function _initializeAgain(address hop) internal override {
        RemoteHopV201Tempo(payable(hop)).initialize(
            1,
            ATTACKER,
            bytes32(0),
            1,
            ATTACKER,
            ATTACKER,
            ATTACKER,
            _rogueOfts()
        );
    }

    function _newHarnessImplementation() internal override returns (address) {
        return address(new RemoteHopV201TempoInitHarness(endpoint));
    }

    function _initializeCalldata() internal view override returns (bytes memory) {
        return
            abi.encodeCall(
                RemoteHopV201Tempo.initialize,
                (TEMPO_EID, endpoint, FRAXTAL_HOP, NUM_DVNS, EXECUTOR, DVN, TREASURY, approvedOfts)
            );
    }
}
