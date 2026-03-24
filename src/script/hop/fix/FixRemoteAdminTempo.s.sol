// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import { DeployRemoteHopV2, ISendLibrary } from "../DeployRemoteHopV2.s.sol";
import { console } from "forge-std/Script.sol";
import { RemoteHopV2 } from "src/contracts/hop/RemoteHopV2.sol";
import { RemoteHopV2Tempo } from "src/contracts/hop/RemoteHopV2Tempo.sol";
import { FraxUpgradeableProxy, ITransparentUpgradeableProxy } from "frax-std/FraxUpgradeableProxy.sol";
import { SafeTxHelper, SafeTx } from "frax-std/SafeTxHelper.sol";
import { IAccessControl } from "@openzeppelin/contracts/access/IAccessControl.sol";

// forge script src/script/hop/fix/FixRemoteAdminTempo.s.sol --rpc-url https://rpc.tempo.xyz --gcp --sender 0x54f9b12743a7deec0ea48721683cbebedc6e17bc --broadcast --verify --ffi
contract FixRemoteAdminTempo is DeployRemoteHopV2 {
    address public constant TEMPO_ENDPOINT = 0x20Bb7C2E2f4e5ca2B4c57060d1aE2615245dCc9C;
    address public constant REMOTE_HOP = 0x0000006D38568b00B457580b734e0076C62de659;

    address public constant oldRemoteAdmin = 0x954286118E93df807aB6f99aE0454f8710f0a8B9;

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

        address newRemoteAdmin = _deployRemoteAdmin(REMOTE_HOP);
        console.log("RemoteAdmin deployed at:", newRemoteAdmin);

        vm.stopBroadcast();

        // Generate Safe batch JSON for msig to swap admin roles
        SafeTx[] memory txs = new SafeTx[](2);

        // Grant first so admin role is never left empty.
        txs[0] = SafeTx({
            name: "Grant DEFAULT_ADMIN_ROLE to new RemoteAdmin",
            to: REMOTE_HOP,
            value: 0,
            data: abi.encodeCall(IAccessControl.grantRole, (bytes32(0), newRemoteAdmin))
        });

        txs[1] = SafeTx({
            name: "Revoke DEFAULT_ADMIN_ROLE from old RemoteAdmin",
            to: REMOTE_HOP,
            value: 0,
            data: abi.encodeCall(IAccessControl.revokeRole, (bytes32(0), oldRemoteAdmin))
        });

        string memory root = vm.projectRoot();
        string memory filename = string(abi.encodePacked(root, "/src/script/hop/fix/txs/FixRemoteAdminTempo.json"));
        new SafeTxHelper().writeTxs(txs, filename);

        console.log("Safe tx JSON written to:", filename);
    }
}
