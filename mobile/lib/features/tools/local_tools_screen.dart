import 'dart:io';
import 'dart:isolate';
import 'dart:convert';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:share_plus/share_plus.dart';
import 'package:uuid/uuid.dart';
import '../../core/database/app_database.dart';
import '../../core/security/file_sanitizer.dart';
import '../../core/theme/app_theme.dart';
import '../../services/local_tools.dart';
import '../../services/pdf_operations.dart';
import '../../services/document_scanner.dart';
import '../../core/ffi/pdf_ffi_bindings.dart';
import '../../core/ffi/pdf_edits.dart';

class LocalToolsScreen extends StatefulWidget {
  const LocalToolsScreen({
    super.key,
    required this.database,
    this.initialTool = 'Extract pages',
    this.initialFormat = 'png',
  });
  final String initialTool, initialFormat;
  final AppDatabase database;
  @override
  State<LocalToolsScreen> createState() => _ToolsState();
}

class _ToolsState extends State<LocalToolsScreen> {
  final ranges = TextEditingController(text: '1-end');
  final password = TextEditingController();
  final owner = TextEditingController();
  final interval = TextEditingController(text: '1');
  final margin = TextEditingController(text: '18');
  late String tool = widget.initialTool;
  late String format = widget.initialFormat;
  String paper = 'A4';
  int dpi = 150;
  double quality = 80;
  bool busy = false, printing = true, copying = true;
  String status = '';
  static const tools = [
    'Extract pages',
    'Remove pages',
    'Split by ranges',
    'Split every N pages',
    'Encrypt PDF',
    'Decrypt PDF',
    'Crop margins',
    'Strip metadata',
    'View metadata',
    'Compress losslessly',
    'Compress images',
    'PDF to images',
    'Images to PDF',
    'Quick image OCR',
  ];
  Future<void> execute() async {
    final isImages = tool == 'Images to PDF' || tool == 'Quick image OCR';
    final selection = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: isImages
          ? ['png', 'jpg', 'jpeg', 'webp', 'tif', 'tiff']
          : ['pdf'],
      allowMultiple: tool == 'Images to PDF',
    );
    if (selection == null || !mounted) return;
    setState(() {
      busy = true;
      status = 'Processing on this device';
    });
    try {
      final service = LocalTools();
      final paths = selection.paths.whereType<String>().toList();
      final input = isImages
          ? paths.first
          : (await FileSanitizer.importFile(paths.first)).path;
      final outputs = <String>[];
      switch (tool) {
        case 'Extract pages':
        case 'Split by ranges':
          outputs.addAll(await service.ranges(input, ranges.text));
        case 'Remove pages':
          outputs.addAll(
            await service.ranges(input, ranges.text, remove: true),
          );
        case 'Split every N pages':
          outputs.addAll(
            await service.ranges(input, '', every: int.parse(interval.text)),
          );
        case 'Encrypt PDF':
          if (owner.text.length < 8) {
            throw const FormatException(
              'Owner password needs at least 8 characters',
            );
          }
          outputs.add(
            await service.encrypt(
              input,
              password.text,
              owner.text,
              print: printing,
              copy: copying,
            ),
          );
        case 'Decrypt PDF':
          outputs.add(await service.decrypt(input, password.text));
        case 'Crop margins':
          outputs.add(
            await service.crop(input, ranges.text, double.parse(margin.text)),
          );
        case 'Strip metadata':
          outputs.add(await PdfOperations().optimize(input, scrub: true));
        case 'View metadata':
          final metadata = await Isolate.run(() => PdfNative().metadata(input));
          final file = File(await FileSanitizer.outputPath('json'));
          await file.writeAsString(
            const JsonEncoder.withIndent('  ').convert(jsonDecode(metadata)),
            flush: true,
          );
          outputs.add(file.path);
        case 'Compress losslessly':
          outputs.add(await PdfOperations().optimize(input));
        case 'Compress images':
          outputs.add(
            await service.rasterCompress(input, dpi, quality.round()),
          );
        case 'PDF to images':
          outputs.addAll(await service.exportImages(input, format, dpi));
        case 'Images to PDF':
          outputs.add(
            await service.imagesToPdf(paths, paper, double.parse(margin.text)),
          );
        case 'Quick image OCR':
          final sanitized = await FileSanitizer.importFile(input, image: true);
          final text = await DocumentScannerService().quickText(sanitized.path);
          await sanitized.delete();
          final output = File(await FileSanitizer.outputPath('txt'));
          await output.writeAsString(text, flush: true);
          outputs.add(output.path);
      }
      for (final path in outputs) {
        if (path.endsWith('.pdf')) {
          await widget.database.addDocument(
            const Uuid().v4(),
            '$tool.pdf',
            path,
          );
        }
      }
      if (mounted) {
        setState(() => status = 'Completed: ${outputs.length} file(s)');
      }
      await SharePlus.instance.share(
        ShareParams(files: outputs.map(XFile.new).toList()),
      );
    } catch (error) {
      if (mounted) {
        setState(
          () => status = error is FormatException
              ? error.message
              : 'Operation failed. Verify the file, password and selected options.',
        );
      }
    } finally {
      password.clear();
      owner.clear();
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Offline PDF tools')),
    body: ListView(
      padding: const EdgeInsets.all(20),
      children: [
        const ExecutionBadge(),
        const SizedBox(height: 16),
        DropdownButtonFormField<String>(
          initialValue: tool,
          items: tools
              .map((name) => DropdownMenuItem(value: name, child: Text(name)))
              .toList(),
          onChanged: busy ? null : (value) => setState(() => tool = value!),
        ),
        const SizedBox(height: 16),
        if ([
          'Extract pages',
          'Remove pages',
          'Split by ranges',
          'Crop margins',
        ].contains(tool))
          TextField(
            controller: ranges,
            decoration: InputDecoration(
              labelText: tool == 'Split by ranges'
                  ? 'Groups separated by ; e.g. 1-3;4-end'
                  : 'Pages: 1-3,5,8-end',
            ),
          ),
        if (tool == 'Split every N pages')
          TextField(
            controller: interval,
            keyboardType: TextInputType.number,
            decoration: const InputDecoration(
              labelText: 'Pages per output file',
            ),
          ),
        if (tool == 'Encrypt PDF' || tool == 'Decrypt PDF')
          TextField(
            controller: password,
            obscureText: true,
            enableSuggestions: false,
            autocorrect: false,
            decoration: const InputDecoration(
              labelText: 'Document open password',
            ),
          ),
        if (tool == 'Encrypt PDF') ...[
          const SizedBox(height: 12),
          TextField(
            controller: owner,
            obscureText: true,
            enableSuggestions: false,
            autocorrect: false,
            decoration: const InputDecoration(
              labelText: 'Owner password (8+ characters)',
            ),
          ),
          SwitchListTile(
            title: const Text('Allow printing'),
            value: printing,
            onChanged: (value) => setState(() => printing = value),
          ),
          SwitchListTile(
            title: const Text('Allow text extraction'),
            value: copying,
            onChanged: (value) => setState(() => copying = value),
          ),
          const Text(
            'PDF permissions depend on reader enforcement. Passwords are not saved.',
          ),
        ],
        if (tool == 'Crop margins' || tool == 'Images to PDF')
          TextField(
            controller: margin,
            keyboardType: TextInputType.number,
            decoration: const InputDecoration(
              labelText: 'Margin in PDF points (72 points = 1 inch)',
            ),
          ),
        if (tool == 'Crop margins')
          const Text(
            'Cropping hides content outside the crop box. Use redaction to permanently remove sensitive content.',
          ),
        if (tool == 'Compress images' || tool == 'PDF to images')
          DropdownButtonFormField<int>(
            initialValue: dpi,
            items: [72, 150, 300]
                .map((n) => DropdownMenuItem(value: n, child: Text('$n DPI')))
                .toList(),
            onChanged: (n) => setState(() => dpi = n!),
          ),
        if (tool == 'Compress images') ...[
          Text('JPEG quality: ${quality.round()}'),
          Slider(
            value: quality,
            min: 30,
            max: 100,
            divisions: 70,
            onChanged: (n) => setState(() => quality = n),
          ),
          const Text(
            'Image compression rebuilds pages as pixels. Searchable text, forms and digital signatures are removed.',
          ),
        ],
        if (tool == 'PDF to images')
          DropdownButtonFormField<String>(
            initialValue: format,
            items: ['png', 'jpg', 'webp', 'tiff']
                .map(
                  (n) =>
                      DropdownMenuItem(value: n, child: Text(n.toUpperCase())),
                )
                .toList(),
            onChanged: (n) => setState(() => format = n!),
          ),
        if (tool == 'Images to PDF')
          DropdownButtonFormField<String>(
            initialValue: paper,
            items: [
              'A4',
              'Letter',
              'Fit to image',
            ].map((n) => DropdownMenuItem(value: n, child: Text(n))).toList(),
            onChanged: (n) => setState(() => paper = n!),
          ),
        const SizedBox(height: 24),
        FilledButton.icon(
          onPressed: busy ? null : execute,
          icon: const Icon(Icons.file_open_outlined),
          label: const Text('Choose file & process'),
        ),
        if (busy) const LinearProgressIndicator(),
        const SizedBox(height: 16),
        Text(status),
      ],
    ),
  );
  @override
  void dispose() {
    for (final controller in [ranges, password, owner, interval, margin]) {
      controller.dispose();
    }
    super.dispose();
  }
}
