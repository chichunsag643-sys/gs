import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart' as hash;
import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';

import '../data/note_repository.dart';
import '../data/settings_store.dart';
import 'blob_store.dart';
import 'crypto.dart';
import 'pairing.dart';
import 'sync_store.dart';
import 'transport.dart';

/// Serverless sync between this user's own devices.
///
/// Every device runs a small TCP listener while the app is open. Devices
/// reach each other directly on the same Wi-Fi, or over Tailscale from
/// other networks. Nothing is stored anywhere but on the devices.
///
/// * Changes made offline are kept (each row has a local `seq`) and sent the
///   next time a peer is reachable.
/// * A local change is pushed to every reachable peer within about a second.
/// * Records merge last-writer-wins by HLC; deletes travel as tombstones.
/// * Traffic is AES-256-GCM encrypted with a key only paired devices hold.
class SyncService extends ChangeNotifier with WidgetsBindingObserver {
  SyncService({
    required this.store,
    required this.settings,
    required this.repo,
    this.blobs,
    this.port = defaultPort,
    this.beaconPort = defaultBeaconPort,
    this.enableBeacon = true,
  });

  final SyncStore store;
  final SettingsStore settings;
  final NoteRepository repo;
  final SyncBlobStore? blobs;
  final int port;
  final int beaconPort;
  final bool enableBeacon;

  static const defaultPort = 47800;
  static const defaultBeaconPort = 47801;
  static const _groupKeyMeta = 'sync_group_key';
  static const _protocol = 1;

  SyncCipher? _group;
  ServerSocket? _server;
  RawDatagramSocket? _beacon;
  Timer? _periodic;
  Timer? _debounce;
  Timer? _beaconTimer;
  bool _started = false;
  bool _foreground = true;
  int _boundPort = 0;
  List<String> _addresses = const [];
  List<Peer> _peers = const [];
  final Set<String> _syncing = {};
  final Map<String, DateTime> _lastAttempt = {};
  Future<void> _mergeLock = Future.value();
  PairingSession? _pairing;
  final _remoteChanges = StreamController<Set<String>>.broadcast();

  /// Whether this device belongs to a sync group.
  bool get paired => _group != null;
  bool get running => _server != null;
  List<Peer> get peers => _peers;
  List<String> get addresses => _addresses;
  int get boundPort => _boundPort;
  bool isSyncing(String peerId) => _syncing.contains(peerId);
  PairingSession? get pairing => _pairing;

  /// Table names changed by a merge from another device (e.g. so the voice
  /// memo list can reload `attachments`).
  Stream<Set<String>> get remoteChanges => _remoteChanges.stream;

  // ---- Lifecycle -----------------------------------------------------------

  Future<void> start() async {
    if (_started) return;
    _started = true;
    final key = await store.meta(_groupKeyMeta);
    if (key != null) _group = SyncCipher(decodeKey(key));
    await store.resetCursorsIfSchemaChanged();
    repo.addListener(_onLocalChange);
    settings.addListener(_onSettingsChanged);
    WidgetsBinding.instance.addObserver(this);
    _lastName = settings.deviceName;
    _lastAudio = settings.audioSync;
    _lastEnabled = settings.syncEnabled;
    await _refreshPeers();
    await _applyState();
  }

  @override
  Future<void> dispose() async {
    WidgetsBinding.instance.removeObserver(this);
    repo.removeListener(_onLocalChange);
    settings.removeListener(_onSettingsChanged);
    await _stopNetwork();
    await _remoteChanges.close();
    super.dispose();
  }

  bool get _active => paired && settings.syncEnabled;

  /// Starts or stops networking to match the settings.
  Future<void> _applyState() async {
    final wantServer = _active || _pairing != null;
    if (wantServer && _server == null) {
      await _startServer();
    } else if (!wantServer && _server != null) {
      await _stopNetwork();
    }
    if (_active) {
      await _publishSelf();
      if (enableBeacon) await _startBeacon();
      _schedulePeriodic();
      unawaited(syncAll());
    } else {
      _periodic?.cancel();
      _beaconTimer?.cancel();
      _beacon?.close();
      _beacon = null;
    }
    notifyListeners();
  }

  Future<void> _startServer() async {
    try {
      _server = await ServerSocket.bind(InternetAddress.anyIPv4, port,
          shared: false);
    } on SocketException {
      // Port taken (another app); any free port still works because peers
      // learn our port from the device list and from beacons.
      _server = await ServerSocket.bind(InternetAddress.anyIPv4, 0);
    }
    _boundPort = _server!.port;
    _server!.listen(_handleConnection, onError: (_) {});
  }

  Future<void> _stopNetwork() async {
    _periodic?.cancel();
    _debounce?.cancel();
    _beaconTimer?.cancel();
    _beacon?.close();
    _beacon = null;
    await _server?.close();
    _server = null;
  }

  void _schedulePeriodic() {
    _periodic?.cancel();
    if (!_foreground) return;
    // Catch changes from peers that could not reach us (e.g. we were off
    // Wi-Fi) and keep addresses fresh.
    _periodic = Timer.periodic(const Duration(seconds: 30), (_) async {
      await _publishSelf();
      await syncAll();
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final fg = state == AppLifecycleState.resumed;
    if (fg == _foreground) return;
    _foreground = fg;
    if (!_active) return;
    if (fg) {
      _schedulePeriodic();
      unawaited(_publishSelf().then((_) => syncAll()));
    } else {
      _periodic?.cancel();
      // Push anything typed just before leaving the app.
      unawaited(syncAll(onlyIfPending: true));
    }
  }

  void _onLocalChange() {
    if (!_active) return;
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 700),
        () => syncAll(onlyIfPending: true));
  }

  String _lastName = '';
  String _lastAudio = '';
  bool? _lastEnabled;

  void _onSettingsChanged() {
    final changed = settings.deviceName != _lastName ||
        settings.audioSync != _lastAudio ||
        settings.syncEnabled != _lastEnabled;
    if (!changed) return;
    final enabledChanged = _lastEnabled != null &&
        settings.syncEnabled != _lastEnabled;
    _lastName = settings.deviceName;
    _lastAudio = settings.audioSync;
    _lastEnabled = settings.syncEnabled;
    if (enabledChanged) {
      unawaited(_applyState());
    } else if (_active) {
      unawaited(_publishSelf().then((_) => syncAll()));
    }
  }

  String get _platform => Platform.operatingSystem;

  /// Keeps our own row in the device list current.
  Future<void> _publishSelf() async {
    _addresses = await localAddresses();
    final changed = await store.upsertSelf(
      name: settings.deviceName,
      addresses: _addresses,
      port: _boundPort == 0 ? port : _boundPort,
      platform: _platform,
      stamp: repo.newStamp,
    );
    if (changed) notifyListeners();
  }

  Future<void> _refreshPeers() async {
    _peers = await store.peers();
    notifyListeners();
  }

  // ---- Settings ------------------------------------------------------------

  Future<void> setManualAddress(String peerId, String? address) async {
    final a = address?.trim();
    await store.updatePeerState(peerId,
        manualAddress: a == null || a.isEmpty ? null : a);
    await _refreshPeers();
    final peer = _peers.where((p) => p.id == peerId).firstOrNull;
    if (peer != null) unawaited(syncWith(peer));
  }

  /// Removes a device from the group: every device stops syncing with it.
  Future<void> removePeer(String peerId) async {
    final peer = _peers.where((p) => p.id == peerId).firstOrNull;
    await store.removeDevice(peerId, await repo.newStamp());
    await _refreshPeers();
    // If it is reachable now, it learns right away and leaves the group;
    // otherwise it is told the next time it tries to sync.
    if (peer != null) unawaited(syncWith(peer));
    unawaited(syncAll());
  }

  /// Leaves the sync group on this device only. Notes stay on the device.
  Future<void> leaveGroup() async {
    _group = null;
    await store.setMeta(_groupKeyMeta, null);
    await store.forgetPeers();
    await _refreshPeers();
    await _applyState();
  }

  // ---- Pairing -------------------------------------------------------------

  /// Shows this device as joinable. The returned invite goes into a QR code;
  /// it holds a one-time key that stops working when [stopPairing] is
  /// called or after 10 minutes.
  Future<PairingInvite> startPairing() async {
    if (_group == null) {
      final key = randomKey();
      await store.setMeta(_groupKeyMeta, encodeKey(key));
      _group = SyncCipher(key);
      if (!settings.syncEnabled) await settings.setSyncEnabled(true);
    }
    _pairing?.close();
    _pairing = PairingSession(randomKey(), const Duration(minutes: 10));
    await _applyState();
    await _publishSelf();
    final invite = PairingInvite(
      deviceId: store.deviceId,
      name: settings.deviceName,
      addresses: _addresses,
      port: _boundPort,
      token: _pairing!.token,
    );
    notifyListeners();
    return invite;
  }

  void stopPairing() {
    _pairing?.close();
    _pairing = null;
    unawaited(_applyState());
  }

  /// Joins the group of the device that showed [invite]. Returns that
  /// device's name. Throws [PairingException] with a message for the user.
  Future<String> join(PairingInvite invite) async {
    if (invite.deviceId == store.deviceId) {
      throw const PairingException('이 기기 자신의 QR코드입니다.');
    }
    // Our own row must exist so the other device can learn about us.
    _addresses = await localAddresses();
    await store.upsertSelf(
      name: settings.deviceName,
      addresses: _addresses,
      port: _boundPort == 0 ? port : _boundPort,
      platform: _platform,
      stamp: repo.newStamp,
    );
    final selfRow = (await store.deviceRow(store.deviceId))!;
    final cipher = SyncCipher(invite.token);
    final request = await cipher.sealJson({
      'type': 'join',
      'v': _protocol,
      'from': store.deviceId,
      'device': selfRow,
    });

    Object? lastError;
    for (final host in invite.addresses) {
      final Frame reply;
      try {
        reply = await exchange(host, invite.port, Frame(FrameKey.pairing, request),
            replyTimeout: const Duration(seconds: 10));
      } catch (e) {
        lastError = e;
        continue;
      }
      final Map<String, Object?> body;
      try {
        body = await cipher.openJson(reply.payload);
      } catch (_) {
        throw const PairingException('QR코드가 만료되었습니다. 다른 기기에서 QR코드를 다시 띄워 주세요.');
      }
      if (body['ok'] != true) {
        throw const PairingException('QR코드가 만료되었습니다. 다른 기기에서 QR코드를 다시 띄워 주세요.');
      }
      // Switching groups: the old peers can no longer talk to us.
      if (_group != null) await store.forgetPeers();
      await store.setMeta(_groupKeyMeta, body['groupKey'] as String);
      _group = SyncCipher(decodeKey(body['groupKey'] as String));
      if (!settings.syncEnabled) await settings.setSyncEnabled(true);
      await _merge([
        for (final r in body['devices'] as List) (r as Map).cast<String, Object?>(),
      ], fromPeer: invite.deviceId, address: host);
      await store.updatePeerState(invite.deviceId, lastAddress: host);
      await _refreshPeers();
      await _applyState();
      return invite.name;
    }
    throw PairingException(
      '${invite.name}에 연결하지 못했습니다. 두 기기가 같은 Wi-Fi에 있는지, '
      '다른 네트워크라면 둘 다 Tailscale이 켜져 있는지 확인해 주세요.',
      lastError,
    );
  }

  // ---- Server --------------------------------------------------------------

  Future<void> _handleConnection(Socket socket) async {
    try {
      final frame =
          await readFrame(socket, timeout: const Duration(seconds: 15));
      final reply = switch (frame.key) {
        FrameKey.group => await _handleGroup(frame, socket.remoteAddress.address),
        FrameKey.pairing => await _handlePairing(frame),
      };
      if (reply != null) await writeFrame(socket, reply);
    } catch (_) {
      // Bad or foreign frame: drop the connection without a reply.
    } finally {
      socket.destroy();
    }
  }

  Future<Frame?> _handleGroup(Frame frame, String remote) async {
    final group = _group;
    if (group == null || !settings.syncEnabled) return null;
    final msg = await group.openJson(frame.payload);
    final from = msg['from'] as String;
    if (from == store.deviceId) return null;
    if (await store.isRemoved(from)) {
      // Tell a removed device, so it stops trying and leaves the group.
      return Frame(FrameKey.group, await group.sealJson({'removed': true}));
    }
    switch (msg['type']) {
      case 'sync':
        final incoming =
            ChangeBatch.fromJson((msg['changes'] as Map).cast<String, Object?>());
        await _merge(incoming.rows, fromPeer: from, address: remote);
        // The caller has everything of ours up to its cursor.
        final theirCursor = msg['cursor'] as int;
        await store.updatePeerState(from,
            recvCursor: incoming.upTo,
            sentAck: theirCursor,
            lastAddress: remote,
            succeeded: true,
            error: null);
        final outgoing = await store.changesSince(theirCursor);
        unawaited(_refreshPeers());
        return Frame(
            FrameKey.group,
            await group.sealJson({
              'changes': outgoing.toJson(),
              'ack': incoming.upTo,
            }));
      case 'blob':
        final id = msg['id'] as String;
        final file = await blobs?.blobFile(id);
        if (file == null || !await file.exists()) {
          return Frame(FrameKey.group, await group.sealJson({'found': false}));
        }
        final bytes = await file.readAsBytes();
        return Frame(
            FrameKey.group,
            await group.sealJson({
              'found': true,
              'sha256': hash.sha256.convert(bytes).toString(),
              'data': base64.encode(bytes),
            }));
    }
    return null;
  }

  Future<Frame?> _handlePairing(Frame frame) async {
    final session = _pairing;
    final group = _group;
    if (session == null || !session.valid || group == null) return null;
    final cipher = SyncCipher(session.token);
    final msg = await cipher.openJson(frame.payload);
    if (msg['type'] != 'join') return null;
    final device = (msg['device'] as Map).cast<String, Object?>();
    final from = msg['from'] as String;
    if (device['id'] != from || device['_t'] != 'devices') return null;
    // Re-stamp so the join wins even over an earlier removal of this
    // device: scanning the QR code again is how a device is re-added.
    device
      ..['deleted'] = 0
      ..['hlc'] = await repo.newStamp()
      ..['device_id'] = store.deviceId;
    await _merge([device], fromPeer: from, address: null);
    await store.updatePeerState(from, recvCursor: 0, sentAck: 0, error: null);
    final devices = await store.liveDeviceRows();
    session.joined.add(device['name'] as String? ?? '새 기기');
    await _refreshPeers();
    notifyListeners();
    return Frame(
        FrameKey.pairing,
        await cipher.sealJson({
          'ok': true,
          'groupKey': encodeKey(await _groupKeyBytes()),
          'devices': devices,
        }));
  }

  Future<List<int>> _groupKeyBytes() async =>
      decodeKey((await store.meta(_groupKeyMeta))!);

  // ---- Client --------------------------------------------------------------

  /// Syncs with every paired device that is reachable right now.
  ///
  /// With [onlyIfPending], peers that already have all our changes are
  /// skipped (used right after a local edit).
  Future<void> syncAll({bool onlyIfPending = false}) async {
    if (!_active) return;
    await _refreshPeers();
    final current = await store.currentSeq();
    await Future.wait([
      for (final p in _peers)
        if (!onlyIfPending || (await store.cursors(p.id)).$2 < current)
          syncWith(p),
    ]);
  }

  /// Exchanges changes with one peer until both sides are up to date.
  Future<bool> syncWith(Peer peer) async {
    final group = _group;
    if (group == null || !settings.syncEnabled) return false;
    if (_syncing.contains(peer.id)) return false;
    _syncing.add(peer.id);
    _lastAttempt[peer.id] = DateTime.now();
    notifyListeners();
    Object? lastError;
    try {
      for (final host in peer.candidates) {
        try {
          await _syncRounds(group, peer, host);
          await store.updatePeerState(peer.id,
              lastAddress: host, succeeded: true, error: null);
          await _fetchBlobs(group, peer, host);
          return true;
        } catch (e) {
          lastError = e;
        }
      }
      await store.updatePeerState(peer.id,
          error: peer.candidates.isEmpty ? '주소 없음' : _describe(lastError));
      return false;
    } finally {
      _syncing.remove(peer.id);
      await _refreshPeers();
    }
  }

  Future<void> _syncRounds(SyncCipher group, Peer peer, String host) async {
    for (var round = 0; round < 1000; round++) {
      final (recv, sentAck) = await store.cursors(peer.id);
      final outgoing = await store.changesSince(sentAck);
      final reply = await exchange(
          host,
          peer.port,
          Frame(
              FrameKey.group,
              await group.sealJson({
                'type': 'sync',
                'v': _protocol,
                'from': store.deviceId,
                'cursor': recv,
                'changes': outgoing.toJson(),
              })));
      final body = await group.openJson(reply.payload);
      if (body['removed'] == true) {
        unawaited(leaveGroup());
        throw const PairingException('이 기기는 동기화 그룹에서 제거되었습니다.');
      }
      final incoming =
          ChangeBatch.fromJson((body['changes'] as Map).cast<String, Object?>());
      await _merge(incoming.rows, fromPeer: peer.id, address: host);
      await store.updatePeerState(peer.id,
          recvCursor: incoming.upTo, sentAck: body['ack'] as int);
      if (!outgoing.more && !incoming.more) return;
    }
  }

  /// Downloads voice memo files this device is missing, if it keeps them.
  Future<void> _fetchBlobs(SyncCipher group, Peer peer, String host) async {
    final store_ = blobs;
    if (store_ == null || !store_.wantsBlobs) return;
    var fetched = 0;
    for (final id in await store.liveAttachmentIds()) {
      if (fetched >= 20) break;
      if (await store_.hasBlob(id)) continue;
      final reply = await exchange(
          host,
          peer.port,
          Frame(
              FrameKey.group,
              await group.sealJson(
                  {'type': 'blob', 'v': _protocol, 'from': store.deviceId, 'id': id})),
          replyTimeout: const Duration(minutes: 2));
      final body = await group.openJson(reply.payload);
      if (body['found'] != true) continue;
      await store_.importBlob(
          id, base64.decode(body['data'] as String), body['sha256'] as String);
      fetched++;
    }
    if (fetched > 0) _remoteChanges.add({SyncStore.attachmentsTable});
  }

  /// Merges rows one batch at a time, so two peers syncing with us at once
  /// cannot interleave.
  Future<void> _merge(List<Map<String, Object?>> rows,
      {required String fromPeer, required String? address}) {
    final next = _mergeLock.then((_) async {
      if (rows.isEmpty) return;
      final result = await store.merge(rows);
      if (result.isEmpty) return;
      if (result.notes.isNotEmpty || result.folders.isNotEmpty) {
        await repo.applyRemote(notes: result.notes, folders: result.folders);
      }
      if (result.tables.contains('devices')) await _refreshPeers();
      _remoteChanges.add(result.tables);
      // Pass the news on to the other devices right away.
      _onLocalChange();
      if (result.selfRemoved) {
        // Another device removed this one from the group.
        unawaited(leaveGroup());
      }
    });
    _mergeLock = next.catchError((_) {});
    return next;
  }

  static String _describe(Object? e) => switch (e) {
        SocketException() || TimeoutException() => '연결할 수 없음',
        _ => '동기화 실패',
      };

  // ---- LAN discovery -------------------------------------------------------

  /// Devices on the same Wi-Fi announce themselves by UDP broadcast, so a
  /// changed IP address is found without a new QR scan. The beacon is
  /// encrypted with the group key; other apps see only noise.
  Future<void> _startBeacon() async {
    if (_beacon != null) return;
    try {
      _beacon = await RawDatagramSocket.bind(InternetAddress.anyIPv4, beaconPort,
          reuseAddress: true);
    } on SocketException {
      return;
    }
    _beacon!
      ..broadcastEnabled = true
      ..listen((event) {
        if (event != RawSocketEvent.read) return;
        final d = _beacon?.receive();
        if (d != null) unawaited(_onBeacon(d));
      });
    _beaconTimer?.cancel();
    _beaconTimer =
        Timer.periodic(const Duration(seconds: 20), (_) => _sendBeacon());
    await _sendBeacon();
  }

  static final _beaconTag = ascii.encode('GSN1');

  Future<void> _sendBeacon() async {
    final group = _group;
    final socket = _beacon;
    if (group == null || socket == null) return;
    final sealed = await group.sealJson({'id': store.deviceId, 'port': _boundPort});
    try {
      socket.send(Uint8List.fromList([..._beaconTag, ...sealed]),
          InternetAddress('255.255.255.255'), beaconPort);
    } on SocketException {
      // No network right now.
    }
  }

  Future<void> _onBeacon(Datagram d) async {
    final group = _group;
    if (group == null || d.data.length < 5) return;
    for (var i = 0; i < 4; i++) {
      if (d.data[i] != _beaconTag[i]) return;
    }
    final Map<String, Object?> msg;
    try {
      msg = await group.openJson(d.data.sublist(4));
    } catch (_) {
      return;
    }
    final id = msg['id'];
    if (id is! String || id == store.deviceId) return;
    final peer = _peers.where((p) => p.id == id).firstOrNull;
    if (peer == null) return;
    final address = d.address.address;
    if (peer.lastAddress != address) {
      await store.updatePeerState(id, lastAddress: address);
      await _refreshPeers();
    }
    final last = _lastAttempt[id];
    final stale = peer.lastError != null || peer.lastAddress != address;
    if (stale &&
        (last == null ||
            DateTime.now().difference(last) > const Duration(seconds: 10))) {
      final updated = _peers.where((p) => p.id == id).firstOrNull;
      if (updated != null) unawaited(syncWith(updated));
    }
  }
}
