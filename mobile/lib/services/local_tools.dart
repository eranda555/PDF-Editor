import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';
import 'dart:ui' as ui;
import 'package:image/image.dart' as img;
import 'package:path/path.dart' as p;
import 'package:flutter_image_compress/flutter_image_compress.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import '../core/ffi/pdf_ffi_bindings.dart';
import '../core/ffi/pdf_edits.dart';
import '../core/security/file_sanitizer.dart';
import 'page_range.dart';
import 'pdf_operations.dart';

class LocalTools {
  Future<void> redactFile(
    String source,
    String output,
    List<RedactionBox> boxes,
  ) => Isolate.run(() => _redactBounded(source, output, boxes));
  Future<String> qpdf(Map<String, Object> options) async {
    final output = await FileSanitizer.outputPath();
    try {
      await Isolate.run(
        () => PdfNative().job({...options, 'outputFile': output}),
      );
      return output;
    } catch (_) {
      if (await File(output).exists()) await File(output).delete();
      rethrow;
    }
  }

  Future<String> encrypt(
    String path,
    String user,
    String owner, {
    bool print = true,
    bool copy = true,
  }) => qpdf({
    'inputFile': path,
    'encrypt': {
      'userPassword': user,
      'ownerPassword': owner,
      '256bit': {
        'print': print ? 'full' : 'none',
        'extract': copy ? 'y' : 'n',
        'modify': 'none',
        'accessibility': 'y',
      },
    },
  });
  Future<String> decrypt(String path, String password) =>
      qpdf({'inputFile': path, 'password': password, 'decrypt': ''});
  Future<List<String>> ranges(
    String path,
    String groups, {
    bool remove = false,
    int? every,
  }) async {
    final operations = PdfOperations();
    final count = operations.pageCount(path);
    if (every != null) return operations.split(path, every);
    final result = <String>[];
    for (final group in groups.split(';')) {
      final indices = parsePageRange(group, count);
      final pages = remove
          ? [
              for (var i = 0; i < count; i++)
                if (!indices.contains(i)) i,
            ]
          : indices;
      result.add(
        await operations.compose(
          pages.map((i) => ComposerPage(path, i)).toList(),
        ),
      );
    }
    return result;
  }

  Future<String> crop(String input, String ranges, double marginPoints) async {
    final output = await FileSanitizer.outputPath();
    await Isolate.run(() {
      final engine = PdfNative();
      final doc = engine.open(input);
      try {
        final boxes = <RedactionBox>[];
        for (final page in parsePageRange(ranges, engine.count(doc))) {
          final size = engine.pageSize(doc, page);
          if (marginPoints < 0 || marginPoints * 2 >= size.shortestSide) {
            throw const FormatException('Crop margin exceeds page dimensions');
          }
          boxes.add(
            RedactionBox(
              page,
              ui.Rect.fromLTRB(
                marginPoints / size.width,
                marginPoints / size.height,
                1 - marginPoints / size.width,
                1 - marginPoints / size.height,
              ),
            ),
          );
        }
        engine.rectangles(doc, output, boxes);
      } finally {
        engine.close(doc);
      }
    });
    return output;
  }

  Future<List<String>> exportImages(String path, String format, int dpi) async {
    if (![72, 150, 300].contains(dpi)) throw ArgumentError('Unsupported DPI');
    final count = PdfOperations().pageCount(path);
    final files = <String>[];
    for (var page = 0; page < count; page++) {
      final output = await FileSanitizer.outputPath(format);
      var bytes = await Isolate.run(
        () => _rasterImage((
          path: path,
          page: page,
          dpi: dpi,
          format: format,
          quality: 90,
        )),
      );
      if (format == 'webp') {
        bytes = await FlutterImageCompress.compressWithList(
          bytes,
          format: CompressFormat.webp,
          quality: 90,
          keepExif: false,
        );
      }
      await File(output).writeAsBytes(bytes, flush: true);
      files.add(output);
    }
    return files;
  }

  Future<String> rasterCompress(
    String path,
    int dpi,
    int quality, {
    int? targetBytes,
  }) async {
    var currentDpi = dpi;
    var currentQuality = quality;
    while (true) {
      final output = await FileSanitizer.outputPath();
      await Isolate.run(
        () => _rasterPdf(path, output, currentDpi, currentQuality),
      );
      if (targetBytes == null || await File(output).length() <= targetBytes) {
        return output;
      }
      await File(output).delete();
      if (currentQuality > 35) {
        currentQuality -= 15;
      } else if (currentDpi > 72) {
        currentDpi = currentDpi == 300 ? 150 : 72;
        currentQuality = 65;
      } else {
        throw StateError(
          'Cannot reach target size without exceeding the minimum quality limits',
        );
      }
    }
  }

  Future<String> imagesToPdf(
    List<String> paths,
    String paper,
    double margin,
  ) async {
    if (paths.isEmpty) throw ArgumentError('Choose at least one image');
    final output = await FileSanitizer.outputPath();
    await Isolate.run(() async {
      final document = pw.Document();
      var pages = 0;
      var totalEncoded = 0;
      for (final path in paths) {
        final source = File(path);
        if (await source.length() > 150 * 1024 * 1024) {
          throw StateError('Image input exceeds 150 MB');
        }
        final bytes = await source.readAsBytes();
        final info = img.findDecoderForData(bytes)?.startDecode(bytes);
        if (info == null ||
            info.width * info.height * info.numFrames > 45000000 ||
            info.numFrames > 100) {
          throw StateError('Image resource limits exceeded');
        }
        final decoded = img.decodeImage(bytes);
        if (decoded == null) throw StateError('Invalid image');
        for (final frame in decoded.frames) {
          if (++pages > 500) throw StateError('At most 500 image pages');
          final image = img.bakeOrientation(frame);
          final clean = img.Image(
            width: image.width,
            height: image.height,
            numChannels: 3,
          );
          img.fill(clean, color: img.ColorRgb8(255, 255, 255));
          img.compositeImage(clean, image);
          final Uint8List jpeg = Uint8List.fromList(
            img.encodeJpg(clean, quality: 90),
          );
          totalEncoded += jpeg.length;
          if (totalEncoded > 150 * 1024 * 1024) {
            throw StateError('Combined image export exceeds 150 MB');
          }
          final pageFormat = paper == 'Letter'
              ? PdfPageFormat.letter
              : paper == 'Fit to image'
              ? PdfPageFormat(
                  clean.width * .75 + margin * 2,
                  clean.height * .75 + margin * 2,
                )
              : PdfPageFormat.a4;
          if (margin < 0 ||
              margin * 2 >= pageFormat.width ||
              margin * 2 >= pageFormat.height) {
            throw ArgumentError('Invalid page margin');
          }
          document.addPage(
            pw.Page(
              pageFormat: pageFormat,
              margin: pw.EdgeInsets.all(margin),
              build: (context) => pw.Center(
                child: pw.Image(pw.MemoryImage(jpeg), fit: pw.BoxFit.contain),
              ),
            ),
          );
        }
      }
      await File(output).writeAsBytes(await document.save(), flush: true);
    });
    return output;
  }
}

Future<void> _redactBounded(
  String source,
  String output,
  List<RedactionBox> boxes,
) async {
  final base = Directory.systemTemp.absolute.path;
  final scratch = await Directory(base).createTemp('pdf-redaction-');
  if (!p.isWithin(base, scratch.absolute.path)) {
    throw StateError('Invalid redaction workspace');
  }
  try {
    final engine = PdfNative();
    final input = engine.open(source);
    int count;
    try {
      count = engine.count(input);
    } finally {
      engine.close(input);
    }
    final pages = <Map<String, String>>[];
    for (var index = 0; index < count; index++) {
      final single = p.join(scratch.path, 'input-$index.pdf'),
          clean = p.join(scratch.path, 'clean-$index.pdf');
      engine.job({
        'inputFile': source,
        'outputFile': single,
        'pages': [
          {'file': '.', 'range': '${index + 1}'},
        ],
      });
      final page = engine.open(single);
      try {
        engine.redact(
          page,
          clean,
          boxes
              .where((box) => box.page == index)
              .map((box) => RedactionBox(0, box.rect))
              .toList(),
        );
      } finally {
        engine.close(page);
      }
      await File(single).delete();
      pages.add({'file': clean, 'range': '1'});
    }
    engine.job({
      'empty': '',
      'outputFile': output,
      'pages': pages,
      'objectStreams': 'generate',
    });
  } catch (_) {
    if (await File(output).exists()) await File(output).delete();
    rethrow;
  } finally {
    await scratch.delete(recursive: true);
  }
}

Uint8List _rasterImage(
  ({String path, int page, int dpi, String format, int quality}) task,
) {
  final native = PdfNative();
  final doc = native.open(task.path);
  try {
    final size = native.pageSize(doc, task.page);
    final edge = (size.longestSide * task.dpi / 72).ceil();
    final rendered = native.pixels(doc, task.page, edge);
    final image = img.Image.fromBytes(
      width: rendered.width,
      height: rendered.height,
      bytes: rendered.pixels.buffer,
      numChannels: 4,
      order: img.ChannelOrder.rgba,
    );
    return Uint8List.fromList(
      task.format == 'jpg'
          ? img.encodeJpg(image, quality: task.quality)
          : task.format == 'tiff'
          ? img.encodeTiff(image)
          : img.encodePng(image),
    );
  } finally {
    native.close(doc);
  }
}

Future<void> _rasterPdf(
  String path,
  String output,
  int dpi,
  int quality,
) async {
  final native = PdfNative();
  final doc = native.open(path);
  final document = pw.Document();
  try {
    for (var page = 0; page < native.count(doc); page++) {
      final size = native.pageSize(doc, page);
      final bytes = _rasterImage((
        path: path,
        page: page,
        dpi: dpi,
        format: 'jpg',
        quality: quality,
      ));
      document.addPage(
        pw.Page(
          pageFormat: PdfPageFormat(size.width, size.height),
          margin: pw.EdgeInsets.zero,
          build: (context) =>
              pw.Image(pw.MemoryImage(bytes), fit: pw.BoxFit.fill),
        ),
      );
    }
    await File(output).writeAsBytes(await document.save(), flush: true);
  } finally {
    native.close(doc);
  }
}
