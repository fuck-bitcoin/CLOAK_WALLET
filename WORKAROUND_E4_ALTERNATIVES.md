# E4 Alternative Approaches Report
## Workarounds for Asset Buffer Pollution

**Engineer:** E4 - Protocol Specialist
**Date:** 2026-02-04
**Status:** Investigation Complete

---

## Executive Summary

The asset buffer pollution (4 orphaned entries with `field_0: thezeosalias`) is blocking mints. This document explores alternative approaches to shield tokens while the buffer is polluted.

**CRITICAL FINDING: There is NO client-side workaround that can bypass the buffer pollution.** The issue is in the on-chain smart contract's verification logic. The only real solution is to contact the ZEOS team.

---

## 1. Current Blockchain State

```bash
curl -s 'https://telos.eosusa.io/v1/chain/get_table_rows' \
  -d '{"code":"zeosprotocol","scope":"zeosprotocol","table":"assetbuffer","limit":10,"json":true}'
```

**Result (2026-02-04):**
```json
{
  "rows": [{
    "assets": [
      {"field_0": "thezeosalias", "field_1": {"quantity": "0.0001 CLOAK", "contract": "thezeostoken"}},
      {"field_0": "thezeosalias", "field_1": {"quantity": "0.0001 CLOAK", "contract": "thezeostoken"}},
      {"field_0": "thezeosalias", "field_1": {"quantity": "0.0001 CLOAK", "contract": "thezeostoken"}},
      {"field_0": "thezeosalias", "field_1": {"quantity": "0.0001 CLOAK", "contract": "thezeostoken"}}
    ]
  }]
}
```

**Buffer is still polluted. 4 orphaned entries present.**

---

## 2. Alternative 1: Direct cleos/curl Submission

### Analysis

**Question:** Can we bypass ESR/Anchor and submit transactions directly via cleos or curl?

**Answer:** Yes, but it **WILL NOT solve the buffer pollution issue**.

### Why Direct Submission Won't Help

The buffer pollution is **on-chain state**, not a client-side issue:

1. Whether we submit via ESR+Anchor, cleos, or raw curl POST, the **same smart contract code executes**
2. The `zeosprotocol::mint` action reads from `assetbuffer` regardless of submission method
3. The verifier will still read the wrong account from orphaned entries

### Technical Details

Direct submission requires:
- EOSIO CLI tools (cleos) - **NOT INSTALLED** on this system
- Private key for user account (available)
- Private key for thezeosalias@public (available: `5KUxZHKVvF3mzHbCRAHCPJd4nLBewjnxHkDkG8LzVggX4GtnHn6`)

Could be done via curl:
```bash
# Push transaction (example)
curl 'https://telos.eosusa.io/v1/chain/push_transaction' \
  -d '{"compression":"none","transaction":{"..."},"signatures":["SIG_...","SIG_..."]}'
```

**Verdict: NOT A WORKAROUND** - Same error would occur.

---

## 3. Alternative 2: Official CLOAK GUI

### Location

```
/opt/cloak-gui/cloak-gui
```

### Configuration Analysis

From `/opt/cloak-gui/config.json`:
```json
{
  "autoSync": true,
  "autoSyncInterval": 1000,
  "protocols": [{
    "alias_authority": "thezeosalias@public",
    "alias_authority_key": "5KUxZHKVvF3mzHbCRAHCPJd4nLBewjnxHkDkG8LzVggX4GtnHn6",
    "chain_id": "4667b205c6838ef70ff7988f6e8257e8be0e1284a2f59699054a018f743b1d11",
    "protocol_contract": "zeosprotocol",
    "vault_contract": "thezeosvault",
    "peers": [
      "https://telos.eosusa.io",
      "https://telos.cryptolions.io",
      ...
    ]
  }]
}
```

### Key Observations

1. **Same thezeosalias key** - Identical to our Flutter wallet
2. **Same protocol contract** - `zeosprotocol`
3. **Same vault contract** - `thezeosvault`
4. **No special buffer handling** - No config options for buffer management

### Does Official GUI Have Special Handling?

**NO.** The official GUI uses the same:
- Protocol contract (zeosprotocol)
- Same transaction structure
- Same verification process

The GUI would encounter the **same buffer pollution issue**.

**Verdict: NOT A WORKAROUND** - Same contract, same error.

---

## 4. Alternative 3: Vault Deposits (thezeosvault)

### Vault System Analysis

**Question:** Can we deposit to thezeosvault instead of direct mint?

### Vault ABI (from chain):

```json
{
  "tables": [
    {"name": "vaults", "type": "vault"},
    {"name": "vaultcfg", "type": "vault_cfg"}
  ],
  "actions": [
    {"name": "withdrawp", "type": "withdrawp"},
    {"name": "gcvaults", "type": "gcvaults"},
    {"name": "burnvaultp", "type": "burnvaultp"}
  ]
}
```

### Vault Configuration

```bash
curl -s 'https://telos.eosusa.io/v1/chain/get_table_rows' \
  -d '{"code":"thezeosvault","scope":"thezeosvault","table":"vaultcfg","limit":10,"json":true}'
```

**Result:**
```json
{
  "rows": [{
    "free_vault_duration": 86400,
    "min_stake": {"quantity": "1000.0000 CLOAK", "contract": "thezeostoken"},
    "max_slots": 100
  }]
}
```

### Current Vault State

```bash
curl -s 'https://telos.eosusa.io/v1/chain/get_table_rows' \
  -d '{"code":"thezeosvault","scope":"thezeosvault","table":"vaults","limit":10,"json":true}'
```

**Result:**
```json
{
  "rows": [{
    "auth_token": "175a5d85d0541a5e7eba78cfa6a69fcc65c8f9139855cdcb548e1df64b33a847",
    "creation_block_time": 1770156113,
    "fts": [{"first": {"sym": "4,CLOAK", "contract": "thezeostoken"}, "second": 10000}],
    "nfts": []
  }]
}
```

### How Vault Works

The vault system is for **WITHDRAWING from shielded pool**, not for shielding:

1. Vault creates a time-locked container for withdrawn (unshielded) tokens
2. User proves ownership via ZK proof to `withdrawp`
3. Tokens are held in vault temporarily
4. User can then claim publicly

### Is Vault an Alternative to Mint?

**NO.** The vault is for the opposite direction:
- **Mint (Shield):** Public tokens -> Private pool
- **Vault (Unshield):** Private pool -> Time-locked public container

You cannot "deposit to vault" to shield tokens. The vault receives **already-unshielded** tokens.

**Verdict: NOT APPLICABLE** - Vault is for unshielding, not shielding.

---

## 5. Alternative 4: Contact ZEOS Team

### Contact Channels Found

| Platform | Handle/Link |
|----------|-------------|
| Telegram | @ZeosOfficial |
| Twitter/X | @cloak_today |
| GitHub | github.com/mschoenebeck/zeos-caterpillar |
| YouTube | @cloak_today |
| Instagram | @cloak_today |
| Medium | @matthias.schoenebeck |

### GitHub Information

**Repository:** [zeos-caterpillar](https://github.com/mschoenebeck/zeos-caterpillar)

**Current Issues:** 1 open (macOS build issue, unrelated)

**How to Report:**
1. Navigate to github.com/mschoenebeck/zeos-caterpillar/issues
2. Click "New Issue"
3. Describe the assetbuffer pollution problem

### Recommended Message

```
Subject: Asset Buffer Pollution Blocking All Mints

The zeosprotocol::assetbuffer table on Telos mainnet has 4 orphaned entries
with field_0 = "thezeosalias". These appear to be remnants of incomplete
transactions.

Current state:
- 4 entries with 0.0001 CLOAK each
- All have field_0 = thezeosalias (not actual users)
- This causes "mint: proof invalid" for ALL users attempting to shield

Verification command:
curl -s 'https://telos.eosusa.io/v1/chain/get_table_rows' \
  -d '{"code":"zeosprotocol","scope":"zeosprotocol","table":"assetbuffer","limit":10}'

Could these orphaned entries be cleared? The buffer should be empty between
transactions.

Thank you.
```

**Verdict: BEST OPTION** - Only the contract owner can clear orphaned entries.

---

## 6. Alternative 5: Web App (app.cloak.today)

### Analysis

**Question:** Does the web app have workarounds built in?

### Observations

The web app at app.cloak.today:
- Uses the same zeosprotocol contract
- Uses the same transaction flow
- Uses same Anchor wallet integration
- Has NO special buffer handling visible

### Web App Features

From page analysis:
- Dashboard with supply metrics
- Vault interface (for withdrawals)
- Bridge functionality
- Auction/DEX/Lending modules

**No special mint workarounds visible in the public interface.**

**Verdict: NO WORKAROUND** - Same contract, same limitation.

---

## 7. Theory Test: Different Account

### Proposal

Create a **new Telos account** and attempt to shield from that account.

### Possible Outcomes

1. **If buffer uses account-specific indexing:**
   - New account would have clean buffer state
   - Mint might succeed
   - UNLIKELY based on contract structure

2. **If buffer is shared FIFO (current understanding):**
   - New account's entry would be added after orphaned entries
   - Verifier might still read orphaned entry first
   - Mint would still fail

### How to Test

```bash
# 1. Create new Telos account (via Anchor or Wombat)
# 2. Transfer some CLOAK to new account
# 3. Attempt shield from new account
# 4. Observe result
```

This would **confirm the theory** but likely **not provide a workaround**.

---

## 8. Diagnostic: Monitor Buffer Changes

### Watch for Natural Cleanup

Run this periodically to see if buffer clears:

```bash
watch -n 60 'curl -s "https://telos.eosusa.io/v1/chain/get_table_rows" \
  -d "{\"code\":\"zeosprotocol\",\"scope\":\"zeosprotocol\",\"table\":\"assetbuffer\",\"limit\":10,\"json\":true}" \
  | jq ".rows[0].assets | length"'
```

### Expected Clean State

```json
{"rows":[{"assets":[]}],"more":false}
```

or

```json
{"rows":[],"more":false}
```

---

## 9. Summary of Alternatives

| Alternative | Viable? | Reason |
|------------|---------|--------|
| Direct cleos submission | NO | Same contract code executes |
| Official CLOAK GUI | NO | Same contract, same error |
| Vault deposits | NO | Vault is for unshielding, not shielding |
| **Contact ZEOS team** | **YES** | Only solution - contract owner can clear buffer |
| Web app workaround | NO | Same contract limitation |
| Different account | UNLIKELY | Buffer appears to be shared |

---

## 10. Recommended Action Plan

### Immediate (Today)

1. **Join Telegram:** @ZeosOfficial
2. **Send message** explaining the assetbuffer pollution
3. **Include verification command** for them to check
4. **Request buffer cleanup**

### If No Response (48 hours)

1. **Open GitHub Issue** on zeos-caterpillar repository
2. **Tag @mschoenebeck** (maintainer)
3. **Tweet @cloak_today** for visibility

### Ongoing

1. **Monitor buffer state** with curl command
2. **Test shield immediately** when buffer is cleared
3. **Document the resolution** for future reference

---

## 11. Conclusion

**There is no client-side workaround for the asset buffer pollution.**

The root cause is on-chain smart contract state that can only be cleared by:
1. Contract owner (ZEOS team) explicitly clearing entries
2. Normal protocol operation consuming the entries (unlikely given their structure)
3. Contract upgrade with cleanup mechanism

**The only viable path forward is contacting the ZEOS team through Telegram (@ZeosOfficial) or GitHub issues.**

---

*Report compiled by E4 - Protocol Specialist*
*Engineering Roundtable Investigation - 2026-02-04*
