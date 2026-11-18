import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:share_plus/share_plus.dart';

import '../../core/database/app_database.dart';
import '../../core/security/file_sanitizer.dart';
import '../../core/theme/app_theme.dart';
import '../../services/pdf_operations.dart';
import '../../services/page_range.dart';
import '../../services/document_scanner.dart';

import 'package:uuid/uuid.dart';

class PageComposerScreen extends StatefulWidget {
  const PageComposerScreen({
    super.key,
    required this.operations,
    required this.database,
  });
  final PdfOperations operations;
  final AppDatabase database;
  @override
  State<PageComposerScreen> createState() => _ComposerState();
}

class _ComposerState extends State<PageComposerScreen> {
  final pages = <ComposerPage>[];
  final selected = <String>{};
  bool busy = false;
  Future<void> scan() => run(() async {
    final path = await DocumentScannerService().scan();
    if (path == null) return;
    final count = widget.operations.pageCount(path);
    pages.addAll([for (var i = 0; i < count; i++) ComposerPage(path, i)]);
  });
  Future<void> run(Future<void> Function() action) async {
    setState(() => busy = true);
    try {
      await action();
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
              'Could not complete the PDF operation. Check the input files.',
            ),
          ),
        );
      }
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> add() async {
    final result = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['pdf'],
      allowMultiple: true,
    );
    if (result == null) return;
    if (!mounted) return;
    final rangeController = TextEditingController(text: '1-end');
    String? range;
    try {
      range = await showDialog<String>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('Choose pages'),
          content: TextField(
            controller: rangeController,
            decoration: const InputDecoration(
              labelText: 'Range for each document',
              hintText: '1-3,5,8-end',
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, rangeController.text),
              child: const Text('Add pages'),
            ),
          ],
        ),
      );
    } finally {
      rangeController.dispose();
    }
    if (range == null) return;
    await run(() async {
      for (final file in result.files) {
        if (file.path == null) continue;
        final imported = await FileSanitizer.importFile(file.path!);
        final count = widget.operations.pageCount(imported.path);
        pages.addAll([
          for (final index in parsePageRange(range!, count))
            ComposerPage(imported.path, index),
        ]);
      }
    });
  }

  Future<void> export() => run(() async {
    final output = await widget.operations.compose(pages);
    await widget.database.addDocument(
      const Uuid().v4(),
      'Composed document.pdf',
      output,
    );
    await SharePlus.instance.share(
      ShareParams(files: [XFile(output)], text: 'Composed document'),
    );
  });
  void move(String id, int target) {
    final ids = selected.contains(id) ? selected : {id};
    final moving = pages.where((page) => ids.contains(page.id)).toList();
    final insertion = pages
        .take(target)
        .where((page) => !ids.contains(page.id))
        .length;
    setState(() {
      pages.removeWhere((page) => ids.contains(page.id));
      pages.insertAll(insertion, moving);
    });
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: const Text('Page composer'),
      actions: [
        IconButton(
          onPressed: busy ? null : scan,
          tooltip: 'Insert scanned pages',
          icon: const Icon(Icons.document_scanner_outlined),
        ),
        IconButton(onPressed: busy ? null : add, icon: const Icon(Icons.add)),
      ],
    ),
    bottomNavigationBar: SafeArea(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: FilledButton.icon(
          onPressed: busy || pages.isEmpty ? null : export,
          icon: const Icon(Icons.ios_share),
          label: Text('Export ${pages.length} pages'),
        ),
      ),
    ),
    body: Column(
      children: [
        const Padding(padding: EdgeInsets.all(12), child: ExecutionBadge()),
        if (busy) const LinearProgressIndicator(),
        Wrap(
          spacing: 8,
          children: [
            TextButton.icon(
              onPressed: busy
                  ? null
                  : () => setState(() {
                      for (final page in pages.where(
                        (page) => selected.contains(page.id),
                      )) {
                        page.rotation = (page.rotation + 90) % 360;
                      }
                    }),
              icon: const Icon(Icons.rotate_right),
              label: const Text('Rotate'),
            ),
            TextButton.icon(
              onPressed: busy
                  ? null
                  : () => setState(() {
                      final copies = pages
                          .where((page) => selected.contains(page.id))
                          .map((page) => page.duplicate())
                          .toList();
                      pages.addAll(copies);
                    }),
              icon: const Icon(Icons.copy_all),
              label: const Text('Duplicate'),
            ),
            TextButton.icon(
              onPressed: busy
                  ? null
                  : () => setState(() {
                      pages.removeWhere((page) => selected.contains(page.id));
                      selected.clear();
                    }),
              icon: const Icon(Icons.delete_outline, color: AppColors.coral),
              label: const Text('Remove'),
            ),
            TextButton(
              onPressed: busy
                  ? null
                  : () => run(() async {
                      final path = await FileSanitizer.outputPath();
                      widget.operations.engine.blank(path);
                      pages.add(ComposerPage(path, 0));
                    }),
              child: const Text('Blank page'),
            ),
          ],
        ),
        const Padding(
          padding: EdgeInsets.symmetric(horizontal: 16),
          child: Text(
            'Tap to select. Hold and drag to reorder pages across documents.',
          ),
        ),
        Expanded(
          child: pages.isEmpty
              ? Center(
                  child: FilledButton.icon(
                    onPressed: busy ? null : add,
                    icon: const Icon(Icons.add_to_photos_outlined),
                    label: const Text('Add PDF documents'),
                  ),
                )
              : GridView.builder(
                  padding: const EdgeInsets.all(16),
                  gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
                    maxCrossAxisExtent: 180,
                    childAspectRatio: .68,
                    crossAxisSpacing: 12,
                    mainAxisSpacing: 12,
                  ),
                  itemCount: pages.length,
                  itemBuilder: (context, index) {
                    final page = pages[index];
                    page.preview ??= widget.operations.preview(
                      page.path,
                      page.page,
                    );
                    final tile = Card(
                      color: selected.contains(page.id)
                          ? AppColors.primary20
                          : Colors.white,
                      child: InkWell(
                        onTap: busy
                            ? null
                            : () => setState(() {
                                if (!selected.add(page.id)) {
                                  selected.remove(page.id);
                                }
                              }),
                        child: Column(
                          children: [
                            Expanded(
                              child: Padding(
                                padding: const EdgeInsets.all(8),
                                child: RotatedBox(
                                  quarterTurns: page.rotation ~/ 90,
                                  child: FutureBuilder(
                                    future: page.preview,
                                    builder: (context, snapshot) =>
                                        snapshot.connectionState ==
                                                ConnectionState.done &&
                                            snapshot.hasData
                                        ? Image.memory(
                                            snapshot.data!,
                                            fit: BoxFit.contain,
                                          )
                                        : Center(
                                            child: snapshot.hasError
                                                ? const Icon(
                                                    Icons.error_outline,
                                                  )
                                                : const CircularProgressIndicator(),
                                          ),
                                  ),
                                ),
                              ),
                            ),
                            Text(
                              'Page ${page.page + 1}',
                              style: const TextStyle(fontFamily: 'monospace'),
                            ),
                            Text(
                              'Position ${index + 1}',
                              style: const TextStyle(fontSize: 11),
                            ),
                            const SizedBox(height: 8),
                          ],
                        ),
                      ),
                    );
                    return DragTarget<String>(
                      onAcceptWithDetails: (details) =>
                          move(details.data, index),
                      builder: (context, candidates, rejected) =>
                          LongPressDraggable<String>(
                            data: page.id,
                            maxSimultaneousDrags: busy ? 0 : 1,
                            feedback: Material(
                              elevation: 8,
                              borderRadius: BorderRadius.circular(16),
                              child: SizedBox(
                                width: 130,
                                height: 180,
                                child: Center(
                                  child: Text(
                                    '${selected.contains(page.id) ? selected.length : 1} page(s)',
                                  ),
                                ),
                              ),
                            ),
                            child: Opacity(
                              opacity: candidates.isEmpty ? 1 : .5,
                              child: tile,
                            ),
                          ),
                    );
                  },
                ),
        ),
      ],
    ),
  );
  @override
  void dispose() {
    for (final page in pages) {
      page.preview = null;
    }
    super.dispose();
  }
}
