import 'dart:typed_data';
import 'dart:convert';
import 'dart:math';
import 'dart:io';
import 'package:image/image.dart' as img;
import 'package:flutter_image_compress/flutter_image_compress.dart';
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as p;
import 'photo_models.dart';

/// Photo encoding and chunking utility
class PhotoEncoder {
  // Constants
  static const int MAX_CHUNK_SIZE = 400; // bytes payload after header
  static const int MAX_CHUNKS_PER_TX = 200; // Moderate option for transaction size
  static const int MAX_PHOTO_SIZE_BYTES = 2 * 1024 * 1024; // 2MB original size limit
  static const int DEFAULT_QUALITY = 70; // Compression quality (WebP/JPEG, reduced from 85 for smaller files)
  static const int MAX_DIMENSION = 1600; // Maximum width or height in pixels
  
  /// Resize image if it exceeds max dimensions while maintaining aspect ratio
  static img.Image _resizeIfNeeded(img.Image image) {
    final width = image.width;
    final height = image.height;
    
    // If both dimensions are within limits, return as-is
    if (width <= MAX_DIMENSION && height <= MAX_DIMENSION) {
      return image;
    }
    
    // Calculate new dimensions maintaining aspect ratio
    double aspectRatio = width / height;
    int newWidth, newHeight;
    
    if (width > height) {
      // Landscape: constrain width
      newWidth = MAX_DIMENSION;
      newHeight = (MAX_DIMENSION / aspectRatio).round();
    } else {
      // Portrait or square: constrain height
      newHeight = MAX_DIMENSION;
      newWidth = (MAX_DIMENSION * aspectRatio).round();
    }
    
    // Resize using nearest neighbor for speed (can use linear for better quality)
    return img.copyResize(image, width: newWidth, height: newHeight, interpolation: img.Interpolation.linear);
  }
  
  /// Compress photo to WebP (with JPEG fallback) with resizing and quality control
  /// Attempts WebP encoding first (better compression), falls back to JPEG if WebP not supported
  /// Uses flutter_image_compress for WebP (when available), image package for JPEG fallback
  static Future<Uint8List> compressPhoto(Uint8List imageBytes, {int quality = DEFAULT_QUALITY}) async {
    if (imageBytes.isEmpty) {
      throw Exception('Empty image data');
    }
    
    if (imageBytes.length > MAX_PHOTO_SIZE_BYTES) {
      throw Exception('Photo too large: ${imageBytes.length} bytes. Maximum: $MAX_PHOTO_SIZE_BYTES bytes');
    }
    
    // Decode and resize first using the image package
    img.Image? decoded;
    img.Image? resized;
    
    try {
      decoded = img.decodeImage(imageBytes);
      if (decoded == null) throw Exception('Invalid image format');
      
      // Resize if needed (before compression for better results)
      resized = _resizeIfNeeded(decoded);
    } catch (e) {
      if (e is Exception) rethrow;
      throw Exception('Failed to decode/resize image: $e');
    }
    
    // Try WebP encoding first (if supported), fall back to JPEG if not
    File? tempInputFile;
    File? tempOutputFile;
    
    try {
      // Get temporary directory
      final tempDir = await getTemporaryDirectory();
      final timestamp = DateTime.now().millisecondsSinceEpoch;
      final tempInputPath = p.join(tempDir.path, 'photo_input_$timestamp.jpg');
      final tempOutputPath = p.join(tempDir.path, 'photo_output_$timestamp.webp');
      
      tempInputFile = File(tempInputPath);
      tempOutputFile = File(tempOutputPath);
      
      // Write resized image as JPEG to temp file (flutter_image_compress can handle JPEG input)
      final jpegBytes = Uint8List.fromList(img.encodeJpg(resized, quality: 95));
      await tempInputFile.writeAsBytes(jpegBytes);
      
      // Try WebP compression first (may not be supported on all platforms)
      try {
        final result = await FlutterImageCompress.compressAndGetFile(
          tempInputFile.path,
          tempOutputPath,
          format: CompressFormat.webp,
          quality: quality,
          minWidth: resized.width,
          minHeight: resized.height,
          keepExif: false,
        );
        
        if (result != null) {
          final webpBytes = await result.readAsBytes();
          if (webpBytes.isNotEmpty) {
            return webpBytes; // Successfully compressed to WebP
          }
        }
      } catch (e) {
        // WebP not supported (UnimplementedError/UnsupportedError on Linux)
        // Fall through to JPEG fallback
        if (e is! UnimplementedError && e is! UnsupportedError) {
          // Re-throw if it's a different error
          rethrow;
        }
      }
      
      // Fallback to JPEG compression using image package (works everywhere)
      final compressed = Uint8List.fromList(img.encodeJpg(resized, quality: quality));
      
      if (compressed.isEmpty) {
        throw Exception('JPEG compression failed');
      }
      
      return compressed;
    } catch (e) {
      if (e is Exception) rethrow;
      throw Exception('Failed to compress photo: $e');
    } finally {
      // Clean up temporary files
      try {
        if (tempInputFile != null && await tempInputFile.exists()) {
          await tempInputFile.delete();
        }
      } catch (_) {}
      
      try {
        if (tempOutputFile != null && await tempOutputFile.exists()) {
          await tempOutputFile.delete();
        }
      } catch (_) {}
    }
  }
  
  /// Encode to base64url (no padding)
  static String encodeBase64Url(Uint8List bytes) {
    return base64UrlEncode(bytes).replaceAll('=', '');
  }
  
  /// Generate photo ID (UUID v4-like, base64url-encoded)
  static String generatePhotoId() {
    // Generate 16 random bytes
    final random = Random.secure();
    final bytes = Uint8List(16);
    for (int i = 0; i < 16; i++) {
      bytes[i] = random.nextInt(256);
    }
    // Set UUID v4 bits (version 4, variant 10)
    bytes[6] = (bytes[6] & 0x0f) | 0x40; // version 4
    bytes[8] = (bytes[8] & 0x3f) | 0x80; // variant 10
    return base64UrlEncode(bytes).replaceAll('=', '');
  }
  
  /// Calculate dynamic chunk size based on actual header length
  /// Returns the maximum payload size that will fit in a 512-byte memo
  static int calculateMaxPayloadSize(String cid, int seq, String photoId, int estimatedTotalChunks, int estimatedChunkSize) {
    // Build a sample header with actual values to measure its length
    final sampleHeader = 'v1; type=photo_chunk; conversation_id=$cid; seq=$seq; '
        'photo_id=$photoId; chunk_index=0; '
        'total_chunks=$estimatedTotalChunks; chunk_size=$estimatedChunkSize';
    final headerLength = sampleHeader.length;
    const separatorLength = 2; // '\n\n'
    
    // Calculate max payload size: 512 - header - separator
    final maxPayloadSize = 512 - headerLength - separatorLength;
    
    // Ensure we have at least some space for payload (safety check)
    if (maxPayloadSize < 50) {
      throw Exception('Header too long ($headerLength bytes). Memo would exceed 512-byte limit.');
    }
    
    return maxPayloadSize;
  }

  /// Chunk photo data into smaller pieces with dynamic sizing based on header length
  static List<PhotoChunk> chunkPhoto(String base64UrlData, String cid, int seq, String photoId) {
    final chunks = <PhotoChunk>[];
    
    // Use iterative approach to calculate optimal chunk size
    // We need to know totalChunks to build accurate headers, but totalChunks depends on chunk size
    int maxPayloadSize = 350; // Start conservative
    int totalChunks = 0;
    int previousTotalChunks = 0;
    
    // Iterate until we converge on a stable chunk size
    for (int iteration = 0; iteration < 10; iteration++) {
      totalChunks = (base64UrlData.length / maxPayloadSize).ceil();
      
      // If totalChunks hasn't changed, we've converged
      if (totalChunks == previousTotalChunks && iteration > 0) break;
      
      // Calculate max payload size with current totalChunks estimate
      // Use average chunk size for better estimation
      final avgChunkSize = (base64UrlData.length / totalChunks).ceil();
      maxPayloadSize = calculateMaxPayloadSize(cid, seq, photoId, totalChunks, avgChunkSize);
      
      previousTotalChunks = totalChunks;
    }
    
    // Final calculation of totalChunks
    totalChunks = (base64UrlData.length / maxPayloadSize).ceil();
    
    // Now create chunks with verified sizing
    for (int i = 0; i < totalChunks; i++) {
      final start = i * maxPayloadSize;
      final end = (start + maxPayloadSize).clamp(0, base64UrlData.length);
      var chunkData = base64UrlData.substring(start, end);
      
      // Build actual header to verify it fits
      final actualHeader = 'v1; type=photo_chunk; conversation_id=$cid; seq=$seq; '
          'photo_id=$photoId; chunk_index=$i; '
          'total_chunks=$totalChunks; chunk_size=${chunkData.length}';
      final headerLength = actualHeader.length;
      final maxAllowedPayload = 512 - headerLength - 2; // 2 for '\n\n'
      
      // Adjust chunk if it doesn't fit
      if (chunkData.length > maxAllowedPayload) {
        if (maxAllowedPayload < 1) {
          throw Exception('Header too long ($headerLength bytes). Cannot fit any payload for chunk $i.');
        }
        chunkData = chunkData.substring(0, maxAllowedPayload);
      }
      
      chunks.add(PhotoChunk(
        chunkIndex: i,
        totalChunks: totalChunks,
        data: chunkData,
        photoId: photoId,
        cid: cid,
        seq: seq,
        chunkSize: chunkData.length,
      ));
    }
    
    return chunks;
  }
  
  /// Build memo header for photo chunk
  static String buildChunkMemo(PhotoChunk chunk) {
    final header = 'v1; type=photo_chunk; conversation_id=${chunk.cid}; seq=${chunk.seq}; '
        'photo_id=${chunk.photoId}; chunk_index=${chunk.chunkIndex}; '
        'total_chunks=${chunk.totalChunks}; chunk_size=${chunk.chunkSize}';
    return '$header\n\n${chunk.data}';
  }
  
  /// Complete encoding pipeline: compress → encode → chunk
  static Future<List<PhotoChunk>> encodePhoto(
    Uint8List imageBytes,
    String cid,
    int seq, {
    int quality = DEFAULT_QUALITY,
  }) async {
    // 1. Compress to WebP (with automatic resizing if needed)
    final compressed = await compressPhoto(imageBytes, quality: quality);
    
    // 2. Encode to base64url
    final base64UrlData = encodeBase64Url(compressed);
    
    // 3. Generate photo ID
    final photoId = generatePhotoId();
    
    // 4. Chunk
    final chunks = chunkPhoto(base64UrlData, cid, seq, photoId);
    
    return chunks;
  }
}

