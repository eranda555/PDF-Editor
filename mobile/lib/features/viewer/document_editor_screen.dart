import 'dart:io';
import 'dart:convert';
import 'dart:isolate';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:share_plus/share_plus.dart';
import '../../core/ffi/pdf_ffi_bindings.dart';
import '../../core/ffi/pdf_edits.dart';
import '../../core/security/file_sanitizer.dart';
import '../../core/security/secure_vault.dart';
import '../../core/theme/app_theme.dart';
import '../../services/pdf_operations.dart';
import '../../services/local_tools.dart';
import 'tiled_page.dart';

enum EditMode {
  view,
  redact,
  highlight,
  underline,
  strike,
  ink,
  text,
  signature,
  crop,
}

class PdfViewerScreen extends StatefulWidget {
  const PdfViewerScreen({
    super.key,
    required this.path,
    required this.operations,
  });
  final String path;
  final PdfOperations operations;
  @override
  State<PdfViewerScreen> createState() => _EditorState();
}

class _EditorState extends State<PdfViewerScreen> {
  final transform = TransformationController();
  List<Offset>? lastInk;
  late String path;
  late int count;
  int page = 0;
  bool busy = false;
  EditMode mode = EditMode.view;
  final history = <String>[];
  final redactions = <RedactionBox>[];
  final stroke = <Offset>[];
  Offset? start;
  Rect? draft;
  late Future<Uint8List> preview;
  @override
  void initState() {
    super.initState();
    path = widget.path;
    count = widget.operations.pageCount(path);
    refresh();
    SecureVault.protectScreen(true);
  }

  void refresh() {
    transform.value = Matrix4.identity();
    preview = widget.operations.preview(path, page, edge: 2000);
  }

  Future<void> guard(Future<void> Function() action) async {
    if (busy) return;
    setState(() => busy = true);
    try {
      await action();
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
              'PDF operation failed. Check the document and selected field.',
            ),
          ),
        );
      }
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> apply(Future<void> Function(String, String) operation) async {
    final input = path;
    final output = await FileSanitizer.outputPath();
    try {
      await operation(input, output);
      if (!mounted) return;
      setState(() {
        history.add(path);
        path = output;
        draft = null;
        stroke.clear();
        refresh();
      });
    } catch (_) {
      if (await File(output).exists()) await File(output).delete();
      rethrow;
    }
  }

  Future<String?> input(String title, {String initial = ''}) async {
    final controller = TextEditingController(text: initial);
    try {
      return await showDialog<String>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text(title),
          content: TextField(
            controller: controller,
            maxLength: 4000,
            decoration: const InputDecoration(labelText: 'Text'),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, controller.text),
              child: const Text('Apply'),
            ),
          ],
        ),
      );
    } finally {
      controller.dispose();
    }
  }

  Future<void> textSearch() async {
    final inputPath = path;
    final query = await input('Search all pages');
    if (query == null || query.isEmpty) return;
    await guard(() async {
      final results = await Isolate.run(() {
        final engine = PdfNative();
        final doc = engine.open(inputPath);
        final hits = <Map<String, dynamic>>[];
        try {
          for (var i = 0; i < engine.count(doc); i++) {
            final text = engine.text(doc, i);
            if (text.toLowerCase().contains(query.toLowerCase())) {
              hits.add({'page': i, 'text': text});
            }
          }
          return hits;
        } finally {
          engine.close(doc);
        }
      });
      if (!mounted) return;
      await showModalBottomSheet<void>(
        context: context,
        isScrollControlled: true,
        builder: (context) => DraggableScrollableSheet(
          expand: false,
          initialChildSize: .75,
          builder: (context, controller) => ListView(
            controller: controller,
            padding: const EdgeInsets.all(20),
            children: [
              Text('${results.length} matching pages'),
              for (final hit in results)
                ListTile(
                  title: Text('Page ${(hit['page'] as int) + 1}'),
                  subtitle: SelectableText.rich(
                    TextSpan(
                      children: _highlight(hit['text'] as String, query),
                    ),
                  ),
                  onTap: () {
                    Navigator.pop(context);
                    setState(() {
                      page = hit['page'] as int;
                      refresh();
                    });
                  },
                ),
            ],
          ),
        ),
      );
    });
  }

  List<TextSpan> _highlight(String text, String query) {
    final spans = <TextSpan>[];
    var position = 0;
    final lower = text.toLowerCase();
    while (true) {
      final index = lower.indexOf(query.toLowerCase(), position);
      if (index < 0) {
        spans.add(TextSpan(text: text.substring(position)));
        break;
      }
      spans.add(TextSpan(text: text.substring(position, index)));
      spans.add(
        TextSpan(
          text: text.substring(index, index + query.length),
          style: const TextStyle(
            backgroundColor: AppColors.primary20,
            fontWeight: FontWeight.bold,
          ),
        ),
      );
      position = index + query.length;
    }
    return spans;
  }

  Future<void> form() async {
    final current = path;
    final fields = await Isolate.run(() => PdfNative().fields(current));
    if (!mounted) return;
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (context) => DraggableScrollableSheet(
        expand: false,
        builder: (context, controller) => ListView(
          controller: controller,
          children: [
            const ListTile(
              title: Text('Interactive form fields'),
              subtitle: Text(
                'Text, choice and checkbox fields. Certificate signatures require a signing identity.',
              ),
            ),
            if (fields.isEmpty)
              const ListTile(title: Text('No editable AcroForm fields found')),
            for (final field in fields)
              ListTile(
                title: Text(field['name'] as String),
                subtitle: Text(field['value'] as String),
                enabled: field['type'] != '/Sig',
                onTap: () {
                  Navigator.pop(context);
                  editField(field);
                },
              ),
          ],
        ),
      ),
    );
  }

  Future<void> editField(Map<String, dynamic> field) async {
    final options = (field['options'] as List).cast<String>();
    final value = options.isEmpty
        ? await input(
            'Value for ${field['name']}',
            initial: field['value'] as String,
          )
        : await showDialog<String>(
            context: context,
            builder: (context) => SimpleDialog(
              title: Text(field['name'] as String),
              children: options
                  .map(
                    (option) => SimpleDialogOption(
                      onPressed: () => Navigator.pop(context, option),
                      child: Text(option),
                    ),
                  )
                  .toList(),
            ),
          );
    if (value == null) return;
    await guard(
      () => apply((source, destination) async {
        final temporary = await FileSanitizer.outputPath();
        try {
          await Isolate.run(() {
            final engine = PdfNative();
            engine.fillField(source, temporary, field['name'] as String, value);
            engine.job({
              'inputFile': temporary,
              'outputFile': destination,
              'generateAppearances': '',
            });
          });
        } finally {
          if (await File(temporary).exists()) await File(temporary).delete();
        }
      }),
    );
  }

  Future<void> placeText(Offset position) async {
    if (mode == EditMode.signature) {
      final saved = await SecureVault.storage.read(
        key: 'handwritten_signature',
      );
      if (saved != null && mounted) {
        final choice = await showModalBottomSheet<String>(
          context: context,
          builder: (context) => SafeArea(
            child: Wrap(
              children: [
                ListTile(
                  title: const Text('Use saved handwriting'),
                  onTap: () => Navigator.pop(context, 'ink'),
                ),
                ListTile(
                  title: const Text('Type a signature'),
                  onTap: () => Navigator.pop(context, 'typed'),
                ),
              ],
            ),
          ),
        );
        if (choice == null) return;
        if (choice == 'ink') {
          final normalized = (jsonDecode(saved) as List)
              .map(
                (point) => Offset(
                  (point[0] as num).toDouble(),
                  (point[1] as num).toDouble(),
                ),
              )
              .toList();
          final width = (1 - position.dx).clamp(0, .30),
              height = (1 - position.dy).clamp(0, .12);
          final target = page;
          final points = normalized
              .map(
                (point) => Offset(
                  position.dx + point.dx * width,
                  position.dy + point.dy * height,
                ),
              )
              .toList();
          await guard(
            () => apply(
              (source, destination) => Isolate.run(() {
                final engine = PdfNative();
                final doc = engine.open(source);
                try {
                  engine.ink(doc, destination, target, points);
                } finally {
                  engine.close(doc);
                }
              }),
            ),
          );
          return;
        }
      }
    }
    String initial = '';
    if (mode == EditMode.signature) {
      initial = await SecureVault.storage.read(key: 'typed_signature') ?? '';
    }
    if (!mounted) return;
    final text = await input(
      mode == EditMode.signature ? 'Typed signature' : 'Insert text',
      initial: initial,
    );
    if (text == null || text.isEmpty) return;
    final signature = mode == EditMode.signature;
    final targetPage = page;
    if (signature) {
      await SecureVault.storage.write(key: 'typed_signature', value: text);
    }
    await guard(
      () => apply(
        (source, destination) => Isolate.run(() {
          final engine = PdfNative();
          final doc = engine.open(source);
          try {
            engine.writeText(
              doc,
              destination,
              targetPage,
              position,
              text,
              signature: signature,
              size: signature ? 24 : 14,
            );
          } finally {
            engine.close(doc);
          }
        }),
      ),
    );
  }

  Future<void> finishGesture(Size size) async {
    final targetPage = page;
    final selectedMode = mode;
    if (mode == EditMode.crop && redactions.any((box) => box.page == page)) {
      setState(() => draft = null);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Export the redacted copy before cropping this page.'),
        ),
      );
      return;
    }
    if (mode == EditMode.ink) {
      final points = List<Offset>.of(stroke);
      if (points.length < 2) return;
      lastInk = points;
      await guard(
        () => apply(
          (source, destination) => Isolate.run(() {
            final engine = PdfNative();
            final doc = engine.open(source);
            try {
              engine.ink(doc, destination, targetPage, points);
            } finally {
              engine.close(doc);
            }
          }),
        ),
      );
      return;
    }
    final drawn = draft;
    if (drawn == null || drawn.width < 4 || drawn.height < 4) return;
    final rect = Rect.fromLTRB(
      (drawn.left / size.width).clamp(0, 1),
      (drawn.top / size.height).clamp(0, 1),
      (drawn.right / size.width).clamp(0, 1),
      (drawn.bottom / size.height).clamp(0, 1),
    );
    if (mode == EditMode.redact) {
      setState(() {
        redactions.add(RedactionBox(page, rect));
        draft = null;
      });
      return;
    }
    await guard(
      () => apply(
        (source, destination) => Isolate.run(() {
          final engine = PdfNative();
          final doc = engine.open(source);
          try {
            engine.rectangles(
              doc,
              destination,
              [RedactionBox(targetPage, rect)],
              kind: selectedMode == EditMode.crop
                  ? null
                  : selectedMode == EditMode.highlight
                  ? 9
                  : selectedMode == EditMode.underline
                  ? 10
                  : 12,
            );
          } finally {
            engine.close(doc);
          }
        }),
      ),
    );
  }

  Future<void> save() => guard(() async {
    var output = path;
    if (redactions.isNotEmpty) {
      output = await FileSanitizer.outputPath();
      final source = path;
      final target = output;
      final boxes = List<RedactionBox>.of(redactions);
      await LocalTools().redactFile(source, target, boxes);
    }
    await SharePlus.instance.share(
      ShareParams(
        files: [XFile(output)],
        text: redactions.isEmpty ? 'Edited PDF' : 'Rasterized redacted PDF',
      ),
    );
  });
  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: Text('Page ${page + 1} / $count'),
      actions: [
        IconButton(
          onPressed: busy ? null : textSearch,
          tooltip: 'Search and select text',
          icon: const Icon(Icons.search),
        ),
        IconButton(
          onPressed: busy ? null : () => guard(form),
          tooltip: 'Fill forms',
          icon: const Icon(Icons.list_alt),
        ),
        IconButton(
          onPressed: busy
              ? null
              : () {
                  setState(() {
                    if (redactions.isNotEmpty) {
                      redactions.removeLast();
                    } else if (history.isNotEmpty) {
                      path = history.removeLast();
                      refresh();
                    }
                  });
                },
          tooltip: 'Undo',
          icon: const Icon(Icons.undo),
        ),
      ],
    ),
    body: Column(
      children: [
        const ExecutionBadge(),
        if (lastInk != null)
          TextButton.icon(
            onPressed: busy
                ? null
                : () async {
                    final points = lastInk!;
                    final xs = points.map((point) => point.dx).toList()..sort();
                    final ys = points.map((point) => point.dy).toList()..sort();
                    final width = (xs.last - xs.first).clamp(.001, 1),
                        height = (ys.last - ys.first).clamp(.001, 1);
                    await SecureVault.storage.write(
                      key: 'handwritten_signature',
                      value: jsonEncode(
                        points
                            .map(
                              (point) => [
                                (point.dx - xs.first) / width,
                                (point.dy - ys.first) / height,
                              ],
                            )
                            .toList(),
                      ),
                    );
                    if (context.mounted) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(
                          content: Text('Handwriting saved in secure storage.'),
                        ),
                      );
                    }
                  },
            icon: const Icon(Icons.draw),
            label: const Text('Save last ink stroke as signature'),
          ),
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: Row(
            children: [
              for (final value in EditMode.values)
                Padding(
                  padding: const EdgeInsets.all(3),
                  child: ChoiceChip(
                    label: Text(value.name),
                    selected: mode == value,
                    onSelected: busy
                        ? null
                        : (_) => setState(() {
                            mode = value;
                            draft = null;
                            stroke.clear();
                          }),
                  ),
                ),
            ],
          ),
        ),
        if (mode == EditMode.redact)
          const Padding(
            padding: EdgeInsets.all(8),
            child: Text(
              'Draw over sensitive content. Export removes underlying text by rebuilding pages as pixels. Original remains separate.',
            ),
          ),
        if (mode == EditMode.crop)
          const Padding(
            padding: EdgeInsets.all(8),
            child: Text(
              'Draw the area to retain. Cropping does not erase hidden content.',
            ),
          ),
        if (mode == EditMode.text || mode == EditMode.signature)
          const Text(
            'Tap where the text should start. Use ink for a handwritten signature.',
          ),
        if (busy) const LinearProgressIndicator(),
        Expanded(
          child: FutureBuilder<Uint8List>(
            future: preview,
            builder: (context, snapshot) {
              if (snapshot.connectionState != ConnectionState.done ||
                  !snapshot.hasData) {
                return Center(
                  child: snapshot.hasError
                      ? const Text('Rendering failed')
                      : const CircularProgressIndicator(),
                );
              }
              final png = ByteData.sublistView(snapshot.data!);
              return Center(
                child: AspectRatio(
                  aspectRatio: png.getUint32(16) / png.getUint32(20),
                  child: LayoutBuilder(
                    builder: (context, constraints) => InteractiveViewer(
                      transformationController: transform,
                      panEnabled: mode == EditMode.view,
                      scaleEnabled: mode == EditMode.view,
                      maxScale: 5,
                      child: GestureDetector(
                        onTapUp:
                            mode == EditMode.text || mode == EditMode.signature
                            ? (event) => placeText(
                                Offset(
                                  (event.localPosition.dx /
                                          constraints.maxWidth)
                                      .clamp(0, 1),
                                  (event.localPosition.dy /
                                          constraints.maxHeight)
                                      .clamp(0, 1),
                                ),
                              )
                            : null,
                        onPanStart:
                            mode == EditMode.view ||
                                mode == EditMode.text ||
                                mode == EditMode.signature
                            ? null
                            : (event) => setState(() {
                                start = event.localPosition;
                                stroke.clear();
                              }),
                        onPanUpdate:
                            mode == EditMode.view ||
                                mode == EditMode.text ||
                                mode == EditMode.signature
                            ? null
                            : (event) => setState(() {
                                draft = Rect.fromPoints(
                                  start!,
                                  event.localPosition,
                                );
                                if (mode == EditMode.ink) {
                                  stroke.add(
                                    Offset(
                                      (event.localPosition.dx /
                                              constraints.maxWidth)
                                          .clamp(0, 1),
                                      (event.localPosition.dy /
                                              constraints.maxHeight)
                                          .clamp(0, 1),
                                    ),
                                  );
                                }
                              }),
                        onPanEnd:
                            mode == EditMode.view ||
                                mode == EditMode.text ||
                                mode == EditMode.signature
                            ? null
                            : (_) => finishGesture(constraints.biggest),
                        child: SizedBox(
                          width: constraints.maxWidth,
                          height: constraints.maxHeight,
                          child: Stack(
                            fit: StackFit.expand,
                            children: [
                              TiledPage(
                                path: path,
                                page: page,
                                fallback: snapshot.data!,
                                controller: transform,
                              ),
                              CustomPaint(
                                painter: _EditsPainter(
                                  redactions
                                      .where((box) => box.page == page)
                                      .map((box) => box.rect)
                                      .toList(),
                                  mode == EditMode.ink ? null : draft,
                                  List.of(stroke),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              );
            },
          ),
        ),
        SafeArea(
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
            children: [
              IconButton(
                onPressed: busy || page == 0
                    ? null
                    : () => setState(() {
                        page--;
                        refresh();
                      }),
                icon: const Icon(Icons.chevron_left),
              ),
              FilledButton.icon(
                onPressed: busy ? null : save,
                icon: const Icon(Icons.ios_share),
                label: const Text('Export copy'),
              ),
              IconButton(
                onPressed: busy || page == count - 1
                    ? null
                    : () => setState(() {
                        page++;
                        refresh();
                      }),
                icon: const Icon(Icons.chevron_right),
              ),
            ],
          ),
        ),
      ],
    ),
  );
  @override
  void dispose() {
    transform.dispose();
    SecureVault.protectScreen(false);
    super.dispose();
  }
}

class _EditsPainter extends CustomPainter {
  _EditsPainter(this.boxes, this.draft, this.points);
  final List<Rect> boxes;
  final Rect? draft;
  final List<Offset> points;
  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()..color = Colors.black;
    for (final rect in boxes) {
      canvas.drawRect(
        Rect.fromLTRB(
          rect.left * size.width,
          rect.top * size.height,
          rect.right * size.width,
          rect.bottom * size.height,
        ),
        paint,
      );
    }
    if (draft != null) canvas.drawRect(draft!, paint..color = Colors.black26);
    paint
      ..color = AppColors.charcoal
      ..strokeWidth = 2
      ..strokeCap = StrokeCap.round;
    for (var i = 1; i < points.length; i++) {
      canvas.drawLine(
        Offset(points[i - 1].dx * size.width, points[i - 1].dy * size.height),
        Offset(points[i].dx * size.width, points[i].dy * size.height),
        paint,
      );
    }
  }

  @override
  bool shouldRepaint(covariant _EditsPainter oldDelegate) => true;
}
