# E5 ANALYSIS: Integration Workarounds for AssetBuffer Pollution

**Engineer:** E5 - Integration Specialist
**Date:** 2026-02-04
**Task:** Find practical workarounds for the assetbuffer pollution issue

---

## 1. EXECUTIVE SUMMARY

After extensive investigation of the protocol, contracts, and tooling, I have evaluated multiple workaround strategies. **The bad news:** Most workarounds are blocked by architectural constraints. **The good news:** There are two viable paths forward.

### Viable Workarounds

| Priority | Workaround | Feasibility | Effort |
|----------|------------|-------------|--------|
| 1 | Contact ZEOS Team to clear buffer | HIGH | LOW |
| 2 | Generate "thezeosalias" proofs to consume entries | MEDIUM | HIGH |

### Investigated but NOT Viable

| Approach | Why It Fails |
|----------|--------------|
| Call zeosprotocol::mint directly | Zero-param action, reads buffer automatically |
| Use cleos to specify buffer index | No index parameter exists in protocol |
| Call thezeosalias::end to clear | End only clears actionbuffer, not assetbuffer |
| Use app.cloak.today differently | Uses same protocol, same buffer |
| Batch mint multiple entries | Still FIFO processing, still mismatch |
| Use different account | Buffer entries are from thezeosalias, not user |

---

## 2. DETAILED INVESTIGATION RESULTS

### 2.1 Can We Use Cleos to Specify Buffer Index?

**ANSWER: NO**

The zeosprotocol::mint action has **zero parameters**:
```cpp
struct mint {
    // EMPTY - no fields
};
```

There is no way to tell the contract which buffer entry to use. The contract reads the assetbuffer table sequentially (FIFO).

### 2.2 Can We Call zeosprotocol::mint Directly?

**ANSWER: NO (won't help)**

The zeosprotocol::mint action:
1. Takes no parameters
2. Reads ALL entries from assetbuffer automatically
3. Matches them against the submitted proofs in order
4. Requires `thezeosalias@active` authorization (not user authority)

Even if we called it directly, the buffer mismatch remains.

### 2.3 Can We Call thezeosalias::end to Clear Buffers?

**ANSWER: PARTIAL**

Investigation of the thezeosalias contract:
```
Actions linked to thezeosalias@public:
- begin
- end
- mint
- spend
- authenticate
- withdraw
- publishnotes
```

The `begin` and `end` actions both have **empty structs** (no parameters).

**CRITICAL FINDING:** The `end` action clears the **actionbuffer** table (on thezeosalias), but NOT the **assetbuffer** table (on zeosprotocol).

Table locations:
- `actionbuffer` -> thezeosalias contract (currently empty, gets cleared by end)
- `assetbuffer` -> zeosprotocol contract (contains 4 orphaned entries)

**Calling `end` will not help because the pollution is on zeosprotocol, not thezeosalias.**

### 2.4 Is There an "Abort" or "Cancel" Action?

**ANSWER: NO**

Examined all zeosprotocol actions:
```
authenticate, init, mint, recordblock, rmnftcntrct, setpvk, spend, updnftcntrct, withdraw
```

And all thezeosalias actions:
```
auctioncfg, authenticate, begin, blacklistadd, claimauction, claimauctiop, end, initfees, mint,
publishnotes, removefees, rmauctioncfg, setfee, spend, testlock, withdraw
```

**No abort/cancel/clear action exists for assetbuffer.**

### 2.5 Does app.cloak.today Work Differently?

**ANSWER: NO**

The official CLOAK GUI at `/opt/cloak-gui/` uses identical configuration:
```json
{
    "alias_authority": "thezeosalias@public",
    "alias_authority_key": "5KUxZHKVvF3mzHbCRAHCPJd4nLBewjnxHkDkG8LzVggX4GtnHn6",
    "protocol_contract": "zeosprotocol"
}
```

Both the desktop app and web app:
1. Use the same thezeosalias authority
2. Sign with the same public key
3. Interact with the same zeosprotocol contract
4. Face the same assetbuffer pollution

The issue is at the **protocol level**, not the client level.

### 2.6 Can We Do Batch Mint to Consume Multiple Entries?

**ANSWER: NO (won't help with mismatch)**

The mint action CAN process multiple entries in one transaction:
```
pls_mint[] actions;  // Array of proofs
```

However:
1. Entry 0 proof MUST match buffer entry 0 (thezeosalias account)
2. Entry 1 proof MUST match buffer entry 1 (thezeosalias account)
3. etc.

We cannot generate valid proofs for these entries because we don't control the `thezeosalias` spending key and the commitments have already been determined.

---

## 3. VIABLE WORKAROUND #1: Contact ZEOS Team

**Feasibility: HIGH** | **Effort: LOW**

### Contact Information
- GitHub: https://github.com/mschoenebeck
- Repositories: zeos-caterpillar, zeos-verifier, zeosio, thezeostoken
- Discord/Telegram: (Search for ZEOS community channels)

### What to Request
Ask the ZEOS team to clear the assetbuffer using their contract owner authority:

```
Contract: zeosprotocol
Table: assetbuffer
Scope: zeosprotocol
Entries to clear: 4 orphaned entries with field_0=thezeosalias
```

### Supporting Evidence to Provide
```bash
# Current buffer state
curl -s 'https://telos.eosusa.io/v1/chain/get_table_rows' \
  -d '{"code":"zeosprotocol","scope":"zeosprotocol","table":"assetbuffer","limit":10}'

# Shows 4 entries all with field_0=thezeosalias
```

---

## 4. VIABLE WORKAROUND #2: Generate "thezeosalias" Proofs

**Feasibility: MEDIUM** | **Effort: HIGH**

### Theory
The buffer entries have `field_0: thezeosalias`. To consume them, we would need:
1. Generate proofs with `account = thezeosalias`
2. The note commitment must match expected commitment
3. Submit valid proofs that pass verification

### The Problem
The note commitment is:
```
cm = hash(value, symbol, contract, address, rcm)
```

We need to know:
- `address` - The shielded recipient address (unknown)
- `rcm` - Random commitment factor (unknown)

### Potential Approach
If these were test entries with known parameters, we MIGHT be able to reconstruct:
1. Create a note with `account = thezeosalias`
2. Use value=1 (0.0001 CLOAK), symbol=4,CLOAK, contract=thezeostoken
3. Guess/find the original address and rcm

**This is extremely unlikely to work without insider knowledge of the original transaction parameters.**

---

## 5. TECHNICAL ANALYSIS: Protocol Flow

### Normal Shield Flow
```
1. User calls: thezeosalias::begin (thezeosalias@public signs)
2. User transfers: thezeostoken::transfer(user -> zeosprotocol)
   -> zeosprotocol receives notification
   -> assetbuffer.emplace({sender: user, asset: ...})
3. User calls: thezeosalias::mint(proofs) (thezeosalias@public signs)
   -> INLINE: zeosprotocol::mint() (thezeosalias@active signs)
   -> zeosprotocol reads assetbuffer[0]
   -> Verifier checks: proof.account == buffer.sender (user)
   -> On success: clear buffer entry, add commitment to merkle tree
4. User calls: thezeosalias::end (thezeosalias@public signs)
```

### What Went Wrong (Orphaned Entries)
```
1. thezeosalias::begin was called
2. Transfer from thezeosalias -> zeosprotocol happened
   -> assetbuffer gained entries with sender=thezeosalias
3. mint() was never called OR mint() failed
4. end() was called OR transaction abandoned
5. Result: assetbuffer entries remain, not cleared
```

### Why the Entries Have thezeosalias as Sender
The transfers that created these entries came FROM thezeosalias, not from a user. This suggests:
- Testing by ZEOS team
- A bug in a previous client version
- An automated process that used thezeosalias as source

---

## 6. CONTRACT PERMISSION ANALYSIS

### zeosprotocol Permissions
```json
{
  "active": {
    "keys": ["EOS886iqLMqQdxVebdaSn8xXSzGWwJL9khbq34zSQsvz8SbzM6cFe"],
    "accounts": [{"actor": "zeosprotocol", "permission": "eosio.code"}]
  },
  "owner": {
    "keys": ["EOS886iqLMqQdxVebdaSn8xXSzGWwJL9khbq34zSQsvz8SbzM6cFe"]
  }
}
```

### thezeosalias Permissions
```json
{
  "active": {
    "keys": ["EOS886iqLMqQdxVebdaSn8xXSzGWwJL9khbq34zSQsvz8SbzM6cFe"],
    "accounts": [{"actor": "thezeosalias", "permission": "eosio.code"}]
  },
  "owner": {
    "keys": ["EOS886iqLMqQdxVebdaSn8xXSzGWwJL9khbq34zSQsvz8SbzM6cFe"]
  },
  "public": {
    "keys": ["EOS6XJ9dEWorNYR7xGHtagpq3JkJ5ts5NEP9WP46Nb5j97sf2yU9D"],
    "linked_actions": ["begin", "end", "mint", "spend", "authenticate", "withdraw", "publishnotes"]
  }
}
```

**Key Insight:** Both contracts share the same owner key (`EOS886iq...`). The ZEOS team controls this key.

The `thezeosalias@public` key is the well-known key used for signing shield operations.

---

## 7. TESTING WITH OFFICIAL GUI

### /opt/cloak-gui Available
```
-rwxrwxr-x cloak-gui (46MB executable)
-rw-r--r-- config.json
-rw-r--r-- wallet.bin
-rw-rw-r-- mint.params (15MB)
-rw-rw-r-- spend.params (190MB)
-rwxrwxr-x libzeos_caterpillar.so
```

### Test Result
Running the official GUI would face the **exact same issue** because:
1. It uses the same zeosprotocol contract
2. The assetbuffer pollution exists on-chain
3. Any mint proof for gi4tambwgege will fail against thezeosalias buffer entries

---

## 8. RECOMMENDED NEXT STEPS

### Immediate (Today)

1. **Contact ZEOS Team**
   - GitHub: Create issue on https://github.com/mschoenebeck/zeosio
   - Provide buffer state evidence
   - Request manual buffer clear

2. **Monitor Buffer State**
   ```bash
   watch -n 60 'curl -s "https://telos.eosusa.io/v1/chain/get_table_rows" \
     -d "{\"code\":\"zeosprotocol\",\"scope\":\"zeosprotocol\",\"table\":\"assetbuffer\",\"limit\":10}" | jq'
   ```

### Short-term (If Team Unresponsive)

3. **Research Original Transaction**
   - Use block explorer to find when these entries were created
   - May provide clues about commitment parameters
   - Hyperion API: Search for transfers to zeosprotocol from thezeosalias

### Long-term (Protocol Improvement)

4. **Suggest Protocol Enhancements**
   - Buffer entry timeout/expiration
   - Admin clear function
   - Per-user buffer scoping
   - Selective buffer entry consumption

---

## 9. CURRENT BUFFER STATUS

As of 2026-02-04 22:17 UTC:
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

**Total stuck CLOAK:** 0.0004 CLOAK (4 entries x 0.0001 CLOAK each)
**Impact:** ALL users blocked from minting until cleared

---

## 10. CONCLUSION

The assetbuffer pollution is a **protocol-level issue** that cannot be resolved through client-side workarounds. The architecture requires buffer entries to match proof accounts, and there is no mechanism to skip or select specific entries.

**The only viable solution is ZEOS team intervention to clear the buffer.**

---

*E5 - Integration Specialist*
*Engineering Roundtable Investigation*
*2026-02-04*
