// SPDX-License-Identifier: UNLICENSED
pragma solidity >=0.8.23;

import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { OFTAdapter } from "@layerzerolabs/oft-evm/contracts/OFTAdapter.sol";

/// @notice OFT Adapter for Fraxtal wrapping an ERC20 token (lock/unlock pattern)
/// @dev Standard OFTAdapter that locks tokens on send and unlocks on receive
/// @dev Uses native ETH for gas (standard endpoint, not Alt)
contract FraxtalOFTAdapterMock is OFTAdapter {
    constructor(
        address _token,
        address _lzEndpoint,
        address _delegate
    ) OFTAdapter(_token, _lzEndpoint, _delegate) Ownable(_delegate) {}

    /// @dev 18 decimal token with sharedDecimals = 6
    function sharedDecimals() public pure override returns (uint8) {
        return 6;
    }
}
