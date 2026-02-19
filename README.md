# Specification
## RemoteHop
**Purpose:** User wants to move [(s)frxUSD, (s)frxETH, FXS, FPI] from chain A to chain B via LZ.
1. User sends OFT to RemoteHop on Chain A
   - If `Chain B == Fraxtal`
        1. Chain A RemoteHop sends OFT to recipient on Fraxtal
   - If `Chain B != Fraxtal`
       1. Chain A RemoteHop sends OFT to Fraxtal Remotehop
        2. Fraxtal Remotehop sends OFT to recipient on chain B.

## How to use
### Interfaces
```Solidity
interface IERC20 {
    function approve(address spender, uint256 amount) external;
}
interface IOFT {
    function token() external view returns (address);
}

interface IRemoteHop {
        function quote(
        address _oft,
        uint32 _dstEid,
        bytes32 _recipient,
        uint256 _amountLD,
        uint128 _dstGas,
        bytes memory _data
    ) external view returns (uint256 fee);
    function sendOFT(
        address _oft,
        uint32 _dstEid,
        bytes32 _recipient,
        uint256 _amountLD,
        uint128 _dstGas,
        bytes memory _data
    ) external payable;
}
```

```Solidity
// Ethereum WFRAX => (Fraxtal) => Arbitrum WFRAX

// OFT address found @ https://docs.frax.com/protocol/crosschain/addresses
address remoteHop = 0xFd3B410b82a00B2651b42A13837204c5e3D92e27; // See deployed contracts below
address oft = 0x04ACaF8D2865c0714F79da09645C13FD2888977f; // WFRAX OFT
uint32 dstEid = 30110; // Arbitrum
bytes32 recipient = bytes32(uint256(uint160(0xb0E1650A9760e0f383174af042091fc544b8356f))); // example
uint256 amountLD = 1e18;
uint128 dstGas = 0;
bytes memory data = "";

// 1. Quote cost of send
uint256 fee = IRemoteHop(remoteHop).quote(oft, dstEid, recipient, amountLD, dstGas, data);

// 2. Approve OFT underlying token to be transferred to the remoteHop 
IERC20(IOFT(oft).token()).approve(remoteHop, amountLD);

// 3. Send the OFT to destination
IRemoteHop(remoteHop).sendOFT{value: fee}(oft, dstEid, recipient, amountLD, dstGas, data);
```

When sending `_data`, the `_recipient` on `_dstEid` must support the interface to receive the tokens via `lzCompose()`:
```Solidity
function hopCompose(
    uint32 _srcEid,
    bytes32 _sender,
    address _oft,
    uint256 _amount,
    bytes memory _data
)
```

## RemoteVaultHop

The RemoteVaultHop system enables users to deposit into and redeem from ERC-4626 vaults on remote chains using cross-chain token hops.

### Architecture

**1. RemoteVaultHop Contract**
- Core orchestrator implementing `IHopComposer` to handle vault operations across chains
- Manages both local vaults (on the same chain) and remote vaults (on other chains)
- Tracks user deposits via synthetic `RemoteVaultDeposit` ERC20 tokens

**2. RemoteVaultDeposit Contract** 
- ERC20 receipt token representing user deposits in remote vaults
- Tracks price-per-share with linear interpolation over 100 blocks for smooth price updates
- Provides convenience methods: `deposit()` and `redeem()` forward calls to RemoteVaultHop
- Users interact with this token to manage their remote vault positions

### Cross-Chain Vault Operations

**Deposit Flow (Chain A → Vault on Chain B):**
1. User calls `RemoteVaultDeposit.deposit(_amount)` on Chain A
2. Transfers tokens to RemoteVaultHop and calls `HOP.sendOFT()` with `Action.Deposit` message
3. RemoteVaultHop on Chain B receives via `hopCompose()`, calls `vault.deposit()` 
4. Chain B sends `Action.DepositReturn` message back with shares received + vault price-per-share
5. Chain A receives return message, mints RemoteVaultDeposit tokens to user, updates price

**Redeem Flow (Chain A ← Vault on Chain B):**
1. User calls `RemoteVaultDeposit.redeem(_amount)` on Chain A (burns deposit tokens)
2. Sends `Action.Redeem` message to Chain B
3. Chain B calls `vault.redeem()`, sends tokens back with `Action.RedeemReturn` message
4. Chain A receives underlying tokens, transfers to user

**Security:**
- Only RemoteVaultHop can mint/burn RemoteVaultDeposit tokens
- Validates incoming messages are from registered RemoteVaultHops

## Deployed Contracts
### HopV2 Mainnet
| Chain | `Hop` | `RemoteAdmin` |
| --- | --- | --- |
| Fraxtal | [`0x00000000e18aFc20Afe54d4B2C8688bB60c06B36`](https://fraxscan.com/address/0x00000000e18aFc20Afe54d4B2C8688bB60c06B36) | [`0x34029e02821178B4387e12644896994f910D6E73`](https://fraxscan.com/address/0x34029e02821178B4387e12644896994f910D6E73) |
| Arbitrum | [`0x0000006D38568b00B457580b734e0076C62de659`](https://arbiscan.io/address/0x0000006D38568b00B457580b734e0076C62de659) | [`0x954286118E93df807aB6f99aE0454f8710f0a8B9`](https://arbiscan.io/address/0x954286118E93df807aB6f99aE0454f8710f0a8B9) |
| Base | [`0x0000006D38568b00B457580b734e0076C62de659`](https://basescan.org/address/0x0000006D38568b00B457580b734e0076C62de659) | [`0x07dB789aD17573e5169eDEfe14df91CC305715AA`](https://basescan.org/address/0x07dB789aD17573e5169eDEfe14df91CC305715AA) |
| Ethereum | [`0x0000006D38568b00B457580b734e0076C62de659`](https://etherscan.io/address/0x0000006D38568b00B457580b734e0076C62de659) | [`0x181EBC9deA868ED8e5EeeAef7f767D43BF390dFa`](https://etherscan.io/address/0x181EBC9deA868ED8e5EeeAef7f767D43BF390dFa) |
