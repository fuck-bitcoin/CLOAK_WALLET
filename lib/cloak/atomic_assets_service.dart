// AtomicAssets NFT Metadata Service
// Fetches NFT metadata from the Telos AtomicAssets API and resolves IPFS image URLs.

import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

/// Telos AtomicAssets API endpoint
const String _atomicAssetsEndpoint =
    'https://telos.api.atomicassets.io/atomicassets/v1';

/// IPFS gateway for resolving CIDs to full URLs
const String _ipfsGateway = 'https://ipfs.io/ipfs/';

/// Structured NFT metadata parsed from an AtomicAssets API response.
class NftMetadata {
  final String assetId;
  final String name;
  final String collectionName;
  final String schemaName;
  final String? templateId;
  final String? imageUrl;
  final Map<String, dynamic> rawData;

  const NftMetadata({
    required this.assetId,
    required this.name,
    required this.collectionName,
    required this.schemaName,
    this.templateId,
    this.imageUrl,
    required this.rawData,
  });

  @override
  String toString() =>
      'NftMetadata(assetId=$assetId, name=$name, collection=$collectionName, image=$imageUrl)';
}

/// Singleton service that fetches and caches AtomicAssets NFT metadata.
///
/// Usage:
/// ```dart
/// final meta = await AtomicAssetsService.instance.fetch('12345');
/// if (meta != null) print(meta.imageUrl);
/// ```
class AtomicAssetsService {
  AtomicAssetsService._();
  static final AtomicAssetsService instance = AtomicAssetsService._();

  /// In-memory cache keyed by asset ID.
  final Map<String, NftMetadata> _cache = {};

  /// Fetch metadata for a single asset ID.
  /// Returns null on any failure (network error, 404, malformed JSON).
  Future<NftMetadata?> fetch(String assetId) async {
    final cached = _cache[assetId];
    if (cached != null) return cached;

    try {
      final url = Uri.parse('$_atomicAssetsEndpoint/assets/$assetId');
      debugPrint('[ATOMIC] Fetching $url');
      final response = await http.get(url);

      if (response.statusCode != 200) {
        debugPrint(
            '[ATOMIC] HTTP ${response.statusCode} for asset $assetId');
        return null;
      }

      final json = jsonDecode(response.body) as Map<String, dynamic>;
      if (json['success'] != true || json['data'] == null) {
        debugPrint('[ATOMIC] API returned success=false for asset $assetId');
        return null;
      }

      final data = json['data'] as Map<String, dynamic>;
      final meta = _parseAsset(data);
      if (meta != null) {
        _cache[assetId] = meta;
      }
      return meta;
    } catch (e) {
      debugPrint('[ATOMIC] Error fetching asset $assetId: $e');
      return null;
    }
  }

  /// Fetch metadata for multiple asset IDs in parallel.
  /// Returns a map of assetId -> NftMetadata for all successfully fetched assets.
  /// Missing or failed assets are omitted from the result.
  Future<Map<String, NftMetadata>> fetchMultiple(
      List<String> assetIds) async {
    final results = <String, NftMetadata>{};
    if (assetIds.isEmpty) return results;

    // Split into cached and uncached
    final uncached = <String>[];
    for (final id in assetIds) {
      final cached = _cache[id];
      if (cached != null) {
        results[id] = cached;
      } else {
        uncached.add(id);
      }
    }

    if (uncached.isEmpty) return results;

    // Fetch uncached assets in parallel
    final futures = uncached.map((id) => fetch(id));
    final fetched = await Future.wait(futures);

    for (var i = 0; i < uncached.length; i++) {
      final meta = fetched[i];
      if (meta != null) {
        results[uncached[i]] = meta;
      }
    }

    return results;
  }

  /// Return cached metadata for an asset ID without fetching.
  /// Returns null if the asset hasn't been fetched yet.
  NftMetadata? getCached(String assetId) => _cache[assetId];

  /// Clear the in-memory cache (e.g. on logout or refresh).
  void clearCache() {
    _cache.clear();
    debugPrint('[ATOMIC] Cache cleared');
  }

  /// Parse a single asset object from the AtomicAssets API response.
  NftMetadata? _parseAsset(Map<String, dynamic> data) {
    try {
      final assetId = data['asset_id']?.toString() ?? '';
      if (assetId.isEmpty) return null;

      final immutableData = data['immutable_data'] as Map<String, dynamic>? ?? {};
      final mutableData = data['mutable_data'] as Map<String, dynamic>? ?? {};
      final templateImmutableData =
          (data['template'] as Map<String, dynamic>?)?['immutable_data']
              as Map<String, dynamic>? ??
              {};

      // Merge data sources: template immutable < asset immutable < asset mutable
      // (later entries override earlier ones)
      final mergedData = <String, dynamic>{
        ...templateImmutableData,
        ...immutableData,
        ...mutableData,
      };

      final name = mergedData['name']?.toString() ?? 'Unnamed NFT';

      final collection =
          (data['collection'] as Map<String, dynamic>?)?['collection_name']
              ?.toString() ??
              '';
      final schema =
          (data['schema'] as Map<String, dynamic>?)?['schema_name']
              ?.toString() ??
              '';
      final templateId =
          (data['template'] as Map<String, dynamic>?)?['template_id']
              ?.toString();

      // Resolve image URL from the `img` field (could be a bare CID or a full URL)
      String? imageUrl;
      final img = mergedData['img']?.toString();
      if (img != null && img.isNotEmpty) {
        imageUrl = _resolveIpfsUrl(img);
      }
      // Fallback: some schemas use 'image' instead of 'img'
      if (imageUrl == null) {
        final image = mergedData['image']?.toString();
        if (image != null && image.isNotEmpty) {
          imageUrl = _resolveIpfsUrl(image);
        }
      }

      return NftMetadata(
        assetId: assetId,
        name: name,
        collectionName: collection,
        schemaName: schema,
        templateId: templateId,
        imageUrl: imageUrl,
        rawData: mergedData,
      );
    } catch (e) {
      debugPrint('[ATOMIC] Error parsing asset data: $e');
      return null;
    }
  }

  /// Convert a CID or IPFS URI to a full gateway URL.
  /// Handles: bare CID ("QmXyz..."), ipfs:// URI, or already-full HTTP URL.
  String _resolveIpfsUrl(String value) {
    if (value.startsWith('http://') || value.startsWith('https://')) {
      return value;
    }
    if (value.startsWith('ipfs://')) {
      return '$_ipfsGateway${value.substring(7)}';
    }
    // Bare CID (Qm... or bafy...)
    return '$_ipfsGateway$value';
  }
}
