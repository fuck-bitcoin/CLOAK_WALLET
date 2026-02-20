import 'package:bubble/bubble.dart';
import 'package:flutter/material.dart';
import 'package:flutter_mobx/flutter_mobx.dart';
import 'package:gap/gap.dart';
import 'package:go_router/go_router.dart';
import 'package:warp_api/warp_api.dart';
import 'accounts/submit.dart';
import 'widgets.dart';
import 'package:warp_api/data_fb_generated.dart';
import '../cloak/cloak_wallet_manager.dart';
import '../cloak/cloak_db.dart';
import 'package:intl/intl.dart';
import 'dart:async';
import 'dart:math' as math;
import 'package:flutter_svg/flutter_svg.dart';
import 'dart:ui' as ui;
import 'package:flutter_svg/flutter_svg.dart' show SvgPicture;
import 'dart:io';
import 'package:file_picker/file_picker.dart';
import '../utils/photo_encoder.dart';
import '../utils/photo_models.dart';
import '../utils/photo_decoder.dart';
import 'accounts/send_photo.dart';
import 'messages/photo_viewer.dart';
import 'dart:typed_data';

import '../store2.dart';
import '../accounts.dart';
import '../appsettings.dart';
import '../generated/intl/messages.dart';
import '../tablelist.dart';
import '../../pages/accounts/send.dart';
import 'tx.dart';
import 'avatar.dart';
import 'utils.dart';
import 'widgets.dart';
import '../theme/zashi_tokens.dart';

// Request glyph copied from Receive page to use inside overlay action circle
const String _ZASHI_REQUEST_GLYPH_INLINE =
    '<svg width="36" height="36" viewBox="0 0 36 36" xmlns="http://www.w3.org/2000/svg">\n'
    '  <g transform="translate(1.8,1.8)">\n'
    '    <path d="M9.186 5.568C8.805 5.84 8.338 6 7.833 6C6.545 6 5.5 4.955 5.5 3.666C5.5 2.378 6.545 1.333 7.833 1.333C8.669 1.333 9.401 1.772 9.814 2.432M4.167 13.391H5.907C6.134 13.391 6.359 13.418 6.579 13.472L8.418 13.919C8.817 14.016 9.233 14.026 9.636 13.947L11.669 13.552C12.206 13.447 12.7 13.19 13.087 12.813L14.525 11.414C14.936 11.015 14.936 10.368 14.525 9.968C14.155 9.609 13.57 9.568 13.151 9.873L11.475 11.096C11.235 11.272 10.943 11.366 10.642 11.366H9.024L10.054 11.366C10.635 11.366 11.105 10.909 11.105 10.344V10.139C11.105 9.67 10.777 9.261 10.309 9.148L8.719 8.761C8.46 8.698 8.195 8.666 7.929 8.666C7.286 8.666 6.121 9.199 6.121 9.199L4.167 10.016M13.5 4.333C13.5 5.622 12.455 6.666 11.167 6.666C9.878 6.666 8.833 5.622 8.833 4.333C8.833 3.044 9.878 2 11.167 2C12.455 2 13.5 3.044 13.5 4.333ZM1.5 9.733L1.5 13.6C1.5 13.973 1.5 14.16 1.573 14.302C1.637 14.428 1.739 14.53 1.864 14.594C2.007 14.666 2.193 14.666 2.567 14.666H3.1C3.473 14.666 3.66 14.666 3.803 14.594C3.928 14.53 4.03 14.428 4.094 14.302C4.167 14.16 4.167 13.973 4.167 13.6V9.733C4.167 9.36 4.167 9.173 4.094 9.03C4.03 8.905 3.928 8.803 3.803 8.739C3.66 8.666 3.473 8.666 3.1 8.666L2.567 8.666C2.193 8.666 2.007 8.666 1.864 8.739C1.739 8.803 1.637 8.905 1.573 9.03C1.5 9.173 1.5 9.36 1.5 9.733Z" stroke="#231F20" stroke-width="1.33333" stroke-linecap="round" stroke-linejoin="round" fill="none"/>\n'
    '  </g>\n'
    '</svg>';

// Threaded conversations model (scoped to this file)
const double _threadAvatarRadius = 25.0;
const double _threadGap = 12.0;

// Feature flags for subtle entrance animations
const bool kEnableThreadFadeOnOpen = true;
const bool kEnableInviteEnterAnimation = true;
// Accept entrance flags and tunables
const bool kEnableAcceptEnterAnimation = true;
const bool kEnableAcceptThreadStageFade = true;
const int kAcceptFadeDelayMs = 100;
const int kAcceptFadeDurationMs = 320;
const int kAcceptEnterDelayMs = 140;
const int kAcceptEnterDurationMs = 400;
const double kAcceptSlidePx = 12.0;

// In-memory per-conversation next sequence to avoid duplicates during burst sends
final Map<String, int> _inFlightNextSeq = <String, int>{};

// Parse a v1 header from the first line of a memo body
Map<String, String> _parseHeaderFromBody(String body) {
  try {
    final firstLine = body.split('\n').first.trim();
    if (!firstLine.startsWith('v1;')) return const {};
    final Map<String, String> out = {};
    for (final part in firstLine.split(';')) {
      final t = part.trim();
      if (t.isEmpty) continue;
      final i = t.indexOf('=');
      if (i > 0) {
        final k = t.substring(0, i).trim();
        final v = t.substring(i + 1).trim();
        if (k.isNotEmpty) out[k] = v;
      }
    }
    return out;
  } catch (_) {
    return const {};
  }

}

  Map<String, Map<String, Set<String>>> _computeReactionAggregatesFromThread(MessageThread thread) {
    final List<ZMessage> list = thread.messages;
    final Map<String, List<ZMessage>> candidates = <String, List<ZMessage>>{};
    for (final m in list) {
      try {
        final h = _parseHeader(m);
        final t = (h['type'] ?? '').trim();
        if (t != 'invite' && t != 'accept' && t != 'message') continue;
        final cid = (h['conversation_id'] ?? '').trim();
        final seq = (h['seq'] ?? '').trim();
        if (cid.isEmpty || seq.isEmpty) continue;
        final key = cid + '::' + seq;
        final arr = candidates.putIfAbsent(key, () => <ZMessage>[]);
        arr.add(m);
      } catch (_) {}
    }
    candidates.updateAll((_, arr) {
      int rank(String t) {
        if (t == 'invite') return 0;
        if (t == 'message') return 1;
        if (t == 'accept') return 2;
        return 3;
      }
      arr.sort((a, b) {
        final ha = _parseHeader(a); final hb = _parseHeader(b);
        final ta = (ha['type'] ?? '').trim(); final tb = (hb['type'] ?? '').trim();
        final ra = rank(ta); final rb = rank(tb);
        if (ra != rb) return ra - rb;
        return 0;
      });
      return arr;
    });
    final Map<String, Map<String, Set<String>>> rxByBubble = <String, Map<String, Set<String>>>{};
    for (final rm in list) {
      try {
        final hdr = _parseHeader(rm);
        if ((hdr['type'] ?? '') != 'reaction') continue;
        final cid = (hdr['conversation_id'] ?? '').trim();
        final targetStr = (hdr['target_seq'] ?? '').trim();
        final token = (hdr['emoji'] ?? '').trim();
        final targetAuthor = ((hdr['target_author'] ?? '').trim());
        if (cid.isEmpty || targetStr.isEmpty || token.isEmpty) continue;
        ZMessage? targetMsg;
        final group = candidates[cid + '::' + targetStr];
        if (group != null && group.isNotEmpty) {
          if (targetAuthor == 'me' || targetAuthor == 'peer') {
            final preferIncoming = (targetAuthor == 'peer');
            targetMsg = group.firstWhere((gm) => gm.incoming == preferIncoming, orElse: () => group.first);
          } else {
            targetMsg = group.first;
          }
        }
        if (targetMsg == null) continue;
        final bubbleId = 'cid::' + cid + '#seq::' + targetStr + '#' + (targetMsg!.incoming ? 'in' : 'out');
        final senderKey = rm.incoming ? (((rm.sender ?? rm.fromAddress ?? '').trim().isEmpty) ? 'peer' : (rm.sender ?? rm.fromAddress ?? '').trim()) : 'me';
        if (senderKey.isEmpty) continue;
        final byToken = rxByBubble.putIfAbsent(bubbleId, () => <String, Set<String>>{});
        final set = byToken.putIfAbsent(token, () => <String>{});
        set.add(senderKey);
      } catch (_) {}
    }
    return rxByBubble;
  }

// Robust header parse: prefer body, then subject fallback
Map<String, String> _parseHeader(ZMessage m) {
  try {
    final hb = _parseHeaderFromBody((m.body).trim());
    if (hb.isNotEmpty) return hb;
  } catch (_) {}
  try {
    final hs = _parseHeaderFromBody((m.subject).trim());
    if (hs.isNotEmpty) return hs;
  } catch (_) {}
  return const {};
}

// Robust header key (first line) used for de-duping
String? _headerKeyOfMessage(ZMessage m) {
  try {
    final k1 = _headerKey((m as dynamic).body as String?);
    if (k1 != null) return k1;
  } catch (_) {}
  try {
    final k2 = _headerKey(((m as dynamic).subject) as String?);
    if (k2 != null) return k2;
  } catch (_) {}
  return null;
}

class MessageThread {
  final String key; // Stable key: counterparty address if available, else fallback
  final String title; // Contact name if available, else trimmed address/fallback
  final String? address; // Counterparty address when known
  final List<ZMessage> messages; // Sorted ascending by timestamp
  final int unreadCount;
  final DateTime lastTimestamp;

  MessageThread({
    required this.key,
    required this.title,
    required this.address,
    required this.messages,
    required this.unreadCount,
    required this.lastTimestamp,
  });
}

// Resolve contact name for an address (null if none)
String? _contactNameForAddress(String? address) {
  if (address == null || address.isEmpty) return null;
  try {
    for (final c in contacts.contacts) {
      final t = c.unpack();
      if (t.address == address) return (t.name ?? '').trim().isEmpty ? null : t.name!.trim();
    }
  } catch (_) {}
  return null;
}

// Generate a stable thread key for a message
// Priority: CID first (for chat conversations), then ADDRESS (for legacy memos), then txId
String _threadKeyFor(ZMessage m) {
  // Primary: group by conversation_id if present (ensures all chat messages stay together)
  // This handles the case where invite goes to address A but accept comes from address B
  try {
    final hdr = _parseHeader(m);
    final cid = (hdr['conversation_id'] ?? '').trim();
    if (cid.isNotEmpty) return 'cid::$cid';
  } catch (_) {}
  // Fallback: group by counterparty address (for legacy memo-only messages without CID)
  // For outgoing: use recipient
  // For incoming: use fromAddress, or extract reply_to_ua from headers if fromAddress is empty
  String addr = '';
  if (m.incoming) {
    addr = (m.fromAddress ?? '').trim();
    // If fromAddress is empty, try to extract from message headers
    if (addr.isEmpty) {
      try {
        final hdr = _parseHeader(m);
        addr = (hdr['reply_to_ua'] ?? '').trim();
      } catch (_) {}
    }
  } else {
    addr = (m.recipient ?? '').trim();
  }
  if (addr.isNotEmpty) return 'addr::$addr';
  // Last resort: group by tx id (isolated)
  return 'tx::${m.txId}';
}

// Build conversation threads from flat message list
List<MessageThread> _buildThreads(List<ZMessage> messages) {
  // Side effects: handshake contact upsert/update (idempotent)
  _processHandshake(messages);
  // Phase 2: prefer DB messages (txId > 0) over optimistic echoes (txId == 0) by header key
  final Map<String, ZMessage> bestByHeader = {};
  final List<ZMessage> passthrough = [];
  for (final m in messages) {
    final hk = _headerKeyOfMessage(m);
    if (hk == null) {
      passthrough.add(m);
      continue;
    }
    final prev = bestByHeader[hk];
    if (prev == null) {
      bestByHeader[hk] = m;
    } else {
      // Choose the one that has a real txId; if both have txId>0, keep the later timestamp
      if (m.txId > 0 && prev.txId == 0) {
        bestByHeader[hk] = m;
      } else if (m.txId > 0 && prev.txId > 0) {
        bestByHeader[hk] = (m.timestamp.isAfter(prev.timestamp)) ? m : prev;
      }
    }
  }
  final List<ZMessage> deduped = [...passthrough, ...bestByHeader.values];

  final Map<String, List<ZMessage>> byKey = {};
  for (final m in deduped) {
    final key = _threadKeyFor(m);
    (byKey[key] ??= []).add(m);
  }

  final List<MessageThread> threads = [];
  byKey.forEach((key, list) {
    // Sort ascending for chat view; we'll use last as preview
    list.sort((a, b) => a.timestamp.compareTo(b.timestamp));
    final last = list.isNotEmpty ? list.last : null;
    final String? address = () {
      // Prefer counterparty address (incoming: fromAddress or reply_to_ua from header, outgoing: recipient)
      for (final m in list.reversed) {
        String? v;
        if (m.incoming) {
          v = (m.fromAddress ?? '').trim();
          // If fromAddress is empty, try to extract from message headers
          if (v.isEmpty) {
            try {
              final hdr = _parseHeader(m);
              v = (hdr['reply_to_ua'] ?? '').trim();
            } catch (_) {}
          }
        } else {
          v = m.recipient;
        }
        if (v != null && v.isNotEmpty) return v;
      }
      return null;
    }();
    // Dynamic title resolution - like a phone: look up address in contacts NOW
    // If contact exists, show name. If not, show address.
    String displayAddress(String? a) {
      if (a == null || a.isEmpty) return '?';
      final len = a.length;
      final head = a.substring(0, len < 20 ? len : 20);
      return len > 20 ? '$head...' : head;
    }

    // For CID-based threads, try multiple sources to find contact name:
    // 1. cid_name_ property (set during handshake)
    // 2. Any address in the thread that matches a contact
    // 3. Fallback to displaying address
    String? contactName;
    
    // Extract CID from thread key if present
    String? threadCid;
    if (key.startsWith('cid::')) {
      threadCid = key.substring(5);
    }
    
    // First try: cid_name_ property for CID-based threads
    if (threadCid != null && threadCid.isNotEmpty) {
      try {
        final cidName = WarpApi.getProperty(aa.coin, 'cid_name_' + threadCid).trim();
        if (cidName.isNotEmpty) contactName = cidName;
      } catch (_) {}
    }
    
    // Second try: look up any address in the thread against contacts
    // Check ALL addresses in the thread (both incoming reply_to_ua and outgoing recipients)
    if (contactName == null) {
      try {
        // Collect all unique counterparty addresses from the thread
        final Set<String> allAddresses = {};
        for (final m in list) {
          if (m.incoming) {
            final from = (m.fromAddress ?? '').trim();
            if (from.isNotEmpty) allAddresses.add(from);
            // Also check reply_to_ua from header
            try {
              final hdr = _parseHeader(m);
              final replyTo = (hdr['reply_to_ua'] ?? '').trim();
              if (replyTo.isNotEmpty) allAddresses.add(replyTo);
            } catch (_) {}
          } else {
            final to = (m.recipient ?? '').trim();
            if (to.isNotEmpty) allAddresses.add(to);
          }
        }
        // Try each address until we find a contact match
        for (final addr in allAddresses) {
          final name = contacts.addressToName[addr];
          if (name != null && name.isNotEmpty) {
            contactName = name;
            break;
          }
        }
      } catch (_) {}
    }

    // Title: contact name if exists, else show address (like a phone)
    final title = contactName ?? displayAddress(address ?? (last?.sender ?? '?'));
    final unread = list.where((m) => !m.read).length;
    final ts = last?.timestamp ?? DateTime.fromMillisecondsSinceEpoch(0);
    threads.add(MessageThread(
      key: key,
      title: title,
      address: address,
      messages: list,
      unreadCount: unread,
      lastTimestamp: ts,
    ));
  });

  // Sort threads by most recent activity
  threads.sort((a, b) => b.lastTimestamp.compareTo(a.lastTimestamp));
  return threads;
}
String? _headerKey(String? body) {
  try {
    if (body == null) return null;
    final first = body.split('\n').first.trim();
    if (!first.startsWith('v1;')) return null;
    return first;
  } catch (_) {
    return null;
  }
}

void _processHandshake(List<ZMessage> messages) {
  // Property helpers for CLOAK vs WarpApi
  final isCloak = CloakWalletManager.isCloak(aa.coin);

  String getPropSync(String key) {
    if (isCloak) return ''; // CLOAK requires async, use message scanning instead
    try { return WarpApi.getProperty(aa.coin, key); } catch (_) { return ''; }
  }

  void setPropSync(String key, String value) {
    if (isCloak) {
      CloakDb.setProperty(key, value); // Fire and forget async
    } else {
      try { WarpApi.setProperty(aa.coin, key, value); } catch (_) {}
    }
  }

  void storeContactSync(int id, String name, String address, bool dirty) {
    if (isCloak) {
      if (id == 0) {
        CloakDb.addContact(name: name, address: address); // Fire and forget async
      } else {
        CloakDb.updateContact(id, name: name, address: address); // Fire and forget async
      }
    } else {
      try { WarpApi.storeContact(aa.coin, id, name, address, dirty); } catch (_) {}
    }
  }

  for (final m in messages) {
    try {
      final hdr = _parseHeader(m);
      if (hdr.isEmpty) continue;
      final type = (hdr['type'] ?? '').trim();
      final cid = (hdr['conversation_id'] ?? '').trim();
      final fn = (hdr['first_name'] ?? '').trim();
      final ln = (hdr['last_name'] ?? '').trim();
      final ua = (hdr['reply_to_ua'] ?? '').trim();
      if (cid.isEmpty || ua.isEmpty) continue;
      final name = (fn + ' ' + ln).trim();
      // Upsert: store cid mapping and per-contact UA/name
      try {
        // Only update reply target mapping from incoming headers
        // Outgoing headers include our own reply_to_ua and must not override the peer mapping
        if (m.incoming) {
          // Skip mapping if this conversation was explicitly blocked by user
          final blockedCID = getPropSync('cid_block_' + cid);
          if (blockedCID.trim() != '1') {
            setPropSync('cid_map_' + cid, ua);
          }
        }
      } catch (_) {}
      // For invite: do NOT create/update contacts; keep lightweight metadata only
      if (type == 'invite') {
        // Don't remember name for blocked conversation IDs
        try {
          final blockedCID = getPropSync('cid_block_' + cid);
          if (blockedCID.trim() == '1') { continue; }
        } catch (_) {}
        // If this CID has already been accepted, never overwrite the accepted title
        try {
          final done = getPropSync('cid_accept_done_' + cid).trim();
          if (done == '1') { continue; }
        } catch (_) {}
        // Title policy:
        // - For outgoing invites (we are the sender), use target_* name
        // - For incoming invites (we are the recipient), use sender first/last name
        String tfn = (hdr['target_first_name'] ?? '').trim();
        String tln = (hdr['target_last_name'] ?? '').trim();
        final targetName = (tfn + ' ' + tln).trim();
        final senderName = name;
        final preferTarget = !m.incoming; // outgoing
        final candidate = preferTarget ? targetName : senderName;
        final title = candidate.isNotEmpty && !_isAddressLike(candidate) ? candidate : (senderName);
        // Do not set cid_name_; titles are derived from contacts only
        continue;
      }
      // For accept (or legacy accept-as-message): create/update contact
      if (type == 'accept' || (type == 'message' && (hdr['in_reply_to_seq'] ?? '').isNotEmpty)) {
        // Only use incoming accepts to auto-create/rename contacts.
        // Outgoing accepts (sent by us) should not create a contact from our own header.
        if (!m.incoming) {
          continue;
        }
        // Respect user deletion: if this UA or CID was blocked, do not recreate
        try {
          final blocked = getPropSync('contact_block_' + ua);
          if (blocked.trim() == '1') {
            continue;
          }
          final blockedCID = getPropSync('cid_block_' + cid);
          if (blockedCID.trim() == '1') {
            continue;
          }
        } catch (_) {}

        // Idempotency: allow rename if header name is valid and differs, even if sticky is set
        bool alreadyProcessed = false;
        try { alreadyProcessed = getPropSync('cid_accept_done_' + cid).trim() == '1'; } catch (_) {}
        // Prefer updating the original invite contact (sender side): locate by conversation_id or stored inviter contact id
        int? contactIdByCid;
        try {
          final idStr = getPropSync('cid_inviter_contact_id_' + cid).trim();
          final idVal = int.tryParse(idStr);
          if (idVal != null && idVal > 0) contactIdByCid = idVal;
        } catch (_) {}
        // For CLOAK, find contact by CID from messages instead of property lookup
        if (!isCloak) {
          try {
            for (final c in contacts.contacts) {
              final t = c.unpack();
              try {
                final pcid = WarpApi.getProperty(aa.coin, 'contact_cid_' + t.id.toString()).trim();
                if (pcid == cid) { contactIdByCid = t.id; break; }
              } catch (_) {}
            }
          } catch (_) {}
        }

        // Persist cid on the inviter contact id when found so Contact Info can trust contact_cid_<id>
        try { if (contactIdByCid != null) { setPropSync('contact_cid_' + contactIdByCid.toString(), cid); } } catch (_) {}

        // Choose target contact id: by-cid if found, else by-UA if matching existing
        int? existingId;
        String existingName = '';
        if (contactIdByCid != null) {
          existingId = contactIdByCid;
          try {
            for (final c in contacts.contacts) {
              if (c.id == existingId) { existingName = (c.unpack().name ?? '').trim(); break; }
            }
          } catch (_) {}
        } else {
          try {
            for (final c in contacts.contacts) {
              final t = c.unpack();
              if ((t.address ?? '').trim() == ua) { existingId = t.id; existingName = (t.name ?? '').trim(); break; }
            }
          } catch (_) {}
        }

        // Build desired name from header if valid; otherwise preserve existing name
        final validHeaderName = (name.isNotEmpty && !_isAddressLike(name)) ? name : '';
        final newName = validHeaderName.isNotEmpty ? validHeaderName : existingName;

        // Note: native layer has retry/backoff; perform single calls here

        // Privacy-preserving contact update:
        // When we receive an accept, the peer sends us their NEW reply_to_ua address.
        // We should UPDATE the existing contact (found by CID or original address) with the new address.
        // Do NOT delete + create new - that causes duplicates and loses the contact relationship.
        
        // 1) Find the original contact to update (by CID mapping, inviter contact id, or target address)
        int? originalContactId;
        String originalContactName = '';
        
        // First try: by CID mapping (most reliable)
        if (contactIdByCid != null) {
          originalContactId = contactIdByCid;
          try {
            for (final c in contacts.contacts) {
              if (c.id == originalContactId) { originalContactName = (c.unpack().name ?? '').trim(); break; }
            }
          } catch (_) {}
        }
        
        // Second try: find by the original target_address from the outgoing invite
        if (originalContactId == null) {
          try {
            String targetAddr = '';
            for (final im in messages) {
              try {
                final ih = _parseHeader(im);
                if ((ih['type'] ?? '') == 'invite' && (ih['conversation_id'] ?? '') == cid && !im.incoming) {
                  targetAddr = (ih['target_address'] ?? '').trim();
                  break;
                }
              } catch (_) {}
            }
            if (targetAddr.isNotEmpty) {
              for (final c in contacts.contacts) {
                final t = c.unpack();
                if ((t.address ?? '').trim() == targetAddr) {
                  originalContactId = t.id;
                  originalContactName = (t.name ?? '').trim();
                  break;
                }
              }
            }
          } catch (_) {}
        }
        
        // Third try: by cid_name_ property (find contact by name)
        if (originalContactId == null && !isCloak) {
          try {
            String cidTitle = '';
            try { cidTitle = WarpApi.getProperty(aa.coin, 'cid_name_' + cid).trim(); } catch (_) {}
            if (cidTitle.isNotEmpty) {
              for (final c in contacts.contacts) {
                final t = c.unpack();
                if ((t.name ?? '').trim() == cidTitle) {
                  originalContactId = t.id;
                  originalContactName = cidTitle;
                  break;
                }
              }
            }
          } catch (_) {}
        }

        // 2) Update the contact with the new reply_to_ua address
        final contactName = validHeaderName.isNotEmpty ? validHeaderName : (originalContactName.isNotEmpty ? originalContactName : ua);

        if (alreadyProcessed) {
          // Already processed: only update if we found the original contact AND name changed
          if (originalContactId != null && validHeaderName.isNotEmpty && validHeaderName != originalContactName) {
            storeContactSync(originalContactId, validHeaderName, ua, true);
          }
          // If already processed, do NOT create new contacts - skip
        } else {
          // First time processing: UPDATE existing contact with new address, or create if not found
          if (originalContactId != null) {
            // Update existing contact with new reply_to_ua address
            storeContactSync(originalContactId, contactName, ua, true);
          } else {
            // No existing contact found - create new one
            storeContactSync(0, contactName, ua, true);
          }
        }
        
        // Use the original contact ID for CID mapping, or find the newly created one
        int? upsertId = originalContactId;

        // Ensure CID is stored on the final contact so Chat button can find the thread
        // This is critical: the contact that gets updated/created must have the CID stored
        try {
          int? finalContactId = upsertId;
          if (finalContactId == null) {
            // If new contact was created, refresh contacts and find it by address
            try { contacts.fetchContacts(); } catch (_) {}
            for (final c in contacts.contacts) {
              final t = c.unpack();
              if ((t.address ?? '').trim() == ua) {
                finalContactId = t.id;
                break;
              }
            }
          }
          // Also check if contactIdByCid is different from upsertId - store CID on both if needed
          if (contactIdByCid != null && contactIdByCid != finalContactId) {
            // Store CID on original invite contact (already done above, but ensure it's there)
            setPropSync('contact_cid_' + contactIdByCid.toString(), cid);
          }
          // Store CID on the final contact (the one that was created/updated from accept)
          // CRITICAL: Always store CID if we have a finalContactId, even if it's null we should try to find it
          if (finalContactId != null) {
            setPropSync('contact_cid_' + finalContactId.toString(), cid);
          } else if (cid.isNotEmpty) {
            // Fallback: if we couldn't find finalContactId, try to find it by address after refresh
            try { contacts.fetchContacts(); } catch (_) {}
            for (final c in contacts.contacts) {
              final t = c.unpack();
              if ((t.address ?? '').trim() == ua) {
                setPropSync('contact_cid_' + t.id.toString(), cid);
                break;
              }
            }
          }
        } catch (_) {}

        // Clear preserved invite name; titles are contact-derived
        setPropSync('cid_invite_name_' + cid, '');
        try { aaSequence.seqno = DateTime.now().microsecondsSinceEpoch; } catch (_) {}
        // Mark this cid as processed to avoid repeated creation on subsequent rebuilds
        setPropSync('cid_accept_done_' + cid, '1');

        try { contacts.fetchContacts(); } catch (_) {}
      }
    } catch (_) {}
  }
  try { contacts.fetchContacts(); } catch (_) {}
}

bool _isAddressLike(String s) {
  final v = s.trim();
  if (v.isEmpty) return false;
  if (v.length >= 14 && (v.startsWith('u1') || v.startsWith('uo') || v.startsWith('zs') || v.startsWith('t1'))) return true;
  // crude check for long base32/58-like strings
  final addrLike = RegExp(r'^[a-z0-9]+$', caseSensitive: false);
  if (v.length > 24 && addrLike.hasMatch(v.replaceAll(RegExp(r'[^A-Za-z0-9]'), ''))) return true;
  return false;
}

class MessagePage extends StatefulWidget {
  @override
  State<MessagePage> createState() => _MessagePageState();
}

class _MessagePageState extends State<MessagePage> {
  final TextEditingController _searchCtl = TextEditingController();
  String _query = '';
  // Defer heavy thread build until after first frame for smoother first open
  List<MessageThread> _threads = <MessageThread>[];
  bool _threadsReady = false;
  bool _threadBuildScheduled = false;
  int _lastUnionCount = -1;
  int _lastContactsCount = -1; // Track contacts count to detect changes

  @override
  void dispose() {
    _searchCtl.dispose();
    super.dispose();
  }

  List<MessageThread> _filterThreads(List<MessageThread> threads, String q) {
    final String query = q.trim().toLowerCase();
    if (query.isEmpty) return threads;
    bool contains(String? s) => (s ?? '').toLowerCase().contains(query);
    return threads.where((th) {
      if (contains(th.title) || contains(th.address)) return true;
      for (final m in th.messages) {
        if (contains(m.subject) || contains(m.body) || contains(m.sender) || contains(m.fromto())) {
          return true;
        }
      }
      return false;
    }).toList();
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final balanceFontFamily = t.textTheme.displaySmall?.fontFamily;
    final themed = t.copyWith(
      textTheme: t.textTheme.apply(fontFamily: balanceFontFamily),
    );
    const Color searchFill = Color(0xFF2E2C2C);
    final Color onSurf = t.colorScheme.onSurface;

    return Theme(
      data: themed,
      child: SortSetting(
        child: Observer(
          builder: (context) {
            try {
              aaSequence.seqno;
              aaSequence.settingsSeqno;
              syncStatus2.changed;
              // Watch message list for real-time updates
              final _ = aa.messages.items.length;
              // Watch optimistic echoes for immediate send feedback
              final __ = optimisticEchoes.length;
              // Rebuild when contacts change (add/delete/rename)
              final currentContactsCount = contacts.contacts.length;
              // Union DB messages with optimistic echoes, de-duped by header
              final List<ZMessage> unionList = () {
                try {
                  final db = aa.messages.items;
                  final Map<String, ZMessage> byHeader = {};
                  for (final m in db) {
                    final k = _headerKeyOfMessage(m);
                    if (k != null) byHeader[k] = m;
                  }
                  for (final e in optimisticEchoes) {
                    final k = _headerKeyOfMessage(e);
                    if (k == null) continue;
                    byHeader.putIfAbsent(k, () => e);
                  }
                  final list = db.toList();
                  for (final e in optimisticEchoes) {
                    final k = _headerKeyOfMessage(e);
                    if (k != null && !list.any((m) => _headerKeyOfMessage(m) == k)) {
                      list.add(e);
                    }
                  }
                  return list;
                } catch (_) {
                  return aa.messages.items;
                }
              }();
              // Defer building threads to after first frame to avoid jank on first open
              // Rebuild when: first build, messages changed, OR contacts changed
              final contactsChanged = _lastContactsCount != currentContactsCount;
              if (!_threadBuildScheduled && (!_threadsReady || _lastUnionCount != unionList.length || contactsChanged)) {
                _threadBuildScheduled = true;
                WidgetsBinding.instance.addPostFrameCallback((_) async {
                  try { await Future.delayed(const Duration(milliseconds: 120)); } catch (_) {}
                  if (!mounted) return;
                  final built = _buildThreads(unionList);
                  if (!mounted) return;
                  setState(() {
                    _threads = built;
                    _threadsReady = true;
                    _lastUnionCount = unionList.length;
                    _lastContactsCount = currentContactsCount;
                    _threadBuildScheduled = false;
                  });
                });
              }
              final filtered = _filterThreads(_threads, _query);
              return Column(
                children: [
                  // Match header/footer background across messages page
                  Container(height: 0, color: const Color(0xFF2E2C2C)),
                  Padding(
                    padding: EdgeInsets.fromLTRB(16, 8, 16, 8),
                    child: TextField(
                      controller: _searchCtl,
                      onChanged: (v) => setState(() => _query = v),
                      textInputAction: TextInputAction.search,
                      cursorColor: onSurf,
                      decoration: InputDecoration(
                        hintText: 'Search messages',
                        prefixIcon: Icon(Icons.search, color: onSurf.withOpacity(0.85)),
                        suffixIcon: _query.isEmpty
                            ? null
                            : IconButton(
                                icon: Icon(Icons.close, color: onSurf.withOpacity(0.85)),
                                onPressed: () {
                                  _searchCtl.clear();
                                  setState(() => _query = '');
                                },
                              ),
                        filled: true,
                        fillColor: searchFill,
                        contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
                        border: OutlineInputBorder(borderRadius: BorderRadius.circular(14), borderSide: BorderSide.none),
                        enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(14), borderSide: BorderSide.none),
                        focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(14), borderSide: BorderSide.none),
                      ),
                      style: (t.textTheme.bodyMedium ?? const TextStyle()).copyWith(color: onSurf),
                    ),
                  ),
                  Expanded(child: Builder(builder: (context) {
                    if (!_threadsReady) {
                      // Lightweight placeholder while threads are being built
                      return Center(child: SizedBox(width: 24, height: 24, child: CircularProgressIndicator(strokeWidth: 2)));
                    }
                    return TableListPage<MessageThread, TableListThreadMetadata>(
                      listKey: PageStorageKey('messages'),
                      padding: EdgeInsets.fromLTRB(16, 0, 16, 8),
                      view: appSettings.messageView,
                      items: filtered,
                      metadata: TableListThreadMetadata(),
                    );
                  })),
                ],
              );
            } catch (e, st) {
              try { logger.e('MessagePage Observer build error: ' + e.toString() + '\n' + st.toString()); } catch (_) {}
              return Center(child: Text('Unable to display messages'));
            }
          },
      ),
    ),
  );
  }
}

class TableListThreadMetadata extends TableListItemMetadata<MessageThread> {
  @override
  List<Widget>? actions(BuildContext context) => null;

  @override
  Text? headerText(BuildContext context) => null;

  @override
  void inverseSelection() {}

  @override
  Widget toListTile(BuildContext context, int index, MessageThread thread,
      {void Function(void Function())? setState}) {
    final t = Theme.of(context);
    final textTheme = t.textTheme;
    // Compute a live title so contact deletes/renames reflect immediately
    // Pure phone-like behavior: address → contact name, or show address
    String _liveDisplayAddress(String? a) {
      if (a == null || a.isEmpty) return '?';
      final len = a.length;
      final head = a.substring(0, len < 20 ? len : 20);
      return len > 20 ? '$head...' : head;
    }
    String _liveTitleFor(MessageThread t) {
      // Simple dynamic lookup: address → contact name (if exists) → else show address
      try {
        final addr = (t.address ?? '').trim();
        if (addr.isNotEmpty) {
          final name = contacts.addressToName[addr];
          if (name != null && name.trim().isNotEmpty) return name.trim();
        }
      } catch (_) {}
      // No contact for this address - show the address (like a phone)
      return _liveDisplayAddress(t.address);
    }
    final liveTitle = _liveTitleFor(thread);
    final initial = (liveTitle.isEmpty ? '?' : liveTitle[0]);
    final av = avatar(initial, radius: _threadAvatarRadius);
    final last = thread.messages.isNotEmpty ? thread.messages.last : null;
    String dateString = '';
    if (last != null) {
      final now = DateTime.now();
      final msg = last.timestamp.toLocal();
      final today = DateTime(now.year, now.month, now.day);
      final msgDay = DateTime(msg.year, msg.month, msg.day);
      final diffDays = today.difference(msgDay).inDays;
      if (diffDays == 0) {
        dateString = DateFormat('h:mma').format(msg);
      } else if (diffDays == 1) {
        dateString = 'Yesterday';
      } else if (diffDays >= 2 && diffDays <= 6) {
        dateString = DateFormat('EEEE').format(msg);
      } else {
        dateString = DateFormat('M/d/yyyy').format(msg);
      }
    }
    String _stripHeaderForPreview(String text) {
      try {
        final lines = text.split('\n');
        if (lines.isNotEmpty && lines.first.trim().startsWith('v1;')) {
          if (lines.length > 1 && lines[1].trim().isEmpty) {
            return lines.skip(2).join('\n').trim();
          }
          return lines.skip(1).join('\n').trim();
        }
      } catch (_) {}
      return text.trim();
    }

    String _statusSuffixFor(ZMessage m) {
      try {
        final h = _parseHeader(m);
        final t = (h['type'] ?? '').trim();
        if (t == 'request') return 'ZEC REQUEST';
        if (t == 'payment') return m.incoming ? 'ZEC RECEIVED' : 'ZEC SENT';
      } catch (_) {}
      return '';
    }

    final previewCore = () {
      if (last == null) return '';
      final hasSubject = last.subject.isNotEmpty;
      final bodyOnly = _stripHeaderForPreview(last.body);
      final core = (hasSubject ? ('${last.subject} — ${bodyOnly}') : bodyOnly).trim();
      return core;
    }();
    final statusSuffix = (last == null) ? '' : _statusSuffixFor(last);

    final balanceColor = t.extension<ZashiThemeExt>()?.balanceAmountColor ??
        (textTheme.displaySmall?.color ?? t.colorScheme.onSurface);

    final unreadBadge = thread.unreadCount > 0
        ? Container(
            padding: EdgeInsets.symmetric(horizontal: 8, vertical: 2),
            decoration: BoxDecoration(
              color: t.colorScheme.primary,
              borderRadius: BorderRadius.circular(12),
            ),
            child: Text('${thread.unreadCount}',
                style: textTheme.labelSmall?.copyWith(color: t.colorScheme.onPrimary)),
          )
        : const SizedBox.shrink();

    final body = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          liveTitle,
          style: textTheme.titleMedium?.copyWith(color: Colors.white),
          overflow: TextOverflow.ellipsis,
        ),
        Gap(4),
        Text(
          previewCore,
          style: textTheme.bodyMedium?.copyWith(
              fontWeight: FontWeight.w400, color: balanceColor),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        // Always reserve a second line: show status when present, else keep empty spacer for consistent layout
        Text(
          statusSuffix,
          style: textTheme.labelSmall?.copyWith(
            fontWeight: FontWeight.w600,
            color: balanceColor,
          ),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
      ],
    );

    return Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: () async {
            // Small pre-push delay to let ripple render and warm caches
            await Future.delayed(const Duration(milliseconds: 150));
            // Pass prebuilt thread to detail page to avoid recompute on open
            GoRouter.of(context).push('/messages/details?index=$index', extra: thread);
          },
          child: Padding(
            padding: EdgeInsets.symmetric(vertical: 8),
            child: Row(children: [
              av,
              Gap(_threadGap),
              Expanded(child: body),
              Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        dateString,
                        textAlign: TextAlign.right,
                        style: textTheme.labelMedium?.copyWith(
                            fontWeight: FontWeight.w400, color: balanceColor),
                      ),
                      SizedBox(width: 6),
                      Icon(Icons.chevron_right, size: 18, color: balanceColor),
                    ],
                  ),
                  Gap(6),
                  unreadBadge,
                ],
              )
            ]),
          ),
        ));
  }

  @override
  List<ColumnDefinition> columns(BuildContext context) {
    final s = S.of(context);
    // No sort fields to keep implementation simple and deterministic
    return [
      ColumnDefinition(label: s.messages),
      ColumnDefinition(label: s.body),
      ColumnDefinition(label: s.datetime),
    ];
  }

  @override
  DataRow toRow(BuildContext context, int index, MessageThread thread) {
    final t = Theme.of(context);
    final style = t.textTheme.bodyMedium!;
    final last = thread.messages.isNotEmpty ? thread.messages.last : null;
    final when = last != null ? msgDateFormat.format(last.timestamp) : '';
    String _stripHeaderForPreview(String text) {
      try {
        final lines = text.split('\n');
        if (lines.isNotEmpty && lines.first.trim().startsWith('v1;')) {
          if (lines.length > 1 && lines[1].trim().isEmpty) {
            return lines.skip(2).join('\n').trim();
          }
          return lines.skip(1).join('\n').trim();
        }
      } catch (_) {}
      return text.trim();
    }
    String _statusSuffixFor(ZMessage m) {
      try {
        final h = _parseHeader(m);
        final t = (h['type'] ?? '').trim();
        if (t == 'request') return ' - ZEC REQUEST';
        if (t == 'payment') return m.incoming ? ' - ZEC RECEIVED' : ' - ZEC SENT';
      } catch (_) {}
      return '';
    }
    final preview = () {
      if (last == null) return '';
      final hasSubject = last.subject.isNotEmpty;
      final bodyOnly = _stripHeaderForPreview(last.body);
      final core = (hasSubject ? ('${last.subject} — ${bodyOnly}') : bodyOnly).trim();
      return core;
    }();
    return DataRow.byIndex(
        index: index,
        cells: [
          DataCell(Text(thread.title, style: style)),
          DataCell(Text(preview, style: style)),
          DataCell(Text(when, style: style)),
        ],
        onSelectChanged: (_) {
          GoRouter.of(context).push('/messages/details?index=$index');
        });
  }

  @override
  SortConfig2? sortBy(String field) {
    // Sorting not wired for threads (list already sorted by lastTimestamp)
    return null;
  }

  @override
  Widget? header(BuildContext context) => null;

  @override
  Widget separator(BuildContext context) {
    // Bring divider closer to the avatar by reducing left indent
    final left = _threadAvatarRadius * 2 + _threadGap;
    return Padding(
      padding: EdgeInsets.only(left: left),
      child: const Divider(height: 1),
    );
  }
}

class TableListMessageMetadata extends TableListItemMetadata<ZMessage> {
  @override
  List<Widget>? actions(BuildContext context) => null;

  @override
  Text? headerText(BuildContext context) => null;

  @override
  void inverseSelection() {}

  @override
  Widget toListTile(BuildContext context, int index, ZMessage message,
      {void Function(void Function())? setState}) {
    return MessageBubble(message, index: index);
  }

  @override
  List<ColumnDefinition> columns(BuildContext context) {
    final s = S.of(context);
    return [
      ColumnDefinition(label: s.datetime),
      ColumnDefinition(label: s.fromto),
      ColumnDefinition(label: s.subject),
      ColumnDefinition(label: s.body),
    ];
  }

  @override
  DataRow toRow(BuildContext context, int index, ZMessage message) {
    final t = Theme.of(context);
    var style = t.textTheme.bodyMedium!;
    if (!message.read) style = style.copyWith(fontWeight: FontWeight.bold);
    final addressStyle = message.incoming
        ? style.apply(color: Colors.green)
        : style.apply(color: Colors.red);
    return DataRow.byIndex(
        index: index,
        cells: [
          DataCell(
              Text("${msgDateFormat.format(message.timestamp)}", style: style)),
          DataCell(Text("${message.fromto()}", style: addressStyle)),
          DataCell(Text("${message.subject}", style: style)),
          DataCell(Text("${message.body}", style: style)),
        ],
        onSelectChanged: (_) {
          GoRouter.of(context).push('/messages/details?index=$index');
        });
  }

  @override
  SortConfig2? sortBy(String field) {
    aa.messages.setSortOrder(field);
    return aa.messages.order;
  }

  @override
  Widget? header(BuildContext context) => null;
}

class MessageBubble extends StatelessWidget {
  final ZMessage message;
  final int index;
  MessageBubble(this.message, {required this.index});

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final date = humanizeDateTime(context, message.timestamp);
    final owner = centerTrim(
        (message.incoming ? message.sender : message.recipient) ?? '',
        length: 8);
    return GestureDetector(
        onTap: () => select(context),
        child: Bubble(
          nip: message.incoming ? BubbleNip.leftTop : BubbleNip.rightTop,
          color: message.incoming
              ? t.colorScheme.inversePrimary
              : t.colorScheme.secondaryContainer,
          child:
              Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Stack(children: [
              Text(owner, style: t.textTheme.labelMedium),
              Align(child: Text(message.subject, style: t.textTheme.bodyLarge)),
              Align(
                  alignment: Alignment.centerRight,
                  child: Text(date, style: t.textTheme.labelMedium)),
            ]),
            Gap(8),
            Text(
              message.body,
            ),
          ]),
        ));
  }

  select(BuildContext context) {
    GoRouter.of(context).push('/messages/details?index=$index');
  }
}

class MessageTile extends StatelessWidget {
  final ZMessage message;
  final int index;
  final double? width;

  MessageTile(this.message, this.index, {this.width});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final textTheme = theme.textTheme;
    final s = message.incoming ? message.sender : message.recipient;
    final initial = (s == null || s.isEmpty) ? "?" : s[0];
    final dateString = humanizeDateTime(context, message.timestamp);

    final unreadStyle = (TextStyle? s) =>
        message.read ? s : s?.copyWith(fontWeight: FontWeight.bold);

    final av = avatar(initial);

    final body = Column(
      children: [
        Text(message.fromto(), style: unreadStyle(textTheme.bodySmall)),
        Gap(4),
        if (message.subject.isNotEmpty)
          Text(message.subject,
              style: unreadStyle(textTheme.titleMedium),
              overflow: TextOverflow.ellipsis),
        Gap(6),
        Text(
          message.body,
          softWrap: true,
          maxLines: 5,
          overflow: TextOverflow.ellipsis,
        ),
      ],
    );

    return GestureDetector(
        onTap: () {
          _onSelect(context);
        },
        onLongPress: () {
          WarpApi.markAllMessagesAsRead(aa.coin, aa.id, true);
        },
        child: Padding(
          padding: EdgeInsets.symmetric(vertical: 8),
          child: Row(children: [
            av,
            Gap(15),
            Expanded(child: body),
            SizedBox(
                width: 80, child: Text(dateString, textAlign: TextAlign.right)),
          ]),
        ));
  }

  _onSelect(BuildContext context) {
    GoRouter.of(context).push('/messages/details?index=$index');
  }
}

class MessageItemPage extends StatefulWidget {
  final int index;
  final MessageThread? initialThread;
  final String? cid; // Stable CID for thread lookup (preferred over index)
  MessageItemPage(this.index, {this.initialThread, this.cid});

  @override
  State<StatefulWidget> createState() => _MessageItemState();
}

class _MessageItemState extends State<MessageItemPage> with TickerProviderStateMixin {
  static const bool _debugNoAnimations = false; // Step B: minimal fade for last bubble only
  late List<MessageThread> threads;
  late MessageThread thread;
  final TextEditingController _messageController = TextEditingController();
  final FocusNode _messageFocus = FocusNode();
  final ScrollController _threadController = ScrollController();
  bool _pendingJustAdded = false;
  final Map<String, GlobalKey> _bubbleKeys = {};
  String? _highlightId;
  _ReplyTargetState? _replyTarget;
  bool _firstFramePainted = false;
  late AnimationController _pulseController;
  bool _showDownChevron = false;
  int _outgoingSinceAway = 0;
  int _lastOutgoingCount = 0;
  int _lastThreadCount = 0;
  final List<String> _replyNavStack = <String>[];
  bool _isStepping = false;
  bool _originWasBottom = false;
  static const double _stepThresholdPx = 120.0;
  // Defer heavy aggregation until after first frame to avoid jank on entry
  bool _aggregatesReady = false;
  Map<String, Map<String, Set<String>>> _reactionsByBubbleIdCached = <String, Map<String, Set<String>>>{};
  // Reactions: global MRU cache and transient chooser overlay state
  List<String> _emojiMRU = kDefaultEmojiTokens;
  OverlayEntry? _reactionOverlay;
  String? _reactionOverlayForBubbleId;
  OverlayEntry? _menuOverlay;
  bool _emojiPickerOpen = false;
  // Plus (+) mini-menu overlay state
  final LayerLink _plusLink = LayerLink();
  OverlayEntry? _plusOverlay;
  bool _plusMenuOpen = false;
  late AnimationController _plusController;
  // Accept animation controllers map (per-thread/cid)
  Map<String, AnimationController>? _acceptAnimCtrls;
  // Accept staging fade
  bool _acceptThreadVisible = true;
  // Removed page-level fade
  // Track accept entrance animation to avoid replaying on unrelated rebuilds
  final Set<String> _acceptAnimatedOnceCids = <String>{};
  String? _acceptJustAddedCid;
  // Track which CIDs have their handshake messages expanded
  final Set<String> _expandedHandshakeCids = <String>{};
  // Track rendered bubble IDs for entrance animations
  final Set<String> _renderedBubbleIds = <String>{};
  // Photo reassembly state: map photo_id -> reassembled bytes
  final Map<String, Uint8List> _reassembledPhotos = <String, Uint8List>{};
  // Photo decoding states: map photo_id -> decoding state
  final Map<String, PhotoDecodingState> _photoDecodingStates = <String, PhotoDecodingState>{};

  // Reassemble photos from chunks in thread messages
  // Called whenever messages update to handle out-of-order chunk delivery
  Future<void> _reassemblePhotosFromThread() async {
    try {
      // Collect all photo chunks from thread messages
      final chunksByPhoto = PhotoDecoder.collectChunks(thread.messages);
      
      bool needsUpdate = false;
      
      for (final entry in chunksByPhoto.entries) {
        final photoId = entry.key;
        final chunks = entry.value;
        
        // Update decoding state
        final isComplete = PhotoDecoder.validateChunks(chunks);
        final existingState = _photoDecodingStates[photoId];
        
        // Check if state changed (new chunks arrived)
        final stateChanged = existingState == null || 
            existingState.chunks.length != chunks.length ||
            !existingState.isComplete && isComplete;
        
        if (stateChanged) {
          needsUpdate = true;
          _photoDecodingStates[photoId] = PhotoDecodingState(
            photoId: photoId,
            chunks: chunks,
            isComplete: isComplete,
            lastUpdated: DateTime.now(),
          );
          
          // Reassemble if complete
          if (isComplete && !_reassembledPhotos.containsKey(photoId)) {
            try {
              final photoBytes = await PhotoDecoder.reassemblePhoto(chunks);
              if (photoBytes != null) {
                _reassembledPhotos[photoId] = photoBytes;
                needsUpdate = true;
              } else {
                // Reassembly failed - might be corrupted data
                print('Failed to reassemble photo $photoId');
              }
            } catch (e) {
              print('Error reassembling photo $photoId: $e');
              // Mark as failed but keep state for retry
            }
          }
        }
      }
      
      // Clean up photos that no longer have chunks (messages deleted)
      final activePhotoIds = chunksByPhoto.keys.toSet();
      final photosToRemove = _reassembledPhotos.keys.where((id) => !activePhotoIds.contains(id)).toList();
      for (final id in photosToRemove) {
        _reassembledPhotos.remove(id);
        _photoDecodingStates.remove(id);
        needsUpdate = true;
      }
      
      if (needsUpdate && mounted) {
        setState(() {});
      }
    } catch (e) {
      print('Error in _reassemblePhotosFromThread: $e');
    }
  }

  void _togglePlusMenu() {
    // Block menu if handshake not complete
    try {
      final invite = _pendingInviteForThread();
      final bool acceptedOrReplied = _isChatAcceptedForThread(thread.address) || (invite != null && invite.hasOutgoingAccept);
      if (!acceptedOrReplied) return;
    } catch (_) {}
    if (_plusMenuOpen) {
      _hidePlusMenu();
      return;
    }
    _showPlusMenu();
  }

  void _hidePlusMenu() {
    try {
      if (_plusOverlay != null) {
        _plusController.reverse().whenComplete(() {
          try { _plusOverlay?.remove(); } catch (_) {}
          _plusOverlay = null;
          if (mounted) setState(() { _plusMenuOpen = false; });
        });
      } else {
        if (mounted) setState(() { _plusMenuOpen = false; });
      }
    } catch (_) {
      try { _plusOverlay?.remove(); } catch (_) {}
      _plusOverlay = null;
      if (mounted) setState(() { _plusMenuOpen = false; });
    }
  }

  void _closePlusMenuImmediately() {
    try { _plusOverlay?.remove(); } catch (_) {}
    _plusOverlay = null;
    try { _plusController.reset(); } catch (_) {}
    if (mounted) setState(() { _plusMenuOpen = false; });
  }

  void _showPlusMenu() {
    try { _plusOverlay?.remove(); } catch (_) {}
    try { _plusController.value = 0.0; } catch (_) {}
    _plusOverlay = OverlayEntry(builder: (ctx) {
      final t = Theme.of(context);
      final onSurf = t.colorScheme.onSurface;
      // Circle visual constants
      const double circle = 36.0; // match + button size
      const double spacing = 12.0;
      const double gapFromPlus = 12.0;
      const double plusSize = 36.0;
      final double hOff = (plusSize - circle) / 2.0; // center horizontally over +
      Widget buildCircle({required Widget child, required VoidCallback onTap}) {
        return Container(
          width: circle,
          height: circle,
          decoration: const BoxDecoration(shape: BoxShape.circle, color: Color(0xFF565656)),
          child: Material(
            color: Colors.transparent,
            shape: const CircleBorder(),
            child: InkWell(
              customBorder: const CircleBorder(),
              onTap: () { _hidePlusMenu(); onTap(); },
              child: Center(child: child),
            ),
          ),
        );
      }
      return Stack(children: [
        // Dismiss area (exclude AppBar region so the back button remains clickable)
        Positioned(
          top: MediaQuery.of(context).padding.top + kToolbarHeight,
          left: 0,
          right: 0,
          bottom: 0,
          child: GestureDetector(behavior: HitTestBehavior.translucent, onTap: _hidePlusMenu),
        ),
        CompositedTransformFollower(
          link: _plusLink,
          offset: Offset(hOff, - (circle * 3 + spacing * 2 + gapFromPlus)), // three circles stacked above + with gaps
          showWhenUnlinked: false,
          child: IgnorePointer(
            ignoring: false,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                // Top: Photo camera icon
                AnimatedBuilder(
                  animation: _plusController,
                  builder: (context, child) {
                    final double v = Interval(0.0, 1.0, curve: Curves.easeOutCubic).transform(_plusController.value);
                    final double dy = (1.0 - v) * (circle * 3 + spacing * 2 + gapFromPlus);
                    return Opacity(
                      opacity: v.clamp(0.0, 1.0),
                      child: Transform.translate(
                        offset: Offset(0, dy),
                        child: child,
                      ),
                    );
                  },
                  child: buildCircle(
                    onTap: () {
                      _hidePlusMenu();
                      try {
                        _pickAndSendPhoto();
                      } catch (_) {}
                    },
                    child: Stack(
                      alignment: Alignment.center,
                      children: [
                        // Centered drop shadow for icon
                        ImageFiltered(
                          imageFilter: ui.ImageFilter.blur(sigmaX: 2.5, sigmaY: 2.5),
                          child: Transform.scale(
                            scale: 1.0,
                            child: Icon(Icons.photo, color: Colors.black, size: 22),
                          ),
                        ),
                        // Foreground icon
                        Transform.scale(
                          scale: 1.0,
                          child: Icon(Icons.photo, color: Colors.white, size: 22),
                        ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: spacing),
                // Second: Send (use quick menu icon and open quick_send flow for thread)
                AnimatedBuilder(
                  animation: _plusController,
                  builder: (context, child) {
                    final double v = Interval(0.15, 1.0, curve: Curves.easeOutCubic).transform(_plusController.value);
                    final double dy = (1.0 - v) * (circle * 2 + spacing + gapFromPlus);
                    return Opacity(
                      opacity: v.clamp(0.0, 1.0),
                      child: Transform.translate(
                        offset: Offset(0, dy),
                        child: child,
                      ),
                    );
                  },
                  child: buildCircle(
                    onTap: () {
                      _hidePlusMenu();
                      try {
                        reply();
                      } catch (_) {}
                    },
                    child: Stack(
                      alignment: Alignment.center,
                      children: [
                        // Centered drop shadow for icon
                        ImageFiltered(
                          imageFilter: ui.ImageFilter.blur(sigmaX: 2.5, sigmaY: 2.5),
                          child: Transform.scale(
                            scale: 1.0, // shrunk by 0.5 from previous 1.5
                            child: SvgPicture.asset(
                              'assets/icons/send_quick.svg',
                              width: 22,
                              height: 22,
                              colorFilter: const ColorFilter.mode(Colors.black, BlendMode.srcIn),
                            ),
                          ),
                        ),
                        // Foreground icon
                        Transform.scale(
                          scale: 1.0,
                          child: SvgPicture.asset(
                            'assets/icons/send_quick.svg',
                            width: 22,
                            height: 22,
                            colorFilter: const ColorFilter.mode(Colors.white, BlendMode.srcIn),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: spacing),
                // Third: Request icon from Receive page glyph with centered shadow
                AnimatedBuilder(
                  animation: _plusController,
                  builder: (context, child) {
                    final double v = Interval(0.0, 0.9, curve: Curves.easeOutCubic).transform(_plusController.value);
                    final double dy = (1.0 - v) * (circle + gapFromPlus);
                    return Opacity(
                      opacity: v.clamp(0.0, 1.0),
                      child: Transform.translate(
                        offset: Offset(0, dy),
                        child: child,
                      ),
                    );
                  },
                  child: buildCircle(
                    onTap: () {
                      _hidePlusMenu();
                      try {
                        requestFromThread();
                      } catch (_) {}
                    },
                    child: Stack(
                      alignment: Alignment.center,
                      children: [
                        // Shadow
                        Transform.translate(
                          offset: const Offset(8.2, 8.2),
                          child: ImageFiltered(
                            imageFilter: ui.ImageFilter.blur(sigmaX: 2.8, sigmaY: 2.8),
                            child: Transform.scale(
                              scale: 1.75, // shrunk by 0.5 from previous 2.25
                              child: SvgPicture.string(
                                _ZASHI_REQUEST_GLYPH_INLINE,
                                width: 22,
                                height: 22,
                                colorFilter: const ColorFilter.mode(Colors.black, BlendMode.srcIn),
                              ),
                            ),
                          ),
                        ),
                        // Foreground
                        Transform.translate(
                          offset: const Offset(8.2, 8.2),
                          child: Transform.scale(
                            scale: 1.75,
                            child: SvgPicture.string(
                              _ZASHI_REQUEST_GLYPH_INLINE,
                              width: 22,
                              height: 22,
                              colorFilter: const ColorFilter.mode(Colors.white, BlendMode.srcIn),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ]);
    });
    Overlay.of(context).insert(_plusOverlay!);
    setState(() { _plusMenuOpen = true; });
    try {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && _plusMenuOpen && _plusOverlay != null) {
          _plusController.forward(from: 0.0);
        }
      });
    } catch (_) {}
  }

  @override
  void initState() {
    super.initState();
    // no page-level fade controller
    _pulseController = AnimationController(vsync: this, duration: const Duration(milliseconds: 700));
    _pulseController.addListener(() { if (_highlightId != null && mounted) setState(() {}); });
    _plusController = AnimationController(vsync: this, duration: const Duration(milliseconds: 420), reverseDuration: const Duration(milliseconds: 220));
    // Lightweight thread capture only; avoid heavy recompute and DB work before first frame.
    if (widget.initialThread != null) {
      // Use the passed-in prebuilt thread to avoid heavy recompute on open
      threads = <MessageThread>[widget.initialThread!];
      thread = widget.initialThread!;
    } else {
      threads = _buildThreads(aa.messages.items);
      // Prefer CID-based lookup (stable) over index (dynamic)
      if (widget.cid != null && widget.cid!.isNotEmpty) {
        final targetKey = 'cid::' + widget.cid!.trim();
        final idx = threads.indexWhere((t) => t.key == targetKey);
        if (idx >= 0) {
          thread = threads[idx];
        } else {
          // CID not found, fall back to index
          final i = widget.index.clamp(0, threads.length > 0 ? threads.length - 1 : 0);
          thread = threads.isNotEmpty ? threads[i] : MessageThread(
            key: 'empty', title: 'Messages', address: null, messages: [], unreadCount: 0, lastTimestamp: DateTime.now(),
          );
        }
      } else {
        // No CID provided, use index
        final i = widget.index.clamp(0, threads.length > 0 ? threads.length - 1 : 0);
        thread = threads.isNotEmpty ? threads[i] : MessageThread(
          key: 'empty', title: 'Messages', address: null, messages: [], unreadCount: 0, lastTimestamp: DateTime.now(),
        );
      }
    }
    // Pre-populate rendered bubble IDs so existing messages don't animate on open
    _prePopulateRenderedBubbleIds();
    // Flip first-frame flag after initial layout so we can enable animations later
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (!mounted) return;
      _firstFramePainted = true; // avoid extra rebuild mid-transition
      // Defer mark-as-read and thread refresh until after transition (~700ms)
      try { await Future.delayed(const Duration(milliseconds: 700)); } catch (_) {}
      if (!mounted) return;
      try {
        final current = thread;
        if (current.messages.isNotEmpty) {
          final unreadIds = current.messages.where((m) => !m.read).map((m) => m.id).toSet();
          if (unreadIds.isNotEmpty) {
            // Batch mark-as-read
            for (final id in unreadIds) {
              try { WarpApi.markMessageAsRead(aa.coin, id, true); } catch (_) {}
            }
            // Update store and local thread reference
            final updated = aa.messages.items.map((m) => unreadIds.contains(m.id) ? m.withRead(true) : m).toList();
            aa.messages.items = updated;
            final rebuilt = _buildThreads(updated);
            final idx = rebuilt.indexWhere((t) => t.key == current.key);
            if (idx >= 0) {
              setState(() {
                threads = rebuilt;
                thread = threads[idx];
              });
            }
          }
        }
      } catch (_) {}
      // Lightweight title refresh even when initialThread was provided
      try {
        final currentKey = thread.key;
        final rebuilt = _buildThreads(aa.messages.items);
        final idx = rebuilt.indexWhere((t) => t.key == currentKey);
        if (idx >= 0 && mounted) {
          setState(() { thread = rebuilt[idx]; threads = rebuilt; });
          // Trigger photo reassembly when thread updates (important for receiving wallet)
          WidgetsBinding.instance.addPostFrameCallback((_) async {
            if (!mounted) return;
            await _reassemblePhotosFromThread();
          });
        }
      } catch (_) {}
    });

    // Call photo reassembly when thread messages change
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (!mounted) return;
      await _reassemblePhotosFromThread();
    });

    // Load global MRU emojis
    () async {
      try {
        final list = await loadEmojiMRU();
        if (mounted) setState(() { _emojiMRU = list; });
      } catch (_) {}
    }();

    _threadController.addListener(() {
      try {
        final bool away = _threadController.hasClients && _threadController.offset > 120.0;
        if (_nearBottomReversed() && _isStepping) {
          _resetStepping();
        }
        // Track outgoing increments while away from bottom
        try {
          final all = thread.messages;
          final int currentOutgoing = all.where((m) => !((m.incoming) as bool)).length;
          if (away) {
            final int outDiff = (currentOutgoing - _lastOutgoingCount).clamp(0, 999);
            if (outDiff > 0) _outgoingSinceAway = (_outgoingSinceAway + outDiff).clamp(0, 999);
          } else {
            _outgoingSinceAway = 0;
          }
          _lastOutgoingCount = currentOutgoing;
        } catch (_) {}

        final bool show = (_isStepping && _replyNavStack.isNotEmpty) || away;
        if (show != _showDownChevron && mounted) setState(() { _showDownChevron = show; });
      } catch (_) {}
    });

    // (Optional) SVG warm-up skipped to keep build lean

    // Defer reaction aggregation computation until after initial transition
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      try { await Future.delayed(const Duration(milliseconds: 450)); } catch (_) {}
      if (!mounted) return;
      try {
        // Auto-close plus menu if handshake becomes false
        try {
          final invite = _pendingInviteForThread();
          final bool acceptedOrReplied = _isChatAcceptedForThread(thread.address) || (invite != null && invite.hasOutgoingAccept);
          if (!acceptedOrReplied && _plusMenuOpen) {
            _hidePlusMenu();
          }
        } catch (_) {}
        final rx = _computeReactionAggregatesFromThread(thread);
        setState(() { _reactionsByBubbleIdCached = rx; _aggregatesReady = true; });
      } catch (_) {}
    });
  }

  // Track message count for reactive updates
  int _lastKnownMessageCount = -1;
  int _lastSyncHeight = -1;

  @override
  Widget build(BuildContext context) {
    final s = S.of(context);
    final t = Theme.of(context);
    // Watch for message updates and refresh thread reactively
    return Observer(builder: (context) {
      // Watch these observables for real-time updates
      final currentMsgCount = aa.messages.items.length;
      final currentEchoCount = optimisticEchoes.length;
      final currentSyncHeight = syncStatus2.syncedHeight;
      final __ = contacts.contacts.length; // Watch contact changes for title updates

      // Only refresh from DB when sync has advanced (new blocks), not on local sends
      // This prevents the refresh from racing with optimistic echo updates
      final syncAdvanced = _lastSyncHeight >= 0 && currentSyncHeight > _lastSyncHeight;
      final msgCountChanged = _lastKnownMessageCount >= 0 && currentMsgCount != _lastKnownMessageCount;

      if (_firstFramePainted && (syncAdvanced || (msgCountChanged && currentEchoCount == 0))) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) _refreshThread();
        });
      }
      _lastKnownMessageCount = currentMsgCount;
      _lastSyncHeight = currentSyncHeight;

      // Compute title dynamically for contact rename/delete responsiveness
      final title = _computeDynamicTitle();
    final replyableBase = (thread.address != null && thread.address!.isNotEmpty);
    final pendingInvite = _pendingInviteForThread();
    final replyable = replyableBase || (pendingInvite?.replyUA?.isNotEmpty == true);
    final isAccepted = _isChatAcceptedForThread(thread.address);

    return WillPopScope(
      onWillPop: () async {
        try { if (_plusMenuOpen) { _closePlusMenuImmediately(); } } catch (_) {}
        return true; // also pop the route in the same action
      },
      child: Scaffold(
      appBar: AppBar(
        backgroundColor: Theme.of(context).scaffoldBackgroundColor,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        scrolledUnderElevation: 0,
        centerTitle: true,
        iconTheme: const IconThemeData(color: Colors.white),
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          color: Colors.white,
          onPressed: () {
            try { if (_plusMenuOpen) { _closePlusMenuImmediately(); } } catch (_) {}
            try { GoRouter.of(context).pop(); } catch (_) { Navigator.of(context).maybePop(); }
          },
        ),
        title: Builder(builder: (context) {
          final t = Theme.of(context);
          final base = t.appBarTheme.titleTextStyle ?? t.textTheme.titleLarge ?? t.textTheme.titleMedium ?? t.textTheme.bodyMedium;
          final reduced = (base?.fontSize != null) ? base!.copyWith(fontSize: base.fontSize! * 0.75) : base;
          return Text(title, textAlign: TextAlign.center, overflow: TextOverflow.ellipsis, style: reduced);
        }),
      ),
      body: SafeArea(
        child: Column(
          children: [
            Expanded(
              child: Container(
                color: Theme.of(context).colorScheme.surface,
                child: Stack(children: [
                  Padding(
                    padding: EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                    // Subtle thread fade-in on open; and accept-stage fade when sending accept
                    child: (kEnableThreadFadeOnOpen || kEnableAcceptThreadStageFade)
                        ? Opacity(
                            opacity: _acceptThreadVisible ? 1.0 : 0.0,
                            child: _buildComposeStyleThread(t),
                          )
                        : _buildComposeStyleThread(t),
                  ),
                  Positioned(
                    right: 14,
                    bottom: 14,
                    child: Opacity(
                      opacity: _showDownChevron ? 1.0 : 0.0,
                      child: IgnorePointer(
                        ignoring: !_showDownChevron,
                        child: Stack(
                          clipBehavior: Clip.none,
                          children: [
                            Container(
                              width: 42,
                              height: 42,
                              decoration: const BoxDecoration(
                                shape: BoxShape.circle,
                                color: Color(0xFF565656),
                              ),
                              child: Material(
                                color: Colors.transparent,
                                shape: const CircleBorder(),
                                child: InkWell(
                                  customBorder: const CircleBorder(),
                                  onTap: () async {
                                    try {
                                      if (_isStepping && _replyNavStack.isNotEmpty) {
                                        final String nextId = _replyNavStack.removeLast();
                                        final key = _bubbleKeys[nextId];
                                        if (key?.currentContext != null) {
                                          await Scrollable.ensureVisible(
                                            key!.currentContext!,
                                            alignment: 0.5,
                                            duration: const Duration(milliseconds: 450),
                                            curve: Curves.easeInOutCubic,
                                          );
                                        }
                                        if (_replyNavStack.isEmpty && _originWasBottom) {
                                          _isStepping = false;
                                        }
                                        setState(() {});
                                      } else {
                                        if (_threadController.hasClients) {
                                          await _threadController.animateTo(
                                            _threadController.position.minScrollExtent,
                                            duration: const Duration(milliseconds: 450),
                                            curve: Curves.easeInOutCubic,
                                          );
                                        }
                                        _originWasBottom = false;
                                        _isStepping = false;
                                        _replyNavStack.clear();
                                        _outgoingSinceAway = 0;
                                        setState(() {});
                                      }
                                    } catch (_) {}
                                  },
                                  child: const Center(
                                    child: Icon(Icons.keyboard_arrow_down, color: Colors.white, size: 26),
                                  ),
                                ),
                              ),
                            ),
                            if (_outgoingSinceAway > 0)
                              Positioned(
                                top: -2,
                                right: -2,
                                child: Container(
                                  padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                                  decoration: BoxDecoration(
                                    color: const Color(0xFFF4B728),
                                    borderRadius: BorderRadius.circular(10),
                                  ),
                                  child: Text(
                                    _outgoingSinceAway > 99 ? '99+' : _outgoingSinceAway.toString(),
                                    style: const TextStyle(color: Colors.black, fontSize: 10, fontWeight: FontWeight.w700),
                                  ),
                                ),
                              ),
                            if (_isStepping && _replyNavStack.isNotEmpty)
                              Positioned(
                                top: -2,
                                right: -2,
                                child: Container(
                                  padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                                  decoration: BoxDecoration(
                                    color: const Color(0xFFF4B728),
                                    borderRadius: BorderRadius.circular(10),
                                  ),
                                  child: Text(
                                    _replyNavStack.length > 99 ? '99+' : _replyNavStack.length.toString(),
                                    style: const TextStyle(color: Colors.black, fontSize: 10, fontWeight: FontWeight.w700),
                                  ),
                                ),
                              ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ]),
              ),
            ),
            _buildBottomInputForThread(t, replyable, isAccepted),
          ],
        ),
      ),

      ),
    );  // closes WillPopScope
    });  // closes Observer builder
  }

  // Helper to compute dynamic title based on current contacts
  String _computeDynamicTitle() {
    try {
      final addr = (thread.address ?? '').trim();
      if (addr.isNotEmpty) {
        final name = contacts.addressToName[addr];
        if (name != null && name.trim().isNotEmpty) return name.trim();
      }
      // Fallback: check cid_name_ property
      try {
        final cid = thread.key.startsWith('cid::') ? thread.key.substring(5) : '';
        if (cid.isNotEmpty) {
          final cidName = WarpApi.getProperty(aa.coin, 'cid_name_' + cid).trim();
          if (cidName.isNotEmpty) return cidName;
        }
      } catch (_) {}
      // Final fallback: truncated address or original title
      if (addr.isNotEmpty) {
        final len = addr.length;
        final head = addr.substring(0, len < 20 ? len : 20);
        return len > 20 ? '$head...' : head;
      }
      return thread.title;
    } catch (_) {
      return thread.title;
    }
  }

  // Pre-populate rendered bubble IDs to prevent animations on initial load
  void _prePopulateRenderedBubbleIds() {
    try {
      for (final m in thread.messages) {
        final hdr = _parseHeader(m);
        final cid = (hdr['conversation_id'] ?? '').trim();
        final seqStr = (hdr['seq'] ?? '').trim();
        final bubbleId = _bubbleIdForMessage(m, cid: cid, seqStr: seqStr);
        _renderedBubbleIds.add(bubbleId);
      }
    } catch (_) {}
  }

  // NEW MESSAGE style thread (compose-consistent)
  Widget _buildComposeStyleThread(ThemeData theme) {
    List<ZMessage> list = thread.messages;
    // Fallback: if the prebuilt thread is empty, try matching by counterparty address
    if (list.isEmpty) {
      try {
        final addr = (thread.address ?? '').trim();
        if (addr.isNotEmpty) {
          final fallback = aa.messages.items.where((m) {
            try {
              final fa = (m as dynamic).fromAddress as String?;
              final sd = (m as dynamic).sender as String?;
              final rc = (m as dynamic).recipient as String?;
              return (fa != null && fa == addr) || (sd != null && sd == addr) || (rc != null && rc == addr);
            } catch (_) { return false; }
          }).toList(growable: false);
          if (fallback.isNotEmpty) list = fallback;
        }
      } catch (_) {}
    }
    
    // Trigger photo reassembly when thread messages change
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (!mounted) return;
      await _reassemblePhotosFromThread();
    });
    
    // Use deferred aggregates if ready; otherwise render without reactions on first frame
    final Map<String, Map<String, Set<String>>> reactionsByBubbleId = _aggregatesReady ? _reactionsByBubbleIdCached : const {};
    // Track counters when list changes to drive the outgoing badge while scrolled up
    try {
      if (list.length != _lastThreadCount) {
        final bool near = _nearBottomReversed();
        // Count outgoing so we only badge on my sends
        final int currentOutgoing = list.where((m) => !((m.incoming) as bool)).length;
        if (near) {
          _outgoingSinceAway = 0;
          // stay auto-scrolled when near bottom
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (_threadController.hasClients) {
              _threadController.animateTo(
                _threadController.position.minScrollExtent,
                duration: const Duration(milliseconds: 450),
                curve: Curves.easeInOutCubic,
              );
            }
          });
        } else {
          final int outDiff = (currentOutgoing - _lastOutgoingCount).clamp(0, 999);
          if (outDiff > 0) {
            _outgoingSinceAway = (_outgoingSinceAway + outDiff).clamp(0, 999);
            if (!_showDownChevron && mounted) setState(() { _showDownChevron = true; });
          }
        }
        _lastOutgoingCount = currentOutgoing;
        _lastThreadCount = list.length;
        // Trigger photo reassembly when message count changes (new chunks arrived)
        if (list.length > 0) {
          WidgetsBinding.instance.addPostFrameCallback((_) async {
            if (!mounted) return;
            await _reassemblePhotosFromThread();
          });
        }
      }
    } catch (_) {}

    final balanceFontFamily = Theme.of(context).textTheme.displaySmall?.fontFamily;
    final n = list.length;
    if (n == 0) {
      return Center(
        child: Text(
          'No messages in this thread',
          style: Theme.of(context).textTheme.bodyMedium,
        ),
      );
    }
    return ListView.builder(
      controller: _threadController,
      reverse: true,
      addAutomaticKeepAlives: false,
      addRepaintBoundaries: false,
      itemCount: n,
      itemBuilder: (context, index) {
        // Render newest at the bottom and open already scrolled to bottom
        final m = list[n - 1 - index];
        final incoming = m.incoming;
        final body = (m.body).trim();
        final statusText = (body == 'Sending…' || body == 'Sent' || body == 'Failed') ? body : null;
        final hdr = _parseHeader(m);
        final cid = (hdr['conversation_id'] ?? '').trim();
        final seqStr = (hdr['seq'] ?? '').trim();
        final inReplyToStr = (hdr['in_reply_to_seq'] ?? '').trim();
        final typeStr = (hdr['type'] ?? '').trim();
        // Show full body including headers for debugging/verification
        final String visibleBody = (() {
          if (statusText != null) return body;
          // Show complete body with headers visible
          return body;
        })();
        final String amountStrForPayment = (() {
          try {
            final az = (hdr['amount_zat'] ?? '').trim();
            if (az.isEmpty) return '';
            final z = int.tryParse(az) ?? 0;
            return amountToStringDynamic(z);
          } catch (_) { return ''; }
        })();

        // Hide reaction memos from the message list UI
        if (typeStr == 'reaction') {
          return const SizedBox.shrink();
        }
        // Replace handshake pair with a single centered label once chat is accepted,
        // and render invites as friendly system labels before accept
        try {
          final bool handshakeComplete = _isChatAcceptedForThread(thread.address);
          if (handshakeComplete) {
            // If expanded, show invite and accept messages normally instead of hiding them
            final bool isExpanded = cid.isNotEmpty && _expandedHandshakeCids.contains(cid);
            if (typeStr == 'invite') {
              if (isExpanded) {
                // Show invite message with headers when expanded
                // Continue to normal message rendering below
              } else {
                return const SizedBox.shrink();
              }
            }
            if (typeStr == 'accept') {
              if (isExpanded) {
                // Show accept message with headers when expanded
                // Continue to normal message rendering below (fall through)
              } else {
                // Show "CHAT INITIATED" label that can be clicked to expand
                // Animate the newest accept (reversed list: newest index == 0)
                final bool isNewestIndex = (index == 0);
                final bool shouldAnimate = () {
                  if (!kEnableAcceptEnterAnimation || !isNewestIndex) return false;
                  if (cid.isEmpty) return false;
                  if (_acceptAnimatedOnceCids.contains(cid)) return false;
                  if (_acceptJustAddedCid != null && _acceptJustAddedCid == cid) return true;
                  return false;
                }();
                if (shouldAnimate) {
                  // Per-item, short-lived controller for the label entrance
                  final String animKey = 'accept::' + (cid.isNotEmpty ? cid : 'na');
                  _acceptAnimCtrls ??= <String, AnimationController>{};
                  final existing = _acceptAnimCtrls![animKey];
                  final ctrl = existing ?? AnimationController(vsync: this, duration: const Duration(milliseconds: kAcceptEnterDurationMs));
                  if (existing == null) {
                    _acceptAnimCtrls![animKey] = ctrl;
                    // Stagger after the thread fade start
                    Future.delayed(const Duration(milliseconds: kAcceptFadeDelayMs + kAcceptEnterDelayMs), () {
                      if (mounted && ctrl.status == AnimationStatus.dismissed) {
                        ctrl.forward().whenComplete(() async {
                          try { await Future.delayed(const Duration(milliseconds: 70)); } catch (_) {}
                          if (_threadController.hasClients && _nearBottomReversed()) {
                            _threadController.animateTo(
                              _threadController.position.minScrollExtent,
                              duration: const Duration(milliseconds: 450),
                              curve: Curves.easeInOutCubic,
                            );
                          }
                          try { _acceptAnimCtrls?.remove(animKey)?.dispose(); } catch (_) {}
                          // Mark as animated once; clear just-added marker
                          try { _acceptAnimatedOnceCids.add(cid); } catch (_) {}
                          if (_acceptJustAddedCid == cid) { _acceptJustAddedCid = null; }
                        });
                      }
                    });
                  }
                  final curve = CurvedAnimation(parent: ctrl, curve: Curves.easeOutCubic);
                  final label = Padding(
                    padding: const EdgeInsets.symmetric(vertical: 4),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        InkWell(
                          onTap: () {
                            setState(() {
                              if (_expandedHandshakeCids.contains(cid)) {
                                _expandedHandshakeCids.remove(cid);
                              } else {
                                _expandedHandshakeCids.add(cid);
                              }
                            });
                          },
                          child: Text(
                            'CHAT INITIATED',
                            style: TextStyle(
                              color: const Color(0xFFF4B728),
                              fontFamily: balanceFontFamily,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                      ],
                    ),
                  );
                  return FadeTransition(
                    opacity: curve,
                    child: SlideTransition(
                      position: Tween<Offset>(begin: Offset(0, kAcceptSlidePx / 100.0), end: Offset.zero).animate(curve),
                      child: RepaintBoundary(child: label),
                    ),
                  );
                }
                // Fallback: static label
                return Padding(
                  padding: const EdgeInsets.symmetric(vertical: 4),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      InkWell(
                        onTap: () {
                          setState(() {
                            if (_expandedHandshakeCids.contains(cid)) {
                              _expandedHandshakeCids.remove(cid);
                            } else {
                              _expandedHandshakeCids.add(cid);
                            }
                          });
                        },
                        child: Text(
                          'CHAT INITIATED',
                          style: TextStyle(
                            color: const Color(0xFFF4B728),
                            fontFamily: balanceFontFamily,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                    ],
                  ),
                );
              }
            }
          } else {
            // Before accept: render invite as a centered label (hide raw header)
            if (typeStr == 'invite') {
              final String label = incoming ? 'CHAT INVITE RECEIVED' : 'CHAT INVITE SENT';
              return Padding(
                padding: const EdgeInsets.symmetric(vertical: 4),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    InkWell(
                      onTap: () => _showMessageHeaders(context, m.body),
                      child: Text(
                        label,
                        style: TextStyle(
                          color: const Color(0xFFF4B728),
                          fontFamily: balanceFontFamily,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                  ],
                ),
              );
            }
          }
        } catch (_) {}
        
        bool hasValidReplyTarget = false;
        String? targetBubbleId;
        if ((typeStr == 'message' || typeStr == 'accept' || typeStr == 'invite') && inReplyToStr.isNotEmpty && cid.isNotEmpty) {
          final targetSeq = int.tryParse(inReplyToStr);
          if (targetSeq != null) {
            for (final tm in thread.messages) {
              final th = _parseHeader(tm);
              if ((th['conversation_id'] ?? '').trim() == cid) {
                final ts = int.tryParse((th['seq'] ?? '').trim());
                if (ts == targetSeq) { 
                  hasValidReplyTarget = true; 
                  targetBubbleId = _bubbleIdForMessage(tm, cid: cid, seqStr: targetSeq.toString());
                  break; 
                }
              }
            }
          }
        }
        final bubbleId = _bubbleIdForMessage(m, cid: cid, seqStr: seqStr);
        final key = _bubbleKeys.putIfAbsent(bubbleId, () => GlobalKey());

        const Color incomingFill = Color(0xFF2E2C2C);
        const Color outgoingFill = Color(0xFFF4B728);

        // Compute pulsing overlay color when highlighted (lighter and more obvious)
        final bool isHighlighted = (_highlightId == bubbleId);
        final Color base = incoming ? incomingFill : outgoingFill;
        // Triangular pulse: 0 → 1 → 0 over controller cycle
        final double tPulse = isHighlighted ? (1.0 - (( _pulseController.value * 2.0 - 1.0).abs())) : 0.0;
        // Make outgoing (orange) pulse stronger than incoming (grey)
        final bool isOutgoing = !incoming;
        final double whitenFactor = isOutgoing ? 0.88 : 0.70; // how close to white to blend
        final double opacityScale = isOutgoing ? 0.85 : 0.55; // overlay opacity amplitude
        final Color pulseColor = Color.lerp(base, Colors.white, whitenFactor) ?? base;
        final Color blended = isHighlighted ? Color.alphaBlend(pulseColor.withOpacity(opacityScale * tPulse), base) : base;

        // Build shared bubble content
        final contentColumn = Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            if (typeStr == 'payment') ...[
              Builder(builder: (context) {
                final titleName = thread.title;
                final outgoing = !incoming;
                final label = outgoing
                    ? (amountStrForPayment.isNotEmpty ? 'You sent ' + amountStrForPayment + ' ZEC' : 'You sent ZEC')
                    : ((amountStrForPayment.isNotEmpty ? (titleName + ' sent you ' + amountStrForPayment + ' ZEC!') : (titleName + ' sent you ZEC!')));
                return Text(label, style: Theme.of(context).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w700));
              }),
              if (visibleBody.isNotEmpty) const Gap(6),
            ],
            if (typeStr == 'request') ...[
              Builder(builder: (context) {
                final titleName = thread.title;
                final outgoing = !incoming;
                final label = outgoing
                    ? (amountStrForPayment.isNotEmpty ? 'You requested ' + amountStrForPayment + ' ZEC' : 'You requested ZEC')
                    : ((amountStrForPayment.isNotEmpty ? (titleName + ' requested ' + amountStrForPayment + ' ZEC from you') : (titleName + ' requested ZEC from you')));
                return Text(label, style: Theme.of(context).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w700));
              }),
              if (visibleBody.isNotEmpty) const Gap(6),
            ],
            if (hasValidReplyTarget)
              InkWell(
                onTap: () async {
                  try {
                    // Begin stepping from current bubble so chevron can walk back down
                    _startSteppingIfNeeded(bubbleId);
                    final key = targetBubbleId != null ? _bubbleKeys[targetBubbleId!] : null;
                    if (key?.currentContext != null) {
                      await Scrollable.ensureVisible(
                        key!.currentContext!,
                        alignment: 0.5,
                        duration: const Duration(milliseconds: 450),
                        curve: Curves.easeInOutCubic,
                      );
                      setState(() { _highlightId = targetBubbleId; _pulseController.repeat(reverse: true); });
                      Future.delayed(const Duration(seconds: 2), () { if (mounted) { _pulseController.stop(); setState(() { _highlightId = null; }); } });
                    } else {
                      setState(() {});
                      await Future.delayed(const Duration(milliseconds: 16));
                      final key2 = targetBubbleId != null ? _bubbleKeys[targetBubbleId!] : null;
                      if (key2?.currentContext != null) {
                        await Scrollable.ensureVisible(
                          key2!.currentContext!,
                          alignment: 0.5,
                          duration: const Duration(milliseconds: 450),
                          curve: Curves.easeInOutCubic,
                        );
                        setState(() { _highlightId = targetBubbleId; _pulseController.repeat(reverse: true); });
                        Future.delayed(const Duration(seconds: 2), () { if (mounted) { _pulseController.stop(); setState(() { _highlightId = null; }); } });
                      }
                    }
                  } catch (_) {}
                },
                child: Container(
                  margin: const EdgeInsets.only(bottom: 4),
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                  decoration: BoxDecoration(
                    color: Colors.black.withOpacity(0.12),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  alignment: Alignment.center,
                  child: Builder(builder: (context) {
                    String label = 'Replied to #$inReplyToStr';
                    try {
                      if (targetBubbleId != null) {
                        final target = thread.messages.firstWhere((mm) {
                          final hh = _parseHeader(mm);
                          return (hh['conversation_id'] ?? '').trim() == cid && (hh['seq'] ?? '').trim() == inReplyToStr;
                        }, orElse: () => m);
                        final raw = target.body.trim();
                        if (raw.isNotEmpty) {
                          final sample = raw.length > 44 ? raw.substring(0, 44) + '…' : raw;
                          label = sample;
                        }
                      }
                    } catch (_) {}
                    return Text(label, style: TextStyle(color: Theme.of(context).colorScheme.onSurface, fontSize: 12, fontFamily: balanceFontFamily));
                  }),
                ),
              ),
            if (_firstFramePainted)
                if (statusText != null)
                  Text(
                    statusText,
                    style: TextStyle(
                      color: incoming ? Colors.white70 : Colors.black87,
                      fontWeight: FontWeight.w600,
                      fontFamily: balanceFontFamily,
                    ),
                  )
                else if (PhotoDecoder.isPhotoChunk(m.body))
                  _buildPhotoDisplay(m, hdr)
                else
                  Text(
                    visibleBody,
                    style: TextStyle(color: incoming ? Colors.white : Colors.black, fontFamily: balanceFontFamily),
                  )
            else if (PhotoDecoder.isPhotoChunk(m.body))
              _buildPhotoDisplay(m, hdr)
            else
              Text(
                visibleBody,
                style: TextStyle(color: incoming ? Colors.white : Colors.black, fontFamily: balanceFontFamily),
              ),
            // Add "Send ZEC" button for incoming request messages
            if (typeStr == 'request' && incoming && amountStrForPayment.isNotEmpty) ...[
              const Gap(12),
              SizedBox(
                height: 42,
                child: Material(
                  color: const Color(0xFFF4B728),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                  child: InkWell(
                    borderRadius: BorderRadius.circular(12),
                    onTap: () {
                      _sendZecForRequest(m, hdr, amountStrForPayment);
                    },
                    child: Center(
                      child: Text(
                        'Send ZEC',
                        style: Theme.of(context).textTheme.titleSmall?.copyWith(
                          fontWeight: FontWeight.w600,
                          color: Colors.black,
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ],
        );

        // Prepare reaction chips overlay for this bubble
            final Map<String, Set<String>>? _keyCounts = () {
          try {
            if (cid.isEmpty || seqStr.isEmpty) return null;
            final bubbleId = _bubbleIdForMessage(m, cid: cid, seqStr: seqStr);
            return reactionsByBubbleId[bubbleId];
          } catch (_) { return null; }
        }();
        final Map<String, int> reactionCounts = (_keyCounts == null || _keyCounts.isEmpty)
            ? const <String, int>{}
            : {for (final e in _keyCounts.entries) e.key: e.value.length};
        final Set<String> myTokens = (_keyCounts == null || _keyCounts.isEmpty)
            ? <String>{}
            : {for (final e in _keyCounts.entries) if (e.value.contains('me')) e.key};
        // Render circular reaction chips: color by who reacted (me -> outgoing/orange, others -> incoming/grey)
        Widget buildReactionOverlay(Map<String, int> counts, Set<String> myTokens, {required bool incoming}) {
          if (counts.isEmpty) return const SizedBox.shrink();
          final entries = counts.entries.toList()
            ..sort((a, b) => b.value != a.value ? (b.value - a.value) : a.key.compareTo(b.key));
          final limited = entries.take(8).toList();
          const double chipSize = 36.0; // 50% larger than previous 24
          const double fontSize = 24.0;
          const Color incomingFill = Color(0xFF2E2C2C);
          const Color outgoingFill = Color(0xFFF4B728);
          // Slightly darken the outgoing gold for better contrast with emoji glyphs
          final Color outgoingChipFill = Color.lerp(outgoingFill, Colors.black, 0.16) ?? outgoingFill;
          return Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              for (final e in limited) ...[
                Stack(
                  clipBehavior: Clip.none,
                  alignment: Alignment.center,
                  children: [
                    Container(
                      width: chipSize,
                      height: chipSize,
                      decoration: const BoxDecoration(shape: BoxShape.circle),
                      child: DecoratedBox(
                        decoration: BoxDecoration(shape: BoxShape.circle, color: (myTokens.contains(e.key) ? outgoingChipFill : incomingFill)),
                        child: Center(
                          child: Text(
                            emojiCharForToken(e.key),
                            style: const TextStyle(
                              fontSize: fontSize,
                              height: 1.0,
                              fontFamilyFallback: [
                                'Noto Color Emoji',
                                'Apple Color Emoji',
                                'Segoe UI Emoji',
                                'EmojiOne Color',
                                'Twemoji Mozilla',
                              ],
                              shadows: [
                                Shadow(color: Color(0x8C000000), blurRadius: 3, offset: Offset(0, 0)),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ),
                    if (e.value > 1)
                      Positioned(
                        right: -8,
                        bottom: -8,
                        child: Container(
                          padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
                          decoration: BoxDecoration(
                            color: (myTokens.contains(e.key) ? outgoingChipFill : incomingFill),
                            borderRadius: BorderRadius.circular(8),
                          ),
                          child: Text('x${e.value}', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: (myTokens.contains(e.key) ? Colors.black : Colors.white))),
                        ),
                      ),
                  ],
                ),
                const SizedBox(width: 6),
              ],
            ],
          );
        }

        // Speech bubble with tail (nip) per direction
        final bubbleCoreBase = _ChatBubble(
          key: key,
          incoming: incoming,
          color: blended,
          radius: 20,
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          margin: incoming
              ? const EdgeInsets.only(right: 8)
              : const EdgeInsets.only(left: 8),
          child: contentColumn,
        );

        // Reserve vertical space equal to the upward chip overlap when reactions are present
        // so elements above do not cover the chips. Keep it tight to avoid large gaps.
        final double chipOverlapUp = 36.0 * 0.60; // must match Positioned top offset math below
        final double chipBand = reactionCounts.isNotEmpty ? chipOverlapUp : 0.0;
        final bubbleCore = Container(
          padding: EdgeInsets.only(top: chipBand),
          child: Stack(
            clipBehavior: Clip.none,
            children: [
              bubbleCoreBase,
              if (reactionCounts.isNotEmpty)
                Positioned(
                  top: -chipBand,
                  left: incoming ? null : -6, // nudge outward from left edge for outgoing
                  right: incoming ? -6 : null, // nudge outward from right edge for incoming
                  child: buildReactionOverlay(reactionCounts, myTokens, incoming: incoming),
                ),
            ],
          ),
        );

        final bool animateThis = !_debugNoAnimations && _firstFramePainted && index == list.length - 1 && _nearBottomReversed();
        // Animate freshly inserted optimistic invite with a subtle slide+fade
        final bool isNewestIndex = (index == 0); // reverse: true → newest at index 0
        final bool isOptimistic = (m.id == -1) || (statusText == 'Sending…');
        final bool isInvite = (typeStr == 'invite');
        final bool shouldAnimateInvite = kEnableInviteEnterAnimation && _pendingJustAdded && isNewestIndex && isOptimistic && isInvite;

        // NEW: Animate any new message (incoming or outgoing) that hasn't been rendered before
        final bool isNewBubble = _firstFramePainted && !_renderedBubbleIds.contains(bubbleId);
        final bool shouldAnimateNewMessage = isNewBubble && !shouldAnimateInvite; // Don't double-animate invites

        // Mark this bubble as rendered (do this before build completes)
        if (isNewBubble) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            _renderedBubbleIds.add(bubbleId);
          });
        }

        final Widget bubbleAnimated = (shouldAnimateInvite || shouldAnimateNewMessage)
            ? TweenAnimationBuilder<double>(
                tween: Tween<double>(begin: 0.0, end: 1.0),
                duration: const Duration(milliseconds: 280),
                curve: Curves.easeOutCubic,
                child: bubbleCore,
                builder: (context, value, child) {
                  final double dy = (1.0 - value) * 12.0; // subtle slide up
                  return Opacity(
                    opacity: value,
                    child: Transform.translate(
                      offset: Offset(0, dy),
                      child: child,
                    ),
                  );
                },
              )
            : bubbleCore;

        final Widget row = Row(
          mainAxisAlignment: incoming ? MainAxisAlignment.start : MainAxisAlignment.end,
          children: [
            Flexible(
              fit: FlexFit.loose,
              child: Align(
                alignment: incoming ? Alignment.centerLeft : Alignment.centerRight,
                child: ConstrainedBox(
                  constraints: BoxConstraints(
                    maxWidth: MediaQuery.of(context).size.width * 0.82,
                  ),
                  child: GestureDetector(
                    onLongPressStart: (d) => _showMessageMenuAtPosition(context, m, d.globalPosition),
                    onSecondaryTapDown: (d) => _showMessageMenuAtPosition(context, m, d.globalPosition),
                    child: bubbleAnimated,
                  ),
                ),
              ),
            ),
          ],
        );
        return Padding(
          key: ValueKey('item::' + bubbleId),
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: row,
        );
      },
    );
  }

  void reply() {
    if (thread.address == null || thread.address!.isEmpty) return;
    final memo = MemoData(true, '', '');
    // Build SendContext with thread metadata: prefer current cid_map_<cid> mapping
    final String displayName = thread.title;
    String? cid;
    try {
      for (final m in thread.messages.reversed) {
        final h = _parseHeader(m);
        final c = (h['conversation_id'] ?? '').trim();
        if (c.isNotEmpty) { cid = c; break; }
      }
    } catch (_) {}
    String resolvedAddress = (thread.address ?? '').trim();
    if ((cid ?? '').isNotEmpty) {
      try {
        final map = WarpApi.getProperty(aa.coin, 'cid_map_' + cid!).trim();
        if (map.isNotEmpty) resolvedAddress = map;
      } catch (_) {}
    }
    final sc = SendContext(
      resolvedAddress,
      7,
      Amount(0, false),
      memo,
      marketPrice.price,
      displayName,
      true,
      widget.index,
      cid,
    );
    GoRouter.of(context).push('/account/quick_send', extra: sc);
  }

  void requestFromThread() {
    if (thread.address == null || thread.address!.isEmpty) return;
    try { aa.updateDivisified(); } catch (_) {}
    // Gather thread context similar to reply()
    final String displayName = thread.title;
    String? cid;
    try {
      for (final m in thread.messages.reversed) {
        final h = _parseHeader(m);
        final c = (h['conversation_id'] ?? '').trim();
        if (c.isNotEmpty) { cid = c; break; }
      }
    } catch (_) {}
    String resolvedAddress = (thread.address ?? '').trim();
    if ((cid ?? '').isNotEmpty) {
      try {
        final map = WarpApi.getProperty(aa.coin, 'cid_map_' + cid!).trim();
        if (map.isNotEmpty) resolvedAddress = map;
      } catch (_) {}
    }
    // Pass thread context as extra data to request page
    final extras = {
      'fromThread': true,
      'threadIndex': widget.index,
      'threadCid': cid,
      'threadAddress': resolvedAddress,
      'threadDisplayName': displayName,
    };
    GoRouter.of(context).push('/account/request?mode=4', extra: extras);
  }

  Future<void> _pickAndSendPhoto() async {
    try {
      // 1. Check thread is ready
      if (thread.address == null || thread.address!.isEmpty) {
        await showMessageBox2(context, 'Error', 'No recipient address');
        return;
      }
      
      // 2. Pick photo
      final result = await FilePicker.platform.pickFiles(
        type: FileType.image,
        allowMultiple: false,
      );
      
      if (result == null || result.files.isEmpty) return;
      
      final filePath = result.files.single.path;
      if (filePath == null) return;
      
      // 3. Read photo bytes
      final file = File(filePath);
      final imageBytes = await file.readAsBytes();
      
      // 4. Get thread context
      String? cid;
      try {
        for (final m in thread.messages.reversed) {
          final h = _parseHeader(m);
          final c = (h['conversation_id'] ?? '').trim();
          if (c.isNotEmpty) { cid = c; break; }
        }
      } catch (_) {}
      
      if (cid == null || cid.isEmpty) {
        await showMessageBox2(context, 'Error', 'No conversation ID');
        return;
      }
      
      // 5. Get next sequence number
      final seqKey = cid;
      final currentSeq = _inFlightNextSeq[seqKey] ?? 0;
      final nextSeq = currentSeq + 1;
      _inFlightNextSeq[seqKey] = nextSeq;
      
      // 6. Encode photo
      final chunks = await PhotoEncoder.encodePhoto(imageBytes, cid, nextSeq);
      
      // 7. Navigate to send photo page
      String resolvedAddress = thread.address!.trim();
      if (cid.isNotEmpty) {
        try {
          final map = WarpApi.getProperty(aa.coin, 'cid_map_' + cid).trim();
          if (map.isNotEmpty) resolvedAddress = map;
        } catch (_) {}
      }
      
      final photoContext = PhotoSendContext(
        address: resolvedAddress,
        chunks: chunks,
        cid: cid,
        seq: nextSeq,
        displayName: thread.title,
        threadIndex: widget.index,
      );
      
      GoRouter.of(context).push('/account/send_photo', extra: photoContext);
    } catch (e) {
      await showMessageBox2(context, 'Error', 'Failed to pick photo: $e');
    }
  }

  // Build photo display widget
  Widget _buildPhotoDisplay(ZMessage m, Map<String, String> hdr) {
    try {
      final chunk = PhotoDecoder.parseChunk(m);
      if (chunk == null) {
        return Container(
          padding: EdgeInsets.all(8),
          child: Text(
            'Invalid photo chunk',
            style: TextStyle(color: Colors.red, fontSize: 12),
          ),
        );
      }
      
      final photoBytes = _reassembledPhotos[chunk.photoId];
      final decodingState = _photoDecodingStates[chunk.photoId];
      
      if (photoBytes != null) {
        // Photo is complete, display it
        return GestureDetector(
          onTap: () {
            try {
              Navigator.of(context).push(
                MaterialPageRoute(
                  builder: (context) => PhotoViewerPage(photoBytes: photoBytes),
                  fullscreenDialog: true,
                ),
              );
            } catch (e) {
              print('Error opening photo viewer: $e');
            }
          },
          child: FutureBuilder<ui.Image?>(
            future: PhotoDecoder.decodePhoto(photoBytes),
            builder: (context, snapshot) {
              if (snapshot.hasError) {
                return Container(
                  padding: EdgeInsets.all(8),
                  child: Text(
                    'Error loading photo',
                    style: TextStyle(color: Colors.red, fontSize: 12),
                  ),
                );
              }
              
              if (!snapshot.hasData) {
                return Container(
                  width: 200,
                  height: 200,
                  decoration: BoxDecoration(
                    color: Colors.grey[300],
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Center(child: CircularProgressIndicator()),
                );
              }
              
              final image = snapshot.data!;
              final aspectRatio = image.width / image.height;
              final maxWidth = 250.0;
              final maxHeight = 300.0;
              
              double displayWidth = image.width.toDouble();
              double displayHeight = image.height.toDouble();
              
              if (displayWidth > maxWidth) {
                displayWidth = maxWidth;
                displayHeight = displayWidth / aspectRatio;
              }
              if (displayHeight > maxHeight) {
                displayHeight = maxHeight;
                displayWidth = displayHeight * aspectRatio;
              }
              
              return Container(
                width: displayWidth,
                height: displayHeight,
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: Colors.white.withOpacity(0.3), width: 1),
                ),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(8),
                  child: CustomPaint(
                    size: Size(displayWidth, displayHeight),
                    painter: _ImagePainter(image),
                  ),
                ),
              );
            },
          ),
        );
      } else if (decodingState != null) {
      // Photo is incomplete, show progress with better error handling
      final totalChunks = decodingState.chunks.first.totalChunks;
      final receivedChunks = decodingState.chunks.length;
      final progress = decodingState.progress;
      
      // Check if we're making progress (new chunks arrived recently)
      final timeSinceUpdate = DateTime.now().difference(decodingState.lastUpdated);
      final isStale = timeSinceUpdate.inMinutes > 5; // Consider stale after 5 minutes
      
      return Container(
        padding: EdgeInsets.all(8),
        decoration: BoxDecoration(
          color: Colors.grey[800]!.withOpacity(0.5),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (isStale)
              Padding(
                padding: EdgeInsets.only(bottom: 4),
                child: Text(
                  'Waiting for remaining chunks...',
                  style: TextStyle(fontSize: 10, color: Colors.white60),
                ),
              ),
            CircularProgressIndicator(
              value: progress,
              strokeWidth: 2,
            ),
            SizedBox(height: 8),
            Text(
              'Loading photo: $receivedChunks/$totalChunks chunks',
              style: TextStyle(fontSize: 12, color: Colors.white70),
            ),
            if (totalChunks > 0 && receivedChunks < totalChunks)
              Padding(
                padding: EdgeInsets.only(top: 4),
                child: Text(
                  'Missing ${totalChunks - receivedChunks} chunk(s)',
                  style: TextStyle(fontSize: 10, color: Colors.white60),
                ),
              ),
          ],
        ),
      );
    } else {
      // Photo chunks not yet collected - show placeholder
      final totalChunks = chunk.totalChunks;
      return Container(
        padding: EdgeInsets.all(8),
        decoration: BoxDecoration(
          color: Colors.grey[800]!.withOpacity(0.3),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.image, size: 16, color: Colors.white70),
            SizedBox(width: 8),
            Text(
              'Photo chunk ${chunk.chunkIndex + 1}/$totalChunks',
              style: TextStyle(fontSize: 12, color: Colors.white70),
            ),
          ],
        ),
      );
    }
    } catch (e) {
      return Container(
        padding: EdgeInsets.all(8),
        child: Text(
          'Error displaying photo: $e',
          style: TextStyle(color: Colors.red, fontSize: 12),
        ),
      );
    }
  }

  void _sendZecForRequest(ZMessage requestMsg, Map<String, String> hdr, String amountStr) {
    if (thread.address == null || thread.address!.isEmpty) return;
    
    // Extract amount in zatoshis from header
    int zats = 0;
    try {
      final amountZatStr = (hdr['amount_zat'] ?? '').trim();
      if (amountZatStr.isNotEmpty) {
        zats = int.tryParse(amountZatStr) ?? 0;
      }
    } catch (_) {}
    
    // Extract memo text (strip header)
    String memoText = '';
    try {
      final body = requestMsg.body.trim();
      final lines = body.split('\n');
      // Skip header line and blank line
      if (lines.length > 2) {
        memoText = lines.skip(2).join('\n').trim();
      }
    } catch (_) {}
    
    // Get conversation details
    final String displayName = thread.title;
    String? cid;
    try {
      for (final m in thread.messages.reversed) {
        final h = _parseHeader(m);
        final c = (h['conversation_id'] ?? '').trim();
        if (c.isNotEmpty) { cid = c; break; }
      }
    } catch (_) {}
    
    String resolvedAddress = (thread.address ?? '').trim();
    if ((cid ?? '').isNotEmpty) {
      try {
        final map = WarpApi.getProperty(aa.coin, 'cid_map_' + cid!).trim();
        if (map.isNotEmpty) resolvedAddress = map;
      } catch (_) {}
    }
    
    // Create SendContext with pre-filled amount and memo
    final sc = SendContext(
      resolvedAddress,
      7,
      Amount(zats, false),
      MemoData(true, '', memoText),
      marketPrice.price,
      displayName,
      true,
      widget.index,
      cid,
    );
    GoRouter.of(context).push('/account/quick_send', extra: sc);
  }

  // Invite detection in this thread
  _ThreadInviteInfo? _pendingInviteForThread() {
    try {
      String? cid;
      int? seq;
      String? replyUA;
      for (final m in thread.messages.reversed) {
        if (m.incoming) {
          final hdr = _parseHeader(m);
          if ((hdr['type'] ?? '') == 'invite') {
            cid = hdr['conversation_id'];
            try { seq = int.parse(hdr['seq'] ?? '1'); } catch (_) { seq = 1; }
            final rtu = (hdr['reply_to_ua'] ?? '').trim();
            replyUA = rtu.isEmpty ? null : rtu;
            break;
          }
        }
      }
      if (cid == null || cid.isEmpty) return null;
      // Check whether we already sent accept for this cid
      bool hasOutgoingAccept = false;
      for (final m in thread.messages) {
        if (!m.incoming) {
          final hdr = _parseHeader(m);
          if ((hdr['type'] ?? '') == 'accept' && (hdr['conversation_id'] ?? '') == cid) {
            hasOutgoingAccept = true;
            break;
          }
        }
      }
      return _ThreadInviteInfo(cid: cid, inviteSeq: seq ?? 1, hasOutgoingAccept: hasOutgoingAccept, replyUA: replyUA);
    } catch (_) {
      return null;
    }
  }

  Future<void> _sendAcceptForThread(_ThreadInviteInfo info) async {
    try {
      // Require Display Name (first name) before accepting chat request
      if (!_hasDisplayName()) {
        final proceed = await _promptDisplayNameNeeded();
        if (proceed) _goToDisplayNamePrompt();
        return;
      }
      // Show persistent sending overlay instead of warning dialog
      final sending = SendingOverlayController();
      try {
        sending.show(context);
        if (kEnableAcceptThreadStageFade) {
          setState(() { _acceptThreadVisible = false; });
          await Future.delayed(const Duration(milliseconds: kAcceptFadeDelayMs));
          setState(() { _acceptThreadVisible = true; });
        }
      } catch (_) {}
      final addr = (info.replyUA ?? '').trim();
      if (addr.isEmpty) {
        showSnackBar('Invite is missing reply-to address');
        return;
      }
      // Validate Orchard-capable - skip for CLOAK
      if (!CloakWalletManager.isCloak(aa.coin)) {
        try {
          final rcv = WarpApi.receiversOfAddress(aa.coin, addr);
          if ((rcv & 4) == 0) {
            showSnackBar('Invite reply-to address is not Orchard-capable');
            return;
          }
        } catch (_) {
          showSnackBar('Invalid reply-to address in invite');
          return;
        }
      }
      // Use a fresh diversified reply-to UA for this account
      // For CLOAK, use wallet primary address
      String replyToUA = '';
      if (CloakWalletManager.isCloak(aa.coin)) {
        replyToUA = CloakWalletManager.getDefaultAddress() ?? '';
      } else {
        try {
          final t = DateTime.now().millisecondsSinceEpoch ~/ 1000;
          replyToUA = WarpApi.getDiversifiedAddress(aa.coin, aa.id, 4, t);
        } catch (_) {}
      }
      if (replyToUA.isEmpty) {
        showSnackBar('Reply-to address not set for this contact. Open Contact Info to set it.');
        return;
      }

      // Helper for property access
      final isCloak = CloakWalletManager.isCloak(aa.coin);
      Future<void> setPropAsync(String key, String value) async {
        if (isCloak) {
          await CloakDb.setProperty(key, value);
        } else {
          try { WarpApi.setProperty(aa.coin, key, value); } catch (_) {}
        }
      }
      Future<String> getPropAsync(String key) async {
        if (isCloak) {
          return await CloakDb.getProperty(key) ?? '';
        } else {
          try { return WarpApi.getProperty(aa.coin, key); } catch (_) { return ''; }
        }
      }

      // Derive contact details from the received invite (not from our accept)
      // Persist cid -> UA mapping (idempotent)
      await setPropAsync('cid_map_' + info.cid, addr);
      // Prefer inviter name stored when processing the invite
      String inviterName = '';
      inviterName = (await getPropAsync('cid_name_' + info.cid)).trim();
      if (inviterName.isEmpty) {
        // Fallback: parse name from the invite header in this thread
        try {
          for (final m in thread.messages.reversed) {
            final h = _parseHeader(m);
            if ((h['type'] ?? '') == 'invite' && (h['conversation_id'] ?? '') == info.cid) {
              final fn = (h['first_name'] ?? '').trim();
              final ln = (h['last_name'] ?? '').trim();
              inviterName = (fn + ' ' + ln).trim();
              break;
            }
          }
        } catch (_) {}
      }
      final validName = (inviterName.isNotEmpty && !_isAddressLike(inviterName)) ? inviterName : '';
      if (validName.isNotEmpty) {
        // Skip if blocked
        try {
          final blocked = await getPropAsync('contact_block_' + addr);
          if (blocked.trim() != '1') {
            int? existingId;
            try {
              for (final c in contacts.contacts) {
                final t = c.unpack();
                if ((t.address ?? '').trim() == addr) { existingId = t.id; break; }
              }
            } catch (_) {}
            if (isCloak) {
              if (existingId != null) {
                await CloakDb.updateContact(existingId, name: validName, address: addr);
              } else {
                await CloakDb.addContact(name: validName, address: addr);
              }
            } else {
              try { WarpApi.storeContact(aa.coin, existingId ?? 0, validName, addr, true); } catch (_) {}
            }
            try { contacts.fetchContacts(); } catch (_) {}
          }
        } catch (_) {}
      }

      // Build accept header with display name (first/last)
      String fn = (await getPropAsync('my_first_name')).trim();
      String ln = (await getPropAsync('my_last_name')).trim();
      final header = 'v1; type=accept; conversation_id=' + info.cid + '; seq=2; in_reply_to_seq=' + info.inviteSeq.toString() + '; reply_to_ua=' + replyToUA +
          (fn.isNotEmpty ? '; first_name=' + fn : '') + (ln.isNotEmpty ? '; last_name=' + ln : '');
      final memo = header + '\n\n';

      // Optimistic pending message in the thread
      final pending = ZMessage(
        -1,
        0,
        false,
        '',
        addr,
        addr,
        'Sending…',
        memo,
        DateTime.now(),
        aa.height,
        true,
      );
      try {
        aa.messages.items = List<ZMessage>.from(aa.messages.items)..add(pending);
        _pendingJustAdded = true;
        // Mark accept as done (sticky) and record for one-time animation
        await setPropAsync('cid_accept_done_' + info.cid, '1');
        _acceptJustAddedCid = info.cid;
        // Locally append to current thread so UI shows both invite and accept
        try {
          final local = List<ZMessage>.from(thread.messages)..add(pending);
          thread = MessageThread(
            key: thread.key,
            title: thread.title,
            address: thread.address,
            messages: local,
            unreadCount: thread.unreadCount,
            lastTimestamp: DateTime.now(),
          );
        } catch (_) {}
        // Push a global echo for MESSAGES union
        try { optimisticEchoes.add(pending); } catch (_) {}
        setState(() {});
        WidgetsBinding.instance.addPostFrameCallback((_) async {
          // Delay initial auto-scroll so it doesn't compete with route animation
          try { await Future.delayed(const Duration(milliseconds: 350)); } catch (_) {}
          if (_threadController.hasClients && _nearBottomReversed()) {
            _threadController.animateTo(
              _threadController.position.minScrollExtent, // reverse: true → bottom is min
              duration: const Duration(milliseconds: 450),
              curve: Curves.easeInOutCubic,
            );
          }
          // Reset the just-added flag shortly after the entrance animation window
          try { await Future.delayed(const Duration(milliseconds: 220)); } catch (_) {}
          if (mounted) { setState(() { _pendingJustAdded = false; }); }
        });
      } catch (_) {}
      // memo already constructed above with first_name/last_name when available

      // Send the accept transaction
      String? txResult;
      if (isCloak) {
        // CLOAK: Use CloakWalletManager
        try { sending.setStatus('Preparing…'); } catch (_) {}
        txResult = await CloakWalletManager.sendAccept(
          recipientAddress: addr,
          conversationId: info.cid,
          seq: 2,
          replyToUa: replyToUA,
          firstName: fn.isNotEmpty ? fn : null,
          lastName: ln.isNotEmpty ? ln : null,
          amount: 0,
        );
        if (txResult == null) {
          throw Exception('CLOAK accept transaction failed');
        }
      } else {
        // Zcash/Ycash: Use WarpApi
        final int recipientPools = 4;
        final builder = RecipientObjectBuilder(
          address: addr,
          pools: recipientPools,
          amount: 0, // zero-value memo-only; pay fee only
          feeIncluded: false,
          replyTo: false,
          subject: '',
          memo: memo,
        );
        final recipient = Recipient(builder.toBytes());
        try { sending.setStatus('Preparing…'); } catch (_) {}
        final plan = await WarpApi.prepareTx(
          aa.coin,
          aa.id,
          [recipient],
          7,
          coinSettings.replyUa,
          appSettings.anchorOffset,
          coinSettings.feeT,
        );
        try { sending.setStatus('Signing…'); } catch (_) {}
        final signedTx = await WarpApi.signOnly(aa.coin, aa.id, plan);
        try { sending.setStatus('Broadcasting…'); } catch (_) {}
        txResult = await WarpApi.broadcast(aa.coin, signedTx);
      }
      try { await sending.hide(); } catch (_) {}
      try { triggerManualSync(); } catch (_) {}
      // Persist my seq for this cid so next message starts at 3
      await setPropAsync('cid_my_seq_' + info.cid, '2');
      // Update pending to Sent
      try {
        final updated = aa.messages.items.toList();
        final idx = updated.lastIndexWhere((m) => identical(m, pending));
        if (idx >= 0) {
          final sent = ZMessage(
            pending.id,
            pending.txId,
            pending.incoming,
            pending.fromAddress,
            pending.sender,
            pending.recipient,
            'Sent',
            pending.body,
            pending.timestamp,
            pending.height,
            pending.read,
          );
          updated[idx] = sent;
          aa.messages.items = updated;
          // Update local thread copy
          try {
            final local = List<ZMessage>.from(thread.messages);
            int li = -1;
            for (int i = local.length - 1; i >= 0; i--) {
              if (identical(local[i], pending) || _sameHeader(local[i].body, pending.body)) { li = i; break; }
            }
            if (li >= 0) {
              local[li] = sent;
              thread = MessageThread(
                key: thread.key,
                title: thread.title,
                address: thread.address,
                messages: local,
                unreadCount: thread.unreadCount,
                lastTimestamp: DateTime.now(),
              );
            }
          } catch (_) {}
          // Update global echo copy if present
          try {
            final key = _headerKey(pending.body);
            for (int i = optimisticEchoes.length - 1; i >= 0; i--) {
              if (_headerKey(optimisticEchoes[i].body) == key) {
                optimisticEchoes[i] = sent; break;
              }
            }
          } catch (_) {}
          setState(() {});
        }
      } catch (_) {}
    } catch (e) {
      showSnackBar('Failed to accept chat request');
      try { SendingOverlayController().hide(); } catch (_) {}
    }
  }

  // Removed warning dialog; persistent overlay is used instead

  bool _hasDisplayName() {
    try {
      final first = WarpApi.getProperty(aa.coin, 'my_first_name');
      return first.trim().isNotEmpty;
    } catch (_) {
      return false;
    }
  }

  void _goToDisplayNamePrompt() {
    try {
      GoRouter.of(context).push('/contacts_overlay/display_name');
    } catch (_) {}
  }

  void _showMessageHeaders(BuildContext context, String body) {
    try {
      showDialog<void>(
        context: context,
        barrierDismissible: true,
        builder: (ctx) {
          return AlertDialog(
            title: const Text('Message Headers'),
            content: SingleChildScrollView(
              child: SelectableText(
                body,
                style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(ctx).pop(),
                child: const Text('Close'),
              ),
            ],
          );
        },
      );
    } catch (_) {}
  }

  void _showChatInitiatedHeaders(BuildContext context, String cid, List<ZMessage> messages) {
    try {
      if (cid.isEmpty) {
        // If no CID, try to find messages by scanning all messages
        final StringBuffer sb = StringBuffer();
        sb.writeln('=== ALL INVITE AND ACCEPT MESSAGES IN THREAD ===');
        sb.writeln();
        
        int inviteCount = 0;
        int acceptCount = 0;
        for (final m in messages) {
          final hdr = _parseHeader(m);
          final type = (hdr['type'] ?? '').trim();
          if (type == 'invite') {
            inviteCount++;
            sb.writeln('=== INVITE MESSAGE #$inviteCount ===');
            sb.writeln(m.body);
            sb.writeln();
          } else if (type == 'accept') {
            acceptCount++;
            sb.writeln('=== ACCEPT MESSAGE #$acceptCount ===');
            sb.writeln(m.body);
            sb.writeln();
          }
        }
        
        if (inviteCount == 0 && acceptCount == 0) {
          sb.writeln('No invite or accept messages found in thread.');
        }
        
        showDialog<void>(
          context: context,
          barrierDismissible: true,
          builder: (ctx) {
            return AlertDialog(
              title: const Text('CHAT INITIATED Headers'),
              content: SingleChildScrollView(
                child: SelectableText(
                  sb.toString(),
                  style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.of(ctx).pop(),
                  child: const Text('Close'),
                ),
              ],
            );
          },
        );
        return;
      }
      
      // Find both invite and accept messages for this CID
      ZMessage? inviteMsg;
      ZMessage? acceptMsg;
      
      for (final m in messages) {
        try {
          final hdr = _parseHeader(m);
          final msgCid = (hdr['conversation_id'] ?? '').trim();
          final type = (hdr['type'] ?? '').trim();
          
          if (msgCid == cid) {
            if (type == 'invite' && inviteMsg == null) {
              inviteMsg = m;
            } else if (type == 'accept' && acceptMsg == null) {
              acceptMsg = m;
            }
          }
        } catch (_) {
          // Skip messages that can't be parsed
          continue;
        }
      }
      
      // Build display text with both messages
      final StringBuffer sb = StringBuffer();
      sb.writeln('Conversation ID: $cid');
      sb.writeln();
      
      if (inviteMsg != null) {
        sb.writeln('=== INVITE MESSAGE ===');
        sb.writeln('ID: ${inviteMsg.id}');
        sb.writeln('Incoming: ${inviteMsg.incoming}');
        sb.writeln('Sender: ${inviteMsg.sender ?? "N/A"}');
        sb.writeln('Recipient: ${inviteMsg.recipient}');
        sb.writeln('---');
        sb.writeln(inviteMsg.body);
        sb.writeln();
      } else {
        sb.writeln('=== INVITE MESSAGE ===');
        sb.writeln('(Not found in thread for CID: $cid)');
        sb.writeln();
      }
      
      if (acceptMsg != null) {
        sb.writeln('=== ACCEPT MESSAGE ===');
        sb.writeln('ID: ${acceptMsg.id}');
        sb.writeln('Incoming: ${acceptMsg.incoming}');
        sb.writeln('Sender: ${acceptMsg.sender ?? "N/A"}');
        sb.writeln('Recipient: ${acceptMsg.recipient}');
        sb.writeln('---');
        sb.writeln(acceptMsg.body);
      } else {
        sb.writeln('=== ACCEPT MESSAGE ===');
        sb.writeln('(Not found in thread for CID: $cid)');
      }
      
      // Also show total message count for debugging
      sb.writeln();
      sb.writeln('Total messages in thread: ${messages.length}');
      
      showDialog<void>(
        context: context,
        barrierDismissible: true,
        builder: (ctx) {
          return AlertDialog(
            title: const Text('CHAT INITIATED Headers'),
            content: SingleChildScrollView(
              child: SelectableText(
                sb.toString(),
                style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(ctx).pop(),
                child: const Text('Close'),
              ),
            ],
          );
        },
      );
    } catch (e) {
      // Show error dialog if something goes wrong
      showDialog<void>(
        context: context,
        barrierDismissible: true,
        builder: (ctx) {
          return AlertDialog(
            title: const Text('Error'),
            content: Text('Failed to show headers: $e'),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(ctx).pop(),
                child: const Text('Close'),
              ),
            ],
          );
        },
      );
    }
  }

  Future<bool> _promptDisplayNameNeeded() async {
    try {
      bool confirmed = false;
      await showDialog<void>(
        context: context,
        barrierDismissible: true,
        builder: (ctx) {
          return AlertDialog(
            title: const Text('Display Name Needed'),
            content: const Text('Please create a display name.'),
            actions: [
              TextButton(
                onPressed: () { confirmed = true; Navigator.of(ctx).pop(); },
                child: const Text('OK'),
              ),
            ],
          );
        },
      );
      return confirmed;
    } catch (_) {
      return true;
    }
  }

  bool _isChatAcceptedForThread(String? addr) {
    // Prefer cid-based acceptance: any memo in this thread with type=accept
    try {
      // Determine cid from any header in the thread
      String? cid;
      for (final m in thread.messages.reversed) {
        final h = _parseHeader(m);
        final c = (h['conversation_id'] ?? '').trim();
        if (c.isNotEmpty) { cid = c; break; }
      }
      if (cid != null && cid.isNotEmpty) {
        // Sticky: consult persisted accept-done flag first
        try {
          final done = WarpApi.getProperty(aa.coin, 'cid_accept_done_' + cid).trim();
          if (done == '1') return true;
        } catch (_) {}
        for (final m in thread.messages) {
          final h = _parseHeader(m);
          if ((h['conversation_id'] ?? '') == cid && (h['type'] ?? '') == 'accept') return true;
        }
      }
    } catch (_) {}
    return false;
  }

  bool _sameHeader(String a, String b) {
    try {
      final ha = _parseHeaderFromBody(a).toString();
      final hb = _parseHeaderFromBody(b).toString();
      return ha == hb && ha.isNotEmpty;
    } catch (_) {
      return false;
    }
  }

  void _refreshThread() {
    try {
      // Preserve current thread key to maintain context after refresh
      final currentKey = thread.key;

      // Force reload from DB to catch any messages added by sync
      try {
        aa.messages.read(aa.height);
      } catch (_) {}
      // Use the same DB+optimistic union as the messages page so optimistic items appear in-thread
      final List<ZMessage> unionList = () {
        try {
          final db = aa.messages.items;
          final List<ZMessage> list = db.toList();
          for (final e in optimisticEchoes) {
            final k = _headerKeyOfMessage(e);
            if (k == null) continue;
            if (!list.any((m) => _headerKeyOfMessage(m) == k)) {
              list.add(e);
            }
          }
          return list;
        } catch (_) {
          return aa.messages.items;
        }
      }();
      threads = _buildThreads(unionList);
      // Find thread by preserved key (stable) instead of widget.index (can drift)
      final idx = threads.indexWhere((t) => t.key == currentKey);
      if (idx >= 0) {
        thread = threads[idx];
      } else {
        // Fallback to index if key not found
        final i = widget.index.clamp(0, threads.length > 0 ? threads.length - 1 : 0);
        thread = threads.isNotEmpty ? threads[i] : MessageThread(
          key: 'empty', title: 'Messages', address: null, messages: [], unreadCount: 0, lastTimestamp: DateTime.now(),
        );
      }
      // Trigger photo reassembly after thread refresh (important for receiving wallet)
      WidgetsBinding.instance.addPostFrameCallback((_) async {
        if (!mounted) return;
        await _reassemblePhotosFromThread();
      });
    } catch (_) {}
  }

  String _bubbleIdForMessage(ZMessage m, {String cid = '', String seqStr = ''}) {
    if (cid.isNotEmpty && seqStr.isNotEmpty) {
      return 'cid::$cid#seq::$seqStr#${m.incoming ? 'in' : 'out'}';
    }
    return 'msg::${m.id}::${m.txId}::${m.incoming ? 'in' : 'out'}';
  }

  Future<void> _scrollToCidSeq(String cid, String seqStr) async {
    try {
      if (cid.isEmpty || seqStr.isEmpty) return;
      final id = 'cid::$cid#seq::$seqStr#in';
      final id2 = 'cid::$cid#seq::$seqStr#out';
      final key = _bubbleKeys[id] ?? _bubbleKeys[id2];
      if (key?.currentContext != null) {
        await Scrollable.ensureVisible(key!.currentContext!, alignment: 0.5, duration: const Duration(milliseconds: 300), curve: Curves.easeOutCubic);
        setState(() { _highlightId = _bubbleKeys.entries.firstWhere((e) => e.value == key).key; });
        Future.delayed(const Duration(seconds: 2), () { if (mounted) setState(() { _highlightId = null; }); });
      }
    } catch (_) {}
  }

  void _showMessageMenuAtPosition(BuildContext context, ZMessage m, Offset globalPos) async {
    try {
      // Always close any existing overlays first so only one chooser/menu is visible
      try { _hideReactionChooser(); } catch (_) {}
      try { _hideContextMenu(); } catch (_) {}
      // Preload/refresh tx list so txId->index lookup is reliable
      try { aa.txs.read(aa.height); } catch (_) {}

      final hdr = _parseHeader(m);
      final type = (hdr['type'] ?? '').trim();
      final cid = (hdr['conversation_id'] ?? '').trim();
      final seqStr = (hdr['seq'] ?? '').trim();
      final bool isAccepted = _isChatAcceptedForThread(thread.address);
      // Mirror the input enablement logic from _buildBottomInputForThread
      final invite = _pendingInviteForThread();
      final bool replyableBase = (thread.address != null && thread.address!.isNotEmpty);
      final bool replyable = replyableBase || (invite?.replyUA?.isNotEmpty == true);
      final bool acceptedOrReplied = isAccepted || (invite != null && invite.hasOutgoingAccept);
      final bool isInputEnabled = replyable && acceptedOrReplied;
      final bool hasSeq = seqStr.isNotEmpty;
      final canReply = isInputEnabled && hasSeq; // allow reply on invite/accept/message
      final int txId = m.txId;
      final bool hasTxId = txId > 0;

      // Build lightweight custom context menu overlay so both can coexist and be interactive
      try { _menuOverlay?.remove(); } catch (_) {}
      _menuOverlay = null;
      final overlayBox = Overlay.of(context).context.findRenderObject() as RenderBox;
      final menuWidth = 220.0;
      double left = globalPos.dx;
      if (left + menuWidth > overlayBox.size.width - 8) left = overlayBox.size.width - menuWidth - 8;
      double top = globalPos.dy;
      if (top + 100 > overlayBox.size.height - 8) top = overlayBox.size.height - 100 - 8;

      _menuOverlay = OverlayEntry(builder: (ctx) {
        final theme = Theme.of(context);
        return Stack(children: [
          // Tap outside to dismiss
          Positioned.fill(
            child: GestureDetector(onTap: () { _hideReactionChooser(); _hideContextMenu(); }),
          ),
          Positioned(
            left: left,
            top: top,
            child: Material(
              color: Colors.transparent,
              child: Container(
                width: menuWidth,
                decoration: BoxDecoration(
                  color: theme.colorScheme.surface.withOpacity(0.98),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (canReply)
                      InkWell(
                        onTap: () {
                          final preview = _previewFromBody(m.body);
                          setState(() { _replyTarget = _ReplyTargetState(cid: cid, targetSeq: int.tryParse(seqStr), preview: preview); });
                          _hideReactionChooser();
                          _hideContextMenu();
                        },
                        child: const Padding(
                          padding: EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                          child: Text('Reply'),
                        ),
                      ),
                    InkWell(
                      onTap: hasTxId ? () {
                        gotoTxById(context, txId, from: 'messages', threadIndex: widget.index);
                        _hideReactionChooser();
                        _hideContextMenu();
                      } : null,
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                        child: Text('Transaction Details', style: TextStyle(color: hasTxId ? null : Colors.white54)),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ]);
      });
      Overlay.of(context).insert(_menuOverlay!);
      // Show reaction chooser for any bubble with a seq when input is enabled (invite/accept/message)
      if (isInputEnabled && hasSeq) {
        try { _showReactionChooserForMessage(m); } catch (_) {}
      }
    } catch (_) {}
  }

  void _hideContextMenu() {
    try { _menuOverlay?.remove(); } catch (_) {}
    _menuOverlay = null;
    setState(() {});
  }

  void _hideReactionChooser() {
    try {
      _reactionOverlay?.remove();
    } catch (_) {}
    _reactionOverlay = null;
    _reactionOverlayForBubbleId = null;
    setState(() {});
  }

  void _showReactionChooserForMessage(ZMessage m) async {
    try {
      // Close any existing chooser first
      _hideReactionChooser();
      final hdr = _parseHeader(m);
      final cid = (hdr['conversation_id'] ?? '').trim();
      final seqStr = (hdr['seq'] ?? '').trim();
      if (cid.isEmpty || seqStr.isEmpty) return;
      final bubbleId = _bubbleIdForMessage(m, cid: cid, seqStr: seqStr);
      final key = _bubbleKeys[bubbleId];
      if (key == null || key.currentContext == null) return;

      // Build chooser content
      List<String> emojis = _emojiMRU.isNotEmpty ? _emojiMRU : kDefaultEmojiTokens;
      emojis = filterAllowedTokens(emojis);
      // Ensure unique and valid tokens
      emojis = emojis.where((t) => t.isNotEmpty).toList();
      if (emojis.length < 7) {
        for (final d in kDefaultEmojiTokens) {
          if (!emojis.contains(d)) emojis.add(d);
          if (emojis.length >= 7) break;
        }
      }
      final chooser = (BuildContext overlayContext, Rect bubbleRect) {
        final theme = Theme.of(context);
        final size = MediaQuery.of(overlayContext).size;
        final width = size.width;
        final sideMargin = 8.0;
        final double top = bubbleRect.top - 56.0;

        // Compute anchoring and max width extending toward center
        double? left;
        double? right;
        double maxWidth;
        if (m.incoming) {
          left = bubbleRect.left;
          right = null;
          // Allow expansion toward the right up to screen margins
          final available = (width - left - sideMargin).clamp(160.0, width) as double;
          maxWidth = available;
      } else {
          left = null;
          right = width - bubbleRect.right;
          // Allow expansion toward the left up to screen margins
          final available = (width - right - sideMargin).clamp(160.0, width) as double;
          maxWidth = available;
        }

        return Positioned(
          top: math.max(0, top),
          left: left,
          right: right,
          child: Material(
            color: Colors.transparent,
            child: Container(
              constraints: BoxConstraints(maxWidth: maxWidth),
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
              decoration: BoxDecoration(
                color: theme.colorScheme.surface.withOpacity(0.98),
                borderRadius: BorderRadius.circular(16),
              ),
              child: SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    for (final token in emojis.take(7))
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 3),
                        child: InkWell(
                          borderRadius: BorderRadius.circular(14),
                          onTap: () async {
                            try {
                              final targetSeq = int.tryParse(seqStr);
                              if (targetSeq != null) {
                                await _sendReaction(cid: cid, targetSeq: targetSeq, emojiToken: token);
                                await updateEmojiMRU(token);
                                final updated = await loadEmojiMRU();
                                if (mounted) setState(() { _emojiMRU = updated; });
                              }
                            } catch (_) {}
                            _hideReactionChooser();
                          },
                          child: Container(
                            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
                            decoration: BoxDecoration(
                              color: theme.colorScheme.surfaceVariant,
                              borderRadius: BorderRadius.circular(12),
                            ),
                            child: SizedBox(
                              width: 28,
                              height: 28,
                              child: FittedBox(
                                fit: BoxFit.contain,
                                child: Text(
                                  emojiCharForToken(token),
                                  style: const TextStyle(
                                    fontSize: 28,
                                    height: 1.0,
                                    fontFamilyFallback: [
                                      'Noto Color Emoji',
                                      'Apple Color Emoji',
                                      'Segoe UI Emoji',
                                      'EmojiOne Color',
                                      'Twemoji Mozilla',
                                    ],
                                    shadows: [
                                      Shadow(color: Color(0x8C000000), blurRadius: 3, offset: Offset(0, 0)),
                                    ],
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ),
                      ),
                    // Chevron to open full picker
                    Padding(
                      padding: const EdgeInsets.only(left: 4),
                      child: InkWell(
                        borderRadius: BorderRadius.circular(16),
                        onTap: () async {
                          if (_emojiPickerOpen) return;
                          _hideReactionChooser();
                          _hideContextMenu();
                          _emojiPickerOpen = true;
                          final token = await _openEmojiPickerAll();
                          if (token != null && token.isNotEmpty) {
                            try {
                              final targetSeq = int.tryParse(seqStr);
                              if (targetSeq != null) {
                                await _sendReaction(cid: cid, targetSeq: targetSeq, emojiToken: token);
                                await updateEmojiMRU(token);
                                final updated = await loadEmojiMRU();
                                if (mounted) setState(() { _emojiMRU = updated; });
                              }
                            } catch (_) {}
                          }
                          _emojiPickerOpen = false;
                        },
                        child: CircleAvatar(
                          radius: 14,
                          backgroundColor: theme.colorScheme.surfaceVariant,
                          child: const Icon(Icons.expand_more, color: Colors.white, size: 18),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        );
      };

      final box = key.currentContext!.findRenderObject() as RenderBox;
      final offset = box.localToGlobal(Offset.zero);
      final rect = Rect.fromLTWH(offset.dx, offset.dy, box.size.width, box.size.height);

      _reactionOverlayForBubbleId = bubbleId;
      _reactionOverlay = OverlayEntry(builder: (ctx) {
        return chooser(ctx, rect);
      });
      Overlay.of(context).insert(_reactionOverlay!);
      setState(() {});
    } catch (_) {}
  }

  Future<String?> _openEmojiPickerAll() async {
    try {
      final theme = Theme.of(context);
      final allTokens = filterAllowedTokens(kSupportedEmojiTokens);
      final mru16 = await loadEmojiMRUExtended();
      final res = await showModalBottomSheet<String>(
        context: context,
        useRootNavigator: true,
        backgroundColor: theme.colorScheme.surface,
        shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(16))),
        builder: (ctx) {
          String selected = 'All';
          String query = '';
          final cats = emojiCategories();
          List<String> filtered(List<String> base) {
            var src = filterAllowedTokens(base);
            if (query.trim().isNotEmpty) {
              final q = query.trim().toLowerCase();
              src = src.where((t) {
                final label = t.replaceAll(':', '').replaceAll('_', ' ').toLowerCase();
                return label.contains(q);
              }).toList();
            }
            return src;
          }
          return SafeArea(
            child: StatefulBuilder(builder: (ctx2, setModalState) {
              final base = cats[selected] ?? allTokens;
              final tokens = filtered(base);
              return Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  // Grab handle (top center)
                  Padding(
                    padding: const EdgeInsets.only(top: 8, bottom: 4),
                    child: Center(
                      child: Container(
                        width: 36,
                        height: 4,
                        decoration: BoxDecoration(
                          color: theme.colorScheme.onSurface.withOpacity(0.3),
                          borderRadius: BorderRadius.circular(3),
                        ),
                      ),
                    ),
                  ),
                  // MRU row (up to 16)
                  if (mru16.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.fromLTRB(12, 0, 12, 4),
                      child: Align(
                        alignment: Alignment.centerLeft,
                        child: Text(
                          'Recently used',
                          style: (theme.textTheme.labelLarge ?? const TextStyle()).copyWith(fontFamily: theme.textTheme.displaySmall?.fontFamily),
                        ),
                      ),
                    ),
                  if (mru16.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.fromLTRB(12, 12, 12, 8),
                      child: SizedBox(
                        height: 40,
                        child: ListView.separated(
                          scrollDirection: Axis.horizontal,
                          itemCount: mru16.length.clamp(0, 16),
                          separatorBuilder: (_, __) => const SizedBox(width: 8),
                          itemBuilder: (ctx3, i) {
                            final t = mru16[i];
                            return InkWell(
                              borderRadius: BorderRadius.circular(10),
                              onTap: () => Navigator.of(ctx).pop(t),
                              child: SizedBox(
                                width: 32,
                                height: 32,
                                child: FittedBox(
                                  fit: BoxFit.contain,
                                  child: Text(
                                    emojiCharForToken(t),
                                    style: const TextStyle(
                                      fontSize: 32,
                                      height: 1.0,
                                      fontFamilyFallback: [
                                        'Noto Color Emoji',
                                        'Apple Color Emoji',
                                        'Segoe UI Emoji',
                                        'EmojiOne Color',
                                        'Twemoji Mozilla',
                                      ],
                                      shadows: [
                                        Shadow(color: Color(0x8C000000), blurRadius: 3, offset: Offset(0, 0)),
                                      ],
                                    ),
                                  ),
                                ),
                              ),
                            );
                          },
                        ),
                      ),
                    ),
                  // Categories row
                  SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    padding: const EdgeInsets.symmetric(horizontal: 12),
                    child: Row(
                      children: [
                        for (final name in cats.keys)
                          Padding(
                            padding: const EdgeInsets.only(right: 8),
                            child: Theme(
                              data: Theme.of(context).copyWith(
                                colorScheme: Theme.of(context).colorScheme.copyWith(
                                  primary: Theme.of(context).colorScheme.surfaceVariant,
                                  onPrimary: Theme.of(context).colorScheme.onSurface,
                                ),
                              ),
                              child: Builder(builder: (chipCtx) {
                                final bool isSel = selected == name;
                                final String? titleFont = Theme.of(context).textTheme.displaySmall?.fontFamily;
                                final Color onSurf = Theme.of(context).colorScheme.onSurface;
                                return ChoiceChip(
                                  label: Text(
                                    name,
                                    style: TextStyle(
                                      fontFamily: titleFont,
                                      color: isSel ? Colors.white : onSurf.withOpacity(0.95),
                                    ),
                                  ),
                                  selected: isSel,
                                  selectedColor: Theme.of(context).colorScheme.surfaceVariant.withOpacity(0.7),
                                  backgroundColor: Theme.of(context).colorScheme.surfaceVariant.withOpacity(0.35),
                                  showCheckmark: false,
                                  onSelected: (_) => setModalState(() { selected = name; }),
                                );
                              }),
                            ),
                          ),
                      ],
                    ),
                  ),
                  // Search field
                  Padding(
                    padding: const EdgeInsets.fromLTRB(12, 8, 12, 6),
                    child: Builder(builder: (context) {
                      final onSurf = Theme.of(context).colorScheme.onSurface;
                      final searchFill = const Color(0xFF2E2C2C);
                      return TextField(
                      onChanged: (v) => setModalState(() { query = v; }),
                      cursorColor: onSurf,
                      decoration: InputDecoration(
                        hintText: 'Search emoji',
                        prefixIcon: Icon(Icons.search, color: onSurf.withOpacity(0.85)),
                        filled: true,
                        fillColor: searchFill,
                        contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
                        border: OutlineInputBorder(borderRadius: BorderRadius.circular(14), borderSide: BorderSide.none),
                        enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(14), borderSide: BorderSide.none),
                        focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(14), borderSide: BorderSide.none),
                      ),
                    );}),
                  ),
                  Expanded(
                    child: ListView(
                      padding: const EdgeInsets.fromLTRB(12, 4, 12, 12),
                      children: [
                        if (selected == 'All')
                          ...[
                            for (final name in <String>['Smileys','Gestures','Nature','Animals','Food','Activity','Travel','Objects','Symbols','Fun'])
                              ...(() {
                                final list = filtered(cats[name] ?? const <String>[]);
                                if (list.isEmpty) return <Widget>[];
                                return <Widget>[
                                  Padding(
                                    padding: const EdgeInsets.only(top: 8, bottom: 6),
                                    child: Align(
                                      alignment: Alignment.centerLeft,
                                      child: Text(name, style: (theme.textTheme.titleSmall ?? const TextStyle()).copyWith(fontFamily: theme.textTheme.displaySmall?.fontFamily)),
                                    ),
                                  ),
                                  GridView.count(
                                    crossAxisCount: 6,
                                    shrinkWrap: true,
                                    physics: const NeverScrollableScrollPhysics(),
                                    children: [
                                      for (final t in list)
                                        InkWell(
                                          borderRadius: BorderRadius.circular(10),
                                          onTap: () => Navigator.of(ctx).pop(t),
                                          child: Center(
                                            child: SizedBox(
                                              width: 32,
                                              height: 32,
                                              child: FittedBox(
                                                fit: BoxFit.contain,
                                                child: Text(
                                                  emojiCharForToken(t),
                                                  style: const TextStyle(
                                                    fontSize: 32,
                                                    height: 1.0,
                                                    fontFamilyFallback: [
                                                      'Noto Color Emoji',
                                                      'Apple Color Emoji',
                                                      'Segoe UI Emoji',
                                                      'EmojiOne Color',
                                                      'Twemoji Mozilla',
                                                    ],
                                                    shadows: [
                                                      Shadow(color: Color(0x8C000000), blurRadius: 3, offset: Offset(0, 0)),
                                                    ],
                                                  ),
                                                ),
                                              ),
                                            ),
                                          ),
                                        ),
                                    ],
                                  ),
                                ];
                              }()),
                          ]
                        else ...[
                          Padding(
                            padding: const EdgeInsets.only(top: 8, bottom: 6),
                            child: Align(
                              alignment: Alignment.centerLeft,
                              child: Text(selected, style: (theme.textTheme.titleSmall ?? const TextStyle()).copyWith(fontFamily: theme.textTheme.displaySmall?.fontFamily)),
                            ),
                          ),
                          GridView.count(
                            crossAxisCount: 6,
                            shrinkWrap: true,
                            physics: const NeverScrollableScrollPhysics(),
                            children: [
                              for (final t in tokens)
                                InkWell(
                                  borderRadius: BorderRadius.circular(10),
                                  onTap: () => Navigator.of(ctx).pop(t),
                                  child: Center(
                                    child: SizedBox(
                                      width: 32,
                                      height: 32,
                                      child: FittedBox(
                                        fit: BoxFit.contain,
                                        child: Text(
                                          emojiCharForToken(t),
                                          style: const TextStyle(
                                            fontSize: 32,
                                            height: 1.0,
                                            fontFamilyFallback: [
                                              'Noto Color Emoji',
                                              'Apple Color Emoji',
                                              'Segoe UI Emoji',
                                              'EmojiOne Color',
                                              'Twemoji Mozilla',
                                            ],
                                            shadows: [
                                              Shadow(color: Color(0x8C000000), blurRadius: 3, offset: Offset(0, 0)),
                                            ],
                                          ),
                                        ),
                                      ),
                                    ),
                                  ),
                                ),
                            ],
                          ),
                        ],
                      ],
                    ),
                  ),
                ],
              );
            }),
          );
        },
      );
      return res;
    } catch (_) {
      return null;
    }
  }

  Future<void> _sendReaction({required String cid, required int targetSeq, required String emojiToken}) async {
    try {
      // Resolve reply UA for this conversation
      String dest = '';
      try { dest = WarpApi.getProperty(aa.coin, 'cid_map_' + cid).trim(); } catch (_) {}
      if (dest.isEmpty) {
        dest = (thread.address ?? '').trim();
      }
      if (dest.isEmpty) {
        showSnackBar('No reply address');
        return;
      }
      try {
        final rcv = WarpApi.receiversOfAddress(aa.coin, dest);
        if ((rcv & 4) == 0) {
          showSnackBar('Reply address is not Orchard-capable');
          return;
        }
      } catch (_) {
        showSnackBar('Invalid reply address');
        return;
      }

      int mySeq = 1;
      try {
        final mem = _inFlightNextSeq[cid];
        if (mem != null && mem > 0) {
          mySeq = mem;
        } else {
          final s = WarpApi.getProperty(aa.coin, 'cid_my_seq_' + cid).trim();
          final v = int.tryParse(s);
          mySeq = (v != null && v > 0) ? (v + 1) : 1;
        }
      } catch (_) { mySeq = 1; }

      // Include target_author to disambiguate when both sides have seq=1 (invite/accept)
      final String targetAuthor = 'me';
      String header = 'v1; type=reaction; conversation_id=' + cid + '; seq=' + mySeq.toString() + '; target_seq=' + targetSeq.toString() + '; target_author=' + targetAuthor + '; emoji=' + emojiToken;
      final memo = header + '\n\n';

      // Optimistic hidden pending entry (will not render as a message, but will aggregate in overlay)
      try {
        final pending = ZMessage(
          -1, 0, false, '', dest, dest, 'Sending…', memo, DateTime.now(), aa.height, true,
        );
        aa.messages.items = List<ZMessage>.from(aa.messages.items)..add(pending);
        // Persist across navigation like messages by also adding to global optimistic echoes
        try { optimisticEchoes.add(pending); } catch (_) {}
        setState(() {});
    } catch (_) {}

      // Reserve sequence immediately for reactions as well
      try { _inFlightNextSeq[cid] = mySeq + 1; } catch (_) {}
      try { WarpApi.setProperty(aa.coin, 'cid_my_seq_' + cid, mySeq.toString()); } catch (_) {}

      final int recipientPools = 4;
      final builder = RecipientObjectBuilder(
        address: dest,
        pools: recipientPools,
        amount: 0, // zero-value memo-only; pay fee only
        feeIncluded: false,
        replyTo: false,
        subject: '',
        memo: memo,
      );
      final recipient = Recipient(builder.toBytes());
      () async {
        try {
          // removed warn modal call
          final plan = await WarpApi.prepareTx(
            aa.coin,
            aa.id,
            [recipient],
            7,
            coinSettings.replyUa,
            appSettings.anchorOffset,
            coinSettings.feeT,
          );
          final signedTx = await WarpApi.signOnly(aa.coin, aa.id, plan);
          final _ = WarpApi.broadcast(aa.coin, signedTx);
          try { WarpApi.setProperty(aa.coin, 'cid_my_seq_' + cid, mySeq.toString()); } catch (_) {}
          try { triggerManualSync(); } catch (_) {}
          // Optionally mark the optimistic entry as Sent until DB replacement arrives
          try {
            final updated = aa.messages.items.toList();
            // Find by identical reference first
            final idx = updated.lastIndexWhere((m) => (m.subject == 'Sending…' && _headerKeyOfMessage(m) == _headerKeyOfMessage(updated.last)) ? identical(m, updated.last) : identical(m, m));
          } catch (_) {}
          try {
            // Update matching optimistic echo by header key
            final key = _headerKey(memo);
            for (int i = optimisticEchoes.length - 1; i >= 0; i--) {
              if (_headerKeyOfMessage(optimisticEchoes[i]) == key) {
                final p = optimisticEchoes[i];
                optimisticEchoes[i] = ZMessage(
                  p.id, p.txId, p.incoming, p.fromAddress, p.sender, p.recipient, 'Sent', p.body, p.timestamp, p.height, p.read,
                );
                break;
              }
            }
            setState(() {});
          } catch (_) {}
        } catch (e) {
          showSnackBar('Failed to send reaction');
          // Roll back optimistic reaction so it doesn't remain stuck
          try {
            final key = _headerKey(memo);
            if (key != null) {
              try {
                aa.messages.items = aa.messages.items.where((m) => _headerKeyOfMessage(m) != key).toList();
              } catch (_) {}
              try {
                for (int i = optimisticEchoes.length - 1; i >= 0; i--) {
                  if (_headerKeyOfMessage(optimisticEchoes[i]) == key) {
                    optimisticEchoes.removeAt(i);
                  }
                }
              } catch (_) {}
              try { setState(() {}); } catch (_) {}
            }
          } catch (_) {}
        }
      }();
    } catch (e) {
      showSnackBar('Failed to send reaction');
    }
  }

  String _previewFromBody(String body) {
    try {
      final parts = body.split('\n');
      if (parts.isEmpty) return '';
      if (parts.first.trim().startsWith('v1;')) {
        int start = 1;
        if (parts.length > 1 && parts[1].trim().isEmpty) start = 2;
        final rest = parts.sublist(start).join('\n').trim();
        final firstLine = rest.split('\n').first;
        return firstLine.isEmpty ? '(no text)' : firstLine;
      }
      return parts.first;
    } catch (_) {
      return '';
    }
  }

  void _openTxDetailsForMessage(BuildContext context, ZMessage m) {
    try {
      final txId = m.txId;
      if (txId == 0) {
        // Try to resolve by heuristics when tx id is not set
      } else {
        int index = aa.txs.indexOfTxId(txId);
        if (index < 0) {
          try { aa.txs.read(aa.height); } catch (_) {}
          index = aa.txs.indexOfTxId(txId);
        }
        if (index >= 0) { gotoTx(context, index); return; }
      }
      // Heuristic fallbacks: match by memo header/body, then by time/address
      final msgsFirstLine = () {
        try { return (m.body.split('\n').first).trim(); } catch (_) { return ''; }
      }();
      final bodyTrim = (m.body).trim();
      int bestIndex = -1;
      Duration bestDelta = const Duration(days: 3650);
      for (int i = 0; i < aa.txs.items.length; i++) {
        final tx = aa.txs.items[i];
        bool memoMatch = false;
        try {
          final memo = (tx.memo ?? '').trim();
          if (memo.isNotEmpty) {
            if (memo == bodyTrim || memo.contains(msgsFirstLine)) memoMatch = true;
          }
        } catch (_) {}
        if (!memoMatch) {
          try {
            for (final txm in tx.memos) {
              final memo2 = ((txm as dynamic).memo as String?)?.trim() ?? '';
              if (memo2.isNotEmpty && (memo2 == bodyTrim || memo2.contains(msgsFirstLine))) {
                memoMatch = true; break;
              }
            }
          } catch (_) {}
        }
        bool addressHeuristic = false;
        try {
          final addr = m.incoming ? (m.fromAddress ?? '') : (m.recipient ?? '');
          final txAddr = (tx.address ?? '').trim();
          if (addr.isNotEmpty && txAddr.isNotEmpty && addr == txAddr) addressHeuristic = true;
        } catch (_) {}
        if (memoMatch || addressHeuristic) {
          // Prefer nearest timestamp
          try {
            final delta = (tx.timestamp.difference(m.timestamp)).abs();
            if (delta < bestDelta) { bestDelta = delta; bestIndex = i; }
          } catch (_) {
            if (bestIndex < 0) bestIndex = i;
          }
        }
      }
      if (bestIndex >= 0) { gotoTx(context, bestIndex); return; }
      // Final fallback: pick the closest-in-time tx with matching direction (incoming/outgoing)
      int timeIndex = -1; Duration timeDelta = const Duration(days: 3650);
      for (int i = 0; i < aa.txs.items.length; i++) {
        final tx = aa.txs.items[i];
        try {
          final directionMatches = ((tx.value >= 0) == (m.incoming));
          if (!directionMatches) continue;
          final d = (tx.timestamp.difference(m.timestamp)).abs();
          if (d < timeDelta) { timeDelta = d; timeIndex = i; }
        } catch (_) {}
      }
      if (timeIndex >= 0 && timeDelta < const Duration(hours: 6)) { gotoTx(context, timeIndex); return; }
      showSnackBar('Transaction not found');
    } catch (_) {
      showSnackBar('Transaction not available');
    }
  }

  Widget _buildBottomInputForThread(ThemeData theme, bool replyable, bool isAccepted) {
    final Color onSurf = theme.colorScheme.onSurface;
    const Color bubbleFill = Color(0xFF2E2C2C);
    final kb = MediaQuery.of(context).viewInsets.bottom;
    // Consider invite presence: if there's a pending invite, show Accept button (compose-style) instead of a text field
    final invite = _pendingInviteForThread();
    final baseCanSend = _messageController.text.trim().isNotEmpty;
    final acceptedOrReplied = isAccepted || (invite != null && invite.hasOutgoingAccept);
    final showSendCircle = baseCanSend && replyable && acceptedOrReplied;
    return AnimatedPadding(
      duration: const Duration(milliseconds: 450),
      curve: Curves.easeInOutCubic,
      padding: EdgeInsets.only(bottom: kb),
      child: Container(
        color: Theme.of(context).scaffoldBackgroundColor,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
          child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (_replyTarget != null)
              InkWell(
                onTap: () {
                  _scrollToCidSeq(_replyTarget!.cid, (_replyTarget!.targetSeq ?? '').toString());
                },
                child: Container(
                  margin: const EdgeInsets.only(bottom: 6),
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                  decoration: BoxDecoration(
                    color: Colors.black.withOpacity(0.14),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Row(
                    children: [
                      Expanded(
                        child: Text(
                          'Replying to #${_replyTarget!.targetSeq}: ${_replyTarget!.preview}',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(color: onSurf),
                        ),
                      ),
                      IconButton(
                        tooltip: 'Clear',
                        icon: const Icon(Icons.close, size: 18),
                        color: onSurf,
                        onPressed: () => setState(() { _replyTarget = null; }),
                      ),
                    ],
                  ),
                ),
              ),
            Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            // Grey plus circle (anchor for mini-menu): always reserve space to avoid input shift
            SizedBox(
              width: 36,
              height: 36,
              child: acceptedOrReplied
                  ? CompositedTransformTarget(
                      link: _plusLink,
                      child: Container(
                        decoration: BoxDecoration(shape: BoxShape.circle, color: const Color(0xFF565656)),
                        child: Material(
                          color: Colors.transparent,
                          shape: const CircleBorder(),
                          child: InkWell(
                            customBorder: const CircleBorder(),
                            onTap: _togglePlusMenu,
                            child: Center(
                              child: AnimatedRotation(
                                turns: _plusMenuOpen ? 0.125 : 0.0, // 45 degrees when open
                                duration: const Duration(milliseconds: 200),
                                curve: Curves.easeOutCubic,
                                child: const Icon(Icons.add, color: Colors.white, size: 20),
                              ),
                            ),
                          ),
                        ),
                      ),
                    )
                  : const SizedBox.shrink(),
            ),
            const Gap(8),
            Expanded(
              child: invite != null && !invite.hasOutgoingAccept
                  ? _AcceptButton(
                      enabled: (invite.replyUA != null && invite.replyUA!.isNotEmpty),
                      onTap: (invite.replyUA != null && invite.replyUA!.isNotEmpty)
                          ? () => _sendAcceptForThread(invite)
                          : null,
                    )
                  : TextField(
                controller: _messageController,
                focusNode: _messageFocus,
                enabled: replyable && acceptedOrReplied,
                minLines: 1,
                maxLines: 5,
                keyboardType: TextInputType.multiline,
                textInputAction: TextInputAction.newline,
                cursorColor: onSurf,
                decoration: InputDecoration(
                  hintText: !replyable
                      ? 'No reply address'
                      : (acceptedOrReplied ? 'Type a message' : 'Chat request pending'),
                  filled: true,
                  fillColor: bubbleFill,
                  contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(16), borderSide: BorderSide.none),
                  enabledBorder:
                      OutlineInputBorder(borderRadius: BorderRadius.circular(16), borderSide: BorderSide.none),
                  focusedBorder:
                      OutlineInputBorder(borderRadius: BorderRadius.circular(16), borderSide: BorderSide.none),
                ),
                style: (theme.textTheme.bodyMedium ?? const TextStyle()).copyWith(
                    color: onSurf.withOpacity(replyable && isAccepted ? 1.0 : 0.6)),
                onChanged: (_) => setState(() {}),
              ),
            ),
            const Gap(8),
            // Send circle
            AnimatedSwitcher(
              duration: const Duration(milliseconds: 450),
              switchInCurve: Curves.easeInOutCubic,
              switchOutCurve: Curves.easeInOutCubic,
              transitionBuilder: (child, anim) => FadeTransition(opacity: anim, child: child),
              child: showSendCircle
                  ? Container(
                      key: const ValueKey('send-visible'),
                      width: 40,
                      height: 40,
                      decoration: const BoxDecoration(
                        shape: BoxShape.circle,
                        color: Color(0xFFF4B728),
                      ),
                      child: Material(
                        color: Colors.transparent,
                        shape: const CircleBorder(),
                        child: InkWell(
                          customBorder: const CircleBorder(),
                          onTap: _onSend,
                          child: const Center(child: Icon(Icons.arrow_upward, color: Colors.black, size: 20)),
                        ),
                      ),
                    )
                  : const SizedBox(key: ValueKey('send-hidden'), width: 40, height: 40),
            ),
          ],
        ),
          ],
        ),
      ),
      ),
    );
  }

  void _onSend() {
    final text = _messageController.text.trim();
    if (text.isEmpty) return;
    _messageController.clear();
    _messageFocus.requestFocus();

    try {
      // Preserve scroll position if user is not near bottom
      final bool wasNearBottom = _nearBottomReversed();
      double preserveDelta = 0.0;
      try {
        if (_threadController.hasClients) {
          final pos = _threadController.position;
          preserveDelta = (pos.pixels - pos.minScrollExtent);
        }
      } catch (_) {}
      String? cid;
      for (final m in thread.messages.reversed) {
        final h = _parseHeaderFromBody(m.body);
        final c = (h['conversation_id'] ?? '').trim();
        if (c.isNotEmpty) { cid = c; break; }
      }
      if (cid == null || cid.isEmpty) {
        showSnackBar('No conversation id found for this thread');
        return;
      }

      String dest = '';
      try { dest = WarpApi.getProperty(aa.coin, 'cid_map_' + cid).trim(); } catch (_) {}
      if (dest.isEmpty) {
        dest = (thread.address ?? '').trim();
      }
      if (dest.isEmpty) {
        showSnackBar('No reply address');
        return;
      }
      try {
        final rcv = WarpApi.receiversOfAddress(aa.coin, dest);
        if ((rcv & 4) == 0) {
          showSnackBar('Reply address is not Orchard-capable');
          return;
        }
      } catch (_) {
        showSnackBar('Invalid reply address');
        return;
      }

      // Compute next sequence number with immediate reservation to prevent duplicates
      int mySeq = 1;
      try {
        // Prefer in-memory counter during this session
        final mem = _inFlightNextSeq[cid];
        if (mem != null && mem > 0) {
          mySeq = mem;
        } else {
          final s = WarpApi.getProperty(aa.coin, 'cid_my_seq_' + cid).trim();
          final v = int.tryParse(s);
          mySeq = (v != null && v > 0) ? (v + 1) : 1;
        }
      } catch (_) { mySeq = 1; }

      // If replying, ensure our seq is strictly greater than the target we're replying to
      if (_replyTarget != null && _replyTarget!.cid == cid && _replyTarget!.targetSeq != null) {
        final int targetSeq = _replyTarget!.targetSeq!;
        if (mySeq <= targetSeq) {
          mySeq = targetSeq + 1;
        }
      }

      // Reserve immediately (in-memory and persistent). Gaps on failure are acceptable.
      try { _inFlightNextSeq[cid] = mySeq + 1; } catch (_) {}
      try { WarpApi.setProperty(aa.coin, 'cid_my_seq_' + cid, mySeq.toString()); } catch (_) {}

      String header = 'v1; type=message; conversation_id=' + cid + '; seq=' + mySeq.toString();
      if (_replyTarget != null && _replyTarget!.cid == cid && _replyTarget!.targetSeq != null) {
        header += '; in_reply_to_seq=' + _replyTarget!.targetSeq.toString();
      }
      final memo = header + '\n\n' + text;

      final pending = ZMessage(
        -1,
        0,
        false,
        '',
        dest,
        dest,
        'Sending…',
        memo,
        DateTime.now(),
        aa.height,
        true,
      );
      try {
        aa.messages.items = List<ZMessage>.from(aa.messages.items)..add(pending);
        _pendingJustAdded = true;
        try {
          final local = List<ZMessage>.from(thread.messages)..add(pending);
          thread = MessageThread(
            key: thread.key,
            title: thread.title,
            address: thread.address,
            messages: local,
            unreadCount: thread.unreadCount,
            lastTimestamp: DateTime.now(),
          );
        } catch (_) {}
        try { optimisticEchoes.add(pending); } catch (_) {}
        setState(() {});
        WidgetsBinding.instance.addPostFrameCallback((_) async {
          if (!_threadController.hasClients) return;
          if (wasNearBottom) {
            _threadController.animateTo(
              _threadController.position.minScrollExtent,
              duration: const Duration(milliseconds: 450),
              curve: Curves.easeInOutCubic,
            );
          } else {
            // Restore previous visual position (stay where you were)
            try {
              final pos = _threadController.position;
              final target = (pos.minScrollExtent + preserveDelta)
                  .clamp(pos.minScrollExtent, pos.maxScrollExtent);
              _threadController.jumpTo(target as double);
            } catch (_) {}
          }
          // Reset the just-added flag shortly after the entrance animation window
          try { await Future.delayed(const Duration(milliseconds: 220)); } catch (_) {}
          if (mounted) { setState(() { _pendingJustAdded = false; }); }
        });
      } catch (_) {}

      final int recipientPools = 4;
      final builder = RecipientObjectBuilder(
        address: dest,
        pools: recipientPools,
        amount: 0, // zero-value memo-only; pay fee only
        feeIncluded: false,
        replyTo: false,
        subject: '',
        memo: memo,
      );
      final recipient = Recipient(builder.toBytes());
      () async {
        try {
          // removed warn modal call
          final plan = await WarpApi.prepareTx(
            aa.coin,
            aa.id,
            [recipient],
            7,
            coinSettings.replyUa,
            appSettings.anchorOffset,
            coinSettings.feeT,
          );
          final signedTx = await WarpApi.signOnly(aa.coin, aa.id, plan);
          final _ = WarpApi.broadcast(aa.coin, signedTx);
          try { WarpApi.setProperty(aa.coin, 'cid_my_seq_' + cid!, mySeq.toString()); } catch (_) {}
          setState(() { _replyTarget = null; });
          try { triggerManualSync(); } catch (_) {}
          try {
            final updated = aa.messages.items.toList();
            final idx = updated.lastIndexWhere((m) => identical(m, pending));
            if (idx >= 0) {
              final sent = ZMessage(
                pending.id,
                pending.txId,
                pending.incoming,
                pending.fromAddress,
                pending.sender,
                pending.recipient,
                'Sent',
                pending.body,
                pending.timestamp,
                pending.height,
                pending.read,
              );
              updated[idx] = sent;
              aa.messages.items = updated;
              try {
                final local = List<ZMessage>.from(thread.messages);
                int li = -1;
                for (int i = local.length - 1; i >= 0; i--) {
                  if (identical(local[i], pending) || _sameHeader(local[i].body, pending.body)) { li = i; break; }
                }
                if (li >= 0) {
                  local[li] = sent;
                  thread = MessageThread(
                    key: thread.key,
                    title: thread.title,
                    address: thread.address,
                    messages: local,
                    unreadCount: thread.unreadCount,
                    lastTimestamp: DateTime.now(),
                  );
                }
              } catch (_) {}
              try {
                final key = _headerKey(pending.body);
                for (int i = optimisticEchoes.length - 1; i >= 0; i--) {
                  if (_headerKey(optimisticEchoes[i].body) == key) {
                    optimisticEchoes[i] = sent; break;
                  }
                }
              } catch (_) {}
              setState(() {});
            }
          } catch (_) {}
        } catch (e) {
          showSnackBar('Failed to send message');
        }
      }();
    } catch (e) {
      showSnackBar('Failed to send message');
    }
  }

  @override
  void dispose() {
    // Clean overlays tied to this state
    try { _plusOverlay?.remove(); } catch (_) {}
    _plusOverlay = null;
    try { _plusController.dispose(); } catch (_) {}
    try { _acceptAnimCtrls?.values.forEach((c) { c.dispose(); }); } catch (_) {}
    _messageController.dispose();
    _messageFocus.dispose();
    super.dispose();
  }

  // Reply stepping helpers
  bool _nearBottomReversed() {
    try {
      if (!_threadController.hasClients) return true;
      final pos = _threadController.position;
      final double delta = (pos.pixels - pos.minScrollExtent);
      return delta <= _stepThresholdPx;
    } catch (_) {
      return true;
    }
  }

  void _startSteppingIfNeeded(String currentBubbleId) {
    try {
      if (!_isStepping) {
        _originWasBottom = _nearBottomReversed();
        _isStepping = true;
      }
      _replyNavStack.add(currentBubbleId);
      setState(() {});
    } catch (_) {}
  }

  void _resetStepping() {
    _isStepping = false;
    _originWasBottom = false;
    _replyNavStack.clear();
  }
}

class _ThreadInviteInfo {
  final String cid;
  final int inviteSeq;
  final bool hasOutgoingAccept;
  final String? replyUA;
  _ThreadInviteInfo({required this.cid, required this.inviteSeq, required this.hasOutgoingAccept, this.replyUA});
}

class _ReplyTargetState {
  final String cid;
  final int? targetSeq;
  final String preview;
  _ReplyTargetState({required this.cid, required this.targetSeq, required this.preview});
}

class _AcceptButton extends StatelessWidget {
  final bool enabled;
  final VoidCallback? onTap;
  const _AcceptButton({required this.enabled, this.onTap});

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 40,
      decoration: BoxDecoration(
        color: const Color(0xFFF4B728),
        borderRadius: BorderRadius.circular(16),
      ),
      child: Material(
        color: Colors.transparent,
        borderRadius: BorderRadius.circular(16),
        child: InkWell(
          borderRadius: BorderRadius.circular(16),
          onTap: enabled ? onTap : null,
          child: Center(
            child: Text(
              'Accept chat request',
              style: const TextStyle(
                color: Colors.black,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _ChatBubble extends StatelessWidget {
  final bool incoming;
  final Color color;
  final double radius;
  final EdgeInsets padding;
  final EdgeInsets margin;
  final Widget child;

  const _ChatBubble({super.key, required this.incoming, required this.color, required this.radius, required this.padding, required this.margin, required this.child});

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: margin,
      child: CustomPaint(
        painter: _ChatBubblePainter(incoming: incoming, color: color, radius: radius),
        child: Padding(padding: EdgeInsets.fromLTRB(padding.left + (incoming ? 10 : 10), padding.top, padding.right + (incoming ? 10 : 10), padding.bottom), child: child),
      ),
    );
  }
}

class _ChatBubblePainter extends CustomPainter {
  final bool incoming;
  final Color color;
  final double radius;
  _ChatBubblePainter({required this.incoming, required this.color, required this.radius});

  @override
  void paint(Canvas canvas, Size size) {
    final r = radius;
    final tailWidth = 8.0;
    final tailHeight = 10.0;
    final tailInsetY = (size.height - tailHeight - 2.0);
    final rect = Rect.fromLTWH(0, 0, size.width, size.height);
    final bodyRect = incoming
        ? Rect.fromLTWH(tailWidth, 0, rect.width - tailWidth, rect.height)
        : Rect.fromLTWH(0, 0, rect.width - tailWidth, rect.height);
    final bodyPath = Path();
    final tl = Radius.circular(r);
    final tr = Radius.circular(r);
    final bl = Radius.circular(incoming ? 6 : r);
    final br = Radius.circular(incoming ? r : 6);

    bodyPath.addRRect(RRect.fromRectAndCorners(
      bodyRect,
      topLeft: tl,
      topRight: tr,
      bottomLeft: bl,
      bottomRight: br,
    ));

    // Tail: small rounded triangular shape that slightly overlaps the body
    final tailPath = Path();
    if (incoming) {
      final x0 = bodyRect.left; // equals tailWidth
      tailPath.moveTo(x0 + 0.5, tailInsetY + 2);
      tailPath.quadraticBezierTo(x0 - 2, tailInsetY + 6, 0, tailInsetY + tailHeight);
      tailPath.lineTo(x0 + 1.5, tailInsetY + tailHeight - 2); // slight overlap into body
      tailPath.close();
    } else {
      final x0 = bodyRect.right;
      tailPath.moveTo(x0 - 0.5, tailInsetY + 2);
      tailPath.quadraticBezierTo(x0 + 2, tailInsetY + 6, x0 + tailWidth, tailInsetY + tailHeight);
      tailPath.lineTo(x0 - 1.5, tailInsetY + tailHeight - 2); // slight overlap into body
      tailPath.close();
    }

    // Merge body and tail into one path to avoid hairline seams
    final bubblePath = Path.combine(PathOperation.union, bodyPath, tailPath);
    final paint = Paint()
      ..isAntiAlias = true
      ..style = PaintingStyle.fill
      ..color = color;
    canvas.drawPath(bubblePath, paint);
  }

  @override
  bool shouldRepaint(covariant _ChatBubblePainter oldDelegate) {
    return oldDelegate.incoming != incoming || oldDelegate.color != color || oldDelegate.radius != radius;
  }
}

// Image painter for photo display
class _ImagePainter extends CustomPainter {
  final ui.Image image;
  
  _ImagePainter(this.image);
  
  @override
  void paint(Canvas canvas, Size size) {
    final srcRect = Rect.fromLTWH(0, 0, image.width.toDouble(), image.height.toDouble());
    final dstRect = Rect.fromLTWH(0, 0, size.width, size.height);
    canvas.drawImageRect(image, srcRect, dstRect, Paint());
  }
  
  @override
  bool shouldRepaint(_ImagePainter oldDelegate) => oldDelegate.image != image;
}

