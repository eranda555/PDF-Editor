import 'package:flutter/material.dart';

import 'core/database/app_database.dart';
import 'core/security/secure_vault.dart';
import 'core/theme/app_theme.dart';
import 'features/home/home_screen.dart';
import 'services/background_transfers.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await BackgroundTransfers.initialize();
  PaintingBinding.instance.imageCache.maximumSizeBytes = 32 * 1024 * 1024;
  runApp(const PdfSuiteApp());
}

class PdfSuiteApp extends StatefulWidget {
  const PdfSuiteApp({super.key});
  @override
  State<PdfSuiteApp> createState() => _AppState();
}

class _AppState extends State<PdfSuiteApp> with WidgetsBindingObserver {
  final database = AppDatabase();
  bool unlocked = false;
  bool authenticating = false;
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    unlock();
  }

  Future<void> unlock() async {
    if (authenticating) return;
    authenticating = true;
    try {
      final success = await SecureVault().unlock();
      if (mounted) setState(() => unlocked = success);
    } catch (_) {
      if (mounted) setState(() => unlocked = false);
    } finally {
      authenticating = false;
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (authenticating) return;
    if (state == AppLifecycleState.paused) setState(() => unlocked = false);
    if (state == AppLifecycleState.resumed) unlock();
  }

  @override
  Widget build(BuildContext context) => MaterialApp(
    title: '100% PDF Suite',
    debugShowCheckedModeBanner: false,
    theme: appTheme(),
    home: HomeScreen(database: database),
    builder: (context, child) => Stack(
      children: [
        child!,
        if (!unlocked)
          Positioned.fill(
            child: Scaffold(
              body: Center(
                child: FilledButton.icon(
                  onPressed: unlock,
                  icon: const Icon(Icons.lock),
                  label: const Text('Unlock PDF Suite'),
                ),
              ),
            ),
          ),
      ],
    ),
  );
  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    database.close();
    super.dispose();
  }
}
