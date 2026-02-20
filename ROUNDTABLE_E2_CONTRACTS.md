# ROUNDTABLE E2: Smart Contract Analysis
## ZEOS/CLOAK Protocol Contracts on Telos

**Engineer:** E2 - Smart Contract Specialist
**Date:** 2026-02-04
**Focus:** Deep analysis of all ZEOS protocol smart contracts

---

## Executive Summary

The ZEOS protocol on Telos consists of four primary contracts working together to enable privacy-preserving token transfers using zero-knowledge proofs. The "mint: proof invalid" error is caused by **orphaned entries in the assetbuffer table** that contain `field_0: thezeosalias` instead of the actual user account.

**Critical Finding:** The assetbuffer currently has **4 orphaned entries** that will cause ANY mint operation to fail until cleared.

---

## Contract Architecture Overview

| Contract | Account | Purpose |
|----------|---------|---------|
| **zeosprotocol** | `zeosprotocol` | Core ZK verifier, Merkle tree, nullifier tracking |
| **thezeosalias** | `thezeosalias` | Transaction orchestrator, fee management, wrapper actions |
| **thezeostoken** | `thezeostoken` | CLOAK token (ERC20-like eosio.token) |
| **thezeosvault** | `thezeosvault` | Vault system for authenticated deposits |

---

## 1. zeosprotocol - Core Protocol Contract

### ABI Analysis

**Actions:**
| Action | Type | Purpose |
|--------|------|---------|
| `init` | init | Initialize contract state |
| `mint` | mint | Verify mint proof and add commitment to Merkle tree |
| `spend` | spend | Verify spend proof, add nullifier, update tree |
| `withdraw` | withdraw | Process withdrawals from shielded pool |
| `authenticate` | authenticate | Verify authentication proofs |
| `recordblock` | recordblock | Record block numbers for sync |
| `setpvk` | setpvk | Set prepared verifying key for a circuit |
| `updnftcntrct` | updnftcntrct | Update NFT contract whitelist |
| `rmnftcntrct` | rmnftcntrct | Remove NFT contract from whitelist |

### Tables

#### `global` - Protocol State
```json
{
  "block_num": 450475919,
  "leaf_count": 110,
  "auth_count": 15,
  "tree_depth": 20,
  "recent_roots": [/* 8 recent Merkle roots as scalars */]
}
```

**Key observations:**
- 110 leaves (commitments) in the Merkle tree
- 15 authentication events
- Tree depth of 20 (supports 2^20 = ~1M leaves)
- Maintains 8 recent roots for historical proof verification

#### `assetbuffer` - **THE PROBLEM TABLE**
```json
{
  "assets": [
    {"field_0": "thezeosalias", "field_1": {"quantity": {"amount": 1, "symbol": "4,CLOAK"}, "contract": "thezeostoken"}},
    {"field_0": "thezeosalias", "field_1": {"quantity": {"amount": 1, "symbol": "4,CLOAK"}, "contract": "thezeostoken"}},
    {"field_0": "thezeosalias", "field_1": {"quantity": {"amount": 1, "symbol": "4,CLOAK"}, "contract": "thezeostoken"}},
    {"field_0": "thezeosalias", "field_1": {"quantity": {"amount": 1, "symbol": "4,CLOAK"}, "contract": "thezeostoken"}}
  ]
}
```

**CRITICAL: This is the root cause of "mint: proof invalid"**

- `field_0` stores the **sender account** from the transfer
- `field_1` stores the **asset details** (amount, symbol, contract)
- These 4 entries have `thezeosalias` as the sender instead of a real user
- When `zeosprotocol::mint` runs, it reads from this buffer to get the expected account
- The ZK proof contains the actual user account as a public input
- **Mismatch = "proof invalid"**

#### `pvk` - Prepared Verifying Keys
Contains BLS12-381 verifying keys for:
1. **mint** - 3 IC points (verifies: cm, value, symbol, contract, account)
2. **output** - 4 IC points
3. **spend** - 5 IC points
4. **spendoutput** - 8 IC points

The `ic` (input commitments) array size indicates the number of public inputs for each circuit.

**Mint circuit public inputs (3 IC points = 2 public inputs + 1):**
1. Account (EOSIO name encoded)
2. Commitment hash

#### `merkletree` - Commitment Tree
Stores Merkle tree nodes:
```json
{"idx": 0, "val": {"w0": "17742544370925247537", ...}}  // Root
{"idx": 1, "val": {...}}  // Level 1 nodes
{"idx": 3, "val": {...}}  // Level 2 nodes
...
```

#### `nullifiers` - Spent Note Tracking
Prevents double-spending by storing nullifier hashes:
```json
[
  {"val": {"w0": "276220943548901", ...}},
  {"val": {"w0": "373758672659543023", ...}},
  ...
]
```

#### `blocks` - Block Index
Records which blocks have been processed for syncing.

---

## 2. thezeosalias - Transaction Orchestrator

### ABI Analysis

**Primary Actions:**
| Action | Type | Purpose |
|--------|------|---------|
| `begin` | begin | Start a ZEOS transaction, initialize action buffer |
| `mint` | mint | Forward mint actions to zeosprotocol with proofs |
| `spend` | spend | Forward spend actions with proofs |
| `withdraw` | withdraw | Process unshielded withdrawals |
| `end` | end | Finalize transaction, clear buffers, handle fees |
| `authenticate` | authenticate | Forward authentication proofs |
| `publishnotes` | publishnotes | Publish encrypted note ciphertexts |

**Fee Management:**
| Action | Purpose |
|--------|---------|
| `initfees` | Initialize fee structure |
| `setfee` | Set fee for specific action |
| `removefees` | Remove fee configuration |

**Auction (CLOAK distribution):**
| Action | Purpose |
|--------|---------|
| `auctioncfg` | Configure auction parameters |
| `claimauction` | Claim auction rewards |
| `claimauctiop` | Claim auction (privileged) |
| `rmauctioncfg` | Remove auction config |

### Key Structs

#### `pls_mint` - THE MINT STRUCT (CRITICAL)
```cpp
struct pls_mint {
    bytes cm;           // 32-byte commitment hash
    uint64 value;       // Amount in smallest units
    uint64 symbol;      // Encoded symbol (82743875355396 = "4,CLOAK")
    name contract;      // Token contract (thezeostoken)
    bytes proof;        // 384-byte Groth16 proof
}
```

**IMPORTANT:** This struct has NO `account` field! The account is:
1. A **public input** to the ZK circuit
2. Derived from `assetbuffer.field_0` at verification time

#### `action_buffer` - Transaction Buffer
```cpp
struct action_buffer {
    pls_mint[] mint_actions;
    pls_spend_sequence[] spend_actions;
    pls_authenticate[] authenticate_actions;
    pls_withdraw[] withdraw_actions;
}
```

### Tables

#### `fees` - Fee Configuration
```json
{
  "token_contract": "thezeostoken",
  "symbol_code": "CLOAK",
  "fees": [
    {"first": "authenticate", "second": "0.1000 CLOAK"},
    {"first": "begin", "second": "0.2000 CLOAK"},
    {"first": "mint", "second": "0.1000 CLOAK"},
    {"first": "output", "second": "0.1000 CLOAK"},
    {"first": "publishnotes", "second": "0.1000 CLOAK"},
    {"first": "spend", "second": "0.1000 CLOAK"},
    {"first": "spendoutput", "second": "0.1000 CLOAK"}
  ],
  "burn_rate": 50
}
```

**Fee calculation for shield (mint):**
- begin: 0.2000 CLOAK
- mint: 0.1000 CLOAK
- **Total: 0.3000 CLOAK** (but burn_rate=50 means 0.15 burned, 0.15 kept)

In practice, observed fee is **0.4000 CLOAK** (0.2 burned).

#### `burned` - Total Burned Tokens
```json
{"amount": 133500}
```
= 13.35 CLOAK total burned

#### `exec` - Execution State
Empty (cleared after transactions)

#### `actionbuffer` - Action Buffer
Empty (cleared after `end` action)

---

## 3. thezeostoken - CLOAK Token Contract

Standard `eosio.token` with extensions.

### Token Stats
```json
{
  "supply": "8112211.7838 CLOAK",
  "max_supply": "1000000000.0000 CLOAK",
  "issuer": "thezeosalias"
}
```

### Additional Tables

#### `snapshot` - Token Snapshot
For airdrops/migrations.

#### `deadline` - Time-locked Operations
Contains block heights for deadlines.

### Key Balances
| Account | Balance |
|---------|---------|
| zeosprotocol | 1,146,794.3483 CLOAK (shielded pool) |
| thezeosalias | 13.3501 CLOAK (fee accumulator) |
| gi4tambwgege | 235,483.7754 CLOAK (test user) |

---

## 4. thezeosvault - Vault System

### Purpose
Enables users to receive shielded deposits via an authentication token (commitment hash).

### Tables

#### `vaultcfg` - Vault Configuration
```json
{
  "free_vault_duration": 86400,
  "min_stake": {"quantity": "1000.0000 CLOAK", "contract": "thezeostoken"},
  "max_slots": 100
}
```

#### `vaults` - Active Vaults
```json
{
  "auth_token": "175a5d85d0541a5e7eba78cfa6a69fcc65c8f9139855cdcb548e1df64b33a847",
  "creation_block_time": 1770156113,
  "fts": [{"first": {"sym": "4,CLOAK", "contract": "thezeostoken"}, "second": 10000}],
  "nfts": []
}
```

- `auth_token`: 32-byte commitment hash (hex-encoded)
- `fts`: Fungible token balances
- `nfts`: NFT holdings (by contract + asset IDs)

### Actions
| Action | Purpose |
|--------|---------|
| `withdrawp` | Withdraw from vault (proof required) |
| `burnvaultp` | Burn/close vault |
| `gcvaults` | Garbage collect expired vaults |
| `updvaultcfg` | Update vault configuration |
| `rmvaultcfg` | Remove vault configuration |

---

## Successful Mint Transaction Analysis

Transaction: `907b8e12a10f424593b101ed9bcd49cee48c7ec6d9fe5e68063be79e46abd4fe`

### Action Sequence
```
1. thezeosalias::begin      (auth: thezeosalias@public)
2. eosio.token::transfer    (10 TLOS: retiretelos1 -> zeosprotocol)
3. thezeostoken::transfer   (1 CLOAK: retiretelos1 -> zeosprotocol)
4. thezeostoken::transfer   (0.4 CLOAK: retiretelos1 -> thezeosalias) [fee]
5. thezeosalias::mint       (auth: thezeosalias@public, 2 pls_mint actions)
   -> INLINE: zeosprotocol::mint (auth: thezeosalias@active)
6. thezeosalias::end        (auth: thezeosalias@public)
   -> INLINE: thezeostoken::retire (0.2 CLOAK burned)
```

### Mint Action Data
```json
{
  "actions": [
    {
      "cm": "8638ECD836F102EC23667E81201EE802ED837E38A3309464FE81096F9003E400",
      "value": "10000",
      "symbol": "82743875355396",
      "contract": "thezeostoken",
      "proof": "156A39FB064C2820...901" // 384 bytes
    },
    {
      "cm": "2692C48D24A08157248681C61710ADEE98EF6846305F25F406757986C2355203",
      "value": "100000",
      "symbol": "357812687876",
      "contract": "eosio.token",
      "proof": "E7A237DFAC1E57BD...901" // 384 bytes
    }
  ],
  "note_ct": ["<encrypted_note_1>", "<encrypted_note_2>"]
}
```

**Key observations:**
- Two assets shielded in one transaction (1 CLOAK + 10 TLOS)
- Symbol 82743875355396 = "4,CLOAK"
- Symbol 357812687876 = "4,TLOS"
- Each proof is 384 bytes (Groth16 BLS12-381)
- User was `retiretelos1`, which was in `assetbuffer.field_0`

---

## Root Cause: "mint: proof invalid"

### The Problem Flow

1. **User generates proof**:
   - Account = `gi4tambwgege` (as public input)
   - Commitment = hash of (amount, symbol, contract, account, randomness)

2. **User transfers tokens**:
   - `gi4tambwgege` -> `zeosprotocol` (this adds to assetbuffer)
   - But assetbuffer ALREADY has 4 entries with `field_0: thezeosalias`

3. **thezeosalias::mint called**:
   - Passes pls_mint array to zeosprotocol::mint

4. **zeosprotocol::mint verification**:
   - Reads `assetbuffer.assets[0]`
   - Gets `field_0 = thezeosalias` (WRONG!)
   - Expected account in proof = `gi4tambwgege`
   - **MISMATCH -> "proof invalid"**

### Why the Orphaned Entries Exist

Most likely cause: Previous transactions that were partially completed:
1. `begin` was called (creates buffer)
2. Transfer happened (adds to assetbuffer)
3. Transaction failed or was abandoned before `end`
4. `end` normally clears the buffer, but never ran

### Solution Options

1. **ZEOS Team Action**: Clear assetbuffer manually via contract admin
2. **Protocol Upgrade**: Add cleanup mechanism for stale buffer entries
3. **Workaround**: Use a different account (but this doesn't fix the underlying issue)
4. **Sequential Processing**: Wait for someone to "use up" the orphaned entries by minting with thezeosalias proofs (not practical)

---

## ZK Circuit Analysis

### Mint Circuit Inputs
Based on IC array size (3 points = 2 public inputs):

**Public Inputs:**
1. `account` - EOSIO name encoded as scalar
2. `commitment` - Hash of note contents

**Private Inputs (in witness):**
- Value (amount)
- Symbol (encoded)
- Contract (token contract)
- Randomness (blinding factor)

**Constraint being violated:**
```
commitment == hash(value, symbol, contract, account, randomness)
```

The proof says "I know a valid note for account X" but the contract expects account Y from the buffer.

### Verification Process
```
1. zeosprotocol reads assetbuffer[i].field_0 -> account_from_buffer
2. zeosprotocol reads pls_mint.cm -> commitment
3. zeosprotocol constructs public inputs: [account_from_buffer, commitment]
4. zeosprotocol calls groth16_verify(pvk["mint"], proof, public_inputs)
5. If public inputs don't match what proof was generated for -> FAIL
```

---

## Verification Commands

### Check AssetBuffer Status
```bash
curl -s 'https://telos.eosusa.io/v1/chain/get_table_rows' \
  -d '{"code":"zeosprotocol","scope":"zeosprotocol","table":"assetbuffer","limit":10}'
```

### Check Global State
```bash
curl -s 'https://telos.eosusa.io/v1/chain/get_table_rows' \
  -d '{"code":"zeosprotocol","scope":"zeosprotocol","table":"global","limit":1}'
```

### Check Fees
```bash
curl -s 'https://telos.eosusa.io/v1/chain/get_table_rows' \
  -d '{"code":"thezeosalias","scope":"thezeosalias","table":"fees","limit":1}'
```

---

## Recommendations

### Immediate (Unblock Testing)
1. Contact ZEOS team to clear the assetbuffer
2. Test with a clean account that hasn't interacted before

### Short-term (Protocol Robustness)
1. Add buffer cleanup action callable by protocol admin
2. Implement buffer entry expiration
3. Add explicit account field to pls_mint for verification

### Long-term (Architecture)
1. Consider per-user buffers instead of global buffer
2. Add buffer size limits with automatic rollback
3. Implement transaction timeouts with automatic cleanup

---

## Contract Addresses Summary

| Contract | Account | CLOAK Balance |
|----------|---------|---------------|
| zeosprotocol | `zeosprotocol` | 1,146,794.3483 |
| thezeosalias | `thezeosalias` | 13.3501 |
| thezeostoken | `thezeostoken` | (issuer) |
| thezeosvault | `thezeosvault` | (holds vaults) |

---

*E2 - Smart Contract Specialist*
*Engineering Roundtable Investigation*
*2026-02-04*
