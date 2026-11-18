import 'dart:async';
import 'dart:collection';
import 'dart:ffi';
import 'dart:isolate';
import 'dart:math' as math;
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:image/image.dart' as img;
import '../../core/ffi/pdf_ffi_bindings.dart';

class TiledPage extends StatefulWidget {
  const TiledPage({
    super.key,
    required this.path,
    required this.page,
    required this.fallback,
    required this.controller,
  });
  final String path;
  final int page;
  final Uint8List fallback;
  final TransformationController controller;
  @override
  State<TiledPage> createState() => _TiledPageState();
}

class _TiledPageState extends State<TiledPage> {
  Timer? throttle;
  final cache = <String, Future<Uint8List>>{};
  @override
  void initState() {
    super.initState();
    widget.controller.addListener(changed);
  }

  void changed() {
    throttle?.cancel();
    throttle = Timer(const Duration(milliseconds: 100), () {
      if (mounted) setState(() {});
    });
  }

  @override
  void didUpdateWidget(covariant TiledPage old) {
    super.didUpdateWidget(old);
    if (old.path != widget.path || old.page != widget.page) cache.clear();
  }

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final w = constraints.maxWidth, h = constraints.maxHeight;
      final scale = widget.controller.value.getMaxScaleOnAxis();
      final dpr = MediaQuery.devicePixelRatioOf(context);
      final resolution = math.min(
        4,
        math.max(1, math.pow(2, (math.log(scale) / math.ln2).ceil()).toInt()),
      );
      final factor = math.min(dpr * resolution, math.sqrt(44900000 / (w * h)));
      final fw = (w * factor).ceil(), fh = (h * factor).ceil();
      final inverse = Matrix4.inverted(widget.controller.value);
      final topLeft = MatrixUtils.transformPoint(inverse, Offset.zero),
          bottomRight = MatrixUtils.transformPoint(inverse, Offset(w, h));
      final visible = Rect.fromPoints(
        topLeft,
        bottomRight,
      ).intersect(Rect.fromLTWH(0, 0, w, h));
      final tiles = <Widget>[];
      if (scale > 1.2 && !visible.isEmpty) {
        for (
          var y = math.max(0, (visible.top * factor / 512).floor() * 512);
          y < math.min(fh, visible.bottom * factor);
          y += 512
        ) {
          for (
            var x = math.max(0, (visible.left * factor / 512).floor() * 512);
            x < math.min(fw, visible.right * factor);
            x += 512
          ) {
            final tw = math.min(512, fw - x),
                th = math.min(512, fh - y),
                key = '${widget.path}:${widget.page}:$fw:$fh:$x:$y';
            final task = (
              path: widget.path,
              page: widget.page,
              fw: fw,
              fh: fh,
              x: x,
              y: y,
              w: tw,
              h: th,
            );
            final future = cache.putIfAbsent(key, () => requestTile(task));
            tiles.add(
              Positioned(
                left: x / factor,
                top: y / factor,
                width: tw / factor,
                height: th / factor,
                child: FutureBuilder<Uint8List>(
                  future: future,
                  builder: (context, snapshot) => snapshot.hasData
                      ? Image.memory(
                          snapshot.data!,
                          fit: BoxFit.fill,
                          gaplessPlayback: true,
                        )
                      : const SizedBox.shrink(),
                ),
              ),
            );
          }
        }
      }
      while (cache.length > 48) {
        cache.remove(cache.keys.first);
      }
      return Stack(
        fit: StackFit.expand,
        children: [
          Image.memory(
            widget.fallback,
            fit: BoxFit.fill,
            gaplessPlayback: true,
          ),
          ...tiles,
        ],
      );
    },
  );
  @override
  void dispose() {
    throttle?.cancel();
    widget.controller.removeListener(changed);
    cache.clear();
    super.dispose();
  }
}

Future<Uint8List> requestTile(
  ({String path, int page, int fw, int fh, int x, int y, int w, int h}) task,
) => _TileQueue.run(() => Isolate.run(() => _tile(task)));

class _TileQueue {
  static int active = 0;
  static final waiting = Queue<Completer<void>>();
  static Future<T> run<T>(Future<T> Function() action) async {
    if (active >= 2) {
      final signal = Completer<void>();
      waiting.add(signal);
      await signal.future;
    } else {
      active++;
    }
    try {
      return await action();
    } finally {
      if (waiting.isNotEmpty) {
        waiting.removeFirst().complete();
      } else {
        active--;
      }
    }
  }
}

Uint8List _tile(
  ({String path, int page, int fw, int fh, int x, int y, int w, int h}) task,
) {
  final native = PdfNative();
  final doc = native.open(task.path);
  Pointer<Uint8> pixels = nullptr;
  final free = native.library
      .lookupFunction<
        Void Function(Pointer<Void>),
        void Function(Pointer<Void>)
      >('pdf_free');
  try {
    final render = native.library
        .lookupFunction<
          Pointer<Uint8> Function(
            Pointer<Void>,
            Int32,
            Int32,
            Int32,
            Int32,
            Int32,
            Int32,
            Int32,
          ),
          Pointer<Uint8> Function(
            Pointer<Void>,
            int,
            int,
            int,
            int,
            int,
            int,
            int,
          )
        >('pdf_render_tile');
    pixels = render(
      doc,
      task.page,
      task.fw,
      task.fh,
      task.x,
      task.y,
      task.w,
      task.h,
    );
    if (pixels == nullptr) throw StateError('Tile rendering failed');
    final bytes = Uint8List.fromList(pixels.asTypedList(task.w * task.h * 4));
    return Uint8List.fromList(
      img.encodePng(
        img.Image.fromBytes(
          width: task.w,
          height: task.h,
          bytes: bytes.buffer,
          numChannels: 4,
          order: img.ChannelOrder.rgba,
        ),
      ),
    );
  } finally {
    if (pixels != nullptr) free(pixels.cast());
    native.close(doc);
  }
}
