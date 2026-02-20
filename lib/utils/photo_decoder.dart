import 'dart:typed_data';
import 'dart:ui' as ui;
import 'dart:convert';
import '../pages/utils.dart';
import 'photo_models.dart';

/// Photo decoding and reassembly utility
class PhotoDecoder {
  /// Parse header from message body (reused from message_threads.dart pattern)
  static Map<String, String> _parseHeader(String body) {
    try {
      final firstLine = body.split('\n').first.trim();
      if (!firstLine.startsWith('v1;')) return const {};
      final parts = firstLine.split(';');
      final Map<String, String> m = {};
      for (final raw in parts) {
        final t = raw.trim();
        if (t.isEmpty) continue;
        final i = t.indexOf('=');
        if (i > 0) {
          final k = t.substring(0, i).trim();
          final v = t.substring(i + 1).trim();
          if (k.isNotEmpty) m[k] = v;
        }
      }
      return m;
    } catch (_) {
      return const {};
    }
  }
  
  /// Check if message is a photo chunk
  static bool isPhotoChunk(String? body) {
    if (body == null || body.isEmpty) return false;
    final header = _parseHeader(body);
    return header['type'] == 'photo_chunk';
  }
  
  /// Parse chunk from message
  static PhotoChunk? parseChunk(ZMessage msg) {
    if (!isPhotoChunk(msg.body)) return null;
    
    final header = _parseHeader(msg.body);
    final photoId = header['photo_id'];
    final chunkIndexStr = header['chunk_index'];
    final totalChunksStr = header['total_chunks'];
    final chunkSizeStr = header['chunk_size'];
    final cid = header['conversation_id'];
    final seqStr = header['seq'];
    
    if (photoId == null || chunkIndexStr == null || totalChunksStr == null || cid == null || seqStr == null) {
      return null;
    }
    
    // Extract chunk data (after header and blank line)
    final lines = msg.body.split('\n');
    String chunkData = '';
    if (lines.length > 2) {
      chunkData = lines.skip(2).join('\n');
    }
    
    return PhotoChunk(
      chunkIndex: int.tryParse(chunkIndexStr) ?? -1,
      totalChunks: int.tryParse(totalChunksStr) ?? 0,
      data: chunkData,
      photoId: photoId,
      cid: cid,
      seq: int.tryParse(seqStr) ?? 0,
      txId: msg.txId > 0 ? msg.txId.toString() : null,
      chunkSize: chunkSizeStr != null ? int.tryParse(chunkSizeStr) : null,
    );
  }
  
  /// Collect chunks by photo_id from message list
  static Map<String, List<PhotoChunk>> collectChunks(List<ZMessage> messages) {
    final Map<String, List<PhotoChunk>> chunksByPhoto = {};
    
    for (final msg in messages) {
      final chunk = parseChunk(msg);
      if (chunk == null) continue;
      
      chunksByPhoto.putIfAbsent(chunk.photoId, () => []).add(chunk);
    }
    
    return chunksByPhoto;
  }
  
  /// Validate chunks completeness
  static bool validateChunks(List<PhotoChunk> chunks) {
    if (chunks.isEmpty) return false;
    
    // Sort by chunk_index
    chunks.sort((a, b) => a.chunkIndex.compareTo(b.chunkIndex));
    
    final totalChunks = chunks.first.totalChunks;
    if (totalChunks <= 0) return false;
    
    // Check if we have all chunks
    if (chunks.length != totalChunks) return false;
    
    // Check index range and no duplicates
    final Set<int> seenIndices = {};
    for (final chunk in chunks) {
      if (chunk.chunkIndex < 0 || chunk.chunkIndex >= totalChunks) return false;
      if (seenIndices.contains(chunk.chunkIndex)) return false; // Duplicate
      seenIndices.add(chunk.chunkIndex);
    }
    
    // Verify all indices are present
    for (int i = 0; i < totalChunks; i++) {
      if (!seenIndices.contains(i)) return false;
    }
    
    return true;
  }
  
  /// Reassemble photo from chunks
  static Future<Uint8List?> reassemblePhoto(List<PhotoChunk> chunks) async {
    if (!validateChunks(chunks)) return null;
    
    try {
      // Sort by chunk_index
      chunks.sort((a, b) => a.chunkIndex.compareTo(b.chunkIndex));
      
      // Reassemble base64url string
      final base64UrlData = chunks.map((c) => c.data).join('');
      
      if (base64UrlData.isEmpty) return null;
      
      // Decode base64url → bytes
      // Add padding if needed for base64url decode
      String padded = base64UrlData;
      final remainder = padded.length % 4;
      if (remainder != 0) {
        padded += '=' * (4 - remainder);
      }
      
      try {
        return base64Decode(padded);
      } catch (e) {
        print('Base64 decode error: $e');
        return null;
      }
    } catch (e) {
      print('Reassemble error: $e');
      return null;
    }
  }
  
  /// Decode image bytes (JPEG, PNG, WebP) to displayable image
  /// Flutter's instantiateImageCodec auto-detects format (supports JPEG, PNG, GIF, WebP)
  static Future<ui.Image?> decodePhoto(Uint8List imageBytes) async {
    if (imageBytes.isEmpty) return null;
    
    try {
      // Flutter's image codec supports JPEG, PNG, GIF, and WebP automatically
      final codec = await ui.instantiateImageCodec(imageBytes);
      final frame = await codec.getNextFrame();
      return frame.image;
    } catch (e) {
      print('Image decode error: $e');
      return null;
    }
  }
}

