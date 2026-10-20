import 'package:flutter/material.dart';

import '../api.dart';
import '../theme.dart';
import '../widgets.dart';

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
      if (!mounted) return;
      setState(() {
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
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
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
    if (_regId == null) return showError(context, 'Pilih kendaraan dulu (registrasi di pos timbang)');
    if (items.isEmpty) return showError(context, 'Isi qty minimal satu baris');
    setState(() => _busy = true);
    try {
      final r = await Api.post('/api/plan/${widget.planId}/simpan', {'regId': _regId, 'lines': items});
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
    if (_regId == null) return;
    setState(() => _busy = true);
    try {
      await Api.post('/api/kendaraan/$_regId/selesai-krani', {});
      if (mounted) {
        showInfo(context, 'Kendaraan boleh timbang keluar');
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
                  const FieldLabel('Kendaraan', required: true),
                  if (_veh.isEmpty) const Hint('Belum ada kendaraan terdaftar untuk dokumen ini. Daftarkan dulu di Pos Timbang.', color: C.outbound),
                  DropdownButtonFormField<int>(
                    value: _regId,
                    items: [for (final v in _veh) DropdownMenuItem(value: toI(v['regId']), child: Text('${v['noPolisi']} · ${v['sopir']}'))],
                    onChanged: (v) => setState(() => _regId = v),
                  ),
                  const SizedBox(height: 12),
                  for (final l in _lines) _lineCard(l, spbb),
                ]),
        ),
        if (h != null)
          Footer(children: [
            BigButton(label: 'Simpan ${spbb ? 'penerimaan' : 'pengiriman'}', color: spbb ? C.inbound : C.outbound, busy: _busy, onPressed: _simpan),
            BigButton(label: 'Selesai · kendaraan boleh keluar', outlined: true, color: C.ink, onPressed: _regId == null || _busy ? null : _selesai),
          ]),
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
