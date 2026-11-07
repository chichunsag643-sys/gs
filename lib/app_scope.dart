import 'package:flutter/widgets.dart';

import 'data/note_repository.dart';
import 'data/settings_store.dart';
import 'security/app_lock.dart';

/// Hands the app's long-lived services to the widget tree.
class AppScope extends InheritedWidget {
  const AppScope({
    super.key,
    required this.repo,
    required this.settings,
    required this.lock,
    required super.child,
  });

  final NoteRepository repo;
  final SettingsStore settings;
  final AppLock lock;

  static AppScope of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<AppScope>()!;

  @override
  bool updateShouldNotify(AppScope oldWidget) =>
      repo != oldWidget.repo ||
      settings != oldWidget.settings ||
      lock != oldWidget.lock;
}
