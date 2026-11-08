import 'package:flutter_secure_storage/flutter_secure_storage.dart';

abstract class TokenStore {
  Future<String?> read();
  Future<void> write(String? token);
}

class MemoryTokenStore implements TokenStore {
  String? value;

  @override
  Future<String?> read() async => value;

  @override
  Future<void> write(String? token) async {
    value = token;
  }
}

class SecureTokenStore implements TokenStore {
  SecureTokenStore({FlutterSecureStorage? storage}) : _storage = storage ?? const FlutterSecureStorage();

  final FlutterSecureStorage _storage;
  static const _key = 'access_token';

  @override
  Future<String?> read() async {
    try {
      return await _storage.read(key: _key);
    } catch (_) {
      return null;
    }
  }

  @override
  Future<void> write(String? token) async {
    try {
      if (token == null || token.isEmpty) {
        await _storage.delete(key: _key);
        return;
      }
      await _storage.write(key: _key, value: token);
    } catch (_) {}
  }
}
