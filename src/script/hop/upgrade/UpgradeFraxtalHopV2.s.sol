// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import { UpgradeHopV2 } from "src/script/hop/upgrade/UpgradeHopV2.sol";
import { FraxtalHopV201 } from "src/contracts/hop/FraxtalHopV201.sol";
import { MintRedeemModule } from "src/contracts/hop/MintRedeemModule.sol";
import { HopActions } from "src/contracts/libraries/HopActions.sol";
import { SafeTx } from "frax-std/SafeTxHelper.sol";

// forge script src/script/hop/upgrade/UpgradeFraxtalHopV2.s.sol --rpc-url https://rpc.frax.com --ffi --gcp --sender 0x54f9b12743a7deec0ea48721683cbebedc6e17bc --broadcast --verify --verifier etherscan --etherscan-api-key $ETHERSCAN_API_KEY
//
// Hop 2.1.0 on the Fraxtal hub: deploys FraxtalHopV201 (plain CREATE) and writes the Fraxtal Safe batch
//   [upgradeAndCall(hub, impl), grantRole(RECOVER_ETH_ROLE, msig), setActionModule(ACTION_MODULE)]
// ACTION_MODULE is the MintRedeemModule proxy from DeployMintRedeemModule.s.sol. Leave it unset to omit the call.
contract UpgradeFraxtalHopV2 is UpgradeHopV2 {
    function setUp() public override {
        hop = 0x00000000e18aFc20Afe54d4B2C8688bB60c06B36;
        super.setUp();
    }

    function deployImplementation() internal virtual override {
        vm.startBroadcast();
        newImplementation = address(new FraxtalHopV201());
        vm.stopBroadcast();
    }

    /// @dev A module with code is not enough: it must be the mint/redeem module wired for THIS hub, with both OFTs of
    ///      its pair approved on the hub and a live mint-redeemer, or tagged sends would start reverting right after
    ///      the upgrade. Runs against the simulated post-upgrade hub, which already exposes `approvedOft`.
    function _assertActionModule(address _module) internal view {
        require(_module.code.length != 0, "ACTION_MODULE has no code");
        MintRedeemModule module = MintRedeemModule(_module);
        require(module.hub() == hop, "ACTION_MODULE is wired for another hub");
        require(module.mintRedeemer().code.length != 0, "ACTION_MODULE mint-redeemer has no code");
        address assetOft = module.assetOft();
        address shareOft = module.shareOft();
        FraxtalHopV201 fraxtalHop = FraxtalHopV201(payable(hop));
        require(
            fraxtalHop.approvedOft(assetOft) && fraxtalHop.approvedOft(shareOft),
            "ACTION_MODULE pair not approved"
        );
        require(module.outputOft(HopActions.MINT_REDEEM, assetOft) == shareOft, "ACTION_MODULE pair mismatch");
        require(module.outputOft(HopActions.MINT_REDEEM, shareOft) == assetOft, "ACTION_MODULE pair mismatch");
        require(!module.paused(), "ACTION_MODULE is paused");
    }

    /// @dev Runs under the msig prank right after the simulated upgrade, so the hub already exposes setActionModule.
    function _appendExtraTxs() internal override {
        address module = vm.envOr("ACTION_MODULE", address(0));
        if (module == address(0)) return;
        _assertActionModule(module);

        bytes memory data = abi.encodeCall(FraxtalHopV201.setActionModule, (module));
        (bool success, ) = hop.call(data);
        require(success, "setActionModule failed");
        safeTxs.push(SafeTx({ name: "set action module", to: hop, value: 0, data: data }));
    }
}
