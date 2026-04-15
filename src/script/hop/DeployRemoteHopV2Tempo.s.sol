// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import { DeployRemoteHopV2, ISendLibrary } from "./DeployRemoteHopV2.s.sol";
import { console } from "forge-std/Script.sol";
import { RemoteHopV2 } from "src/contracts/hop/RemoteHopV2.sol";
import { RemoteHopV2Tempo } from "src/contracts/hop/RemoteHopV2Tempo.sol";
import { FraxUpgradeableProxy, ITransparentUpgradeableProxy } from "frax-std/FraxUpgradeableProxy.sol";

// forge script src/script/hop/DeployRemoteHopV2Tempo.s.sol --rpc-url https://rpc.tempo.xyz --gcp --sender 0x54f9b12743a7deec0ea48721683cbebedc6e17bc --broadcast --verify
contract DeployRemoteHopV2Tempo is DeployRemoteHopV2 {
    address public constant TEMPO_ENDPOINT = 0x20Bb7C2E2f4e5ca2B4c57060d1aE2615245dCc9C;

    constructor() {
        proxyAdmin = 0x000000dbfaA1Fb91ca46867cE6D41aB6da4f7428;
        endpoint = 0x20Bb7C2E2f4e5ca2B4c57060d1aE2615245dCc9C;
        localEid = 30_410;

        msig = 0x1Ba19a54a01AE967f5E3895764Caaa6919FD2bEe;

        EXECUTOR = 0xf851abCa1d0fD1Df8eAba6de466a102996b7d7B2;
        DVN = 0x76FaFF60799021B301B45dC1BbEDE53F261F9961;
        SEND_LIBRARY = 0x572863d9247E52026E0892d9Cd2E519B41EdB73C;

        frxUsdOft = 0x00000000D61733e7A393A10A5B48c311AbE8f1E5;
        sfrxUsdOft = 0x00000000fD8C4B8A413A06821456801295921a71;
        frxEthOft = 0x000000008c3930dCA540bB9B3A5D0ee78FcA9A4c;
        sfrxEthOft = 0x00000000883279097A49dB1f2af954EAd0C77E3c;
        wFraxOft = 0x00000000E9CE0f293D1Ce552768b187eBA8a56D4;
        fpiOft = 0x00000000bC4aEF4bA6363a437455Cb1af19e2aEb;
    }

    function run() public override {
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
    ) internal returns (address payable) {
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
        address proxy = 0x0000006D38568b00B457580b734e0076C62de659;

        address implementationTempo = address(new RemoteHopV2Tempo(TEMPO_ENDPOINT));

        ITransparentUpgradeableProxy(proxy).upgradeToAndCall(implementationTempo, initializeArgs);
        ITransparentUpgradeableProxy(proxy).changeAdmin(_proxyAdmin);

        // set solana enforced options
        RemoteHopV2(payable(address(proxy))).setExecutorOptions(
            30_168,
            hex"0100210100000000000000000000000000030D40000000000000000000000000002DC6C0"
        );

        return payable(address(proxy));
    }
}
