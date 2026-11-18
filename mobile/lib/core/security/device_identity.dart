import 'package:flutter/services.dart';

abstract final class DeviceIdentity {
  static const channel = MethodChannel('pdf_suite/identity');
  static Future<String> publicKey() async {
    final value = await channel.invokeMethod<String>('publicKey');
    if (value == null) throw StateError('Hardware-backed identity unavailable');
    return value;
  }

  static Future<String> sign(String message) async {
    final value = await channel.invokeMethod<String>('sign', {
      'message': message,
    });
    if (value == null) throw StateError('Device signature failed');
    return value;
  }
}
