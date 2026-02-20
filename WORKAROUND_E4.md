# WORKAROUND_E4: Assetbuffer Pollution Resolution

**Agent:** E4 (Protocol Specialist)
**Date:** 2026-02-04
**Status:** CONTACT INFO GATHERED - ACTION REQUIRED

---

## Executive Summary

The `zeosprotocol::assetbuffer` table on Telos Mainnet has 4 orphaned entries blocking all mint operations. **There is NO on-chain admin function to clear this buffer** - a contract update by the ZEOS team is required.

---

## Contact Information for ZEOS Team

### Primary Contact: Matthias Schoenebeck

| Channel | Contact |
|---------|---------|
| **GitHub** | [@mschoenebeck](https://github.com/mschoenebeck) |
| **Twitter/X** | [@mschoenebeck1](https://x.com/mschoenebeck1) |
| **Website** | [zeos.one](https://zeos.one) |
| **Medium** | [@matthias.schoenebeck](https://medium.com/@matthias.schoenebeck) |

### Community Channels

| Channel | Link |
|---------|------|
| **Telegram** | [@ZeosOnEos](https://t.me/ZeosOnEos) (38 subscribers) |

---

## On-Chain Analysis

### zeosprotocol Contract Details

**Account:** `zeosprotocol`
**Chain:** Telos Mainnet
**Last Code Update:** 2026-01-26
**Owner Key:** `EOS886iqLMqQdxVebdaSn8xXSzGWwJL9khbq34zSQsvz8SbzM6cFe`

### Available Contract Actions

```
authenticate, init, mint, recordblock, rmnftcntrct,
setpvk, spend, updnftcntrct, withdraw
```

### Contract Tables

```
assetbuffer, blocks, global, merkletree, nftcontracts, nullifiers, pvk
```

### Critical Finding: No Buffer Clear Function

**The zeosprotocol contract has NO action to clear the assetbuffer table.**

The only way to remove entries is:
1. Contract update by the owner (Matthias Schoenebeck)
2. Or completing the mint cycle (which is blocked by the pollution)

---

## Current Buffer State

```bash
curl -s 'https://telos.eosusa.io/v1/chain/get_table_rows' \
  -d '{"code":"zeosprotocol","scope":"zeosprotocol","table":"assetbuffer","limit":10}'
```

**Result:** 4 orphaned entries still present with `thezeosalias` as the transfer sender, blocking mints for any other account.

---

## Recommended Contact Message

### For Telegram/Twitter/GitHub Issue:

```
Subject: URGENT: assetbuffer pollution blocking all CLOAK mints on Telos

Hi Matthias,

I'm developing a CLOAK Wallet for Telos using the ZEOS shielded protocol.
We've discovered a critical issue:

PROBLEM:
The `zeosprotocol::assetbuffer` table on Telos has 4 orphaned entries
with `field_0: thezeosalias`. These entries are blocking ALL mint
operations because:

1. User sends CLOAK to thezeosvault (transfer recorded in assetbuffer)
2. User calls mint with ZK proof
3. The verifier reads the WRONG account from assetbuffer (thezeosalias
   instead of the actual sender)
4. Result: "mint: proof invalid" because proof was generated for wrong account

REPRODUCTION:
- Any account trying to mint gets "proof invalid"
- The buffer has old entries from thezeosalias that were never consumed

REQUEST:
Could you please clear the assetbuffer table entries? The contract has
no user-accessible clear function.

Alternatively, could you add an admin action to clear stale buffer entries?

Thank you for your work on ZEOS!

Technical details:
- Contract: zeosprotocol on Telos Mainnet
- Table: assetbuffer
- Orphaned entries: 4 rows with field_0=thezeosalias
- Affected asset: CLOAK (4,CLOAK)
```

---

## Alternative Workarounds (While Waiting for Team Response)

### Workaround 1: Use thezeosalias Account

Since the buffer entries belong to `thezeosalias`:
- The private key for `thezeosalias@public` is publicly known: `5KUxZHKVvF3mzHbCRAHCPJd4nLBewjnxHkDkG8LzVggX4GtnHn6`
- **THEORY:** If we could complete the mint cycle AS thezeosalias, it would consume the buffer entries

**Steps:**
1. Generate ZK proof as thezeosalias (not gi4tambwgege)
2. Call mint action
3. This should consume 1 buffer entry
4. Repeat 4 times to clear all entries

**Risk:** thezeosalias may not have the correct commitment state

### Workaround 2: Deploy on Alternative Chain

ZEOS is also deployed on EOS Mainnet:
- Check if EOS mainnet assetbuffer is clean
- Test minting on EOS first

### Workaround 3: Wait for Contract Update

The `last_code_update` was 2026-01-26, suggesting active development. The team may already be aware and working on a fix.

---

## GitHub Repositories to File Issue

| Repository | Purpose |
|------------|---------|
| [thezeostoken](https://github.com/mschoenebeck/thezeostoken) | Main token contract |
| [zeos-validator](https://github.com/mschoenebeck/zeos-validator) | Validator node |
| [zeos-bundler](https://github.com/mschoenebeck/zeos-bundler) | Web3 bundler |

**Note:** No existing issues about buffer pollution were found.

---

## Project Background

ZEOS received ~$25,000 from Pomelo Grants Season 2, funded by the EOS Network Foundation. This is an actively maintained project with recent contract updates.

---

## Action Items

1. **IMMEDIATE:** Join Telegram [@ZeosOnEos](https://t.me/ZeosOnEos) and post the issue
2. **IMMEDIATE:** DM @mschoenebeck1 on Twitter/X
3. **TODAY:** Open GitHub issue on [thezeostoken](https://github.com/mschoenebeck/thezeostoken/issues)
4. **EXPERIMENT:** Try generating proof for thezeosalias to test buffer consumption theory

---

## Technical Notes

### Why No Self-Service Clear?

The assetbuffer is intentionally non-clearable because:
- It holds pending transfer records for shielded minting
- Allowing arbitrary clearing would break the atomic transfer->mint flow
- Only successful mint verification should consume entries

### The Design Flaw

The contract assumes buffer entries will always be consumed. There's no:
- Timeout/expiration mechanism
- Admin clear function
- User refund/cancel action

This is a protocol design gap that should be addressed.

---

## References

- [ZEOS HackerNoon Article](https://hackernoon.com/zeos-privacy-on-eos)
- [ZEOS Whitepaper](https://github.com/mschoenebeck/zeos-docs)
- [Pomelo Grants S2 Recipients](https://www.eosgo.io/news/look-into-pomelo-top-ten-season-2-grant-recipients)
- [ZEOS Privacy Token Launch](https://en.cryptonomist.ch/2021/12/27/zeos-active-privacy-token-blockchain-eos/)

---

*Generated by E4 (Protocol Specialist) - CLOAK Wallet Investigation Team*
