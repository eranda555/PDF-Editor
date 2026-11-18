import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:uuid/uuid.dart';

import '../../services/image_downsampler.dart';

class FileSanitizer {
  static String displayName(String name) => p
      .basename(name.replaceAll('\\', '/'))
      .replaceAll(RegExp(r'[^a-zA-Z0-9._-]'), '_');
  static Future<Directory> vaultDirectory() async {
    final root = await getApplicationSupportDirectory();
    return Directory(p.join(root.path, 'documents')).create(recursive: true);
  }

  static Future<File> importFile(String source, {bool image = false}) async {
    final original = File(source);
    if (await original.length() > 150 * 1024 * 1024) {
      throw StateError('Local import exceeds 150 MB');
    }
    final directory = await vaultDirectory();
    final extension = image
        ? '.jpg'
        : p.extension(displayName(source)).toLowerCase();
    if (!RegExp(r'^\.[a-z0-9]{1,6}$').hasMatch(extension)) {
      throw StateError('Invalid file extension');
    }
    final output = File(
      p.join(directory.path, '${const Uuid().v4()}$extension'),
    );
    if (image) {
      await output.writeAsBytes(
        await ImageDownsampler.sanitize(await original.readAsBytes()),
        flush: true,
      );
    } else {
      await original.copy(output.path);
    }
    return output;
  }

  static Future<String> outputPath([String extension = 'pdf']) async =>
      p.join((await vaultDirectory()).path, '${const Uuid().v4()}.$extension');
}
