import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

class BarberBookApi {
  BarberBookApi({String? baseUrl}) : baseUrl = baseUrl ?? _defaultBaseUrl;

  static const _configuredBaseUrl = String.fromEnvironment('API_BASE_URL');
  static String get _defaultBaseUrl {
    if (_configuredBaseUrl.isNotEmpty) return _configuredBaseUrl;
    // Android emulators reach the host machine through this special address.
    if (!kIsWeb && defaultTargetPlatform == TargetPlatform.android) {
      return 'http://10.0.2.2:8787';
    }
    return 'http://127.0.0.1:8787';
  }

  final String baseUrl;
  String? token;

  Future<Map<String, dynamic>> request(String path, {String method = 'GET', Map<String, dynamic>? data, bool authenticated = false}) async {
    final uri = Uri.parse('$baseUrl$path');
    final headers = <String, String>{'Content-Type': 'application/json'};
    if (authenticated && token != null) headers['Authorization'] = 'Bearer $token';
    late http.Response response;
    try {
      switch (method) {
        case 'POST':
          response = await http.post(uri, headers: headers, body: jsonEncode(data ?? {})).timeout(const Duration(seconds: 8));
          break;
        case 'PATCH':
          response = await http.patch(uri, headers: headers, body: jsonEncode(data ?? {})).timeout(const Duration(seconds: 8));
          break;
        default:
          response = await http.get(uri, headers: headers).timeout(const Duration(seconds: 8));
      }
    } on Exception catch (e) {
      throw Exception('Cannot reach the BarberBook server. Start it with: node api/server.mjs. ($e)');
    }
    final decoded = response.body.isEmpty ? <String, dynamic>{} : jsonDecode(response.body) as Map<String, dynamic>;
    if (response.statusCode < 200 || response.statusCode >= 300) throw Exception(decoded['error'] ?? 'Request failed (${response.statusCode}).');
    return decoded;
  }

  Future<Map<String, dynamic>> login(String email, String password) async {
    final result = await request('/auth/login', method: 'POST', data: {'email': email, 'password': password});
    token = result['token'] as String?;
    return result;
  }

  Future<Map<String, dynamic>> register({required String name, required String email, required String password, required String role, String? phone, String? shop, String? address}) =>
      request('/auth/register', method: 'POST', data: {'name': name, 'email': email, 'password': password, 'role': role, 'phone': phone, if (shop != null) 'shop': shop, if (address != null) 'address': address});

  Future<Map<String, dynamic>> get(String path) => request(path, authenticated: true);
  Future<Map<String, dynamic>> post(String path, Map<String, dynamic> data) => request(path, method: 'POST', data: data, authenticated: true);
  Future<Map<String, dynamic>> patch(String path, Map<String, dynamic> data) => request(path, method: 'PATCH', data: data, authenticated: true);
}
