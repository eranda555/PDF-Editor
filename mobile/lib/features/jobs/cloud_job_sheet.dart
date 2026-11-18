import 'dart:async';
import 'dart:io';
import 'dart:convert';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:share_plus/share_plus.dart';

import '../../core/security/file_sanitizer.dart';
import '../../core/theme/app_theme.dart';
import '../../services/api_client.dart';
import '../../services/background_transfers.dart';
import '../../services/local_tools.dart';
import 'package:uuid/uuid.dart';
import '../../core/database/app_database.dart';

class CloudJobSheet extends StatefulWidget {
  const CloudJobSheet({
    super.key,
    required this.api,
    required this.database,
    this.initialFormat = 'docx',
  });
  final String initialFormat;
  final ApiClient api;
  final AppDatabase database;
  @override
  State<CloudJobSheet> createState() => _CloudState();
}

class _CloudState extends State<CloudJobSheet> {
  late String format = widget.initialFormat;
  String? jobId;
  String state = 'Choose a document';
  double progress = 0;
  bool busy = false;
  bool consent = false;
  bool localResult = false;
  Map<String, dynamic>? report;
  Future<void> loadReport(String id) async {
    try {
      final info = await widget.api.request('GET', '/v1/jobs/$id');
      if (mounted) {
        setState(
          () => report = (info['report'] as Map?)?.cast<String, dynamic>(),
        );
      }
    } catch (_) {
      if (mounted) {
        setState(
          () => state =
              'Result ready; quality report unavailable. Reopen the job to retry.',
        );
      }
    }
  }

  int pdfaPart = 2;
  String language = 'eng';
  String presentationMode = 'editable';
  List<Map<String, dynamic>> savedJobs = [];
  @override
  void initState() {
    super.initState();
    reloadJobs();
  }

  Future<void> reloadJobs() async {
    final rows = await widget.database.jobs();
    if (mounted) setState(() => savedJobs = rows);
  }

  Future<void> resume(Map<String, dynamic> job) async {
    final id = job['id'] as String;
    try {
      if (job['state'] == 'uploading' &&
          await BackgroundTransfers.uploadCompleted(id)) {
        await widget.api.request(
          'POST',
          '/v1/jobs/dispatch',
          body: {'job_id': id},
        );
      }
      final info = await widget.api.request('GET', '/v1/jobs/$id');
      if (!mounted) return;
      await subscription?.cancel();
      setState(() {
        jobId = id;
        format =
            info['output_format'] as String? ??
            (jsonDecode(job['payload'] as String)['format'] as String);
        state = info['state'] as String;
        progress = (info['progress'] as num).toDouble() / 100;
        busy = !['done', 'failed', 'deleted'].contains(state);
      });
      if (busy) watch(id);
      if (state == 'done') loadReport(id);
    } catch (_) {
      if (mounted) {
        setState(
          () => state =
              'Job unavailable or expired. Try again if the transfer is still active.',
        );
      }
    }
  }

  void watch(String id) {
    subscription = widget.api
        .progress(id)
        .listen(
          (event) {
            final next = event['state'] as String? ?? 'Expired';
            if (next == 'done') loadReport(id);
            widget.database.updateJob(id, next);
            if (mounted) {
              setState(() {
                state = next;
                progress = ((event['progress'] as num?)?.toDouble() ?? 0) / 100;
                busy = !['done', 'failed', 'deleted', 'Expired'].contains(next);
              });
            }
          },
          onError: (Object error) {
            if (mounted) {
              setState(() {
                busy = false;
                state = 'Connection interrupted. Reopen this job to reconnect.';
              });
            }
          },
        );
  }

  StreamSubscription<Map<String, dynamic>>? subscription;
  Future<void> start() async {
    final result = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: format == 'pdf'
          ? [
              'pdf',
              'docx',
              'xlsx',
              'pptx',
              'doc',
              'xls',
              'ppt',
              'html',
              'md',
              'txt',
              'tex',
              'png',
              'jpg',
              'jpeg',
              'webp',
              'tif',
              'tiff',
            ]
          : ['pdf'],
    );
    if (result == null || result.files.single.path == null) return;
    setState(() {
      busy = true;
      localResult = false;
      report = null;
      state = 'Uploading';
    });
    try {
      final path = result.files.single.path!;
      final isImage = [
        '.png',
        '.jpg',
        '.jpeg',
        '.webp',
        '.tif',
        '.tiff',
      ].contains(p.extension(path).toLowerCase());
      if (isImage) {
        if (mounted) setState(() => localResult = true);
        final output = await LocalTools().imagesToPdf([path], 'A4', 18);
        await widget.database.addDocument(
          const Uuid().v4(),
          'Converted images.pdf',
          output,
        );
        if (mounted) {
          setState(() {
            busy = false;
            state = 'Processed on-device; no cloud upload was needed';
            progress = 1;
          });
        }
        await SharePlus.instance.share(ShareParams(files: [XFile(output)]));
        return;
      }
      final file = await FileSanitizer.importFile(path, image: isImage);
      final id = await widget.api.upload(
        file,
        p.extension(file.path).substring(1),
        format,
        database: widget.database,
        options: {
          'pdfa_part': pdfaPart,
          'ocr_language': language,
          'presentation_mode': presentationMode,
        },
      );
      if (!mounted) return;
      setState(() {
        jobId = id;
        state = 'Queued';
      });
      watch(id);
      await reloadJobs();
    } catch (_) {
      if (mounted) {
        setState(() {
          busy = false;
          state = 'Cloud request failed. Check service availability and quota.';
        });
      }
    }
  }

  Future<void> download() async {
    try {
      final info = await widget.api.request('GET', '/v1/jobs/$jobId');
      final extension = format == 'svg'
          ? 'zip'
          : ['pdfa', 'searchable_pdf', 'flattened_pdf'].contains(format)
          ? 'pdf'
          : format;
      final file = File(await FileSanitizer.outputPath(extension));
      await widget.api.download(info['download_url'] as String, file);
      await SharePlus.instance.share(ShareParams(files: [XFile(file.path)]));
    } catch (_) {
      if (mounted) setState(() => state = 'Download unavailable or expired');
    }
  }

  Future<void> delete() async {
    try {
      await widget.api.request('DELETE', '/v1/jobs/$jobId');
      await widget.database.updateJob(jobId!, 'deleted');
      await subscription?.cancel();
      if (mounted) {
        setState(() {
          state = 'deleted';
          busy = false;
        });
      }
    } catch (_) {
      if (mounted) {
        setState(() => state = 'Deletion could not be confirmed. Retry.');
      }
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Cloud conversion')),
    body: ListView(
      padding: const EdgeInsets.all(20),
      children: [
        ExecutionBadge(cloud: !localResult),
        const SizedBox(height: 20),
        const Text(
          'Cloud limits: 15 MB • 20 PDF pages • 15 jobs/hour. Files use encrypted transport and provider storage. The service can read files during conversion. AI extraction requires operator opt-in.',
        ),
        const SizedBox(height: 16),
        DropdownButtonFormField<String>(
          initialValue: format,
          decoration: const InputDecoration(labelText: 'Convert to'),
          items:
              [
                    'docx',
                    'txt',
                    'md',
                    'json',
                    'xml',
                    'xlsx',
                    'csv',
                    'pptx',
                    'svg',
                    'html',
                    'dxf',
                    'pdf',
                    'searchable_pdf',
                    'pdfa',
                    'flattened_pdf',
                    'epub',
                    'rtf',
                    'odt',
                    'doc',
                    'xls',
                    'ppt',
                    'mobi',
                    'azw3',
                    'dwg',
                  ]
                  .map(
                    (value) => DropdownMenuItem(
                      value: value,
                      child: Text(value.toUpperCase()),
                    ),
                  )
                  .toList(),
          onChanged: busy || jobId != null
              ? null
              : (value) => setState(() => format = value!),
        ),
        CheckboxListTile(
          value: consent,
          onChanged: busy
              ? null
              : (value) => setState(() => consent = value ?? false),
          title: const Text('Upload this document for cloud processing'),
          subtitle: const Text(
            'Expiry target: 1 hour. Actual removal depends on the purge service; download promptly.',
          ),
        ),
        if (format == 'pdfa' || format == 'searchable_pdf') ...[
          DropdownButtonFormField<int>(
            initialValue: pdfaPart,
            decoration: const InputDecoration(labelText: 'Archival profile'),
            items: [1, 2]
                .map(
                  (n) => DropdownMenuItem(value: n, child: Text('PDF/A-${n}b')),
                )
                .toList(),
            onChanged: busy ? null : (n) => setState(() => pdfaPart = n!),
          ),
          DropdownButtonFormField<String>(
            initialValue: language,
            decoration: const InputDecoration(labelText: 'OCR language'),
            items: [
              'eng',
              'eng+sin',
              'eng+tam',
              'sin',
              'tam',
            ].map((n) => DropdownMenuItem(value: n, child: Text(n))).toList(),
            onChanged: busy ? null : (n) => setState(() => language = n!),
          ),
        ],
        if (format == 'pptx')
          DropdownButtonFormField<String>(
            initialValue: presentationMode,
            decoration: const InputDecoration(labelText: 'Presentation output'),
            items: [
              'editable',
              'facsimile',
            ].map((n) => DropdownMenuItem(value: n, child: Text(n))).toList(),
            onChanged: busy
                ? null
                : (n) => setState(() => presentationMode = n!),
          ),
        FilledButton(
          onPressed: busy || !consent || jobId != null ? null : start,
          child: const Text('Choose file & convert'),
        ),
        const SizedBox(height: 24),
        Text(state),
        if (report != null)
          ExpansionTile(
            title: Text(
              (report!['visual_qa'] as Map?)?['flagged'] == true
                  ? 'Quality check: layout needs review'
                  : 'Conversion quality report',
            ),
            children: [
              SelectableText(
                const JsonEncoder.withIndent('  ').convert(report),
              ),
            ],
          ),
        if (jobId != null)
          SelectableText(
            jobId!,
            style: const TextStyle(fontFamily: 'monospace', fontSize: 11),
          ),
        const SizedBox(height: 12),
        LinearProgressIndicator(value: progress),
        if (state == 'done')
          FilledButton(
            onPressed: download,
            child: const Text('Download result'),
          ),
        if (jobId != null && state != 'deleted')
          TextButton.icon(
            onPressed: delete,
            icon: const Icon(Icons.delete_forever, color: AppColors.plum),
            label: const Text('Delete from cloud now'),
          ),
        if (!busy && jobId != null)
          TextButton(
            onPressed: () => setState(() {
              jobId = null;
              state = 'Choose a document';
              progress = 0;
            }),
            child: const Text('Start another conversion'),
          ),
        const SizedBox(height: 20),
        const Text('Recent cloud jobs'),
        for (final job in savedJobs)
          ListTile(
            title: Text(
              job['id'] as String,
              style: const TextStyle(fontSize: 11, fontFamily: 'monospace'),
            ),
            subtitle: Text(job['state'] as String),
            onTap: busy ? null : () => resume(job),
          ),
      ],
    ),
  );
  @override
  void dispose() {
    subscription?.cancel();
    super.dispose();
  }
}
