import 'dashboard_widgets.dart';
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
  final search = TextEditingController();
  String category = 'All';
  int tab = 0;
  bool visitedWorkflows = false;
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

  Future<void> open(String path, {bool sign = false}) async {
    if (operations == null) {
      error(
        'Install the QPDF/PDFium native bridge for your device architecture.',
      );
      return;
    }
    await Navigator.push<void>(
      context,
      MaterialPageRoute(
        builder: (context) => PdfViewerScreen(
          path: path,
          operations: operations!,
          signOnOpen: sign,
        ),
      ),
    );
  }

  Future<void> cloud([String format = 'docx']) async {
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
          builder: (context) => CloudJobSheet(
            api: api,
            database: widget.database,
            initialFormat: format,
          ),
        ),
      );
    } finally {
      api.close();
    }
  }

  Future<void> local([
    String tool = 'Extract pages',
    String format = 'png',
  ]) async {
    await Navigator.push<void>(
      context,
      MaterialPageRoute(
        builder: (_) => LocalToolsScreen(
          database: widget.database,
          initialTool: tool,
          initialFormat: format,
        ),
      ),
    );
    await reload();
  }

  Future<void> compose() async {
    final engine = operations;
    if (engine == null) {
      error('Native engine installation required');
      return;
    }
    await Navigator.push<void>(
      context,
      MaterialPageRoute(
        builder: (_) =>
            PageComposerScreen(database: widget.database, operations: engine),
      ),
    );
    await reload();
  }

  Future<void> view({bool sign = false}) => guard(() async {
    final path = await pick();
    if (path != null && mounted) await open(path, sign: sign);
  });

  Future<void> scan() => guard(() async {
    final path = await DocumentScannerService().scan();
    if (path == null) return;
    await widget.database.addDocument(
      const Uuid().v4(),
      'Scanned document.pdf',
      path,
    );
    await SharePlus.instance.share(ShareParams(files: [XFile(path)]));
  });

  Future<void> optimize() => guard(() async {
    final engine = operations;
    if (engine == null) throw StateError('Native engine required');
    final path = await pick();
    if (path == null) return;
    final output = await engine.optimize(path);
    await widget.database.addDocument(
      const Uuid().v4(),
      'Optimized document.pdf',
      output,
    );
    await SharePlus.instance.share(ShareParams(files: [XFile(output)]));
  });

  void selectTab(int value) {
    if (busy) return;
    if (value == 2 && operations == null) {
      error('Native engine installation required');
      return;
    }
    setState(() {
      tab = value;
      if (value == 2) visitedWorkflows = true;
    });
    if (value == 1) reload();
  }

  Future<void> recipes() async {
    final engine = operations;
    if (engine == null) {
      error('Native engine installation required');
      return;
    }
    await Navigator.push<void>(
      context,
      MaterialPageRoute(
        builder: (_) => WorkflowRecipesScreen(
          database: widget.database,
          operations: engine,
        ),
      ),
    );
  }

  List<DashboardTool> get tools => [
    DashboardTool(
      'Merge PDF',
      'Combine documents in the order you want.',
      Icons.library_add_outlined,
      AppColors.red,
      ['Organize PDF'],
      compose,
    ),
    DashboardTool(
      'Split PDF',
      'Separate pages into individual PDF files.',
      Icons.vertical_split_outlined,
      AppColors.red,
      ['Organize PDF'],
      () => local('Split by ranges'),
    ),
    DashboardTool(
      'Compress PDF',
      'Optimize a PDF to reduce its file size.',
      Icons.compress,
      AppColors.green,
      ['Optimize PDF'],
      optimize,
    ),
    DashboardTool(
      'Scan Document',
      'Capture paper pages with your camera.',
      Icons.document_scanner_outlined,
      AppColors.slate,
      ['Convert PDF'],
      scan,
    ),
    DashboardTool(
      'PDF to Word',
      'Convert a PDF to an editable Word file.',
      Icons.article_outlined,
      AppColors.word,
      ['Convert PDF'],
      cloud,
      cloud: true,
      keywords: 'docx cloud conversion',
    ),
    DashboardTool(
      'Word to PDF',
      'Convert a Word document to PDF.',
      Icons.file_present_outlined,
      AppColors.word,
      ['Convert PDF'],
      () => cloud('pdf'),
      cloud: true,
      keywords: 'doc docx',
    ),
    DashboardTool(
      'PDF to JPG',
      'Export PDF pages as images.',
      Icons.photo_outlined,
      AppColors.gold,
      ['Convert PDF'],
      () => local('PDF to images', 'jpg'),
      keywords: 'jpeg png webp tiff',
    ),
    DashboardTool(
      'JPG to PDF',
      'Combine images into one PDF.',
      Icons.photo_library_outlined,
      AppColors.gold,
      ['Convert PDF'],
      () => local('Images to PDF'),
      keywords: 'jpeg png webp tiff',
    ),
    DashboardTool(
      'Page Composer',
      'Reorder, rotate and duplicate pages.',
      Icons.dashboard_customize_outlined,
      AppColors.violet,
      ['Organize PDF', 'Edit PDF'],
      compose,
    ),
    DashboardTool(
      'Sign PDF',
      'Place a saved or typed signature.',
      Icons.draw_outlined,
      AppColors.blue,
      ['PDF Security', 'Edit PDF'],
      () => view(sign: true),
    ),
    DashboardTool(
      'View & Redact',
      'Read a PDF and black out sensitive text.',
      Icons.visibility_outlined,
      AppColors.plum,
      ['PDF Security', 'Edit PDF'],
      view,
    ),
    DashboardTool(
      'Recipes & Chains',
      'Run a saved sequence of PDF tasks.',
      Icons.bolt_outlined,
      AppColors.amber,
      ['Workflows', 'Optimize PDF'],
      recipes,
    ),
    DashboardTool(
      'Offline PDF Tools',
      'Extract, crop, protect or convert files.',
      Icons.tune,
      AppColors.slate,
      ['Edit PDF', 'PDF Security', 'Organize PDF'],
      local,
      keywords: 'encrypt decrypt metadata remove OCR',
    ),
    DashboardTool(
      'Cloud Conversion',
      'Choose an output format or review jobs.',
      Icons.cloud_outlined,
      AppColors.plum,
      ['Convert PDF'],
      cloud,
      cloud: true,
    ),
  ];

  Widget get searchBar => AppSearchBar(
    controller: search,
    hint: tab == 1 ? 'Search documents' : 'Search tools or documents',
    onChanged: (_) => setState(() {}),
  );

  List<Widget> fileList({required bool showEmpty}) {
    final docs = recent
        .where(
          (d) => (d['name'] as String).toLowerCase().contains(
            search.text.trim().toLowerCase(),
          ),
        )
        .toList();
    if (!showEmpty && docs.isEmpty) return [];
    return [
      SectionHeader(
        'Recent documents',
        trailing: TextButton.icon(
          onPressed: busy
              ? null
              : () => guard(() async {
                  await pick();
                }),
          icon: const Icon(Icons.add),
          label: const Text('Import'),
        ),
      ),
      if (docs.isEmpty)
        Text(
          search.text.trim().isEmpty
              ? 'Import or scan a PDF to get started.'
              : 'No matching documents.',
        ),
      for (final d in docs)
        Card(
          child: ListTile(
            leading: const Icon(Icons.picture_as_pdf_outlined),
            title: Text(d['name'] as String),
            subtitle: const Text('Stored on this device'),
            onTap: busy ? null : () => guard(() => open(d['path'] as String)),
          ),
        ),
    ];
  }

  @override
  Widget build(BuildContext context) {
    final visible = tools
        .where((item) => item.matches(category, search.text))
        .toList();
    final toggleLock = busy
        ? null
        : () => guard(() => SecureVault().setEnabled(!locked));
    return Scaffold(
      appBar: tab == 2
          ? null
          : AppBar(
              titleSpacing: Ui.md,
              title: const PdfGoWordmark(),
              actions: [
                IconButton(
                  tooltip: 'App lock',
                  onPressed: toggleLock,
                  icon: Icon(locked ? Icons.lock : Icons.lock_open),
                ),
              ],
            ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: tab,
        onDestinationSelected: selectTab,
        destinations: const [
          NavigationDestination(
            icon: Icon(Icons.grid_view_outlined),
            label: 'Tools',
          ),
          NavigationDestination(
            icon: Icon(Icons.folder_outlined),
            label: 'Files',
          ),
          NavigationDestination(
            icon: Icon(Icons.alt_route),
            label: 'Workflows',
          ),
          NavigationDestination(
            icon: Icon(Icons.settings_outlined),
            label: 'Settings',
          ),
        ],
      ),
      body: IndexedStack(
        index: tab == 2 ? 1 : 0,
        children: [
          SafeArea(
            top: false,
            bottom: false,
            child: ListView(
              key: PageStorageKey(tab),
              padding: const EdgeInsets.all(Ui.md),
              children: [
                if (busy) const LinearProgressIndicator(),
                if (tab == 0) ...[
                  searchBar,
                  const SizedBox(height: Ui.sm),
                  CategoryFilterBar(
                    selected: category,
                    onChanged: (value) => setState(() => category = value),
                  ),
                  const SizedBox(height: Ui.gutter),
                  SectionHeader(
                    category == 'All' ? 'All PDF Tools' : category,
                    trailing: Text(
                      '${visible.length} tools',
                      style: Theme.of(context).textTheme.labelMedium,
                    ),
                  ),
                  const SizedBox(height: Ui.gutter),
                  if (operations == null)
                    const Padding(
                      padding: EdgeInsets.only(bottom: Ui.gutter),
                      child: Text(
                        'Native PDF engine unavailable. Scan and cloud tools are still available.',
                      ),
                    ),
                  if (visible.isEmpty)
                    ListTile(
                      title: const Text('No matching tools'),
                      trailing: TextButton(
                        onPressed: () => setState(() {
                          search.clear();
                          category = 'All';
                        }),
                        child: const Text('Reset'),
                      ),
                    ),
                  ToolGrid(visible, enabled: !busy),
                  ...fileList(showEmpty: false),
                ] else if (tab == 1) ...[
                  searchBar,
                  const SizedBox(height: Ui.md),
                  ...fileList(showEmpty: true),
                ] else ...[
                  const SectionHeader('Settings'),
                  const SizedBox(height: Ui.gutter),
                  Card(
                    child: SwitchListTile(
                      title: const Text('App lock'),
                      subtitle: const Text(
                        'Require authentication to unlock the suite.',
                      ),
                      value: locked,
                      onChanged: toggleLock == null
                          ? null
                          : (_) => toggleLock(),
                    ),
                  ),
                ],
              ],
            ),
          ),
          if (visitedWorkflows)
            WorkflowRecipesScreen(
              database: widget.database,
              operations: operations!,
            ),
        ],
      ),
    );
  }

  @override
  void dispose() {
    search.dispose();
    incoming?.stop();
    super.dispose();
  }
}
