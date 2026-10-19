import 'package:permission_handler/permission_handler.dart';
import 'package:print_bluetooth_thermal/print_bluetooth_thermal.dart';

import 'api.dart';

class PrinterInfo {
  PrinterInfo(this.name, this.mac);
  final String name;
  final String mac;
}

/// Printer label TSC / Xprinter lewat Bluetooth (SPP). Printer harus di-pair dulu di Pengaturan Android.
class LabelPrinter {
  static Future<void> _permissions() async {
    await [Permission.bluetoothConnect, Permission.bluetoothScan, Permission.location].request();
  }

  static Future<List<PrinterInfo>> paired() async {
    await _permissions();
    if (!await PrintBluetoothThermal.bluetoothEnabled) {
      throw ApiException('Bluetooth HP belum dinyalakan');
    }
    final list = await PrintBluetoothThermal.pairedBluetooths;
    return list.map((b) => PrinterInfo(b.name, b.macAdress)).toList();
  }

  static Future<void> send(List<int> bytes) async {
    final mac = Session.I.printerMac;
    if (mac == null || mac.isEmpty) throw ApiException('Printer belum dipilih. Buka Pengaturan › Printer.');
    await _permissions();
    if (!await PrintBluetoothThermal.bluetoothEnabled) throw ApiException('Bluetooth HP belum dinyalakan');

    var connected = await PrintBluetoothThermal.connectionStatus;
    if (!connected) {
      connected = await PrintBluetoothThermal.connect(macPrinterAddress: mac);
    }
    if (!connected) throw ApiException('Gagal terhubung ke printer ${Session.I.printerName ?? mac}');

    // kirim bertahap supaya buffer printer tidak penuh
    const chunk = 2048;
    for (var i = 0; i < bytes.length; i += chunk) {
      final end = (i + chunk < bytes.length) ? i + chunk : bytes.length;
      final ok = await PrintBluetoothThermal.writeBytes(bytes.sublist(i, end));
      if (!ok) throw ApiException('Pengiriman ke printer terputus');
    }
  }
}
