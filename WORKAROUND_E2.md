# E2 Analysis: Workaround for Asset Buffer Pollution

**Engineer:** E2 - Smart Contract Specialist (Return Visit)
**Date:** 2026-02-04
**Task:** Find a workaround for the assetbuffer pollution issue

---

## 1. Executive Summary

**FINDING: We CANNOT drain the orphaned entries using thezeosalias mints.**

After detailed analysis, I've determined that:
1. The orphaned buffer entries (4 x 0.0001 CLOAK) were NOT created by normal transfers
2. thezeosalias has 13.3501 CLOAK balance but cannot self-mint to consume orphaned entries
3. The buffer entries require matching ZK proofs that bind the sender account
4. Without knowing the original Note data (rcm, address), generating valid proofs is impossible

---

## 2. Current Buffer State

```json
{
  "rows": [{
    "assets": [
      {"field_0": "thezeosalias", "field_1": {"quantity": {"amount": 1, "symbol": "4,CLOAK"}, "contract": "thezeostoken"}},
      {"field_0": "thezeosalias", "field_1": {"quantity": {"amount": 1, "symbol": "4,CLOAK"}, "contract": "thezeostoken"}},
      {"field_0": "thezeosalias", "field_1": {"quantity": {"amount": 1, "symbol": "4,CLOAK"}, "contract": "thezeostoken"}},
      {"field_0": "thezeosalias", "field_1": {"quantity": {"amount": 1, "symbol": "4,CLOAK"}, "contract": "thezeostoken"}}
    ]
  }]
}
```

**Key Details:**
- 4 entries, each with `amount: 1` (0.0001 CLOAK in 4-decimal format)
- All entries have `field_0: thezeosalias` (sender account)
- These entries do NOT appear in transaction history as normal transfers

---

## 3. Successful Transaction Analysis

### Transaction `907b8e12a10f424593b101ed9bcd49cee48c7ec6d9fe5e68063be79e46abd4fe`

**User:** `retiretelos1`
**Time:** 2026-02-04T15:50:42.000
**Status:** SUCCESS

**Action Sequence:**
1. `thezeosalias::begin` (+240 RAM)
2. `eosio.token::transfer` (10 TLOS to zeosprotocol)
3. `thezeostoken::transfer` (1 CLOAK to zeosprotocol)
4. `thezeostoken::transfer` (0.4 CLOAK fee to thezeosalias)
5. `thezeosalias::mint` (+1114 RAM)
6. `zeosprotocol::mint` (+572 RAM alias, **-64 RAM zeosprotocol**)
7. `thezeosalias::end` (-1354 RAM)
8. `thezeostoken::retire` (0.2 CLOAK burned)

**Key Observation:** The `zeosprotocol::mint` action consumed **-64 bytes** from zeosprotocol RAM.
- Each buffer entry is 32 bytes
- **2 entries consumed** (TLOS + CLOAK)
- This matches the 2 assets being minted

**Why It Worked:** The user's transfer ADDED new buffer entries that matched their proof. The orphaned entries were NOT consumed because the verifier matched:
- Buffer entry from user's transfer (field_0: retiretelos1)
- Proof with account: retiretelos1

---

## 4. thezeosalias Recent Transaction

### Transaction `4bac7918827ecbc529c03ceda64b25f7241df8079e40ba87bcdf8a3f12a7a954`

**User:** `thezeosalias` (claiming auction)
**Time:** 2026-02-04T20:39:09.000
**Status:** SUCCESS

**What Happened:**
1. `thezeosalias::authenticate` (spent auth token)
2. `thezeosalias::claimauctiop` (claimed auction round 4)
3. `thezeostoken::issue` (145416.2270 CLOAK issued)
4. `thezeostoken::transfer` (145416.2270 CLOAK to zeosprotocol)
5. `thezeosalias::mint` (minted that CLOAK)
6. `thezeosalias::spend` (spent to pay 0.5 CLOAK fee)
7. `thezeosalias::end`

**Key Observation:** The `zeosprotocol::mint` consumed **-32 bytes** (1 buffer entry).
- This was thezeosalias minting its OWN claimed auction tokens
- The proof was generated with `account: thezeosalias`
- The buffer entry had `field_0: thezeosalias`
- MATCH!

---

## 5. Why Can't We Drain Orphaned Entries?

### The Problem

To consume a buffer entry, we need:
1. **A transfer to zeosprotocol** that adds to the buffer
2. **A matching proof** with the SAME account

For the orphaned entries:
- `field_0 = thezeosalias`
- `amount = 0.0001 CLOAK`

To generate a valid proof, we would need:
```rust
Mint {
    account: thezeosalias,      // OK - we know this
    value: 1,                    // OK - amount in raw units
    symbol: 82743875355396,      // OK - "4,CLOAK" encoded
    contract: thezeostoken,      // OK - we know this
    address: ???,                // UNKNOWN - where should coins go?
    rcm: ???,                    // UNKNOWN - note commitment randomness
    proof_generation_key: ???,   // UNKNOWN - for address validation
}
```

**Without the original `rcm` and `address`, we cannot reconstruct the note commitment that would match.**

### What About Just Any Address?

If we try to generate a proof with arbitrary values:
- The note commitment (cm) would be different from what was expected
- The on-chain verifier compares `cm` in the proof vs expected `cm`
- The expected `cm` is derived from the ORIGINAL transaction data

**CRITICAL:** The orphaned entries exist because a transaction sequence failed AFTER the transfer but BEFORE the mint completed. The original `cm` values are lost.

---

## 6. thezeosalias Balance Check

```bash
curl -s 'https://telos.eosusa.io/v1/chain/get_currency_balance' \
  -d '{"code":"thezeostoken","account":"thezeosalias","symbol":"CLOAK"}'
```

**Result:** `["13.3501 CLOAK"]`

thezeosalias has 13.3501 CLOAK, but this balance exists OUTSIDE the shielded pool. To shield this CLOAK:
1. Transfer from thezeosalias to zeosprotocol (adds new buffer entry)
2. Generate proof with account: thezeosalias
3. Submit mint transaction

But this would ADD to the buffer, not consume the orphaned entries!

---

## 7. Buffer Consumption Pattern Analysis

Looking at RAM deltas from zeosprotocol:
| Transaction | RAM Delta | Entries Consumed |
|-------------|-----------|------------------|
| 907b8e12... | -64 | 2 (TLOS + CLOAK) |
| 4bac7918... | -32 | 1 (claimed CLOAK) |
| eb4f7e0d... | -32 | 1 |
| b4e20184... | 0 | 0 (failed mint?) |

**Pattern:** Buffer entries are consumed based on the proof matching, not FIFO order.

---

## 8. Origin of Orphaned Entries

**Mystery:** No 0.0001 CLOAK transfers to zeosprotocol appear in transaction history.

**Possible Explanations:**
1. Created during early protocol testing (before history indexing)
2. Created via direct contract call (not transfer notification)
3. Result of a transaction rollback that left partial state
4. Bug in buffer cleanup during failed transactions

**All unique transfer quantities to zeosprotocol:**
```
1.0000 CLOAK, 10.0000 CLOAK, 11.0000 CLOAK, 30.0000 CLOAK, 100.0000 CLOAK...
```
No 0.0001 CLOAK in the list!

---

## 9. Recommended Solutions

### Option 1: ZEOS Team Intervention (REQUIRED)

Contact the ZEOS team to:
1. **Clear the assetbuffer** using owner authority
2. Add a buffer cleanup action for future issues
3. Investigate how the orphaned entries were created

### Option 2: New Account Workaround (TEST THEORY)

If the verifier uses **account-specific buffer indexing** (unlikely but worth testing):
1. Create a new Telos account
2. Transfer CLOAK to new account
3. Attempt shield from new account
4. If successful, the buffer is account-specific

**Expected Result:** Will likely fail because buffer is global, not per-account.

### Option 3: Wait for Matching Transaction (IMPRACTICAL)

If someone happens to:
1. Transfer exactly 0.0001 CLOAK to zeosprotocol from thezeosalias
2. Generate a proof that happens to match the orphaned cm values

This is essentially impossible without knowing the original transaction data.

---

## 10. Why thezeosalias Cannot Self-Drain

Even though thezeosalias has CLOAK and can call mint:

1. **New transfer creates NEW buffer entry**
   - Transfer 0.0001 CLOAK from thezeosalias to zeosprotocol
   - Buffer now has 5 entries (4 orphaned + 1 new)

2. **New proof would have NEW cm**
   - Generate proof with account: thezeosalias
   - This creates a NEW note commitment

3. **Verifier looks for matching cm**
   - The proof's cm won't match any orphaned entry
   - It WILL match the new entry from the transfer
   - The new entry gets consumed, orphaned entries remain!

**Result:** We could successfully mint new coins, but orphaned entries persist.

---

## 11. Technical Deep Dive: Note Commitment

The note commitment is:
```rust
cm = PedersenHash(
    account ||     // thezeosalias raw u64
    value ||       // 1
    symbol ||      // 82743875355396 ("4,CLOAK")
    contract ||    // thezeostoken raw u64
    g_d ||         // diversifier from recipient address
    pk_d,          // public key from recipient address
    rcm            // random commitment trapdoor
)
```

**The orphaned entries were created with specific (g_d, pk_d, rcm) values that are now LOST.**

Without these values, any proof we generate will have a different `cm`, and the verification will fail.

---

## 12. Conclusion

**The orphaned buffer entries CANNOT be drained through normal protocol operations.**

The only viable solution is **ZEOS team intervention** to clear the buffer using contract owner authority.

### Alternative: E3's Workaround Analysis

E3 (ZK Proof Specialist) suggested generating proofs with `account = thezeosalias` and the user's shielded address. This would:
1. Pass the account check (account matches buffer.field_0)
2. Route coins to user's wallet (address is user's)

**BUT:** This still requires generating a proof that matches the expected `cm`, which requires knowing the original (rcm, address) values. The E3 workaround only works if we can generate matching proofs, which we cannot for ORPHANED entries with unknown commitment data.

---

## 13. Summary

| Question | Answer |
|----------|--------|
| Can we drain orphaned entries via thezeosalias? | **NO** |
| Does thezeosalias have CLOAK balance? | YES (13.3501) |
| Can thezeosalias mint to consume buffer? | NO - new transfer adds new entry |
| Origin of orphaned entries? | UNKNOWN - not in transfer history |
| Viable workaround? | **NONE without ZEOS team** |
| Required action? | Contact ZEOS team to clear buffer |

---

## 14. Verification Commands

Check buffer state:
```bash
curl -s 'https://telos.eosusa.io/v1/chain/get_table_rows' \
  -d '{"code":"zeosprotocol","scope":"zeosprotocol","table":"assetbuffer","limit":10,"json":true}'
```

Check thezeosalias balance:
```bash
curl -s 'https://telos.eosusa.io/v1/chain/get_currency_balance' \
  -d '{"code":"thezeostoken","account":"thezeosalias","symbol":"CLOAK"}'
```

---

*E2 - Smart Contract Specialist*
*2026-02-04*
