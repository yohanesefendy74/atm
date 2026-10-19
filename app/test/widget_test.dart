import 'package:flutter_test/flutter_test.dart';
import 'package:gudang_atm/models.dart';
import 'package:gudang_atm/tspl.dart';

void main() {
  test('palet keluar sebagian: KG otomatis dari karung, bisa diubah manual', () {
    final p = ScannedPallet.fromJson({
      'qr': '261009-GLA-001-TGHU8812345',
      'itemCode': 'GLA-001',
      'itemName': 'Gula Pasir',
      'containerNo': 'TGHU8812345',
      'kgPerSak': 50,
      'sakPerPalet': 25,
    });
    expect(p.sak, 25);
    expect(p.kg, 1250);
    p.partial = true;
    p.sak = 10;
    expect(p.kg, 500);
    p.kgManual = 490;
    expect(p.kg, 490);
    expect(p.sisaSak, 15);
  });

  test('label TSPL berisi QR dan jumlah cetak = qty palet', () {
    final bytes = Tspl.build([
      LabelData(
        containerNo: 'TGHU8812345',
        date: DateTime(2026, 10, 9),
        itemName: 'Gula Pasir',
        brand: 'BRAND-A',
        packKg: 50,
        ptName: 'PT CONTOH',
        qr: '261009-GLA-001-TGHU8812345',
        sakPerPalet: 25,
        copies: 20,
      ),
    ], const LabelSize(100, 70));
    final s = String.fromCharCodes(bytes);
    expect(s, contains('QRCODE'));
    expect(s, contains('261009-GLA-001-TGHU8812345'));
    expect(s, contains('TGHU 8812345'));
    expect(s, contains('PRINT 1,20'));
  });
}
