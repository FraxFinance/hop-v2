pragma solidity 0.8.23;

import { UpgradeHopV2 } from "src/script/hop/upgrade/UpgradeHopV2.sol";
import { RemoteHopV201 } from "src/contracts/hop/RemoteHopV201.sol";

// forge script src/script/hop/upgrade/UpgradeRemoteHopV2.s.sol --rpc-url https://api.zan.top/arb-one --ffi --gcp --sender 0x54f9b12743a7deec0ea48721683cbebedc6e17bc --broadcast --verify --verifier etherscan --etherscan-api-key $ETHERSCAN_API_KEY
// forge script src/script/hop/upgrade/UpgradeRemoteHopV2.s.sol --rpc-url https://api.avax.network/ext/bc/C/rpc  --ffi --gcp --sender 0x54f9b12743a7deec0ea48721683cbebedc6e17bc --broadcast --verify --verifier-url 'https://api.routescan.io/v2/network/mainnet/evm/43114/etherscan'
// forge script src/script/hop/upgrade/UpgradeRemoteHopV2.s.sol --rpc-url https://mainnet.base.org --ffi --gcp --sender 0x54f9b12743a7deec0ea48721683cbebedc6e17bc --broadcast --verify --verifier etherscan --etherscan-api-key $ETHERSCAN_API_KEY
// forge script src/script/hop/upgrade/UpgradeRemoteHopV2.s.sol --rpc-url https://bsc-mainnet.public.blastapi.io --ffi --gcp --sender 0x54f9b12743a7deec0ea48721683cbebedc6e17bc --broadcast --verify --verifier etherscan --etherscan-api-key $ETHERSCAN_API_KEY
// forge script src/script/hop/upgrade/UpgradeRemoteHopV2.s.sol --rpc-url https://ethereum-rpc.publicnode.com --ffi --gcp --sender 0x54f9b12743a7deec0ea48721683cbebedc6e17bc --broadcast --verify --verifier etherscan --etherscan-api-key $ETHERSCAN_API_KEY
// forge script src/script/hop/upgrade/UpgradeRemoteHopV2.s.sol --rpc-url https://hyperliquid.drpc.org --ffi --gcp --sender 0x54f9b12743a7deec0ea48721683cbebedc6e17bc --broadcast --verify --verifier etherscan --etherscan-api-key $ETHERSCAN_API_KEY
// forge script src/script/hop/upgrade/UpgradeRemoteHopV2.s.sol --rpc-url https://rpc-gel.inkonchain.com --ffi --gcp --sender 0x54f9b12743a7deec0ea48721683cbebedc6e17bc --broadcast --verify --verifier etherscan --verifier-url "https://api.routescan.io/v2/network/mainnet/evm/57073/etherscan" --etherscan-api-key "verifyContract"
// forge script src/script/hop/upgrade/UpgradeRemoteHopV2.s.sol --rpc-url https://rpc.katana.network --ffi --gcp --sender 0x54f9b12743a7deec0ea48721683cbebedc6e17bc --broadcast --verify --verifier etherscan --verifier-url "https://api.etherscan.io/v2/api?chainid=747474" --etherscan-api-key $ETHERSCAN_API_KEY
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
// forge script src/script/hop/upgrade/UpgradeRemoteHopV2.s.sol --rpc-url https://forno.celo.org --ffi --gcp --sender 0x54f9b12743a7deec0ea48721683cbebedc6e17bc --broadcast --priority-gas-price 2500000000 --verify --verifier etherscan --verifier-url "https://api.etherscan.io/v2/api?chainid=42220" --etherscan-api-key $ETHERSCAN_API_KEY
// forge script src/script/hop/upgrade/UpgradeRemoteHopV2.s.sol --rpc-url https://rpc.mainnet.chain.robinhood.com --ffi --gcp --sender 0x54f9b12743a7deec0ea48721683cbebedc6e17bc --broadcast --verify --verifier sourcify
// forge script src/script/hop/upgrade/UpgradeRemoteHopV2.s.sol --rpc-url https://rpc.linea.build --ffi --gcp --sender 0x54f9b12743a7deec0ea48721683cbebedc6e17bc --broadcast --verify --verifier etherscan --etherscan-api-key $ETHERSCAN_API_KEY
// zksync
// forge script src/script/hop/upgrade/UpgradeRemoteHopV2.s.sol --rpc-url https://api.infra.mainnet.somnia.network --ffi --gcp --sender 0x54f9b12743a7deec0ea48721683cbebedc6e17bc --broadcast --verify

contract UpgradeRemoteHopV2 is UpgradeHopV2 {
    function setUp() public override {
        hop = 0x0000006D38568b00B457580b734e0076C62de659;
        super.setUp();
    }

    bytes32 internal constant SALT = 0x4e59b44847b379578588920ca78fbf26c0b4956ce6ac70492feaa59e63000008;

    function deployImplementation() internal virtual override {
        require(block.chainid != 4217, "Tempo: use UpgradeRemoteHopV2Tempo.s.sol");

        newImplementation = _deployCreate2(SALT, type(RemoteHopV201).creationCode);
    }
}
