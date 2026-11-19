// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

/// @title HopActions
/// @notice Action tags carried in `HopMessage.data`. The Fraxtal hub executes a tagged action on the
///         tokens it receives (today: frxUSD <-> sfrxUSD through the Fraxtal mint-redeemer) and then
///         forwards the result to `recipient` on `dstEid` as a plain OFT send, with `data` cleared.
/// @dev A tag is exactly four bytes so it can never collide with a composer payload, which is
///      ABI-encoded and therefore at least 32 bytes long.
library HopActions {
    /// @dev bytes4(keccak256("frax.hop.action.mintRedeem.v1"))
    bytes4 internal constant MINT_REDEEM = 0xd71e9971;

    /// @dev lzCompose gas a spoke books for the Fraxtal hub when the message carries `MINT_REDEEM`.
    ///      Measured on a Fraxtal fork: the mint-redeemer alone costs ~155k and the legacy hub's full
    ///      compose (validation, conversion, lockbox send) ~750k against the 1,000,000 default budget.
    uint128 internal constant HUB_GAS_MINT_REDEEM = 1_500_000;

    function isMintRedeem(bytes memory _data) internal pure returns (bool) {
        return _data.length == 4 && bytes4(_data) == MINT_REDEEM;
    }
}
