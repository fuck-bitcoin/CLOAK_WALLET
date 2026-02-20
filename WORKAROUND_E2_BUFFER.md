# E2 ANALYSIS: Asset Buffer Read Mechanism During Mint

**Engineer:** E2 - Smart Contract Specialist
**Date:** 2026-02-04
**Task:** Analyze how the buffer is read during mint operations

---

## 1. EXECUTIVE SUMMARY

**CRITICAL FINDING:** There is **NO WAY** to specify which buffer entry the proof corresponds to.

The zeosprotocol mint action has **zero parameters** - it processes the **entire buffer sequentially**, matching each entry with the next proof in the submitted batch. This is a fundamental architectural constraint that makes selective buffer entry consumption impossible.

---

## 2. BUFFER STATE ANALYSIS

### Current assetbuffer Contents (zeosprotocol)
```
4 orphaned entries, ALL with:
  - field_0 (sender account): thezeosalias
  - amount: 0.0001 CLOAK (1 unit at 4 decimals)
  - contract: thezeostoken
```

### Raw Data Analysis
```
Entry Structure: tuple<name, extended_zasset>
  - field_0: name (8 bytes) = sender account from transfer
  - field_1: extended_zasset
    - quantity: zasset (amount: int64 + symbol: uint64 = 16 bytes)
    - contract: name (8 bytes)
Total: 32 bytes per entry
```

Decoded values:
| Entry | field_0 (sender) | Amount | Symbol | Contract |
|-------|------------------|--------|--------|----------|
| 0 | thezeosalias | 1 | 4,CLOAK | thezeostoken |
| 1 | thezeosalias | 1 | 4,CLOAK | thezeostoken |
| 2 | thezeosalias | 1 | 4,CLOAK | thezeostoken |
| 3 | thezeosalias | 1 | 4,CLOAK | thezeostoken |

---

## 3. CONTRACT ARCHITECTURE

### 3.1 zeosprotocol Mint Action (On-Chain Verifier)
```cpp
// From ABI
struct mint {
    // NO FIELDS - ZERO PARAMETERS
};

action mint();  // Takes nothing
```

**The mint action takes NO parameters.** It reads directly from the assetbuffer table.

### 3.2 thezeosalias Mint Action (Alias Contract)
```cpp
struct pls_mint {
    bytes cm;        // Note commitment (32 bytes)
    uint64 value;    // Amount
    uint64 symbol;   // Symbol raw
    name contract;   // Token contract
    bytes proof;     // ZK proof (384 bytes)
};

struct mint {
    pls_mint[] actions;   // Array of mint proofs
    string[] note_ct;     // Encrypted notes
};
```

**No index or position parameter exists in pls_mint.**

---

## 4. PROOF CIRCUIT ANALYSIS

### 4.1 Mint Circuit Public Inputs
From `/home/kameron/Projects/CLOAK Wallet/zeos-caterpillar/src/circuit/mint.rs`:

```rust
pub struct Mint {
    pub account: Option<u64>,       // EOSIO account (sender for mint)
    pub auth_hash: Option<[u64; 4]>, // Auth token hash (zeros for regular mint)
    pub value: Option<u64>,
    pub symbol: Option<u64>,
    pub contract: Option<u64>,
    pub address: Option<Address>,   // Recipient's zk-address
    pub rcm: Option<jubjub::Fr>,    // Note commitment randomness
    pub proof_generation_key: Option<ProofGenerationKey>,
}
```

### 4.2 What the Proof Binds
The ZK proof cryptographically binds:
1. **commitment (cm)** - The note commitment hash
2. **value** - The amount being minted
3. **symbol** - The token symbol
4. **contract** - The token contract
5. **account** - The sender's EOSIO account (OR auth_hash for auth tokens)

**The `account` field IS part of the proof's public inputs (inputs3).**

### 4.3 Proof Creation Code
From `/home/kameron/Projects/CLOAK Wallet/zeos-caterpillar/src/transaction.rs` (line 1064-1084):

```rust
mints.push(PlsMint{
    cm: ScalarBytes(data.note.commitment().to_bytes()),
    value: data.note.amount(),
    symbol: data.note.symbol().raw(),
    contract: data.note.contract().clone(),
    proof: {
        let instance = Mint {
            account: Some(data.note.account().raw()),  // <-- ACCOUNT FROM NOTE
            auth_hash: Some([0; 4]),
            value: Some(data.note.amount()),
            symbol: Some(data.note.symbol().raw()),
            contract: Some(data.note.contract().raw()),
            address: Some(data.note.address()),
            rcm: Some(data.note.rcm()),
            proof_generation_key: Some(pgk.clone()),
        };
        create_random_proof(instance, mint_params, &mut OsRng)?
    }
});
```

**The proof is generated with `data.note.account()` - the user's account.**

---

## 5. THE VERIFICATION PROBLEM

### 5.1 What the Verifier Does (Inferred)
The on-chain verifier must:
1. Pop entries from assetbuffer in FIFO order
2. For each entry, extract: `(sender_account, amount, symbol, contract)`
3. Match against the submitted proof's public inputs
4. Verify: `proof_account == buffer_entry.field_0`

### 5.2 The Mismatch
When gi4tambwgege tries to mint:
- **Proof generated with:** `account = gi4tambwgege (7172425823245473952)`
- **Buffer contains:** `field_0 = thezeosalias (14651886699660676480)`
- **Verifier expects:** proof.account == buffer.field_0
- **Result:** MISMATCH -> "proof invalid"

---

## 6. KEY QUESTION ANSWERED

> **"Is there a way to tell the contract WHICH buffer entry our proof corresponds to?"**

**NO.** The architecture does not support this because:

1. **zeosprotocol::mint()** takes zero parameters
2. **pls_mint** struct has no index/position field
3. **Buffer is processed sequentially** (FIFO)
4. **No skip/select mechanism exists**

---

## 7. POSSIBLE WORKAROUNDS

### 7.1 Clear the Buffer (Requires ZEOS Team)
- Contact ZEOS team to manually clear orphaned entries
- They would need contract owner authority

### 7.2 Generate Proofs for Buffer Entries (Complex)
- Create proofs as `thezeosalias` to consume the 4 entries
- Requires: `thezeosalias` private key + spending key
- The note commitment would differ (wrong recipient)
- **LIKELY IMPOSSIBLE** without ZEOS team help

### 7.3 Transfer from Different Source
- Use a different token source that doesn't go through thezeosalias
- Not applicable - thezeosalias IS the required alias authority

### 7.4 Wait for Buffer to be Consumed
- If the ZEOS team or original sender processes these entries
- No indication this will happen

---

## 8. TECHNICAL DEEP DIVE: Buffer Population

The buffer is populated when tokens are transferred to zeosprotocol:

```
thezeostoken::transfer(from, zeosprotocol, amount, memo)
    -> zeosprotocol::on_transfer(from, amount, symbol, contract)
        -> assetbuffer.emplace(from, {amount, symbol, contract})
```

The `field_0` is set to the **sender of the transfer**, which in our case was `thezeosalias` (likely during testing or a failed transaction sequence).

---

## 9. RECOMMENDATIONS

### Immediate Actions
1. **Contact ZEOS team** to clear the assetbuffer
2. **Document the bug** - buffer should auto-clear on failed transactions

### Long-term Suggestions for Protocol
1. Add buffer entry ID/index to pls_mint struct
2. Allow selective consumption of buffer entries
3. Add timeout mechanism for stale buffer entries
4. Add owner-only buffer clear function

---

## 10. FILES ANALYZED

| File | Purpose |
|------|---------|
| `/home/kameron/Projects/CLOAK Wallet/zeos-caterpillar/src/transaction.rs` | Proof generation, PlsMint creation |
| `/home/kameron/Projects/CLOAK Wallet/zeos-caterpillar/src/contract.rs` | PlsMint struct definition |
| `/home/kameron/Projects/CLOAK Wallet/zeos-caterpillar/src/circuit/mint.rs` | ZK circuit definition |
| `zeosprotocol ABI` | On-chain verifier interface |
| `thezeosalias ABI` | Alias contract interface |

---

## 11. CONCLUSION

The "mint: proof invalid" error is caused by a **fundamental architectural limitation**:
- The proof binds to `gi4tambwgege` (the user's account)
- The buffer contains entries from `thezeosalias`
- The verifier compares these and they don't match
- **There is no mechanism to skip or select buffer entries**

The only solutions require **ZEOS team intervention** to clear the polluted buffer.
