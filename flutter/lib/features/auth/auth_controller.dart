import 'package:flutter/foundation.dart';

import '../../core/networking/api_client.dart';
import '../../core/networking/api_exception.dart';
import 'auth_gateway.dart';

class UserProfile {
  UserProfile({required this.id, required this.displayName, required this.timezone});

  final String id;
  final String displayName;
  final String timezone;

  factory UserProfile.fromJson(Map<String, dynamic> json) {
    return UserProfile(
      id: json['id'].toString(),
      displayName: (json['display_name'] ?? json['email'] ?? 'Learner').toString(),
      timezone: (json['timezone'] ?? 'UTC').toString(),
    );
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

  Future<void> signOut() async {
    await gateway.signOut();
    await api.tokens.write(null);
    user = null;
    notifyListeners();
  }
}
