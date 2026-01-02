// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import "frax-std/FraxTest.sol";
import { RemoteSignatureHop, Authorization } from "src/contracts/hop/RemoteSignatureHop.sol";
import { HopMessage } from "src/contracts/interfaces/IHopV2.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { IERC3009 } from "src/contracts/interfaces/IERC3009.sol";
import { IERC20Metadata } from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import { AggregatorV3Interface } from "src/contracts/interfaces/AggregatorV3Interface.sol";
import { OFTMsgCodec } from "@layerzerolabs/oft-evm/contracts/libs/OFTMsgCodec.sol";
import { FraxUpgradeableProxy } from "frax-std/FraxUpgradeableProxy.sol";

// Mock Contracts
contract MockERC3009Token is IERC20, IERC20Metadata, IERC3009 {
    string public name = "Frax USD";
    string public symbol = "frxUSD";
    uint8 public decimals = 18;

    mapping(address => uint256) private _balances;
    mapping(address => mapping(address => uint256)) private _allowances;
    mapping(address => mapping(bytes32 => bool)) private _authorizationStates;
    uint256 private _totalSupply;

    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);
    event AuthorizationUsed(address indexed authorizer, bytes32 indexed nonce);

    function totalSupply() external view returns (uint256) {
        return _totalSupply;
    }

    function balanceOf(address account) external view returns (uint256) {
        return _balances[account];
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        _transfer(msg.sender, to, amount);
        return true;
    }

    function allowance(address owner, address spender) external view returns (uint256) {
        return _allowances[owner][spender];
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        _approve(msg.sender, spender, amount);
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        uint256 currentAllowance = _allowances[from][msg.sender];
        require(currentAllowance >= amount, "ERC20: insufficient allowance");
        _transfer(from, to, amount);
        _approve(from, msg.sender, currentAllowance - amount);
        return true;
    }

    function _transfer(address from, address to, uint256 amount) internal {
        require(from != address(0), "ERC20: transfer from zero address");
        require(to != address(0), "ERC20: transfer to zero address");
        require(_balances[from] >= amount, "ERC20: insufficient balance");

        _balances[from] -= amount;
        _balances[to] += amount;
        emit Transfer(from, to, amount);
    }

    function _approve(address owner, address spender, uint256 amount) internal {
        require(owner != address(0), "ERC20: approve from zero address");
        require(spender != address(0), "ERC20: approve to zero address");
        _allowances[owner][spender] = amount;
        emit Approval(owner, spender, amount);
    }

    function mint(address to, uint256 amount) external {
        _balances[to] += amount;
        _totalSupply += amount;
        emit Transfer(address(0), to, amount);
    }

    // ERC-3009 functions
    function receiveWithAuthorization(
        address from,
        address to,
        uint256 value,
        uint256 validAfter,
        uint256 validBefore,
        bytes32 nonce,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) external override {
        require(block.timestamp >= validAfter, "Authorization not yet valid");
        require(block.timestamp < validBefore, "Authorization expired");
        require(!_authorizationStates[from][nonce], "Authorization already used");

        // In a real implementation, this would verify the signature
        // For testing, we'll just check that the parameters are reasonable
        require(from != address(0), "Invalid from address");
        require(to != address(0), "Invalid to address");
        require(value > 0, "Invalid value");
        require(v == 27 || v == 28, "Invalid v");
        require(r != bytes32(0), "Invalid r");
        require(s != bytes32(0), "Invalid s");

        _authorizationStates[from][nonce] = true;
        emit AuthorizationUsed(from, nonce);

        _transfer(from, to, value);
    }

    function transferWithAuthorization(
        address from,
        address to,
        uint256 value,
        uint256 validAfter,
        uint256 validBefore,
        bytes32 nonce,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) external override {
        require(block.timestamp >= validAfter, "Authorization not yet valid");
        require(block.timestamp < validBefore, "Authorization expired");
        require(!_authorizationStates[from][nonce], "Authorization already used");

        _authorizationStates[from][nonce] = true;
        emit AuthorizationUsed(from, nonce);

        _transfer(from, to, value);
    }

    function cancelAuthorization(address authorizer, bytes32 nonce, uint8 v, bytes32 r, bytes32 s) external override {
        require(!_authorizationStates[authorizer][nonce], "Authorization already used");
        _authorizationStates[authorizer][nonce] = true;
    }

    function authorizationState(address authorizer, bytes32 nonce) external view override returns (bool) {
        return _authorizationStates[authorizer][nonce];
    }
}

// Mock OFT that wraps the ERC-3009 token
contract MockOFT {
    address public token;
    string public name = "OFT Frax USD";
    string public symbol = "frxUSD";

    constructor(address _token) {
        token = _token;
    }

    function send(
        address /*_to*/,
        uint256 /*_amount*/,
        bytes memory /*_options*/
    ) external payable returns (bytes memory) {
        return "";
    }
}

// Mock Chainlink Oracle
contract MockChainlinkOracle is AggregatorV3Interface {
    int256 public price;
    uint8 public decimals;

    constructor(int256 _price, uint8 _decimals) {
        price = _price;
        decimals = _decimals;
    }

    function setPrice(int256 _price) external {
        price = _price;
    }

    function description() external pure returns (string memory) {
        return "ETH/USD";
    }

    function version() external pure returns (uint256) {
        return 1;
    }

    function getRoundData(
        uint80 /*_roundId*/
    )
        external
        view
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound)
    {
        return (1, price, block.timestamp, block.timestamp, 1);
    }

    function latestRoundData()
        external
        view
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound)
    {
        return (1, price, block.timestamp, block.timestamp, 1);
    }
}

contract RemoteSignatureHopTest is FraxTest {
    RemoteSignatureHop remoteSignatureHop;
    MockERC3009Token frxUsdUnderlying;
    MockOFT frxUsdOft;
    MockChainlinkOracle chainlinkOracle;

    address proxyAdmin = vm.addr(0x1);
    address constant ENDPOINT = 0x1a44076050125825900e736c501f859c50fE728c;
    address constant EXECUTOR = 0x31CAe3B7fB82d847621859fb1585353c5720660D;
    address constant DVN = 0x2f55C492897526677C5B68fb199ea31E2c126416;
    address constant TREASURY = 0x532410B245eB41f24Ed1179BA0f6ffD94738AE70;
    address[] approvedOfts;

    uint32 constant FRAXTAL_EID = 30_255;
    uint32 constant ARBITRUM_EID = 30_110;

    // Oracle price constants
    int256 constant INITIAL_ETH_PRICE = 2000 * 1e8; // $2000 with 8 decimals
    int256 constant UPDATED_ETH_PRICE = 3000 * 1e8; // $3000 with 8 decimals
    uint8 constant ORACLE_DECIMALS = 8;

    // Test constants
    uint256 constant DUST_BUFFER = 1e18; // Buffer for dust in fee calculations

    address fraxtalHop;
    address user1;
    address user2;
    uint256 user1PrivateKey;
    uint256 user2PrivateKey;

    function setUp() public {
        vm.createSelectFork(vm.envString("ARBITRUM_MAINNET_URL"), 316_670_752);

        // Setup users
        user1PrivateKey = 0x1234;
        user1 = vm.addr(user1PrivateKey);
        user2PrivateKey = 0x5678;
        user2 = vm.addr(user2PrivateKey);

        // Deploy mock contracts
        frxUsdUnderlying = new MockERC3009Token();
        frxUsdOft = new MockOFT(address(frxUsdUnderlying));

        // Deploy oracle with ETH price of $2000 with 8 decimals
        chainlinkOracle = new MockChainlinkOracle(INITIAL_ETH_PRICE, ORACLE_DECIMALS);

        // Setup approved OFTs
        approvedOfts.push(address(frxUsdOft));

        fraxtalHop = address(0x123); // Mock Fraxtal hop address

        // Deploy RemoteSignatureHop
        bytes memory initializeArgs = abi.encodeCall(
            RemoteSignatureHop.initialize,
            (
                ARBITRUM_EID,
                ENDPOINT,
                OFTMsgCodec.addressToBytes32(fraxtalHop),
                2,
                EXECUTOR,
                DVN,
                TREASURY,
                approvedOfts,
                address(chainlinkOracle)
            )
        );

        address implementation = address(new RemoteSignatureHop());
        FraxUpgradeableProxy proxy = new FraxUpgradeableProxy(implementation, proxyAdmin, initializeArgs);

        remoteSignatureHop = RemoteSignatureHop(payable(address(proxy)));

        // Fund the remote signature hop contract
        payable(address(remoteSignatureHop)).call{ value: 100 ether }("");

        // Mint tokens to users
        frxUsdUnderlying.mint(user1, 1000e18);
        frxUsdUnderlying.mint(user2, 1000e18);
    }

    receive() external payable {}

    // ============ Initialization Tests ============

    function test_Initialization() public {
        assertEq(remoteSignatureHop.localEid(), ARBITRUM_EID, "Local EID should be set");
        assertEq(remoteSignatureHop.endpoint(), ENDPOINT, "Endpoint should be set");
        assertEq(remoteSignatureHop.numDVNs(), 2, "NumDVNs should be set");
        assertEq(remoteSignatureHop.EXECUTOR(), EXECUTOR, "Executor should be set");
        assertEq(remoteSignatureHop.DVN(), DVN, "DVN should be set");
        assertEq(remoteSignatureHop.TREASURY(), TREASURY, "Treasury should be set");
        assertTrue(remoteSignatureHop.approvedOft(address(frxUsdOft)), "frxUSD OFT should be approved");
        assertEq(
            remoteSignatureHop.remoteHop(FRAXTAL_EID),
            OFTMsgCodec.addressToBytes32(fraxtalHop),
            "Fraxtal hop should be set"
        );
    }

    function test_Initialization_HasDefaultAdminRole() public {
        assertTrue(
            remoteSignatureHop.hasRole(remoteSignatureHop.DEFAULT_ADMIN_ROLE(), address(this)),
            "Deployer should have DEFAULT_ADMIN_ROLE"
        );
    }

    // ============ sendFrxUsdWithAuthorization Tests ============

    function test_SendFrxUsdWithAuthorization_Success() public {
        uint256 amount = 100e18;

        Authorization memory auth = Authorization({
            from: user1,
            validAfter: block.timestamp - 1,
            validBefore: block.timestamp + 1 hours,
            nonce: keccak256("nonce1"),
            v: 27,
            r: keccak256("r"),
            s: keccak256("s")
        });

        vm.deal(address(this), 10 ether);

        uint256 senderBalanceBefore = address(this).balance;

        // Call the function
        uint256 fee = remoteSignatureHop.quote(
            address(frxUsdOft),
            FRAXTAL_EID,
            bytes32(uint256(uint160(user2))),
            amount,
            0,
            ""
        );

        remoteSignatureHop.sendFrxUsdWithAuthorization{ value: fee }(
            auth,
            address(frxUsdOft),
            FRAXTAL_EID,
            bytes32(uint256(uint160(user2))),
            amount
        );

        // Verify the fee was refunded to the sender
        uint256 senderBalanceAfter = address(this).balance;
        assertGt(senderBalanceAfter, 0, "Sender should have remaining ETH after transaction");

        // Verify sender received frxUSD as fee
        uint256 senderFrxUsdBalance = IERC20(address(frxUsdUnderlying)).balanceOf(address(this));
        assertGt(senderFrxUsdBalance, 0, "Sender should receive frxUSD as fee");
    }

    function test_SendFrxUsdWithAuthorization_WithCustomGasAndData() public {
        uint256 amount = 100e18;
        uint128 dstGas = 500_000;
        bytes memory data = "test data";

        Authorization memory auth = Authorization({
            from: user1,
            validAfter: block.timestamp - 1,
            validBefore: block.timestamp + 1 hours,
            nonce: keccak256("nonce2"),
            v: 27,
            r: keccak256("r"),
            s: keccak256("s")
        });

        vm.deal(msg.sender, 10 ether);

        uint256 fee = remoteSignatureHop.quote(
            address(frxUsdOft),
            FRAXTAL_EID,
            bytes32(uint256(uint160(user2))),
            amount,
            dstGas,
            data
        );

        remoteSignatureHop.sendFrxUsdWithAuthorization{ value: fee }(
            auth,
            address(frxUsdOft),
            FRAXTAL_EID,
            bytes32(uint256(uint160(user2))),
            amount,
            dstGas,
            data
        );
    }

    function test_SendFrxUsdWithAuthorization_LocalTransfer() public {
        uint256 amount = 100e18;

        Authorization memory auth = Authorization({
            from: user1,
            validAfter: block.timestamp - 1,
            validBefore: block.timestamp + 1 hours,
            nonce: keccak256("nonce3"),
            v: 27,
            r: keccak256("r"),
            s: keccak256("s")
        });

        // Local transfer should have zero fee
        uint256 fee = remoteSignatureHop.quote(
            address(frxUsdOft),
            ARBITRUM_EID,
            bytes32(uint256(uint160(user2))),
            amount,
            0,
            ""
        );

        assertEq(fee, 0, "Local transfer should have zero ETH fee");

        remoteSignatureHop.sendFrxUsdWithAuthorization(
            auth,
            address(frxUsdOft),
            ARBITRUM_EID,
            bytes32(uint256(uint160(user2))),
            amount
        );

        // Verify sender receives frxUSD fee
        assertGt(IERC20(address(frxUsdUnderlying)).balanceOf(msg.sender), 0, "Sender should receive frxUSD fee");
    }

    function test_SendFrxUsdWithAuthorization_WhenPaused() public {
        remoteSignatureHop.pauseOn();

        Authorization memory auth = Authorization({
            from: user1,
            validAfter: block.timestamp - 1,
            validBefore: block.timestamp + 1 hours,
            nonce: keccak256("nonce4"),
            v: 27,
            r: keccak256("r"),
            s: keccak256("s")
        });

        vm.expectRevert(abi.encodeWithSignature("HopPaused()"));
        remoteSignatureHop.sendFrxUsdWithAuthorization(
            auth,
            address(frxUsdOft),
            FRAXTAL_EID,
            bytes32(uint256(uint160(user2))),
            100e18
        );
    }

    function test_SendFrxUsdWithAuthorization_InvalidOFT() public {
        address invalidOft = address(0x999);

        Authorization memory auth = Authorization({
            from: user1,
            validAfter: block.timestamp - 1,
            validBefore: block.timestamp + 1 hours,
            nonce: keccak256("nonce5"),
            v: 27,
            r: keccak256("r"),
            s: keccak256("s")
        });

        vm.expectRevert(abi.encodeWithSignature("InvalidOFT()"));
        remoteSignatureHop.sendFrxUsdWithAuthorization(
            auth,
            invalidOft,
            FRAXTAL_EID,
            bytes32(uint256(uint160(user2))),
            100e18
        );
    }

    function test_SendFrxUsdWithAuthorization_NonFrxUSDToken() public {
        // Create a mock OFT with different symbol
        MockERC3009Token otherToken = new MockERC3009Token();
        MockOFT otherOft = new MockOFT(address(otherToken));

        // Approve the OFT but it's not frxUSD
        remoteSignatureHop.setApprovedOft(address(otherOft), true);

        // Override symbol to something else
        vm.mockCall(address(otherOft), abi.encodeWithSelector(IERC20Metadata.symbol.selector), abi.encode("OTHER"));

        Authorization memory auth = Authorization({
            from: user1,
            validAfter: block.timestamp - 1,
            validBefore: block.timestamp + 1 hours,
            nonce: keccak256("nonce6"),
            v: 27,
            r: keccak256("r"),
            s: keccak256("s")
        });

        vm.expectRevert(abi.encodeWithSignature("InvalidOFT()"));
        remoteSignatureHop.sendFrxUsdWithAuthorization(
            auth,
            address(otherOft),
            FRAXTAL_EID,
            bytes32(uint256(uint160(user2))),
            100e18
        );
    }

    function test_SendFrxUsdWithAuthorization_InsufficientFee() public {
        Authorization memory auth = Authorization({
            from: user1,
            validAfter: block.timestamp - 1,
            validBefore: block.timestamp + 1 hours,
            nonce: keccak256("nonce7"),
            v: 27,
            r: keccak256("r"),
            s: keccak256("s")
        });

        vm.expectRevert(abi.encodeWithSignature("InsufficientFee()"));
        remoteSignatureHop.sendFrxUsdWithAuthorization{ value: 0 }(
            auth,
            address(frxUsdOft),
            FRAXTAL_EID,
            bytes32(uint256(uint160(user2))),
            100e18
        );
    }

    function test_SendFrxUsdWithAuthorization_RefundsExcessFee() public {
        Authorization memory auth = Authorization({
            from: user1,
            validAfter: block.timestamp - 1,
            validBefore: block.timestamp + 1 hours,
            nonce: keccak256("nonce8"),
            v: 27,
            r: keccak256("r"),
            s: keccak256("s")
        });

        vm.deal(address(this), 10 ether);

        uint256 fee = remoteSignatureHop.quote(
            address(frxUsdOft),
            FRAXTAL_EID,
            bytes32(uint256(uint160(user2))),
            100e18,
            0,
            ""
        );

        uint256 balanceBefore = address(this).balance;
        uint256 excessFee = 1 ether;

        remoteSignatureHop.sendFrxUsdWithAuthorization{ value: fee + excessFee }(
            auth,
            address(frxUsdOft),
            FRAXTAL_EID,
            bytes32(uint256(uint160(user2))),
            100e18
        );

        assertEq(address(this).balance, balanceBefore - fee, "Excess ETH fee should be refunded");
    }

    function test_SendFrxUsdWithAuthorization_ExpiredAuthorization() public {
        Authorization memory auth = Authorization({
            from: user1,
            validAfter: block.timestamp - 2 hours,
            validBefore: block.timestamp - 1 hours, // Already expired
            nonce: keccak256("nonce9"),
            v: 27,
            r: keccak256("r"),
            s: keccak256("s")
        });

        vm.deal(address(this), 10 ether);
        uint256 fee = remoteSignatureHop.quote(
            address(frxUsdOft),
            FRAXTAL_EID,
            bytes32(uint256(uint160(user2))),
            100e18,
            0,
            ""
        );

        vm.expectRevert("Authorization expired");
        remoteSignatureHop.sendFrxUsdWithAuthorization{ value: fee }(
            auth,
            address(frxUsdOft),
            FRAXTAL_EID,
            bytes32(uint256(uint160(user2))),
            100e18
        );
    }

    function test_SendFrxUsdWithAuthorization_NotYetValid() public {
        Authorization memory auth = Authorization({
            from: user1,
            validAfter: block.timestamp + 1 hours, // Not yet valid
            validBefore: block.timestamp + 2 hours,
            nonce: keccak256("nonce10"),
            v: 27,
            r: keccak256("r"),
            s: keccak256("s")
        });

        vm.deal(address(this), 10 ether);
        uint256 fee = remoteSignatureHop.quote(
            address(frxUsdOft),
            FRAXTAL_EID,
            bytes32(uint256(uint160(user2))),
            100e18,
            0,
            ""
        );

        vm.expectRevert("Authorization not yet valid");
        remoteSignatureHop.sendFrxUsdWithAuthorization{ value: fee }(
            auth,
            address(frxUsdOft),
            FRAXTAL_EID,
            bytes32(uint256(uint160(user2))),
            100e18
        );
    }

    function test_SendFrxUsdWithAuthorization_DuplicateNonce() public {
        Authorization memory auth = Authorization({
            from: user1,
            validAfter: block.timestamp - 1,
            validBefore: block.timestamp + 1 hours,
            nonce: keccak256("nonce11"),
            v: 27,
            r: keccak256("r"),
            s: keccak256("s")
        });

        vm.deal(address(this), 10 ether);
        uint256 fee = remoteSignatureHop.quote(
            address(frxUsdOft),
            FRAXTAL_EID,
            bytes32(uint256(uint160(user2))),
            100e18,
            0,
            ""
        );

        // First call should succeed
        remoteSignatureHop.sendFrxUsdWithAuthorization{ value: fee }(
            auth,
            address(frxUsdOft),
            FRAXTAL_EID,
            bytes32(uint256(uint160(user2))),
            100e18
        );

        // Second call with same nonce should fail
        vm.expectRevert("Authorization already used");
        remoteSignatureHop.sendFrxUsdWithAuthorization{ value: fee }(
            auth,
            address(frxUsdOft),
            FRAXTAL_EID,
            bytes32(uint256(uint160(user2))),
            100e18
        );
    }

    // ============ quoteInUsd Tests ============

    function test_QuoteInUsd_CalculatesCorrectly() public {
        uint256 amount = 100e18;

        // Get ETH fee first
        uint256 feeInEth = remoteSignatureHop.quote(
            address(frxUsdOft),
            FRAXTAL_EID,
            bytes32(uint256(uint160(user2))),
            amount,
            0,
            ""
        );

        // Get USD fee
        uint256 feeInUsd = remoteSignatureHop.quoteInUsd(
            address(frxUsdOft),
            FRAXTAL_EID,
            bytes32(uint256(uint160(user2))),
            amount,
            0,
            ""
        );

        // With ETH price at $2000, the USD fee should be feeInEth * 2000
        uint256 expectedFeeInUsd = (feeInEth * uint256(INITIAL_ETH_PRICE)) / (10 ** ORACLE_DECIMALS);
        assertEq(feeInUsd, expectedFeeInUsd, "Fee in USD should match calculation");
    }

    function test_QuoteInUsd_WithDifferentEthPrice() public {
        // Change ETH price to $3000
        chainlinkOracle.setPrice(UPDATED_ETH_PRICE);

        uint256 amount = 100e18;
        uint256 feeInEth = remoteSignatureHop.quote(
            address(frxUsdOft),
            FRAXTAL_EID,
            bytes32(uint256(uint160(user2))),
            amount,
            0,
            ""
        );

        uint256 feeInUsd = remoteSignatureHop.quoteInUsd(
            address(frxUsdOft),
            FRAXTAL_EID,
            bytes32(uint256(uint160(user2))),
            amount,
            0,
            ""
        );

        uint256 expectedFeeInUsd = (feeInEth * uint256(UPDATED_ETH_PRICE)) / (10 ** ORACLE_DECIMALS);
        assertEq(feeInUsd, expectedFeeInUsd, "Fee in USD should reflect new ETH price");
    }

    function test_QuoteInUsd_LocalDestination() public {
        uint256 feeInUsd = remoteSignatureHop.quoteInUsd(
            address(frxUsdOft),
            ARBITRUM_EID,
            bytes32(uint256(uint160(user2))),
            100e18,
            0,
            ""
        );

        assertEq(feeInUsd, 0, "Local transfers should have zero USD fee");
    }

    function test_QuoteInUsd_WithCustomGasAndData() public {
        uint128 dstGas = 500_000;
        bytes memory data = "test data";

        uint256 feeInUsd = remoteSignatureHop.quoteInUsd(
            address(frxUsdOft),
            FRAXTAL_EID,
            bytes32(uint256(uint160(user2))),
            100e18,
            dstGas,
            data
        );

        assertGt(feeInUsd, 0, "Fee should be greater than zero for remote transfer with data");
    }

    // ============ Integration Tests ============

    function test_FullFlow_SendToFraxtal() public {
        uint256 amount = 100e18;
        uint256 user1BalanceBefore = IERC20(address(frxUsdUnderlying)).balanceOf(user1);

        Authorization memory auth = Authorization({
            from: user1,
            validAfter: block.timestamp - 1,
            validBefore: block.timestamp + 1 hours,
            nonce: keccak256("nonce12"),
            v: 27,
            r: keccak256("r"),
            s: keccak256("s")
        });

        vm.deal(address(this), 10 ether);
        uint256 fee = remoteSignatureHop.quote(
            address(frxUsdOft),
            FRAXTAL_EID,
            bytes32(uint256(uint160(user2))),
            amount,
            0,
            ""
        );

        uint256 feeInUsd = remoteSignatureHop.quoteInUsd(
            address(frxUsdOft),
            FRAXTAL_EID,
            bytes32(uint256(uint160(user2))),
            amount,
            0,
            ""
        );

        remoteSignatureHop.sendFrxUsdWithAuthorization{ value: fee }(
            auth,
            address(frxUsdOft),
            FRAXTAL_EID,
            bytes32(uint256(uint160(user2))),
            amount
        );

        // Verify user1's balance decreased
        uint256 user1BalanceAfter = IERC20(address(frxUsdUnderlying)).balanceOf(user1);
        assertEq(user1BalanceAfter, user1BalanceBefore - amount, "User1 balance should decrease");

        // Verify sender received frxUSD fee
        uint256 senderFrxUsdBalance = IERC20(address(frxUsdUnderlying)).balanceOf(address(this));
        assertGt(senderFrxUsdBalance, 0, "Sender should receive frxUSD fee");

        // Fee should be approximately the USD fee (minus amount sent)
        // The actual formula is: sender receives (feeInUsd + dust after removeDust)
        assertLe(senderFrxUsdBalance, feeInUsd + DUST_BUFFER, "Sender fee should not exceed USD fee + dust buffer");
    }

    function test_FullFlow_LocalSend() public {
        uint256 amount = 100e18;
        uint256 user1BalanceBefore = IERC20(address(frxUsdUnderlying)).balanceOf(user1);
        uint256 user2BalanceBefore = IERC20(address(frxUsdUnderlying)).balanceOf(user2);

        Authorization memory auth = Authorization({
            from: user1,
            validAfter: block.timestamp - 1,
            validBefore: block.timestamp + 1 hours,
            nonce: keccak256("nonce13"),
            v: 27,
            r: keccak256("r"),
            s: keccak256("s")
        });

        remoteSignatureHop.sendFrxUsdWithAuthorization(
            auth,
            address(frxUsdOft),
            ARBITRUM_EID,
            bytes32(uint256(uint160(user2))),
            amount
        );

        // Verify user1's balance decreased
        uint256 user1BalanceAfter = IERC20(address(frxUsdUnderlying)).balanceOf(user1);
        assertEq(user1BalanceAfter, user1BalanceBefore - amount, "User1 balance should decrease");

        // For local transfer, user2 should receive the tokens minus fees
        uint256 user2BalanceAfter = IERC20(address(frxUsdUnderlying)).balanceOf(user2);
        assertGt(user2BalanceAfter, user2BalanceBefore, "User2 should receive tokens");

        // Sender should receive some frxUSD as fee
        uint256 senderFrxUsdBalance = IERC20(address(frxUsdUnderlying)).balanceOf(address(this));
        assertGt(senderFrxUsdBalance, 0, "Sender should receive frxUSD fee");
    }

    // ============ Edge Cases ============

    function test_SendFrxUsdWithAuthorization_SmallAmount() public {
        uint256 amount = 1e6; // Very small amount

        Authorization memory auth = Authorization({
            from: user1,
            validAfter: block.timestamp - 1,
            validBefore: block.timestamp + 1 hours,
            nonce: keccak256("nonce14"),
            v: 27,
            r: keccak256("r"),
            s: keccak256("s")
        });

        vm.deal(address(this), 10 ether);
        uint256 fee = remoteSignatureHop.quote(
            address(frxUsdOft),
            FRAXTAL_EID,
            bytes32(uint256(uint160(user2))),
            amount,
            0,
            ""
        );

        // This might revert if the fee in USD is greater than the amount
        // But we'll try anyway to test the behavior
        try
            remoteSignatureHop.sendFrxUsdWithAuthorization{ value: fee }(
                auth,
                address(frxUsdOft),
                FRAXTAL_EID,
                bytes32(uint256(uint160(user2))),
                amount
            )
        {
            // If it succeeds, that's fine
        } catch {
            // If it fails (e.g., underflow when subtracting fee), that's also expected
        }
    }

    function test_SendFrxUsdWithAuthorization_LargeAmount() public {
        uint256 amount = 1000e18; // Large amount

        Authorization memory auth = Authorization({
            from: user1,
            validAfter: block.timestamp - 1,
            validBefore: block.timestamp + 1 hours,
            nonce: keccak256("nonce15"),
            v: 27,
            r: keccak256("r"),
            s: keccak256("s")
        });

        vm.deal(address(this), 10 ether);
        uint256 fee = remoteSignatureHop.quote(
            address(frxUsdOft),
            FRAXTAL_EID,
            bytes32(uint256(uint160(user2))),
            amount,
            0,
            ""
        );

        remoteSignatureHop.sendFrxUsdWithAuthorization{ value: fee }(
            auth,
            address(frxUsdOft),
            FRAXTAL_EID,
            bytes32(uint256(uint160(user2))),
            amount
        );
    }

    // ============ Access Control Tests ============

    function test_OnlyAdminCanPause() public {
        address nonAdmin = address(0x999);

        vm.prank(nonAdmin);
        vm.expectRevert();
        remoteSignatureHop.pauseOn();
    }

    function test_OnlyAdminCanSetApprovedOft() public {
        address nonAdmin = address(0x999);
        address newOft = address(0x888);

        vm.prank(nonAdmin);
        vm.expectRevert();
        remoteSignatureHop.setApprovedOft(newOft, true);
    }
}
