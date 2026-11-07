import 'package:flutter/material.dart';

import 'app.dart';
import 'app_scope.dart';
import 'data/database.dart';
import 'data/note_repository.dart';
import 'data/settings_store.dart';
import 'security/app_lock.dart';
import 'sync/sync_service.dart';
import 'sync/sync_store.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final db = await openEncryptedDatabase();
  final settings = await SettingsStore.load(db);
  final repo = await NoteRepository.load(db, settings);
  final lock = AppLock(settings);
  final sync = SyncService(
    store: SyncStore(db, settings.deviceId),
    settings: settings,
    repo: repo,
  );
  // Networking starts in the background; the notes are usable right away.
  sync.start();
  runApp(AppScope(
    repo: repo,
    settings: settings,
    lock: lock,
    sync: sync,
    child: const NoteApp(),
  ));
}
