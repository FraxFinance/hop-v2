// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { EndpointV2Mock } from "@layerzerolabs/test-devtools-evm-foundry/contracts/mocks/EndpointV2Mock.sol";

/// @notice Minimal wrapped-native mock used by TempoGasTokenBase integration tests.
/// @dev Mirrors the relevant LZEndpointDollar surface used by the Tempo fee flow.
contract MockLZEndpointDollar {
    string public constant name = "LZ Endpoint Dollar";
    string public constant symbol = "LZUSD";
    uint8 public constant decimals = 6;

    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;
    mapping(address => bool) internal whitelistedTokens;
    address[] internal whitelistedTokensList;
    uint256 public totalSupply;

    address public immutable owner;

    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);
    event TokenWhitelisted(address indexed token, bool whitelisted);
    event TokenWrapped(address indexed token, address indexed from, address indexed to, uint256 amount);
    event TokenUnwrapped(address indexed token, address indexed from, address indexed to, uint256 amount);

    constructor() {
        owner = msg.sender;
    }

    function whitelistToken(address token) external {
        require(msg.sender == owner, "Only owner");
        require(!whitelistedTokens[token], "Already whitelisted");
        whitelistedTokens[token] = true;
        whitelistedTokensList.push(token);
        emit TokenWhitelisted(token, true);
    }

    function isWhitelistedToken(address token) external view returns (bool) {
        return whitelistedTokens[token];
    }

    function getWhitelistedTokens() external view returns (address[] memory) {
        return whitelistedTokensList;
    }

    function wrap(address token, address to, uint256 amount) external {
        require(whitelistedTokens[token], "Not whitelisted");
        IERC20(token).transferFrom(msg.sender, address(this), amount);
        balanceOf[to] += amount;
        totalSupply += amount;
        emit Transfer(address(0), to, amount);
        emit TokenWrapped(token, msg.sender, to, amount);
    }

    function unwrap(address token, address to, uint256 amount) external {
        require(whitelistedTokens[token], "Not whitelisted");
        require(balanceOf[msg.sender] >= amount, "Insufficient balance");
        balanceOf[msg.sender] -= amount;
        totalSupply -= amount;
        IERC20(token).transfer(to, amount);
        emit Transfer(msg.sender, address(0), amount);
        emit TokenUnwrapped(token, msg.sender, to, amount);
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        require(balanceOf[msg.sender] >= amount, "Insufficient balance");
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        emit Transfer(msg.sender, to, amount);
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        require(balanceOf[from] >= amount, "Insufficient balance");
        require(allowance[from][msg.sender] >= amount, "Insufficient allowance");
        allowance[from][msg.sender] -= amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        emit Transfer(from, to, amount);
        return true;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        emit Approval(msg.sender, spender, amount);
        return true;
    }
}

/// @notice EndpointV2 alt-token mock whose native token is a wrapped LZ dollar.
/// @dev Extends the devtools endpoint so packets still flow through TestHelperOz5.
contract EndpointV2AltLzDollarMock is EndpointV2Mock {
    error LZ_OnlyAltToken();

    MockLZEndpointDollar public immutable nativeErc20;

    constructor(uint32 _eid, address _owner, address _whitelistedToken) EndpointV2Mock(_eid, _owner) {
        nativeErc20 = new MockLZEndpointDollar();
        nativeErc20.whitelistToken(_whitelistedToken);
    }

    function _payNative(
        uint256 _required,
        uint256 _supplied,
        address _receiver,
        address _refundAddress
    ) internal override {
        if (msg.value > 0) revert LZ_OnlyAltToken();
        _payToken(address(nativeErc20), _required, _supplied, _receiver, _refundAddress);
    }

    function _suppliedNative() internal view override returns (uint256) {
        return IERC20(address(nativeErc20)).balanceOf(address(this));
    }

    function nativeToken() external view override returns (address) {
        return address(nativeErc20);
    }
}
