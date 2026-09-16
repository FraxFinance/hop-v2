# 1 — canonical V201 (NO profile)
```
forge script src/script/hop/DeployRemoteHopV201.s.sol --rpc-url https://rpc.mainnet.chain.robinhood.com --gcp --sender 0x54f9b12743a7deec0ea48721683cbebedc6e17bc --broadcast
```

# 2 — full hop deploy (deploy profile; re-dry-run against the real RPC first now that V201 exists)

```
FOUNDRY_PROFILE=deploy forge script src/script/hop/DeployRemoteHopV2Robinhood.s.sol --rpc-url https://rpc.mainnet.chain.robinhood.com --gcp --sender 0x54f9b12743a7deec0ea48721683cbebedc6e17bc --broadcast
```