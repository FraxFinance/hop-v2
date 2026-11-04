// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import { AccessControlEnumerableUpgradeable } from "@openzeppelin/contracts-upgradeable/access/extensions/AccessControlEnumerableUpgradeable.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { IOFT } from "@fraxfinance/layerzero-v2-upgradeable/oapp/contracts/oft/interfaces/IOFT.sol";

import { IHopActionModule } from "src/contracts/interfaces/IHopActionModule.sol";
import { IFraxtalERC4626MintRedeemer } from "src/contracts/interfaces/IFraxtalERC4626MintRedeemer.sol";
import { HopActions } from "src/contracts/libraries/HopActions.sol";

// ====================================================================
// |     ______                   _______                             |
// |    / _____________ __  __   / ____(_____  ____ _____  ________   |
// |   / /_  / ___/ __ `| |/_/  / /_  / / __ \/ __ `/ __ \/ ___/ _ \  |
// |  / __/ / /  / /_/ _>  <   / __/ / / / / / /_/ / / / / /__/  __/  |
// | /_/   /_/   \__,_/_/|_|  /_/   /_/_/ /_/\__,_/_/ /_/\___/\___/   |
// |                                                                  |
// ====================================================================
// ========================= MintRedeemModule =========================
// ====================================================================

/// @title MintRedeemModule
/// @notice Fraxtal-only action module behind `FraxtalHopV201`. Converts frxUSD <-> sfrxUSD through the
///         Fraxtal mint-redeemer for the `HopActions.MINT_REDEEM` tag. The hub approves this module for
///         the input token and calls `convert`; the output is minted or paid straight to the hub, so the
///         module holds nothing between calls.
/// @dev Upgradeable behind the hub's ProxyAdmin. Any mint-redeemer change (address, fee, oracle) is
///      absorbed here; the hub never needs another upgrade for it.
/// @author Frax Finance: https://github.com/FraxFinance
contract MintRedeemModule is AccessControlEnumerableUpgradeable, IHopActionModule {
    struct MintRedeemModuleStorage {
        /// @dev The only caller allowed to convert
        address hub;
        /// @dev Fraxtal frxUSD <-> sfrxUSD mint-redeemer
        address mintRedeemer;
        /// @dev OFT whose token() is the redeemer's asset (frxUSD lockbox)
        address assetOft;
        /// @dev OFT whose token() is the redeemer's share (sfrxUSD lockbox)
        address shareOft;
        /// @dev Admin kill switch; a paused module makes the hub revert tagged messages, which stay retryable
        bool paused;
    }

    // keccak256(abi.encode(uint256(keccak256("frax.storage.MintRedeemModule")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant MintRedeemModuleStorageLocation =
        0x5fc1efba3f6517d84b43cdff25b9ae95f4bfeb742b621f011156acc456a07a00;

    function _getMintRedeemModuleStorage() private pure returns (MintRedeemModuleStorage storage $) {
        assembly {
            $.slot := MintRedeemModuleStorageLocation
        }
    }

    event Converted(address indexed oftIn, address indexed oftOut, uint256 amountIn, uint256 amountOut);
    event HubSet(address indexed hub);
    event MintRedeemerSet(address indexed mintRedeemer);
    event OftsSet(address indexed assetOft, address indexed shareOft);
    event PausedSet(bool paused);
    event RecoveredERC20(address indexed token, address indexed recipient, uint256 amount);

    error NotHub();
    error ModulePaused();
    error UnknownAction();
    error UnsupportedOFT();
    error ZeroOutput();
    error ZeroAddress();

    constructor() {
        _disableInitializers();
    }

    function initialize(
        address _admin,
        address _hub,
        address _mintRedeemer,
        address _assetOft,
        address _shareOft
    ) external initializer {
        if (_admin == address(0)) revert ZeroAddress();
        _grantRole(DEFAULT_ADMIN_ROLE, _admin);
        _setHub(_hub);
        _setMintRedeemer(_mintRedeemer);
        _setOfts(_assetOft, _shareOft);
    }

    function version() external pure returns (string memory) {
        return "1.0.0";
    }

    // Action

    /// @inheritdoc IHopActionModule
    function outputOft(bytes4 _action, address _oftIn) public view returns (address oftOut) {
        if (_action != HopActions.MINT_REDEEM) revert UnknownAction();
        MintRedeemModuleStorage storage $ = _getMintRedeemModuleStorage();
        if (_oftIn == $.assetOft) return $.shareOft;
        if (_oftIn == $.shareOft) return $.assetOft;
        revert UnsupportedOFT();
    }

    /// @inheritdoc IHopActionModule
    /// @dev Direction is decided before anything is pulled. `deposit` mints the shares to the hub and
    ///      `redeem` pays the assets to the hub, so no transfer back is needed.
    function convert(
        bytes4 _action,
        address _oftIn,
        uint256 _amountIn
    ) external returns (address oftOut, uint256 amountOut) {
        MintRedeemModuleStorage storage $ = _getMintRedeemModuleStorage();
        if (msg.sender != $.hub) revert NotHub();
        if ($.paused) revert ModulePaused();
        oftOut = outputOft(_action, _oftIn);

        IFraxtalERC4626MintRedeemer redeemer = IFraxtalERC4626MintRedeemer($.mintRedeemer);
        IERC20 tokenIn = IERC20(IOFT(_oftIn).token());
        SafeERC20.safeTransferFrom(tokenIn, msg.sender, address(this), _amountIn);
        SafeERC20.forceApprove(tokenIn, address(redeemer), _amountIn);

        if (_oftIn == $.assetOft) {
            amountOut = redeemer.deposit(_amountIn, msg.sender);
        } else {
            amountOut = redeemer.redeem(_amountIn, msg.sender, address(this));
        }
        if (amountOut == 0) revert ZeroOutput();

        emit Converted(_oftIn, oftOut, _amountIn, amountOut);
    }

    // Admin

    function setHub(address _hub) external onlyRole(DEFAULT_ADMIN_ROLE) {
        _setHub(_hub);
    }

    function setMintRedeemer(address _mintRedeemer) external onlyRole(DEFAULT_ADMIN_ROLE) {
        _setMintRedeemer(_mintRedeemer);
    }

    function setOfts(address _assetOft, address _shareOft) external onlyRole(DEFAULT_ADMIN_ROLE) {
        _setOfts(_assetOft, _shareOft);
    }

    function setPaused(bool _paused) external onlyRole(DEFAULT_ADMIN_ROLE) {
        _getMintRedeemModuleStorage().paused = _paused;
        emit PausedSet(_paused);
    }

    /// @notice Sweep anything stranded here; the module holds nothing between calls.
    function recoverERC20(address _token, address _recipient, uint256 _amount) external onlyRole(DEFAULT_ADMIN_ROLE) {
        SafeERC20.safeTransfer(IERC20(_token), _recipient, _amount);
        emit RecoveredERC20(_token, _recipient, _amount);
    }

    function _setHub(address _hub) internal {
        if (_hub == address(0)) revert ZeroAddress();
        _getMintRedeemModuleStorage().hub = _hub;
        emit HubSet(_hub);
    }

    function _setMintRedeemer(address _mintRedeemer) internal {
        if (_mintRedeemer == address(0)) revert ZeroAddress();
        _getMintRedeemModuleStorage().mintRedeemer = _mintRedeemer;
        emit MintRedeemerSet(_mintRedeemer);
    }

    function _setOfts(address _assetOft, address _shareOft) internal {
        if (_assetOft == address(0) || _shareOft == address(0) || _assetOft == _shareOft) revert ZeroAddress();
        MintRedeemModuleStorage storage $ = _getMintRedeemModuleStorage();
        $.assetOft = _assetOft;
        $.shareOft = _shareOft;
        emit OftsSet(_assetOft, _shareOft);
    }

    // Views

    function hub() external view returns (address) {
        return _getMintRedeemModuleStorage().hub;
    }

    function mintRedeemer() external view returns (address) {
        return _getMintRedeemModuleStorage().mintRedeemer;
    }

    function assetOft() external view returns (address) {
        return _getMintRedeemModuleStorage().assetOft;
    }

    function shareOft() external view returns (address) {
        return _getMintRedeemModuleStorage().shareOft;
    }

    function paused() external view returns (bool) {
        return _getMintRedeemModuleStorage().paused;
    }
}
