import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:local_auth/local_auth.dart';
import 'package:flutter/services.dart';

class SecureVault {
  static const storage = FlutterSecureStorage(
    aOptions: AndroidOptions(encryptedSharedPreferences: true),
    iOptions: IOSOptions(
      accessibility: KeychainAccessibility.first_unlock_this_device,
    ),
  );
  static const channel = MethodChannel('pdf_suite/privacy');
  final LocalAuthentication auth = LocalAuthentication();
  Future<bool> get enabled async =>
      await storage.read(key: 'vault_enabled') == 'true';
  Future<bool> unlock() async {
    if (!await enabled) return true;
    return auth.authenticate(
      localizedReason: 'Unlock your private PDF vault',
      options: const AuthenticationOptions(
        biometricOnly: false,
        stickyAuth: true,
      ),
    );
  }

  Future<void> setEnabled(bool value) async {
    if (value &&
        !await auth.authenticate(
          localizedReason: 'Enable private vault protection',
          options: const AuthenticationOptions(biometricOnly: false),
        )) {
      return;
    }
    await storage.write(key: 'vault_enabled', value: value.toString());
  }

  static Future<void> protectScreen(bool sensitive) async =>
      channel.invokeMethod<void>('protectScreen', {'enabled': sensitive});
}
