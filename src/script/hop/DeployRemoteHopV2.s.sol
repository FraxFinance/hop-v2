pragma solidity 0.8.23;

import { Script } from "forge-std/Script.sol";
import { console } from "forge-std/Script.sol";
import { RemoteHopV2 } from "src/contracts/hop/RemoteHopV2.sol";
import { RemoteAdmin } from "src/contracts/RemoteAdmin.sol";

import { IERC20Metadata } from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

import { FraxUpgradeableProxy, ITransparentUpgradeableProxy } from "frax-std/FraxUpgradeableProxy.sol";

interface IExecutor {
    function endpoint() external view returns (address);

    function localEidV2() external view returns (uint32);
}

interface ISendLibrary {
    function treasury() external view returns (address);

    function version() external view returns (uint64, uint8, uint8);
}

interface IDVN {
    function vid() external view returns (uint32);
}

interface IOFT {
    function token() external view returns (address);
}

abstract contract DeployRemoteHopV2 is Script {
    address constant FRAXTAL_HOP = 0x00000000e18aFc20Afe54d4B2C8688bB60c06B36;
    address constant FRAXTAL_MSIG = 0x5f25218ed9474b721d6a38c115107428E832fA2E;

    address proxyAdmin;
    address endpoint;
    uint32 localEid;

    address EXECUTOR;
    address DVN;
    address SEND_LIBRARY;

    address msig;
    address frxUsdOft;
    address sfrxUsdOft;
    address frxEthOft;
    address sfrxEthOft;
    address wFraxOft;
    address fpiOft;
    address[] approvedOfts;

    function run() public {
        _validateAddrs();

        vm.startBroadcast();

        approvedOfts.push(frxUsdOft);
        approvedOfts.push(sfrxUsdOft);
        approvedOfts.push(frxEthOft);
        approvedOfts.push(sfrxEthOft);
        approvedOfts.push(wFraxOft);
        approvedOfts.push(fpiOft);

        address remoteHop = _deployRemoteHopV2({
            _proxyAdmin: proxyAdmin,
            _localEid: localEid,
            _endpoint: endpoint,
            _fraxtalHop: bytes32(uint256(uint160(FRAXTAL_HOP))),
            _numDVNs: 3,
            _EXECUTOR: EXECUTOR,
            _DVN: DVN,
            _TREASURY: ISendLibrary(SEND_LIBRARY).treasury(),
            _approvedOfts: approvedOfts
        });
        console.log("RemoteHopV2 deployed at:", remoteHop);

        address remoteAdmin = _deployRemoteAdmin(remoteHop);
        console.log("RemoteAdmin deployed at:", remoteAdmin);

        // grant Pauser roles to msig signers
        bytes32 PAUSER_ROLE = 0x65d7a28e3265b37a6474929f336521b332c1681b933f6cb9f3376673440d862a;

        // carter
        RemoteHopV2(payable(remoteHop)).grantRole(PAUSER_ROLE, 0x54C5Ef136D02b95C4Ff217aF93FA63F9E4119919);
        // sam
        RemoteHopV2(payable(remoteHop)).grantRole(PAUSER_ROLE, 0x17e06ce6914E3969f7BD37D8b2a563890cA1c96e);
        // dhruvin
        RemoteHopV2(payable(remoteHop)).grantRole(PAUSER_ROLE, 0x8d8290d49e88D16d81C6aDf6C8774eD88762274A);
        // travis
        RemoteHopV2(payable(remoteHop)).grantRole(PAUSER_ROLE, 0xcbc616D595D38483e6AdC45C7E426f44bF230928);
        // thomas
        RemoteHopV2(payable(remoteHop)).grantRole(PAUSER_ROLE, 0x381e2495e683868F693AA5B1414F712f21d34b40);
        // nader
        RemoteHopV2(payable(remoteHop)).grantRole(PAUSER_ROLE, 0x6e74053a3798e0fC9a9775F7995316b27f21c4D2);
        // dennis
        RemoteHopV2(payable(remoteHop)).grantRole(PAUSER_ROLE, 0xC6EF452b0de9E95Ccb153c2A5A7a90154aab3419);

        // transfer admin role to msig & RemoteAdmin and renounce from deployer
        RemoteHopV2(payable(remoteHop)).grantRole(bytes32(0), msig);
        RemoteHopV2(payable(remoteHop)).grantRole(bytes32(0), remoteAdmin);
        RemoteHopV2(payable(remoteHop)).renounceRole(bytes32(0), msg.sender);

        vm.stopBroadcast();
    }

    function _validateAddrs() internal view {
        (uint64 major, uint8 minor, uint8 endpointVersion) = ISendLibrary(SEND_LIBRARY).version();
        require(major == 3 && minor == 0 && endpointVersion == 2, "Invalid SendLibrary version");

        require(IExecutor(EXECUTOR).endpoint() == endpoint, "Invalid executor endpoint");
        try IExecutor(EXECUTOR).localEidV2() returns (uint32 eid) {
            require(eid == localEid, "Invalid executor localEidV2");
        } catch {}
        require(IDVN(DVN).vid() != 0, "Invalid DVN vid");

        require(msig != address(0), "msig is not set");
        require(proxyAdmin != address(0), "proxyAdmin is not set");

        require(isStringEqual(IERC20Metadata(IOFT(frxUsdOft).token()).symbol(), "frxUSD"), "frxUsdOft != frxUSD");
        require(isStringEqual(IERC20Metadata(IOFT(sfrxUsdOft).token()).symbol(), "sfrxUSD"), "sfrxUsdOft != sfrxUSD");
        require(isStringEqual(IERC20Metadata(IOFT(frxEthOft).token()).symbol(), "frxETH"), "frxEthOft != frxETH");
        require(isStringEqual(IERC20Metadata(IOFT(sfrxEthOft).token()).symbol(), "sfrxETH"), "sfrxEthOft != sfrxETH");
        require(isStringEqual(IERC20Metadata(IOFT(wFraxOft).token()).symbol(), "WFRAX"), "wFraxOft != WFRAX");
        require(isStringEqual(IERC20Metadata(IOFT(fpiOft).token()).symbol(), "FPI"), "fpiOft != FPI");
    }

    function isStringEqual(string memory _a, string memory _b) public pure returns (bool) {
        return keccak256(abi.encodePacked(_a)) == keccak256(abi.encodePacked(_b));
    }

    function _deployRemoteAdmin(address remoteHop) internal virtual returns (address) {
        address remoteAdmin = address(new RemoteAdmin{ salt: bytes32(uint256(1)) }(frxUsdOft, remoteHop, FRAXTAL_MSIG));
        // require(remoteAdmin == 0x954286118E93df807aB6f99aE0454f8710f0a8B9, "RemoteAdmin address mismatch");
        return remoteAdmin;
    }

    function _deployRemoteHopV2(
        address _proxyAdmin,
        uint32 _localEid,
        address _endpoint,
        bytes32 _fraxtalHop,
        uint32 _numDVNs,
        address _EXECUTOR,
        address _DVN,
        address _TREASURY,
        address[] memory _approvedOfts
    ) internal virtual returns (address payable) {
        return
            deployRemoteHopV2(
                _proxyAdmin,
                _localEid,
                _endpoint,
                _fraxtalHop,
                _numDVNs,
                _EXECUTOR,
                _DVN,
                _TREASURY,
                _approvedOfts
            );
    }
}

function deployRemoteHopV2(
    address _proxyAdmin,
    uint32 _localEid,
    address _endpoint,
    bytes32 _fraxtalHop,
    uint32 _numDVNs,
    address _EXECUTOR,
    address _DVN,
    address _TREASURY,
    address[] memory _approvedOfts
) returns (address payable) {
    bytes memory initializeArgs = abi.encodeCall(
        RemoteHopV2.initialize,
        (_localEid, _endpoint, _fraxtalHop, _numDVNs, _EXECUTOR, _DVN, _TREASURY, _approvedOfts)
    );

    // @dev: for paris
    /*
    address implementation = address(new RemoteHopV2{salt: bytes32(0x4e59b44847b379578588920ca78fbf26c0b4956c2791269a18c599f416240000) }());
    require(implementation == 0x00000000115aFDdC31Ecf21723EB657f3457B419, "Implementation address mismatch");

    FraxUpgradeableProxy proxy = new FraxUpgradeableProxy{ salt: bytes32(0x4e59b44847b379578588920ca78fbf26c0b4956cab19add5db38737da0030080) }(
        implementation,
        msg.sender,
        ""
    );
    require(address(proxy) == 0x000000004388B53172053d6a45B9B34B3A98A3C3, "Proxy address mismatch");
    */

    // @dev: for cancun
    address implementation = address(
        new RemoteHopV2{ salt: bytes32(0x4e59b44847b379578588920ca78fbf26c0b4956c9354ec210d62dd5b592000c0) }()
    );
    require(implementation == 0x0000000087ED0dD8b999aE6C7c30f95e9707a3C6, "Implementation address mismatch");

    FraxUpgradeableProxy proxy = new FraxUpgradeableProxy{
        salt: bytes32(0x4e59b44847b379578588920ca78fbf26c0b4956cf4079e3d6eda7a014e9e0040)
    }(implementation, msg.sender, "");
    require(address(proxy) == 0x0000006D38568b00B457580b734e0076C62de659, "Proxy address mismatch");

    ITransparentUpgradeableProxy(address(proxy)).upgradeToAndCall(implementation, initializeArgs);
    ITransparentUpgradeableProxy(address(proxy)).changeAdmin(_proxyAdmin);

    // set solana enforced options
    RemoteHopV2(payable(address(proxy))).setExecutorOptions(
        30_168,
        hex"0100210100000000000000000000000000030D40000000000000000000000000002DC6C0"
    );

    return payable(address(proxy));
}
