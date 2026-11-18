import 'dart:io';

import 'package:flutter/services.dart';
import 'package:google_mlkit_document_scanner/google_mlkit_document_scanner.dart';
import 'package:google_mlkit_text_recognition/google_mlkit_text_recognition.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;

import '../core/security/file_sanitizer.dart';

class DocumentScannerService {
  static const channel = MethodChannel('pdf_suite/scanner');
  Future<String?> scan() async {
    List<String> paths;
    if (Platform.isIOS) {
      paths = await channel.invokeListMethod<String>('scan') ?? [];
    } else {
      final scanner = DocumentScanner(
        options: DocumentScannerOptions(
          documentFormats: {DocumentFormat.jpeg},
          pageLimit: 20,
          mode: ScannerMode.full,
          isGalleryImport: true,
        ),
      );
      try {
        paths = (await scanner.scanDocument()).images ?? [];
      } finally {
        await scanner.close();
      }
    }
    if (paths.isEmpty) return null;
    final document = pw.Document();
    for (final path in paths) {
      final file = await FileSanitizer.importFile(path, image: true);
      final bytes = await file.readAsBytes();
      document.addPage(
        pw.Page(
          pageFormat: PdfPageFormat.a4,
          margin: const pw.EdgeInsets.all(18),
          build: (context) => pw.Center(
            child: pw.Image(pw.MemoryImage(bytes), fit: pw.BoxFit.contain),
          ),
        ),
      );
      await file.delete();
    }
    final output = File(await FileSanitizer.outputPath());
    await output.writeAsBytes(await document.save(), flush: true);
    return output.path;
  }

  Future<String> quickText(String path) async {
    if (Platform.isIOS) {
      return await channel.invokeMethod<String>('recognize', {'path': path}) ??
          '';
    }
    final recognizer = TextRecognizer(script: TextRecognitionScript.latin);
    try {
      return (await recognizer.processImage(
        InputImage.fromFilePath(path),
      )).text;
    } finally {
      await recognizer.close();
    }
  }
}
