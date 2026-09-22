// Engine | Flutter 3.x / Dart 3 | lib/main.dart
// Build: flutter pub get
// Run:   flutter run   (Windows 桌面 / Android / iOS)

import 'package:flutter/material.dart';

import 'core/session.dart';
import 'ui/home_shell.dart';
import 'ui/splash_page.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Session.I.init();
  runApp(const NuaaEamsApp());
}

class NuaaEamsApp extends StatelessWidget {
  const NuaaEamsApp({super.key});

  static final ColorScheme _scheme =
      ColorScheme.fromSeed(seedColor: const Color(0xFF0A3D8F));

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'i泥航',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: _scheme,
        useMaterial3: true,
        fontFamily: 'HarmonyOS Sans SC',
        // 标题栏颜色钉死：显式背景色 + 无 tint + 滚动不升高程，
        // 三个都关掉后滚动时不再有任何变色/状态切换
        appBarTheme: AppBarTheme(
          backgroundColor: _scheme.surface,
          surfaceTintColor: Colors.transparent,
          elevation: 0,
          scrolledUnderElevation: 0,
        ),
      ),
      home: const SplashPage(),
      routes: {'/home': (_) => const HomeShell()},
    );
  }
}
