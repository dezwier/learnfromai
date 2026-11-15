import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import 'api_exception.dart';
import 'token_storage.dart';

class ApiClient {
  ApiClient({required this.baseUrl, required this.tokens, this.refreshIdToken});

  final String baseUrl;
  final TokenStore tokens;
  Future<bool> Function()? refreshIdToken;
  Future<bool>? _refreshing;

  Future<dynamic> get(String path, {bool retry = true}) => _send('GET', path, retry: retry);

  Future<dynamic> post(String path, {Object? body, String? idempotencyKey, bool skipAuth = false}) {
    return _send('POST', path, body: body, idempotencyKey: idempotencyKey, skipAuth: skipAuth, retry: false);
  }

  Future<dynamic> patch(String path, {Object? body}) => _send('PATCH', path, body: body, retry: false);

  Future<dynamic> delete(String path) => _send('DELETE', path, retry: false);

  /// Authenticated GET that returns raw response bytes (e.g. PNG).
  Future<List<int>> getBytes(String path, {bool retry = true}) async {
    final attempts = retry ? 3 : 1;
    Object? lastError;
    for (var attempt = 1; attempt <= attempts; attempt++) {
      try {
        final response = await _dispatch('GET', path);
        if (response.statusCode == 401 && refreshIdToken != null) {
          final refreshed = await _refreshOnce();
          if (refreshed) {
            final again = await _dispatch('GET', path);
            if (again.statusCode >= 200 && again.statusCode < 300) return again.bodyBytes;
            throw ApiException(again.statusCode, 'HTTP_${again.statusCode}', 'Request failed');
          }
        }
        if (response.statusCode >= 200 && response.statusCode < 300) return response.bodyBytes;
        throw ApiException(response.statusCode, 'HTTP_${response.statusCode}', 'Request failed');
      } on ApiException {
        rethrow;
      } catch (error) {
        lastError = error;
        if (attempt == attempts) break;
        await Future<void>.delayed(Duration(milliseconds: 300 * attempt));
      }
    }
    throw ApiException(0, 'NETWORK', 'Network request failed: $lastError');
  }

  Future<dynamic> _send(
    String method,
    String path, {
    Object? body,
    String? idempotencyKey,
    bool skipAuth = false,
    bool retry = false,
    bool allowRefresh = true,
  }) async {
    final attempts = retry ? 3 : 1;
    Object? lastError;
    for (var attempt = 1; attempt <= attempts; attempt++) {
      try {
        final response = await _dispatch(method, path, body: body, idempotencyKey: idempotencyKey, skipAuth: skipAuth);
        if (response.statusCode == 401 && allowRefresh && !skipAuth && refreshIdToken != null) {
          final refreshed = await _refreshOnce();
          if (refreshed) {
            return await _send(method, path, body: body, idempotencyKey: idempotencyKey, skipAuth: skipAuth, retry: false, allowRefresh: false);
          }
        }
        return _decode(response);
      } on ApiException {
        rethrow;
      } catch (error) {
        lastError = error;
        if (attempt == attempts) break;
        await Future<void>.delayed(Duration(milliseconds: 300 * attempt));
      }
    }
    throw ApiException(0, 'NETWORK', 'Network request failed: $lastError');
  }

  Future<bool> _refreshOnce() {
    final existing = _refreshing;
    if (existing != null) return existing;
    final future = refreshIdToken!.call().whenComplete(() => _refreshing = null);
    _refreshing = future;
    return future;
  }

  Future<http.Response> _dispatch(String method, String path, {Object? body, String? idempotencyKey, bool skipAuth = false}) async {
    final headers = <String, String>{'Content-Type': 'application/json'};
    if (!skipAuth) {
      final token = await tokens.read();
      if (token != null && token.isNotEmpty) headers['Authorization'] = 'Bearer $token';
    }
    if (idempotencyKey != null) headers['Idempotency-Key'] = idempotencyKey;
    final uri = Uri.parse('$baseUrl/api/v1$path');
    switch (method) {
      case 'GET':
        return http.get(uri, headers: headers);
      case 'POST':
        return http.post(uri, headers: headers, body: jsonEncode(body ?? {}));
      case 'PATCH':
        return http.patch(uri, headers: headers, body: jsonEncode(body ?? {}));
      case 'DELETE':
        return http.delete(uri, headers: headers);
      default:
        throw ApiException(0, 'NETWORK', 'Unsupported method $method');
    }
  }

  dynamic _decode(http.Response response) {
    final dynamic payload = response.body.isEmpty ? null : jsonDecode(response.body);
    if (response.statusCode >= 200 && response.statusCode < 300) return payload;
    if (payload is Map<String, dynamic>) {
      throw ApiException(
        response.statusCode,
        payload['code']?.toString() ?? 'HTTP_${response.statusCode}',
        payload['message']?.toString() ?? 'Request failed',
        details: payload['details'] is Map<String, dynamic> ? payload['details'] as Map<String, dynamic> : const {},
      );
    }
    throw ApiException(response.statusCode, 'HTTP_${response.statusCode}', 'Request failed');
  }
}
