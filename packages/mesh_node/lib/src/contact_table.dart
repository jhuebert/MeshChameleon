import 'dart:typed_data';

import 'package:mesh_protocol/mesh_protocol.dart';

import 'virtual_clock.dart';

/// Result of a persistent-contact upsert.
class ContactUpsert {
  const ContactUpsert({
    required this.candidate,
    this.evicted,
    this.full = false,
  });

  /// Cloned persistent table to persist; empty when [full].
  final List<Contact> candidate;

  /// Contact displaced by overwrite-on-full, if any.
  final Contact? evicted;

  /// The table is full and overwrite-on-full is disabled (or every entry is a
  /// favourite).
  final bool full;
}

/// Persistent contacts plus the non-persistent anonymous request slots.
///
/// The table owns only contact data. Persistence, push notifications, and
/// cross-service cleanup stay with the node so a failed save leaves the live
/// table untouched.
class ContactTable {
  ContactTable({required this.clock});

  final VirtualClock clock;

  final List<Contact> _persistent = [];
  final List<Contact> _transient = [];

  /// Persistent contacts in insertion order.
  List<Contact> get contacts => _persistent;

  /// Anonymous request targets. Never persisted or listed.
  List<Contact> get transient => _transient;

  Iterable<Contact> get all sync* {
    yield* _persistent;
    yield* _transient;
  }

  List<Contact> since(int timestamp) =>
      _persistent.where((c) => c.lastmod > timestamp).toList();

  Contact? findByKey(Uint8List pubkey) {
    final hex = bytesToHex(pubkey);
    for (final c in all) {
      if (c.publicKeyHex == hex) return c;
    }
    return null;
  }

  Contact? findPersistentByKey(Uint8List pubkey) {
    final hex = bytesToHex(pubkey);
    for (final c in _persistent) {
      if (c.publicKeyHex == hex) return c;
    }
    return null;
  }

  Contact? findByKeyPrefix(Uint8List prefix) {
    for (final c in all) {
      if (c.publicKey.length >= prefix.length &&
          bytesEqual(c.publicKey.sublist(0, prefix.length), prefix)) {
        return c;
      }
    }
    return null;
  }

  bool isPersistent(Contact contact) {
    final hex = contact.publicKeyHex;
    return _persistent.any((c) => c.publicKeyHex == hex);
  }

  int? transientIndex(Uint8List pubkey) {
    final hex = bytesToHex(pubkey);
    final index = _transient.indexWhere((c) => c.publicKeyHex == hex);
    return index < 0 ? null : index;
  }

  void removeTransientAt(int index) => _transient.removeAt(index);

  void removeTransient(Uint8List pubkey) {
    final hex = bytesToHex(pubkey);
    _transient.removeWhere((c) => c.publicKeyHex == hex);
  }

  void clearTransient() => _transient.clear();

  /// Return the persistent table as cloned rows for a mutation candidate.
  List<Contact> clonePersistent() => [for (final c in _persistent) c.clone()];

  /// Upsert [contact] into a cloned candidate table.
  ///
  /// Existing rows preserve their sync cursor, saved advert, and (when
  /// [hasGps] is false) their last known location.
  ContactUpsert upsert(
    Contact contact, {
    required bool hasGps,
    required NodePrefs prefs,
    required int maxContacts,
  }) {
    final candidate = clonePersistent();
    final index =
        candidate.indexWhere((c) => c.publicKeyHex == contact.publicKeyHex);
    if (index >= 0) {
      final old = candidate[index];
      final updated = contact.clone()
        ..syncSince = contact.syncSince != 0 ? contact.syncSince : old.syncSince
        ..rawAdvert = contact.rawAdvert ?? old.rawAdvert;
      if (!hasGps) {
        updated
          ..gpsLat = old.gpsLat
          ..gpsLon = old.gpsLon;
      }
      candidate[index] = updated;
      return ContactUpsert(candidate: candidate);
    }

    final added = contact.clone();
    if (candidate.length >= maxContacts) {
      final overwrite =
          _oldestOverwritableIndex(candidate, prefs.autoaddConfig);
      if (overwrite < 0) {
        return const ContactUpsert(candidate: [], full: true);
      }
      final evicted = candidate[overwrite];
      candidate[overwrite] = added;
      return ContactUpsert(candidate: candidate, evicted: evicted);
    }
    candidate.add(added);
    return ContactUpsert(candidate: candidate);
  }

  /// Index of the oldest non-favourite contact, or -1 when overwrite-on-full is
  /// disabled (`AUTO_ADD_OVERWRITE_OLDEST`) or every contact is a favourite.
  int oldestOverwritableIndex(List<Contact> table, NodePrefs prefs) =>
      _oldestOverwritableIndex(table, prefs.autoaddConfig);

  int _oldestOverwritableIndex(List<Contact> table, int autoaddConfig) {
    if ((autoaddConfig & autoAddOverwriteOldest) == 0) return -1;
    var oldestIdx = -1;
    var oldestLastmod = 0xFFFFFFFF;
    for (var i = 0; i < table.length; i++) {
      final isFavourite = (table[i].flags & 0x01) != 0;
      if (!isFavourite && table[i].lastmod < oldestLastmod) {
        oldestLastmod = table[i].lastmod;
        oldestIdx = i;
      }
    }
    return oldestIdx;
  }

  /// Return the persistent table with [pubkey] removed, or null when the key is
  /// not persistent.
  List<Contact>? removePersistent(Uint8List pubkey) {
    final hex = bytesToHex(pubkey);
    final candidate = clonePersistent();
    final before = candidate.length;
    candidate.removeWhere((c) => c.publicKeyHex == hex);
    return candidate.length == before ? null : candidate;
  }

  /// Reset the outbound path of [pubkey] in either table.
  ///
  /// Returns a persistent candidate when the contact is persistent, null when a
  /// transient contact was updated in place, or null when the key is unknown.
  List<Contact>? resetPath(Uint8List pubkey) {
    final hex = bytesToHex(pubkey);
    final candidate = clonePersistent();
    final index = candidate.indexWhere((c) => c.publicKeyHex == hex);
    if (index >= 0) {
      candidate[index]
        ..outPath = Uint8List(0)
        ..outPathLen = -1;
      return candidate;
    }
    final transient = transientIndex(pubkey);
    if (transient == null) return null;
    _transient[transient]
      ..outPath = Uint8List(0)
      ..outPathLen = -1;
    return null;
  }

  /// Register a transient zero-hop contact for [pubkey] if one doesn't exist.
  Contact ensureAnon(Uint8List pubkey) {
    final hex = bytesToHex(pubkey);
    for (final c in _transient) {
      if (c.publicKeyHex == hex) return c;
    }
    final contact = Contact(
      publicKey: Uint8List.fromList(pubkey),
      advType: advTypeNone,
      lastmod: clock.wallSeconds,
    );
    if (_transient.length < maxTransientContacts) {
      _transient.add(contact);
    } else {
      var oldestIdx = 0;
      for (var i = 1; i < _transient.length; i++) {
        if (_transient[i].lastmod < _transient[oldestIdx].lastmod) {
          oldestIdx = i;
        }
      }
      _transient[oldestIdx] = contact;
    }
    return contact;
  }

  /// Whether auto-add policy accepts an advert of [type].
  bool shouldAutoAddType(int type, NodePrefs prefs) {
    if ((prefs.manualAddContacts & 0x01) == 0) return true;
    final bit = switch (type) {
      advTypeChat => autoAddChat,
      advTypeRepeater => autoAddRepeater,
      advTypeRoom => autoAddRoom,
      advTypeSensor => autoAddSensor,
      _ => 0,
    };
    return bit != 0 && (prefs.autoaddConfig & bit) != 0;
  }

  /// Whether [pathHashCount] is within the configured auto-add hop limit.
  bool hopAllowed(int pathHashCount, NodePrefs prefs) {
    final limit = prefs.autoaddMaxHops;
    return limit == 0 || pathHashCount < limit;
  }

  void replacePersistent(Iterable<Contact> contacts) {
    _persistent
      ..clear()
      ..addAll(contacts);
  }
}
