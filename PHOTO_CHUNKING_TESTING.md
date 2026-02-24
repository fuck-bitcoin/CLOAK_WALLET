# Photo Chunking Integration Testing Guide

This document provides guidelines for manually testing the photo chunking feature.

## Prerequisites

1. Two CLOAK Wallet instances running (Instance A and Instance B)
2. Both instances synced with the blockchain
3. Active chat conversation between the two instances

## Test Scenarios

### Scenario 1: Small Photo (Single Transaction)

**Objective**: Verify basic photo sending works with a small photo that fits in one transaction.

**Steps**:
1. Open chat thread in Instance A
2. Tap the plus (+) button
3. Select "Photo" option
4. Pick a small photo (< 80KB uncompressed)
5. Verify the send photo page shows:
   - "Photo: X chunks"
   - "1 transaction(s) required"
6. Tap "Send Photo"
7. Complete the transaction
8. In Instance B, wait for messages to sync
9. Verify photo appears in chat thread
10. Tap photo to view full-screen
11. Verify photo displays correctly

**Expected Results**:
- Photo is encoded and chunked correctly
- Single transaction created
- Photo reassembles correctly on receiver side
- Photo displays in chat bubble
- Full-screen viewer works

---

### Scenario 2: Medium Photo (Multiple Transactions)

**Objective**: Verify photo sending works with a photo requiring multiple transactions.

**Steps**:
1. Open chat thread in Instance A
2. Tap plus (+) → Photo
3. Pick a medium photo (200-500KB uncompressed)
4. Verify send photo page shows multiple transactions
5. Tap "Send Photo"
6. Complete each transaction sequentially:
   - Transaction 1 of N
   - Transaction 2 of N
   - etc.
7. In Instance B, monitor chat thread as chunks arrive
8. Verify progress indicator shows chunk count
9. Wait for all chunks to arrive
10. Verify photo reassembles automatically
11. Verify photo displays correctly

**Expected Results**:
- Photo is split into multiple transactions
- Progress indicator shows correct chunk count
- All chunks arrive (may be out of order)
- Photo reassembles when complete
- Photo displays correctly

---

### Scenario 3: Large Photo (Maximum Size)

**Objective**: Verify photo sending works with maximum size photo (2MB limit).

**Steps**:
1. Open chat thread in Instance A
2. Tap plus (+) → Photo
3. Pick a large photo (~2MB uncompressed)
4. Verify send photo page shows:
   - Many chunks
   - Multiple transactions
   - Estimated transaction count
5. Tap "Send Photo"
6. Complete all transactions
7. In Instance B, verify photo reassembles
8. Verify photo quality is acceptable after compression

**Expected Results**:
- Photo compresses successfully
- Photo is split into many chunks
- Multiple transactions created
- All chunks arrive
- Photo reassembles correctly
- Photo quality is acceptable

---

### Scenario 4: Out-of-Order Chunk Delivery

**Objective**: Verify photo reassembly works when chunks arrive out of order.

**Steps**:
1. Send a photo requiring multiple transactions (Scenario 2)
2. In Instance B, observe chat thread during sending
3. Verify chunks appear in chat as they arrive
4. Verify progress indicator updates as chunks arrive
5. Verify photo reassembles when all chunks arrive (regardless of order)

**Expected Results**:
- Chunks may arrive in any order
- Progress indicator updates incrementally
- Photo reassembles correctly once all chunks arrive
- No duplicate chunks processed

---

### Scenario 5: Transaction Size Verification

**Objective**: Verify transactions with 200 chunks per transaction work correctly.

**Steps**:
1. Send a photo large enough to require 200+ chunks
2. Monitor transaction preparation:
   - Check if transaction with 200 chunks is accepted
   - Verify transaction size is within limits
3. If transaction fails, reduce batch size:
   - Modify `MAX_CHUNKS_PER_TX` in `photo_encoder.dart`
   - Test with smaller batches (e.g., 100, 50)

**Expected Results**:
- Transactions with 200 chunks work (if supported)
- OR transactions are automatically batched smaller
- No transaction size errors

**If Transaction Fails**:
- Reduce `MAX_CHUNKS_PER_TX` to 100 or 50
- Re-test with smaller batches
- Document working batch size

---

### Scenario 6: Error Handling

**Objective**: Verify error handling works correctly.

**Test Cases**:

#### 6a. Missing Chunks
1. Send a photo with multiple transactions
2. Cancel one transaction (don't send it)
3. In Instance B, verify:
   - Incomplete photo shows loading state
   - Progress indicator shows missing chunks
   - Error message appears after timeout

#### 6b. Invalid Photo
1. Try to send a corrupted/invalid image file
2. Verify error message appears
3. Verify no transaction is created

#### 6c. Oversized Photo
1. Try to send a photo > 2MB
2. Verify error message appears
3. Verify no encoding occurs

#### 6d. Network Failure
1. Send a photo
2. Disconnect network mid-transaction
3. Verify error handling
4. Reconnect and verify recovery

**Expected Results**:
- All errors handled gracefully
- User-friendly error messages displayed
- No app crashes
- State remains consistent

---

### Scenario 7: Performance & Memory

**Objective**: Verify performance is acceptable.

**Steps**:
1. Send multiple photos in quick succession
2. Verify:
   - Memory usage doesn't spike
   - UI remains responsive
   - Photos cache correctly
   - Old photos cleaned up

**Expected Results**:
- Memory usage stays reasonable
- UI remains responsive
- Photos cache efficiently
- No memory leaks

---

## Verification Checklist

After testing, verify:

- [ ] Small photos (single transaction) work
- [ ] Medium photos (multiple transactions) work
- [ ] Large photos (max size) work
- [ ] Out-of-order chunk delivery handled
- [ ] Progress indicators work correctly
- [ ] Photo thumbnails display in chat
- [ ] Full-screen photo viewer works
- [ ] Error handling works for all scenarios
- [ ] Transaction size limits respected
- [ ] Performance is acceptable
- [ ] Memory usage is reasonable
- [ ] No crashes or data corruption

## Troubleshooting

### Issue: Transaction fails with "too large" error

**Solution**: Reduce `MAX_CHUNKS_PER_TX` in `photo_encoder.dart`:
```dart
static const int MAX_CHUNKS_PER_TX = 100; // Reduced from 200
```

### Issue: Photo doesn't reassemble

**Check**:
1. All chunks received (check progress indicator)
2. Chunks have same `photo_id`
3. Chunks have correct `chunk_index` values
4. No duplicate chunks

### Issue: Photo quality too low

**Solution**: Adjust compression quality in `photo_encoder.dart`:
```dart
static const int DEFAULT_QUALITY = 90; // Increased from 85
```

### Issue: Memory issues with large photos

**Check**:
1. Photos are cached efficiently
2. Old photos cleaned up
3. Consider limiting max photo size further

## Notes

- Transaction size limits depend on Zcash network configuration
- Real-world testing may reveal optimal batch sizes
- Photo quality vs. size tradeoff may need adjustment
- Network conditions affect chunk delivery timing





