# E3 - ZK Proof Specialist: Proof-Side Workaround Analysis

## Executive Summary

**CRITICAL FINDING: Account and Address are INDEPENDENT in the Mint circuit.**

The `account` field (Telos sender) and `address` field (shielded recipient) are **separate inputs** to the ZK circuit. This means:

1. We CAN generate a proof with `account = thezeosalias`
2. The shielded coins would STILL go to the user's CLOAK wallet (their shielded address)
3. **This is a viable workaround** if certain conditions are met

---

## 1. Mint Circuit Analysis

### Source: `/home/kameron/Projects/CLOAK Wallet/zeos-caterpillar/src/circuit/mint.rs`

```rust
/// This is an instance of the `Mint` circuit.
pub struct Mint
{
    /// The EOSIO account this note is associated with (Mint: sender, Transfer: 0, Burn: receiver, Auth: == contract)
    pub account: Option<u64>,      // <-- Telos account (sender side)
    /// ...
    pub address: Option<Address>,   // <-- Shielded address (recipient side)
    /// ...
}
```

### Key Observations:

1. **`account`**: The EOSIO account name encoded as u64
   - For Mint: This is the **sender** on the Telos side
   - It's used in the note commitment AND exposed as public input (inputs3)

2. **`address`**: The shielded payment address
   - Contains: diversifier (g_d) + public key (pk_d)
   - This is where the coins **actually go** in the shielded pool
   - The recipient with the corresponding viewing key can decrypt and spend

3. **These are INDEPENDENT fields!**

---

## 2. Note Commitment Structure

### Source: `/home/kameron/Projects/CLOAK Wallet/zeos-caterpillar/src/note/commitment.rs`

```rust
pub fn derive(
    g_d: [u8; 32],     // from address.diversifier
    pk_d: [u8; 32],    // from address.pk_d
    account: u64,       // EOSIO account
    value: u64,
    symbol: u64,
    code: u64,
    rcm: NoteCommitTrapdoor,
) -> Self
```

The note commitment is a Pedersen hash of:
```
commitment = PedersenHash(account || value || symbol || contract || g_d || pk_d, rcm)
```

**CRITICAL**: Both `account` AND `address` are bound into the commitment, but they serve different purposes:
- `account`: Links to Telos identity (for verification)
- `address` (g_d, pk_d): Determines who can **spend** the note

---

## 3. Public Inputs in Mint Proof

The Mint circuit exposes 4 public inputs:
1. `ONE` (constant)
2. `commitment` (note commitment)
3. `inputs2` = pack(value || symbol || contract)
4. `inputs3` = pack(account || 0 || 0 || 0) for fungible tokens

The on-chain verifier reconstructs `inputs3` from `assetbuffer.field_0` and compares.

---

## 4. Can We Generate a Proof for `thezeosalias`?

### Requirements Analysis:

| Requirement | Status | Notes |
|-------------|--------|-------|
| Know the account name | YES | `thezeosalias` is public |
| Control thezeosalias account | **NO** | But `thezeosalias@public` key IS public! |
| Have shielded address | YES | User's CLOAK wallet address |
| Have proof generation key | YES | User's key (for address validation) |

### The Trick:

The `thezeosalias@public` permission has a **publicly known private key**:
```
Private Key: 5KUxZHKVvF3mzHbCRAHCPJd4nLBewjnxHkDkG8LzVggX4GtnHn6
Public Key:  EOS7ckzf4BMgxjgNSYPo8p8teUbwrj3tPz6qDz7aJNLLbpLkEyFZZ
```

This key is intentionally public - it's used for protocol-level operations that don't require user-specific authorization.

---

## 5. Proposed Workaround

### If we generate a proof with:
- `account = thezeosalias` (u64 encoding)
- `address = user's CLOAK shielded address`
- All other fields (value, symbol, contract) matching the orphaned buffer entry

### Then:
1. The proof will verify because `account` matches `assetbuffer.field_0`
2. The note commitment will include `thezeosalias` as the account
3. **BUT** the shielded coins go to the user's address (g_d, pk_d)
4. Only the user can decrypt and spend the coins!

### Note Structure:
```
Note {
    account: thezeosalias,           // Matches buffer - proof verifies
    address: user_cloak_address,      // User receives coins
    value: 1,
    symbol: 4,CLOAK,
    contract: thezeostoken
}
```

---

## 6. Implementation Feasibility

### What's Needed:

1. **Modify proof generation** to use `thezeosalias` account instead of user's account
2. **Keep user's shielded address** as recipient
3. **Match exact asset details** from orphaned buffer entry

### Code Location:
`/home/kameron/Projects/CLOAK Wallet/zeos-caterpillar/src/transaction.rs` line 1064-1084

Current code:
```rust
mints.push(PlsMint{
    // ...
    proof: {
        let instance = Mint {
            account: Some(data.note.account().raw()),  // <-- Change this
            // ...
            address: Some(data.note.address()),        // <-- Keep user's address
        };
        // ...
    }
});
```

### Modified approach:
```rust
// For orphaned buffer recovery:
let instance = Mint {
    account: Some(Name::from_string(&"thezeosalias").unwrap().raw()),
    address: Some(user_shielded_address),  // User's actual address
    // ... rest same
};
```

---

## 7. Critical Questions Answered

### Q1: Can we generate a proof for thezeosalias?
**YES** - We only need to know the account name (encoded as u64), which is public.

### Q2: Does the user need to control thezeosalias?
**NO** - The proof generation doesn't require controlling the account. The `account` field is just data that goes into the note commitment and is exposed as a public input.

### Q3: Would coins still go to user's CLOAK wallet?
**YES!** - The `address` field (containing g_d and pk_d) determines the recipient. The `account` is just metadata linking to the Telos sender identity.

### Q4: Is thezeosalias@public sufficient?
**NO NEED** - The private key isn't needed for proof generation. We just need to use the account NAME in the proof.

---

## 8. Security Implications

### Safe Aspects:
- Coins arrive at user's shielded address (only they can spend)
- No private keys compromised
- Note commitment properly binds all values

### Considerations:
- The note's `account` field will show `thezeosalias` instead of user's account
- This is metadata - doesn't affect ownership
- When user later transfers/burns from this note, their identity is revealed

### Risk Assessment: **LOW**
- User controls the coins (address is theirs)
- `account` is just a label linking to the original transfer
- Since these are orphaned entries from failed txs, the "wrong" account is acceptable

---

## 9. Recommended Approach

### Option A: Manual Recovery (Per-User)
1. Check assetbuffer state
2. If orphaned entries exist with `field_0: thezeosalias`
3. Generate proof with `account = thezeosalias`
4. User's coins arrive in their CLOAK wallet

### Option B: Automated Buffer-Aware Proof Generation
1. Before generating proof, query assetbuffer
2. If buffer has orphaned entries, use their `field_0` value as account
3. Warn user that proof will use different account metadata

### Option C: Clear Buffer First (Preferred)
1. Contact ZEOS team to clear orphaned entries
2. Then normal proof generation works
3. No workaround needed

---

## 10. Implementation Notes

### Name Encoding for `thezeosalias`:
```rust
use crate::eosio::Name;
let thezeosalias_u64 = Name::from_string(&"thezeosalias").unwrap().raw();
// This is the value to use in the Mint circuit's `account` field
```

### Note Creation for Recovery:
```rust
let recovery_note = Note::from_parts(
    0,                                    // header
    user_shielded_address,                // user's CLOAK address
    Name::from_string(&"thezeosalias").unwrap(),  // "wrong" account
    ExtendedAsset::new(
        Asset::new(1, Symbol::from_string(&"4,CLOAK").unwrap()).unwrap(),
        Name::from_string(&"thezeostoken").unwrap()
    ),
    rseed,
    memo
);
```

---

## Summary

| Question | Answer |
|----------|--------|
| Can generate proof for thezeosalias? | **YES** |
| Need to control thezeosalias account? | **NO** |
| Coins go to user's address? | **YES** |
| Account and address independent? | **YES** |
| Viable workaround? | **YES** |
| Risk level | **LOW** |

**Recommended Action:** Implement Option C (clear buffer) as primary solution. Keep Option A/B as fallback for future resilience.

---

## Files Referenced

| File | Lines | Purpose |
|------|-------|---------|
| `/home/kameron/Projects/CLOAK Wallet/zeos-caterpillar/src/circuit/mint.rs` | 1-265 | Mint ZK circuit definition |
| `/home/kameron/Projects/CLOAK Wallet/zeos-caterpillar/src/note/commitment.rs` | 1-95 | Note commitment derivation |
| `/home/kameron/Projects/CLOAK Wallet/zeos-caterpillar/src/note.rs` | 66-132 | Note structure (account vs address) |
| `/home/kameron/Projects/CLOAK Wallet/zeos-caterpillar/src/transaction.rs` | 1064-1084 | Proof generation code |
| `/home/kameron/Projects/CLOAK Wallet/zeos-caterpillar/src/contract.rs` | 340-354 | PlsMint structure |

---

*E3 - ZK Proof Specialist*
*2026-02-04*
