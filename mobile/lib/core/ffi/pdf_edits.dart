import 'dart:convert';
import 'dart:ffi';
import 'dart:typed_data';
import 'dart:ui' as ui;
import 'package:ffi/ffi.dart';
import 'pdf_ffi_bindings.dart';

extension PdfEdits on PdfNative {
  String metadata(String input) {
    final arena = Arena();
    Pointer<Utf8> result = nullptr;
    final free = library
        .lookupFunction<
          Void Function(Pointer<Void>),
          void Function(Pointer<Void>)
        >('pdf_free');
    try {
      final call = library
          .lookupFunction<
            Pointer<Utf8> Function(Pointer<Utf8>),
            Pointer<Utf8> Function(Pointer<Utf8>)
          >('pdf_metadata');
      result = call(input.toNativeUtf8(allocator: arena));
      if (result == nullptr) throw StateError('Metadata inspection failed');
      return result.toDartString();
    } finally {
      if (result != nullptr) free(result.cast());
      arena.releaseAll();
    }
  }

  ui.Size pageSize(Pointer<Void> doc, int index) {
    final arena = Arena();
    try {
      final width = arena<Double>();
      final height = arena<Double>();
      final call = library
          .lookupFunction<
            Int32 Function(
              Pointer<Void>,
              Int32,
              Pointer<Double>,
              Pointer<Double>,
            ),
            int Function(Pointer<Void>, int, Pointer<Double>, Pointer<Double>)
          >('pdf_page_size');
      if (call(doc, index, width, height) != 1) {
        throw StateError('Page dimensions unavailable');
      }
      return ui.Size(width.value, height.value);
    } finally {
      arena.releaseAll();
    }
  }

  ({Uint8List pixels, int width, int height}) pixels(
    Pointer<Void> doc,
    int index,
    int edge,
  ) {
    final arena = Arena();
    Pointer<Uint8> memory = nullptr;
    final free = library
        .lookupFunction<
          Void Function(Pointer<Void>),
          void Function(Pointer<Void>)
        >('pdf_free');
    try {
      final w = arena<Int32>(), h = arena<Int32>();
      final length = arena<Size>();
      final render = library
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
      memory = render(doc, index, edge, w, h, length);
      if (memory == nullptr) throw StateError('Page rendering failed');
      return (
        pixels: Uint8List.fromList(memory.asTypedList(length.value)),
        width: w.value,
        height: h.value,
      );
    } finally {
      if (memory != nullptr) free(memory.cast());
      arena.releaseAll();
    }
  }

  void scrub(String input, String output) {
    final arena = Arena();
    try {
      final call = library
          .lookupFunction<
            Int32 Function(Pointer<Utf8>, Pointer<Utf8>),
            int Function(Pointer<Utf8>, Pointer<Utf8>)
          >('pdf_scrub');
      if (call(
            input.toNativeUtf8(allocator: arena),
            output.toNativeUtf8(allocator: arena),
          ) !=
          1) {
        throw StateError('Metadata scrub failed');
      }
    } finally {
      arena.releaseAll();
    }
  }

  void rectangles(
    Pointer<Void> doc,
    String output,
    List<RedactionBox> boxes, {
    int? kind,
  }) {
    final arena = Arena();
    try {
      final memory = arena<NativeRect>(boxes.length);
      for (var i = 0; i < boxes.length; i++) {
        memory[i]
          ..page = boxes[i].page
          ..x0 = boxes[i].rect.left
          ..y0 = boxes[i].rect.top
          ..x1 = boxes[i].rect.right
          ..y1 = boxes[i].rect.bottom;
      }
      final path = output.toNativeUtf8(allocator: arena);
      final result = kind == null
          ? library.lookupFunction<
              Int32 Function(
                Pointer<Void>,
                Pointer<Utf8>,
                Pointer<NativeRect>,
                Int32,
              ),
              int Function(
                Pointer<Void>,
                Pointer<Utf8>,
                Pointer<NativeRect>,
                int,
              )
            >('pdf_crop')(doc, path, memory, boxes.length)
          : library.lookupFunction<
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
            >('pdf_markup')(doc, path, memory, boxes.length, kind);
      if (result != 1) throw StateError('Page editing failed');
    } finally {
      arena.releaseAll();
    }
  }

  void ink(Pointer<Void> doc, String output, int page, List<ui.Offset> points) {
    final arena = Arena();
    try {
      final xy = arena<Double>(points.length * 2);
      for (var i = 0; i < points.length; i++) {
        xy[i * 2] = points[i].dx;
        xy[i * 2 + 1] = points[i].dy;
      }
      final call = library
          .lookupFunction<
            Int32 Function(
              Pointer<Void>,
              Pointer<Utf8>,
              Int32,
              Pointer<Double>,
              Int32,
            ),
            int Function(
              Pointer<Void>,
              Pointer<Utf8>,
              int,
              Pointer<Double>,
              int,
            )
          >('pdf_ink');
      if (call(
            doc,
            output.toNativeUtf8(allocator: arena),
            page,
            xy,
            points.length,
          ) !=
          1) {
        throw StateError('Ink export failed');
      }
    } finally {
      arena.releaseAll();
    }
  }

  void writeText(
    Pointer<Void> doc,
    String output,
    int page,
    ui.Offset position,
    String text, {
    bool signature = false,
    double size = 14,
  }) {
    final arena = Arena();
    try {
      final units = text.codeUnits;
      final memory = arena<Uint16>(units.length + 1);
      memory.asTypedList(units.length + 1).fillRange(0, units.length + 1, 0);
      memory.asTypedList(units.length).setAll(0, units);
      final call = library
          .lookupFunction<
            Int32 Function(
              Pointer<Void>,
              Pointer<Utf8>,
              Int32,
              Double,
              Double,
              Pointer<Uint16>,
              Double,
              Int32,
            ),
            int Function(
              Pointer<Void>,
              Pointer<Utf8>,
              int,
              double,
              double,
              Pointer<Uint16>,
              double,
              int,
            )
          >('pdf_write_text');
      if (call(
            doc,
            output.toNativeUtf8(allocator: arena),
            page,
            position.dx,
            position.dy,
            memory,
            size,
            signature ? 1 : 0,
          ) !=
          1) {
        throw StateError('Text export failed');
      }
    } finally {
      arena.releaseAll();
    }
  }

  List<Map<String, dynamic>> fields(String input) {
    final arena = Arena();
    Pointer<Utf8> result = nullptr;
    final free = library
        .lookupFunction<
          Void Function(Pointer<Void>),
          void Function(Pointer<Void>)
        >('pdf_free');
    try {
      final call = library
          .lookupFunction<
            Pointer<Utf8> Function(Pointer<Utf8>),
            Pointer<Utf8> Function(Pointer<Utf8>)
          >('pdf_form_fields');
      result = call(input.toNativeUtf8(allocator: arena));
      if (result == nullptr) throw StateError('Form inspection failed');
      return (jsonDecode(result.toDartString()) as List)
          .cast<Map<String, dynamic>>();
    } finally {
      if (result != nullptr) free(result.cast());
      arena.releaseAll();
    }
  }

  void fillField(String input, String output, String name, String value) {
    final arena = Arena();
    try {
      final call = library
          .lookupFunction<
            Int32 Function(
              Pointer<Utf8>,
              Pointer<Utf8>,
              Pointer<Utf8>,
              Pointer<Utf8>,
            ),
            int Function(
              Pointer<Utf8>,
              Pointer<Utf8>,
              Pointer<Utf8>,
              Pointer<Utf8>,
            )
          >('pdf_fill_field');
      if (call(
            input.toNativeUtf8(allocator: arena),
            output.toNativeUtf8(allocator: arena),
            name.toNativeUtf8(allocator: arena),
            value.toNativeUtf8(allocator: arena),
          ) !=
          1) {
        throw StateError('Form update failed');
      }
    } finally {
      arena.releaseAll();
    }
  }
}
