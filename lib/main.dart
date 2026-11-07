import 'package:flutter/material.dart';

import 'app.dart';
import 'app_scope.dart';
import 'data/database.dart';
import 'data/note_repository.dart';
import 'data/settings_store.dart';
import 'security/app_lock.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final db = await openEncryptedDatabase();
  final settings = await SettingsStore.load(db);
  final repo = await NoteRepository.load(db, settings);
  final lock = AppLock(settings);
  runApp(AppScope(
    repo: repo,
    settings: settings,
    lock: lock,
    child: const NoteApp(),
  ));
}
