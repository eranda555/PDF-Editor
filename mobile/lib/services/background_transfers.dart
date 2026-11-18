import 'dart:io';
import 'package:background_downloader/background_downloader.dart';
import 'package:path/path.dart' as p;

abstract final class BackgroundTransfers {
  static Future<void> initialize() async {
    await FileDownloader().start(autoCleanDatabase: true);
  }

  static Future<void> upload(String url, File file, String id) async {
    final task = UploadTask(
      taskId: 'upload-$id',
      url: url,
      filename: p.basename(file.path),
      directory: 'documents',
      baseDirectory: BaseDirectory.applicationSupport,
      httpRequestMethod: 'PUT',
      post: 'binary',
      headers: {
        'Content-Type': 'application/octet-stream',
        'Content-Length': '${await file.length()}',
      },
      retries: 0,
      metaData: id,
    );
    final transfer = await FileDownloader().transfers.start(task);
    final result = await transfer.result;
    if (result.status != TaskStatus.complete) {
      throw StateError('Background upload failed or its signed URL expired');
    }
  }

  static Future<void> download(String url, File output) async {
    final task = DownloadTask(
      url: url,
      filename: p.basename(output.path),
      directory: 'documents',
      baseDirectory: BaseDirectory.applicationSupport,
      retries: 0,
    );
    final transfer = await FileDownloader().transfers.start(task);
    final result = await transfer.result;
    if (result.status != TaskStatus.complete) {
      throw StateError('Background download failed or its signed URL expired');
    }
    if (await output.length() > 50000000) {
      await output.delete();
      throw StateError('Output size exceeded');
    }
  }

  static Future<bool> uploadCompleted(String id) async {
    final record = await FileDownloader().database.recordForId('upload-$id');
    return record?.status == TaskStatus.complete;
  }
}
