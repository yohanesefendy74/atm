import 'package:flutter/material.dart';

import '../api.dart';
import '../models.dart';
import '../theme.dart';
import '../widgets.dart';
import 'doc_list.dart';

class InboundListScreen extends StatelessWidget {
  const InboundListScreen({super.key});
  @override
  Widget build(BuildContext context) => DocList(
        kind: 'inbound',
        accent: C.inbound,
        eyebrow: 'Inbound',
        title: 'Penerimaan Barang',
        filters: const ['Menunggu PT', 'Siap cetak', 'Selesai'],
        newScreen: (_) => const InboundHeaderScreen(),
        note: 'Inbound dicatat tanpa PO. Label QR bisa dicetak setelah Admin mengisi PT di CMS.',
      );
}

const _steps = ['Header', 'Detail barang', 'Simpan'];

/// Langkah 1: Warehouse, No Mobil, No Kontainer. 1 header = 1 container.
class InboundHeaderScreen extends StatefulWidget {
  const InboundHeaderScreen({super.key});
  @override
  State<InboundHeaderScreen> createState() => _InboundHeaderScreenState();
}

class _InboundHeaderScreenState extends State<InboundHeaderScreen> {
  final _draft = InboundDraft();
  final _mobil = TextEditingController();
  final _cont = TextEditingController();
  List<Warehouse> _whs = [];
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final list = (await Api.warehouses()).map(Warehouse.fromJson).toList();
      if (!mounted) return;
      setState(() {
        _whs = list;
        _draft.warehouse = list.isEmpty ? null : list.firstWhere((w) => w.isDefault, orElse: () => list.first);
      });
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    }
  }

  @override
  void dispose() {
    _mobil.dispose();
    _cont.dispose();
    super.dispose();
  }

  void _next() {
    final cont = _cont.text.replaceAll(' ', '').toUpperCase();
    if (_draft.warehouse == null) return showError(context, 'Pilih warehouse');
    if (_mobil.text.trim().isEmpty) return showError(context, 'No. mobil wajib diisi');
    if (cont.isNotEmpty && !RegExp(r'^[A-Z]{4}\d{7}$').hasMatch(cont)) {
      return showError(context, 'Format kontainer: 4 huruf + 7 angka (contoh TGHU8812345)');
    }
    _draft.noMobil = _mobil.text.trim().toUpperCase();
    _draft.containerNo = cont;
    Navigator.of(context).push(MaterialPageRoute(builder: (_) => InboundDetailScreen(draft: _draft)));
  }

  @override
  Widget build(BuildContext context) {
    final monoStyle = const TextStyle(fontFamily: mono, fontSize: 17, fontWeight: FontWeight.w600, letterSpacing: 0.7);
    return Scaffold(
      body: Column(children: [
        const Header(
          eyebrow: 'Inbound baru',
          title: 'Data Header',
          bottom: Steps(labels: _steps, current: 0, accent: C.inbound),
        ),
        Expanded(
          child: _error != null
              ? ErrorView(_error!, onRetry: _load)
              : ListView(padding: const EdgeInsets.all(20), children: [
                  const FieldLabel('Warehouse', required: true),
                  WarehouseField(items: _whs, value: _draft.warehouse, onChanged: (w) => setState(() => _draft.warehouse = w)),
                  Hint(_draft.warehouse?.isTitipan ?? false
                      ? 'Warehouse titipan: transaksi otomatis BT (Barang Titipan)'
                      : 'Daftar sesuai hak akses akun Anda'),
                  const SizedBox(height: 18),
                  const FieldLabel('No. Mobil', required: true),
                  TextField(controller: _mobil, inputFormatters: [upperCase], style: monoStyle, decoration: const InputDecoration(hintText: 'B 9123 KXT')),
                  const Hint('Nomor polisi kendaraan pengantar'),
                  const SizedBox(height: 18),
                  const FieldLabel('No. Kontainer'),
                  TextField(controller: _cont, inputFormatters: [upperCase], style: monoStyle, decoration: const InputDecoration(hintText: 'TGHU8812345')),
                  const Hint('Format 4 huruf + 7 angka. 1 inbound = 1 kontainer. Kosongkan bila tanpa kontainer.'),
                  const SizedBox(height: 18),
                  Box(
                    child: Row(children: [
                      Expanded(child: KV('Tanggal', fmtDate(_draft.date), monoValue: false)),
                      Expanded(child: KV('Petugas', Session.I.userName, monoValue: false)),
                    ]),
                  ),
                ]),
        ),
        Footer(children: [BigButton(label: 'Lanjut isi detail barang', color: C.inbound, icon: Icons.chevron_right, onPressed: _next)]),
      ]),
    );
  }
}

/// Langkah 2: detail barang curah, diisi manual (tidak scan).
class InboundDetailScreen extends StatefulWidget {
  const InboundDetailScreen({super.key, required this.draft});
  final InboundDraft draft;
  @override
  State<InboundDetailScreen> createState() => _InboundDetailScreenState();
}

class _InboundDetailScreenState extends State<InboundDetailScreen> {
  String? _ruang;

  @override
  Widget build(BuildContext context) {
    final d = widget.draft;
    return Scaffold(
      body: Column(children: [
        Header(
          eyebrow: 'Langkah 2 dari 3',
          title: 'Detail barang curah',
          bottom: Wrap(spacing: 6, children: [
            Pill(d.warehouse?.code ?? '-', bg: C.ground, fg: C.ink, monoFont: true),
            Pill(d.noMobil, bg: C.ground, fg: C.ink, monoFont: true),
            if (d.containerNo.isNotEmpty) Pill(d.containerNo, bg: C.ground, fg: C.ink, monoFont: true),
          ]),
        ),
        Expanded(
          child: ListView(padding: const EdgeInsets.all(20), children: [
            RuanganField(
              whs: d.warehouse!.code,
              value: _ruang,
              titipan: d.warehouse!.isTitipan ? true : null,
              label: 'Ruangan tujuan',
              onChanged: (v) => setState(() => _ruang = v),
            ),
            const Hint('Ruangan berlaku untuk barang yang ditambahkan berikutnya. Satu container boleh masuk ke beberapa ruangan.'),
            const SizedBox(height: 12),
            LineForm(
              accent: C.inbound,
              onAdd: (l) {
                if (_ruang == null) return showError(context, 'Pilih ruangan tujuan dulu');
                setState(() => d.lines.add(l.withRuangan(_ruang)));
              },
            ),
            const SizedBox(height: 16),
            Text('Sudah ditambahkan · ${d.lines.length} baris', style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
            const SizedBox(height: 8),
            for (var i = 0; i < d.lines.length; i++) ...[
              LineTile(d.lines[i], onDelete: () => setState(() => d.lines.removeAt(i))),
              const SizedBox(height: 8),
            ],
          ]),
        ),
        Footer(children: [
          BigButton(
            label: 'Lanjut ke ringkasan',
            color: C.inbound,
            outlined: true,
            icon: Icons.chevron_right,
            onPressed: d.lines.isEmpty
                ? null
                : () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => InboundSummaryScreen(draft: d))).then((_) => setState(() {})),
          ),
        ]),
      ]),
    );
  }
}

/// Langkah 3: ringkasan & simpan. Tersimpan sebagai "Menunggu PT"; label dicetak setelah Admin mengisi PT.
class InboundSummaryScreen extends StatefulWidget {
  const InboundSummaryScreen({super.key, required this.draft});
  final InboundDraft draft;
  @override
  State<InboundSummaryScreen> createState() => _InboundSummaryScreenState();
}

class _InboundSummaryScreenState extends State<InboundSummaryScreen> {
  bool _busy = false;

  Future<void> _save() async {
    setState(() => _busy = true);
    try {
      final r = await Api.saveInbound(widget.draft.toJson());
      if (!mounted) return;
      await showDialog<void>(
        context: context,
        builder: (c) => AlertDialog(
          title: const Text('Inbound tersimpan'),
          content: Text('No. ${r['docEntry']} (${r['trxCode']}).\n\nStatus: Menunggu PT. Label QR bisa dicetak dari daftar Inbound setelah Admin mengisi PT di CMS.'),
          actions: [FilledButton(onPressed: () => Navigator.of(c).pop(), child: const Text('OK'))],
        ),
      );
      if (mounted) Navigator.of(context).popUntil((r) => r.isFirst);
    } catch (e) {
      if (mounted) showError(context, e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final d = widget.draft;
    return Scaffold(
      body: Column(children: [
        const Header(eyebrow: 'Langkah 3 dari 3', title: 'Ringkasan Inbound'),
        Expanded(
          child: ListView(padding: const EdgeInsets.all(20), children: [
            Box(
              child: Row(children: [
                Expanded(child: KV('WAREHOUSE', d.warehouse?.code ?? '-')),
                Expanded(child: KV('NO. MOBIL', d.noMobil)),
                Expanded(child: KV('KONTAINER', d.containerNo.isEmpty ? '-' : d.containerNo)),
              ]),
            ),
            const SizedBox(height: 16),
            Text('Detail barang · ${d.lines.length} baris', style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600)),
            const SizedBox(height: 8),
            for (final l in d.lines) ...[
              Box(
                padding: const EdgeInsets.all(14),
                radius: 14,
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Row(children: [
                    Expanded(child: Text(l.itemCode, style: const TextStyle(fontFamily: mono, fontSize: 15, fontWeight: FontWeight.w600))),
                    Pill(l.uom, monoFont: true),
                  ]),
                  Text([l.itemName, l.brand, l.origin].whereType<String>().join(' · '), style: const TextStyle(fontSize: 13, color: C.muted)),
                  Text('Ruangan ${l.kodeRuangan ?? '-'}', style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
                  const SizedBox(height: 8),
                  Row(children: [
                    Expanded(child: KV('Qty (${l.uom})', fmt(l.qty))),
                    Expanded(child: KV('Qty 2 (Karung)', fmt(l.qty2))),
                    Expanded(child: KV('Qty Palet', fmt(l.qtyPalet))),
                  ]),
                ]),
              ),
              const SizedBox(height: 10),
            ],
            TotalsBar([('Total KG', fmt(d.totalKg)), ('Total karung', fmt(d.totalSak)), ('Total palet', fmt(d.totalPalet))]),
          ]),
        ),
        Footer(children: [
          Text.rich(
            const TextSpan(children: [
              TextSpan(text: 'Tersimpan sebagai '),
              TextSpan(text: 'Menunggu PT', style: TextStyle(fontWeight: FontWeight.w700, color: C.amberText)),
              TextSpan(text: ' · label QR bisa dicetak setelah Admin mengisi PT di CMS'),
            ]),
            textAlign: TextAlign.center,
            style: const TextStyle(fontSize: 12, color: C.muted),
          ),
          BigButton(label: 'Simpan & kirim ke Admin', color: C.inbound, icon: Icons.check, busy: _busy, onPressed: _save),
        ]),
      ]),
    );
  }
}
