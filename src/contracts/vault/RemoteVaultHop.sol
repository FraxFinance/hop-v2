pragma solidity ^0.8.0;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { IERC20Metadata } from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import { IERC4626 } from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import { AccessControlEnumerableUpgradeable } from "@openzeppelin/contracts-upgradeable/access/extensions/AccessControlEnumerableUpgradeable.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { IHopComposer } from "src/contracts/interfaces/IHopComposer.sol";
import { IHopV2 } from "src/contracts/interfaces/IHopV2.sol";
import { RemoteVaultDeposit } from "src/contracts/vault/RemoteVaultDeposit.sol";
import { IOFT2 } from "src/contracts/interfaces/IOFT2.sol";
import { FraxUpgradeableProxy } from "frax-std/FraxUpgradeableProxy.sol";

// ====================================================================
// |     ______                   _______                             |
// |    / _____________ __  __   / ____(_____  ____ _____  ________   |
// |   / /_  / ___/ __ `| |/_/  / /_  / / __ \/ __ `/ __ \/ ___/ _ \  |
// |  / __/ / /  / /_/ _>  <   / __/ / / / / / /_/ / / / / /__/  __/  |
// | /_/   /_/   \__,_/_/|_|  /_/   /_/_/ /_/\__,_/_/ /_/\___/\___/   |
// |                                                                  |
// ====================================================================
// =========================== RemoteVault ============================
// ====================================================================

/// @author Frax Finance: https://github.com/FraxFinance
contract RemoteVaultHop is AccessControlEnumerableUpgradeable, IHopComposer {
    uint128 public constant DEFAULT_REMOTE_GAS = 400_000;
    uint32 public constant FRAXTAL_EID = 30_255;
    uint32 public constant LOCAL_GAS = 400_000;

    struct RemoteVaultHopStorage {
        IERC20 TOKEN;
        address OFT;
        IHopV2 HOP;
        uint32 EID; // This chain's EID on LayerZero
        uint256 DECIMAL_CONVERSION_RATE;
        address implementation;
        address proxyAdmin;
        // Local vault management
        /// @notice The vault share token by vault address
        mapping(address => address) vaultShares;
        /// @notice The balance of shares owned by users in remote vaults
        mapping(uint32 => mapping(address => uint256)) balance; // vault => srcEid => srcAddress => shares
        // Remote vault management
        /// @notice Remote vault hop address by eid
        mapping(uint32 => address) remoteVaultHops;
        /// @notice Deposit token mapping for tracking user deposits in remote vaults
        mapping(uint32 => mapping(address => RemoteVaultDeposit)) depositToken; // eid => vault => rvd
        /// @notice The token used for deposits and withdrawals
        mapping(uint32 => mapping(address => uint128)) remoteGas; // eid => vault => remote gas
    }

    // keccak256(abi.encode(uint256(keccak256("frax.storage.RemoteVaultHop")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant RemoteVaultHopStorageLocation =
        0xb011a2b9c7887d2611adbf2b472db6b2906944d90d3561a6da3a04c2dbdb4400;

    function _getRemoteVaultHopStorage() private pure returns (RemoteVaultHopStorage storage $) {
        assembly {
            $.slot := RemoteVaultHopStorageLocation
        }
    }

    /// @notice Message structure for cross-chain communication
    /// @dev Used in hopCompose to decode incoming messages
    struct RemoteVaultMessage {
        Action action;
        uint32 userEid;
        address userAddress;
        uint32 remoteEid;
        address remoteVault;
        uint256 amount;
        uint64 remoteTimestamp;
        uint128 pricePerShare;
    }

    enum Action {
        Deposit,
        DepositReturn,
        Redeem,
        RedeemReturn
    }

    error InvalidChain();
    error InvalidOFT();
    error InsufficientFee();
    error NotHop();
    error InvalidAction();
    error InvalidVault();
    error InvalidAmount();
    error VaultExists();
    error RefundFailed();
    error InvalidCaller();

    event VaultAdded(address vault, address share);
    event RemoteVaultAdded(uint32 eid, address vault, string name, string symbol);
    event RemoteVaultHopSet(uint32 eid, address remoteVaultHop);
    event RemoteGasSet(uint32 eid, address vault, uint128 remoteGas);
    event Deposit(address indexed to, uint32 indexed remoteEid, address indexed remoteVault, uint256 amount);
    event DepositReturn(address indexed to, uint32 indexed remoteEid, address indexed remoteVault, uint256 amount);
    event Redeem(address indexed to, uint32 indexed remoteEid, address indexed remoteVault, uint256 amount);
    event RedeemReturn(address indexed to, uint32 indexed remoteEid, address indexed remoteVault, uint256 amount);

    constructor() {
        _disableInitializers();
    }

    function initialize(
        address _token,
        address _oft,
        address _hop,
        uint32 _eid,
        address _proxyAdmin,
        address _implementation
    ) external initializer {
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);

        RemoteVaultHopStorage storage $ = _getRemoteVaultHopStorage();
        $.TOKEN = IERC20(_token);
        $.OFT = _oft;
        $.HOP = IHopV2(_hop);
        $.EID = _eid;
        $.DECIMAL_CONVERSION_RATE = IOFT2(_oft).decimalConversionRate();

        $.proxyAdmin = _proxyAdmin;

        $.implementation = _implementation;
    }

    /// @notice Receive ETH payments
    receive() external payable {}

    function deposit(
        uint256 _amount,
        uint32 _remoteEid,
        address _remoteVault,
        address _to
    ) external payable returns (uint256) {
        RemoteVaultHopStorage storage $ = _getRemoteVaultHopStorage();

        if ($.remoteVaultHops[_remoteEid] == address(0)) revert InvalidChain();
        if (address($.depositToken[_remoteEid][_remoteVault]) != msg.sender) revert InvalidCaller();

        _amount = removeDust(_amount);
        uint256 fee = quote(_amount, _remoteEid, _remoteVault);
        if (msg.value < fee) revert InsufficientFee();

        IHopV2 HOP_ = $.HOP; // gas
        SafeERC20.forceApprove($.TOKEN, address(HOP_), _amount);
        bytes memory hopComposeMessage = abi.encode(
            RemoteVaultMessage({
                action: Action.Deposit,
                userEid: $.EID,
                userAddress: _to,
                remoteEid: _remoteEid,
                remoteVault: _remoteVault,
                amount: _amount,
                remoteTimestamp: 0,
                pricePerShare: 0
            })
        );
        uint128 _remoteGas = getRemoteVaultGas(_remoteEid, _remoteVault);
        HOP_.sendOFT{ value: fee }(
            $.OFT,
            _remoteEid,
            bytes32(uint256(uint160($.remoteVaultHops[_remoteEid]))),
            _amount,
            _remoteGas,
            hopComposeMessage
        );
        if (msg.value > fee) {
            (bool success, ) = msg.sender.call{ value: msg.value - fee }("");
            if (!success) revert RefundFailed();
        }
        emit Deposit(_to, _remoteEid, _remoteVault, _amount);

        return fee;
    }

    function redeem(
        uint256 _amount,
        uint32 _remoteEid,
        address _remoteVault,
        address _to
    ) external payable returns (uint256) {
        RemoteVaultHopStorage storage $ = _getRemoteVaultHopStorage();

        if ($.remoteVaultHops[_remoteEid] == address(0)) revert InvalidChain();
        if (address($.depositToken[_remoteEid][_remoteVault]) != msg.sender) revert InvalidCaller();

        uint256 fee = quote(_amount, _remoteEid, _remoteVault);
        if (msg.value < fee) revert InsufficientFee();
        bytes memory hopComposeMessage = abi.encode(
            RemoteVaultMessage({
                action: Action.Redeem,
                userEid: $.EID,
                userAddress: _to,
                remoteEid: _remoteEid,
                remoteVault: _remoteVault,
                amount: _amount,
                remoteTimestamp: 0,
                pricePerShare: 0
            })
        );
        uint128 _remoteGas = getRemoteVaultGas(_remoteEid, _remoteVault);
        $.HOP.sendOFT{ value: fee }(
            $.OFT,
            _remoteEid,
            bytes32(uint256(uint160($.remoteVaultHops[_remoteEid]))),
            0,
            _remoteGas,
            hopComposeMessage
        );
        if (msg.value > fee) {
            (bool success, ) = msg.sender.call{ value: msg.value - fee }("");
            if (!success) revert RefundFailed();
        }
        emit Redeem(_to, _remoteEid, _remoteVault, _amount);
        return fee;
    }

    /// @notice Quotes the cost to hop to a remote vault and back.  This can be either through:
    ///     - (1) A => Fraxtal then (2) A <= Fraxtal
    ///     - (1) A => Fraxtal => B then (2) A <= Fraxtal <= B
    ///     - A => A or Fraxtal => Fraxtal (no hop needed)
    ///     - (1) Fraxtal => A then (2) Fraxtal <= A
    function quote(uint256 _amount, uint32 _remoteEid, address _remoteVault) public view returns (uint256) {
        RemoteVaultHopStorage storage $ = _getRemoteVaultHopStorage();
        uint32 EID_ = $.EID; // gas
        IHopV2 HOP_ = $.HOP; // gas

        if (_remoteEid == EID_) return 0; // No hop needed (A => A or Fraxtal => Fraxtal)
        bytes memory hopComposeMessage = abi.encode(
            RemoteVaultMessage({
                action: Action.Redeem,
                userEid: EID_,
                userAddress: msg.sender,
                remoteEid: _remoteEid,
                remoteVault: _remoteVault,
                amount: _amount,
                remoteTimestamp: 0,
                pricePerShare: 0
            })
        );

        uint128 _remoteGas = getRemoteVaultGas(_remoteEid, _remoteVault);

        // Fee for remote chain and Fraxtal hop if needed
        // Returns either A => Fraxtal or A => Fraxtal => B or Fraxtal => A
        uint256 fee = HOP_.quote(
            $.OFT,
            _remoteEid,
            bytes32(uint256(uint160(address(this)))),
            _amount,
            _remoteGas,
            hopComposeMessage
        );
        // Fee for return on local chain (A <= Fraxtal or Fraxtal <= A)
        fee += HOP_.quoteHop(EID_, LOCAL_GAS, hopComposeMessage);

        if (EID_ != FRAXTAL_EID && _remoteEid != FRAXTAL_EID) {
            // Include Fraxtal hop fee for the return message (Fraxtal <= B)
            uint128 fraxtalGas = 1_000_000;
            fee += HOP_.quoteHop(FRAXTAL_EID, fraxtalGas, hopComposeMessage);
        }
        return fee;
    }

    function hopCompose(
        uint32 _srcEid,
        bytes32 _srcAddress,
        address _oft,
        uint256 _amount,
        bytes memory _data
    ) external {
        RemoteVaultHopStorage storage $ = _getRemoteVaultHopStorage();

        if (msg.sender != address($.HOP)) revert NotHop();
        if (_oft != $.OFT) revert InvalidOFT();
        if (bytes32(uint256(uint160($.remoteVaultHops[_srcEid]))) != _srcAddress) revert InvalidChain();
        //(uint256 _actionUint, uint32 _userEid, address _userAddress, uint32 _vaultEid, address _vaultAddress, uint256 _amnt, uint256 _pricePerShare) = abi.decode(_data, (uint256, uint32, address, uint32, address, uint256, uint256));
        RemoteVaultMessage memory message = abi.decode(_data, (RemoteVaultMessage));
        if (message.action == Action.Deposit) {
            if (_amount != message.amount) revert InvalidAmount();
            _handleDeposit(message);
        } else if (message.action == Action.Redeem) {
            _handleRedeem(message);
        } else if (message.action == Action.RedeemReturn) {
            if (_amount != message.amount) revert InvalidAmount();
            _handleRedeemReturn(message);
        } else if (message.action == Action.DepositReturn) {
            _handleDepositReturn(message);
        } else {
            revert InvalidAction();
        }
    }

    function _handleDeposit(RemoteVaultMessage memory message) internal {
        RemoteVaultHopStorage storage $ = _getRemoteVaultHopStorage();

        SafeERC20.forceApprove($.TOKEN, message.remoteVault, message.amount);
        uint256 out = IERC4626(message.remoteVault).deposit(message.amount, address(this));
        $.balance[message.remoteEid][message.remoteVault] += out;

        uint256 _pricePerShare = IERC4626(message.remoteVault).convertToAssets(
            10 ** IERC20Metadata(message.remoteVault).decimals()
        );
        bytes memory _data = abi.encode(
            RemoteVaultMessage({
                action: Action.DepositReturn,
                userEid: message.userEid,
                userAddress: message.userAddress,
                remoteEid: $.EID,
                remoteVault: message.remoteVault,
                amount: out,
                remoteTimestamp: uint64(block.timestamp),
                pricePerShare: uint128(_pricePerShare)
            })
        );

        IHopV2 HOP_ = $.HOP; // gas
        address OFT_ = $.OFT; // gas
        bytes32 remoteVaultHop = bytes32(uint256(uint160($.remoteVaultHops[message.userEid])));

        uint256 fee = HOP_.quote(OFT_, message.userEid, remoteVaultHop, 0, LOCAL_GAS, _data);
        HOP_.sendOFT{ value: fee }(OFT_, message.userEid, remoteVaultHop, 0, LOCAL_GAS, _data);
    }

    function _handleRedeem(RemoteVaultMessage memory message) internal {
        RemoteVaultHopStorage storage $ = _getRemoteVaultHopStorage();
        SafeERC20.forceApprove(
            IERC20($.vaultShares[message.remoteVault]),
            address(message.remoteVault),
            message.amount
        );
        uint256 out = IERC4626(message.remoteVault).redeem(message.amount, address(this), address(this));
        $.balance[message.remoteEid][message.remoteVault] -= message.amount;
        out = removeDust(out);
        uint256 _pricePerShare = IERC4626(message.remoteVault).convertToAssets(
            10 ** IERC20Metadata(message.remoteVault).decimals()
        );
        bytes memory _data = abi.encode(
            RemoteVaultMessage({
                action: Action.RedeemReturn,
                userEid: message.userEid,
                userAddress: message.userAddress,
                remoteEid: $.EID,
                remoteVault: message.remoteVault,
                amount: out,
                remoteTimestamp: uint64(block.timestamp),
                pricePerShare: uint128(_pricePerShare)
            })
        );

        IHopV2 HOP_ = $.HOP; // gas
        address OFT_ = $.OFT; // gas
        bytes32 remoteVaultHop = bytes32(uint256(uint160($.remoteVaultHops[message.userEid])));

        uint256 fee = HOP_.quote(OFT_, message.userEid, remoteVaultHop, out, LOCAL_GAS, _data);
        SafeERC20.forceApprove($.TOKEN, address(HOP_), out);
        HOP_.sendOFT{ value: fee }(OFT_, message.userEid, remoteVaultHop, out, LOCAL_GAS, _data);
    }

    function _handleRedeemReturn(RemoteVaultMessage memory message) internal {
        RemoteVaultHopStorage storage $ = _getRemoteVaultHopStorage();
        SafeERC20.safeTransfer($.TOKEN, message.userAddress, message.amount);

        $.depositToken[message.remoteEid][message.remoteVault].setPricePerShare(
            message.remoteTimestamp,
            message.pricePerShare
        );
        emit RedeemReturn(message.userAddress, message.remoteEid, message.remoteVault, message.amount);
    }

    function _handleDepositReturn(RemoteVaultMessage memory message) internal {
        RemoteVaultHopStorage storage $ = _getRemoteVaultHopStorage();
        $.depositToken[message.remoteEid][message.remoteVault].mint(message.userAddress, message.amount);
        $.depositToken[message.remoteEid][message.remoteVault].setPricePerShare(
            message.remoteTimestamp,
            message.pricePerShare
        );
        emit DepositReturn(message.userAddress, message.remoteEid, message.remoteVault, message.amount);
    }

    function setRemoteVaultHop(uint32 _eid, address _remoteVault) external onlyRole(DEFAULT_ADMIN_ROLE) {
        RemoteVaultHopStorage storage $ = _getRemoteVaultHopStorage();
        $.remoteVaultHops[_eid] = _remoteVault;
        emit RemoteVaultHopSet(_eid, _remoteVault);
    }

    function addLocalVault(address _vault, address _share) external onlyRole(DEFAULT_ADMIN_ROLE) {
        RemoteVaultHopStorage storage $ = _getRemoteVaultHopStorage();
        $.vaultShares[_vault] = _share;
        emit VaultAdded(_vault, _share);
    }

    function addRemoteVault(
        uint32 _eid,
        address _vault,
        string memory name,
        string memory symbol,
        uint8 decimals
    ) external onlyRole(DEFAULT_ADMIN_ROLE) returns (address) {
        RemoteVaultHopStorage storage $ = _getRemoteVaultHopStorage();
        if (address($.depositToken[_eid][_vault]) != address(0)) revert VaultExists();
        FraxUpgradeableProxy proxy = new FraxUpgradeableProxy(
            address($.implementation),
            $.proxyAdmin,
            abi.encodeCall(
                RemoteVaultDeposit.initialize,
                (_eid, _vault, address($.TOKEN), $.DECIMAL_CONVERSION_RATE, name, symbol, decimals)
            )
        );
        $.depositToken[_eid][_vault] = RemoteVaultDeposit(payable(address(proxy)));
        emit RemoteVaultAdded(_eid, _vault, name, symbol);
        return address(proxy);
    }

    function getRemoteVaultGas(uint32 _eid, address _vault) public view returns (uint128) {
        RemoteVaultHopStorage storage $ = _getRemoteVaultHopStorage();
        uint128 _remoteGas = $.remoteGas[_eid][_vault];
        if (_remoteGas == 0) _remoteGas = DEFAULT_REMOTE_GAS;
        return _remoteGas;
    }

    function setRemoteVaultGas(uint32 _eid, address _vault, uint128 _gas) external onlyRole(DEFAULT_ADMIN_ROLE) {
        RemoteVaultHopStorage storage $ = _getRemoteVaultHopStorage();
        if (address($.depositToken[_eid][_vault]) == address(0)) revert InvalidVault();
        $.remoteGas[_eid][_vault] = _gas;
        emit RemoteGasSet(_eid, _vault, _gas);
    }

    function setProxyAdmin(address _proxyAdmin) external onlyRole(DEFAULT_ADMIN_ROLE) {
        RemoteVaultHopStorage storage $ = _getRemoteVaultHopStorage();
        $.proxyAdmin = _proxyAdmin;
    }

    function recover(address _target, uint256 _value, bytes memory _data) external onlyRole(DEFAULT_ADMIN_ROLE) {
        (bool success, ) = _target.call{ value: _value }(_data);
        require(success);
    }

    function removeDust(uint256 _amountLD) internal view returns (uint256) {
        RemoteVaultHopStorage storage $ = _getRemoteVaultHopStorage();
        return (_amountLD / $.DECIMAL_CONVERSION_RATE) * $.DECIMAL_CONVERSION_RATE;
    }

    function TOKEN() external view returns (IERC20) {
        RemoteVaultHopStorage storage $ = _getRemoteVaultHopStorage();
        return $.TOKEN;
    }

    function OFT() external view returns (address) {
        RemoteVaultHopStorage storage $ = _getRemoteVaultHopStorage();
        return $.OFT;
    }

    function HOP() external view returns (IHopV2) {
        RemoteVaultHopStorage storage $ = _getRemoteVaultHopStorage();
        return $.HOP;
    }

    function EID() external view returns (uint32) {
        RemoteVaultHopStorage storage $ = _getRemoteVaultHopStorage();
        return $.EID;
    }

    function DECIMAL_CONVERSION_RATE() external view returns (uint256) {
        RemoteVaultHopStorage storage $ = _getRemoteVaultHopStorage();
        return $.DECIMAL_CONVERSION_RATE;
    }

    function vaultShares(address _vault) external view returns (address) {
        RemoteVaultHopStorage storage $ = _getRemoteVaultHopStorage();
        return $.vaultShares[_vault];
    }

    function balance(uint32 _eid, address _vault) external view returns (uint256) {
        RemoteVaultHopStorage storage $ = _getRemoteVaultHopStorage();
        return $.balance[_eid][_vault];
    }

    function remoteVaultHops(uint32 _eid) external view returns (address) {
        RemoteVaultHopStorage storage $ = _getRemoteVaultHopStorage();
        return $.remoteVaultHops[_eid];
    }

    function depositToken(uint32 _eid, address _vault) external view returns (RemoteVaultDeposit) {
        RemoteVaultHopStorage storage $ = _getRemoteVaultHopStorage();
        return $.depositToken[_eid][_vault];
    }

    function remoteGas(uint32 _eid, address _vault) external view returns (uint128) {
        RemoteVaultHopStorage storage $ = _getRemoteVaultHopStorage();
        return $.remoteGas[_eid][_vault];
    }
}
