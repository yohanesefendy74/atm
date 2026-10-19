import 'theme.dart';

class Warehouse {
  Warehouse(this.code, this.name, this.isTitipan, this.isDefault);
  final String code;
  final String name;
  final bool isTitipan;
  final bool isDefault;

  factory Warehouse.fromJson(Map<String, dynamic> j) => Warehouse(
        (j['whsCode'] ?? '').toString(),
        (j['whsName'] ?? '').toString(),
        j['isTitipan'] == true || j['isTitipan'] == 1,
        j['isDefault'] == true || j['isDefault'] == 1,
      );
}

/// Satu baris detail barang (inbound atau Item Inbound KR/RP). Flag selalu +1.
class LineDraft {
  LineDraft({
    required this.itemCode,
    required this.itemName,
    this.groupName = '',
    this.uom = 'KG',
    this.brand,
    this.origin,
    required this.qty,
    required this.qty2,
    required this.qtyPalet,
  });
  final String itemCode;
  final String itemName;
  final String groupName;
  final String uom;
  final String? brand;
  final String? origin;
  final double qty;
  final double qty2;
  final double qtyPalet;

  Map<String, dynamic> toJson() => {
        'itemCode': itemCode,
        'uom': uom,
        'brand': brand,
        'origin': origin,
        'qty': qty,
        'qty2': qty2,
        'qtyPalet': qtyPalet,
      };
}

class InboundDraft {
  Warehouse? warehouse;
  String noMobil = '';
  String containerNo = '';
  final DateTime date = DateTime.now();
  final List<LineDraft> lines = [];

  double get totalKg => lines.fold(0, (s, l) => s + l.qty);
  double get totalSak => lines.fold(0, (s, l) => s + l.qty2);
  double get totalPalet => lines.fold(0, (s, l) => s + l.qtyPalet);

  Map<String, dynamic> toJson() => {
        'whsCode': warehouse!.code,
        'noMobil': noMobil,
        'containerNo': containerNo,
        'docDate': date.toIso8601String().substring(0, 10),
        'lines': lines.map((l) => l.toJson()).toList(),
      };
}

/// Palet yang discan keluar. Utuh = semua sak di palet; sebagian = sak diisi krani.
/// KG default = sak × KG per sak, tapi bisa diubah manual karena penyusutan.
class ScannedPallet {
  ScannedPallet.fromJson(Map<String, dynamic> j)
      : qr = (j['qr'] ?? '').toString(),
        itemCode = (j['itemCode'] ?? '').toString(),
        itemName = (j['itemName'] ?? '').toString(),
        brand = j['brand']?.toString(),
        origin = j['origin']?.toString(),
        containerNo = (j['containerNo'] ?? '').toString(),
        kgPerSak = toD(j['kgPerSak']),
        sakPerPalet = toD(j['sakPerPalet']),
        stockKg = toD(j['stockKg']),
        stockSak = toD(j['stockSak']) {
    sak = sakPerPalet;
  }

  final String qr;
  final String itemCode;
  final String itemName;
  final String? brand;
  final String? origin;
  final String containerNo;
  final double kgPerSak;
  final double sakPerPalet;
  final double stockKg;
  final double stockSak;

  bool partial = false;
  double sak = 0;
  double? kgManual;

  double get kgAuto => sak * kgPerSak;
  double get kg => kgManual ?? kgAuto;
  double get sisaSak => (sakPerPalet - sak).clamp(0, double.infinity).toDouble();
  double get sisaKg => sisaSak * kgPerSak;
}

class OutboundDraft {
  Warehouse? warehouse;
  String jenis = 'OB'; // OB / KR / RP (BT otomatis dari warehouse titipan)
  String noMobil = '';
  String? containerNo; // diisi otomatis dari QR palet pertama
  final DateTime date = DateTime.now();
  final List<ScannedPallet> pallets = [];
  final List<LineDraft> inLines = [];

  bool get isTitipan => warehouse?.isTitipan ?? false;
  String get trxCode => isTitipan ? 'BT' : jenis;
  bool get isAdj => !isTitipan && jenis != 'OB';
  String get jenisLabel => switch (trxCode) {
        'BT' => 'BT · Titipan',
        'KR' => 'KR · Penyesuaian',
        'RP' => 'RP · Repacking',
        _ => 'OB · Outbound',
      };

  double get totalKg => pallets.fold(0, (s, p) => s + p.kg);
  double get totalSak => pallets.fold(0, (s, p) => s + p.sak);

  /// Palet digabung per item: tiap palet discan = 1 QtyPalet.
  List<Map<String, dynamic>> outLines() {
    final map = <String, Map<String, dynamic>>{};
    for (final p in pallets) {
      final m = map.putIfAbsent(p.itemCode, () => {
            'itemCode': p.itemCode,
            'itemName': p.itemName,
            'uom': 'KG',
            'brand': p.brand,
            'origin': p.origin,
            'qty': 0.0,
            'qty2': 0.0,
            'qtyPalet': 0.0,
            'partial': 0,
          });
      m['qty'] = (m['qty'] as double) + p.kg;
      m['qty2'] = (m['qty2'] as double) + p.sak;
      m['qtyPalet'] = (m['qtyPalet'] as double) + 1;
      if (p.partial) m['partial'] = (m['partial'] as int) + 1;
    }
    return map.values.toList();
  }

  Map<String, dynamic> toJson() => {
        'whsCode': warehouse!.code,
        'jenis': jenis,
        'noMobil': noMobil,
        'containerNo': containerNo,
        'docDate': date.toIso8601String().substring(0, 10),
        'outLines': outLines()
            .map((l) => {
                  'itemCode': l['itemCode'],
                  'uom': l['uom'],
                  'brand': l['brand'],
                  'origin': l['origin'],
                  'qty': l['qty'],
                  'qty2': l['qty2'],
                  'qtyPalet': l['qtyPalet'],
                })
            .toList(),
        'inLines': isAdj ? inLines.map((l) => l.toJson()).toList() : <Map<String, dynamic>>[],
      };
}
