import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

class ThemeController extends ChangeNotifier {
  ThemeController({FlutterSecureStorage? storage}) : _storage = storage ?? const FlutterSecureStorage();

  final FlutterSecureStorage _storage;
  ThemeMode mode = ThemeMode.system;
  String? _userId;

  Future<void> bindUser(String? userId) async {
    _userId = userId;
    if (userId == null) {
      mode = ThemeMode.system;
      notifyListeners();
      return;
    }
    try {
      final raw = await _storage.read(key: 'theme:$userId');
      mode = switch (raw) {
        'light' => ThemeMode.light,
        'dark' => ThemeMode.dark,
        _ => ThemeMode.system,
      };
    } catch (_) {
      mode = ThemeMode.system;
    }
    notifyListeners();
  }

  Future<void> setMode(ThemeMode value) async {
    mode = value;
    notifyListeners();
    final userId = _userId;
    if (userId == null) return;
    try {
      await _storage.write(
        key: 'theme:$userId',
        value: switch (value) {
          ThemeMode.light => 'light',
          ThemeMode.dark => 'dark',
          ThemeMode.system => 'system',
        },
      );
    } catch (_) {}
  }
}
