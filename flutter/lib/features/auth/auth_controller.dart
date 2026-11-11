import 'package:flutter/foundation.dart';

import '../../core/networking/api_client.dart';
import '../../core/networking/api_exception.dart';
import 'auth_gateway.dart';

class UserProfile {
  UserProfile({
    required this.id,
    required this.displayName,
    required this.timezone,
    this.email,
    this.username,
    this.fullName,
    this.photoUrl,
  });

  final String id;
  final String displayName;
  final String timezone;
  final String? email;
  final String? username;
  final String? fullName;
  final String? photoUrl;

  String get hudName {
    final user = username?.trim();
    if (user != null && user.isNotEmpty) return _titleCase(user);
    final full = fullName?.trim();
    if (full != null && full.isNotEmpty) return _titleCase(full);
    return _titleCase(displayName);
  }

  String get initial {
    final name = hudName.trim();
    if (name.isEmpty) return 'L';
    return name.substring(0, 1).toUpperCase();
  }

  factory UserProfile.fromJson(Map<String, dynamic> json) {
    return UserProfile(
      id: json['id'].toString(),
      displayName: (json['display_name'] ?? json['email'] ?? 'Learner').toString(),
      timezone: (json['timezone'] ?? 'UTC').toString(),
      email: json['email']?.toString(),
      username: json['username']?.toString(),
      fullName: json['full_name']?.toString(),
      photoUrl: json['photo_url']?.toString(),
    );
  }

  static String _titleCase(String value) {
    return value
        .split(RegExp(r'\s+'))
        .where((part) => part.isNotEmpty)
        .map((part) => '${part[0].toUpperCase()}${part.substring(1)}')
        .join(' ');
  }
}

class AuthController extends ChangeNotifier {
  AuthController({required this.api, required this.gateway});

  final ApiClient api;
  final AuthGateway gateway;
  UserProfile? user;
  bool loading = false;
  String? error;

  Future<void> signIn(String email, String password) async {
    loading = true;
    error = null;
    notifyListeners();
    try {
      await gateway.signIn(email, password);
      final idToken = await gateway.idToken();
      if (idToken == null) throw StateError('Firebase did not return an ID token');
      final response = await api.post('/auth/firebase', body: {'id_token': idToken}, skipAuth: true);
      await api.tokens.write(response['access_token'] as String);
      user = UserProfile.fromJson(Map<String, dynamic>.from(response['user'] as Map));
    } on ApiException catch (exc) {
      error = exc.message;
    } catch (exc) {
      error = exc.toString();
    } finally {
      loading = false;
      notifyListeners();
    }
  }

  Future<bool> refreshSession() async {
    try {
      final idToken = await gateway.idToken(forceRefresh: true);
      if (idToken == null) return false;
      final response = await api.post('/auth/firebase', body: {'id_token': idToken}, skipAuth: true);
      await api.tokens.write(response['access_token'] as String);
      return true;
    } catch (_) {
      user = null;
      await api.tokens.write(null);
      notifyListeners();
      return false;
    }
  }

  Future<void> loadMe() async {
    final token = await api.tokens.read();
    if (token == null) return;
    loading = true;
    notifyListeners();
    try {
      user = UserProfile.fromJson(Map<String, dynamic>.from(await api.get('/me') as Map));
      error = null;
    } on ApiException catch (exc) {
      if (exc.status == 401) {
        error = 'Session expired';
        user = null;
      } else {
        error = exc.message;
      }
    } finally {
      loading = false;
      notifyListeners();
    }
  }

  Future<void> updateProfile({
    String? username,
    String? fullName,
    String? photoUrl,
  }) async {
    final body = <String, dynamic>{};
    if (username != null) body['username'] = username;
    if (fullName != null) body['full_name'] = fullName;
    if (photoUrl != null) body['photo_url'] = photoUrl;
    if (body.isEmpty) return;
    final raw = Map<String, dynamic>.from(await api.patch('/me', body: body) as Map);
    user = UserProfile.fromJson(raw);
    notifyListeners();
  }

  Future<void> updateAccount({
    String? email,
    String? currentPassword,
    String? newPassword,
  }) async {
    final currentEmail = user?.email;
    if (email != null && email.trim().isNotEmpty && email.trim() != currentEmail) {
      if (currentEmail == null || currentPassword == null || currentPassword.isEmpty) {
        throw StateError('Current password is required to change email');
      }
      await gateway.reauthenticate(email: currentEmail, password: currentPassword);
      await gateway.updateEmail(email.trim());
    }
    if (newPassword != null && newPassword.isNotEmpty) {
      if (currentEmail == null || currentPassword == null || currentPassword.isEmpty) {
        throw StateError('Current password is required to change password');
      }
      await gateway.reauthenticate(email: currentEmail, password: currentPassword);
      await gateway.updatePassword(newPassword);
    }
  }

  Future<void> signOut() async {
    await gateway.signOut();
    await api.tokens.write(null);
    user = null;
    notifyListeners();
  }
}
