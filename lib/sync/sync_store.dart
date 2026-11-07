import 'dart:convert';

import 'package:sqflite_common/sqlite_api.dart';

import '../data/hlc.dart';
import '../data/models.dart';
import '../data/schema.dart';

/// A paired device, as kept in the synced `devices` table.
class Peer {
  const Peer({
    required this.id,
    required this.name,
    required this.addresses,
    required this.port,
    required this.platform,
    this.manualAddress,
    this.lastAddress,
    this.lastSyncAt,
    this.lastError,
  });

  final String id;
  final String name;

  /// Addresses the device reported (LAN and Tailscale), newest first.
  final List<String> addresses;
  final int port;
  final String platform;

  /// An address typed in by the user (e.g. a Tailscale MagicDNS name).
  final String? manualAddress;

  /// The address that last worked.
  final String? lastAddress;
  final DateTime? lastSyncAt;
  final String? lastError;

  /// Addresses to try, most likely first.
  List<String> get candidates => {
        ?lastAddress,
        ?manualAddress,
        ...addresses,
      }.toList();
}

/// Rows to send to a peer, and how far they reach in our `seq` order.
class ChangeBatch {
  const ChangeBatch(this.rows, this.upTo, this.more);
  final List<Map<String, Object?>> rows;
  final int upTo;
  final bool more;

  Map<String, Object?> toJson() => {'rows': rows, 'upTo': upTo, 'more': more};

  factory ChangeBatch.fromJson(Map<String, Object?> json) => ChangeBatch(
        [
          for (final r in json['rows'] as List)
            (r as Map).cast<String, Object?>(),
        ],
        json['upTo'] as int,
        json['more'] as bool,
      );
}

/// What a merge changed, so the in-memory caches can catch up.
class MergeResult {
  final notes = <Note>[];
  final folders = <Folder>[];
  final tables = <String>{};
  final attachmentIds = <String>[];
  bool selfRemoved = false;

  bool get isEmpty => tables.isEmpty;
}

/// Sync bookkeeping in the encrypted database: which rows changed since a
/// peer last heard from us, merging rows from peers, the device list.
class SyncStore {
  SyncStore(this._db, this.deviceId);

  final Database _db;
  final String deviceId;
  final Map<String, Set<String>> _columns = {};

  static const attachmentsTable = 'attachments';
  static const batchSize = 300;

  /// Synced tables present in this database. `attachments` arrives with the
  /// voice memo feature and is synced once its table exists.
  Future<List<String>> tables([DatabaseExecutor? ex]) async {
    final hasAttachments = (await (ex ?? _db).rawQuery(
            "SELECT 1 FROM sqlite_master WHERE type='table' AND name=?",
            [attachmentsTable]))
        .isNotEmpty;
    return [...syncedTables, if (hasAttachments) attachmentsTable];
  }

  Future<Set<String>> _cols(DatabaseExecutor ex, String table) async =>
      _columns[table] ??= {
        for (final r in await ex.rawQuery('PRAGMA table_info($table)'))
          r['name'] as String,
      };

  // ---- Meta ----------------------------------------------------------------

  Future<String?> meta(String key) async {
    final rows = await _db.query('meta', where: 'key = ?', whereArgs: [key]);
    return rows.isEmpty ? null : rows.first['value'] as String;
  }

  Future<void> setMeta(String key, String? value) async {
    if (value == null) {
      await _db.delete('meta', where: 'key = ?', whereArgs: [key]);
    } else {
      await _db.insert('meta', {'key': key, 'value': value},
          conflictAlgorithm: ConflictAlgorithm.replace);
    }
  }

  /// After a schema change, rows we skipped earlier (tables we did not have)
  /// may now be wanted, so start every peer over. Merging is idempotent.
  Future<void> resetCursorsIfSchemaChanged() async {
    const key = 'sync_schema';
    final tableList = (await tables()).join(',');
    if (await meta(key) == tableList) return;
    await _db.update('peer_state', {'recv_cursor': 0, 'sent_ack': 0});
    await setMeta(key, tableList);
  }

  // ---- Changes -------------------------------------------------------------

  Future<int> currentSeq() async =>
      (await _db.rawQuery('SELECT value FROM sync_counter')).first['value']
          as int;

  /// Our rows with `seq > after`, oldest first, at most [batchSize].
  Future<ChangeBatch> changesSince(int after) async {
    return _db.transaction((txn) async {
      final all = <(int, Map<String, Object?>)>[];
      for (final t in await tables(txn)) {
        final rows = await txn.query(t,
            where: 'seq > ?',
            whereArgs: [after],
            orderBy: 'seq',
            limit: batchSize + 1);
        for (final r in rows) {
          final row = Map<String, Object?>.of(r)..remove('seq');
          // Per-peer bookkeeping columns are local only.
          if (t == 'devices') {
            row
              ..remove('public_key')
              ..remove('last_seen_hlc');
          }
          all.add((r['seq'] as int, {'_t': t, ...row}));
        }
      }
      all.sort((a, b) => a.$1.compareTo(b.$1));
      final head = await txn.rawQuery('SELECT value FROM sync_counter');
      final current = head.first['value'] as int;
      if (all.length <= batchSize) {
        return ChangeBatch([for (final e in all) e.$2], current, false);
      }
      final taken = all.take(batchSize).toList();
      return ChangeBatch([for (final e in taken) e.$2], taken.last.$1, true);
    });
  }

  /// Merges rows from a peer: per record, the higher HLC wins
  /// (last writer wins). Ties and older rows are ignored, so receiving the
  /// same rows twice changes nothing.
  Future<MergeResult> merge(List<Map<String, Object?>> rows) async {
    final result = MergeResult();
    final known = (await tables()).toSet();
    await _db.transaction((txn) async {
      for (final incoming in rows) {
        final table = incoming['_t'];
        if (table is! String || !known.contains(table)) continue;
        final cols = await _cols(txn, table);
        final row = <String, Object?>{
          for (final e in incoming.entries)
            if (e.key != '_t' && e.key != 'seq' && cols.contains(e.key))
              e.key: e.value,
        };
        final id = row['id'];
        final hlc = row['hlc'];
        if (id is! String || hlc is! String) continue;
        final local = await txn.query(table,
            columns: ['hlc'], where: 'id = ?', whereArgs: [id]);
        if (local.isNotEmpty &&
            !_newer(hlc, local.first['hlc'] as String)) {
          continue;
        }
        if (local.isEmpty) {
          await txn.insert(table, row);
        } else {
          await txn.update(table, row, where: 'id = ?', whereArgs: [id]);
        }
        result.tables.add(table);
        Future<Map<String, Object?>> stored() async =>
            (await txn.query(table, where: 'id = ?', whereArgs: [id])).first;
        switch (table) {
          case 'notes':
            result.notes.add(Note.fromRow(await stored()));
          case 'folders':
            result.folders.add(Folder.fromRow(await stored()));
          case 'devices':
            if (id == deviceId && row['deleted'] == 1) {
              result.selfRemoved = true;
            }
          case attachmentsTable:
            result.attachmentIds.add(id);
        }
      }
    });
    return result;
  }

  static bool _newer(String remote, String local) {
    if (local.isEmpty) return true;
    try {
      return Hlc.parse(remote) > Hlc.parse(local);
    } on FormatException {
      return remote.compareTo(local) > 0;
    }
  }

  // ---- Devices -------------------------------------------------------------

  /// Writes this device's own row if anything about it changed, so peers
  /// learn our name and current addresses.
  Future<bool> upsertSelf({
    required String name,
    required List<String> addresses,
    required int port,
    required String platform,
    required Future<String> Function() stamp,
  }) async {
    final rows =
        await _db.query('devices', where: 'id = ?', whereArgs: [deviceId]);
    final encoded = jsonEncode(addresses);
    if (rows.isNotEmpty) {
      final r = rows.first;
      if (r['name'] == name &&
          r['addresses'] == encoded &&
          r['port'] == port &&
          r['platform'] == platform &&
          r['deleted'] == 0) {
        return false;
      }
    }
    await _db.insert(
      'devices',
      {
        'id': deviceId,
        'name': name,
        'addresses': encoded,
        'port': port,
        'platform': platform,
        'added_at': rows.isEmpty
            ? DateTime.now().millisecondsSinceEpoch
            : rows.first['added_at'],
        'hlc': await stamp(),
        'device_id': deviceId,
        'deleted': 0,
      },
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
    return true;
  }

  /// A device row in the form [changesSince] sends it.
  Future<Map<String, Object?>?> deviceRow(String id) async {
    final rows = await _db.query('devices', where: 'id = ?', whereArgs: [id]);
    if (rows.isEmpty) return null;
    return {'_t': 'devices', ...rows.first}
      ..remove('seq')
      ..remove('public_key')
      ..remove('last_seen_hlc');
  }

  Future<List<Map<String, Object?>>> liveDeviceRows() async => [
        for (final r in await _db.query('devices', where: 'deleted = 0'))
          {'_t': 'devices', ...r}
            ..remove('seq')
            ..remove('public_key')
            ..remove('last_seen_hlc'),
      ];

  Future<List<Peer>> peers() async {
    final rows = await _db.rawQuery('''
      SELECT d.*, p.last_address, p.manual_address, p.last_sync_at,
             p.last_error
      FROM devices d LEFT JOIN peer_state p ON p.device_id = d.id
      WHERE d.deleted = 0 AND d.id != ?
      ORDER BY d.added_at''', [deviceId]);
    return [
      for (final r in rows)
        Peer(
          id: r['id'] as String,
          name: r['name'] as String,
          addresses: [
            for (final a in jsonDecode(r['addresses'] as String) as List)
              a as String,
          ],
          port: r['port'] as int,
          platform: r['platform'] as String,
          manualAddress: r['manual_address'] as String?,
          lastAddress: r['last_address'] as String?,
          lastSyncAt: r['last_sync_at'] == null
              ? null
              : DateTime.fromMillisecondsSinceEpoch(r['last_sync_at'] as int),
          lastError: r['last_error'] as String?,
        ),
    ];
  }

  Future<bool> isRemoved(String id) async => (await _db.query('devices',
          columns: ['id'], where: 'id = ? AND deleted = 1', whereArgs: [id]))
      .isNotEmpty;

  /// Tombstones a device so every other device stops syncing with it.
  Future<void> removeDevice(String id, String hlc) async {
    await _db.update('devices', {'deleted': 1, 'hlc': hlc, 'device_id': deviceId},
        where: 'id = ?', whereArgs: [id]);
    await _db.delete('peer_state', where: 'device_id = ?', whereArgs: [id]);
  }

  /// Forgets all peers (local only): used when leaving the sync group.
  Future<void> forgetPeers() async {
    await _db.delete('devices', where: 'id != ?', whereArgs: [deviceId]);
    await _db.delete('peer_state');
  }

  // ---- Per-peer progress (local only) --------------------------------------

  Future<(int recvCursor, int sentAck)> cursors(String peerId) async {
    final rows = await _db
        .query('peer_state', where: 'device_id = ?', whereArgs: [peerId]);
    if (rows.isEmpty) return (0, 0);
    return (rows.first['recv_cursor'] as int, rows.first['sent_ack'] as int);
  }

  Future<void> updatePeerState(
    String peerId, {
    int? recvCursor,
    int? sentAck,
    String? lastAddress,
    Object? manualAddress = _keep,
    bool succeeded = false,
    Object? error = _keep,
  }) async {
    await _db.insert('peer_state', {'device_id': peerId},
        conflictAlgorithm: ConflictAlgorithm.ignore);
    await _db.update(
      'peer_state',
      {
        'recv_cursor': ?recvCursor,
        'sent_ack': ?sentAck,
        'last_address': ?lastAddress,
        if (!identical(manualAddress, _keep)) 'manual_address': manualAddress,
        if (succeeded) 'last_sync_at': DateTime.now().millisecondsSinceEpoch,
        if (!identical(error, _keep)) 'last_error': error,
      },
      where: 'device_id = ?',
      whereArgs: [peerId],
    );
  }

  /// Attachments whose file this device does not have yet (metadata only).
  Future<List<String>> liveAttachmentIds() async {
    if (!(await tables()).contains(attachmentsTable)) return const [];
    return [
      for (final r in await _db.query(attachmentsTable,
          columns: ['id'], where: 'deleted = 0'))
        r['id'] as String,
    ];
  }
}

const Object _keep = Object();
