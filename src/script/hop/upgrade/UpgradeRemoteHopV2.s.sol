pragma solidity ^0.8.0;

import { UpgradeHopV2 } from "src/script/hop/upgrade/UpgradeHopV2.sol";
import { RemoteHopV201 } from "src/contracts/hop/RemoteHopV201.sol";
import { RemoteHopV201Tempo } from "src/contracts/hop/RemoteHopV201Tempo.sol";

// forge script src/script/hop/upgrade/UpgradeRemoteHopV2.s.sol --rpc-url https://api.zan.top/arb-one --ffi --gcp --sender 0x54f9b12743a7deec0ea48721683cbebedc6e17bc --broadcast --verify --verifier etherscan --etherscan-api-key $ETHERSCAN_API_KEY
// forge script src/script/hop/upgrade/UpgradeRemoteHopV2.s.sol --rpc-url https://mainnet.aurora.dev --ffi --legacy --gcp --sender 0x54f9b12743a7deec0ea48721683cbebedc6e17bc --broadcast --verify --verifier blockscout --verifier-url https://explorer.aurora.dev/api/
// forge script src/script/hop/upgrade/UpgradeRemoteHopV2.s.sol --rpc-url https://api.avax.network/ext/bc/C/rpc  --ffi --gcp --sender 0x54f9b12743a7deec0ea48721683cbebedc6e17bc --broadcast --verify --verifier-url 'https://api.routescan.io/v2/network/mainnet/evm/43114/etherscan'
// forge script src/script/hop/upgrade/UpgradeRemoteHopV2.s.sol --rpc-url https://mainnet.base.org --ffi --gcp --sender 0x54f9b12743a7deec0ea48721683cbebedc6e17bc --broadcast --verify --verifier etherscan --etherscan-api-key $ETHERSCAN_API_KEY
// forge script src/script/hop/upgrade/UpgradeRemoteHopV2.s.sol --rpc-url https://rpc.berachain.com --ffi  --gcp --sender 0x54f9b12743a7deec0ea48721683cbebedc6e17bc --broadcast --verify --verifier etherscan --verifier-url "https://api.etherscan.io/v2/api?chainid=80094&" --etherscan-api-key $ETHERSCAN_API_KEY
// forge script src/script/hop/upgrade/UpgradeRemoteHopV2.s.sol --rpc-url https://bsc-mainnet.public.blastapi.io --ffi --gcp --sender 0x54f9b12743a7deec0ea48721683cbebedc6e17bc --broadcast --verify --verifier etherscan --etherscan-api-key $ETHERSCAN_API_KEY
// forge script src/script/hop/upgrade/UpgradeRemoteHopV2.s.sol --rpc-url https://ethereum-rpc.publicnode.com --ffi --gcp --sender 0x54f9b12743a7deec0ea48721683cbebedc6e17bc --broadcast --verify --verifier etherscan --etherscan-api-key $ETHERSCAN_API_KEY
// forge script src/script/hop/upgrade/UpgradeRemoteHopV2.s.sol --rpc-url https://hyperliquid.drpc.org --ffi --gcp --sender 0x54f9b12743a7deec0ea48721683cbebedc6e17bc --broadcast --verify --verifier etherscan --etherscan-api-key $ETHERSCAN_API_KEY
// forge script src/script/hop/upgrade/UpgradeRemoteHopV2.s.sol --rpc-url https://rpc-gel.inkonchain.com --ffi --gcp --sender 0x54f9b12743a7deec0ea48721683cbebedc6e17bc --broadcast --verify --verifier etherscan --verifier-url "https://api.routescan.io/v2/network/mainnet/evm/57073/etherscan" --etherscan-api-key "verifyContract"
// forge script src/script/hop/upgrade/UpgradeRemoteHopV2.s.sol --rpc-url https://rpc.katana.network --ffi --gcp --sender 0x54f9b12743a7deec0ea48721683cbebedc6e17bc --broadcast --verify --verifier etherscan --verifier-url "https://api.etherscan.io/v2/api?chainid=747474" --etherscan-api-key $ETHERSCAN_API_KEY
// forge script src/script/hop/upgrade/UpgradeRemoteHopV2.s.sol --rpc-url https://mainnet.mode.network --ffi --gcp --sender 0x54f9b12743a7deec0ea48721683cbebedc6e17bc --broadcast --verify --verifier etherscan --verifier-url "https://explorer.mode.network/api" --etherscan-api-key "abc"
// forge script src/script/hop/upgrade/UpgradeRemoteHopV2.s.sol --rpc-url https://rpc.monad.xyz --ffi --gcp --sender 0x54f9b12743a7deec0ea48721683cbebedc6e17bc --broadcast --verify --verifier etherscan --etherscan-api-key "abc"
// forge script src/script/hop/upgrade/UpgradeRemoteHopV2.s.sol --rpc-url https://mainnet.optimism.io --ffi --gcp --sender 0x54f9b12743a7deec0ea48721683cbebedc6e17bc --broadcast --verify --verifier etherscan --etherscan-api-key $ETHERSCAN_API_KEY
// forge script src/script/hop/upgrade/UpgradeRemoteHopV2.s.sol --rpc-url https://polygon.gateway.tenderly.co --ffi --gcp --sender 0x54f9b12743a7deec0ea48721683cbebedc6e17bc --broadcast --verify --verifier etherscan --etherscan-api-key $ETHERSCAN_API_KEY
// forge script src/script/hop/upgrade/UpgradeRemoteHopV2.s.sol --rpc-url https://98866.rpc.thirdweb.com --ffi --gcp --sender 0x54f9b12743a7deec0ea48721683cbebedc6e17bc --broadcast --verify --verifier blockscout
// forge script src/script/hop/upgrade/UpgradeRemoteHopV2.s.sol --rpc-url https://evm-rpc.sei-apis.com --ffi --gcp --sender 0x54f9b12743a7deec0ea48721683cbebedc6e17bc --broadcast --verify --verifier etherscan --etherscan-api-key $ETHERSCAN_API_KEY
// forge script src/script/hop/upgrade/UpgradeRemoteHopV2.s.sol --rpc-url https://rpc.soniclabs.com --ffi --gcp --sender 0x54f9b12743a7deec0ea48721683cbebedc6e17bc --broadcast --verify --verifier etherscan --etherscan-api-key $ETHERSCAN_API_KEY
// forge script src/script/hop/upgrade/UpgradeRemoteHopV2.s.sol --rpc-url https://rpc.stable.xyz --ffi --gcp --sender 0x54f9b12743a7deec0ea48721683cbebedc6e17bc --broadcast --verify --verifier etherscan --etherscan-api-key $ETHERSCAN_API_KEY
// forge script src/script/hop/upgrade/UpgradeRemoteHopV2.s.sol --rpc-url https://unichain.drpc.org --ffi --gcp --sender 0x54f9b12743a7deec0ea48721683cbebedc6e17bc --broadcast --verify --verifier etherscan --etherscan-api-key $ETHERSCAN_API_KEY
// forge script src/script/hop/upgrade/UpgradeRemoteHopV2.s.sol --rpc-url https://worldchain-mainnet.g.alchemy.com/public --ffi --gcp --sender 0x54f9b12743a7deec0ea48721683cbebedc6e17bc --broadcast --verify --verifier etherscan --etherscan-api-key $ETHERSCAN_API_KEY
// forge script src/script/hop/upgrade/UpgradeRemoteHopV2.s.sol --rpc-url https://xlayerrpc.okx.com --ffi --legacy --gcp --sender 0x54f9b12743a7deec0ea48721683cbebedc6e17bc --broadcast --verify --verifier-url https://www.oklink.com/api/v5/explorer/contract/verify-source-code-plugin/XLAYER --verifier oklink --verifier-api-key $OKLINK_API_KEY
// forge script src/script/hop/upgrade/UpgradeRemoteHopV2.s.sol --rpc-url https://api.mainnet.abs.xyz --ffi --gcp --sender 0x54f9b12743a7deec0ea48721683cbebedc6e17bc --broadcast --verify --verifier etherscan --etherscan-api-key $ETHERSCAN_API_KEY
// forge script src/script/hop/upgrade/UpgradeRemoteHopV2.s.sol --rpc-url https://rpc.linea.build --ffi --gcp --sender 0x54f9b12743a7deec0ea48721683cbebedc6e17bc --broadcast --verify --verifier etherscan --etherscan-api-key $ETHERSCAN_API_KEY
// forge script src/script/hop/upgrade/UpgradeRemoteHopV2.s.sol --rpc-url https://rpc.scroll.io --ffi --gcp --sender 0x54f9b12743a7deec0ea48721683cbebedc6e17bc --broadcast --verify --verifier etherscan --etherscan-api-key $ETHERSCAN_API_KEY
// zksync
// forge script src/script/hop/upgrade/UpgradeRemoteHopV2.s.sol --rpc-url https://api.infra.mainnet.somnia.network --ffi --gcp --sender 0x54f9b12743a7deec0ea48721683cbebedc6e17bc --broadcast --verify
// forge script src/script/hop/upgrade/UpgradeRemoteHopV2.s.sol --rpc-url https://rpc.tempo.xyz --ffi --gcp --sender 0x54f9b12743a7deec0ea48721683cbebedc6e17bc --broadcast --verify

contract UpgradeRemoteHopV2 is UpgradeHopV2 {
    function setUp() public override {
        hop = 0x0000006D38568b00B457580b734e0076C62de659;
        super.setUp();
    }

    function deployImplementation() internal virtual override {
        vm.startBroadcast();

        if (block.chainid == 4217) {
            newImplementation = address(
                new RemoteHopV201Tempo{ salt: 0x4e59b44847b379578588920ca78fbf26c0b4956c9f4ed96d14900e7523000004 }(
                    0x20Bb7C2E2f4e5ca2B4c57060d1aE2615245dCc9C
                )
            );
            require(
                newImplementation == 0x00000000b2707226814D5792137fb0B482310A36,
                "Unexpected Tempo implementation address"
            );
        } else {
            newImplementation = address(
                new RemoteHopV201{ salt: 0x4e59b44847b379578588920ca78fbf26c0b4956ce6ac70492feaa59e63000008 }()
            );
            require(
                newImplementation == 0x0000000f9a66622C8885E1071B78E37b2b3ecCCd,
                "Unexpected implementation address"
            );
        }

        vm.stopBroadcast();
    }
}
