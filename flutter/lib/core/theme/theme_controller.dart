import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

class ThemeController extends ChangeNotifier {
  ThemeController({
    ThemeMode? initialMode,
    FlutterSecureStorage? storage,
  })  : _storage = storage ?? const FlutterSecureStorage(),
        mode = initialMode ?? ThemeMode.system,
        _ready = initialMode != null;

  static const _lastKey = 'theme:last';

  final FlutterSecureStorage _storage;
  ThemeMode mode;
  String? _userId;
  var _ready = false;

  bool get ready => _ready;

  /// Read last chosen mode before [runApp], so the first frame matches dark/light.
  static Future<ThemeMode> readLastMode([FlutterSecureStorage? storage]) async {
    final store = storage ?? const FlutterSecureStorage();
    try {
      return _parseStatic(await store.read(key: _lastKey)) ?? ThemeMode.system;
    } catch (_) {
      return ThemeMode.system;
    }
  }

  /// Resolve [mode] against the platform brightness (for splash before MaterialApp).
  static bool isDark(ThemeMode mode, Brightness platform) => switch (mode) {
        ThemeMode.light => false,
        ThemeMode.dark => true,
        ThemeMode.system => platform == Brightness.dark,
      };

  /// Restore the last chosen mode before auth, so splash matches dark/light.
  Future<void> restoreLastMode() async {
    try {
      final raw = await _storage.read(key: _lastKey);
      mode = _parse(raw) ?? ThemeMode.system;
    } catch (_) {
      mode = ThemeMode.system;
    }
    _ready = true;
    notifyListeners();
  }

  Future<void> bindUser(String? userId) async {
    _userId = userId;
    if (userId == null) {
      // Keep last mode for signed-out / splash — do not force system.
      notifyListeners();
      return;
    }
    try {
      final raw = await _storage.read(key: 'theme:$userId');
      mode = _parse(raw) ?? mode;
      await _storage.write(key: _lastKey, value: _encode(mode));
    } catch (_) {}
    notifyListeners();
  }

  Future<void> setMode(ThemeMode value) async {
    mode = value;
    notifyListeners();
    try {
      await _storage.write(key: _lastKey, value: _encode(value));
    } catch (_) {}
    final userId = _userId;
    if (userId == null) return;
    try {
      await _storage.write(key: 'theme:$userId', value: _encode(value));
    } catch (_) {}
  }

  ThemeMode? _parse(String? raw) => _parseStatic(raw);

  static ThemeMode? _parseStatic(String? raw) => switch (raw) {
        'light' => ThemeMode.light,
        'dark' => ThemeMode.dark,
        'system' => ThemeMode.system,
        _ => null,
      };

  String _encode(ThemeMode value) => switch (value) {
        ThemeMode.light => 'light',
        ThemeMode.dark => 'dark',
        ThemeMode.system => 'system',
      };
}
