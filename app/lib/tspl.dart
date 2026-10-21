import 'dart:convert';

import 'theme.dart';

/// Ukuran label yang didukung (mm).
class LabelSize {
  const LabelSize(this.w, this.h);
  final int w;
  final int h;
  String get label => '$w × $h mm';
  static const all = [LabelSize(50, 30), LabelSize(80, 50), LabelSize(100, 70)];
}

/// Data satu jenis label (satu item). Dicetak sebanyak [copies] = Qty Palet.
class LabelData {
  LabelData({
    required this.containerNo,
    required this.date,
    required this.itemName,
    required this.brand,
    required this.packKg,
    required this.ptName,
    required this.qr,
    required this.sakPerPalet,
    required this.copies,
    this.ruangan = '',
  });
  final String ruangan;
  final String containerNo;
  final DateTime date;
  final String itemName;
  final String brand;
  final double packKg;
  final String ptName;
  final String qr;
  final double sakPerPalet;
  final int copies;

  /// TGHU8812345 -> TGHU 8812345 (seperti label fisik)
  String get containerDisplay {
    final c = containerNo.replaceAll(' ', '');
    return c.length == 11 ? '${c.substring(0, 4)} ${c.substring(4)}' : c;
  }
}

/// Perintah TSPL untuk printer TSC / Xprinter (203 dpi = 8 dot per mm).
/// Layout mengikuti label palet: container besar, tanggal, item, merek, @isi, PT, QR, kotak SAK.
class Tspl {
  static String _clean(String s, int max, {bool upper = true}) {
    final ascii = (upper ? s.toUpperCase() : s).replaceAll('"', "'").replaceAll(RegExp(r'[^\x20-\x7E]'), '');
    return ascii.length > max ? ascii.substring(0, max) : ascii;
  }

  static List<int> build(List<LabelData> labels, LabelSize size) {
    final dots = 8; // 203 dpi
    final s = size.w / 100.0; // skala terhadap layout 100 x 70 mm
    int x(num v) => (v * s).round();
    // font TSPL bawaan: "1" 8x12, "2" 12x20, "3" 16x24, "4" 24x32, "5" 32x48
    final big = size.w >= 100 ? '5' : (size.w >= 80 ? '4' : '3');
    final body = size.w >= 80 ? '3' : '2';
    final qrCell = size.w >= 100 ? 6 : (size.w >= 80 ? 5 : 3);
    final maxChars = size.w >= 100 ? 30 : (size.w >= 80 ? 26 : 20);

    final step = x(36) < 21 ? 21 : x(36); // jarak baris teks
    int line(int i) => x(96) + i * step;

    final b = StringBuffer();
    for (final l in labels) {
      if (l.copies <= 0) continue;
      final pack = l.packKg == l.packKg.roundToDouble() ? l.packKg.toInt().toString() : fmt(l.packKg);
      b
        ..writeln('SIZE ${size.w} mm,${size.h} mm')
        ..writeln('GAP 2 mm,0 mm')
        ..writeln('DIRECTION 1')
        ..writeln('REFERENCE 0,0')
        ..writeln('CLS')
        ..writeln('TEXT ${x(24)},${x(24)},"$big",0,1,1,"${_clean(l.containerDisplay, 14)}"')
        ..writeln('TEXT ${x(24)},${line(0)},"$body",0,1,1,"${fmtDate(l.date)}"')
        ..writeln('TEXT ${x(24)},${line(1)},"$body",0,1,1,"${_clean(l.itemName, maxChars)}"')
        ..writeln('TEXT ${x(24)},${line(2)},"$body",0,1,1,"${_clean(l.brand, maxChars)}"')
        ..writeln('TEXT ${x(24)},${line(3)},"$body",0,1,1,"@$pack"')
        ..writeln('TEXT ${x(24)},${line(4)},"$body",0,1,1,"${_clean(l.ptName, maxChars)}"')
        ..writeln('TEXT ${x(24)},${x(size.h * dots / s - 40)},"1",0,1,1,"${_clean(l.qr, 40, upper: false)}"')
        ..writeln('QRCODE ${x(590)},${x(28)},M,$qrCell,A,0,"${_clean(l.qr, 60, upper: false)}"')
        ..writeln('BOX ${x(584)},${x(216)},${x(776)},${x(286)},3')
        ..writeln('TEXT ${x(610)},${x(240)},"$body",0,1,1,"${fmt(l.sakPerPalet)} SAK"')
        ..writeln('BOX ${x(584)},${x(304)},${x(776)},${x(374)},3')
        ..writeln('TEXT ${x(600)},${x(328)},"$body",0,1,1,"${_clean(l.ruangan, 10)}"')
        ..writeln('BOX ${x(584)},${x(392)},${x(776)},${x(462)},3')
        ..writeln('PRINT 1,${l.copies}');
    }
    return latin1.encode(b.toString().replaceAll('\n', '\r\n'));
  }

  static List<LabelData> testLabels() => [
        LabelData(
          containerNo: 'TEST0000001',
          date: DateTime.now(),
          itemName: 'TES PRINTER',
          brand: 'GUDANG ATM',
          packKg: 50,
          ptName: 'PT',
          qr: 'TEST',
          sakPerPalet: 25,
          copies: 1,
        )
      ];

  /// Label uji 1 lembar untuk cek koneksi printer.
  static List<int> test(LabelSize size) => build(testLabels(), size);
}
