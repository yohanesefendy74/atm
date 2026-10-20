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
  final _qty = <int, TextEditingController>{};
  final _sak = <int, TextEditingController>{};
  final _pal = <int, TextEditingController>{};
  final _room = <int, String?>{};
  int? _regId;
  // SPBB: kontainer di dock + sampling berat per barang
  List<Map<String, dynamic>> _kont = [];
  int? _sesiId;
  List<Map<String, dynamic>> _kItems = [];
  String? _kStatus;
  final _sSak = <int, TextEditingController>{};
  final _sKg = <int, TextEditingController>{};
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
          _qty.putIfAbsent(k, () => TextEditingController());
          _sak.putIfAbsent(k, () => TextEditingController());
          _pal.putIfAbsent(k, () => TextEditingController());
          _room[k] ??= l['kodeRuangan']?.toString() ?? h['kodeRuangan']?.toString();
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
      for (final i in _kItems) {
        final k = toI(i['planLine']);
        _sSak.putIfAbsent(k, () => TextEditingController(text: toI(i['sakSampel']) > 0 ? '${toI(i['sakSampel'])}' : ''));
        _sKg.putIfAbsent(k, () => TextEditingController(text: toD(i['kgSampel']) > 0 ? toD(i['kgSampel']).toString() : ''));
      }
    });
  }

  Future<void> _simpanSampling() async {
    final items = <Map<String, dynamic>>[];
    for (final i in _kItems) {
      final k = toI(i['planLine']);
      final sak = int.tryParse(_sSak[k]!.text.trim()) ?? 0;
      final kg = double.tryParse(_sKg[k]!.text.replaceAll(',', '.')) ?? 0;
      if (sak <= 0 && kg <= 0) continue;
      if (sak < 1 || kg <= 0) return showError(context, '${i['itemCode']}: isi jumlah karung sampel (min 1) dan beratnya');
      items.add({'planLine': k, 'sakSampel': sak, 'kgSampel': kg});
    }
    if (items.isEmpty) return showError(context, 'Isi sampling minimal satu barang');
    setState(() => _busy = true);
    try {
      await Api.put('/api/kontainer/$_sesiId/sampling', {'items': items});
      if (mounted) showInfo(context, 'Sampling tersimpan');
      await _loadKont();
    } catch (e) {
      if (mounted) showError(context, e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _simpan() async {
    final items = <Map<String, dynamic>>[];
    for (final l in _lines) {
      final k = toI(l['planLine']);
      final q = double.tryParse(_qty[k]!.text.replaceAll(',', '.')) ?? 0;
      if (q <= 0) continue;
      items.add({
        'planLine': k,
        'qty': q,
        'qty2': double.tryParse(_sak[k]!.text.replaceAll(',', '.')) ?? 0,
        'qtyPalet': double.tryParse(_pal[k]!.text.replaceAll(',', '.')) ?? 0,
        'kodeRuangan': _room[k],
      });
    }
    final spbb = _h?['jenis'] == 'SPBB';
    if (spbb && _sesiId == null) return showError(context, 'Pilih kontainer yang sedang dibongkar');
    if (!spbb && _regId == null) return showError(context, 'Pilih kendaraan dulu (registrasi di pos timbang)');
    if (items.isEmpty) return showError(context, 'Isi qty minimal satu baris');
    setState(() => _busy = true);
    try {
      final r = await Api.post('/api/plan/${widget.planId}/simpan', {'regId': spbb ? null : _regId, 'sesiId': spbb ? _sesiId : null, 'lines': items});
      if (!mounted) return;
      showInfo(context, 'Tersimpan · penerimaan ke-${r['penerimaanKe']}');
      for (final c in [..._qty.values, ..._sak.values, ..._pal.values]) {
        c.clear();
      }
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
                          _sSak.clear();
                          _sKg.clear();
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

  /// Sampling berat: per barang di kontainer ini, timbang beberapa karung (bebas, min 1).
  Widget _samplingCard() {
    return Box(
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        const Text('Sampling berat per barang', style: TextStyle(fontWeight: FontWeight.w700)),
        const Hint('Timbang beberapa karung tiap barang. Berat bersih kontainer dibagi ke tiap barang sesuai sampling (prorata).'),
        const SizedBox(height: 8),
        if (_kItems.isEmpty) const Text('Simpan input barang dulu, lalu isi sampling.', style: TextStyle(color: C.muted)),
        for (final i in _kItems) ...[
          Text('${i['itemCode']} · ${toD(i['sakTotal']).toStringAsFixed(0)} karung · ${toD(i['kgKrani']).toStringAsFixed(0)} kg', style: const TextStyle(fontWeight: FontWeight.w600)),
          Row(children: [
            Expanded(child: TextField(controller: _sSak[toI(i['planLine'])], keyboardType: TextInputType.number, decoration: const InputDecoration(labelText: 'Karung sampel'))),
            const SizedBox(width: 8),
            Expanded(child: TextField(controller: _sKg[toI(i['planLine'])], keyboardType: const TextInputType.numberWithOptions(decimal: true), decoration: const InputDecoration(labelText: 'Berat sampel (kg)'))),
          ]),
          const SizedBox(height: 10),
        ],
        if (_kItems.isNotEmpty) BigButton(label: 'Simpan sampling', outlined: true, color: C.inbound, busy: _busy, onPressed: _simpanSampling),
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
          else ...[
            Row(children: [
              Expanded(child: TextField(controller: _qty[k], keyboardType: const TextInputType.numberWithOptions(decimal: true), decoration: const InputDecoration(labelText: 'Kg'))),
              const SizedBox(width: 8),
              Expanded(child: TextField(controller: _sak[k], keyboardType: TextInputType.number, decoration: const InputDecoration(labelText: 'Karung'))),
              const SizedBox(width: 8),
              Expanded(child: TextField(controller: _pal[k], keyboardType: const TextInputType.numberWithOptions(decimal: true), decoration: const InputDecoration(labelText: 'Palet'))),
            ]),
            if (_ruang.isNotEmpty) ...[
              const SizedBox(height: 8),
              DropdownButtonFormField<String>(
                value: _ruang.any((r) => r['kodeRuangan'] == _room[k]) ? _room[k] : null,
                decoration: const InputDecoration(labelText: 'Ruangan'),
                items: [for (final r in _ruang) DropdownMenuItem(value: r['kodeRuangan'].toString(), child: Text('${r['kodeRuangan']} · ${r['namaRuangan']}'))],
                onChanged: (v) => setState(() => _room[k] = v),
              ),
            ],
          ],
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
