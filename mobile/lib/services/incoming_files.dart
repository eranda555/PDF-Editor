import 'dart:io';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:uuid/uuid.dart';
import '../core/database/app_database.dart';
import '../core/security/file_sanitizer.dart';
import 'local_tools.dart';

class IncomingFiles {
  IncomingFiles(this.database, this.changed);
  final AppDatabase database;
  final void Function() changed;
  static const channel = MethodChannel('pdf_suite/imports');
  bool draining = false;
  Future<void> start() async {
    channel.setMethodCallHandler((call) async {
      if (call.method == 'available') await drain();
    });
    await drain();
  }

  Future<void> drain() async {
    if (draining) return;
    draining = true;
    try {
      final files =
          await channel.invokeListMethod<dynamic>('takePending') ?? [];
      for (final raw in files) {
        final item = Map<String, dynamic>.from(raw as Map);
        final source = File(item['path'] as String);
        try {
          final extension = p.extension(source.path).toLowerCase();
          String output;
          if (extension == '.pdf') {
            output = (await FileSanitizer.importFile(source.path)).path;
          } else {
            output = await LocalTools().imagesToPdf([source.path], 'A4', 18);
          }
          await database.addDocument(
            const Uuid().v4(),
            FileSanitizer.displayName(item['name'] as String),
            output,
          );
        } finally {
          if (await source.exists()) await source.delete();
        }
      }
      changed();
    } finally {
      draining = false;
    }
  }

  void stop() {
    channel.setMethodCallHandler(null);
  }
}
