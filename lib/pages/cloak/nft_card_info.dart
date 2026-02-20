import 'package:flutter/material.dart';

/// The back face of an NFT card in the lightbox — a trading-card-style
/// metadata table showing core attributes and custom rawData fields.
class NftCardInfo extends StatelessWidget {
  final String nftId;
  final String contract;
  final String? name;
  final String? collectionName;
  final String? imageUrl;
  final String? schemaName;
  final String? templateId;
  final Map<String, dynamic>? rawData;
  final VoidCallback? onFlipBack;

  const NftCardInfo({
    required this.nftId,
    required this.contract,
    this.name,
    this.collectionName,
    this.imageUrl,
    this.schemaName,
    this.templateId,
    this.rawData,
    this.onFlipBack,
    super.key,
  });

  /// Keys in rawData that are already displayed elsewhere (header / image).
  static const _excludedKeys = {'img', 'image', 'name'};

  @override
  Widget build(BuildContext context) {
    final filteredData = <String, String>{};
    if (rawData != null) {
      for (final entry in rawData!.entries) {
        if (_excludedKeys.contains(entry.key)) continue;
        final v = entry.value;
        if (v is String || v is int || v is double || v is bool) {
          filteredData[entry.key] = v.toString();
        }
      }
    }

    return Container(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(16),
        gradient: const LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [Color(0xFF1A1A2E), Color(0xFF252542)],
        ),
      ),
      clipBehavior: Clip.antiAlias,
      child: Stack(
        children: [
          // Scrollable metadata content
          Positioned.fill(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(20),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // Top-right clearance for flip button
                  const SizedBox(height: 4),

                  // ── Header ──
                  Text(
                    name ?? 'Unnamed NFT',
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 18,
                      fontWeight: FontWeight.bold,
                    ),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                  if (collectionName != null &&
                      collectionName!.isNotEmpty) ...[
                    const SizedBox(height: 4),
                    Text(
                      collectionName!,
                      style: TextStyle(
                        color: Colors.white.withOpacity(0.6),
                        fontSize: 13,
                      ),
                    ),
                  ],

                  const SizedBox(height: 12),
                  _divider(),
                  const SizedBox(height: 12),

                  // ── Core attributes ──
                  _attributeRow('ASSET ID', _truncate(nftId, 20)),
                  const SizedBox(height: 8),
                  _attributeRow('CONTRACT', contract),
                  if (schemaName != null && schemaName!.isNotEmpty) ...[
                    const SizedBox(height: 8),
                    _attributeRow('SCHEMA', schemaName!),
                  ],
                  if (templateId != null && templateId!.isNotEmpty) ...[
                    const SizedBox(height: 8),
                    _attributeRow('TEMPLATE', '#$templateId'),
                  ],

                  const SizedBox(height: 12),
                  _divider(),
                  const SizedBox(height: 12),

                  // ── Custom attributes from rawData ──
                  if (filteredData.isEmpty)
                    Text(
                      'No additional attributes',
                      style: TextStyle(
                        color: Colors.white.withOpacity(0.4),
                        fontSize: 12,
                        fontStyle: FontStyle.italic,
                      ),
                    )
                  else
                    ...filteredData.entries.map((e) {
                      return Padding(
                        padding: const EdgeInsets.only(bottom: 8),
                        child: _attributeRow(
                          e.key.toUpperCase(),
                          _truncate(e.value, 32),
                        ),
                      );
                    }),

                  const SizedBox(height: 16),
                ],
              ),
            ),
          ),

          // ── Flip-back button (top-right) ──
          if (onFlipBack != null)
            Positioned(
              top: 8,
              right: 8,
              child: GestureDetector(
                onTap: onFlipBack,
                child: Container(
                  width: 32,
                  height: 32,
                  decoration: BoxDecoration(
                    color: Colors.white.withOpacity(0.12),
                    shape: BoxShape.circle,
                  ),
                  child: Icon(
                    Icons.image_outlined,
                    size: 16,
                    color: Colors.white.withOpacity(0.8),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }

  /// A single label-value row in the two-column attribute table.
  static Widget _attributeRow(String label, String value) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: 90,
          child: Text(
            label,
            style: TextStyle(
              color: Colors.white.withOpacity(0.5),
              fontSize: 11,
              fontWeight: FontWeight.w500,
              letterSpacing: 0.5,
            ),
          ),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            value,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 13,
              fontWeight: FontWeight.w500,
            ),
            overflow: TextOverflow.ellipsis,
            maxLines: 2,
          ),
        ),
      ],
    );
  }

  /// Thin horizontal divider.
  static Widget _divider() {
    return Container(
      height: 1,
      color: Colors.white.withOpacity(0.1),
    );
  }

  /// Truncate [text] to [maxLen] characters, appending ellipsis if needed.
  static String _truncate(String text, int maxLen) {
    if (text.length <= maxLen) return text;
    return '${text.substring(0, maxLen)}...';
  }
}
