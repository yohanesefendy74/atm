import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

import '../api.dart';
import '../models.dart';
import '../theme.dart';
import '../widgets.dart';
import 'doc_list.dart';

class OutboundListScreen extends StatelessWidget {
  const OutboundListScreen({super.key});
  @override
  Widget build(BuildContext context) => DocList(
        kind: 'outbound',
        accent: C.outbound,
        eyebrow: 'Outbound',
        title: 'Pengeluaran Barang',
        filters: const ['Menunggu DO', 'Menunggu PT', 'Siap cetak', 'Selesai'],
        newScreen: (_) => const OutboundHeaderScreen(),
        note: 'Outbound dicatat tanpa DO. Label Item Inbound (KR/RP) bisa dicetak setelah Admin mengisi PT.',
      );
}

const _steps = ['Header', 'Scan palet', 'Simpan'];

/// Langkah 1: Warehouse (paling atas) lalu Jenis transaksi.
/// Warehouse titipan -> otomatis BT, KR & RP tidak tersedia.
class OutboundHeaderScreen extends StatefulWidget {
  const OutboundHeaderScreen({super.key});
  @override
  State<OutboundHeaderScreen> createState() => _OutboundHeaderScreenState();
}

class _OutboundHeaderScreenState extends State<OutboundHeaderScreen> {
  final _draft = OutboundDraft();
  final _mobil = TextEditingController();
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
    super.dispose();
  }

  bool _check() {
    if (_draft.warehouse == null) {
      showError(context, 'Pilih warehouse');
      return false;
    }
    if (_draft.jenis == 'OB' && _mobil.text.trim().isEmpty) {
      showError(context, 'No. mobil wajib diisi');
      return false;
    }
    _draft.noMobil = _mobil.text.trim().toUpperCase();
    return true;
  }

  Future<void> _push(Widget page) async {
    if (!_check()) return;
    await Navigator.of(context).push(MaterialPageRoute(builder: (_) => page));
    if (mounted) setState(() {});
  }

  String get _hint {
    if (_draft.isTitipan) return 'Warehouse titipan: otomatis BT · KR & RP tidak tersedia';
    return _draft.jenis == 'OB' ? 'Scan palet keluar' : 'Scan palet keluar dan tambah Item Inbound';
  }

  Widget _jenisButton(String key, String code, String label) {
    final off = _draft.isTitipan && key != 'OB';
    final on = (_draft.isTitipan ? 'OB' : _draft.jenis) == key;
    final fg = on ? Colors.white : (off ? C.disabled : C.ink);
    final deco = off ? TextDecoration.lineThrough : null;
    return Expanded(
      child: Material(
        color: on ? C.ink : Colors.transparent,
        borderRadius: BorderRadius.circular(9),
        child: InkWell(
          borderRadius: BorderRadius.circular(9),
          onTap: off ? null : () => setState(() => _draft.jenis = key),
          child: SizedBox(
            height: 48,
            child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
              Text(code, style: TextStyle(fontFamily: mono, fontSize: 12, fontWeight: FontWeight.w700, color: fg, decoration: deco)),
              Text(label, style: TextStyle(fontSize: 12, color: fg, decoration: deco)),
            ]),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final t = _draft.isTitipan;
    return Scaffold(
      body: Column(children: [
        const Header(
          eyebrow: 'Outbound baru',
          title: 'Data Header',
          accent: C.outbound,
          bottom: Steps(labels: _steps, current: 0, accent: C.outbound),
        ),
        Expanded(
          child: _error != null
              ? ErrorView(_error!, onRetry: _load)
              : ListView(padding: const EdgeInsets.all(20), children: [
                  const FieldLabel('Warehouse', required: true),
                  WarehouseField(
                    items: _whs,
                    value: _draft.warehouse,
                    onChanged: (w) => setState(() {
                      _draft.warehouse = w;
                      if (w.isTitipan) _draft.jenis = 'OB';
                    }),
                  ),
                  const Hint('Daftar sesuai hak akses akun Anda'),
                  const SizedBox(height: 18),
                  const FieldLabel('Jenis transaksi', required: true),
                  Container(
                    padding: const EdgeInsets.all(4),
                    decoration: BoxDecoration(color: C.lineSoft, borderRadius: BorderRadius.circular(12)),
                    child: Row(children: [
                      _jenisButton('OB', t ? 'BT' : 'OB', t ? 'Titipan' : 'Outbound'),
                      _jenisButton('KR', 'KR', 'Penyesuaian'),
                      _jenisButton('RP', 'RP', 'Repacking'),
                    ]),
                  ),
                  Hint(_hint),
                  const SizedBox(height: 18),
                  FieldLabel('No. Mobil', required: _draft.jenis == 'OB'),
                  TextField(
                    controller: _mobil,
                    inputFormatters: [upperCase],
                    style: const TextStyle(fontFamily: mono, fontSize: 17, fontWeight: FontWeight.w600, letterSpacing: 0.7),
                    decoration: const InputDecoration(hintText: 'B 9555 KLA'),
                  ),
                  const Hint('Nomor polisi kendaraan pengangkut'),
                  const SizedBox(height: 18),
                  Box(
                    color: C.outboundTint,
                    border: C.outboundTint,
                    padding: const EdgeInsets.all(14),
                    child: const Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Icon(Icons.view_week_outlined, color: Color(0xFF5C2306)),
                      SizedBox(width: 10),
                      Expanded(
                        child: Text('Container asal diisi otomatis dari QR palet pertama yang discan. 1 outbound = 1 container.',
                            style: TextStyle(color: Color(0xFF5C2306), fontSize: 13)),
                      ),
                    ]),
                  ),
                  const SizedBox(height: 18),
                  Box(
                    child: Row(children: [
                      Expanded(child: KV('Tanggal', fmtDate(_draft.date), monoValue: false)),
                      Expanded(child: KV('Petugas', Session.I.userName, monoValue: false)),
                    ]),
                  ),
                ]),
        ),
        Footer(children: [
          if (_draft.isAdj)
            BigButton(
              label: _draft.inLines.isEmpty ? 'Item Inbound' : 'Item Inbound (${_draft.inLines.length} baris)',
              color: C.green,
              outlined: true,
              icon: Icons.add,
              onPressed: () => _push(OutboundAddItemScreen(draft: _draft)),
            ),
          BigButton(label: 'Lanjut scan palet', color: C.outbound, icon: Icons.chevron_right, onPressed: () => _push(OutboundScanScreen(draft: _draft))),
        ]),
      ]),
    );
  }
}

/// Item Inbound untuk KR / RP: form seperti inbound, baris masuk ke stok (+).
class OutboundAddItemScreen extends StatefulWidget {
  const OutboundAddItemScreen({super.key, required this.draft});
  final OutboundDraft draft;
  @override
  State<OutboundAddItemScreen> createState() => _OutboundAddItemScreenState();
}

class _OutboundAddItemScreenState extends State<OutboundAddItemScreen> {
  String? _ruang;

  @override
  Widget build(BuildContext context) {
    final d = widget.draft;
    return Scaffold(
      body: Column(children: [
        Header(
          eyebrow: d.jenisLabel,
          title: 'Item Inbound',
          accent: C.outbound,
          bottom: Wrap(spacing: 6, children: [
            Pill(d.warehouse?.code ?? '-', bg: C.ground, fg: C.ink, monoFont: true),
            if (d.containerNo != null) Pill(d.containerNo!, bg: C.ground, fg: C.ink, monoFont: true),
          ]),
        ),
        Expanded(
          child: ListView(padding: const EdgeInsets.all(20), children: [
            RuanganField(whs: d.warehouse!.code, value: _ruang, titipan: false, label: 'Ruangan tujuan (item masuk)', onChanged: (v) => setState(() => _ruang = v)),
            const SizedBox(height: 12),
            LineForm(
              accent: C.green,
              sakLabel: 'Sak',
              onAdd: (l) {
                if (_ruang == null) return showError(context, 'Pilih ruangan tujuan dulu');
                setState(() => d.inLines.add(l.withRuangan(_ruang)));
              },
            ),
            const SizedBox(height: 16),
            Text('Item Inbound · ${d.inLines.length} baris', style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
            const SizedBox(height: 8),
            for (var i = 0; i < d.inLines.length; i++) ...[
              LineTile(d.inLines[i],
                  sakLabel: 'sak',
                  badge: Pill('MASUK · ${d.inLines[i].kodeRuangan ?? '-'}', bg: C.greenTint, fg: C.greenText),
                  onDelete: () => setState(() => d.inLines.removeAt(i))),
              const SizedBox(height: 8),
            ],
            const Hint('Label QR Item Inbound bisa dicetak setelah Admin mengisi PT di CMS.'),
          ]),
        ),
        Footer(children: [
          Row(children: [
            Expanded(child: BigButton(label: 'Kembali', outlined: true, onPressed: () => Navigator.of(context).pop())),
            const SizedBox(width: 10),
            Expanded(
              child: BigButton(
                label: 'Lanjut scan palet',
                color: C.outbound,
                onPressed: () => Navigator.of(context).pushReplacement(MaterialPageRoute(builder: (_) => OutboundScanScreen(draft: d))),
              ),
            ),
          ]),
        ]),
      ]),
    );
  }
}

/// Langkah 2: scan QR palet (yymmdd-itemcode-container). Bisa keluar utuh atau sebagian.
class OutboundScanScreen extends StatefulWidget {
  const OutboundScanScreen({super.key, required this.draft});
  final OutboundDraft draft;
  @override
  State<OutboundScanScreen> createState() => _OutboundScanScreenState();
}

class _OutboundScanScreenState extends State<OutboundScanScreen> {
  final _scanner = MobileScannerController(detectionSpeed: DetectionSpeed.normal);
  // Semua palet satu item+container memakai QR yang sama, jadi kamera tidak menghitung terus-menerus:
  // setelah 1 palet terbaca, krani menekan "Scan palet berikutnya" untuk membaca palet lain.
  bool _armed = true;
  bool _busy = false;
  int _selected = -1;

  @override
  void initState() {
    super.initState();
    _selected = widget.draft.pallets.length - 1;
  }

  @override
  void dispose() {
    _scanner.dispose();
    super.dispose();
  }

  void _onDetect(BarcodeCapture cap) {
    final raw = cap.barcodes.isEmpty ? null : cap.barcodes.first.rawValue;
    if (raw == null || raw.isEmpty || _busy || !_armed) return;
    setState(() => _armed = false);
    _add(raw);
  }

  Future<void> _add(String qr) async {
    final d = widget.draft;
    setState(() => _busy = true);
    try {
      final p = ScannedPallet.fromJson(await Api.pallet(qr.trim(), d.warehouse!.code));
      if (d.containerNo != null && d.containerNo != p.containerNo) {
        throw ApiException('QR container lain ditolak. Outbound ini untuk container ${d.containerNo}.');
      }
      if (!mounted) return;
      if (p.rooms.length > 1) {
        final r = await pilihRuanganSumber(context, p);
        if (r == null) return;
        p.kodeRuangan = r;
      }
      if (!mounted) return;
      d.containerNo ??= p.containerNo;
      final already = d.pallets.where((x) => x.itemCode == p.itemCode).length;
      setState(() {
        d.pallets.add(p);
        _selected = d.pallets.length - 1;
      });
      if (mounted) {
        final stockPalet = p.stockSak > 0 && p.sakPerPalet > 0 ? (p.stockSak / p.sakPerPalet).ceil() : 0;
        if (stockPalet > 0 && already + 1 > stockPalet) {
          showInfo(context, 'Perhatian: stok ${p.itemCode} di container ini sekitar $stockPalet palet');
        } else {
          showInfo(context, '${p.itemCode} · palet ke-${already + 1} ditambahkan');
        }
      }
    } catch (e) {
      if (mounted) showError(context, e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _manual() async {
    final ctl = TextEditingController();
    final qr = await showDialog<String>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('Input QR manual'),
        content: TextField(
          controller: ctl,
          autofocus: true,
          inputFormatters: [upperCase],
          decoration: const InputDecoration(hintText: '261009-GLA-001-TGHU8812345'),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.of(c).pop(), child: const Text('Batal')),
          FilledButton(onPressed: () => Navigator.of(c).pop(ctl.text), child: const Text('Tambah')),
        ],
      ),
    );
    ctl.dispose();
    if (qr != null && qr.trim().isNotEmpty) _add(qr);
  }

  @override
  Widget build(BuildContext context) {
    final d = widget.draft;
    final pallets = d.pallets;
    final sel = _selected >= 0 && _selected < pallets.length ? pallets[_selected] : null;
    final inPalet = d.inLines.fold<double>(0, (s, l) => s + l.qtyPalet);

    return Scaffold(
      backgroundColor: const Color(0xFF0E1013),
      body: Column(children: [
        SizedBox(
          height: 260 + MediaQuery.of(context).padding.top,
          child: Stack(children: [
            Positioned.fill(child: MobileScanner(controller: _scanner, onDetect: _onDetect)),
            Positioned.fill(child: Container(color: Colors.black26)),
            Center(
              child: Container(
                width: 180,
                height: 140,
                decoration: BoxDecoration(border: Border.all(color: Colors.white, width: 3), borderRadius: BorderRadius.circular(14)),
              ),
            ),
            Positioned(
              top: MediaQuery.of(context).padding.top + 8,
              left: 8,
              right: 12,
              child: Row(children: [
                IconButton(onPressed: () => Navigator.of(context).pop(), icon: const Icon(Icons.chevron_left, color: Colors.white, size: 28)),
                Expanded(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text('Langkah 2 dari 3 · ${d.jenisLabel}', style: const TextStyle(color: Color(0xFFB8BEC6), fontSize: 12)),
                    const Text('Scan palet keluar', style: TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.w600)),
                  ]),
                ),
                IconButton(
                  tooltip: 'Senter',
                  onPressed: () => _scanner.toggleTorch(),
                  icon: const Icon(Icons.flashlight_on_outlined, color: Colors.white),
                ),
                IconButton(
                  tooltip: 'Input QR manual',
                  onPressed: _manual,
                  icon: const Icon(Icons.keyboard_outlined, color: Colors.white),
                ),
              ]),
            ),
            Positioned(
              left: 0,
              right: 0,
              bottom: 10,
              child: Text(
                !_armed
                    ? 'Palet terbaca · tekan "Scan palet berikutnya"'
                    : (d.containerNo == null ? 'Arahkan kamera ke QR palet' : 'Container ${d.containerNo} · QR container lain ditolak'),
                textAlign: TextAlign.center,
                style: const TextStyle(color: Color(0xFFD5DAE0), fontSize: 13),
              ),
            ),
            if (_busy) const Positioned(left: 0, right: 0, top: 0, child: LinearProgressIndicator(minHeight: 3)),
          ]),
        ),
        Expanded(
          child: Container(
            decoration: const BoxDecoration(color: Colors.white, borderRadius: BorderRadius.vertical(top: Radius.circular(24))),
            child: ListView(padding: const EdgeInsets.all(20), children: [
              if (sel != null)
                _PalletEditor(
                  key: ObjectKey(sel),
                  pallet: sel,
                  index: pallets.where((x) => x.itemCode == sel.itemCode).toList().indexOf(sel) + 1,
                  onChanged: () => setState(() {}),
                  onDelete: () => setState(() {
                    pallets.remove(sel);
                    if (pallets.isEmpty) d.containerNo = null;
                    _selected = pallets.length - 1;
                  }),
                )
              else
                const Padding(
                  padding: EdgeInsets.symmetric(vertical: 24),
                  child: Text('Belum ada palet. Scan QR label palet.', textAlign: TextAlign.center, style: TextStyle(color: C.muted)),
                ),
              const SizedBox(height: 14),
              Row(children: [
                Expanded(
                  child: Text.rich(TextSpan(children: [
                    const TextSpan(text: 'Keluar', style: TextStyle(fontWeight: FontWeight.w700, color: Color(0xFF8A2E08))),
                    TextSpan(text: ' · ${pallets.length} palet'),
                  ])),
                ),
                if (d.isAdj)
                  Text.rich(TextSpan(children: [
                    const TextSpan(text: 'Item Inbound', style: TextStyle(fontWeight: FontWeight.w700, color: C.greenText)),
                    TextSpan(text: ' · ${d.inLines.length} item · ${fmt(inPalet)} palet'),
                  ])),
              ]),
              const SizedBox(height: 8),
              for (var i = 0; i < pallets.length; i++)
                ListTile(
                  dense: true,
                  selected: i == _selected,
                  selectedTileColor: C.outboundTint,
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                  onTap: () => setState(() => _selected = i),
                  title: Text('${pallets[i].itemCode}${pallets[i].partial ? ' · sebagian' : ''}',
                      style: const TextStyle(fontFamily: mono, fontWeight: FontWeight.w600, color: C.ink)),
                  trailing: Text('${fmt(pallets[i].sak)} krg · ${fmt(pallets[i].kg)} KG',
                      style: const TextStyle(fontFamily: mono, fontSize: 13, color: C.ink)),
                ),
              const SizedBox(height: 10),
              TotalsBar([('Total palet', '${pallets.length}'), ('Total KG', fmt(d.totalKg)), ('Total karung', fmt(d.totalSak))]),
            ]),
          ),
        ),
        Container(
          color: Colors.white,
          child: Footer(children: [
            if (!_armed)
              BigButton(
                label: 'Scan palet berikutnya',
                color: C.ink,
                outlined: true,
                icon: Icons.qr_code_scanner,
                onPressed: _busy ? null : () => setState(() => _armed = true),
              ),
            BigButton(
              label: 'Selesai scan · Ringkasan',
              color: C.outbound,
              onPressed: pallets.isEmpty
                  ? null
                  : () async {
                      await Navigator.of(context).push(MaterialPageRoute(builder: (_) => OutboundSummaryScreen(draft: d)));
                      if (mounted) setState(() {});
                    },
            ),
          ]),
        ),
      ]),
    );
  }
}

/// Edit palet yang dipilih: keluar utuh / sebagian, jumlah karung, KG (bisa diubah karena susut).
class _PalletEditor extends StatefulWidget {
  const _PalletEditor({super.key, required this.pallet, required this.index, required this.onChanged, required this.onDelete});
  final ScannedPallet pallet;
  final int index;
  final VoidCallback onChanged;
  final VoidCallback onDelete;
  @override
  State<_PalletEditor> createState() => _PalletEditorState();
}

class _PalletEditorState extends State<_PalletEditor> {
  late final TextEditingController _kg = TextEditingController(text: _kgText());

  String _kgText() {
    final v = widget.pallet.kg;
    return v == v.roundToDouble() ? v.toInt().toString() : v.toStringAsFixed(2);
  }

  @override
  void dispose() {
    _kg.dispose();
    super.dispose();
  }

  void _setSak(double v) {
    final p = widget.pallet;
    p.sak = v.clamp(1, p.sakPerPalet > 0 ? p.sakPerPalet : 9999).toDouble();
    p.kgManual = null;
    _kg.text = _kgText();
    setState(() {});
    widget.onChanged();
  }

  @override
  Widget build(BuildContext context) {
    final p = widget.pallet;
    final diff = p.kgManual == null ? 0 : p.kg - p.kgAuto;
    return Box(
      border: C.ink,
      padding: const EdgeInsets.all(14),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Row(children: [
          const CircleAvatar(radius: 16, backgroundColor: C.green, child: Icon(Icons.check, color: Colors.white, size: 18)),
          const SizedBox(width: 10),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text('${p.itemCode} · palet ke-${widget.index}', style: const TextStyle(fontFamily: mono, fontWeight: FontWeight.w600, fontSize: 15)),
              Text('QR ${p.qr}', style: const TextStyle(fontFamily: mono, fontSize: 11, color: C.muted)),
              Text('Isi palet: ${fmt(p.sakPerPalet * p.kgPerSak)} KG · ${fmt(p.sakPerPalet)} krg',
                  style: const TextStyle(fontSize: 12, color: C.muted)),
            ]),
          ),
          OutlinedButton(onPressed: widget.onDelete, child: const Text('Batalkan')),
        ]),
        const SizedBox(height: 12),
        if (p.rooms.isEmpty)
          const Hint('Stok item ini di container tersebut belum punya ruangan. Minta Admin mengisi ruangan stok lama dulu.', color: C.outbound)
        else
          DropdownButtonFormField<String>(
            value: p.kodeRuangan,
            decoration: const InputDecoration(labelText: 'Ruangan sumber'),
            items: [
              for (final r in p.rooms)
                DropdownMenuItem(value: r['kodeRuangan']?.toString(), child: Text('${r['kodeRuangan'] ?? '-'} · stok ${fmt(toD(r['stockKg']))} kg · ${fmt(toD(r['stockSak']))} krg')),
            ],
            onChanged: (v) {
              setState(() => p.kodeRuangan = v);
              widget.onChanged();
            },
          ),
        const SizedBox(height: 12),
        SegmentedButton<bool>(
          segments: const [
            ButtonSegment(value: false, label: Text('Keluar utuh')),
            ButtonSegment(value: true, label: Text('Keluar sebagian')),
          ],
          selected: {p.partial},
          showSelectedIcon: false,
          onSelectionChanged: (v) {
            p.partial = v.first;
            _setSak(p.partial ? (p.sakPerPalet > 1 ? p.sakPerPalet - 1 : 1) : p.sakPerPalet);
          },
        ),
        if (p.partial) ...[
          const SizedBox(height: 12),
          Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                const FieldLabel('Qty 2 (Karung)'),
                Row(children: [
                  IconButton.outlined(onPressed: () => _setSak(p.sak - 1), icon: const Icon(Icons.remove)),
                  Expanded(
                    child: Text(fmt(p.sak), textAlign: TextAlign.center, style: const TextStyle(fontFamily: mono, fontSize: 20, fontWeight: FontWeight.w600)),
                  ),
                  IconButton.filled(
                    style: IconButton.styleFrom(backgroundColor: C.outbound),
                    onPressed: () => _setSak(p.sak + 1),
                    icon: const Icon(Icons.add),
                  ),
                ]),
              ]),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                const FieldLabel('Qty (KG)'),
                TextField(
                  controller: _kg,
                  keyboardType: const TextInputType.numberWithOptions(decimal: true),
                  style: const TextStyle(fontFamily: mono, fontSize: 18, fontWeight: FontWeight.w600),
                  onChanged: (v) {
                    final n = double.tryParse(v.replaceAll(',', '.'));
                    p.kgManual = (n == null || n == p.kgAuto) ? null : n;
                    setState(() {});
                    widget.onChanged();
                  },
                ),
              ]),
            ),
          ]),
          const SizedBox(height: 8),
          Row(children: [
            Expanded(
              child: Text(
                p.kgManual == null
                    ? 'Otomatis dari karung: ${fmt(p.sak)} × ${fmt(p.kgPerSak)} KG'
                    : 'Diubah manual · selisih ${diff > 0 ? '+' : ''}${fmt(diff)} KG dari otomatis',
                style: const TextStyle(fontSize: 12, color: C.muted),
              ),
            ),
            if (p.kgManual != null)
              TextButton(
                onPressed: () {
                  p.kgManual = null;
                  _kg.text = _kgText();
                  setState(() {});
                  widget.onChanged();
                },
                child: const Text('Pakai otomatis'),
              ),
          ]),
          const SizedBox(height: 8),
          Box(
            color: C.amberTint,
            border: C.amberTint,
            radius: 10,
            padding: const EdgeInsets.all(12),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Row(children: [
                const Expanded(child: Text('Sisa di palet', style: TextStyle(fontWeight: FontWeight.w600, color: Color(0xFF5C3F00)))),
                Text('${fmt(p.sisaKg)} KG · ${fmt(p.sisaSak)} krg',
                    style: const TextStyle(fontFamily: mono, fontWeight: FontWeight.w600, color: Color(0xFF5C3F00))),
              ]),
              const Text('Tercatat di sistem · label QR tetap dipakai', style: TextStyle(fontSize: 11, color: Color(0xFF5C3F00))),
            ]),
          ),
        ],
      ]),
    );
  }
}

/// Langkah 3: ringkasan & simpan.
class OutboundSummaryScreen extends StatefulWidget {
  const OutboundSummaryScreen({super.key, required this.draft});
  final OutboundDraft draft;
  @override
  State<OutboundSummaryScreen> createState() => _OutboundSummaryScreenState();
}

class _OutboundSummaryScreenState extends State<OutboundSummaryScreen> {
  bool _busy = false;

  Future<void> _save() async {
    final d = widget.draft;
    if (d.pallets.any((p) => p.kodeRuangan == null)) return showError(context, 'Pilih ruangan sumber untuk setiap palet');
    setState(() => _busy = true);
    try {
      final r = await Api.saveOutbound(d.toJson());
      if (!mounted) return;
      final next = d.isAdj && d.inLines.isNotEmpty
          ? 'Status: Menunggu PT. Label Item Inbound bisa dicetak dari daftar Outbound setelah Admin mengisi PT.'
          : 'Status: Menunggu DO. Customer & No DO diisi Admin di CMS.';
      await showDialog<void>(
        context: context,
        builder: (c) => AlertDialog(
          title: const Text('Outbound tersimpan'),
          content: Text('No. ${r['docEntry']} (${r['trxCode']}).\n\n$next'),
          actions: [FilledButton(onPressed: () => Navigator.of(c).pop(), child: const Text('OK'))],
        ),
      );
      if (mounted) Navigator.of(context).popUntil((route) => route.isFirst);
    } catch (e) {
      if (mounted) showError(context, e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final d = widget.draft;
    final lines = d.outLines();
    final adjIn = d.isAdj && d.inLines.isNotEmpty;
    final btn = switch (d.trxCode) {
      'RP' => 'Simpan repacking & kirim ke Admin',
      'KR' => 'Simpan penyesuaian & kirim ke Admin',
      _ => 'Simpan outbound · ${d.pallets.length} palet',
    };
    final note = adjIn
        ? '${d.trxCode} · Menunggu PT · label Item Inbound dicetak setelah Admin mengisi PT'
        : 'Tersimpan sebagai Menunggu DO · No DO di-assign di CMS';

    return Scaffold(
      body: Column(children: [
        Header(eyebrow: 'Langkah 3 dari 3 · ${d.jenisLabel}', title: 'Ringkasan Outbound', accent: C.outbound),
        Expanded(
          child: ListView(padding: const EdgeInsets.all(20), children: [
            Box(
              child: Row(children: [
                Expanded(child: KV('WAREHOUSE', d.warehouse?.code ?? '-')),
                Expanded(child: KV('NO. MOBIL', d.noMobil.isEmpty ? '-' : d.noMobil)),
                Expanded(child: KV('CONTAINER ASAL', d.containerNo ?? '-')),
              ]),
            ),
            const SizedBox(height: 16),
            Text('Barang keluar · ${lines.length} item', style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600)),
            const SizedBox(height: 8),
            for (final l in lines) ...[
              Box(
                padding: const EdgeInsets.all(14),
                radius: 14,
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Row(children: [
                    Expanded(child: Text('${l['itemCode']}', style: const TextStyle(fontFamily: mono, fontSize: 15, fontWeight: FontWeight.w600))),
                    const Pill('KELUAR', bg: C.outboundTint, fg: C.outbound),
                  ]),
                  Text([l['itemName'], l['brand'], l['origin']].where((v) => v != null).join(' · '),
                      style: const TextStyle(fontSize: 13, color: C.muted)),
                  if ((l['partial'] as int) > 0) ...[
                    const SizedBox(height: 6),
                    Pill('${toI(l['qtyPalet']) - (l['partial'] as int)} utuh + ${l['partial']} sebagian', bg: C.amberTint, fg: const Color(0xFF5C3F00)),
                  ],
                  const SizedBox(height: 8),
                  Row(children: [
                    Expanded(child: KV('Qty (KG)', fmt(toD(l['qty'])))),
                    Expanded(child: KV('Qty 2 (Karung)', fmt(toD(l['qty2'])))),
                    Expanded(child: KV('Qty Palet', fmt(toD(l['qtyPalet'])))),
                  ]),
                ]),
              ),
              const SizedBox(height: 10),
            ],
            if (d.isAdj) ...[
              Text('Item Inbound · ${d.inLines.length} item', style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600)),
              const SizedBox(height: 8),
              if (d.inLines.isEmpty) const Text('Tidak ada item masuk', style: TextStyle(color: C.muted)),
              for (final l in d.inLines) ...[
                LineTile(l, sakLabel: 'sak', badge: const Pill('MASUK', bg: C.greenTint, fg: C.greenText)),
                const SizedBox(height: 8),
              ],
            ],
          ]),
        ),
        Footer(children: [
          Text(note, textAlign: TextAlign.center, style: const TextStyle(fontSize: 12, color: C.muted)),
          BigButton(label: btn, color: C.outbound, icon: Icons.local_shipping_outlined, busy: _busy, onPressed: _save),
        ]),
      ]),
    );
  }
}


/// Satu container bisa tersebar di beberapa ruangan: krani memilih ruangan SUMBER palet ini.
Future<String?> pilihRuanganSumber(BuildContext context, ScannedPallet p) => showModalBottomSheet<String>(
      context: context,
      builder: (c) => SafeArea(
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 16, 20, 8),
            child: Text('Ruangan sumber · ${p.itemCode}', style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w700)),
          ),
          const Padding(padding: EdgeInsets.symmetric(horizontal: 20), child: Text('Barang dari container ini ada di beberapa ruangan. Pilih asal palet yang discan.', style: TextStyle(color: C.muted))),
          for (final r in p.rooms)
            ListTile(
              title: Text('${r['kodeRuangan'] ?? '-'}${r['namaRuangan'] != null ? ' · ${r['namaRuangan']}' : ''}'),
              subtitle: Text('Stok ${fmt(toD(r['stockKg']))} kg · ${fmt(toD(r['stockSak']))} karung'),
              onTap: () => Navigator.of(c).pop(r['kodeRuangan']?.toString()),
            ),
          const SizedBox(height: 8),
        ]),
      ),
    );
