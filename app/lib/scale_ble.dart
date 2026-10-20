import 'dart:async';
import 'dart:convert';

import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:permission_handler/permission_handler.dart';

import 'api.dart';

/// Satu bacaan dari indikator timbangan.
class ScaleReading {
  ScaleReading(this.kg, this.stabil, this.raw);
  final double kg;
  final bool stabil;
  final String raw; // teks mentah dari indikator (disimpan ke server untuk audit)
}

class ScaleDevice {
  ScaleDevice(this.id, this.name);
  final String id;
  final String name;
}

/// Membaca indikator timbangan (A12E) lewat jembatan ESP32 yang memancarkan BLE (Nordic UART Service).
/// Parser angka dan aturan stabil sama dengan Gateway: ubah [pattern] bila format A12E berbeda (lihat hasil --sniff).
class BleScale {
  BleScale._();
  static final I = BleScale._();

  static final Guid serviceUuid = Guid('6E400001-B5A3-F393-E0A9-E50E24DCCA9E');
  static final Guid txUuid = Guid('6E400003-B5A3-F393-E0A9-E50E24DCCA9E'); // ESP32 -> HP (notify)

  /// Regex pengambil angka berat dari satu baris. Grup 1 dipakai bila ada.
  RegExp pattern = RegExp(r'[-+]?\d+(?:[.,]\d+)?');
  /// Teks penanda stabil (mis. 'ST'); kosong = stabil bila [minStabil] bacaan berturut-turut sama.
  RegExp? stabilPattern;
  bool gram = false;
  int minStabil = 3;

  BluetoothDevice? _dev;
  StreamSubscription<List<int>>? _sub;
  final _buf = StringBuffer();
  final _recent = <_Rd>[];
  final _live = StreamController<ScaleReading>.broadcast();

  /// Bacaan langsung (untuk tampilan berat yang bergerak).
  Stream<ScaleReading> get live => _live.stream;
  bool get connected => _dev != null && _sub != null;

  static Future<void> _permissions() async {
    await [Permission.bluetoothConnect, Permission.bluetoothScan, Permission.location].request();
  }

  /// Mencari ESP32 timbangan di sekitar (siaran BLE dengan servis Nordic UART).
  static Future<List<ScaleDevice>> scan({Duration timeout = const Duration(seconds: 6)}) async {
    await _permissions();
    if (!await FlutterBluePlus.isSupported) throw ApiException('HP ini tidak mendukung Bluetooth LE');
    if (FlutterBluePlus.adapterStateNow != BluetoothAdapterState.on) throw ApiException('Bluetooth HP belum dinyalakan');
    final found = <String, ScaleDevice>{};
    final sub = FlutterBluePlus.scanResults.listen((rs) {
      for (final r in rs) {
        final name = r.advertisementData.advName.isNotEmpty ? r.advertisementData.advName : r.device.platformName;
        found[r.device.remoteId.str] = ScaleDevice(r.device.remoteId.str, name.isEmpty ? r.device.remoteId.str : name);
      }
    });
    await FlutterBluePlus.startScan(withServices: [serviceUuid], timeout: timeout);
    await FlutterBluePlus.isScanning.where((s) => s == false).first;
    await sub.cancel();
    return found.values.toList();
  }

  Future<void> connect(String remoteId) async {
    await disconnect();
    await _permissions();
    final d = BluetoothDevice.fromId(remoteId);
    try {
      await d.connect(timeout: const Duration(seconds: 10));
      final services = await d.discoverServices();
      BluetoothCharacteristic? tx;
      for (final s in services) {
        if (s.serviceUuid == serviceUuid) {
          for (final c in s.characteristics) {
            if (c.characteristicUuid == txUuid) tx = c;
          }
        }
      }
      if (tx == null) throw ApiException('Perangkat ini bukan jembatan timbangan Gudang ATM');
      await tx.setNotifyValue(true);
      _sub = tx.onValueReceived.listen(_onBytes);
      _dev = d;
    } catch (e) {
      try { await d.disconnect(); } catch (_) {}
      if (e is ApiException) rethrow;
      throw ApiException('Gagal terhubung ke timbangan: $e');
    }
  }

  Future<void> disconnect() async {
    await _sub?.cancel();
    _sub = null;
    try { await _dev?.disconnect(); } catch (_) {}
    _dev = null;
    _buf.clear();
    _recent.clear();
  }

  void _onBytes(List<int> data) {
    for (final ch in latin1.decode(data, allowInvalid: true).split('')) {
      if (ch == '\r' || ch == '\n') {
        final line = _buf.toString();
        _buf.clear();
        if (line.isNotEmpty) _feed(line);
      } else if (_buf.length < 200) {
        _buf.write(ch);
      }
    }
  }

  void _feed(String line) {
    final m = pattern.firstMatch(line);
    if (m == null) return;
    final txt = ((m.groupCount >= 1 ? m.group(1) : null) ?? m.group(0)!).replaceAll(',', '.');
    var kg = double.tryParse(txt);
    if (kg == null) return;
    if (gram) kg /= 1000;
    final flag = stabilPattern?.hasMatch(line) ?? false;
    _recent.add(_Rd(kg, flag, DateTime.now(), line));
    if (_recent.length > 20) _recent.removeAt(0);
    _live.add(ScaleReading(kg, _isStable(), line));
  }

  bool _isStable() {
    if (_recent.isEmpty) return false;
    if (stabilPattern != null) return _recent.last.flag;
    if (_recent.length < minStabil) return false;
    final last = _recent.last.kg;
    return _recent.sublist(_recent.length - minStabil).every((r) => r.kg == last);
  }

  /// Menunggu berat stabil (maks [timeout]). Bila tidak stabil, mengembalikan bacaan terakhir dengan stabil=false.
  Future<ScaleReading> readStable({Duration timeout = const Duration(seconds: 10)}) async {
    if (!connected) throw ApiException('Timbangan Bluetooth belum terhubung');
    final since = DateTime.now().subtract(const Duration(seconds: 1));
    final end = DateTime.now().add(timeout);
    _Rd? last;
    while (DateTime.now().isBefore(end)) {
      final fresh = _recent.where((r) => r.at.isAfter(since)).toList();
      if (fresh.isNotEmpty) {
        last = fresh.last;
        if (_isStable() && last.at.isAfter(since)) return ScaleReading(last.kg, true, last.raw);
      }
      await Future<void>.delayed(const Duration(milliseconds: 150));
    }
    if (last == null) throw ApiException('Tidak ada data dari timbangan. Periksa ESP32 dan kabelnya.');
    return ScaleReading(last.kg, false, last.raw);
  }
}

class _Rd {
  _Rd(this.kg, this.flag, this.at, this.raw);
  final double kg;
  final bool flag;
  final DateTime at;
  final String raw;
}
