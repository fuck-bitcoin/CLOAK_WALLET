import 'package:flutter_test/flutter_test.dart';
import 'package:zwallet/utils/photo_encoder.dart';
import 'package:zwallet/utils/photo_decoder.dart';
import 'package:zwallet/utils/photo_models.dart';
import 'package:zwallet/utils/photo_test_utils.dart';
import 'package:zwallet/pages/utils.dart';
import 'dart:typed_data';
import 'dart:math';
import 'package:image/image.dart' as img;

void main() {
  group('Photo Encoder Tests', () {
    test('generatePhotoId generates unique IDs', () {
      final id1 = PhotoEncoder.generatePhotoId();
      final id2 = PhotoEncoder.generatePhotoId();
      expect(id1, isNotEmpty);
      expect(id2, isNotEmpty);
      expect(id1, isNot(equals(id2)));
      // Photo ID should be base64url (no padding)
      expect(id1.contains('='), isFalse);
    });

    test('encodeBase64Url removes padding', () {
      final bytes = Uint8List.fromList([1, 2, 3]);
      final encoded = PhotoEncoder.encodeBase64Url(bytes);
      expect(encoded.contains('='), isFalse);
    });

    test('chunkPhoto creates correct number of chunks', () {
      final testData = 'a' * 800; // 800 chars
      final chunks = PhotoEncoder.chunkPhoto(testData, 'test_cid', 1, 'test_photo_id');
      
      // Should create 2 chunks (800 / 400 = 2)
      expect(chunks.length, equals(2));
      expect(chunks[0].chunkIndex, equals(0));
      expect(chunks[1].chunkIndex, equals(1));
      expect(chunks[0].totalChunks, equals(2));
      expect(chunks[1].totalChunks, equals(2));
    });

    test('chunkPhoto handles exact boundary', () {
      final testData = 'a' * 400; // Exactly one chunk
      final chunks = PhotoEncoder.chunkPhoto(testData, 'test_cid', 1, 'test_photo_id');
      expect(chunks.length, equals(1));
      expect(chunks[0].chunkIndex, equals(0));
      expect(chunks[0].totalChunks, equals(1));
    });

    test('chunkPhoto handles small data', () {
      final testData = 'a' * 50; // Less than one chunk
      final chunks = PhotoEncoder.chunkPhoto(testData, 'test_cid', 1, 'test_photo_id');
      expect(chunks.length, equals(1)); // Still creates one chunk
      expect(chunks[0].chunkIndex, equals(0));
      expect(chunks[0].totalChunks, equals(1));
    });

    test('buildChunkMemo creates valid memo format', () {
      final chunk = PhotoChunk(
        chunkIndex: 0,
        totalChunks: 5,
        data: 'testdata',
        photoId: 'test_photo_id',
        cid: 'test_cid',
        seq: 1,
      );
      
      final memo = PhotoEncoder.buildChunkMemo(chunk);
      expect(memo, contains('v1; type=photo_chunk'));
      expect(memo, contains('conversation_id=test_cid'));
      expect(memo, contains('photo_id=test_photo_id'));
      expect(memo, contains('chunk_index=0'));
      expect(memo, contains('total_chunks=5'));
      expect(memo, contains('testdata'));
    });

    test('buildChunkMemo stays within 512 byte limit', () {
      // Create chunk with max payload
      final maxPayload = 'a' * 400;
      final chunk = PhotoChunk(
        chunkIndex: 0,
        totalChunks: 100,
        data: maxPayload,
        photoId: 'a' * 22, // Max photo ID length
        cid: 'a' * 14, // Max CID length
        seq: 999999,
      );
      
      final memo = PhotoEncoder.buildChunkMemo(chunk);
      expect(memo.length, lessThanOrEqualTo(512));
    });
  });

  group('Photo Decoder Tests', () {
    test('isPhotoChunk identifies photo chunks correctly', () {
      final photoChunkBody = 'v1; type=photo_chunk; conversation_id=abc; photo_id=xyz\n\nchunkdata';
      final normalMessage = 'v1; type=message; conversation_id=abc\n\nHello';
      
      expect(PhotoDecoder.isPhotoChunk(photoChunkBody), isTrue);
      expect(PhotoDecoder.isPhotoChunk(normalMessage), isFalse);
      expect(PhotoDecoder.isPhotoChunk(null), isFalse);
    });

    test('validateChunks detects complete and incomplete sets', () {
      final completeChunks = [
        PhotoChunk(chunkIndex: 0, totalChunks: 2, data: 'chunk0', photoId: 'p1', cid: 'c1', seq: 1),
        PhotoChunk(chunkIndex: 1, totalChunks: 2, data: 'chunk1', photoId: 'p1', cid: 'c1', seq: 1),
      ];
      
      final incompleteChunks = [
        PhotoChunk(chunkIndex: 0, totalChunks: 2, data: 'chunk0', photoId: 'p1', cid: 'c1', seq: 1),
      ];
      
      final duplicateChunks = [
        PhotoChunk(chunkIndex: 0, totalChunks: 2, data: 'chunk0', photoId: 'p1', cid: 'c1', seq: 1),
        PhotoChunk(chunkIndex: 0, totalChunks: 2, data: 'chunk0', photoId: 'p1', cid: 'c1', seq: 1),
      ];
      
      final outOfOrderChunks = [
        PhotoChunk(chunkIndex: 1, totalChunks: 2, data: 'chunk1', photoId: 'p1', cid: 'c1', seq: 1),
        PhotoChunk(chunkIndex: 0, totalChunks: 2, data: 'chunk0', photoId: 'p1', cid: 'c1', seq: 1),
      ];
      
      expect(PhotoDecoder.validateChunks(completeChunks), isTrue);
      expect(PhotoDecoder.validateChunks(incompleteChunks), isFalse);
      expect(PhotoDecoder.validateChunks(duplicateChunks), isFalse);
      expect(PhotoDecoder.validateChunks(outOfOrderChunks), isTrue); // Order doesn't matter
      expect(PhotoDecoder.validateChunks([]), isFalse);
    });

    test('reassemblePhoto works with correct chunks', () async {
      // Create test data
      final testData = 'Hello, World! This is a test photo data.';
      final encoded = PhotoEncoder.encodeBase64Url(Uint8List.fromList(testData.codeUnits));
      
      final chunks = PhotoEncoder.chunkPhoto(encoded, 'test_cid', 1, 'test_photo_id');
      
      final reassembled = await PhotoDecoder.reassemblePhoto(chunks);
      expect(reassembled, isNotNull);
      
      // Verify data matches
      final decoded = String.fromCharCodes(reassembled!);
      expect(decoded, equals(testData));
    });
  });

  group('Transaction Size Verification', () {
    test('verifyTransactionSize for small batches', () {
      final chunks = List.generate(10, (i) => PhotoChunk(
        chunkIndex: i,
        totalChunks: 10,
        data: 'a' * 400,
        photoId: 'test_photo',
        cid: 'test_cid',
        seq: 1,
      ));
      
      expect(PhotoChunkingTestUtils.verifyTransactionSize(chunks), isTrue);
    });

    test('verifyTransactionSize for max batch size', () {
      final chunks = List.generate(PhotoEncoder.MAX_CHUNKS_PER_TX, (i) => PhotoChunk(
        chunkIndex: i,
        totalChunks: PhotoEncoder.MAX_CHUNKS_PER_TX,
        data: 'a' * 400,
        photoId: 'test_photo',
        cid: 'test_cid',
        seq: 1,
      ));
      
      final isValid = PhotoChunkingTestUtils.verifyTransactionSize(chunks);
      expect(isValid, isTrue); // Should pass if implementation is correct
    });
  });

  group('Integration Tests', () {
    test('simulatePhotoEncoding with small image', () async {
      // Create a small test image
      final image = img.Image(width: 100, height: 100);
      img.fill(image, color: img.ColorRgb8(255, 0, 0));
      final imageBytes = Uint8List.fromList(img.encodePng(image));
      
      final result = await PhotoChunkingTestUtils.simulatePhotoEncoding(
        imageBytes,
        'test_cid',
        1,
      );
      
      expect(result['success'], isTrue);
      expect(result['chunks'], greaterThan(0));
      expect(result['batches'], greaterThan(0));
      expect(result['maxBatchSize'], lessThan(1024 * 1024)); // Less than 1MB
    });

    test('testOutOfOrderReassembly', () async {
      final testData = 'a' * 2000; // Create multiple chunks
      final encoded = PhotoEncoder.encodeBase64Url(Uint8List.fromList(testData.codeUnits));
      final chunks = PhotoEncoder.chunkPhoto(encoded, 'test_cid', 1, 'test_photo_id');
      
      final success = await PhotoChunkingTestUtils.testOutOfOrderReassembly(chunks);
      expect(success, isTrue);
    });

    test('estimateTransactionFee calculates reasonable fees', () {
      final fee1 = PhotoChunkingTestUtils.estimateTransactionFee(10);
      final fee2 = PhotoChunkingTestUtils.estimateTransactionFee(200);
      
      expect(fee1, greaterThan(0));
      expect(fee2, greaterThan(fee1));
      expect(fee2, lessThan(100000)); // Should be reasonable (< 0.001 ZEC)
    });
  });

  group('Edge Cases', () {
    test('handle empty image data', () async {
      expect(() => PhotoEncoder.compressPhoto(Uint8List(0)), throwsException);
    });

    test('handle oversized image', () async {
      final hugeImage = Uint8List(PhotoEncoder.MAX_PHOTO_SIZE_BYTES + 1);
      expect(() => PhotoEncoder.compressPhoto(hugeImage), throwsException);
    });

    test('handle invalid chunk data', () {
      final invalidChunks = [
        PhotoChunk(chunkIndex: 0, totalChunks: 2, data: '', photoId: 'p1', cid: 'c1', seq: 1),
        PhotoChunk(chunkIndex: 1, totalChunks: 2, data: '', photoId: 'p1', cid: 'c1', seq: 1),
      ];
      
      // Empty chunks should still validate if structure is correct
      expect(PhotoDecoder.validateChunks(invalidChunks), isTrue);
    });
  });
}


