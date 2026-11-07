import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../app_scope.dart';
import '../sync/pairing.dart';
import '../sync/sync_service.dart';
import '../sync/sync_store.dart';
import '../sync/transport.dart';

/// 설정 → 기기 동기화.
class SyncScreen extends StatelessWidget {
  const SyncScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final scope = AppScope.of(context);
    final sync = scope.sync;
    final settings = scope.settings;
    return Scaffold(
      appBar: AppBar(title: const Text('기기 동기화')),
      body: ListenableBuilder(
        listenable: Listenable.merge([sync, settings]),
        builder: (context, _) {
          final theme = Theme.of(context);
          return ListView(
            children: [
              if (!sync.paired)
                const Padding(
                  padding: EdgeInsets.fromLTRB(16, 16, 16, 8),
                  child: Text(
                    '내 기기끼리 메모를 직접 주고받습니다. 중간에 서버를 거치지 않고, '
                    '메모는 각 기기에만 저장됩니다.\n\n'
                    '처음 한 번만, 이미 쓰고 있는 기기에서 QR코드를 띄우고 새 기기로 '
                    '스캔하면 연결됩니다.',
                  ),
                )
              else
                SwitchListTile(
                  secondary: const Icon(Icons.sync),
                  title: const Text('동기화 사용'),
                  subtitle: const Text('끄면 이 기기는 다른 기기와 주고받지 않습니다. '
                      '다시 켜면 그동안 바뀐 내용을 자동으로 맞춥니다.'),
                  value: settings.syncEnabled,
                  onChanged: settings.setSyncEnabled,
                ),
              const Divider(),
              _SectionTitle('기기 추가'),
              ListTile(
                leading: const Icon(Icons.qr_code_2),
                title: const Text('이 기기에 QR코드 띄우기'),
                subtitle: const Text('새 기기에서 이 QR코드를 스캔합니다.'),
                onTap: () => Navigator.of(context).push(MaterialPageRoute(
                    builder: (_) => const ShowPairingQrScreen())),
              ),
              ListTile(
                leading: const Icon(Icons.qr_code_scanner),
                title: const Text('QR코드 스캔해서 연결'),
                subtitle: const Text('다른 기기에 띄운 QR코드를 이 기기로 찍습니다.'),
                onTap: () => _scanAndJoin(context),
              ),
              ListTile(
                leading: const Icon(Icons.content_paste),
                title: const Text('연결 코드 붙여넣기'),
                subtitle: const Text('카메라가 없을 때: QR 화면의 "코드 복사"로 받은 코드'),
                onTap: () => _pasteAndJoin(context),
              ),
              if (sync.paired) ...[
                const Divider(),
                _SectionTitle('연결된 기기'),
                if (sync.peers.isEmpty)
                  const ListTile(
                    title: Text('아직 없습니다'),
                    subtitle: Text('다른 기기에서 이 기기의 QR코드를 스캔하면 여기에 나타납니다.'),
                  ),
                for (final p in sync.peers)
                  _PeerTile(peer: p, syncing: sync.isSyncing(p.id)),
                if (sync.peers.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    child: Align(
                      alignment: Alignment.centerLeft,
                      child: OutlinedButton.icon(
                        icon: const Icon(Icons.sync, size: 18),
                        label: const Text('지금 동기화'),
                        onPressed: settings.syncEnabled ? sync.syncAll : null,
                      ),
                    ),
                  ),
              ],
              const Divider(),
              const ListTile(
                leading: Icon(Icons.mic_none),
                title: Text('음성 메모 파일'),
                subtitle: Text('다른 기기의 녹음을 글자만 받을지, 음성 파일까지 받을지는 '
                    '설정 → 음성 메모에서 기기마다 고를 수 있습니다.'),
              ),
              const Divider(),
              _SectionTitle('이 기기'),
              ListTile(
                leading: const Icon(Icons.smartphone),
                title: Text(settings.deviceName),
                subtitle: Text(sync.addresses.isEmpty
                    ? '네트워크 연결 없음 (오프라인에서도 메모는 그대로 쓸 수 있습니다)'
                    : [
                        for (final a in sync.addresses)
                          '${isTailscaleAddress(a) ? 'Tailscale' : 'Wi-Fi'} $a',
                      ].join('\n')),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
                child: Text(
                  '같은 Wi-Fi에 있으면 바로 연결됩니다. 밖에서(LTE, 다른 Wi-Fi) 연결하려면 '
                  '각 기기에 Tailscale 앱을 설치하고 같은 계정으로 로그인해 켜 두세요. '
                  '이 앱이 Tailscale 주소를 자동으로 찾아 씁니다.\n'
                  '앱이 열려 있는 동안 동기화되고, 꺼져 있던 기기는 다음에 열 때 '
                  '밀린 내용을 자동으로 받습니다.',
                  style: theme.textTheme.bodySmall,
                ),
              ),
              if (sync.paired) ...[
                const Divider(),
                ListTile(
                  leading: Icon(Icons.link_off, color: theme.colorScheme.error),
                  title: Text('동기화 그룹에서 나가기',
                      style: TextStyle(color: theme.colorScheme.error)),
                  subtitle: const Text('이 기기의 메모는 그대로 남고, 다른 기기와 연결만 끊습니다.'),
                  onTap: () => _confirmLeave(context, sync),
                ),
              ],
            ],
          );
        },
      ),
    );
  }

  static Future<void> _scanAndJoin(BuildContext context) async {
    final code = await Navigator.of(context).push<String>(
        MaterialPageRoute(builder: (_) => const ScanPairingQrScreen()));
    if (code == null || !context.mounted) return;
    await joinWithCode(context, code);
  }

  static Future<void> _pasteAndJoin(BuildContext context) async {
    final clip = await Clipboard.getData(Clipboard.kTextPlain);
    if (!context.mounted) return;
    final controller = TextEditingController(text: clip?.text ?? '');
    final code = await showDialog<String>(
      context: context,
      builder: (d) => AlertDialog(
        title: const Text('연결 코드'),
        content: TextField(
          controller: controller,
          maxLines: 4,
          decoration: const InputDecoration(hintText: 'GSNOTE1:...'),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(d), child: const Text('취소')),
          FilledButton(
              onPressed: () => Navigator.pop(d, controller.text),
              child: const Text('연결')),
        ],
      ),
    );
    if (code == null || !context.mounted) return;
    await joinWithCode(context, code);
  }

  static Future<void> _confirmLeave(BuildContext context, SyncService sync) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (d) => AlertDialog(
        title: const Text('동기화 그룹에서 나갈까요?'),
        content: const Text('이 기기의 메모는 지워지지 않습니다. 다른 기기들은 이 기기와 '
            '더 이상 주고받지 않습니다. 다시 연결하려면 QR코드를 스캔하세요.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(d, false), child: const Text('취소')),
          FilledButton(
              onPressed: () => Navigator.pop(d, true), child: const Text('나가기')),
        ],
      ),
    );
    if (ok == true) await sync.leaveGroup();
  }
}

/// Joins the group from a scanned or pasted code, with feedback.
Future<void> joinWithCode(BuildContext context, String code) async {
  final sync = AppScope.of(context).sync;
  final messenger = ScaffoldMessenger.of(context);
  final PairingInvite invite;
  try {
    invite = PairingInvite.decode(code);
  } on FormatException catch (e) {
    messenger.showSnackBar(SnackBar(content: Text(e.message)));
    return;
  }
  if (sync.paired && sync.peers.isNotEmpty &&
      !sync.peers.any((p) => p.id == invite.deviceId)) {
    final ok = await showDialog<bool>(
      context: context,
      builder: (d) => AlertDialog(
        title: const Text('다른 동기화 그룹으로 옮길까요?'),
        content: Text('이 기기는 이미 다른 기기들과 연결되어 있습니다. '
            '${invite.name}의 그룹으로 옮기면 기존 연결은 끊어집니다. '
            '메모는 지워지지 않고 새 그룹으로 함께 옮겨집니다.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(d, false), child: const Text('취소')),
          FilledButton(
              onPressed: () => Navigator.pop(d, true), child: const Text('옮기기')),
        ],
      ),
    );
    if (ok != true) return;
  }
  if (!context.mounted) return;
  showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (_) => PopScope(
      canPop: false,
      child: AlertDialog(
        content: Row(children: [
          const CircularProgressIndicator(),
          const SizedBox(width: 20),
          Expanded(child: Text('${invite.name}에 연결하는 중…')),
        ]),
      ),
    ),
  );
  String message;
  try {
    final name = await sync.join(invite);
    message = '$name과(와) 연결되었습니다. 메모를 맞추는 중입니다.';
  } on PairingException catch (e) {
    message = e.message;
  } catch (_) {
    message = '연결하지 못했습니다. 다시 시도해 주세요.';
  }
  if (context.mounted) Navigator.of(context, rootNavigator: true).pop();
  messenger.showSnackBar(SnackBar(content: Text(message)));
}

class _SectionTitle extends StatelessWidget {
  const _SectionTitle(this.text);
  final String text;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
        child: Text(text,
            style: Theme.of(context)
                .textTheme
                .titleSmall
                ?.copyWith(color: Theme.of(context).colorScheme.primary)),
      );
}

class _PeerTile extends StatelessWidget {
  const _PeerTile({required this.peer, required this.syncing});
  final Peer peer;
  final bool syncing;

  IconData get _icon => switch (peer.platform) {
        'macos' || 'windows' || 'linux' => Icons.laptop_mac,
        'ios' => Icons.phone_iphone,
        _ => Icons.smartphone,
      };

  String _status() {
    if (syncing) return '동기화 중…';
    final via = peer.lastAddress == null
        ? ''
        : isTailscaleAddress(peer.lastAddress!)
            ? ' · Tailscale'
            : ' · 같은 Wi-Fi';
    final at = peer.lastSyncAt;
    if (peer.lastError != null) {
      final when = at == null ? '' : ' (마지막 동기화 ${_ago(at)})';
      return '지금은 연결되지 않음$when';
    }
    if (at == null) return '아직 동기화 전';
    return '동기화됨 ${_ago(at)}$via';
  }

  static String _ago(DateTime t) {
    final d = DateTime.now().difference(t);
    if (d.inSeconds < 60) return '방금';
    if (d.inMinutes < 60) return '${d.inMinutes}분 전';
    if (d.inHours < 24) return '${d.inHours}시간 전';
    return '${d.inDays}일 전';
  }

  @override
  Widget build(BuildContext context) {
    return ListTile(
      leading: Icon(_icon),
      title: Text(peer.name),
      subtitle: Text(_status()),
      trailing: syncing
          ? const SizedBox.square(
              dimension: 20, child: CircularProgressIndicator(strokeWidth: 2))
          : peer.lastError == null && peer.lastSyncAt != null
              ? const Icon(Icons.check_circle_outline)
              : const Icon(Icons.cloud_off_outlined),
      onTap: () => _showPeerSheet(context),
    );
  }

  Future<void> _showPeerSheet(BuildContext context) async {
    final sync = AppScope.of(context).sync;
    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (sheet) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              title: Text(peer.name),
              subtitle: Text([
                ...peer.addresses.map((a) =>
                    '${isTailscaleAddress(a) ? 'Tailscale' : 'Wi-Fi'} $a'),
                if (peer.manualAddress != null) '직접 입력 ${peer.manualAddress}',
              ].join('\n')),
            ),
            ListTile(
              leading: const Icon(Icons.sync),
              title: const Text('지금 동기화'),
              onTap: () {
                Navigator.pop(sheet);
                sync.syncWith(peer);
              },
            ),
            ListTile(
              leading: const Icon(Icons.edit_location_alt_outlined),
              title: const Text('주소 직접 입력'),
              subtitle: const Text('자동으로 못 찾을 때: Tailscale 주소(100.x.x.x)나 '
                  'MagicDNS 이름'),
              onTap: () async {
                Navigator.pop(sheet);
                final controller =
                    TextEditingController(text: peer.manualAddress ?? '');
                final value = await showDialog<String>(
                  context: context,
                  builder: (d) => AlertDialog(
                    title: Text('${peer.name} 주소'),
                    content: TextField(
                      controller: controller,
                      autofocus: true,
                      keyboardType: TextInputType.url,
                      decoration: const InputDecoration(
                          hintText: '예: 100.101.102.103 또는 macbook'),
                    ),
                    actions: [
                      TextButton(
                          onPressed: () => Navigator.pop(d),
                          child: const Text('취소')),
                      FilledButton(
                          onPressed: () => Navigator.pop(d, controller.text),
                          child: const Text('저장')),
                    ],
                  ),
                );
                if (value != null) await sync.setManualAddress(peer.id, value);
              },
            ),
            ListTile(
              leading: Icon(Icons.delete_outline,
                  color: Theme.of(context).colorScheme.error),
              title: Text('이 기기 제거',
                  style: TextStyle(color: Theme.of(context).colorScheme.error)),
              subtitle: const Text('모든 기기가 이 기기와 동기화를 멈춥니다. '
                  '잃어버린 기기라면 여기서 제거하세요.'),
              onTap: () async {
                Navigator.pop(sheet);
                final ok = await showDialog<bool>(
                  context: context,
                  builder: (d) => AlertDialog(
                    title: Text('${peer.name}을(를) 제거할까요?'),
                    content: const Text('그 기기에 이미 있는 메모는 남지만, 앞으로의 변경은 '
                        '주고받지 않습니다. 다시 연결하려면 QR코드를 스캔하세요.'),
                    actions: [
                      TextButton(
                          onPressed: () => Navigator.pop(d, false),
                          child: const Text('취소')),
                      FilledButton(
                          onPressed: () => Navigator.pop(d, true),
                          child: const Text('제거')),
                    ],
                  ),
                );
                if (ok == true) await sync.removePeer(peer.id);
              },
            ),
          ],
        ),
      ),
    );
  }
}

/// Shows the "add device" QR code while this screen is open.
class ShowPairingQrScreen extends StatefulWidget {
  const ShowPairingQrScreen({super.key});

  @override
  State<ShowPairingQrScreen> createState() => _ShowPairingQrScreenState();
}

class _ShowPairingQrScreenState extends State<ShowPairingQrScreen> {
  late final SyncService _sync;
  String? _code;
  String? _error;

  @override
  void initState() {
    super.initState();
    _sync = AppScope.of(context).sync;
    _sync.startPairing().then((invite) {
      if (!mounted) return;
      setState(() {
        _code = invite.encode();
        if (invite.addresses.isEmpty) {
          _error = '이 기기가 네트워크에 연결되어 있지 않습니다. Wi-Fi를 켜거나 '
              'Tailscale을 켠 뒤 다시 열어 주세요.';
        }
      });
    });
  }

  @override
  void dispose() {
    _sync.stopPairing();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('기기 추가')),
      body: ListenableBuilder(
        listenable: _sync,
        builder: (context, _) {
          final joined = _sync.pairing?.joined ?? const <String>[];
          return ListView(
            padding: const EdgeInsets.all(24),
            children: [
              Text('새 기기에서 메모 앱을 열고\n설정 → 기기 동기화 → QR코드 스캔해서 연결',
                  textAlign: TextAlign.center, style: theme.textTheme.titleMedium),
              const SizedBox(height: 24),
              Center(
                child: _code == null
                    ? const SizedBox.square(
                        dimension: 260,
                        child: Center(child: CircularProgressIndicator()))
                    : Container(
                        color: Colors.white,
                        padding: const EdgeInsets.all(12),
                        child: QrImageView(data: _code!, size: 260),
                      ),
              ),
              if (_error != null) ...[
                const SizedBox(height: 16),
                Text(_error!,
                    textAlign: TextAlign.center,
                    style: TextStyle(color: theme.colorScheme.error)),
              ],
              const SizedBox(height: 16),
              Text('이 화면이 열려 있는 동안만 연결할 수 있습니다 (최대 10분). '
                  '여러 기기를 차례로 스캔해도 됩니다.',
                  textAlign: TextAlign.center, style: theme.textTheme.bodySmall),
              if (_code != null)
                Center(
                  child: TextButton.icon(
                    icon: const Icon(Icons.copy, size: 18),
                    label: const Text('코드 복사 (카메라 없는 기기용)'),
                    onPressed: () {
                      Clipboard.setData(ClipboardData(text: _code!));
                      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
                          content: Text('복사했습니다. 이 코드는 10분 뒤 만료됩니다.')));
                    },
                  ),
                ),
              for (final name in joined)
                ListTile(
                  leading: const Icon(Icons.check_circle, color: Colors.green),
                  title: Text('$name 연결됨'),
                ),
            ],
          );
        },
      ),
    );
  }
}

/// Camera view that returns the first pairing code it sees.
class ScanPairingQrScreen extends StatefulWidget {
  const ScanPairingQrScreen({super.key});

  @override
  State<ScanPairingQrScreen> createState() => _ScanPairingQrScreenState();
}

class _ScanPairingQrScreenState extends State<ScanPairingQrScreen> {
  final _controller = MobileScannerController(formats: const [BarcodeFormat.qrCode]);
  bool _done = false;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('QR코드 스캔')),
      body: Stack(
        children: [
          MobileScanner(
            controller: _controller,
            onDetect: (capture) {
              if (_done) return;
              for (final b in capture.barcodes) {
                final v = b.rawValue;
                if (v != null && v.startsWith('GSNOTE1:')) {
                  _done = true;
                  Navigator.of(context).pop(v);
                  return;
                }
              }
            },
            errorBuilder: (context, error) => Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Text(
                  '카메라를 열 수 없습니다. 카메라 권한을 허용하거나, '
                  '"연결 코드 붙여넣기"를 이용해 주세요.',
                  textAlign: TextAlign.center,
                  style: const TextStyle(color: Colors.white),
                ),
              ),
            ),
          ),
          const Align(
            alignment: Alignment.bottomCenter,
            child: Padding(
              padding: EdgeInsets.all(24),
              child: Text('다른 기기에 띄운 QR코드를 비춰 주세요',
                  style: TextStyle(color: Colors.white, fontSize: 16)),
            ),
          ),
        ],
      ),
    );
  }
}
