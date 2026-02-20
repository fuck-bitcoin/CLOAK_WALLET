/// Data models for photo chunking system

class PhotoChunk {
  final int chunkIndex;
  final int totalChunks;
  final String data; // Base64url chunk data
  final String photoId;
  final String cid;
  final int seq;
  final String? txId; // Optional transaction ID
  final int? chunkSize; // Optional chunk size
  
  PhotoChunk({
    required this.chunkIndex,
    required this.totalChunks,
    required this.data,
    required this.photoId,
    required this.cid,
    required this.seq,
    this.txId,
    this.chunkSize,
  });
}

class PhotoMetadata {
  final String photoId;
  final String cid;
  final int seq;
  final int totalChunks;
  final DateTime timestamp;
  
  PhotoMetadata({
    required this.photoId,
    required this.cid,
    required this.seq,
    required this.totalChunks,
    required this.timestamp,
  });
}

class PhotoDecodingState {
  final String photoId;
  final List<PhotoChunk> chunks;
  final bool isComplete;
  final DateTime lastUpdated;
  
  PhotoDecodingState({
    required this.photoId,
    required this.chunks,
    required this.isComplete,
    required this.lastUpdated,
  });
  
  double get progress {
    if (chunks.isEmpty) return 0.0;
    return chunks.length / chunks.first.totalChunks;
  }
}





