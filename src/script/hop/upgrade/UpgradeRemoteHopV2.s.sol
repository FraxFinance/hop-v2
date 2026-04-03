pragma solidity ^0.8.0;

import { UpgradeHopV2 } from "src/script/hop/upgrade/UpgradeHopV2.s.sol";
import { RemoteHopV201 } from "src/contracts/hop/RemoteHopV201.sol";

// TODO: abstract, tempo, zksync, hyperevm, somnia
// forge script src/script/hop/upgrade/UpgradeRemoteHopV2.s.sol --rpc-url https://arbitrum.public.blockpi.network/v1/rpc/public --broadcast --verify --verifier etherscan --etherscan-api-key $ETHERSCAN_API_KEY
// forge script src/script/hop/upgrade/UpgradeRemoteHopV2.s.sol --rpc-url https://mainnet.aurora.dev --legacy --broadcast --verify --verifier blockscout --verifier-url https://explorer.aurora.dev/api/ --gcp --sender 0x54f9b12743a7deec0ea48721683cbebedc6e17bc
// forge script src/script/hop/upgrade/UpgradeRemoteHopV2.s.sol --rpc-url https://api.avax.network/ext/bc/C/rpc --broadcast --verify --verifier-url 'https://api.routescan.io/v2/network/mainnet/evm/43114/etherscan' --etherscan-api-key "verifyContract" --verifier etherscan  --gcp
// forge script src/script/hop/upgrade/UpgradeRemoteHopV2.s.sol --rpc-url https://mainnet.base.org --broadcast --verify --verifier etherscan --etherscan-api-key $ETHERSCAN_API_KEY --gcp
// forge script src/script/hop/upgrade/UpgradeRemoteHopV2.s.sol --rpc-url https://rpc.berachain.com --broadcast --verify --verifier etherscan --verifier-url "https://api.etherscan.io/v2/api?chainid=80094&" --etherscan-api-key $ETHERSCAN_API_KEY --gcp --sender 0x54f9b12743a7deec0ea48721683cbebedc6e17bc
// forge script src/script/hop/upgrade/UpgradeRemoteHopV2.s.sol --rpc-url https://bsc-mainnet.public.blastapi.io --broadcast --verify --verifier etherscan --etherscan-api-key $ETHERSCAN_API_KEY --gcp --sender 0x54f9b12743a7deec0ea48721683cbebedc6e17bc
// TODO (once grantRole passes): forge script src/script/hop/upgrade/UpgradeRemoteHopV2.s.sol --rpc-url https://ethereum-rpc.publicnode.com --broadcast --verify --verifier etherscan --etherscan-api-key $ETHERSCAN_API_KEY --gcp
// forge script src/script/hop/upgrade/UpgradeRemoteHopV2.s.sol --rpc-url https://rpc-gel.inkonchain.com --broadcast --gcp --sender 0x54f9b12743a7deec0ea48721683cbebedc6e17bc --verify --verifier etherscan --verifier-url "https://api.routescan.io/v2/network/mainnet/evm/57073/etherscan" --etherscan-api-key "verifyContract"
// forge script src/script/hop/upgrade/UpgradeRemoteHopV2.s.sol --rpc-url https://rpc.katana.network --broadcast --gcp --sender 0x54f9b12743a7deec0ea48721683cbebedc6e17bc --verify --verifier etherscan --verifier-url "https://api.etherscan.io/v2/api?chainid=747474" --etherscan-api-key $ETHERSCAN_API_KEY
// forge script src/script/hop/upgrade/UpgradeRemoteHopV2.s.sol --rpc-url https://rpc.linea.build --broadcast --verify --verifier etherscan --etherscan-api-key $ETHERSCAN_API_KEY --gcp
// forge script src/script/hop/upgrade/UpgradeRemoteHopV2.s.sol --rpc-url https://mainnet.mode.network --broadcast --gcp --sender 0x54f9b12743a7deec0ea48721683cbebedc6e17bc --verify --verifier etherscan --verifier-url "https://explorer.mode.network/api" --etherscan-api-key "abc"
// forge script src/script/hop/upgrade/UpgradeRemoteHopV2.s.sol --rpc-url https://mainnet.optimism.io --broadcast --verify --verifier etherscan --etherscan-api-key $ETHERSCAN_API_KEY --gcp --sender 0x54f9b12743a7deec0ea48721683cbebedc6e17bc
// forge script src/script/hop/upgrade/UpgradeRemoteHopV2.s.sol --rpc-url https://rpc.scroll.io --broadcast --verify --verifier etherscan --etherscan-api-key $ETHERSCAN_API_KEY --gcp --sender 0x54f9b12743a7deec0ea48721683cbebedc6e17bc
// forge script src/script/hop/upgrade/UpgradeRemoteHopV2.s.sol --rpc-url https://evm-rpc.sei-apis.com --broadcast --verify --verifier-url https://seitrace.com/pacific-1/api --verifier custom --verifier-api-key $ETHERSCAN_API_KEY --gcp --sender 0x54f9b12743a7deec0ea48721683cbebedc6e17bc
// forge script src/script/hop/upgrade/UpgradeRemoteHopV2.s.sol --rpc-url https://rpc.soniclabs.com --broadcast --verify --verifier etherscan --etherscan-api-key $ETHERSCAN_API_KEY --gcp --sender 0x54f9b12743a7deec0ea48721683cbebedc6e17bc
// forge script src/script/hop/upgrade/UpgradeRemoteHopV2.s.sol --rpc-url https://mainnet.unichain.org --broadcast --verify --verifier etherscan --etherscan-api-key $ETHERSCAN_API_KEY --gcp --sender 0x54f9b12743a7deec0ea48721683cbebedc6e17bc
// forge script src/script/hop/upgrade/UpgradeRemoteHopV2.s.sol --rpc-url https://worldchain-mainnet.g.alchemy.com/public --broadcast --verify --verifier etherscan --etherscan-api-key $ETHERSCAN_API_KEY --gcp --sender 0x54f9b12743a7deec0ea48721683cbebedc6e17bc
// forge script src/script/hop/upgrade/UpgradeRemoteHopV2.s.sol --rpc-url https://xlayerrpc.okx.com --legacy --broadcast --verify --verifier-url https://www.oklink.com/api/v5/explorer/contract/verify-source-code-plugin/XLAYER --verifier oklink --verifier-api-key $OKLINK_API_KEY --gcp --sender 0x54f9b12743a7deec0ea48721683cbebedc6e17bc
contract UpgradeRemoteHopV2 is UpgradeHopV2 {
    function setUp() public override {
        hop = 0x0000006D38568b00B457580b734e0076C62de659;
        super.setUp();
    }

    function deployImplementation() internal virtual override {
        vm.startBroadcast();

        newImplementation = address(
            new RemoteHopV201{ salt: 0x4e59b44847b379578588920ca78fbf26c0b4956c425b52b18422043c590a00c0 }()
        );
        require(newImplementation == 0xD3b7B923990000003500009264561127A87B00Bd, "Unexpected implementation address");

        vm.stopBroadcast();
    }
}
