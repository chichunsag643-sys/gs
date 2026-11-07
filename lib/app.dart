import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_quill/flutter_quill.dart';

import 'app_scope.dart';
import 'ui/home_screen.dart';
import 'ui/lock_screen.dart';

class NoteApp extends StatelessWidget {
  const NoteApp({super.key});

  @override
  Widget build(BuildContext context) {
    final lock = AppScope.of(context).lock;
    return MaterialApp(
      title: '메모',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorSchemeSeed: const Color(0xFFE0A526),
        useMaterial3: true,
      ),
      darkTheme: ThemeData(
        colorSchemeSeed: const Color(0xFFE0A526),
        brightness: Brightness.dark,
        useMaterial3: true,
      ),
      locale: const Locale('ko'),
      supportedLocales: const [Locale('ko'), Locale('en')],
      localizationsDelegates: const [
        GlobalMaterialLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        FlutterQuillLocalizations.delegate,
      ],
      home: const HomeScreen(),
      // The lock screen sits on top of whatever page is open, so unlocking
      // returns to exactly where the user was.
      builder: (context, child) => ListenableBuilder(
        listenable: lock,
        builder: (context, _) => Stack(
          children: [
            child!,
            if (lock.locked) const Positioned.fill(child: LockScreen()),
          ],
        ),
      ),
    );
  }
}
