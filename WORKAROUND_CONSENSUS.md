# Engineering Round Table - Workaround Consensus

**Date:** 2026-02-04
**Purpose:** Find workaround for assetbuffer pollution blocking shield operations

---

## FINAL VERDICT

### Creating a new CLOAK account will NOT help.

However, there IS a potential workaround discovered:

---

## The Breakthrough Finding (E2)

E2 discovered that the successful transaction `907b8e12...` (user: retiretelos1) worked because:

1. The user's transfer **ADDED NEW buffer entries**
2. The proof was generated for those **NEW entries**
3. The orphaned entries were **NOT touched** - they're still there!
4. The transaction consumed the NEW entries, leaving orphaned ones intact

**This suggests the buffer matching is NOT purely FIFO by position.**

The orphaned entries are for **0.0001 CLOAK** each. If you shield a **DIFFERENT amount**, your new buffer entry might be matched to your proof instead of the orphaned entries.

---

## RECOMMENDED WORKAROUND: Try a Different Amount

### Option 1: Shield TLOS Instead of CLOAK (HIGH confidence)
- Different token entirely
- Won't match orphaned CLOAK entries
- Verified: retiretelos1 shielded TLOS successfully

### Option 2: Shield a Different CLOAK Amount (MEDIUM confidence)
- Orphaned entries are exactly **0.0001 CLOAK** each
- Try shielding **1.0000 CLOAK** or any amount that's NOT 0.0001
- Your new entry might be matched correctly

### Option 3: Contact ZEOS Team (DEFINITIVE but slow)
- Telegram: [@ZeosOnEos](https://t.me/ZeosOnEos)
- Twitter: [@mschoenebeck1](https://x.com/mschoenebeck1)
- GitHub: [@mschoenebeck](https://github.com/mschoenebeck)

---

## What WON'T Work

| Approach | Why It Won't Work |
|----------|-------------------|
| New Telos account | Same buffer, same pollution |
| Using cleos directly | Same on-chain contract |
| Using official CLOAK GUI | Same protocol, same pollution |
| Using app.cloak.today | Same protocol, same pollution |
| Calling end without mint | Only clears actionbuffer, not assetbuffer |
| Minting AS thezeosalias | Original note commitment data (rcm) is LOST |

---

## Why Orphaned Entries Can't Be Consumed

E2 discovered a critical detail: Each buffer entry has an expected **note commitment (cm)** that requires:
- account + value + symbol + contract + recipient_address + **rcm** (random trapdoor)

The original **rcm** values are **LOST**. Without them, nobody can generate a valid proof to consume those entries - not even the ZEOS team through normal minting.

The only solution is for the contract owner to **manually clear** the buffer table using their owner key.

---

## Recommended Action Plan

### Immediate (Try Now):
1. **Shield TLOS** - Try shielding 10 TLOS instead of CLOAK
2. **Shield different CLOAK amount** - Try 1.0000 CLOAK instead of your usual amount

### If That Fails:
3. **Contact ZEOS team**:
   - Join Telegram: https://t.me/ZeosOnEos
   - DM on Twitter: @mschoenebeck1
   - Open GitHub issue: github.com/mschoenebeck/zeos-caterpillar

### Message Template for ZEOS Team:
```
Hi, I'm encountering "mint: proof invalid" errors when trying to shield CLOAK.

Investigation found 4 orphaned entries in zeosprotocol::assetbuffer:
- All have field_0: thezeosalias
- All for 0.0001 CLOAK

These appear to be from incomplete transactions. Could you please clear
the assetbuffer table? The orphaned entries are blocking all shield operations.

Verification command:
curl -s 'https://telos.eosusa.io/v1/chain/get_table_rows' \
  -d '{"code":"zeosprotocol","scope":"zeosprotocol","table":"assetbuffer","limit":10}'

Thank you!
```

---

## Technical Summary

| Finding | Engineer | Confidence |
|---------|----------|------------|
| Buffer is NOT purely FIFO | E2 | HIGH (evidence from retiretelos1) |
| New account won't help | E1, E4, E5 | HIGH |
| Different token/amount may work | E1 | MEDIUM-HIGH |
| No admin clear function exists | E4 | CONFIRMED |
| Orphaned rcm data is lost | E2 | CONFIRMED |
| All client paths hit same buffer | E5 | CONFIRMED |

---

## Files Created During Investigation

| File | Engineer | Content |
|------|----------|---------|
| WORKAROUND_E1.md | E1 (Lead) | Buffer mechanics, new account analysis |
| WORKAROUND_E2.md | E2 | Successful tx analysis, lost rcm discovery |
| WORKAROUND_E3.md | E3 | ZK proof generation options |
| WORKAROUND_E4.md | E4 | ZEOS contact info, no admin function |
| WORKAROUND_E5.md | E5 | Alternative flows analysis |
| WORKAROUND_CONSENSUS.md | ALL | This document |

---

## Conclusion

**Don't create a new CLOAK account - it won't help.**

Instead:
1. **Try shielding TLOS** or a **different CLOAK amount** first
2. If that fails, **contact the ZEOS team** to manually clear the buffer

The good news: Your CLOAK balance (235,483.7754 CLOAK) is safe. Only the shielding operation is blocked until the buffer is cleared or you find an amount that works.

---

*Engineering Round Table - Workaround Investigation*
*2026-02-04*
