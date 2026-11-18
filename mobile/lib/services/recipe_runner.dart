import 'dart:io';
import 'package:path/path.dart' as p;
import '../core/database/app_database.dart';
import '../core/security/file_sanitizer.dart';
import 'api_client.dart';
import 'document_scanner.dart';
import 'local_tools.dart';
import 'pdf_operations.dart';

const recipeSteps = [
  'Scan document',
  'Optimize streams',
  'Strip metadata',
  'Compress under 2 MB',
  'Cloud OCR',
  'Export PDF/A',
  'Burst pages',
];

class RecipeRunner {
  RecipeRunner(this.database, {this.api});
  final AppDatabase database;
  final ApiClient? api;
  Future<List<String>> run(
    List<String> steps,
    String? input,
    void Function(String) progress,
  ) async {
    if (steps.isEmpty) throw ArgumentError('Recipe has no steps');
    var path = input;
    var outputs = <String>[];
    for (var index = 0; index < steps.length; index++) {
      final step = steps[index];
      progress('${index + 1}/${steps.length}: $step');
      if (step == 'Scan document') {
        if (index != 0) throw StateError('Scan must be the first step');
        path = await DocumentScannerService().scan();
        if (path == null) throw StateError('Scan cancelled');
        continue;
      }
      if (path == null) throw StateError('Choose an input PDF');
      switch (step) {
        case 'Optimize streams':
          path = await PdfOperations().optimize(path);
        case 'Strip metadata':
          path = await PdfOperations().optimize(path, scrub: true);
        case 'Compress under 2 MB':
          path = await LocalTools().rasterCompress(
            path,
            150,
            80,
            targetBytes: 2000000,
          );
        case 'Cloud OCR':
        case 'Export PDF/A':
          if (api == null) throw StateError('Cloud service is not configured');
          String? job;
          try {
            job = await api!.upload(
              File(path),
              p.extension(path).substring(1),
              step == 'Cloud OCR' ? 'searchable_pdf' : 'pdfa',
              database: database,
            );
            var completed = false;
            await for (final event
                in api!.progress(job).timeout(const Duration(minutes: 5))) {
              progress('$step: ${event['progress'] ?? 0}%');
              if (event['state'] == 'done') {
                completed = true;
                break;
              }
              if (['failed', 'deleted'].contains(event['state']) ||
                  event.isEmpty) {
                throw StateError('Cloud step failed or expired');
              }
            }
            if (!completed) throw StateError('Cloud step did not complete');
            final info = await api!.request('GET', '/v1/jobs/$job');
            final output = File(await FileSanitizer.outputPath());
            await api!.download(info['download_url'] as String, output);
            path = output.path;
          } finally {
            if (job != null) {
              await api!.request('DELETE', '/v1/jobs/$job');
              await database.updateJob(job, 'deleted');
            }
          }
        case 'Burst pages':
          if (index != steps.length - 1) {
            throw StateError('Burst pages must be the final step');
          }
          outputs = await PdfOperations().split(path, 1);
        default:
          throw StateError('Unknown recipe step');
      }
    }
    if (outputs.isEmpty && path != null) outputs = [path];
    return outputs;
  }
}
