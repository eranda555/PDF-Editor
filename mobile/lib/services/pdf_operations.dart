import 'dart:io';
import 'dart:typed_data';
import 'dart:isolate';
import 'package:image/image.dart' as img;
import '../core/ffi/pdf_edits.dart';

import 'package:uuid/uuid.dart';

import '../core/ffi/pdf_ffi_bindings.dart';
import '../core/security/file_sanitizer.dart';

class ComposerPage {
  ComposerPage(this.path, this.page, {this.rotation = 0})
    : id = const Uuid().v4();
  final String id;
  final String path;
  final int page;
  int rotation;
  Future<Uint8List>? preview;
  ComposerPage duplicate() => ComposerPage(path, page, rotation: rotation);
}

class PdfOperations {
  PdfOperations() : engine = PdfNative();
  final PdfNative engine;
  int pageCount(String path) {
    final document = engine.open(path);
    try {
      return engine.count(document);
    } finally {
      engine.close(document);
    }
  }

  Future<Uint8List> preview(String path, int page, {int edge = 512}) async {
    return Isolate.run(
      () => renderPreview((path: path, page: page, edge: edge)),
    );
  }

  Future<String> compose(List<ComposerPage> pages) async {
    if (pages.isEmpty) throw StateError('Select at least one page');
    final output = await FileSanitizer.outputPath();
    try {
      engine.job({
        'empty': '',
        'outputFile': output,
        'pages': pages
            .map((page) => {'file': page.path, 'range': '${page.page + 1}'})
            .toList(),
        'rotate': [
          for (var i = 0; i < pages.length; i++)
            if (pages[i].rotation != 0) '+${pages[i].rotation}:${i + 1}',
        ],
        'objectStreams': 'generate',
      });
      return output;
    } catch (_) {
      if (await File(output).exists()) await File(output).delete();
      rethrow;
    }
  }

  Future<String> optimize(String input, {bool scrub = false}) async {
    final output = await FileSanitizer.outputPath();
    if (scrub) {
      await Isolate.run(() => PdfNative().scrub(input, output));
      return output;
    }
    final options = <String, Object>{
      'inputFile': input,
      'outputFile': output,
      'objectStreams': 'generate',
      'recompressFlate': '',
      'compressionLevel': '9',
    };
    await Isolate.run(() => PdfNative().job(options));
    return output;
  }

  Future<List<String>> split(String path, int every) async {
    if (every < 1) {
      throw const FormatException('Split interval must be positive');
    }
    final count = pageCount(path);
    final results = <String>[];
    for (var first = 0; first < count; first += every) {
      results.add(
        await compose([
          for (
            var index = first;
            index < first + every && index < count;
            index++
          )
            ComposerPage(path, index),
        ]),
      );
    }
    return results;
  }
}

Uint8List renderPreview(({String path, int page, int edge}) input) {
  final native = PdfNative();
  final doc = native.open(input.path);
  try {
    final rendered = native.pixels(doc, input.page, input.edge);
    final image = img.Image.fromBytes(
      width: rendered.width,
      height: rendered.height,
      bytes: rendered.pixels.buffer,
      numChannels: 4,
      order: img.ChannelOrder.rgba,
    );
    return Uint8List.fromList(img.encodePng(image));
  } finally {
    native.close(doc);
  }
}
