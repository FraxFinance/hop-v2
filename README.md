# Hop V2 Protocol — Technical Documentation

> **Author:** Frax Finance
> **Protocol:** LayerZero V2-based cross-chain token bridge with hub-and-spoke architecture
> **Hub:** `FraxtalHopV2` on Fraxtal
> **Spokes:** `RemoteHopV2` on non-Fraxtal chains

---

## Table of Contents

1. [Protocol Overview](#1-protocol-overview)
2. [Architecture Diagrams](#2-architecture-diagrams)
   - 2.1 [Hub & Spoke Topology](#21-hub--spoke-topology)
   - 2.2 [Remote → Fraxtal (Direct)](#22-remote--fraxtal-direct-transfer)
   - 2.3 [Remote A → Remote B (Via Hub)](#23-remote-a--remote-b-relay-via-hub)
   - 2.4 [Fraxtal → Remote (Hub Initiated)](#24-fraxtal--remote-hub-initiated)
   - 2.5 [Cross-Chain Vault Deposit Flow](#25-cross-chain-vault-deposit-flow)
   - 2.6 [Cross-Chain Vault Redeem Flow](#26-cross-chain-vault-redeem-flow)
   - 2.7 [Remote Admin Execution Flow](#27-remote-admin-execution-flow)
3. [Contract Reference](#3-contract-reference)
   - 3.1 [HopV2 (Abstract Base)](#31-hopv2-abstract-base)
   - 3.2 [FraxtalHopV2 (Hub)](#32-fraxtalhopv2-hub)
   - 3.3 [RemoteHopV2 (Spoke)](#33-remotehopv2-spoke)
   - 3.4 [RemoteAdmin](#34-remoteadmin)
   - 3.5 [RemoteVaultHop](#35-remotevaulthop)
   - 3.6 [RemoteVaultDeposit](#36-remotevaultdeposit)
4. [Message Encoding & Codec](#4-message-encoding--codec)
5. [Fee Structure](#5-fee-structure)
6. [Security Model](#6-security-model)
7. [Technical Examples](#7-technical-examples)
   - 7.1 [Simple Token Bridge: Remote → Fraxtal](#71-simple-token-bridge-remote--fraxtal)
   - 7.2 [Token Bridge: Remote A → Remote B](#72-token-bridge-remote-a--remote-b)
   - 7.3 [Fraxtal → Remote](#73-fraxtal--remote)
   - 7.4 [Composed Message (Custom Execution)](#74-composed-message-with-custom-execution)
   - 7.5 [Cross-Chain Vault Deposit](#75-cross-chain-vault-deposit)
   - 7.6 [Cross-Chain Vault Redeem](#76-cross-chain-vault-redeem)
   - 7.7 [Remote Admin Call](#77-remote-admin-call)
   - 7.8 [Implementing IHopComposer](#78-implementing-ihopcomposer)
8. [Deployed Addresses](#8-deployed-addresses)
9. [Integration Checklist](#9-integration-checklist)

---

## 1. Protocol Overview

Hop V2 is a cross-chain token bridging protocol built on [LayerZero V2](https://docs.layerzero.network/v2). All cross-chain routes pass through a single hub on Fraxtal, making the protocol a canonical **hub-and-spoke** system.

```
          ┌─────────────────────────────────────┐
          │          CORE PROTOCOL LOOP         │
          │                                     │
          │  1. User calls sendOFT() on spoke   │
          │  2. OFT travels to Fraxtal hub      │
          │  3. Hub routes to final destination │
          │  4. Recipient receives on dst chain │
          └─────────────────────────────────────┘
```

---

## 2. Architecture Diagrams

### 2.1 Hub & Spoke Topology

```
                        ╔══════════════════════════════════════╗
                        ║          FRAXTAL (EID 30_255)        ║
                        ║                                      ║
                        ║  ┌────────────────────────────────┐  ║
                        ║  │        FraxtalHopV2            │  ║
                        ║  │  ───────────────────────────── │  ║
                        ║  │  • Routes all cross-chain hops │  ║
                        ║  │  • Implements lzCompose (hub)  │  ║
                        ║  │  • Manages remoteHop registry  │  ║
                        ║  │  • Handles trusted/untrusted   │  ║
                        ║  │    message verification        │  ║
                        ║  └────────────────────────────────┘  ║
                        ║               │  ▲                   ║
                        ╚═══════════════╪══╪═══════════════════╝
                                        │  │
              ┌─────────────────────────┼──┼──────────────────────────┐
              │                         │  │                          │
     LZ OFT ──┼──────────────────┐      │  │      ┌───────────────────┼── LZ OFT
    (frxUSD)  │                  ▼      │  │      ▼                   │  (frxUSD)
              │        ╔═════════════════╗  ╔══════════════════╗      │
              │        ║  ARBITRUM       ║  ║  ETHEREUM        ║      │
              │        ║  EID 30_110     ║  ║  EID 30_101      ║      │
              │        ║                 ║  ║                  ║      │
              │        ║ RemoteHopV2     ║  ║  RemoteHopV2     ║      │
              │        ║ + RemoteAdmin   ║  ║  + RemoteAdmin   ║      │
              │        ╚═════════════════╝  ╚══════════════════╝      │
              │                                                       │
              │        ╔═════════════════╗                            │
              │        ║  BASE           ║                            │
              │        ║  EID 30_102     ║                            │
              │        ║                 ║                            │
              │        ║ RemoteHopV2     ║                            │
              │        ║ + RemoteAdmin   ║◄───────────────────────────┘
              │        ║ + VaultHop      ║
              │        ╚═════════════════╝
              │
              └─────── All RemoteHopV2 spokes ALWAYS send to
                        FraxtalHopV2 first — never peer-to-peer
```

**Registry mapping on `FraxtalHopV2`:**

```
remoteHop[30_110] → RemoteHopV2 on Arbitrum
remoteHop[30_102] → RemoteHopV2 on Base
remoteHop[30_101] → RemoteHopV2 on Ethereum

remoteHop[30_255] (Fraxtal EID) on each RemoteHopV2 → FraxtalHopV2
```

---

### 2.2 Remote → Fraxtal (Direct Transfer)

User on Base wants to send frxUSD to an address on Fraxtal.

```
  BASE (EID 30_102)                           FRAXTAL (EID 30_255)
  ─────────────────                           ──────────────────────

  User                                        recipient
   │                                              ▲
   │ 1. approve(RemoteHopV2, amount)              │
   │ 2. sendOFT(                                  │
   │      oft=frxUSD,                             │
   │      dstEid=30_255,          ┌───────────────┘
   │      recipient=0x...,        │
   │      amount=1000e18          │
   │    ) {value: fee}            │
   │                              │
   ▼                              │
  RemoteHopV2 (Base)              │
   │                              │
   │ _generateSendParam():        │
   │  dstEid=FRAXTAL(30_255)      │
   │  to=recipient (no compose)   │
   │                              │
   │ IOFT(frxUSD).send()──────────┤
   │                       LZ V2  │
   │                   ───────────┘
   │
   │                   FraxtalHopV2 receives OFT directly
   │                   (no lzCompose triggered, dstEid=Fraxtal,
   │                    no composeMsg → funds land at recipient)
   ▼
  [tx complete]

  Fee: LZ OFT fee only (no Fraxtal hop fee)
```

---

### 2.3 Remote A → Remote B (Relay via Hub)

User on Arbitrum sends frxUSD to an address on Base. All traffic relays through Fraxtal.

```
  ARBITRUM (30_110)         FRAXTAL (30_255)          BASE (30_102)
  ─────────────────         ─────────────────         ─────────────

  User
   │
   │ 1. approve(RemoteHopV2_ARB, amt)
   │ 2. sendOFT(
   │      oft=frxUSD_ARB,
   │      dstEid=30_102,              ←── Base EID
   │      recipient=0xBASE_USER,
   │      amount=1000e18
   │    ) {value: lzFee + hopFee}
   │
   ▼
  RemoteHopV2 (Arb)
   │ _generateSendParam():
   │  dstEid = FRAXTAL (always)
   │  to     = FraxtalHopV2
   │  gas    = max(400_000, 1_000_000)
   │  composeMsg = abi.encode(HopMessage{
   │    srcEid: 30_110,
   │    dstEid: 30_102,       ← original destination
   │    dstGas: 0,
   │    sender: 0xARB_USER,
   │    recipient: 0xBASE_USER,
   │    data: ""
   │  })
   │
   │ IOFT(frxUSD_ARB).send{lzFee}()
   │
   ├───────────────────────────────────────────────────────────────────►
   │                    [LayerZero V2: Arbitrum → Fraxtal]
   │
   │                         FraxtalHopV2.lzCompose()
   │                          │
   │                          │ 1. _validateComposeMessage()
   │                          │    isTrusted: remoteHop[30_110] == sender ✓
   │                          │
   │                          │ 2. decode HopMessage
   │                          │    hopMessage.dstEid = 30_102 (Base)
   │                          │
   │                          │ 3. dstEid != FRAXTAL_EID
   │                          │    → _sendToDestination()
   │                          │
   │                          │ 4. _generateSendParam():
   │                          │    dstEid = 30_102
   │                          │    to     = RemoteHopV2_BASE
   │                          │    composeMsg = abi.encode(HopMessage{
   │                          │      dstEid: 30_102,
   │                          │      recipient: 0xBASE_USER,
   │                          │      data: ""     ← no compose
   │                          │    })
   │                          │
   │                          │ IOFT(frxUSD_FRAX).send{hopFee}()
   │                          │
   │                          ├──────────────────────────────────────►
   │                          │     [LayerZero V2: Fraxtal → Base]
   │                          │
   │                          │            RemoteHopV2 (Base).lzCompose()
   │                          │             │
   │                          │             │ _validateComposeMessage()
   │                          │             │   isTrusted: remoteHop[30_255]==sender ✓
   │                          │             │
   │                          │             │ _sendLocal()
   │                          │             │   transfer(0xBASE_USER, amount) ✓
   │                          │             ▼
   │                          │            BASE_USER receives frxUSD
   │                          ▼
   │                    emit Hop(oft, 30_110, 30_102, recipient, amount)
   ▼

  Total Fee = LZ(ARB→FRAX) + quoteHop(30_102) + Hop service fee
```

---

### 2.4 Fraxtal → Remote (Hub Initiated)

User on Fraxtal sends to a remote chain directly from `FraxtalHopV2`.

```
  FRAXTAL (30_255)                              BASE (30_102)
  ────────────────                              ─────────────

  User (on Fraxtal)
   │
   │ 1. approve(FraxtalHopV2, amount)
   │ 2. FraxtalHopV2.sendOFT(
   │      oft=frxUSD,
   │      dstEid=30_102,
   │      recipient=0xBASE_USER,
   │      amount=1000e18
   │    ) {value: fee}
   │
   ▼
  FraxtalHopV2
   │ sendOFT() override:
   │   validate: remoteHop[30_102] != 0 ✓
   │
   │ super.sendOFT():
   │   dstEid != localEid(30_255)
   │   → _sendToDestination()
   │
   │ _generateSendParam():
   │   dstEid = 30_102
   │   to     = 0xBASE_USER  (no compose data)
   │   (direct delivery, no composeMsg)
   │
   │ IOFT(frxUSD).send{fee}()
   │
   ├──────────────────────────────────────────────────────────────────►
   │              [LayerZero V2: Fraxtal → Base]
   │
   │                             OFT delivery — BASE_USER receives frxUSD
   │                             (no lzCompose triggered for direct transfers)
   ▼

  Fee = LZ OFT fee only (localEid == FRAXTAL_EID → hopFeeOnFraxtal = 0)
```

---

### 2.5 Cross-Chain Vault Deposit Flow

User on Arbitrum deposits frxUSD into an ERC-4626 vault that lives on Fraxtal.

```
  ARBITRUM (30_110)              FRAXTAL (30_255)
  ─────────────────              ─────────────────

  User
   │
   │ 1. approve(frxUSD, rvDeposit_ARB_FRAXVAULT, amount)
   │ 2. RemoteVaultDeposit.deposit{value: fee}(amount)
   │
   ▼
  RemoteVaultDeposit (Arb)        ← ERC20 receipt token
   │ safeTransferFrom(user → RemoteVaultHop_ARB, amount)
   │ RemoteVaultHop.deposit{value}(amount, FRAXTAL_EID, vault, user)
   │
   ▼
  RemoteVaultHop (Arb)
   │ encode RemoteVaultMessage {
   │   action:      Deposit
   │   userEid:     30_110
   │   userAddress: USER
   │   remoteEid:   30_255
   │   remoteVault: VAULT_ADDR
   │   amount:      1000e18
   │ }
   │
   │ HOP.sendOFT{fee}(
   │   frxUSD_ARB, 30_255,
   │   RemoteVaultHop_FRAX,
   │   amount, 400_000,
   │   hopComposeMessage
   │ )
   │
   ├─────────────────────────────────────────────────────────────────►
   │                  [LayerZero: Arb → Fraxtal]
   │
   │                    FraxtalHopV2.lzCompose()
   │                     │ dstEid == FRAXTAL_EID
   │                     │ → _sendLocal(RemoteVaultHop_FRAX, amount, msg)
   │                     │
   │                     ▼
   │                    RemoteVaultHop (Fraxtal).hopCompose()
   │                     │ action == Deposit
   │                     │ → _handleDeposit()
   │                     │
   │                     │ vault.deposit(amount) → shares
   │                     │ pricePerShare = vault.convertToAssets(1e18)
   │                     │
   │                     │ encode DepositReturn {
   │                     │   action:         DepositReturn
   │                     │   userEid:        30_110
   │                     │   userAddress:    USER
   │                     │   remoteEid:      30_255
   │                     │   remoteVault:    VAULT_ADDR
   │                     │   amount:         shares
   │                     │   pricePerShare:  X
   │                     │   remoteTimestamp: block.timestamp
   │                     │ }
   │                     │
   │                     │ HOP.sendOFT{fee}(frxUSD, 30_110,
   │                     │   RemoteVaultHop_ARB, 0, 400_000, data)
   │                     │
   │                     ├────────────────────────────────────────────►
   │                     │          [LayerZero: Fraxtal → Arb]
   │                     │
   │                     │              RemoteHopV2 (Arb).lzCompose()
   │                     │               │ → _sendLocal(RemoteVaultHop_ARB,0,msg)
   │                     │               ▼
   │                     │              RemoteVaultHop (Arb).hopCompose()
   │                     │               │ action == DepositReturn
   │                     │               │ → _handleDepositReturn()
   │                     │               │
   │                     │               │ rvDeposit.mint(USER, shares)
   │                     │               │ rvDeposit.setPricePerShare(ts, pps)
   │                     │               ▼
   │                     │              USER receives RemoteVaultDeposit tokens
   │                     ▼
   │                    Vault shares tracked: balance[30_110][VAULT] += shares
   ▼

  USER now holds RemoteVaultDeposit ERC20 on Arbitrum
  representing their proportional share of VAULT on Fraxtal
```

---

### 2.6 Cross-Chain Vault Redeem Flow

```
  ARBITRUM (30_110)              FRAXTAL (30_255)
  ─────────────────              ─────────────────

  User
   │ RemoteVaultDeposit.redeem{value: fee}(shares)
   │
   ▼
  RemoteVaultDeposit (Arb)
   │ _burn(user, shares)
   │ RemoteVaultHop.redeem{value}(shares, FRAXTAL_EID, vault, user)
   │
   ▼
  RemoteVaultHop (Arb)
   │ encode RemoteVaultMessage { action: Redeem, amount: shares, ... }
   │ HOP.sendOFT{fee}(frxUSD, 30_255, RemoteVaultHop_FRAX, 0, 400K, msg)
   │                            ↑
   │                      amount=0 for redeem (no tokens moving out)
   │
   ├──────────────────────────────────────────────────────────────────►
   │                  [LayerZero: Arb → Fraxtal]
   │
   │                    FraxtalHopV2.lzCompose()
   │                     │ → _sendLocal(RemoteVaultHop_FRAX, 0, msg)
   │                     ▼
   │                    RemoteVaultHop (Fraxtal).hopCompose()
   │                     │ action == Redeem
   │                     │ → _handleRedeem()
   │                     │
   │                     │ vault.redeem(shares) → tokensOut
   │                     │ balance[30_110][VAULT] -= shares
   │                     │ removeDust(tokensOut) → cleanAmount
   │                     │
   │                     │ encode RedeemReturn {
   │                     │   action: RedeemReturn
   │                     │   amount: cleanAmount
   │                     │   pricePerShare: updated pps
   │                     │ }
   │                     │
   │                     │ HOP.sendOFT{fee}(frxUSD, 30_110,
   │                     │   RemoteVaultHop_ARB, cleanAmount, 400K, data)
   │                     │
   │                     ├────────────────────────────────────────────►
   │                     │          [LayerZero: Fraxtal → Arb]
   │                     │              (actual frxUSD tokens travel back)
   │                     │
   │                     │              RemoteHopV2 (Arb).lzCompose()
   │                     │               │ → _sendLocal(RemoteVaultHop_ARB, amt, msg)
   │                     │               ▼
   │                     │              RemoteVaultHop (Arb).hopCompose()
   │                     │               │ action == RedeemReturn
   │                     │               │ → _handleRedeemReturn()
   │                     │               │
   │                     │               │ transfer(USER, cleanAmount)
   │                     │               │ rvDeposit.setPricePerShare(ts, pps)
   │                     │               ▼
   │                     │              USER receives frxUSD on Arbitrum
   │                     ▼
   ▼
```

---

### 2.7 Remote Admin Execution Flow

The Fraxtal multisig remotely pauses a spoke's `RemoteHopV2` over LayerZero.

```
  FRAXTAL (30_255)                       ARBITRUM (30_110)
  ────────────────                       ─────────────────

  FraxtalMsig (0x...)
   │
   │ 1. encode adminData = abi.encode(
   │      target = RemoteHopV2_ARB,
   │      data   = IHopV2.pauseOn.selector
   │    )
   │
   │ 2. FraxtalHopV2.sendOFT{value: fee}(
   │      oft       = frxUSD_FRAX,
   │      dstEid    = 30_110,
   │      recipient = RemoteAdmin_ARB,   ← bytes32 encoded
   │      amount    = DUST (1 wei),
   │      dstGas    = 400_000,
   │      data      = adminData
   │    )
   │
   ▼
  FraxtalHopV2
   │ _generateSendParam():
   │   to = RemoteHopV2_ARB (since dstEid has compose)
   │   composeMsg = abi.encode(HopMessage{
   │     sender: FraxtalMsig,
   │     recipient: RemoteAdmin_ARB,
   │     data: adminData
   │   })
   │
   │ IOFT.send{fee}() → Arbitrum
   │
   ├────────────────────────────────────────────────────────────────►
   │             [LayerZero: Fraxtal → Arbitrum]
   │
   │                  RemoteHopV2 (Arb).lzCompose()
   │                   │ _validateComposeMessage() → isTrusted ✓
   │                   │ _sendLocal(RemoteAdmin_ARB, amount, hopMsg)
   │                   │   → transfer(RemoteAdmin_ARB, 1 wei)
   │                   │   → IHopComposer(RemoteAdmin_ARB).hopCompose(
   │                   │       srcEid = 30_255,
   │                   │       sender = FraxtalMsig,
   │                   │       data   = adminData
   │                   │     )
   │                   ▼
   │                  RemoteAdmin.hopCompose()
   │                   │ msg.sender == RemoteHopV2_ARB ✓
   │                   │ _sender    == fraxtalMsig ✓
   │                   │ _srcEid    == FRAXTAL_EID ✓
   │                   │ _oft       == frxUsdOft ✓
   │                   │
   │                   │ (target, data) = decode(_data)
   │                   │ target.call(data)
   │                   │   → RemoteHopV2_ARB.pauseOn()  ✓
   │                   ▼
   │                  RemoteHopV2 (Arb) is now PAUSED
   ▼
```

---

## 3. Contract Reference

### 3.1 HopV2 (Abstract Base)

**File:** [src/contracts/hop/HopV2.sol](../src/contracts/hop/HopV2.sol)

Abstract base contract inherited by both `FraxtalHopV2` and `RemoteHopV2`.

#### Storage (`HopV2Storage`)

```solidity
struct HopV2Storage {
    uint32  localEid;                          // This chain's LayerZero EID
    address endpoint;                          // LayerZero endpoint address
    bool    paused;                            // Global pause flag
    mapping(address => bool)   approvedOft;    // OFT whitelist
    mapping(bytes32 => bool)   messageProcessed; // Replay protection
    mapping(uint32  => bytes32) remoteHop;     // eid → remote HopV2 address
    uint32  numDVNs;                           // DVN count for fee calculation
    uint256 hopFee;                            // Service fee (10_000 based, e.g. 100 = 1%)
    mapping(uint32  => bytes)   executorOptions; // Per-chain executor option overrides
    address EXECUTOR;                          // LayerZero Executor
    address DVN;                               // LayerZero DVN
    address TREASURY;                          // LayerZero Treasury
}
```

Storage slot: `keccak256("frax.storage.HopV2") - 1` (ERC-7201 namespaced).

#### Constants

```solidity
uint32 internal constant FRAXTAL_EID = 30_255;
bytes32 internal constant PAUSER_ROLE = keccak256("PAUSER_ROLE");
```

#### Public Functions

| Function | Mutability | Description |
|---|---|---|
| `sendOFT(oft, dstEid, recipient, amount)` | `payable` | Send OFT without compose data |
| `sendOFT(oft, dstEid, recipient, amount, dstGas, data)` | `payable` | Send OFT with compose data |
| `quote(oft, dstEid, recipient, amount, dstGas, data)` | `view` | Estimate total fee |
| `quoteHop(dstEid, dstGas, data)` | `view` | Estimate Fraxtal→dst leg fee |
| `removeDust(oft, amount)` | `view` | Strip sub-decimal amounts |

#### Admin Functions

| Function | Role Required | Description |
|---|---|---|
| `pauseOn()` | `PAUSER_ROLE` or `DEFAULT_ADMIN_ROLE` | Halt all hops |
| `pauseOff()` | `DEFAULT_ADMIN_ROLE` | Resume hops |
| `setApprovedOft(oft, bool)` | `DEFAULT_ADMIN_ROLE` | Whitelist/delist OFT |
| `setRemoteHop(eid, address)` | `DEFAULT_ADMIN_ROLE` | Register spoke address |
| `setRemoteHop(eid, bytes32)` | `DEFAULT_ADMIN_ROLE` | Register spoke (bytes32) |
| `setNumDVNs(n)` | `DEFAULT_ADMIN_ROLE` | Set DVN count for fee |
| `setHopFee(fee)` | `DEFAULT_ADMIN_ROLE` | Set service fee (10_000 based) |
| `setExecutorOptions(eid, opts)` | `DEFAULT_ADMIN_ROLE` | Set per-chain executor options |
| `setMessageProcessed(...)` | `DEFAULT_ADMIN_ROLE` | Manually mark message processed |
| `recover(target, value, data)` | `DEFAULT_ADMIN_ROLE` | Emergency fund recovery |

#### Key Events

```solidity
event SendOFT(address oft, address indexed sender, uint32 indexed dstEid, bytes32 indexed to, uint256 amount);
event MessageHash(address oft, uint32 indexed srcEid, uint64 indexed nonce, bytes32 indexed composeFrom);
```

#### Custom Errors

```solidity
error InvalidOFT();       // OFT not in approvedOft whitelist
error HopPaused();        // Contract is paused
error NotEndpoint();      // lzCompose caller is not LZ endpoint
error NotAuthorized();    // Caller lacks required role
error InsufficientFee();  // msg.value < required fee
error RefundFailed();     // ETH refund call failed
```

#### Fee Calculation (`quoteHop`)

```solidity
// For a cross-chain hop from Fraxtal → dstEid:
dvnFee      = ILayerZeroDVN(DVN).getFee(dstEid, 5, address(this), "")
executorFee = IExecutor(EXECUTOR).getFee(dstEid, address(this), msgLen, options)
//  msgLen = 360 + data.length
//  360 = 32 (sendTo) + 8 (amountShared) + 32 (composeFrom) + 288 (HopMessage base)

totalFee    = dvnFee * numDVNs + executorFee
treasuryFee = ILayerZeroTreasury(TREASURY).getFee(address(this), dstEid, totalFee, false)
finalFee    = totalFee + treasuryFee
finalFee    = (finalFee * (10_000 + hopFee)) / 10_000   // apply service fee
```

#### Dust Removal

LayerZero OFTs operate in "shared decimals" (typically 6 sd for 18-decimal tokens), meaning the lowest representable unit is `decimalConversionRate = 10^(localDecimals - sharedDecimals) = 10^12`. Any amount smaller than this is lost in transit. `removeDust` floors amounts to the nearest representable unit:

```solidity
function removeDust(address oft, uint256 amountLD) public view returns (uint256) {
    uint256 dcr = IOFT2(oft).decimalConversionRate();   // e.g. 1e12
    return (amountLD / dcr) * dcr;
}
```

---

### 3.2 FraxtalHopV2 (Hub)

**File:** [src/contracts/hop/FraxtalHopV2.sol](../src/contracts/hop/FraxtalHopV2.sol)

Deployed on Fraxtal at `0x00000000e18aFc20Afe54d4B2C8688bB60c06B36`.

#### Initialization

```solidity
function initialize(
    uint32 _localEid,        // 30_255
    address _endpoint,       // LZ endpoint on Fraxtal
    uint32 _numDVNs,         // DVN count
    address _EXECUTOR,
    address _DVN,
    address _TREASURY,
    address[] memory _approvedOfts
) external initializer
```

#### `sendOFT` Override

Adds a pre-check: destination must be Fraxtal itself OR a registered `remoteHop`.

```solidity
function sendOFT(...) public payable override {
    if (_dstEid != FRAXTAL_EID && remoteHop(_dstEid) == bytes32(0))
        revert InvalidDestinationChain();
    super.sendOFT(...);
}
```

#### `lzCompose` (Hub Routing Logic)

Called by the LayerZero endpoint when an OFT with a compose message arrives on Fraxtal.

```
lzCompose(oft, guid, message, executor, executorData)
    │
    ├─ _validateComposeMessage()
    │    ├─ sender == endpoint?                (NotEndpoint if not)
    │    ├─ paused?                            (HopPaused if yes)
    │    ├─ approvedOft[oft]?                  (InvalidOFT if not)
    │    ├─ messageProcessed[hash]?            (return early if duplicate)
    │    └─ isTrusted = remoteHop[srcEid] == composeFrom
    │
    ├─ decode HopMessage from OFTComposeMsgCodec.composeMsg()
    │
    ├─ if !isTrusted:
    │    overwrite hopMessage.srcEid with OFTComposeMsgCodec.srcEid()
    │    overwrite hopMessage.sender  with OFTComposeMsgCodec.composeFrom()
    │
    ├─ if hopMessage.dstEid == FRAXTAL_EID:
    │    _sendLocal(oft, amount, hopMessage)
    │       transfer tokens to recipient
    │       if data.length > 0: IHopComposer(recipient).hopCompose(...)
    │
    └─ else (dstEid is a remote chain):
         _sendToDestination(oft, amount, isTrusted, hopMessage)
            → IOFT(oft).send() with composeMsg to RemoteHopV2[dstEid]
         emit Hop(oft, srcEid, dstEid, recipient, amount)
```

#### `_generateSendParam` (Hub Implementation)

```solidity
// No compose data → direct delivery to recipient
sendParam.to = hopMessage.recipient

// With compose data → deliver to RemoteHopV2 with compose execution
sendParam.to = remoteHop(hopMessage.dstEid)   // must not be 0 or reverts
sendParam.extraOptions = LzComposeOption(index=0, gas=dstGas, value=0)
sendParam.composeMsg = abi.encode(hopMessage)
```

#### Additional Errors

```solidity
error InvalidDestinationChain();  // dstEid not registered as remoteHop
error InvalidRemoteHop();         // remoteHop[dstEid] is address(0) during compose
```

#### Events

```solidity
event Hop(
    address oft,
    uint32 indexed srcEid,
    uint32 indexed dstEid,
    bytes32 indexed recipient,
    uint256 amount
);
```

---

### 3.3 RemoteHopV2 (Spoke)

**File:** [src/contracts/hop/RemoteHopV2.sol](../src/contracts/hop/RemoteHopV2.sol)

Deployed on Arbitrum, Base, Ethereum at `0x0000006D38568b00B457580b734e0076C62de659`.

#### Initialization

```solidity
function initialize(
    uint32 _localEid,         // e.g. 30_110 for Arbitrum
    address _endpoint,
    bytes32 _fraxtalHop,      // FraxtalHopV2 address as bytes32
    uint32 _numDVNs,
    address _EXECUTOR,
    address _DVN,
    address _TREASURY,
    address[] memory _approvedOfts
) external initializer
// Internally calls: _setRemoteHop(FRAXTAL_EID, _fraxtalHop)
```

#### `_generateSendParam` (Spoke Implementation)

The spoke **always sends to Fraxtal first**, never directly to another remote.

```solidity
// Case 1: Direct send to Fraxtal, no compose needed
if (dstEid == FRAXTAL_EID && data.length == 0):
    sendParam.dstEid = FRAXTAL_EID
    sendParam.to     = recipient             // lands directly
    // no extraOptions, no composeMsg

// Case 2: Everything else → relay through Fraxtal
else:
    sendParam.dstEid = FRAXTAL_EID
    sendParam.to     = remoteHop(FRAXTAL_EID)  // FraxtalHopV2
    fraxtalGas = max(1_000_000, dstGas if dstEid==FRAXTAL else 1_000_000)
    sendParam.extraOptions = LzComposeOption(0, fraxtalGas, 0)
    sendParam.composeMsg   = abi.encode(hopMessage)
    // HopMessage carries the original dstEid for the hub to continue routing
```

**Gas enforcement:**
- `dstGas` supplied by user is floored to `400_000`
- Gas forwarded to Fraxtal is always at least `1_000_000` (to handle the hub's routing logic)

#### `lzCompose` (Spoke Delivery)

The spoke only handles **local delivery** — it never re-routes to another chain.

```solidity
lzCompose(oft, guid, message, executor, executorData)
    │
    ├─ _validateComposeMessage()  (same checks as hub)
    │
    ├─ decode HopMessage
    │
    ├─ if !isTrusted: overwrite srcEid + sender (anti-spoofing)
    │
    └─ _sendLocal(oft, amount, hopMessage)
         transfer tokens to hopMessage.recipient
         if data.length > 0:
             IHopComposer(recipient).hopCompose(srcEid, sender, oft, amount, data)
         emit Hop(oft, recipient, amount)
```

#### Events

```solidity
event Hop(address oft, address indexed recipient, uint256 amount);
```

---

### 3.4 RemoteAdmin

**File:** [src/contracts/RemoteAdmin.sol](../src/contracts/RemoteAdmin.sol)

Non-upgradeable helper contract deployed alongside each `RemoteHopV2`. Enables the Fraxtal multisig to execute arbitrary admin calls on remote chains by sending a composed hop.

#### Constructor Parameters

```solidity
constructor(
    address _frxUsdOft,      // frxUSD OFT on this chain
    address _hopV2,          // RemoteHopV2 on this chain
    address _fraxtalMsig     // Fraxtal multisig address
)
```

#### `hopCompose`

Strict validation before executing any call:

```solidity
function hopCompose(
    uint32 _srcEid,
    bytes32 _sender,
    address _oft,
    uint256, /* amount */
    bytes memory _data
) external {
    require(msg.sender == hopV2);          // must come through RemoteHopV2
    require(_sender == fraxtalMsig);       // must originate from Fraxtal msig
    require(_srcEid == FRAXTAL_EID);       // must come from Fraxtal chain
    require(_oft == frxUsdOft);            // must use frxUSD token

    (address target, bytes memory data) = abi.decode(_data, (address, bytes));
    (bool success,) = target.call(data);
    require(success);
}
```

**Use Cases:**
- `RemoteHopV2.pauseOn()` / `pauseOff()`
- `RemoteHopV2.setApprovedOft(address, bool)`
- `RemoteHopV2.setHopFee(uint256)`
- `RemoteHopV2.setRemoteHop(uint32, address)`
- Any contract where `RemoteAdmin` holds `DEFAULT_ADMIN_ROLE`

---

### 3.5 RemoteVaultHop

**File:** [src/contracts/vault/RemoteVaultHop.sol](../src/contracts/vault/RemoteVaultHop.sol)

Upgradeable `IHopComposer` contract that orchestrates cross-chain ERC-4626 vault interactions.

#### Storage

```solidity
IERC20  TOKEN;                                           // frxUSD
address OFT;                                             // frxUSD OFT
IHopV2  HOP;                                             // Local HopV2 contract
uint32  EID;                                             // This chain's EID
uint256 DECIMAL_CONVERSION_RATE;

mapping(address vault  => address share)     vaultShares;   // local vaults
mapping(uint32  eid    => address)           remoteVaultHops;
mapping(uint32  eid    => mapping(address vault => RemoteVaultDeposit)) depositToken;
mapping(uint32  eid    => mapping(address vault => uint128))            remoteGas;
mapping(uint32  vaultEid => mapping(address vault => uint256)) balance; // shares held
```

#### `RemoteVaultMessage`

```solidity
struct RemoteVaultMessage {
    Action   action;           // Deposit | DepositReturn | Redeem | RedeemReturn
    uint32   userEid;          // Chain where user lives
    address  userAddress;      // User's address
    uint32   remoteEid;        // Chain where vault lives
    address  remoteVault;      // Vault address
    uint256  amount;           // Token amount or share count (context-dependent)
    uint64   remoteTimestamp;  // block.timestamp on vault chain (for PPS freshness)
    uint128  pricePerShare;    // vault.convertToAssets(1e18)
}
```

#### `hopCompose` Routing

```
hopCompose(srcEid, srcAddress, oft, amount, data)
    │
    ├─ require(msg.sender == HOP)
    ├─ require(oft == OFT)
    ├─ require(remoteVaultHops[srcEid] == srcAddress)  // authenticated sender
    │
    ├─ decode RemoteVaultMessage
    │
    ├─ action == Deposit      → _handleDeposit()
    ├─ action == Redeem       → _handleRedeem()
    ├─ action == DepositReturn → _handleDepositReturn()
    └─ action == RedeemReturn  → _handleRedeemReturn()
```

#### Fee Quoting

The vault quote covers the **round trip** (out + back):

```solidity
// Case: A ←→ B (both non-Fraxtal)
totalFee = HOP.quote(OFT, remoteEid, remoteVaultHop, amount, remoteGas, outMsg)  // A → Fraxtal → B
         + HOP.quoteHop(EID, LOCAL_GAS, returnMsg)                               // B → Fraxtal leg
         + HOP.quoteHop(FRAXTAL_EID, 1_000_000, returnMsg)                       // Fraxtal → A leg

// Case: A ←→ Fraxtal (one leg)
totalFee = HOP.quote(OFT, FRAXTAL_EID, remoteVaultHop, amount, remoteGas, msg)  // A → Fraxtal
         + HOP.quoteHop(EID, LOCAL_GAS, returnMsg)                               // Fraxtal → A
```

---

### 3.6 RemoteVaultDeposit

**File:** [src/contracts/vault/RemoteVaultDeposit.sol](../src/contracts/vault/RemoteVaultDeposit.sol)

ERC20 receipt token representing a user's pro-rata share in a remote ERC-4626 vault. One `RemoteVaultDeposit` token is deployed per `(remoteChain, vaultAddress)` pair by calling `RemoteVaultHop.addRemoteVault()`.

#### Price Per Share (PPS) with Linear Interpolation

Because cross-chain price updates are not instantaneous, the contract smoothly transitions between PPS values over 100 blocks to prevent arbitrage:

```solidity
function pricePerShare() public view returns (uint256) {
    if (block.number > ppsUpdateBlock + 99) return pps;  // fully settled

    // Linear interpolation over 100 blocks
    int256 delta = int256(uint256(pps)) - int256(uint256(previousPps));
    int256 interpolated = int256(uint256(previousPps))
                        + (delta * int256(block.number - ppsUpdateBlock)) / 100;
    return uint256(interpolated);
}
```

**Timeline:**

```
Block 0 (update)   Block 50              Block 100+
      │                  │                     │
      pps = newPps ─────►│── linear ramp ─────►│── returns newPps (fixed)
      previousPps stored │                     │
```

#### Core User Functions

```solidity
// Deposit: transfer asset → mint receipt tokens (async, cross-chain)
function deposit(uint256 amount) external payable
function deposit(uint256 amount, address to) public payable

// Redeem: burn receipt tokens → receive asset back (async, cross-chain)
function redeem(uint256 amount) public payable
function redeem(uint256 amount, address to) public payable

// Quote: estimate round-trip fee
function quote(uint256 amount) public view returns (uint256 fee)
```

---

## 4. Message Encoding & Codec

All composed messages use LayerZero's `OFTComposeMsgCodec`. The full wire format is:

```
OFTComposeMsgCodec wire format:
┌──────────────────────────────────────────────────────────────────────────────┐
│  srcEid (4 bytes) │ composeFrom (32 bytes) │ amountLD (32 bytes*) │          │
│  nonce   (8 bytes)│                        │                      │          │
│                   │                        │                      composeMsg │
└──────────────────────────────────────────────────────────────────────────────┘
* amountLD stored as uint64 (shared decimals) then decoded back to LD

composeMsg = abi.encode(HopMessage)

HopMessage struct:
┌──────────────┬──────────────┬──────────────┬──────────────────────────────────┐
│ srcEid(4B)   │ dstEid(4B)   │ dstGas(16B)  │ sender (32B) │ recipient (32B)   │
│              │              │              │              │ data (dynamic)     │
└──────────────┴──────────────┴──────────────┴──────────────┴────────────────────┘
```

**Message hash for replay protection:**

```solidity
bytes32 hash = keccak256(abi.encode(oft, srcEid, nonce, composeFrom));
```

This ensures each (token, source chain, message sequence, sender) combination is processed exactly once.

---

## 5. Fee Structure

### Fee Components

```
Total user fee = LZ OFT send fee + Hop service fee

LZ OFT send fee:
  IOFT.quoteSend(sendParam, false).nativeFee

Hop service fee (for remote→remote only, charged on Fraxtal leg):
  quoteHop(dstEid, dstGas, data)
  = (dvnFee × numDVNs + executorFee + treasuryFee) × (1 + hopFee/10_000)
```

### Fee Rules by Route

| Route | Fee |
|---|---|
| Same chain (A → A) | `0` |
| Fraxtal → Remote | LZ fee only (`hopFeeOnFraxtal = 0` when `localEid == FRAXTAL_EID`) |
| Remote → Fraxtal | LZ fee only (Fraxtal is the destination, one leg only) |
| Remote A → Remote B | LZ(A→Fraxtal) + `quoteHop(B)` including service fee |

### Service Fee (`hopFee`)

Expressed in basis points with 10,000 base:

```
hopFee = 100  → 1% additional on Fraxtal relay fees
hopFee = 10   → 0.1%
hopFee = 0    → no service fee (default)
```

### Vault Round-Trip Fee

```
fee(A→B vault deposit) =
    HOP.quote(OFT, B, remoteVaultHop_B, amount, remoteGas, outMsg)   // A→(Fraxtal)→B
  + HOP.quoteHop(A_EID, 400_000, returnMsg)                          // B→(Fraxtal)→A return
  + (HOP.quoteHop(FRAXTAL_EID, 1_000_000, returnMsg) if A≠Fraxtal and B≠Fraxtal)
```

---

## 6. Security Model

### 6.1 Message Authentication

Two trust levels:

```
isTrustedHopMessage = (remoteHop[srcEid] == composeFrom)

Trusted:   composeFrom is a registered RemoteHopV2
           → HopMessage.srcEid and .sender are taken at face value
           → Used for protocol-internal routing

Untrusted: composeFrom is an arbitrary contract
           → HopMessage.srcEid and .sender are OVERWRITTEN with
             OFTComposeMsgCodec.srcEid() and .composeFrom()
           → Prevents spoofed HopMessage data
           → User can still bridge via any composer, but cannot impersonate chains
```

### 6.2 Replay Protection

```solidity
// Every message is keyed by (oft, srcEid, nonce, composeFrom)
bytes32 messageHash = keccak256(abi.encode(_oft, srcEid, nonce, composeFrom));

if ($.messageProcessed[messageHash]) return (isTrusted, true);  // skip duplicate
$.messageProcessed[messageHash] = true;
```

Administrators can manually mark a hash processed via `setMessageProcessed()` to handle edge cases.

### 6.3 Access Control

```
DEFAULT_ADMIN_ROLE
  ├─ setApprovedOft()         Whitelist OFTs
  ├─ setRemoteHop()           Register spokes
  ├─ setNumDVNs()             DVN configuration
  ├─ setHopFee()              Service fee
  ├─ setExecutorOptions()     Per-chain gas options
  ├─ pauseOff()               Resume (admin only, not pauser)
  ├─ setMessageProcessed()    Manual replay mark
  └─ recover()                Emergency fund recovery

PAUSER_ROLE
  └─ pauseOn()                Halt hops (emergency)
```

### 6.4 OFT Whitelist

Only OFTs in the `approvedOft` mapping can be bridged. `InvalidOFT()` is thrown otherwise.

### 6.5 Dust Removal

All amounts are floored to `decimalConversionRate` multiples before sending. This ensures the amount announced in the `HopMessage` equals the amount that actually arrives on the destination chain (no silent dust loss).

### 6.6 Fee Refunds

`sendOFT` and vault functions refund overpaid native tokens:

```solidity
if (msg.value > sendFee) {
    (bool success,) = payable(msg.sender).call{value: msg.value - sendFee}("");
    if (!success) revert RefundFailed();
}
```

---

## 7. Technical Examples

### Setup

```solidity
// Chain IDs (LayerZero EIDs)
uint32 constant FRAXTAL_EID  = 30_255;
uint32 constant ARBITRUM_EID = 30_110;
uint32 constant BASE_EID     = 30_102;
uint32 constant ETHEREUM_EID = 30_101;

// Deployed addresses
address constant FRAXTAL_HOP    = 0x00000000e18aFc20Afe54d4B2C8688bB60c06B36;
address constant ARBITRUM_HOP   = 0x0000006D38568b00B457580b734e0076C62de659;
address constant BASE_HOP       = 0x0000006D38568b00B457580b734e0076C62de659;
address constant ETHEREUM_HOP   = 0x0000006D38568b00B457580b734e0076C62de659;

// frxUSD OFT (representative; actual varies per chain)
address constant FRX_USD_FRAXTAL = 0x96A394058E2b84A89bac9667B19661Ed003cF5D4;
```

---

### 7.1 Simple Token Bridge: Remote → Fraxtal

Send frxUSD from Base to a Fraxtal address.

```solidity
// On Base
IHopV2 hop = IHopV2(BASE_HOP);
address oft = frxUSD_BASE;            // frxUSD OFT on Base
address user = msg.sender;
bytes32 recipient = bytes32(uint256(uint160(0xFRAXTAL_RECIPIENT)));
uint256 amount = 1000e18;

// 1. Get fee estimate
uint256 fee = hop.quote(
    oft,
    FRAXTAL_EID,
    recipient,
    amount,
    0,   // no extra gas (no compose)
    ""   // no data
);

// 2. Approve the underlying token
IERC20(IOFT(oft).token()).approve(BASE_HOP, amount);

// 3. Send
// msg.value must be >= fee; excess is refunded
hop.sendOFT{value: fee}(oft, FRAXTAL_EID, recipient, amount);
```

**What happens on-chain:**
- `RemoteHopV2._generateSendParam()` sets `dstEid=FRAXTAL`, `to=recipient`, no compose
- LZ delivers the OFT directly to `recipient` on Fraxtal
- No `lzCompose` callback needed

---

### 7.2 Token Bridge: Remote A → Remote B

Send frxUSD from Arbitrum to a Base address. Relays through Fraxtal.

```solidity
// On Arbitrum
IHopV2 hop = IHopV2(ARBITRUM_HOP);
address oft = frxUSD_ARB;
bytes32 recipient = bytes32(uint256(uint160(0xBASE_RECIPIENT)));
uint256 amount = 500e18;

// 1. Get fee (includes both LZ leg A→Fraxtal AND quoteHop Fraxtal→Base)
uint256 fee = hop.quote(
    oft,
    BASE_EID,
    recipient,
    amount,
    0,
    ""
);

// 2. Approve
IERC20(IOFT(oft).token()).approve(ARBITRUM_HOP, amount);

// 3. Send
hop.sendOFT{value: fee}(oft, BASE_EID, recipient, amount);

// Internally:
// RemoteHopV2._generateSendParam() wraps a HopMessage{dstEid:BASE_EID} and sends to Fraxtal
// FraxtalHopV2.lzCompose() decodes it, sees dstEid=BASE, calls _sendToDestination()
// RemoteHopV2 on Base receives, lzCompose() fires, _sendLocal() transfers to recipient
```

---

### 7.3 Fraxtal → Remote

Send frxUSD from Fraxtal to Ethereum.

```solidity
// On Fraxtal
IHopV2 hub = IHopV2(FRAXTAL_HOP);
address oft = FRX_USD_FRAXTAL;
bytes32 recipient = bytes32(uint256(uint160(0xETH_RECIPIENT)));
uint256 amount = 2000e18;

// 1. Quote (no hopFee since we're already on Fraxtal)
uint256 fee = hub.quote(oft, ETHEREUM_EID, recipient, amount, 0, "");

// 2. Approve
IERC20(IOFT(oft).token()).approve(FRAXTAL_HOP, amount);

// 3. Send directly
hub.sendOFT{value: fee}(oft, ETHEREUM_EID, recipient, amount);
```

---

### 7.4 Composed Message with Custom Execution

Send frxUSD from Base to a contract on Arbitrum that implements `IHopComposer`.

```solidity
// On Base
IHopV2 hop = IHopV2(BASE_HOP);
address oft = frxUSD_BASE;

// Recipient is a IHopComposer contract on Arbitrum
bytes32 recipient = bytes32(uint256(uint160(0xARB_COMPOSER)));
uint256 amount = 100e18;
uint128 dstGas = 500_000;    // gas for IHopComposer.hopCompose() on Arbitrum

// Arbitrary payload for the composer
bytes memory composerData = abi.encode(
    address(0xSOME_TOKEN),
    uint256(42),
    bytes("hello")
);

// 1. Quote (includes Fraxtal relay fee since going Arb → not-Fraxtal)
uint256 fee = hop.quote(oft, ARBITRUM_EID, recipient, amount, dstGas, composerData);

// 2. Approve
IERC20(IOFT(oft).token()).approve(BASE_HOP, amount);

// 3. Send with compose
hop.sendOFT{value: fee}(oft, ARBITRUM_EID, recipient, amount, dstGas, composerData);

// Execution chain:
// Base.RemoteHopV2.sendOFT → Fraxtal.FraxtalHopV2.lzCompose
//   → Arbitrum.RemoteHopV2.lzCompose
//     → _sendLocal: transfer tokens to 0xARB_COMPOSER
//     → IHopComposer(0xARB_COMPOSER).hopCompose(
//           srcEid=BASE_EID,
//           sender=bytes32(msg.sender_on_Base),
//           oft=frxUSD_ARB,
//           amount=100e18,
//           data=composerData
//       )
```

---

### 7.5 Cross-Chain Vault Deposit

User on Arbitrum deposits frxUSD into an sfrxUSD vault on Fraxtal.

```solidity
// On Arbitrum
RemoteVaultDeposit rvd = RemoteVaultDeposit(RVD_SFRXUSD_ARB);  // deployed by protocol
uint256 amount = 1000e18;

// 1. Quote round-trip fee
uint256 fee = rvd.quote(amount);

// 2. Approve frxUSD
IERC20(frxUSD_ARB).approve(address(rvd), amount);

// 3. Deposit (fee covers both legs: ARB→FRAX deposit + FRAX→ARB return)
rvd.deposit{value: fee}(amount);

// After ~1-3 minutes:
// - User holds RemoteVaultDeposit tokens on Arbitrum
// - pricePerShare() returns current sfrxUSD price with linear interpolation
// - sfrxUSD vault on Fraxtal holds the actual shares
```

**Depositing on behalf of another address:**

```solidity
address beneficiary = 0xOTHER_USER;
rvd.deposit{value: fee}(amount, beneficiary);
// RemoteVaultDeposit tokens minted to beneficiary, not msg.sender
```

---

### 7.6 Cross-Chain Vault Redeem

```solidity
RemoteVaultDeposit rvd = RemoteVaultDeposit(RVD_SFRXUSD_ARB);
uint256 shares = rvd.balanceOf(msg.sender);  // shares to redeem

// 1. Quote
uint256 fee = rvd.quote(shares);

// 2. Redeem (burns RVD tokens immediately, frxUSD arrives async)
rvd.redeem{value: fee}(shares);

// After ~1-3 minutes:
// - frxUSD transferred to msg.sender on Arbitrum
// - pricePerShare() on RVD updated with latest vault price
```

---

### 7.7 Remote Admin Call

Pause `RemoteHopV2` on Base remotely from the Fraxtal multisig.

```solidity
// On Fraxtal, called by the multisig
IHopV2 fraxtalHop = IHopV2(FRAXTAL_HOP);
address oft = FRX_USD_FRAXTAL;
address remoteAdmin_BASE = 0x07dB789aD17573e5169eDEfe14df91CC305715AA;
address remoteHop_BASE   = 0x0000006D38568b00B457580b734e0076C62de659;

// Encode target + calldata
bytes memory adminCalldata = abi.encodeCall(IHopV2.pauseOn, ());
bytes memory composerData  = abi.encode(remoteHop_BASE, adminCalldata);

bytes32 recipient = bytes32(uint256(uint160(remoteAdmin_BASE)));
uint256 dustAmount = 1e12;  // minimum above dust threshold

uint256 fee = fraxtalHop.quote(oft, BASE_EID, recipient, dustAmount, 400_000, composerData);
IERC20(IOFT(oft).token()).approve(FRAXTAL_HOP, dustAmount);

fraxtalHop.sendOFT{value: fee}(
    oft,
    BASE_EID,
    recipient,
    dustAmount,
    400_000,
    composerData
);

// RemoteAdmin on Base will call: RemoteHopV2_BASE.pauseOn()
```

**Unpause** (admin-only, cannot use RemoteAdmin for pauseOff):

```solidity
// Must be called directly by DEFAULT_ADMIN_ROLE on Base
IHopV2(remoteHop_BASE).pauseOff();
```

---

### 7.8 Implementing IHopComposer

Build a contract that receives tokens + executes logic when a hop arrives.

```solidity
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import { IHopComposer } from "src/contracts/interfaces/IHopComposer.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @notice Example: auto-stake frxUSD into a vault on arrival
contract AutoStakeComposer is IHopComposer {
    address public immutable HOP;          // Local HopV2 address
    address public immutable TOKEN;        // frxUSD token
    address public immutable VAULT;        // ERC-4626 vault

    error NotHop();
    error InvalidToken();

    constructor(address _hop, address _token, address _vault) {
        HOP = _hop;
        TOKEN = _token;
        VAULT = _vault;
    }

    /// @notice Called by RemoteHopV2 after tokens are transferred to this contract.
    /// @param _srcEid  Source chain EID
    /// @param _sender  Original sender on source chain (bytes32)
    /// @param _oft     OFT token address
    /// @param _amount  Amount of tokens transferred to this contract
    /// @param _data    ABI-encoded (address beneficiary)
    function hopCompose(
        uint32 _srcEid,
        bytes32 _sender,
        address _oft,
        uint256 _amount,
        bytes memory _data
    ) external override {
        // Only callable by local HopV2
        if (msg.sender != HOP) revert NotHop();
        // Only accept approved token
        if (_oft != TOKEN) revert InvalidToken();   // or check via IHopV2.approvedOft()

        address beneficiary = abi.decode(_data, (address));

        // Stake received tokens into vault on behalf of beneficiary
        SafeERC20.forceApprove(IERC20(TOKEN), VAULT, _amount);
        IERC4626(VAULT).deposit(_amount, beneficiary);

        // Note: _srcEid and _sender can be used for access control
        // if you only want to accept from specific chains/users
    }
}
```

**Sending to the composer from a remote chain:**

```solidity
// Encode beneficiary
address beneficiary = msg.sender;
bytes memory data = abi.encode(beneficiary);

bytes32 composerAddr = bytes32(uint256(uint160(address(autoStakeComposer))));
uint128 gasForCompose = 300_000;  // enough for vault.deposit()

uint256 fee = remoteHop.quote(oft, DEST_EID, composerAddr, amount, gasForCompose, data);
IERC20(token).approve(address(remoteHop), amount);
remoteHop.sendOFT{value: fee}(oft, DEST_EID, composerAddr, amount, gasForCompose, data);
```

---

### 7.9 Checking if a Route is Supported

Before calling `sendOFT`, verify the destination is configured:

```solidity
IHopV2 hop = IHopV2(SOME_REMOTE_HOP);

// From a remote: all traffic goes to Fraxtal first, which then routes out.
// Check if Fraxtal has the destination registered:
IHopV2 fraxtalHop = IHopV2(FRAXTAL_HOP);
bytes32 remoteAddr = fraxtalHop.remoteHop(TARGET_EID);
require(remoteAddr != bytes32(0), "Destination chain not supported");

// Check if OFT is approved on both ends:
require(hop.approvedOft(srcOft),          "OFT not approved on source");
// (Fraxtal approval is checked implicitly during lzCompose)
```

---

### 7.10 Estimating Fees Off-Chain (TypeScript / ethers.js)

```typescript
import { ethers } from "ethers";

const REMOTE_HOP_ABI = [
  "function quote(address oft, uint32 dstEid, bytes32 recipient, uint256 amount, uint128 dstGas, bytes data) external view returns (uint256)",
  "function quoteHop(uint32 dstEid, uint128 dstGas, bytes data) external view returns (uint256)",
];

const provider = new ethers.JsonRpcProvider("https://rpc.arbitrum.io");
const remoteHop = new ethers.Contract(
  "0x0000006D38568b00B457580b734e0076C62de659",
  REMOTE_HOP_ABI,
  provider
);

const frxUSD_ARB = "0x...";  // frxUSD OFT on Arbitrum
const BASE_EID   = 30_102;
const recipient  = ethers.zeroPadValue("0xRecipientAddress", 32);
const amount     = ethers.parseEther("1000");  // 1000 frxUSD

// Simple bridge: Arbitrum → Base
const fee = await remoteHop.quote(
  frxUSD_ARB,
  BASE_EID,
  recipient,
  amount,
  0n,       // no extra gas
  "0x"      // no compose data
);

console.log(`Bridge fee: ${ethers.formatEther(fee)} ETH`);
// Typically: ~0.0001 ETH for Arb→Fraxtal→Base

// Bridge with composed execution
const composerAddress = "0xComposerOnBase";
const composerData = ethers.AbiCoder.defaultAbiCoder().encode(
  ["address"],
  ["0xBeneficiary"]z
);
const feeWithCompose = await remoteHop.quote(
  frxUSD_ARB,
  BASE_EID,
  ethers.zeroPadValue(composerAddress, 32),
  amount,
  500_000n,     // gas for composer
  composerData
);
console.log(`Bridge + compose fee: ${ethers.formatEther(feeWithCompose)} ETH`);
```

---

## 8. Deployed Addresses

### HopV2 Contracts

| Chain | `Hop` | `RemoteAdmin` |
| --- | --- | --- |
| Arbitrum | [`0x0000006D38568b00B457580b734e0076C62de659`](https://arbiscan.io/address/0x0000006D38568b00B457580b734e0076C62de659) | [`0x954286118E93df807aB6f99aE0454f8710f0a8B9`](https://arbiscan.io/address/0x954286118E93df807aB6f99aE0454f8710f0a8B9) |
| Avalanche | [`0x0000006D38568b00B457580b734e0076C62de659`](https://routescan.io/address/0x0000006D38568b00B457580b734e0076C62de659/contract/43114/code) | [`0x954286118E93df807aB6f99aE0454f8710f0a8B9`](https://routescan.io/address/0x954286118E93df807aB6f99aE0454f8710f0a8B9/contract/43114/code) |
| Berachain | [`0x0000006D38568b00B457580b734e0076C62de659`](https://berascan.com/address/0x0000006D38568b00B457580b734e0076C62de659) | [`0x954286118E93df807aB6f99aE0454f8710f0a8B9`](https://berascan.com/address/0x954286118E93df807aB6f99aE0454f8710f0a8B9) |
| BSC | [`0x0000006D38568b00B457580b734e0076C62de659`](https://bscscan.com/address/0x0000006D38568b00B457580b734e0076C62de659) | [`0x954286118E93df807aB6f99aE0454f8710f0a8B9`](https://bscscan.com/address/0x954286118E93df807aB6f99aE0454f8710f0a8B9) |
| Ink | [`0x0000006D38568b00B457580b734e0076C62de659`](https://routescan.io/address/0x0000006D38568b00B457580b734e0076C62de659/contract/57073/code) | [`0x954286118E93df807aB6f99aE0454f8710f0a8B9`](https://routescan.io/address/0x954286118E93df807aB6f99aE0454f8710f0a8B9/contract/57073/code) |
| Katana | [`0x0000006D38568b00B457580b734e0076C62de659`](https://katanascan.com/address/0x0000006d38568b00b457580b734e0076c62de659) | [`0x954286118E93df807aB6f99aE0454f8710f0a8B9`](https://katanascan.com/address/0x954286118E93df807aB6f99aE0454f8710f0a8B9) |
| Mode | [`0x0000006D38568b00B457580b734e0076C62de659`](https://explorer.mode.network/address/0x0000006d38568b00b457580b734e0076c62de659) | [`0x954286118E93df807aB6f99aE0454f8710f0a8B9`](https://explorer.mode.network/address/0x954286118E93df807aB6f99aE0454f8710f0a8B9) |
| Optimism | [`0x0000006D38568b00B457580b734e0076C62de659`](https://optimistic.etherscan.io/address/0x0000006d38568b00b457580b734e0076c62de659) | [`0x954286118E93df807aB6f99aE0454f8710f0a8B9`](https://optimistic.etherscan.io/address/0x954286118E93df807aB6f99aE0454f8710f0a8B9) |
| Plume | [`0x0000006D38568b00B457580b734e0076C62de659`](https://explorer.plume.org/address/0x0000006d38568b00b457580b734e0076c62de659) | [`0x954286118E93df807aB6f99aE0454f8710f0a8B9`](https://explorer.plume.org/address/0x954286118E93df807aB6f99aE0454f8710f0a8B9) |
| Polygon | [`0x0000006D38568b00B457580b734e0076C62de659`](https://polygonscan.com/address/0x0000006d38568b00b457580b734e0076c62de659) | [`0x954286118E93df807aB6f99aE0454f8710f0a8B9`](https://polygonscan.com/address/0x954286118E93df807aB6f99aE0454f8710f0a8B9) |
| Sei | [`0x0000006D38568b00B457580b734e0076C62de659`](https://seiscan.io/address/0x0000006d38568b00b457580b734e0076c62de659) | [`0x954286118E93df807aB6f99aE0454f8710f0a8B9`](https://seiscan.io/address/0x954286118E93df807aB6f99aE0454f8710f0a8B9) |
| Sonic | [`0x0000006D38568b00B457580b734e0076C62de659`](https://sonicscan.org/address/0x0000006d38568b00b457580b734e0076c62de659) | [`0x954286118E93df807aB6f99aE0454f8710f0a8B9`](https://sonicscan.org/address/0x954286118E93df807aB6f99aE0454f8710f0a8B9) |
| Stable | [`0x0000006D38568b00B457580b734e0076C62de659`](https://stablescan.xyz/address/0x0000006d38568b00b457580b734e0076c62de659) | [`0x954286118E93df807aB6f99aE0454f8710f0a8B9`](https://stablescan.xyz/address/0x954286118E93df807aB6f99aE0454f8710f0a8B9) |
| Unichain | [`0x0000006D38568b00B457580b734e0076C62de659`](https://uniscan.xyz/address/0x0000006d38568b00b457580b734e0076c62de659) | [`0x954286118E93df807aB6f99aE0454f8710f0a8B9`](https://uniscan.xyz/address/0x954286118E93df807aB6f99aE0454f8710f0a8B9) |
| Worldchain | [`0x0000006D38568b00B457580b734e0076C62de659`](https://worldscan.org/address/0x0000006d38568b00b457580b734e0076c62de659) | [`0x954286118E93df807aB6f99aE0454f8710f0a8B9`](https://worldscan.org/address/0x954286118E93df807aB6f99aE0454f8710f0a8B9) |
| Base | [`0x0000006D38568b00B457580b734e0076C62de659`](https://basescan.org/address/0x0000006D38568b00B457580b734e0076C62de659) | [`0x07dB789aD17573e5169eDEfe14df91CC305715AA`](https://basescan.org/address/0x07dB789aD17573e5169eDEfe14df91CC305715AA) |
| Ethereum | [`0x0000006D38568b00B457580b734e0076C62de659`](https://etherscan.io/address/0x0000006D38568b00B457580b734e0076C62de659) | [`0x181EBC9deA868ED8e5EeeAef7f767D43BF390dFa`](https://etherscan.io/address/0x181EBC9deA868ED8e5EeeAef7f767D43BF390dFa) |
| Linea | [`0x0000006D38568b00B457580b734e0076C62de659`](https://lineascan.build/address/0x0000006D38568b00B457580b734e0076C62de659) | [`0xfa803b63DaACCa6CD953061BDBa4E3da6b177447`](https://lineascan.build/address/0xfa803b63DaACCa6CD953061BDBa4E3da6b177447) |
| Monad | [`0x0000006D38568b00B457580b734e0076C62de659`](https://monadscan.com/address/0x0000006D38568b00B457580b734e0076C62de659) | [`0x4bE0942c2CbFd741DB5906CF2831c1AF29fcEa55`](https://monadscan.com/address/0x4bE0942c2CbFd741DB5906CF2831c1AF29fcEa55) |
| Scroll | [`0x0000006D38568b00B457580b734e0076C62de659`](https://scrollscan.com/address/0x0000006D38568b00B457580b734e0076C62de659) | [`0x1dE5910A2b0f860A226a8a43148aeA91afbE3d01`](https://scrollscan.com/address/0x1dE5910A2b0f860A226a8a43148aeA91afbE3d01) |
| Fraxtal | [`0x00000000e18aFc20Afe54d4B2C8688bB60c06B36`](https://fraxscan.com/address/0x00000000e18aFc20Afe54d4B2C8688bB60c06B36) | [`0x34029e02821178B4387e12644896994f910D6E73`](https://fraxscan.com/address/0x34029e02821178B4387e12644896994f910D6E73) |


---

## 9. Integration Checklist

### Before Calling `sendOFT`

- [ ] Verify `hop.approvedOft(oftAddress) == true`
- [ ] For remote→remote: verify `FraxtalHopV2.remoteHop(dstEid) != bytes32(0)`
- [ ] Call `hop.quote()` to get accurate fee; pass as `msg.value` (excess is refunded)
- [ ] `approve(IOFT(oft).token(), hopAddress, amount)` — note: approve the **underlying token**, not the OFT
- [ ] Ensure `amount` is above `removeDust` threshold (`decimalConversionRate`, typically `1e12`)
- [ ] Check `hop.paused() == false`

### For Compose Messages (`IHopComposer`)

- [ ] Implement `hopCompose(uint32, bytes32, address, uint256, bytes)` on recipient contract
- [ ] Validate `msg.sender == localHopAddress` inside `hopCompose`
- [ ] Set `dstGas` high enough to cover your `hopCompose` logic (minimum `400_000`)
- [ ] Test with `_data.length == 0` (no compose) and `_data.length > 0` paths

### For Vault Integration

- [ ] Verify `RemoteVaultHop.remoteVaultHops(vaultChainEid) != address(0)`
- [ ] Use `RemoteVaultDeposit.quote(amount)` for round-trip fee (not `hop.quote()`)
- [ ] Approve `ASSET` (frxUSD) to the `RemoteVaultDeposit` address, not `RemoteVaultHop`
- [ ] Be aware of PPS interpolation: price smooths over 100 blocks after each update

### For Admin Operations via RemoteAdmin

- [ ] Caller must be the registered `fraxtalMsig`
- [ ] OFT must be `frxUsdOft` (even for non-token admin calls, 1 wei of frxUSD is sent)
- [ ] `DEFAULT_ADMIN_ROLE` must be granted to `RemoteAdmin` on the target contract
- [ ] `pauseOff` requires direct call — cannot go through `RemoteAdmin` (admin-role only)
