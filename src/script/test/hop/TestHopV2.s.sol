pragma solidity ^0.8.0;

import { BaseScript } from "frax-std/BaseScript.sol";
import { IHopV2 } from "src/contracts/interfaces/IHopV2.sol";

interface IERC20 {
    function approve(address spender, uint256 amount) external;
}

interface IOFT {
    function token() external view returns (address);
}

// forge script src/script/test/TestHopV2.s.sol --rpc-url https://mainnet.base.org --broadcast
contract TestHopV2 is BaseScript {
    uint256 public configDeployerPK = vm.envUint("PK_CONFIG_DEPLOYER");

    function run() public {
        IHopV2 hopV2 = IHopV2(0x1b93526eA567d59B7FD38126bb74D72818166C51);

        // hop arguments
        address oft = 0x96A394058E2b84A89bac9667B19661Ed003cF5D4;
        uint32 dstEid = 30_184;
        bytes32 recipient = bytes32(uint256(uint160(0x378699c6F0f77033024b3b1F3796d67a9AC82D5D)));
        uint256 amountLD = 0.0001e18;
        uint128 dstGas = 250_000;
        bytes memory data = "hello world";

        // quote cost of send
        uint256 fee = hopV2.quote(oft, dstEid, recipient, amountLD, dstGas, data);

        // approve OFT underlying token to be transferred to the HopV2
        vm.startBroadcast(configDeployerPK);
        IERC20(IOFT(oft).token()).approve(address(hopV2), amountLD);

        // send the OFT to destination
        hopV2.sendOFT{ value: fee }(oft, dstEid, recipient, amountLD, dstGas, data);
    }
}
