import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:share_plus/share_plus.dart';
import 'package:uuid/uuid.dart';

import '../../core/database/app_database.dart';
import '../../core/security/file_sanitizer.dart';
import '../../core/security/secure_vault.dart';
import '../../core/theme/app_theme.dart';
import '../../services/api_client.dart';
import '../../services/document_scanner.dart';
import '../../services/pdf_operations.dart';
import '../../services/incoming_files.dart';
import '../composer/page_composer_screen.dart';
import '../viewer/pdf_viewer_screen.dart';
import '../recipes/workflow_recipes_screen.dart';
import '../jobs/cloud_job_sheet.dart';
import '../tools/local_tools_screen.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key, required this.database});
  final AppDatabase database;
  @override
  State<HomeScreen> createState() => _HomeState();
}

class _HomeState extends State<HomeScreen> {
  PdfOperations? operations;
  List<Map<String, dynamic>> recent = [];
  String query = '';
  bool busy = false;
  bool locked = false;
  IncomingFiles? incoming;
  @override
  void initState() {
    super.initState();
    try {
      operations = PdfOperations();
    } on ArgumentError {
      operations = null;
    }
    reload();
    incoming = IncomingFiles(widget.database, () {
      reload();
    });
    incoming!.start();
  }

  Future<void> reload() async {
    final documents = await widget.database.documents();
    final enabled = await SecureVault().enabled;
    if (mounted) {
      setState(() {
        recent = documents;
        locked = enabled;
      });
    }
  }

  void error(String value) {
    if (mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(value)));
    }
  }

  Future<void> guard(Future<void> Function() action) async {
    setState(() => busy = true);
    try {
      await action();
      await reload();
    } catch (_) {
      error(
        'Operation unavailable. Check input file and native engine installation.',
      );
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<String?> pick() async {
    final result = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['pdf'],
    );
    if (result == null || result.files.single.path == null) return null;
    final file = await FileSanitizer.importFile(result.files.single.path!);
    await widget.database.addDocument(
      const Uuid().v4(),
      FileSanitizer.displayName(result.files.single.name),
      file.path,
    );
    return file.path;
  }

  Future<void> open(String path) async {
    if (operations == null) {
      error(
        'Install the QPDF/PDFium native bridge for your device architecture.',
      );
      return;
    }
    await Navigator.push<void>(
      context,
      MaterialPageRoute(
        builder: (context) =>
            PdfViewerScreen(path: path, operations: operations!),
      ),
    );
  }

  Future<void> cloud() async {
    const endpoint = String.fromEnvironment('PDF_API_URL');
    if (endpoint.isEmpty) {
      error('Cloud is not configured. Offline tools remain available.');
      return;
    }
    final api = ApiClient(endpoint);
    try {
      await Navigator.push<void>(
        context,
        MaterialPageRoute(
          builder: (context) =>
              CloudJobSheet(api: api, database: widget.database),
        ),
      );
    } finally {
      api.close();
    }
  }

  @override
  Widget build(BuildContext context) {
    final filtered = recent
        .where(
          (document) => (document['name'] as String).toLowerCase().contains(
            query.toLowerCase(),
          ),
        )
        .toList();
    return Scaffold(
      appBar: AppBar(
        title: const Text('100% PDF Suite'),
        actions: [
          IconButton(
            tooltip: 'App lock',
            onPressed: () => guard(() async {
              await SecureVault().setEnabled(!locked);
            }),
            icon: Icon(locked ? Icons.lock : Icons.lock_open),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          Text(
            'Your documents.\nYour control.',
            style: Theme.of(context).textTheme.headlineSmall,
          ),
          const SizedBox(height: 16),
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: AppColors.blush,
              borderRadius: BorderRadius.circular(16),
            ),
            child: const Row(
              children: [
                Icon(Icons.verified_user_outlined),
                SizedBox(width: 12),
                Expanded(
                  child: Text(
                    'Offline by default. You choose when a file leaves your device.',
                  ),
                ),
              ],
            ),
          ),
          if (operations == null)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 12),
              child: Text(
                'Native PDF engine is not installed in this build. Scan and cloud tools can run independently.',
              ),
            ),
          const SizedBox(height: 20),
          TextField(
            decoration: const InputDecoration(
              hintText: 'Search documents',
              prefixIcon: Icon(Icons.search),
            ),
            onChanged: (text) => setState(() => query = text),
          ),
          const SizedBox(height: 24),
          Text('Tools', style: Theme.of(context).textTheme.titleMedium),
          if (busy) const LinearProgressIndicator(),
          GridView.count(
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            crossAxisCount: 2,
            childAspectRatio: 1.05,
            mainAxisSpacing: 10,
            crossAxisSpacing: 10,
            children: [
              tool('Offline PDF tools', Icons.construction_outlined, () async {
                await Navigator.push<void>(
                  context,
                  MaterialPageRoute(
                    builder: (context) =>
                        LocalToolsScreen(database: widget.database),
                  ),
                );
                await reload();
              }),
              tool(
                'Page composer',
                Icons.dashboard_customize_outlined,
                () async {
                  if (operations == null) {
                    error('Native engine installation required');
                    return;
                  }
                  await Navigator.push<void>(
                    context,
                    MaterialPageRoute(
                      builder: (context) => PageComposerScreen(
                        operations: operations!,
                        database: widget.database,
                      ),
                    ),
                  );
                  await reload();
                },
              ),
              tool(
                'View & redact',
                Icons.edit_document,
                () => guard(() async {
                  final path = await pick();
                  if (path != null) await open(path);
                }),
              ),
              tool(
                'Scan document',
                Icons.document_scanner_outlined,
                () => guard(() async {
                  final path = await DocumentScannerService().scan();
                  if (path != null) {
                    await widget.database.addDocument(
                      const Uuid().v4(),
                      'Scanned document.pdf',
                      path,
                    );
                    await SharePlus.instance.share(
                      ShareParams(files: [XFile(path)]),
                    );
                  }
                }),
              ),
              tool(
                'Optimize PDF',
                Icons.compress,
                () => guard(() async {
                  if (operations == null) {
                    throw StateError('Native engine required');
                  }
                  final path = await pick();
                  if (path == null) return;
                  final output = await operations!.optimize(path);
                  await widget.database.addDocument(
                    const Uuid().v4(),
                    'Optimized document.pdf',
                    output,
                  );
                  await SharePlus.instance.share(
                    ShareParams(files: [XFile(output)]),
                  );
                }),
              ),
              tool('Recipes', Icons.auto_awesome, () async {
                if (operations == null) {
                  error('Native engine installation required');
                  return;
                }
                await Navigator.push<void>(
                  context,
                  MaterialPageRoute(
                    builder: (context) => WorkflowRecipesScreen(
                      database: widget.database,
                      operations: operations!,
                    ),
                  ),
                );
              }),
              tool(
                'Cloud conversion',
                Icons.cloud_outlined,
                cloud,
                cloudTask: true,
              ),
            ],
          ),
          const SizedBox(height: 24),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                'Recent documents',
                style: Theme.of(context).textTheme.titleMedium,
              ),
              TextButton(
                onPressed: busy
                    ? null
                    : () => guard(() async {
                        await pick();
                      }),
                child: const Text('Import'),
              ),
            ],
          ),
          if (filtered.isEmpty)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 20),
              child: Text('Import or scan a document to get started.'),
            ),
          for (final document in filtered)
            Card(
              child: ListTile(
                leading: const Icon(Icons.picture_as_pdf_outlined),
                title: Text(document['name'] as String),
                subtitle: const Text('Stored on this device'),
                onTap: busy
                    ? null
                    : () => guard(() => open(document['path'] as String)),
              ),
            ),
        ],
      ),
    );
  }

  Widget tool(
    String title,
    IconData icon,
    Future<void> Function() action, {
    bool cloudTask = false,
  }) => Card(
    child: InkWell(
      borderRadius: BorderRadius.circular(16),
      onTap: busy ? null : action,
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Container(
              padding: const EdgeInsets.all(9),
              decoration: BoxDecoration(
                color: AppColors.primary20,
                borderRadius: BorderRadius.circular(12),
              ),
              child: Icon(icon),
            ),
            Text(title, style: const TextStyle(fontWeight: FontWeight.w600)),
            ExecutionBadge(cloud: cloudTask),
          ],
        ),
      ),
    ),
  );
  @override
  void dispose() {
    incoming?.stop();
    super.dispose();
  }
}
