import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

class ApiException implements Exception {
  ApiException(this.message, [this.status, this.data]);
  final String message;
  final int? status;
  final Map? data;
  @override
  String toString() => message;
}

/// Sesi login + alamat server API (disimpan di HP).
class Session {
  Session._();
  static final Session I = Session._();

  String baseUrl = 'https://194.233.84.97:5443';
  String? token;
  Map<String, dynamic>? user;
  String? printerMac;
  String? printerName;
  String? rememberedUser;

  String get userName => (user?['name'] ?? user?['userCode'] ?? '').toString();
  String get userCode => (user?['userCode'] ?? '').toString();

  Future<void> load() async {
    final p = await SharedPreferences.getInstance();
    baseUrl = p.getString('baseUrl') ?? baseUrl;
    printerMac = p.getString('printerMac');
    printerName = p.getString('printerName');
    rememberedUser = p.getString('rememberedUser');
  }

  Future<void> saveBaseUrl(String url) async {
    baseUrl = url.trim().replaceAll(RegExp(r'/+$'), '');
    final p = await SharedPreferences.getInstance();
    await p.setString('baseUrl', baseUrl);
  }

  Future<void> savePrinter(String mac, String name) async {
    printerMac = mac;
    printerName = name;
    final p = await SharedPreferences.getInstance();
    await p.setString('printerMac', mac);
    await p.setString('printerName', name);
  }

  Future<void> saveRememberedUser(String? code) async {
    rememberedUser = code;
    final p = await SharedPreferences.getInstance();
    if (code == null) {
      await p.remove('rememberedUser');
    } else {
      await p.setString('rememberedUser', code);
    }
  }

  void logout() {
    token = null;
    user = null;
  }
}

/// Nomor build aplikasi ini (diisi CI lewat --dart-define=BUILD_NUMBER). 0 = build lokal.
const int kBuildNumber = int.fromEnvironment('BUILD_NUMBER', defaultValue: 0);

/// Klien REST ke GudangAtm.Api.
class Api {
  static const _timeout = Duration(seconds: 20);

  static Uri _uri(String path, [Map<String, String?>? query]) {
    final q = <String, String>{};
    query?.forEach((k, v) {
      if (v != null && v.isNotEmpty) q[k] = v;
    });
    return Uri.parse('${Session.I.baseUrl}$path').replace(queryParameters: q.isEmpty ? null : q);
  }

  static Map<String, String> get _headers => {
        'Content-Type': 'application/json',
        if (Session.I.token != null) 'Authorization': 'Bearer ${Session.I.token}',
      };

  static dynamic _decode(http.Response r) {
    dynamic body;
    try {
      body = r.body.isEmpty ? null : jsonDecode(utf8.decode(r.bodyBytes));
    } catch (_) {
      body = null;
    }
    if (r.statusCode >= 200 && r.statusCode < 300) return body;
    String msg = 'Server error ${r.statusCode}';
    if (body is Map && body['message'] != null) msg = body['message'].toString();
    if (r.statusCode == 401 && Session.I.token != null) msg = 'Sesi habis, silakan login ulang';
    throw ApiException(msg, r.statusCode, body is Map ? body : null);
  }

  static Future<dynamic> get(String path, [Map<String, String?>? query]) async {
    try {
      final r = await http.get(_uri(path, query), headers: _headers).timeout(_timeout);
      return _decode(r);
    } on ApiException {
      rethrow;
    } on TimeoutException {
      throw ApiException('Server tidak merespons. Cek koneksi WiFi gudang.');
    } catch (e) {
      throw ApiException('Tidak bisa terhubung ke server (${Session.I.baseUrl}): ${e.toString().split('\n').first}');
    }
  }

  static Future<dynamic> post(String path, Object body) async {
    try {
      final r = await http.post(_uri(path), headers: _headers, body: jsonEncode(body)).timeout(_timeout);
      return _decode(r);
    } on ApiException {
      rethrow;
    } on TimeoutException {
      throw ApiException('Server tidak merespons. Cek koneksi WiFi gudang.');
    } catch (e) {
      throw ApiException('Tidak bisa terhubung ke server (${Session.I.baseUrl}): ${e.toString().split('\n').first}');
    }
  }
  static Future<dynamic> put(String path, Object body) async {
    try {
      final r = await http.put(_uri(path), headers: _headers, body: jsonEncode(body)).timeout(_timeout);
      return _decode(r);
    } on ApiException {
      rethrow;
    } on TimeoutException {
      throw ApiException('Server tidak merespons. Cek koneksi WiFi gudang.');
    } catch (e) {
      throw ApiException('Tidak bisa terhubung ke server (${Session.I.baseUrl}): ${e.toString().split('\n').first}');
    }
  }

  /// Cek versi baru di server (distribusi internal). Mengembalikan alamat unduh bila ada versi lebih baru.
  static Future<String?> cekUpdate() async {
    try {
      final r = await http.get(Uri.parse('${Session.I.baseUrl}/unduh/versi.json')).timeout(const Duration(seconds: 5));
      if (r.statusCode != 200) return null;
      final j = jsonDecode(utf8.decode(r.bodyBytes));
      final v = (j['build'] as num?)?.toInt() ?? 0;
      if (kBuildNumber > 0 && v > kBuildNumber) return '${Session.I.baseUrl}/unduh/';
    } catch (_) {}
    return null;
  }

  // ------------------------------------------------------------ endpoint

  static Future<void> login(String userCode, String password) async {
    final res = await post('/api/auth/login', {'userCode': userCode, 'password': password});
    Session.I.token = res['token'] as String;
    Session.I.user = Map<String, dynamic>.from(res['user'] as Map);
  }

  static Future<List<Map<String, dynamic>>> _list(String path, [Map<String, String?>? q]) async {
    final res = await get(path, q);
    return (res as List).map((e) => Map<String, dynamic>.from(e as Map)).toList();
  }

  static Future<List<Map<String, dynamic>>> warehouses() => _list('/api/warehouses');
  static Future<List<Map<String, dynamic>>> items(String q) => _list('/api/items', {'q': q});
  static Future<List<String>> brands() async => ((await get('/api/brands')) as List).map((e) => e.toString()).toList();
  static Future<List<Map<String, dynamic>>> docs(String kind) => _list('/api/docs', {'kind': kind});

  static Future<Map<String, dynamic>> doc(String objType, int docEntry) async =>
      Map<String, dynamic>.from(await get('/api/docs/$objType/$docEntry') as Map);

  static Future<Map<String, dynamic>> saveInbound(Map<String, dynamic> body) async =>
      Map<String, dynamic>.from(await post('/api/inbound', body) as Map);

  static Future<Map<String, dynamic>> saveOutbound(Map<String, dynamic> body) async =>
      Map<String, dynamic>.from(await post('/api/outbound', body) as Map);

  static Future<Map<String, dynamic>> pallet(String qr, String whsCode) async =>
      Map<String, dynamic>.from(await get('/api/pallet', {'qr': qr, 'whsCode': whsCode}) as Map);

  static Future<Map<String, dynamic>> labels(String objType, int docEntry) async =>
      Map<String, dynamic>.from(await get('/api/labels/$objType/$docEntry') as Map);

  static Future<List<Map<String, dynamic>>> stockItem(String? whs) => _list('/api/reports/stock-item', {'whsCode': whs});
  static Future<List<Map<String, dynamic>>> stockContainer(String? whs) =>
      _list('/api/reports/stock-container', {'whsCode': whs});
  static Future<List<Map<String, dynamic>>> stockCard(String itemCode, String? whs, String? container) =>
      _list('/api/reports/stock-card', {'itemCode': itemCode, 'whsCode': whs, 'containerNo': container});
  static Future<Map<String, dynamic>> kpi(DateTime from, DateTime to, String? whs) async =>
      Map<String, dynamic>.from(await get('/api/reports/kpi', {
        'from': from.toIso8601String().substring(0, 10),
        'to': to.toIso8601String().substring(0, 10),
        'whsCode': whs,
      }) as Map);
}
