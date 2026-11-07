import 'package:flutter/material.dart';

import '../app_scope.dart';

class SettingsScreen extends StatelessWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final scope = AppScope.of(context);
    final settings = scope.settings;
    return Scaffold(
      appBar: AppBar(title: const Text('설정')),
      body: ListenableBuilder(
        listenable: settings,
        builder: (context, _) => ListView(
          children: [
            SwitchListTile(
              secondary: const Icon(Icons.folder_copy_outlined),
              title: const Text('서재 사용'),
              subtitle: const Text('끄면 폴더 없이 메모장만 사용합니다. 폴더 정보는 그대로 남습니다.'),
              value: settings.libraryEnabled,
              onChanged: settings.setLibraryEnabled,
            ),
            SwitchListTile(
              secondary: const Icon(Icons.fingerprint),
              title: const Text('지문 잠금'),
              subtitle: const Text('앱을 열 때와 다시 돌아올 때 지문(또는 기기 잠금)으로 확인합니다.'),
              value: settings.lockEnabled,
              onChanged: (v) async {
                final lock = scope.lock;
                if (v && !await lock.isAvailable()) {
                  if (!context.mounted) return;
                  ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
                    content: Text('이 기기에서 지문 또는 화면 잠금이 설정되어 있지 않습니다.'),
                  ));
                  return;
                }
                await lock.setEnabled(v);
              },
            ),
            const Divider(),
            ListTile(
              leading: const Icon(Icons.smartphone),
              title: const Text('이 기기 이름'),
              subtitle: Text(settings.deviceName),
              onTap: () async {
                final controller = TextEditingController(text: settings.deviceName);
                final name = await showDialog<String>(
                  context: context,
                  builder: (d) => AlertDialog(
                    title: const Text('기기 이름'),
                    content: TextField(controller: controller, autofocus: true),
                    actions: [
                      TextButton(
                          onPressed: () => Navigator.pop(d),
                          child: const Text('취소')),
                      FilledButton(
                          onPressed: () => Navigator.pop(d, controller.text.trim()),
                          child: const Text('확인')),
                    ],
                  ),
                );
                if (name != null && name.isNotEmpty) {
                  await settings.setDeviceName(name);
                }
              },
            ),
            const ListTile(
              leading: Icon(Icons.lock_outline),
              title: Text('저장 위치'),
              subtitle: Text('모든 메모는 이 기기에만 암호화되어 저장됩니다. 외부 서버로 전송되지 않습니다.'),
            ),
            const ListTile(
              leading: Icon(Icons.sync_disabled),
              title: Text('기기 간 동기화'),
              subtitle: Text('다음 단계에서 추가됩니다 (QR 기기 추가, 같은 Wi-Fi / Tailscale).'),
            ),
          ],
        ),
      ),
    );
  }
}
