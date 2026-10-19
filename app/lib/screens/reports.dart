import 'package:flutter/material.dart';

import '../api.dart';
import '../models.dart';
import '../theme.dart';
import '../widgets.dart';

/// Laporan mengikuti KARTU_STOCK_GUDANG_BASAH: Kartu Stok, Stock per Barang, Stock per Container, KPI.
/// Stok dihitung dari dokumen yang sudah diposting Admin (status Close).
class ReportsMenu extends StatelessWidget {
  const ReportsMenu({super.key});

  @override
  Widget build(BuildContext context) {
    Widget item(IconData icon, String title, String sub, Widget page) => Padding(
          padding: const EdgeInsets.only(bottom: 12),
          child: Box(
            onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => page)),
            child: Row(children: [
              Container(
                width: 44,
                height: 44,
                decoration: BoxDecoration(color: C.inboundTint, borderRadius: BorderRadius.circular(12)),
                child: Icon(icon, color: C.inbound),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(title, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
                  Text(sub, style: const TextStyle(fontSize: 13, color: C.muted)),
                ]),
              ),
              const Icon(Icons.chevron_right, color: C.muted),
            ]),
          ),
        );

    return Column(children: [
      const Header(back: false, eyebrow: 'Laporan', title: 'Kartu Stock Gudang', accent: C.inbound),
      Expanded(
        child: ListView(padding: const EdgeInsets.all(20), children: [
          item(Icons.receipt_long_outlined, 'Kartu Stok', 'Mutasi masuk/keluar per item + saldo berjalan', const StockCardScreen()),
          item(Icons.inventory_2_outlined, 'Stock per Barang', 'Saldo KG, sak, palet per item', const StockItemScreen()),
          item(Icons.view_week_outlined, 'Stock per Container', 'Saldo per container & item', const StockContainerScreen()),
          item(Icons.speed_outlined, 'KPI Gudang', 'Jumlah dokumen, tonase & palet keluar-masuk', const KpiScreen()),
        ]),
      ),
    ]);
  }
}

/// Pilihan warehouse untuk filter laporan (null = semua warehouse cabang).
class _WhsFilter extends StatefulWidget {
  const _WhsFilter({required this.onChanged});
  final ValueChanged<String?> onChanged;
  @override
  State<_WhsFilter> createState() => _WhsFilterState();
}

class _WhsFilterState extends State<_WhsFilter> {
  List<Warehouse> _whs = [];
  String? _value;

  @override
  void initState() {
    super.initState();
    Api.warehouses().then((l) {
      if (mounted) setState(() => _whs = l.map(Warehouse.fromJson).toList());
    }, onError: (Object _) {});
  }

  @override
  Widget build(BuildContext context) => DropdownButtonFormField<String?>(
        value: _value,
        isExpanded: true,
        decoration: const InputDecoration(contentPadding: EdgeInsets.symmetric(horizontal: 12, vertical: 10)),
        items: [
          const DropdownMenuItem<String?>(value: null, child: Text('Semua warehouse')),
          for (final w in _whs) DropdownMenuItem<String?>(value: w.code, child: Text('${w.code} · ${w.name}', overflow: TextOverflow.ellipsis)),
        ],
        onChanged: (v) {
          setState(() => _value = v);
          widget.onChanged(v);
        },
      );
}

/// Kerangka layar laporan: header + filter + isi yang dimuat ulang saat filter berubah.
class _ReportPage extends StatelessWidget {
  const _ReportPage({required this.title, required this.filter, required this.body});
  final String title;
  final Widget filter;
  final Widget body;
  @override
  Widget build(BuildContext context) => Scaffold(
        body: Column(children: [
          Header(eyebrow: 'Laporan', title: title, bottom: filter),
          Expanded(child: body),
        ]),
      );
}

Widget _table(List<String> head, List<List<String>> rows, {List<int> flex = const []}) {
  int f(int i) => i < flex.length ? flex[i] : 1;
  Widget row(List<String> cells, {bool header = false}) => Container(
        padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 12),
        decoration: const BoxDecoration(border: Border(bottom: BorderSide(color: C.lineSoft))),
        child: Row(children: [
          for (var i = 0; i < cells.length; i++)
            Expanded(
              flex: f(i),
              child: Text(
                cells[i],
                textAlign: i == 0 ? TextAlign.left : TextAlign.right,
                style: header
                    ? const TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: C.muted)
                    : TextStyle(fontSize: 13, fontFamily: i == 0 ? null : mono),
              ),
            ),
        ]),
      );
  return Box(
    padding: EdgeInsets.zero,
    child: Column(children: [row(head, header: true), for (final r in rows) row(r)]),
  );
}

class StockItemScreen extends StatefulWidget {
  const StockItemScreen({super.key});
  @override
  State<StockItemScreen> createState() => _StockItemScreenState();
}

class _StockItemScreenState extends State<StockItemScreen> {
  String? _whs;
  late Future<List<Map<String, dynamic>>> _f = Api.stockItem(null);

  @override
  Widget build(BuildContext context) => _ReportPage(
        title: 'Stock per Barang',
        filter: _WhsFilter(onChanged: (v) => setState(() {
              _whs = v;
              _f = Api.stockItem(_whs);
            })),
        body: FutureBuilder<List<Map<String, dynamic>>>(
          future: _f,
          builder: (c, s) {
            if (s.hasError) return ErrorView(s.error.toString(), onRetry: () => setState(() => _f = Api.stockItem(_whs)));
            if (!s.hasData) return const Loading();
            final rows = s.data!;
            final tk = rows.fold<double>(0, (a, r) => a + toD(r['kg']));
            final ts = rows.fold<double>(0, (a, r) => a + toD(r['sak']));
            final tp = rows.fold<double>(0, (a, r) => a + toD(r['palet']));
            return ListView(padding: const EdgeInsets.all(20), children: [
              TotalsBar([('Total KG', fmt(tk)), ('Total sak', fmt(ts)), ('Total palet', fmt(tp))]),
              const SizedBox(height: 12),
              _table(
                ['ITEM', 'KG', 'SAK', 'PLT'],
                [for (final r in rows) ['${r['itemCode']}\n${r['itemName'] ?? ''}', fmt(toD(r['kg'])), fmt(toD(r['sak'])), fmt(toD(r['palet']))]],
                flex: [3, 2, 1, 1],
              ),
            ]);
          },
        ),
      );
}

class StockContainerScreen extends StatefulWidget {
  const StockContainerScreen({super.key});
  @override
  State<StockContainerScreen> createState() => _StockContainerScreenState();
}

class _StockContainerScreenState extends State<StockContainerScreen> {
  String? _whs;
  late Future<List<Map<String, dynamic>>> _f = Api.stockContainer(null);

  @override
  Widget build(BuildContext context) => _ReportPage(
        title: 'Stock per Container',
        filter: _WhsFilter(onChanged: (v) => setState(() {
              _whs = v;
              _f = Api.stockContainer(_whs);
            })),
        body: FutureBuilder<List<Map<String, dynamic>>>(
          future: _f,
          builder: (c, s) {
            if (s.hasError) return ErrorView(s.error.toString(), onRetry: () => setState(() => _f = Api.stockContainer(_whs)));
            if (!s.hasData) return const Loading();
            final rows = s.data!;
            return ListView(padding: const EdgeInsets.all(20), children: [
              for (final r in rows) ...[
                Box(
                  padding: const EdgeInsets.all(14),
                  radius: 14,
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Row(children: [
                      Expanded(child: Text('${r['containerNo'] ?? 'tanpa kontainer'}', style: const TextStyle(fontFamily: mono, fontWeight: FontWeight.w700, fontSize: 15))),
                      Text('masuk ${fmtDate(toDate(r['inboundDate']))}', style: const TextStyle(fontSize: 12, color: C.muted)),
                    ]),
                    Text('${r['itemCode']} · ${r['itemName'] ?? ''} · ${r['brand'] ?? ''}', style: const TextStyle(fontSize: 13, color: C.muted)),
                    const SizedBox(height: 8),
                    Row(children: [
                      Expanded(child: KV('KG', fmt(toD(r['kg'])))),
                      Expanded(child: KV('Sak', fmt(toD(r['sak'])))),
                      Expanded(child: KV('Palet', fmt(toD(r['palet'])))),
                    ]),
                  ]),
                ),
                const SizedBox(height: 10),
              ],
              if (rows.isEmpty) const Text('Tidak ada stok', textAlign: TextAlign.center),
            ]);
          },
        ),
      );
}

class StockCardScreen extends StatefulWidget {
  const StockCardScreen({super.key});
  @override
  State<StockCardScreen> createState() => _StockCardScreenState();
}

class _StockCardScreenState extends State<StockCardScreen> {
  String? _whs;
  Map<String, dynamic>? _item;
  final _cont = TextEditingController();
  Future<List<Map<String, dynamic>>>? _f;

  @override
  void dispose() {
    _cont.dispose();
    super.dispose();
  }

  void _run() {
    if (_item == null) return;
    setState(() => _f = Api.stockCard(_item!['itemCode'].toString(), _whs, _cont.text.trim().isEmpty ? null : _cont.text.trim().toUpperCase()));
  }

  @override
  Widget build(BuildContext context) => _ReportPage(
        title: 'Kartu Stok',
        filter: Column(children: [
          Autocomplete<Map<String, dynamic>>(
            displayStringForOption: (o) => '${o['itemCode']} · ${o['itemName']}',
            optionsBuilder: (v) async {
              if (v.text.trim().length < 2) return const Iterable<Map<String, dynamic>>.empty();
              try {
                return await Api.items(v.text.trim());
              } catch (_) {
                return const Iterable<Map<String, dynamic>>.empty();
              }
            },
            onSelected: (o) {
              _item = o;
              _run();
            },
            fieldViewBuilder: (c, ctl, focus, submit) => TextField(
              controller: ctl,
              focusNode: focus,
              decoration: const InputDecoration(prefixIcon: Icon(Icons.search), hintText: 'Cari item', contentPadding: EdgeInsets.symmetric(vertical: 10)),
            ),
          ),
          const SizedBox(height: 8),
          Row(children: [
            Expanded(child: _WhsFilter(onChanged: (v) {
              _whs = v;
              _run();
            })),
            const SizedBox(width: 8),
            Expanded(
              child: TextField(
                controller: _cont,
                inputFormatters: [upperCase],
                onSubmitted: (_) => _run(),
                decoration: const InputDecoration(hintText: 'Container (opsional)', contentPadding: EdgeInsets.symmetric(horizontal: 12, vertical: 10)),
              ),
            ),
          ]),
        ]),
        body: _f == null
            ? const Center(child: Text('Pilih item untuk melihat kartu stok', style: TextStyle(color: C.muted)))
            : FutureBuilder<List<Map<String, dynamic>>>(
                future: _f,
                builder: (c, s) {
                  if (s.hasError) return ErrorView(s.error.toString(), onRetry: _run);
                  if (!s.hasData) return const Loading();
                  final rows = s.data!;
                  final last = rows.isEmpty ? null : rows.last;
                  return ListView(padding: const EdgeInsets.all(20), children: [
                    if (last != null)
                      TotalsBar([('Saldo KG', fmt(toD(last['saldoKg']))), ('Saldo sak', fmt(toD(last['saldoSak']))), ('Saldo palet', fmt(toD(last['saldoPalet'])))]),
                    const SizedBox(height: 12),
                    _table(
                      ['TANGGAL / DOK', 'MUTASI KG', 'SALDO KG'],
                      [
                        for (final r in rows)
                          [
                            '${fmtDate(toDate(r['docDate']))}\n${r['trxCode']} ${r['docEntry']}${r['containerNo'] == null ? '' : ' · ${r['containerNo']}'}',
                            '${toD(r['kg']) > 0 ? '+' : ''}${fmt(toD(r['kg']))}',
                            fmt(toD(r['saldoKg'])),
                          ]
                      ],
                      flex: [3, 2, 2],
                    ),
                    if (rows.isEmpty) const Padding(padding: EdgeInsets.all(16), child: Text('Belum ada mutasi', textAlign: TextAlign.center)),
                  ]);
                },
              ),
      );
}

class KpiScreen extends StatefulWidget {
  const KpiScreen({super.key});
  @override
  State<KpiScreen> createState() => _KpiScreenState();
}

class _KpiScreenState extends State<KpiScreen> {
  String? _whs;
  int _range = 7;
  late Future<Map<String, dynamic>> _f = _query();

  Future<Map<String, dynamic>> _query() {
    final to = DateTime.now();
    final from = _range == 0 ? DateTime(to.year, to.month, 1) : to.subtract(Duration(days: _range - 1));
    return Api.kpi(from, to, _whs);
  }

  @override
  Widget build(BuildContext context) => _ReportPage(
        title: 'KPI Gudang',
        filter: Column(children: [
          _WhsFilter(onChanged: (v) => setState(() {
                _whs = v;
                _f = _query();
              })),
          const SizedBox(height: 8),
          SegmentedButton<int>(
            segments: const [
              ButtonSegment(value: 1, label: Text('Hari ini')),
              ButtonSegment(value: 7, label: Text('7 hari')),
              ButtonSegment(value: 0, label: Text('Bulan ini')),
            ],
            selected: {_range},
            showSelectedIcon: false,
            onSelectionChanged: (v) => setState(() {
              _range = v.first;
              _f = _query();
            }),
          ),
        ]),
        body: FutureBuilder<Map<String, dynamic>>(
          future: _f,
          builder: (c, s) {
            if (s.hasError) return ErrorView(s.error.toString(), onRetry: () => setState(() => _f = _query()));
            if (!s.hasData) return const Loading();
            final k = s.data!;
            Widget tile(String label, String value, Color color) => Expanded(
                  child: Box(
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Text(label, style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: color)),
                      const SizedBox(height: 4),
                      Text(value, style: const TextStyle(fontFamily: mono, fontSize: 24, fontWeight: FontWeight.w700)),
                    ]),
                  ),
                );
            return ListView(padding: const EdgeInsets.all(20), children: [
              Row(children: [
                tile('DOK INBOUND', fmt(toD(k['inboundDocs'])), C.inbound),
                const SizedBox(width: 12),
                tile('DOK OUTBOUND', fmt(toD(k['outboundDocs'])), C.outbound),
              ]),
              const SizedBox(height: 12),
              Row(children: [
                tile('KG MASUK', fmt(toD(k['kgIn'])), C.inbound),
                const SizedBox(width: 12),
                tile('KG KELUAR', fmt(toD(k['kgOut'])), C.outbound),
              ]),
              const SizedBox(height: 12),
              Row(children: [
                tile('PALET MASUK', fmt(toD(k['paletIn'])), C.inbound),
                const SizedBox(width: 12),
                tile('PALET KELUAR', fmt(toD(k['paletOut'])), C.outbound),
              ]),
              const SizedBox(height: 12),
              Row(children: [
                tile('BELUM DIPOSTING', fmt(toD(k['openDocs'])), C.amberText),
                const SizedBox(width: 12),
                tile('MENUNGGU PT', fmt(toD(k['waitingPt'])), C.amberText),
              ]),
            ]);
          },
        ),
      );
}
