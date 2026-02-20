import 'package:zwallet/utils/photo_encoder.dart';
import 'package:zwallet/utils/photo_decoder.dart';
import 'package:zwallet/utils/photo_models.dart';
import 'package:zwallet/pages/utils.dart';
import 'dart:typed_data';
import 'dart:math';

/// Integration test utilities for photo chunking
class PhotoChunkingTestUtils {
  /// Create a test image of specified size (simple colored rectangle)
  static Uint8List createTestImage({int width = 100, int height = 100}) {
    // Create a minimal PNG-like structure for testing
    // In real tests, you'd use the image package to create actual images
    final random = Random();
    final bytes = Uint8List(width * height * 4); // RGBA
    for (int i = 0; i < bytes.length; i += 4) {
      bytes[i] = random.nextInt(256);     // R
      bytes[i + 1] = random.nextInt(256);  // G
      bytes[i + 2] = random.nextInt(256);  // B
      bytes[i + 3] = 255;                  // A
    }
    return bytes;
  }
  
  /// Simulate encoding a photo and verify chunk count
  static Future<Map<String, dynamic>> simulatePhotoEncoding(
    Uint8List imageBytes,
    String cid,
    int seq,
  ) async {
    try {
      final chunks = await PhotoEncoder.encodePhoto(imageBytes, cid, seq);
      
      // Group chunks by transaction (simulate MAX_CHUNKS_PER_TX)
      final batches = <List<PhotoChunk>>[];
      for (int i = 0; i < chunks.length; i += PhotoEncoder.MAX_CHUNKS_PER_TX) {
        final end = (i + PhotoEncoder.MAX_CHUNKS_PER_TX).clamp(0, chunks.length);
        batches.add(chunks.sublist(i, end));
      }
      
      // Calculate total memo size per transaction
      final batchSizes = batches.map((batch) {
        int totalSize = 0;
        for (final chunk in batch) {
          final memo = PhotoEncoder.buildChunkMemo(chunk);
          totalSize += memo.length;
        }
        return totalSize;
      }).toList();
      
      return {
        'success': true,
        'chunks': chunks.length,
        'batches': batches.length,
        'batchSizes': batchSizes,
        'maxBatchSize': batchSizes.isNotEmpty ? batchSizes.reduce((a, b) => a > b ? a : b) : 0,
        'photoId': chunks.isNotEmpty ? chunks.first.photoId : null,
      };
    } catch (e) {
      return {
        'success': false,
        'error': e.toString(),
      };
    }
  }
  
  /// Verify transaction size is within limits
  static bool verifyTransactionSize(List<PhotoChunk> chunks) {
    if (chunks.isEmpty) return true;
    
    // Calculate total memo size
    int totalSize = 0;
    for (final chunk in chunks) {
      final memo = PhotoEncoder.buildChunkMemo(chunk);
      totalSize += memo.length;
    }
    
    // Zcash block size is ~2MB, but individual transactions should be smaller
    // Conservative limit: ~1MB per transaction (allowing for overhead)
    const int maxTransactionSize = 1024 * 1024; // 1MB
    
    return totalSize <= maxTransactionSize;
  }
  
  /// Test reassembly with simulated out-of-order delivery
  static Future<bool> testOutOfOrderReassembly(List<PhotoChunk> chunks) async {
    if (chunks.isEmpty) return false;
    
    // Shuffle chunks to simulate out-of-order delivery
    final shuffled = List<PhotoChunk>.from(chunks)..shuffle();
    
    // Collect chunks as if they arrive one by one
    final Map<String, List<PhotoChunk>> collected = {};
    for (final chunk in shuffled) {
      collected.putIfAbsent(chunk.photoId, () => []).add(chunk);
    }
    
    // Try to reassemble
    for (final entry in collected.entries) {
      final reassembled = await PhotoDecoder.reassemblePhoto(entry.value);
      if (reassembled == null) return false;
    }
    
    return true;
  }
  
  /// Calculate estimated transaction fee based on chunk count
  static int estimateTransactionFee(int chunkCount) {
    // Rough estimate: base fee + per-output fee
    // Zcash base fee: ~1000 zatoshis
    // Per-output overhead: ~100-200 zatoshis
    const int baseFee = 1000;
    const int perOutputFee = 150;
    return baseFee + (chunkCount * perOutputFee);
  }
}





