import '../store2.dart';
import '../accounts.dart';
import '../pages/utils.dart';
import '../cloak/cloak_db.dart';

// Internal: extract conversation_id from a ZMessage body header if present
String _extractConversationId(String? body) {
  try {
    if (body == null || body.isEmpty) return '';
    final first = body.split('\n').first.trim();
    if (!first.startsWith('v1;')) return '';
    for (final raw in first.split(';')) {
      final t = raw.trim();
      if (t.isEmpty) continue;
      final i = t.indexOf('=');
      if (i > 0) {
        final k = t.substring(0, i).trim();
        final v = t.substring(i + 1).trim();
        if (k == 'conversation_id') return v;
      }
    }
  } catch (_) {}
  return '';
}

// Internal: parse header from message body to extract type and other fields
Map<String, String> _parseHeader(String? body) {
  try {
    if (body == null || body.isEmpty) return const {};
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

// Mirrors Messages._threadKeyFor semantics for grouping
// Priority: CID first (for chat conversations), then ADDRESS (for legacy memos), then txId
String threadKeyForMessage(ZMessage m) {
  // Primary: group by conversation_id if present (ensures all chat messages stay together)
  // This handles the case where invite goes to address A but accept comes from address B
  try {
    final cid = _extractConversationId(m.body);
    if (cid.isNotEmpty) return 'cid::' + cid;
  } catch (_) {}
  // Fallback: group by counterparty address (for legacy memo-only messages without CID)
  // For incoming: use fromAddress, or extract reply_to_ua from headers if fromAddress is empty
  // For outgoing: use recipient
  try {
    String addr = '';
    if (m.incoming) {
      addr = (m.fromAddress ?? '').trim();
      // If fromAddress is empty, try to extract from message headers
      if (addr.isEmpty) {
        final hdr = _parseHeader(m.body);
        addr = (hdr['reply_to_ua'] ?? '').trim();
      }
    } else {
      addr = (m.recipient ?? '').trim();
    }
    if (addr.isNotEmpty) return 'addr::' + addr;
  } catch (_) {}
  return 'tx::' + m.txId.toString();
}

// Compute the zero-based index of a thread key in the Messages list ordering
// Sorting matches Messages: newest lastTimestamp per key first
// Priority: CID first (matches threadKeyForMessage), then ADDRESS
int computeThreadIndex(List<ZMessage> unionList, {String? cid, String? address}) {
  try {
    final Map<String, DateTime> lastByKey = {};
    for (final m in unionList) {
      try {
        final key = threadKeyForMessage(m);
        final ts = m.timestamp;
        final prev = lastByKey[key];
        if (prev == null || ts.isAfter(prev)) lastByKey[key] = ts;
      } catch (_) {}
    }
    final keys = lastByKey.keys.toList(growable: false);
    keys.sort((a, b) => (lastByKey[b] ?? DateTime.fromMillisecondsSinceEpoch(0))
        .compareTo(lastByKey[a] ?? DateTime.fromMillisecondsSinceEpoch(0)));
    String? targetKey;
    // CID-first priority (matches threadKeyForMessage)
    if (cid != null && cid.trim().isNotEmpty) {
      targetKey = 'cid::' + cid.trim();
    } else if (address != null && address.trim().isNotEmpty) {
      targetKey = 'addr::' + address.trim();
    }
    if (targetKey == null || targetKey.isEmpty) return -1;
    return keys.indexOf(targetKey);
  } catch (_) {
    return -1;
  }
}

// Unified thread detection result
class ThreadDetectionResult {
  final bool exists;
  final int? index;
  final String? cid;
  final bool hasOutgoingInvite;

  ThreadDetectionResult({
    required this.exists,
    this.index,
    this.cid,
    this.hasOutgoingInvite = false,
  });
}

// Build union list of DB messages and optimistic echoes, de-duped by header
List<ZMessage> buildUnionList() {
  try {
    final db = aa.messages.items;
    final Map<String, ZMessage> byHeader = {};
    for (final m in db) {
      try {
        final body = (m as dynamic).body as String?;
        if (body == null) continue;
        final first = body.split('\n').first.trim();
        if (!first.startsWith('v1;')) continue;
        byHeader[first] = m;
      } catch (_) {}
    }
    final list = db.toList();
    for (final e in optimisticEchoes) {
      try {
        final key = (e.body).split('\n').first.trim();
        if (key.startsWith('v1;') && !list.any((m) {
          try {
            final body = (m as dynamic).body as String?;
            return body != null && body.split('\n').first.trim() == key;
          } catch (_) {
            return false;
          }
        })) {
          list.add(e);
        }
      } catch (_) {}
    }
    return list;
  } catch (_) {
    return aa.messages.items;
  }
}

// Helper to get property for any coin
Future<String> _getPropertyAsync(int coin, String key) async {
  return await CloakDb.getProperty(key) ?? '';
}

// Helper to set property for any coin
Future<void> _setPropertyAsync(int coin, String key, String value) async {
  await CloakDb.setProperty(key, value);
}

// Synchronous version for use in sync contexts
// Returns empty; callers should prefer _getPropertyAsync when possible
String _getPropertySync(int coin, String key) {
  return '';
}

// Unified thread detection function that combines all detection criteria
// This is the single source of truth for determining if a thread exists
ThreadDetectionResult findThreadForContact(int contactId, String address, int coin) {
  try {
    // 1. Check for stored cid
    String storedCid = '';
    try {
      storedCid = _getPropertySync(coin, 'contact_cid_' + contactId.toString());
    } catch (_) {}

    // 2. Build union list of messages
    final unionList = buildUnionList();

    // 3. Check for evidence: messages with cid, address matches, invites
    bool addressEvidence = false;
    bool hasOutgoingInvite = false;
    bool hasIncomingInvite = false;
    bool cidMatchesMessages = false; // Track if stored CID has matching messages
    String? foundCid = storedCid.isNotEmpty ? storedCid : null;

    for (final m in unionList) {
      try {
        final incoming = ((m as dynamic).incoming as bool?) ?? false;
        final fromA = (m as dynamic).fromAddress as String?;
        final toA = (m as dynamic).recipient as String?;
        final from2 = (m as dynamic).from as String?;
        final to2 = (m as dynamic).to as String?;

        // Check message headers first (need reply_to_ua for invite matching)
        final body = (m as dynamic).body as String? ?? '';
        final hdr = _parseHeader(body);
        final t = (hdr['type'] ?? '').trim();
        final msgCid = (hdr['conversation_id'] ?? '').trim();
        final replyToUA = (hdr['reply_to_ua'] ?? '').trim();

        // Check address match (including reply_to_ua from invite headers)
        if ((fromA != null && fromA == address) || (toA != null && toA == address) ||
            (from2 != null && from2 == address) || (to2 != null && to2 == address) ||
            (replyToUA.isNotEmpty && replyToUA == address)) {
          addressEvidence = true;
        }

        // Check for cid in message
        if (msgCid.isNotEmpty) {
          if (storedCid.isNotEmpty && msgCid == storedCid) {
            // Stored CID matches a message - this is strong evidence
            foundCid = msgCid;
            cidMatchesMessages = true;
            addressEvidence = true;
          } else if (foundCid == null && msgCid.isNotEmpty) {
            // Found a cid in messages - only use it if this message matches the contact's address
            // This ensures we don't pick up CID from unrelated conversations
            // Include reply_to_ua from invite headers for matching
            bool messageMatchesAddress = (fromA != null && fromA == address) || 
                                        (toA != null && toA == address) ||
                                        (from2 != null && from2 == address) || 
                                        (to2 != null && to2 == address) ||
                                        (replyToUA.isNotEmpty && replyToUA == address);
            if (messageMatchesAddress) {
              foundCid = msgCid;
              // Also mark address evidence since this message matches
              addressEvidence = true;
            }
          }
        }

        // Check for outgoing invite
        if (!incoming && t == 'invite') {
          final targetAddr = (hdr['target_address'] ?? '').trim();
          if ((toA != null && toA == address) || targetAddr == address) {
            hasOutgoingInvite = true;
            if (msgCid.isNotEmpty) {
              foundCid = msgCid;
              // If stored CID matches invite CID, mark as matching
              if (storedCid.isNotEmpty && msgCid == storedCid) {
                cidMatchesMessages = true;
              }
            }
          }
        }

        // Check for incoming invite
        // IMPORTANT: Check reply_to_ua from invite header - this is the address that matches the contact!
        if (incoming && t == 'invite') {
          if ((fromA != null && fromA == address) || (from2 != null && from2 == address) ||
              (replyToUA.isNotEmpty && replyToUA == address)) {
            hasIncomingInvite = true;
            if (msgCid.isNotEmpty) {
              foundCid = msgCid;
              // If stored CID matches invite CID, mark as matching
              if (storedCid.isNotEmpty && msgCid == storedCid) {
                cidMatchesMessages = true;
              }
            }
          }
        }
      } catch (_) {}
    }

    // Thread exists if:
    // 1. Stored CID exists AND we found messages with that CID (cidMatchesMessages) - PRIMARY METHOD
    // 2. OR we have address evidence (messages matching contact address)
    // 3. OR we have invites (invite-only state, before accept)
    // PRIORITY: If stored CID exists, ONLY use CID-based detection (more robust)
    final bool threadExists;
    if (storedCid.isNotEmpty) {
      // CID-only detection: if stored CID exists, check if ANY message has that CID
      // This is more robust than address matching
      bool hasMessagesWithStoredCid = false;
      for (final m in unionList) {
        try {
          final body = (m as dynamic).body as String? ?? '';
          final hdr = _parseHeader(body);
          final msgCid = (hdr['conversation_id'] ?? '').trim();
          if (msgCid == storedCid) {
            hasMessagesWithStoredCid = true;
            foundCid = storedCid;
            break;
          }
        } catch (_) {}
      }
      threadExists = hasMessagesWithStoredCid || cidMatchesMessages;
    } else {
      // Fallback to address/invite matching if no stored CID
      threadExists = cidMatchesMessages || addressEvidence || hasOutgoingInvite || hasIncomingInvite;
    }

    // Persist cid if we found one in messages but it wasn't stored
    // Do this BEFORE checking thread existence so we have complete data
    // Also store CID when we find it matching messages, even if address matching failed
    if (foundCid != null && foundCid.isNotEmpty && storedCid.isEmpty) {
      final cidKey = 'contact_cid_' + contactId.toString();
      // Fire-and-forget async
      CloakDb.setProperty(cidKey, foundCid);
      // Update storedCid for subsequent checks
      storedCid = foundCid;
    }
    
    // If stored CID exists but wasn't found in messages, do a final scan
    // This handles edge cases where CID was stored but messages weren't matched properly
    if (storedCid.isNotEmpty && !cidMatchesMessages) {
      // Re-scan messages to see if stored CID exists in any message
      for (final m in unionList) {
        try {
          final body = (m as dynamic).body as String? ?? '';
          final hdr = _parseHeader(body);
          final msgCid = (hdr['conversation_id'] ?? '').trim();
          if (msgCid == storedCid) {
            cidMatchesMessages = true;
            foundCid = storedCid;
            break;
          }
        } catch (_) {}
      }
    }

    if (!threadExists) {
      return ThreadDetectionResult(exists: false);
    }

    // Calculate thread index
    int? threadIndex;
    try {
      threadIndex = computeThreadIndex(unionList, cid: foundCid, address: address);
      if (threadIndex < 0 && foundCid != null && foundCid.isNotEmpty) {
        // Fallback: try with just address if cid didn't match
        threadIndex = computeThreadIndex(unionList, address: address);
      }
    } catch (_) {}

    return ThreadDetectionResult(
      exists: true,
      index: threadIndex != null && threadIndex >= 0 ? threadIndex : null,
      cid: foundCid,
      hasOutgoingInvite: hasOutgoingInvite,
    );
  } catch (_) {
    return ThreadDetectionResult(exists: false);
  }
}





