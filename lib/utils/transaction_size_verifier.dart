import 'photo_models.dart';
import 'photo_encoder.dart';

/// Transaction size verification utility for photo chunking
/// This can be used to verify transaction sizes before sending
class TransactionSizeVerifier {
  /// Maximum recommended transaction size in bytes
  /// Zcash blocks are ~2MB, but individual transactions should be smaller
  static const int MAX_RECOMMENDED_TX_SIZE = 1024 * 1024; // 1MB
  
  /// Estimate transaction size for a batch of photo chunks
  /// Returns estimated size in bytes
  static int estimateTransactionSize(List<PhotoChunk> chunks) {
    if (chunks.isEmpty) return 0;
    
    int totalMemoSize = 0;
    
    // Calculate total memo size for all chunks
    for (final chunk in chunks) {
      final memo = PhotoEncoder.buildChunkMemo(chunk);
      totalMemoSize += memo.length;
    }
    
    // Add transaction overhead (approximate)
    // Base transaction structure: ~200 bytes
    // Per-output overhead: ~150 bytes per recipient
    const int baseTxOverhead = 200;
    const int perOutputOverhead = 150;
    
    final estimatedSize = baseTxOverhead + (chunks.length * perOutputOverhead) + totalMemoSize;
    
    return estimatedSize;
  }
  
  /// Check if transaction size is acceptable
  static bool isTransactionSizeAcceptable(List<PhotoChunk> chunks) {
    final size = estimateTransactionSize(chunks);
    return size <= MAX_RECOMMENDED_TX_SIZE;
  }
  
  /// Find optimal batch size for chunks
  /// Returns maximum number of chunks that fit in one transaction
  static int findOptimalBatchSize(List<PhotoChunk> chunks) {
    if (chunks.isEmpty) return 0;
    
    // Use binary search to find optimal batch size
    int low = 1;
    int high = chunks.length;
    int optimal = 1;
    
    while (low <= high) {
      final mid = (low + high) ~/ 2;
      final batch = chunks.take(mid).toList();
      
      if (isTransactionSizeAcceptable(batch)) {
        optimal = mid;
        low = mid + 1;
      } else {
        high = mid - 1;
      }
    }
    
    return optimal;
  }
  
  /// Get batch size recommendations
  static Map<String, dynamic> getBatchSizeRecommendations(List<PhotoChunk> chunks) {
    final currentBatchSize = PhotoEncoder.MAX_CHUNKS_PER_TX;
    final optimalBatchSize = findOptimalBatchSize(chunks);
    
    final recommendations = <String, dynamic>{
      'currentBatchSize': currentBatchSize,
      'optimalBatchSize': optimalBatchSize,
      'currentSizeOk': optimalBatchSize >= currentBatchSize,
      'recommendation': currentBatchSize > optimalBatchSize
          ? 'Consider reducing MAX_CHUNKS_PER_TX to $optimalBatchSize'
          : 'Current batch size is acceptable',
    };
    
    return recommendations;
  }
  
  /// Verify all batches in a photo sending operation
  static List<Map<String, dynamic>> verifyAllBatches(List<PhotoChunk> chunks) {
    final batches = <List<PhotoChunk>>[];
    for (int i = 0; i < chunks.length; i += PhotoEncoder.MAX_CHUNKS_PER_TX) {
      final end = ((i + PhotoEncoder.MAX_CHUNKS_PER_TX) as int).clamp(0, chunks.length);
      batches.add(chunks.sublist(i, end));
    }
    
    final results = batches.asMap().entries.map((entry) {
      final batchIndex = entry.key;
      final batch = entry.value;
      final size = estimateTransactionSize(batch);
      final isOk = isTransactionSizeAcceptable(batch);
      
      return {
        'batchIndex': batchIndex + 1,
        'chunkCount': batch.length,
        'estimatedSize': size,
        'isAcceptable': isOk,
        'warning': !isOk ? 'Transaction size may be too large!' : null,
      };
    }).toList();
    
    return results;
  }
}

