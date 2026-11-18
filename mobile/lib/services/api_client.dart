import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart' as hash;
import '../core/security/device_identity.dart';

import '../core/security/secure_vault.dart';
import '../core/database/app_database.dart';
import 'background_transfers.dart';

class ApiClient {
  ApiClient(String endpoint) : base = Uri.parse(endpoint) {
    if (base.scheme != 'https' ||
        base.host.isEmpty ||
        base.userInfo.isNotEmpty) {
      throw ArgumentError('Cloud API must use HTTPS');
    }
  }
  final Uri base;
  final HttpClient client = HttpClient()
    ..connectionTimeout = const Duration(seconds: 20);
  Future<void>? refreshing;

  Future<Map<String, dynamic>> request(
    String method,
    String path, {
    Map<String, dynamic>? body,
    bool authenticated = true,
    bool retry = true,
  }) async {
    final request = await client.openUrl(method, base.resolve(path));
    if (authenticated) {
      final token = await SecureVault.storage.read(key: 'access_token');
      if (token == null) {
        await authenticate();
        request.headers.set(
          'Authorization',
          'Bearer ${await SecureVault.storage.read(key: 'access_token')}',
        );
      } else {
        request.headers.set('Authorization', 'Bearer $token');
      }
    }
    request.headers.contentType = ContentType.json;
    if (body != null) request.write(jsonEncode(body));
    final response = await request.close().timeout(const Duration(seconds: 30));
    final bytes = <int>[];
    await for (final chunk in response) {
      bytes.addAll(chunk);
      if (bytes.length > 1024 * 1024) {
        throw const HttpException('API response exceeded limit');
      }
    }
    if (response.statusCode == 401 && authenticated && retry) {
      await authenticate();
      return this.request(method, path, body: body, retry: false);
    }
    if (response.statusCode >= 400) {
      throw HttpException('Service returned HTTP ${response.statusCode}');
    }
    return bytes.isEmpty
        ? <String, dynamic>{}
        : jsonDecode(utf8.decode(bytes)) as Map<String, dynamic>;
  }

  Future<void> authenticate() async {
    if (refreshing != null) return refreshing;
    final future = _authenticate();
    refreshing = future;
    try {
      await future;
    } finally {
      refreshing = null;
    }
  }

  Future<void> _authenticate() async {
    await SecureVault.storage.delete(key: 'device_ed25519');
    final challenge = await request(
      'POST',
      '/v1/auth/challenge',
      authenticated: false,
    );
    final refresh = await SecureVault.storage.read(key: 'refresh_token');
    final public = await DeviceIdentity.publicKey();
    final message = refresh == null
        ? 'register\n${challenge['challenge_id']}\n${challenge['nonce']}\n$public'
        : 'refresh\n${challenge['challenge_id']}\n${challenge['nonce']}\n${hash.sha256.convert(utf8.encode(refresh))}';
    final signature = await DeviceIdentity.sign(message);
    Map<String, dynamic> result;
    try {
      result = await request(
        'POST',
        refresh == null ? '/v1/auth/register' : '/v1/auth/refresh',
        authenticated: false,
        body: {
          'challenge_id': challenge['challenge_id'],
          'signature': signature,
          if (refresh == null) 'algorithm': 'p256',
          if (refresh == null)
            'public_key': public
          else
            'refresh_token': refresh,
        },
      );
    } on HttpException {
      if (refresh == null) rethrow;
      await SecureVault.storage.delete(key: 'refresh_token');
      return _authenticate();
    }
    await SecureVault.storage.write(
      key: 'access_token',
      value: result['access_token'] as String,
    );
    await SecureVault.storage.write(
      key: 'refresh_token',
      value: result['refresh_token'] as String,
    );
  }

  Future<String> upload(
    File file,
    String extension,
    String outputFormat, {
    AppDatabase? database,
    Map<String, dynamic> options = const {},
  }) async {
    final size = await file.length();
    if (size > 15728640) throw StateError('Cloud limit is 15 MB');
    final digest = await hash.sha256.bind(file.openRead()).first;
    final init = await request(
      'POST',
      '/v1/jobs/init',
      body: {
        'extension': extension,
        'byte_length': size,
        'sha256': digest.toString(),
        'output_format': outputFormat,
        'options': options,
      },
    );
    final url = Uri.parse(init['upload_url'] as String);
    if (url.scheme != 'https') throw StateError('Upload URL requires HTTPS');
    final id = init['job_id'] as String;
    await database?.trackJob(id, 'uploading', {'format': outputFormat});
    await BackgroundTransfers.upload(url.toString(), file, id);
    await request('POST', '/v1/jobs/dispatch', body: {'job_id': id});
    await database?.updateJob(id, 'queued');
    return id;
  }

  Stream<Map<String, dynamic>> progress(String id) async* {
    var active = true;
    while (active) {
      final token = await SecureVault.storage.read(key: 'access_token');
      final request = await client.getUrl(base.resolve('/v1/jobs/$id/stream'));
      request.headers.set('Authorization', 'Bearer $token');
      final response = await request.close();
      if (response.statusCode == 401) {
        await response.drain<void>();
        await authenticate();
        continue;
      }
      if (response.statusCode != 200) {
        await response.drain<void>();
        throw StateError('Progress connection failed');
      }
      await for (final line
          in response.transform(utf8.decoder).transform(const LineSplitter())) {
        if (!line.startsWith('data: ')) continue;
        final value = jsonDecode(line.substring(6)) as Map<String, dynamic>;
        yield value;
        if (['done', 'failed', 'deleted'].contains(value['state']) ||
            value.isEmpty) {
          active = false;
          break;
        }
      }
      if (active) await Future<void>.delayed(const Duration(seconds: 2));
    }
  }

  Future<void> download(String signedUrl, File output) async {
    final uri = Uri.parse(signedUrl);
    if (uri.scheme != 'https') throw StateError('Download requires HTTPS');
    await BackgroundTransfers.download(signedUrl, output);
  }

  void close() => client.close(force: true);
}
