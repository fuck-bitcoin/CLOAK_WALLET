# E3 (ZK Proof Specialist) - Workaround Analysis for Asset Buffer Pollution

**Date:** 2026-02-04
**Status:** WORKAROUND FOUND - Theoretically Feasible but with Critical Caveats

---

## Executive Summary

After analyzing the ZK circuit and buffer consumption mechanism, I have identified a **theoretically possible workaround** to clear the orphaned buffer entries. However, it requires specific conditions and coordination.

---

## Current Buffer State (Verified)

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

**Key observation:** Each entry has:
- `field_0`: `thezeosalias` (the account that "sent" the tokens)
- `amount`: 1 (which is 0.0001 CLOAK with 4 decimals)

---

## Question 1: Can We Generate a Proof for `thezeosalias`?

**ANSWER: YES, but with a critical limitation.**

The Mint circuit public inputs are:
1. `cm` - Note commitment (depends on account, value, symbol, contract, address, rcm)
2. `inputs2` - Packed (value, symbol, contract)
3. `inputs3` - Account (or auth_hash for auth tokens)

From `zeos-caterpillar/src/circuit/mint.rs` (lines 70-72):
```rust
// append inputs bits (account, value, symbol, contract) to note preimage
note_preimage.extend(account_bits.clone());
note_preimage.extend(inputs2_bits.clone());
```

The `account` is:
1. Included in the note commitment hash
2. Exposed as a public input (inputs3)

**To generate a valid proof for `thezeosalias`:**
1. Create a Note with `account = thezeosalias`
2. Generate proof with `account = thezeosalias.raw()` as circuit input
3. The proof would be mathematically valid

**The limitation:** The note commitment will be different because account is part of the commitment hash.

---

## Question 2: What Would Happen If We Did 4 Mints Using `thezeosalias`?

**ANSWER: It COULD work, but requires the tokens to actually come from `thezeosalias`.**

### The Shield Flow

1. **Transfer:** User transfers tokens TO `zeosprotocol` with memo "ZEOS transfer & mint"
2. **Buffer Population:** `zeosprotocol` records `{field_0: sender, field_1: asset}` in `assetbuffer`
3. **Mint Action:** `thezeosalias::mint` verifies proof against buffer entry
4. **Verification:** Contract reads `field_0` from buffer as expected account

### The Critical Issue

The orphaned entries have `field_0: thezeosalias`. This means:
- The tokens were transferred FROM `thezeosalias` TO `zeosprotocol`
- The proof must be generated with `account = thezeosalias`

**If someone with `thezeosalias` private key could:**
1. Generate a proof with `account = thezeosalias`
2. Mint to consume each orphaned entry

**But wait** - there's a problem. The orphaned entries likely represent tokens that were ALREADY transferred to zeosprotocol. The 0.0001 CLOAK is sitting in the protocol's buffer, not waiting to be transferred.

---

## Question 3: Would This Consume the Orphaned Entries?

**ANSWER: YES, if the proof is valid for `thezeosalias`.**

The buffer consumption happens in the `mint` action:
```
1. zeosprotocol reads assetbuffer[i].field_0 -> expected_account
2. zeosprotocol verifies proof against public inputs including expected_account
3. If valid, buffer entry is consumed
```

**Important:** The buffer entries appear to be consumed in order (FIFO based on the array structure).

---

## Question 4: Is There Any Way to Specify WHICH Buffer Entry to Consume?

**ANSWER: NOT from the Rust code perspective.**

From my analysis of `zeos-caterpillar/src/transaction.rs`:
- The `PlsMint` struct contains: `cm, value, symbol, contract, proof`
- There is NO index or selector to specify which buffer entry

The on-chain contract appears to iterate through buffer entries. The exact mechanism (FIFO, matching, etc.) is in the C++ contract code on-chain.

**Based on the error behavior:** It seems the contract reads entries sequentially, which is why orphaned entries at the front block new mints.

---

## Question 5: Buffer Consumption Analysis from Rust Code

From `zeos-caterpillar/src/transaction.rs` (lines 1064-1084):

```rust
mints.push(PlsMint{
    cm: crate::contract::ScalarBytes(data.note.commitment().to_bytes()),
    value: data.note.amount(),
    symbol: data.note.symbol().raw(),
    contract: data.note.contract().clone(),
    proof: {
        let instance = Mint {
            account: Some(data.note.account().raw()),  // <-- KEY: account from note
            // ...
        };
        let proof = create_random_proof(instance, mint_params, &mut OsRng)?;
        AffineProofBytesLE::try_from(proof)?
    }
});
```

The proof is generated for whatever `account` is in the `note`. The on-chain verification expects this to match `assetbuffer[i].field_0`.

---

## Viable Workaround Strategy

### Option A: Use `thezeosalias` Private Key (RECOMMENDED if available)

The `thezeosalias@public` key is: `5KUxZHKVvF3mzHbCRAHCPJd4nLBewjnxHkDkG8LzVggX4GtnHn6`

**Steps:**
1. Generate 4 ZK proofs with `account = thezeosalias`
2. Each proof should be for 0.0001 CLOAK (matching buffer entries)
3. Execute 4 mint transactions to consume all orphaned entries
4. The shielded notes would go to any address (even the ZEOS team's)

**Transaction structure:**
```json
{
  "zactions": [{
    "name": "mint",
    "data": {
      "to": "<any_zaddress>",
      "contract": "thezeostoken",
      "quantity": "0.0001 CLOAK",
      "memo": "",
      "from": "thezeosalias",  // <-- CRITICAL: must be thezeosalias
      "publish_note": true
    }
  }]
}
```

**Important:** This transaction would NOT need a new transfer action because the tokens are ALREADY in the buffer.

### Option B: Admin Clear Action

If `zeosprotocol` has an admin action to clear the buffer, that would be simpler.

### Option C: Wait for Buffer Timeout

If the protocol has buffer entry expiration, wait for entries to expire.

---

## Technical Deep Dive: Why This Workaround Should Work

### The Circuit Constraint

From `mint.rs` lines 250-261:
```rust
// inputs3 is either (account) or (auth_hash)
let (mut inputs3_bits, _) = conditionally_swap_u256(
    cs.namespace(|| "conditional swap of auth_hash_bits"),
    &account_zero_bits,
    &auth_hash_bits,
    &auth_bit,
)?;
inputs3_bits.truncate(254);
multipack::pack_into_inputs(cs.namespace(|| "pack inputs3 contents"), &inputs3_bits)?;
```

For regular FT mints (not auth tokens), `inputs3 = account`. The verifier reconstructs this from `assetbuffer.field_0`.

### Proof Generation Independence

The ZK proof can be generated by ANYONE - the circuit doesn't verify who generates the proof. It only verifies:
1. The prover knows a valid note with the specified account, value, symbol, contract
2. The commitment matches the note contents
3. The public inputs match

### The Buffer Match Requirement

The on-chain contract reads `field_0` from buffer and expects the proof to be for that account. If we generate a proof for `thezeosalias` and the buffer has `field_0 = thezeosalias`, verification succeeds.

---

## Critical Caveats

### 1. No New Transfer Needed
The orphaned buffer entries represent tokens that were ALREADY transferred to `zeosprotocol`. A mint-only transaction (without transfer) should work if the buffer already has the entry.

### 2. Transaction Must Skip Transfer Action
Normal shield transactions have:
1. `begin`
2. `transfer` (user -> zeosprotocol)
3. `fee` (optional)
4. `mint`
5. `end`

For clearing orphaned entries, we might need:
1. `begin`
2. `mint` (4x, one per entry)
3. `end`

### 3. Who Gets the Shielded Notes?
The minted notes would go to whatever address is specified in `to`. The ZEOS team could mint them to themselves.

### 4. Order Matters
If buffer consumption is FIFO, we must consume all 4 orphaned entries before any user transaction can succeed.

---

## Recommended Action Plan

### Immediate (ZEOS Team)

1. **Generate 4 Mint Proofs:**
   ```
   account = thezeosalias
   value = 1 (0.0001 CLOAK)
   symbol = 82743875355396 ("4,CLOAK")
   contract = thezeostoken
   to = <ZEOS team's shielded address>
   ```

2. **Execute Transaction:**
   - Skip transfer (tokens already in buffer)
   - Include 4 PlsMint actions
   - Each proof for thezeosalias + 0.0001 CLOAK

3. **Verify Buffer Cleared:**
   ```bash
   curl -s 'https://telos.eosusa.io/v1/chain/get_table_rows' \
     -d '{"code":"zeosprotocol","scope":"zeosprotocol","table":"assetbuffer","limit":10}'
   ```

### Alternative: Admin Intervention

If the zeosprotocol contract has an admin clear function:
```
cleos push action zeosprotocol clearbuffer '[]' -p zeosprotocol@active
```

---

## Conclusion

**A workaround IS technically feasible.** The orphaned buffer entries can be cleared by generating valid ZK proofs for `thezeosalias` (matching the `field_0` in each entry) and executing mint actions without the transfer step.

**Key Insight:** The ZK proof doesn't care WHO generates it - only that it's mathematically valid for the specified public inputs. Since the buffer already has `thezeosalias` entries, we need proofs that satisfy `account = thezeosalias`.

**Recommended Contact:** The ZEOS team should be able to execute this workaround since they control the `thezeosalias` account and can generate the necessary proofs.

---

*E3 - ZK Proof Specialist*
*Engineering Roundtable 2026-02-04*
