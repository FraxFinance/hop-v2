// SPDX-License-Identifier: UNLICENSED
pragma solidity >=0.8.23;

import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { OFT } from "@layerzerolabs/oft-evm/contracts/OFT.sol";

/// @notice Full OFT for Chain A (any EVM chain except Fraxtal/Tempo) using standard ETH gas
/// @dev Mint/burn pattern, used with RemoteHopV2 for hopping through Fraxtal hub
contract ChainAOFTMock is OFT {
    constructor(
        string memory _name,
        string memory _symbol,
        address _lzEndpoint,
        address _delegate
    ) OFT(_name, _symbol, _lzEndpoint, _delegate) Ownable(_delegate) {}

    function mint(address _to, uint256 _amount) external {
        _mint(_to, _amount);
    }

    function burn(address _from, uint256 _amount) external {
        _burn(_from, _amount);
    }

    /// @dev Use 6 shared decimals (standard for Frax tokens)
    function sharedDecimals() public pure override returns (uint8) {
        return 6;
    }
}
