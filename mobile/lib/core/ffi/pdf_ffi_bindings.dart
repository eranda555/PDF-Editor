import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:ffi/ffi.dart';

final class NativeRect extends Struct {
  @Int32()
  external int page;
  @Double()
  external double x0;
  @Double()
  external double y0;
  @Double()
  external double x1;
  @Double()
  external double y1;
}

class RedactionBox {
  const RedactionBox(this.page, this.rect);
  final int page;
  final ui.Rect rect;
}

class PdfNative {
  PdfNative()
    : library = Platform.isIOS
          ? DynamicLibrary.process()
          : DynamicLibrary.open(
              Platform.isWindows
                  ? 'pdf_native_bridge.dll'
                  : Platform.isMacOS
                  ? 'libpdf_native_bridge.dylib'
                  : 'libpdf_native_bridge.so',
            );
  final DynamicLibrary library;
  late final _open = library
      .lookupFunction<
        Pointer<Void> Function(Pointer<Utf8>, Pointer<Utf8>),
        Pointer<Void> Function(Pointer<Utf8>, Pointer<Utf8>)
      >('pdf_open');
  late final close = library
      .lookupFunction<
        Void Function(Pointer<Void>),
        void Function(Pointer<Void>)
      >('pdf_close');
  late final count = library
      .lookupFunction<
        Int32 Function(Pointer<Void>),
        int Function(Pointer<Void>)
      >('pdf_page_count');
  late final _render = library
      .lookupFunction<
        Pointer<Uint8> Function(
          Pointer<Void>,
          Int32,
          Int32,
          Pointer<Int32>,
          Pointer<Int32>,
          Pointer<Size>,
        ),
        Pointer<Uint8> Function(
          Pointer<Void>,
          int,
          int,
          Pointer<Int32>,
          Pointer<Int32>,
          Pointer<Size>,
        )
      >('pdf_render');
  late final _text = library
      .lookupFunction<
        Pointer<Utf8> Function(Pointer<Void>, Int32),
        Pointer<Utf8> Function(Pointer<Void>, int)
      >('pdf_text');
  late final _free = library
      .lookupFunction<
        Void Function(Pointer<Void>),
        void Function(Pointer<Void>)
      >('pdf_free');
  late final _job = library
      .lookupFunction<
        Int32 Function(Pointer<Utf8>),
        int Function(Pointer<Utf8>)
      >('pdf_qpdf_job');
  late final _blank = library
      .lookupFunction<
        Int32 Function(Pointer<Utf8>, Double, Double),
        int Function(Pointer<Utf8>, double, double)
      >('pdf_blank');
  late final _redact = library
      .lookupFunction<
        Int32 Function(
          Pointer<Void>,
          Pointer<Utf8>,
          Pointer<NativeRect>,
          Int32,
          Int32,
        ),
        int Function(
          Pointer<Void>,
          Pointer<Utf8>,
          Pointer<NativeRect>,
          int,
          int,
        )
      >('pdf_redact');

  Pointer<Void> open(String path, {Uint8List? password}) {
    final input = path.toNativeUtf8();
    final secret = calloc<Uint8>((password?.length ?? 0) + 1);
    try {
      if (password != null) {
        secret.asTypedList(password.length).setAll(0, password);
      }
      final handle = _open(input, secret.cast());
      if (handle == nullptr) {
        throw StateError('Cannot open PDF. Check the file and password.');
      }
      return handle;
    } finally {
      secret
          .asTypedList((password?.length ?? 0) + 1)
          .fillRange(0, (password?.length ?? 0) + 1, 0);
      password?.fillRange(0, password.length, 0);
      calloc.free(secret);
      calloc.free(input);
    }
  }

  Future<Uint8List> thumbnail(
    Pointer<Void> document,
    int page, {
    int edge = 512,
  }) async {
    final width = calloc<Int32>();
    final height = calloc<Int32>();
    final size = calloc<Size>();
    Pointer<Uint8> pixels = nullptr;
    ui.Image? image;
    try {
      pixels = _render(document, page, edge, width, height, size);
      if (pixels == nullptr) throw StateError('PDF rendering failed');
      final buffer = await ui.ImmutableBuffer.fromUint8List(
        Uint8List.fromList(pixels.asTypedList(size.value)),
      );
      try {
        final descriptor = ui.ImageDescriptor.raw(
          buffer,
          width: width.value,
          height: height.value,
          pixelFormat: ui.PixelFormat.rgba8888,
        );
        try {
          final codec = await descriptor.instantiateCodec();
          try {
            image = (await codec.getNextFrame()).image;
          } finally {
            codec.dispose();
          }
        } finally {
          descriptor.dispose();
        }
      } finally {
        buffer.dispose();
      }
      final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
      if (bytes == null) throw StateError('PNG encoding failed');
      return Uint8List.fromList(bytes.buffer.asUint8List());
    } finally {
      image?.dispose();
      if (pixels != nullptr) _free(pixels.cast());
      calloc.free(width);
      calloc.free(height);
      calloc.free(size);
    }
  }

  String text(Pointer<Void> document, int page) {
    Pointer<Utf8> result = nullptr;
    try {
      result = _text(document, page);
      if (result == nullptr) throw StateError('Text extraction failed');
      return result.toDartString();
    } finally {
      if (result != nullptr) _free(result.cast());
    }
  }

  void job(Map<String, Object> options) {
    final bytes = utf8.encode(jsonEncode({'noWarn': '', ...options}));
    final native = calloc<Uint8>(bytes.length + 1);
    try {
      native.asTypedList(bytes.length).setAll(0, bytes);
      if (_job(native.cast()) != 1) throw StateError('PDF operation failed');
    } finally {
      native.asTypedList(bytes.length + 1).fillRange(0, bytes.length + 1, 0);
      bytes.fillRange(0, bytes.length, 0);
      calloc.free(native);
    }
  }

  void blank(String output) {
    final path = output.toNativeUtf8();
    try {
      if (_blank(path, 595.28, 841.89) != 1) {
        throw StateError('Blank page creation failed');
      }
    } finally {
      calloc.free(path);
    }
  }

  void redact(Pointer<Void> doc, String output, List<RedactionBox> boxes) {
    final path = output.toNativeUtf8();
    final memory = calloc<NativeRect>(boxes.isEmpty ? 1 : boxes.length);
    try {
      for (var i = 0; i < boxes.length; i++) {
        memory[i]
          ..page = boxes[i].page
          ..x0 = boxes[i].rect.left
          ..y0 = boxes[i].rect.top
          ..x1 = boxes[i].rect.right
          ..y1 = boxes[i].rect.bottom;
      }
      if (_redact(doc, path, memory, boxes.length, 150) != 1) {
        throw StateError('Raster redaction failed');
      }
    } finally {
      calloc.free(path);
      calloc.free(memory);
    }
  }
}
