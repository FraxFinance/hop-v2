// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import { ERC20Upgradeable } from "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { RemoteVaultHop } from "src/contracts/vault/RemoteVaultHop.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { OwnableUpgradeable } from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";

// ====================================================================
// |     ______                   _______                             |
// |    / _____________ __  __   / ____(_____  ____ _____  ________   |
// |   / /_  / ___/ __ `| |/_/  / /_  / / __ \/ __ `/ __ \/ ___/ _ \  |
// |  / __/ / /  / /_/ _>  <   / __/ / / / / / /_/ / / / / /__/  __/  |
// | /_/   /_/   \__,_/_/|_|  /_/   /_/_/ /_/\__,_/_/ /_/\___/\___/   |
// |                                                                  |
// ====================================================================
// ======================= RemoteVaultDeposit =======================
// ====================================================================

/// @title RemoteVaultDeposit
/// @author Frax Finance: https://github.com/FraxFinance
/// @notice ERC20 token representing deposits in remote vaults, can only be minted/burned by the RemoteVault contract
contract RemoteVaultDeposit is ERC20Upgradeable, OwnableUpgradeable {
    struct RemoteVaultDepositStorage {
        /// @notice The RemoteVaultHop contract that controls this token
        address REMOTE_VAULT_HOP;
        /// @notice The chain ID where the vault is located
        uint32 VAULT_CHAIN_ID;
        /// @notice The address of the vault on the remote chain
        address VAULT_ADDRESS;
        /// @notice The asset deposited into the remote vault
        address ASSET;
        /// @notice Price per share of the remote vault
        uint128 pps;
        /// @notice Previous price per share of the remote vault
        uint128 previousPps;
        /// @notice Block number when price per share was last updated
        uint64 ppsUpdateBlock;
        /// @notice Timestamp of the last price per share update from the remote vault
        uint64 ppsRemoteTimestamp;
    }

    // keccak256(abi.encode(uint256(keccak256("frax.storage.RemoteVaultDeposit")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant RemoteVaultDepositStorageLocation =
        0xdfd688ac89bb25aa5cba198132afa506d2138bddc7e769ec5c5e7c28484c4700;

    function _getRemoteVaultDepositStorage() private pure returns (RemoteVaultDepositStorage storage $) {
        assembly {
            $.slot := RemoteVaultDepositStorageLocation
        }
    }

    /// @notice Only the RemoteVault contract can mint/burn tokens
    error OnlyRemoteVault();

    /// @notice Emitted when tokens are minted
    event Mint(address indexed to, uint256 amount);

    /// @notice Emitted when tokens are burned
    event Burn(address indexed from, uint256 amount);

    /// @notice Emitted when the price per share is updated
    event PricePerShareUpdated(uint64 remoteTimestamp, uint128 pricePerShare);

    constructor() {
        _disableInitializers();
    }

    /// @param _vaultChainId The chain ID where the vault is located
    /// @param _vaultAddress The address of the vault on the remote chain
    /// @param _name The name of the token
    /// @param _symbol The symbol of the token
    function initialize(
        uint32 _vaultChainId,
        address _vaultAddress,
        address _asset,
        string memory _name,
        string memory _symbol
    ) external initializer {
        __ERC20_init(_name, _symbol);
        __Ownable_init(msg.sender);

        RemoteVaultDepositStorage storage $ = _getRemoteVaultDepositStorage();
        $.REMOTE_VAULT_HOP = msg.sender;
        $.VAULT_CHAIN_ID = _vaultChainId;
        $.VAULT_ADDRESS = _vaultAddress;
        $.ASSET = _asset;
    }

    /// @notice Receive ETH payments
    receive() external payable {}

    /// @notice Mint tokens to a specific address
    /// @dev Can only be called by the RemoteVault contract (owner)
    /// @param to The address to mint tokens to
    /// @param amount The amount of tokens to mint
    function mint(address to, uint256 amount) external onlyOwner {
        _mint(to, amount);
        emit Mint(to, amount);
    }

    /// @notice Get the current price per share of the remote vault
    /// @dev Returns the last known price per share, with a simple linear interpolation if called within 100 blocks of the last update
    function pricePerShare() public view returns (uint256) {
        RemoteVaultDepositStorage storage $ = _getRemoteVaultDepositStorage();
        uint128 pps = $.pps;
        uint256 ppsUpdateBlock = $.ppsUpdateBlock;
        uint128 previousPps = $.previousPps;

        if (block.number > ppsUpdateBlock + 99) return pps;

        int256 currentPpsInt = int256(uint256(pps));
        int256 previousPpsInt = int256(uint256(previousPps));
        int256 delta = currentPpsInt - previousPpsInt;
        int256 interpolated = previousPpsInt + (delta * int256(block.number - ppsUpdateBlock)) / 100;

        return uint256(interpolated);
    }

    /// @notice Set the price per share of the remote vault
    /// @dev Can only be called by the owner (RemoteVault contract)
    function setPricePerShare(uint64 _remoteTimestamp, uint128 _pricePerShare) external onlyOwner {
        RemoteVaultDepositStorage storage $ = _getRemoteVaultDepositStorage();
        if (_pricePerShare > 0 && _remoteTimestamp > $.ppsRemoteTimestamp) {
            $.previousPps = uint128(pricePerShare());
            if ($.previousPps == 0) $.previousPps = _pricePerShare;
            $.ppsUpdateBlock = uint64(block.number);
            $.ppsRemoteTimestamp = _remoteTimestamp;
            $.pps = _pricePerShare;
            emit PricePerShareUpdated(_remoteTimestamp, _pricePerShare);
        }
    }

    function deposit(uint256 _amount) external payable {
        deposit(_amount, msg.sender);
    }

    function deposit(uint256 _amount, address _to) public payable {
        RemoteVaultDepositStorage storage $ = _getRemoteVaultDepositStorage();

        SafeERC20.safeTransferFrom(IERC20($.ASSET), msg.sender, address($.REMOTE_VAULT_HOP), _amount);
        RemoteVaultHop(payable($.REMOTE_VAULT_HOP)).deposit{ value: msg.value }(
            _amount,
            $.VAULT_CHAIN_ID,
            $.VAULT_ADDRESS,
            _to
        );
        if (address(this).balance > 0) {
            (bool success, ) = msg.sender.call{ value: address(this).balance }("");
            require(success, "Refund failed");
        }
    }

    function redeem(uint256 _amount) public payable {
        redeem(_amount, msg.sender);
    }

    function redeem(uint256 _amount, address _to) public payable {
        _burn(msg.sender, _amount);
        emit Burn(msg.sender, _amount);

        RemoteVaultDepositStorage storage $ = _getRemoteVaultDepositStorage();

        RemoteVaultHop(payable($.REMOTE_VAULT_HOP)).redeem{ value: msg.value }(
            _amount,
            $.VAULT_CHAIN_ID,
            $.VAULT_ADDRESS,
            _to
        );
        if (address(this).balance > 0) {
            (bool success, ) = msg.sender.call{ value: address(this).balance }("");
            require(success, "Refund failed");
        }
    }

    function quote(uint256 _amount) public view returns (uint256) {
        RemoteVaultDepositStorage storage $ = _getRemoteVaultDepositStorage();
        return RemoteVaultHop(payable($.REMOTE_VAULT_HOP)).quote(_amount, $.VAULT_CHAIN_ID, $.VAULT_ADDRESS);
    }
}
