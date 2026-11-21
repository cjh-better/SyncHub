import 'package:flutter/services.dart';

/// OS-backed credential storage wrapper (`synchub/secure` MethodChannel).
///
/// Backed by Windows Credential Manager (`CredWriteW` / `CredReadW`), macOS
/// Keychain (`SecItemAdd` / `SecItemCopyMatching`), and Android Keystore
/// (`EncryptedSharedPreferences` / AES-GCM Keystore) in the native runners.
///
/// In headless CLI unit tests where the platform channel or `ServicesBinding`
/// is unavailable, all operations degrade gracefully (`read` -> `null`,
/// `write` / `delete` -> `false`) so `AppConfig` continues to work seamlessly
/// with `config.json` while scrubbing plaintext secrets in real app builds once
/// `write` returns `true`.
class SecureStore {
  static const MethodChannel _defaultChannel = MethodChannel('synchub/secure');

  static const String keyToken = 'token';
  static const String keyPrivateKey = 'private_key';
  static const String keyHubPassword = 'hub_password';
  static const String keyClipPassword = 'clip_password';

  /// Override hook for unit tests; defaults to `MethodChannel('synchub/secure')`.
  static MethodChannel channel = _defaultChannel;

  const SecureStore._();

  /// Reads a secret by [key], returning `null` if not found or if the native
  /// secure store plugin is unavailable.
  static Future<String?> read(String key) async {
    if (key.isEmpty) return null;
    try {
      final value = await channel.invokeMethod<String>('read', <String, dynamic>{'key': key});
      if (value == null || value.isEmpty) return null;
      return value;
    } on MissingPluginException {
      return null;
    } on PlatformException {
      return null;
    } catch (_) {
      // Handles uninitialized ServicesBinding in pure Dart CLI tests.
      return null;
    }
  }

  /// Writes [value] under [key] into OS secure storage.
  ///
  /// Returns `true` strictly when the native channel confirms persistence, so
  /// callers only scrub plaintext `token` / `private_key` from `config.json`
  /// after secure storage has succeeded.
  static Future<bool> write(String key, String value) async {
    if (key.isEmpty) return false;
    try {
      final ok = await channel.invokeMethod<dynamic>(
        'write',
        <String, dynamic>{'key': key, 'value': value},
      );
      return ok == true;
    } on MissingPluginException {
      return false;
    } on PlatformException {
      return false;
    } catch (_) {
      return false;
    }
  }

  /// Deletes [key] from OS secure storage.
  static Future<bool> delete(String key) async {
    if (key.isEmpty) return false;
    try {
      final ok = await channel.invokeMethod<dynamic>('delete', <String, dynamic>{'key': key});
      return ok == true;
    } on MissingPluginException {
      return false;
    } on PlatformException {
      return false;
    } catch (_) {
      return false;
    }
  }

  /// Hydrates `token` and `private_key` into [json] when loaded from disk.
  ///
  /// If `config.json` has scrubbed (`""`) values, restores them from OS secure
  /// storage. If `config.json` came from a pre-S11 install with plaintext
  /// secrets, opportunistically migrates them into OS secure storage and
  /// returns `true` when `config.json` can be re-saved in scrubbed form.
  static Future<bool> hydrateConfigJson(Map<String, dynamic> json) async {
    var canScrubDisk = false;

    final diskToken = (json[keyToken] as String?) ?? '';
    if (diskToken.isEmpty) {
      final stored = await read(keyToken);
      if (stored != null && stored.isNotEmpty) {
        json[keyToken] = stored;
      }
    } else {
      if (await write(keyToken, diskToken)) {
        canScrubDisk = true;
      }
    }

    final diskPriv = (json[keyPrivateKey] as String?) ?? '';
    if (diskPriv.isEmpty) {
      final stored = await read(keyPrivateKey);
      if (stored != null && stored.isNotEmpty) {
        json[keyPrivateKey] = stored;
      }
    } else {
      if (await write(keyPrivateKey, diskPriv)) {
        canScrubDisk = true;
      }
    }

    return canScrubDisk;
  }

  /// Stores `token` and `private_key` in OS secure storage and returns a JSON
  /// map ready for writing to `config.json`.
  ///
  /// Plaintext fields are scrubbed (`""`) ONLY when `write` returns `true`; in
  /// headless CLI tests where `write` returns `false`, the returned map keeps
  /// the values intact so `AppConfig.load` continues to work.
  static Future<Map<String, dynamic>> scrubConfigJson(Map<String, dynamic> json) async {
    final copy = Map<String, dynamic>.from(json);

    final tok = (copy[keyToken] as String?) ?? '';
    if (tok.isNotEmpty && await write(keyToken, tok)) {
      copy[keyToken] = '';
    }

    final priv = (copy[keyPrivateKey] as String?) ?? '';
    if (priv.isNotEmpty && await write(keyPrivateKey, priv)) {
      copy[keyPrivateKey] = '';
    }

    return copy;
  }

  /// Clears all known credentials from OS secure storage (e.g. on sign-out).
  static Future<void> clearAll() async {
    await Future.wait(<Future<bool>>[
      delete(keyToken),
      delete(keyPrivateKey),
      delete(keyHubPassword),
      delete(keyClipPassword),
    ]);
  }
}
