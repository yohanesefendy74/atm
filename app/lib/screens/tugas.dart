import 'package:flutter/material.dart';

import '../api.dart';
import '../theme.dart';
import '../widgets.dart';
import 'pos_timbang.dart';

/// Tugas krani: dokumen SPBB/SPMB yang ditugaskan Admin.
class TugasScreen extends StatefulWidget {
  const TugasScreen({super.key, this.embedded = false});
  final bool embedded;
  @override
  State<TugasScreen> createState() => _TugasScreenState();
}

class _TugasScreenState extends State<TugasScreen> {
  List<Map<String, dynamic>> _rows = [];
  String? _error;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final r = await Api.get('/api/plan/saya') as List;
      if (mounted) setState(() => _rows = r.map((e) => Map<String, dynamic>.from(e as Map)).toList());
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Material(color: C.ground, child: 
Column(children: [
        Header(title: 'Tugas Saya', eyebrow: 'Bongkar · Muat', back: !widget.embedded),
        Expanded(
          child: RefreshIndicator(
            onRefresh: _load,
            child: ListView(padding: const EdgeInsets.all(16), children: [
              if (_loading) const LinearProgressIndicator(minHeight: 2),
              if (_error != null) ErrorView(_error!, onRetry: _load),
              if (!_loading && _error == null && _rows.isEmpty) const Padding(padding: EdgeInsets.all(32), child: Center(child: Text('Belum ada tugas', style: TextStyle(color: C.muted)))),
              for (final p in _rows)
                Padding(
                  padding: const EdgeInsets.only(bottom: 10),
                  child: Box(
                    onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => TugasDetail(planId: toI(p['planId'])))).then((_) => _load()),
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Row(children: [
                        Expanded(child: Text('${p['planNo']}', style: const TextStyle(fontWeight: FontWeight.w700, fontFamily: mono))),
                        if (p['titipan'] == true) const Pill('Titipan', bg: C.amberTint, fg: C.amberText),
                        const SizedBox(width: 6),
                        Pill('${p['status']}'),
                      ]),
                      const SizedBox(height: 4),
                      Text('${p['cardName'] ?? '-'} · ${p['whsCode']}', style: const TextStyle(color: C.muted)),
                      Text('Realisasi ${toD(p['qtyDone']).toStringAsFixed(0)} / ${toD(p['qtyPlan']).toStringAsFixed(0)} kg'
                          '${p['etaDatang'] != null ? ' · ETA ${p['etaDatang']}' : ''}${p['dockCode'] != null ? ' · ${p['dockCode']}' : ''}',
                          style: const TextStyle(fontSize: 13)),
                    ]),
                  ),
                ),
            ]),
          ),
        ),
      ]),
    );
  }
}

class TugasDetail extends StatefulWidget {
  const TugasDetail({super.key, required this.planId});
  final int planId;
  @override
  State<TugasDetail> createState() => _TugasDetailState();
}

class _TugasDetailState extends State<TugasDetail> {
  Map<String, dynamic>? _h;
  List<Map<String, dynamic>> _lines = [];
  List<Map<String, dynamic>> _ruang = [];
  List<Map<String, dynamic>> _veh = [];
  // isian per baris dokumen; SPMB boleh beberapa isian per baris (PT berbeda, boleh campur)
  final _entries = <_Entry>[];
  int? _regId;
  // SPBB: kontainer di dock + sampling berat per barang
  List<Map<String, dynamic>> _kont = [];
  int? _sesiId;
  List<Map<String, dynamic>> _kItems = [];
  String? _kStatus;
  List<Map<String, dynamic>> _sampel = [];
  String? _error;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final r = Map<String, dynamic>.from(await Api.get('/api/plan/${widget.planId}') as Map);
      final h = Map<String, dynamic>.from(r['header'] as Map);
      final lines = (r['lines'] as List).map((e) => Map<String, dynamic>.from(e as Map)).toList();
      final whs = h['whsCode'].toString();
      final ruang = (await Api.get('/api/master/ruangan', {'whs': whs}) as List).map((e) => Map<String, dynamic>.from(e as Map)).toList();
      final veh = (await Api.get('/api/kendaraan', {'whs': whs}) as List)
          .map((e) => Map<String, dynamic>.from(e as Map))
          .where((v) => v['planNo'] == h['planNo'])
          .toList();
      var kont = <Map<String, dynamic>>[];
      if (h['jenis'] == 'SPBB') {
        kont = (await Api.get('/api/kontainer/dock', {'whs': whs}) as List)
            .map((e) => Map<String, dynamic>.from(e as Map))
            .where((k) => toI(k['planId']) == widget.planId)
            .toList();
      }
      if (!mounted) return;
      setState(() {
        _kont = kont;
        if (_sesiId == null && kont.length == 1) _sesiId = toI(kont.first['sesiId']);
        if (_sesiId != null && !kont.any((k) => toI(k['sesiId']) == _sesiId)) _sesiId = null;
        _h = h;
        _lines = lines;
        _ruang = ruang.where((x) => h['titipan'] == null || x['titipan'] == h['titipan']).toList();
        _veh = veh;
        if (veh.length == 1) _regId = toI(veh.first['regId']);
        for (final l in lines) {
          final k = toI(l['planLine']);
          if (!_entries.any((e) => e.planLine == k)) _entries.add(_Entry(k, l['kodeRuangan']?.toString() ?? h['kodeRuangan']?.toString()));
        }
      });
      if (_sesiId != null) await _loadKont();
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    }
  }

  Future<void> _loadKont() async {
    if (_sesiId == null) return;
    final r = Map<String, dynamic>.from(await Api.get('/api/kontainer/$_sesiId') as Map);
    if (!mounted) return;
    setState(() {
      _kStatus = (r['header'] as Map)['status']?.toString();
      _kItems = (r['items'] as List).map((e) => Map<String, dynamic>.from(e as Map)).toList();
      _sampel = ((r['sampel'] as List?) ?? const []).map((e) => Map<String, dynamic>.from(e as Map)).toList();
    });
  }

  /// Timbang 1 karung (boleh berkali-kali per barang). Hanya untuk rata-rata kg/karung, tidak ikut dihitung.
  Future<void> _timbangSampel(Map<String, dynamic> item) async {
    Berat? b;
    final ok = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      builder: (c) => Padding(
        padding: EdgeInsets.fromLTRB(16, 16, 16, 16 + MediaQuery.of(c).viewInsets.bottom),
        child: StatefulBuilder(
          builder: (c, set) => Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Text('Sampel 1 karung · ${item['itemCode']}', style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w700)),
            const SizedBox(height: 4),
            const Text('Taruh SATU karung di timbangan. Sampel hanya untuk rata-rata berat per karung.', style: TextStyle(color: C.muted)),
            const SizedBox(height: 12),
            BeratField(whs: _h!['whsCode'].toString(), alat: 'PALET', manualPerluAdmin: false, onChanged: (v) => set(() => b = v)),
            const SizedBox(height: 12),
            BigButton(label: 'Simpan sampel', onPressed: () => Navigator.of(c).pop(true)),
          ]),
        ),
      ),
    );
    if (ok != true) return;
    if (b == null) return showError(context, 'Baca berat karung dulu');
    if (b!.kg > 200) return showError(context, 'Berat ${b!.kg.toStringAsFixed(1)} kg terlalu besar untuk 1 karung');
    try {
      await Api.post('/api/kontainer/$_sesiId/sampel', {'planLine': toI(item['planLine']), 'kgSak': b!.kg, 'sumber': b!.sumber});
      await _loadKont();
    } catch (e) {
      if (mounted) showError(context, e);
    }
  }

  Future<void> _hapusSampel(int sampId) async {
    try {
      await Api.delete('/api/kontainer/$_sesiId/sampel/$sampId');
      await _loadKont();
    } catch (e) {
      if (mounted) showError(context, e);
    }
  }

  Future<void> _simpan() async {
    final spbb = _h?['jenis'] == 'SPBB';
    final items = <Map<String, dynamic>>[];
    for (final e in _entries) {
      final q = double.tryParse(e.qty.text.replaceAll(',', '.')) ?? 0;
      if (q <= 0) continue;
      if (!spbb && (e.pt ?? '').isEmpty) return showError(context, 'Pilih PT untuk setiap baris yang diisi');
      items.add({
        'planLine': e.planLine,
        'qty': q,
        'qty2': double.tryParse(e.sak.text.replaceAll(',', '.')) ?? 0,
        'qtyPalet': double.tryParse(e.pal.text.replaceAll(',', '.')) ?? 0,
        'kodeRuangan': e.room,
        'ptCode': spbb ? null : e.pt,
      });
    }
    if (spbb && _sesiId == null) return showError(context, 'Pilih kontainer yang sedang dibongkar');
    if (!spbb && _regId == null) return showError(context, 'Pilih kendaraan dulu (registrasi di pos timbang)');
    if (items.isEmpty) return showError(context, 'Isi qty minimal satu baris');
    setState(() => _busy = true);
    try {
      final r = await Api.post('/api/plan/${widget.planId}/simpan', {'regId': spbb ? null : _regId, 'sesiId': spbb ? _sesiId : null, 'lines': items});
      if (!mounted) return;
      showInfo(context, 'Tersimpan · penerimaan ke-${r['penerimaanKe']}');
      for (final e in _entries) {
        e.qty.clear();
        e.sak.clear();
        e.pal.clear();
      }
      _entries.removeWhere((e) => e.tambahan);
      await _load();
    } catch (e) {
      if (mounted) showError(context, e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _selesai() async {
    final spbb = _h?['jenis'] == 'SPBB';
    if (spbb ? _sesiId == null : _regId == null) return;
    setState(() => _busy = true);
    try {
      if (spbb) {
        await Api.post('/api/kontainer/$_sesiId/selesai-bongkar', {});
      } else {
        final ok = await Navigator.of(context).push<bool>(MaterialPageRoute(builder: (_) => PaletScreen(whs: _h!['whsCode'].toString(), regId: _regId!)));
        if (ok != true) return;
      }
      if (mounted) {
        showInfo(context, spbb ? 'Kontainer kosong · siap ditarik (timbang kepala lalu kepala + kontainer)' : 'Kendaraan boleh timbang keluar');
        Navigator.of(context).pop();
      }
    } catch (e) {
      if (mounted) showError(context, e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final h = _h;
    final spbb = h?['jenis'] == 'SPBB';
    return Scaffold(
      backgroundColor: C.ground,
      body: Column(children: [
        Header(title: h?['planNo']?.toString() ?? 'Dokumen', eyebrow: spbb ? 'Penerimaan (SPBB)' : 'Pengiriman (SPMB)', accent: spbb ? C.inbound : C.outbound),
        Expanded(
          child: h == null
              ? (_error != null ? ErrorView(_error!, onRetry: _load) : const Loading())
              : ListView(padding: const EdgeInsets.all(16), children: [
                  Box(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text('${h['cardName'] ?? '-'}', style: const TextStyle(fontWeight: FontWeight.w600)),
                    if (h['titipan'] == true) const Hint('Ruangan titipan · barang tidak boleh dicampur dengan non-titipan'),
                  ])),
                  const SizedBox(height: 12),
                  if (spbb) ...[
                    const FieldLabel('Kontainer', required: true),
                    if (_kont.isEmpty) const Hint('Belum ada kontainer untuk dokumen ini. Truk harus ditimbang masuk di Pos Timbang.', color: C.outbound),
                    DropdownButtonFormField<int>(
                      value: _sesiId,
                      items: [
                        for (final k in _kont)
                          DropdownMenuItem(value: toI(k['sesiId']), child: Text('${k['containerNo']} · ${_statusKont(k['status'])}')),
                      ],
                      onChanged: (v) {
                        setState(() {
                          _sesiId = v;
                          _kItems = [];
                          _sampel = [];
                        });
                        _loadKont();
                      },
                    ),
                    if (_kStatus == 'ISI_MASUK') const Hint('Kepala truk belum ditimbang (lepas kontainer). Input boleh, selesai bongkar setelah lepas.', color: C.amberText),
                  ] else ...[
                    const FieldLabel('Kendaraan', required: true),
                    if (_veh.isEmpty) const Hint('Belum ada kendaraan terdaftar untuk dokumen ini. Daftarkan dulu di Pos Timbang.', color: C.outbound),
                    DropdownButtonFormField<int>(
                      value: _regId,
                      items: [for (final v in _veh) DropdownMenuItem(value: toI(v['regId']), child: Text('${v['noPolisi']} · ${v['sopir']}'))],
                      onChanged: (v) => setState(() => _regId = v),
                    ),
                  ],
                  const SizedBox(height: 12),
                  for (final l in _lines) _lineCard(l, spbb),
                  if (spbb && _sesiId != null) _samplingCard(),
                ]),
        ),
        if (h != null)
          Footer(children: [
            BigButton(label: 'Simpan ${spbb ? 'penerimaan' : 'pengiriman'}', color: spbb ? C.inbound : C.outbound, busy: _busy, onPressed: _simpan),
            BigButton(
              label: spbb ? 'Selesai bongkar · kontainer kosong' : 'Selesai · kendaraan boleh keluar',
              outlined: true,
              color: C.ink,
              onPressed: (spbb ? _sesiId == null : _regId == null) || _busy ? null : _selesai,
            ),
          ]),
      ]),
    );
  }

  static String _statusKont(dynamic s) => switch (s) {
        'ISI_MASUK' => 'truk masih terpasang',
        'DI_DOCK' => 'di dock · dibongkar',
        'KOSONG' => 'sudah kosong',
        _ => '$s',
      };

  /// Sampel berat: timbang 1 karung per kali, boleh berkali-kali per barang. Hanya untuk rata-rata kg/karung (tidak ikut dihitung).
  Widget _samplingCard() {
    return Box(
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        const Text('Sampel berat per karung', style: TextStyle(fontWeight: FontWeight.w700)),
        const Hint('Timbang 1 karung per kali, boleh berkali-kali. Sampel hanya untuk rata-rata kg/karung; berat bersih kontainer dibagi ke tiap barang sesuai karung x rata-rata.'),
        const SizedBox(height: 8),
        if (_kItems.isEmpty) const Text('Simpan input barang dulu, lalu timbang sampel.', style: TextStyle(color: C.muted)),
        for (final i in _kItems) ...[
          Text('${i['itemCode']} · ${toD(i['sakTotal']).toStringAsFixed(0)} karung · ${toD(i['kgKrani']).toStringAsFixed(0)} kg', style: const TextStyle(fontWeight: FontWeight.w600)),
          Builder(builder: (_) {
            final list = _sampel.where((x) => toI(x['planLine']) == toI(i['planLine'])).toList();
            final avg = list.isEmpty ? 0.0 : list.fold<double>(0, (a, x) => a + toD(x['kgSak'])) / list.length;
            return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(list.isEmpty ? 'Belum ada sampel' : '${list.length} sampel · rata-rata ${avg.toStringAsFixed(2)} kg/karung',
                  style: TextStyle(fontSize: 13, color: list.isEmpty ? C.outbound : C.ink)),
              Wrap(spacing: 6, runSpacing: 4, children: [
                for (final x in list)
                  InputChip(
                    label: Text('${toD(x['kgSak']).toStringAsFixed(2)} kg'),
                    onDeleted: _busy ? null : () => _hapusSampel(toI(x['sampId'])),
                  ),
              ]),
              TextButton.icon(onPressed: () => _timbangSampel(i), icon: const Icon(Icons.scale_outlined), label: const Text('Timbang 1 karung')),
            ]);
          }),
          const SizedBox(height: 10),
        ],
      ]),
    );
  }

  Widget _lineCard(Map<String, dynamic> l, bool spbb) {
    final k = toI(l['planLine']);
    final sisa = toD(l['qtyOutstanding']);
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Box(
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('${l['itemCode']}', style: const TextStyle(fontWeight: FontWeight.w700)),
          Text('${l['dscription'] ?? ''}${l['containerNo'] != null ? ' · ${l['containerNo']}' : ''}', style: const TextStyle(color: C.muted, fontSize: 13)),
          Text('Rencana ${toD(l['qtyPlan']).toStringAsFixed(0)} · sudah ${toD(l['qtyDone']).toStringAsFixed(0)} · sisa ${sisa.toStringAsFixed(0)} kg', style: const TextStyle(fontSize: 13)),
          const SizedBox(height: 8),
          if (sisa <= 0)
            const Pill('Selesai', bg: C.greenTint, fg: C.greenText)
          else
            for (final e in _entries.where((e) => e.planLine == k)) ...[
              if (e.tambahan) const Divider(height: 20),
              Row(children: [
                Expanded(child: TextField(controller: e.qty, keyboardType: const TextInputType.numberWithOptions(decimal: true), decoration: const InputDecoration(labelText: 'Kg'))),
                const SizedBox(width: 8),
                Expanded(child: TextField(controller: e.sak, keyboardType: TextInputType.number, decoration: const InputDecoration(labelText: 'Karung'))),
                const SizedBox(width: 8),
                Expanded(child: TextField(controller: e.pal, keyboardType: const TextInputType.numberWithOptions(decimal: true), decoration: const InputDecoration(labelText: 'Palet'))),
                if (e.tambahan) IconButton(tooltip: 'Hapus', icon: const Icon(Icons.close), onPressed: () => setState(() => _entries.remove(e))),
              ]),
              if (!spbb) ...[
                const SizedBox(height: 8),
                PtField(value: e.pt, onChanged: (v) => setState(() => e.pt = v)),
              ],
              const SizedBox(height: 8),
              RuanganField(
                whs: _h!['whsCode'].toString(),
                value: e.room,
                titipan: _h!['titipan'] as bool?,
                label: spbb ? 'Ruangan tujuan' : 'Ruangan sumber',
                onChanged: (v) => setState(() => e.room = v),
              ),
            ],
          if (!spbb && sisa > 0)
            TextButton.icon(
              onPressed: () => setState(() => _entries.add(_Entry(k, l['kodeRuangan']?.toString() ?? _h!['kodeRuangan']?.toString(), tambahan: true))),
              icon: const Icon(Icons.add),
              label: const Text('Tambah baris PT lain'),
            ),
        ]),
      ),
    );
  }
}


/// Selesai muat: palet ikut tertimbang di truk, jadi krani menimbang SEMUA palet (boleh beberapa kali) lalu totalnya dikurangkan dari net.
class PaletScreen extends StatefulWidget {
  const PaletScreen({super.key, required this.whs, required this.regId});
  final String whs;
  final int regId;
  @override
  State<PaletScreen> createState() => _PaletScreenState();
}

class _PaletScreenState extends State<PaletScreen> {
  final _batch = <({int jumlah, double kg, String sumber})>[];
  final _jml = TextEditingController();
  Berat? _berat;
  Key _fieldKey = UniqueKey();
  bool _busy = false;

  int get _totalJml => _batch.fold(0, (a, b) => a + b.jumlah);
  double get _totalKg => _batch.fold(0.0, (a, b) => a + b.kg);

  void _tambah() {
    final j = int.tryParse(_jml.text.trim()) ?? 0;
    if (j <= 0) return showError(context, 'Isi jumlah palet yang sedang ditimbang');
    if (_berat == null) return showError(context, 'Baca berat palet dulu');
    setState(() {
      _batch.add((jumlah: j, kg: _berat!.kg, sumber: _berat!.sumber));
      _jml.clear();
      _berat = null;
      _fieldKey = UniqueKey();
    });
  }

  Future<void> _simpan({bool tanpaPalet = false}) async {
    if (!tanpaPalet && _batch.isEmpty) return showError(context, 'Belum ada palet yang ditimbang');
    setState(() => _busy = true);
    try {
      await Api.post('/api/kendaraan/${widget.regId}/selesai-krani', {
        'jumlahPalet': tanpaPalet ? 0 : _totalJml,
        'beratPaletKg': tanpaPalet ? 0 : _totalKg,
        'timbang': tanpaPalet || _batch.isEmpty ? null : {'beratKg': _totalKg, 'sumber': _batch.last.sumber, 'indikatorStatus': 'Stabil'},
      });
      if (mounted) Navigator.of(context).pop(true);
    } catch (e) {
      if (mounted) showError(context, e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: C.ground,
      body: Column(children: [
        const Header(title: 'Timbang Palet', eyebrow: 'Selesai muat', accent: C.outbound),
        Expanded(
          child: ListView(padding: const EdgeInsets.all(16), children: [
            const Box(child: Text('Palet ikut tertimbang bersama truk. Timbang semua palet yang dimuat (boleh beberapa kali). Total berat palet dikurangkan dari net muatan.')),
            const SizedBox(height: 12),
            TextField(controller: _jml, keyboardType: TextInputType.number, decoration: const InputDecoration(labelText: 'Jumlah palet di timbangan')),
            const SizedBox(height: 10),
            BeratField(key: _fieldKey, whs: widget.whs, alat: 'PALET', manualPerluAdmin: false, onChanged: (b) => setState(() => _berat = b)),
            const SizedBox(height: 10),
            BigButton(label: 'Tambahkan ke daftar', outlined: true, color: C.outbound, onPressed: _tambah),
            const SizedBox(height: 16),
            for (var i = 0; i < _batch.length; i++)
              ListTile(
                contentPadding: EdgeInsets.zero,
                title: Text('${_batch[i].jumlah} palet · ${_batch[i].kg.toStringAsFixed(1)} kg'),
                subtitle: Text(_batch[i].sumber),
                trailing: IconButton(icon: const Icon(Icons.delete_outline), tooltip: 'Hapus', onPressed: () => setState(() => _batch.removeAt(i))),
              ),
            if (_batch.isNotEmpty)
              Text('Total: $_totalJml palet · ${_totalKg.toStringAsFixed(1)} kg', style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 16)),
          ]),
        ),
        Footer(children: [
          BigButton(label: 'Simpan · kendaraan boleh keluar', color: C.outbound, busy: _busy, onPressed: () => _simpan()),
          BigButton(label: 'Muat tanpa palet', outlined: true, color: C.ink, onPressed: _busy ? null : () => _simpan(tanpaPalet: true)),
        ]),
      ]),
    );
  }
}


/// Satu isian krani untuk satu baris dokumen. SPMB: PT per isian (boleh beberapa PT untuk satu barang).
class _Entry {
  _Entry(this.planLine, this.room, {this.tambahan = false});
  final int planLine;
  final bool tambahan;
  final qty = TextEditingController();
  final sak = TextEditingController();
  final pal = TextEditingController();
  String? room;
  String? pt;
}
