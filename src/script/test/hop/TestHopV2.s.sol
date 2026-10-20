pragma solidity ^0.8.0;

import { BaseScript } from "frax-std/BaseScript.sol";
import { IHopV2 } from "src/contracts/interfaces/IHopV2.sol";

interface IERC20 {
    function approve(address spender, uint256 amount) external;
}

interface IOFT {
    function token() external view returns (address);
}

// forge script src/script/test/hop/TestHopV2.s.sol --rpc-url https://mainnet.base.org --broadcast
contract TestHopV2 is BaseScript {
    uint256 public configDeployerPK = vm.envUint("PK_CONFIG_DEPLOYER");

    function run() public {
        IHopV2 hopV2 = IHopV2(0x7C5004F64F86728b5d852CeEc7987333114b206d);

        // hop arguments
        address oft = 0xe5020A6d073a794B6E7f05678707dE47986Fb0b6;
        uint32 dstEid = 30_110;
        bytes32 recipient = bytes32(uint256(uint160(0x742109450E2466421b00A2Bf61D513D2616a74FC))); // arbitrum mock hopcomposer
        uint256 amountLD = 0.0001e18;
        uint128 dstGas = 0;
        bytes memory data = new bytes(9500);

        // quote cost of send
        uint256 fee = hopV2.quote(oft, dstEid, recipient, amountLD, dstGas, data);

        // approve OFT underlying token to be transferred to the HopV2
        vm.startBroadcast(configDeployerPK);
        IERC20(IOFT(oft).token()).approve(address(hopV2), amountLD);

        // send the OFT to destination
        hopV2.sendOFT{ value: fee }(oft, dstEid, recipient, amountLD, dstGas, data);
    }
}
