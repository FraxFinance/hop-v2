// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import { DeployRemoteHopV2 } from "./DeployRemoteHopV2.s.sol";
import { RemoteHopV2 } from "src/contracts/hop/RemoteHopV2.sol";
import { RemoteAdmin } from "src/contracts/RemoteAdmin.sol";
import { FraxUpgradeableProxy, ITransparentUpgradeableProxy } from "frax-std/FraxUpgradeableProxy.sol";

/// @title DeployRemoteHopV2ZkSync
/// @notice Deploys RemoteHopV2 + FraxUpgradeableProxy + RemoteAdmin on zkSync ERA (chain 324, LZ eid 30165)
/// @dev Overrides `_deployRemoteHopV2()` and `_deployRemoteAdmin()` with zkEVM-specific CREATE2 salts.
///      zkSync CREATE2 routes ALL deployments through L2_CREATE2_FACTORY (0x0000...10000) as sender.
///      Formula: keccak256(keccak256("zksyncCreate2") ++ pad32(sender) ++ salt ++ bytecodeHash ++ keccak256(constructorInput))[12:]
///      Salts mined via `create2crunch --zksync` for 0x00000000 vanity prefix.
///      Uses `new Contract{salt}()` syntax (not direct factory calls) so zksolc auto-includes factory deps.
///
/// @dev Expected addresses (identical on all zkEVM chains sharing the same bytecodeHash):
///      Implementation: 0x00000001Fc41bB036e7e894F70879F7cA8a4adFc
///      Proxy:          0x0000000175B6B4DDe153c7aE06E4F0b27eEe42DF
///      RemoteAdmin:    0x0000000221a0682d34a635ecAa38C98b31EfFc51
///
/// Simulate:
///   forge script src/script/hop/DeployRemoteHopV2ZkSync.s.sol --rpc-url https://mainnet.era.zksync.io --gcp --sender 0x54f9b12743a7deec0ea48721683cbebedc6e17bc --zksync
///
/// Broadcast:
///   forge script src/script/hop/DeployRemoteHopV2ZkSync.s.sol --rpc-url https://mainnet.era.zksync.io --broadcast --verify --verifier blockscout --verifier-url https://block-explorer-api.mainnet.zksync.io/api --gcp --sender 0x54f9b12743a7deec0ea48721683cbebedc6e17bc --zksync
contract DeployRemoteHopV2ZkSync is DeployRemoteHopV2 {
    constructor() {
        proxyAdmin = 0xE59Dcae52a4ffA39Be99588486C84Bc2dC1bA52f;
        endpoint = 0xd07C30aF3Ff30D96BDc9c6044958230Eb797DDBF;
        localEid = 30_165;

        msig = 0x66716ae60898dD4479B52aC4d92ef16C1821f420;

        EXECUTOR = 0x664e390e672A811c12091db8426cBb7d68D5D8A6;
        DVN = 0x620A9DF73D2F1015eA75aea1067227F9013f5C51;
        SEND_LIBRARY = 0x07fD0e370B49919cA8dA0CE842B8177263c0E12c;

        frxUsdOft = 0xEa77c590Bb36c43ef7139cE649cFBCFD6163170d;
        sfrxUsdOft = 0x9F87fbb47C33Cd0614E43500b9511018116F79eE;
        frxEthOft = 0xc7Ab797019156b543B7a3fBF5A99ECDab9eb4440;
        sfrxEthOft = 0xFD78FD3667DeF2F1097Ed221ec503AE477155394;
        wFraxOft = 0xAf01aE13Fb67AD2bb2D76f29A83961069a5F245F;
        fpiOft = 0x580F2ee1476eDF4B1760bd68f6AaBaD57dec420E;
    }

    /// @dev Override with zkEVM-specific CREATE2 salts (mined for 0x00000000 prefix via create2crunch --zksync)
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
    ) internal override returns (address payable) {
        bytes memory initializeArgs = abi.encodeCall(
            RemoteHopV2.initialize,
            (_localEid, _endpoint, _fraxtalHop, _numDVNs, _EXECUTOR, _DVN, _TREASURY, _approvedOfts)
        );

        address implementation = address(
            new RemoteHopV2{ salt: bytes32(0x070c0543fb5ab610f6ecdaaae669b426a7e12436fecbfec15b6963bf54000010) }()
        );
        require(implementation == 0x00000001Fc41bB036e7e894F70879F7cA8a4adFc, "Implementation address mismatch");

        FraxUpgradeableProxy proxy = new FraxUpgradeableProxy{
            salt: bytes32(0x53a08a10d007da760c7dfc6c9b327cb1a5d871f9cd0dc1d98091831072010008)
        }(implementation, msg.sender, "");
        require(address(proxy) == 0x0000000175B6B4DDe153c7aE06E4F0b27eEe42DF, "Proxy address mismatch");

        ITransparentUpgradeableProxy(address(proxy)).upgradeToAndCall(implementation, initializeArgs);
        ITransparentUpgradeableProxy(address(proxy)).changeAdmin(_proxyAdmin);

        // set solana enforced options
        RemoteHopV2(payable(address(proxy))).setExecutorOptions(
            30_168,
            hex"0100210100000000000000000000000000030D40000000000000000000000000002DC6C0"
        );

        return payable(address(proxy));
    }

    /// @dev Override with zkEVM-specific CREATE2 salt (mined for 0x00000000 prefix via create2crunch --zksync)
    function _deployRemoteAdmin(address remoteHop) internal override returns (address) {
        address remoteAdmin = address(
            new RemoteAdmin{ salt: bytes32(0xde7132b04e420f266d0dd26cb34b7b4e2540d5fe9a55b55620fce04cdc018021) }(
                frxUsdOft,
                remoteHop,
                FRAXTAL_MSIG
            )
        );
        require(remoteAdmin == 0x0000000221a0682d34a635ecAa38C98b31EfFc51, "RemoteAdmin address mismatch");
        return remoteAdmin;
    }
}
