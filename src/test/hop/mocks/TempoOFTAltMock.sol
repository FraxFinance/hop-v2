// SPDX-License-Identifier: UNLICENSED
pragma solidity >=0.8.23;

import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { OFTAlt } from "@layerzerolabs/oft-alt-evm/contracts/OFTAlt.sol";

/// @notice Full OFT for Tempo using Alt (ERC20 gas) with mint/burn
/// @dev Mimics FraxOFTUpgradeableTempo - the OFT IS the token
/// @dev Architecture: Tempo side uses this OFT, Fraxtal uses OFTAdapter wrapping ERC20
contract TempoOFTAltMock is OFTAlt {
    constructor(
        string memory _name,
        string memory _symbol,
        address _lzEndpoint,
        address _delegate
    ) OFTAlt(_name, _symbol, _lzEndpoint, _delegate) Ownable(_delegate) {}

    /// @dev Mint tokens (for testing)
    function mint(address _to, uint256 _amount) external {
        _mint(_to, _amount);
    }

    /// @dev Burn tokens (for testing)
    function burn(address _from, uint256 _amount) external {
        _burn(_from, _amount);
    }

    /// @dev 18 decimal token with sharedDecimals = 6
    function sharedDecimals() public pure override returns (uint8) {
        return 6;
    }
}
