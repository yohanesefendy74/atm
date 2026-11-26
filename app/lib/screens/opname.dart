import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../api.dart';
import '../theme.dart';
import '../widgets.dart';

/// Stock opname untuk krani: hitung buta per rak (saldo sistem tidak ditampilkan).
/// Alur: pilih rak tugas -> scan barcode rak -> scan QR palet, isi sak / kg / palet -> simpan atau kirim.

String rakBarcode(String ruangan, String rak) => 'RAK-$ruangan-$rak';

/// Kartu tugas opname (ditampilkan di atas daftar Tugas Saya).
class OpnameTugasList extends StatelessWidget {
  const OpnameTugasList({super.key, required this.rows, required this.onChanged});
  final List<Map<String, dynamic>> rows;
  final VoidCallback onChanged;

  @override
  Widget build(BuildContext context) {
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      for (final o in rows) ...[
        Box(
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Row(children: [
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  const Text('STOCK OPNAME', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: C.inbound, letterSpacing: 0.7)),
                  Text('${o['opnameNo']}', style: const TextStyle(fontWeight: FontWeight.w700, fontFamily: mono, fontSize: 16)),
                  Text('${o['whsCode']} · ${fmtTgl(o['tglOpname'])}', style: const TextStyle(color: C.muted, fontSize: 13)),
                ]),
              ),
            ]),
            const SizedBox(height: 6),
            const Hint('Hitung buta: saldo sistem tidak ditampilkan. Hitung hanya palet di rak yang ditugaskan.', color: C.inbound),
            const SizedBox(height: 8),
            for (final r in (o['raks'] as List).map((e) => Map<String, dynamic>.from(e as Map)))
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Box(
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                  radius: 12,
                  onTap: r['selesai'] == true
                      ? null
                      : () => Navigator.of(context)
                          .push(MaterialPageRoute(builder: (_) => OpnameHitungScreen(opname: o, rak: r)))
                          .then((_) => onChanged()),
                  child: Row(children: [
                    Expanded(
                      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        Text('Rak ${r['kodeRak']} · ${r['kodeRuangan']}${r['namaRuangan'] != null ? ' ${r['namaRuangan']}' : ''}',
                            style: const TextStyle(fontWeight: FontWeight.w600)),
                        Text('Hitung ke-${r['ke']} · ${toI(r['baris'])} baris${r['ruanganTitipan'] == true ? ' · ruangan titipan' : ''}',
                            style: const TextStyle(fontSize: 12, color: C.muted)),
                      ]),
                    ),
                    r['selesai'] == true
                        ? const Pill('Dikirim', bg: C.greenTint, fg: C.greenText)
                        : toI(r['baris']) > 0
                            ? const Pill('Sedang dihitung', bg: C.amberTint, fg: C.amberText)
                            : const Pill('Belum', bg: C.lineSoft, fg: C.muted),
                    if (r['selesai'] != true) const Icon(Icons.chevron_right, color: C.muted),
                  ]),
                ),
              ),
          ]),
        ),
        const SizedBox(height: 10),
      ],
    ]);
  }
}

String fmtTgl(dynamic v) {
  final s = '${v ?? ''}';
  if (s.length < 10) return s;
  return '${s.substring(8, 10)}/${s.substring(5, 7)}/${s.substring(0, 4)}';
}

class _Baris {
  _Baris({required this.qr, required this.itemCode, this.itemName, required this.containerNo, this.noLot, this.noBL, required this.titipan, this.ptCode, this.ptName, required this.sak, required this.kg, required this.palet});
  final String qr;
  final String itemCode;
  final String? itemName;
  final String containerNo;
  final String? noLot;
  final String? noBL;
  final bool titipan;
  final String? ptCode;
  final String? ptName;
  double sak;
  double kg;
  double palet;

  Map<String, dynamic> toJson() => {'qr': qr, 'noBL': noBL, 'titipan': titipan, 'ptCode': ptCode, 'sak': sak, 'kg': kg, 'palet': palet};
}

class OpnameHitungScreen extends StatefulWidget {
  const OpnameHitungScreen({super.key, required this.opname, required this.rak});
  final Map<String, dynamic> opname;
  final Map<String, dynamic> rak;
  @override
  State<OpnameHitungScreen> createState() => _OpnameHitungScreenState();
}

class _OpnameHitungScreenState extends State<OpnameHitungScreen> {
  final List<_Baris> _rows = [];
  String? _barcode;
  bool _loading = true;
  bool _busy = false;
  bool _dirty = false;

  int get _id => toI(widget.opname['opnameId']);
  String get _ruang => '${widget.rak['kodeRuangan']}';
  String get _rak => '${widget.rak['kodeRak']}';

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final r = await Api.get('/api/opname/$_id/hitung', {'ruangan': _ruang, 'rak': _rak}) as List;
      if (!mounted) return;
      setState(() {
        _rows
          ..clear()
          ..addAll(r.map((e) {
            final m = Map<String, dynamic>.from(e as Map);
            return _Baris(
                qr: '${m['qr']}', itemCode: '${m['itemCode']}', itemName: m['itemName']?.toString(), containerNo: '${m['containerNo'] ?? ''}',
                noLot: m['noLot']?.toString(), noBL: m['noBL']?.toString(), titipan: m['titipan'] == true, ptCode: m['ptCode']?.toString(),
                ptName: m['ptName']?.toString(), sak: toD(m['sak']), kg: toD(m['kg']), palet: toD(m['palet']));
          }));
      });
    } catch (e) {
      if (mounted) showError(context, e);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _scanRak() async {
    final raw = await Navigator.of(context).push<String>(MaterialPageRoute(builder: (_) => const ScanQrScreen(title: 'Scan barcode rak')));
    if (raw == null || !mounted) return;
    if (raw.trim().toUpperCase() != rakBarcode(_ruang, _rak).toUpperCase()) {
      return showError(context, 'Barcode $raw bukan rak $_rak. Scan barcode rak yang ditugaskan.');
    }
    setState(() => _barcode = raw.trim());
  }

  Future<void> _scanPalet() async {
    final raw = await Navigator.of(context).push<String>(MaterialPageRoute(builder: (_) => const ScanQrScreen()));
    if (raw == null || !mounted) return;
    if (raw.toUpperCase().startsWith('RAK-')) return showError(context, 'Itu barcode rak. Scan QR palet.');
    try {
      final r = Map<String, dynamic>.from(await Api.get('/api/opname/$_id/qr', {'qr': raw, 'ruangan': _ruang}) as Map);
      if (!mounted) return;
      final b = await showModalBottomSheet<_Baris>(
        context: context,
        isScrollControlled: true,
        builder: (_) => _IsiPalet(info: r, ruanganTitipan: widget.rak['ruanganTitipan'] == true),
      );
      if (b == null) return;
      setState(() {
        _rows.add(b);
        _dirty = true;
      });
    } catch (e) {
      if (mounted) showError(context, e);
    }
  }

  Future<void> _kirim(bool selesai) async {
    if (_barcode == null) return showError(context, 'Scan barcode rak dulu');
    if (selesai && _rows.isEmpty) {
      final ok = await showDialog<bool>(
        context: context,
        builder: (c) => AlertDialog(
          title: const Text('Rak kosong?'),
          content: Text('Tidak ada palet yang dihitung di rak $_rak. Kirim sebagai rak kosong?'),
          actions: [TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Batal')), FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('Kirim'))],
        ),
      );
      if (ok != true) return;
    } else if (selesai) {
      final ok = await showDialog<bool>(
        context: context,
        builder: (c) => AlertDialog(
          title: const Text('Kirim hitungan?'),
          content: Text('${_rows.length} baris di rak $_rak dikirim ke Admin. Setelah dikirim tidak bisa diubah kecuali Admin meminta hitung ulang.'),
          actions: [TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Batal')), FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('Kirim'))],
        ),
      );
      if (ok != true) return;
    }
    setState(() => _busy = true);
    try {
      await Api.post('/api/opname/$_id/hitung', {
        'kodeRuangan': _ruang,
        'kodeRak': _rak,
        'barcodeRak': _barcode,
        'selesai': selesai,
        'lines': _rows.map((e) => e.toJson()).toList(),
      });
      if (!mounted) return;
      _dirty = false;
      showInfo(context, selesai ? 'Hitungan rak $_rak dikirim' : 'Tersimpan');
      if (selesai) Navigator.of(context).pop();
    } catch (e) {
      if (mounted) showError(context, e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final totKg = _rows.fold<double>(0, (a, b) => a + b.kg);
    final totPlt = _rows.fold<double>(0, (a, b) => a + b.palet);
    return PopScope(
      canPop: !_dirty,
      onPopInvoked: (didPop) async {
        if (didPop) return;
        final ok = await showDialog<bool>(
          context: context,
          builder: (c) => AlertDialog(
            title: const Text('Belum disimpan'),
            content: const Text('Hitungan yang belum disimpan akan hilang. Keluar?'),
            actions: [TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Tetap di sini')), TextButton(onPressed: () => Navigator.pop(c, true), child: const Text('Keluar'))],
          ),
        );
        if (ok == true && mounted) {
          _dirty = false;
          Navigator.of(context).pop();
        }
      },
      child: Scaffold(
        backgroundColor: C.ground,
        body: Column(children: [
          Header(title: 'Rak $_rak', eyebrow: '${widget.opname['opnameNo']} · hitung ke-${widget.rak['ke']}'),
          Expanded(
            child: ListView(padding: const EdgeInsets.all(16), children: [
              if (_loading) const LinearProgressIndicator(minHeight: 2),
              Box(
                border: _barcode == null ? C.amberText : C.green,
                child: Row(children: [
                  Icon(_barcode == null ? Icons.qr_code_scanner : Icons.check_circle, color: _barcode == null ? C.amberText : C.green),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Text(_barcode == null ? '1. Scan barcode rak' : 'Rak terkonfirmasi', style: const TextStyle(fontWeight: FontWeight.w600)),
                      Text('$_ruang · rak $_rak', style: const TextStyle(fontSize: 12, color: C.muted, fontFamily: mono)),
                    ]),
                  ),
                  if (_barcode == null) FilledButton(onPressed: _scanRak, child: const Text('Scan')),
                ]),
              ),
              const SizedBox(height: 12),
              if (_barcode != null)
                BigButton(label: '2. Scan QR palet', icon: Icons.qr_code_scanner, color: C.inbound, onPressed: _busy ? null : _scanPalet),
              const SizedBox(height: 12),
              const Hint('Label lama (tanggal-item-container tanpa lot) tetap bisa discan. Palet dengan QR sama boleh discan lagi, atau isi jumlah palet sekaligus.'),
              const SizedBox(height: 12),
              for (var i = 0; i < _rows.length; i++)
                Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: Box(
                    padding: const EdgeInsets.fromLTRB(14, 10, 4, 10),
                    child: Row(children: [
                      Expanded(
                        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                          Text('${_rows[i].itemCode} · ${_rows[i].itemName ?? ''}', style: const TextStyle(fontWeight: FontWeight.w600)),
                          Text('${_rows[i].containerNo}${_rows[i].noLot != null ? ' · L${_rows[i].noLot}' : ' · label lama'}',
                              style: const TextStyle(fontSize: 12, fontFamily: mono, color: C.muted)),
                          Text('${_rows[i].titipan ? 'TITIPAN' : 'BL ${_rows[i].noBL ?? '-'}'} · PT ${_rows[i].ptName ?? _rows[i].ptCode ?? '-'}',
                              style: const TextStyle(fontSize: 12, color: C.muted)),
                          Text('${_rows[i].sak.toStringAsFixed(0)} sak · ${_rows[i].kg.toStringAsFixed(1)} kg · ${_rows[i].palet.toStringAsFixed(0)} palet',
                              style: const TextStyle(fontSize: 13)),
                        ]),
                      ),
                      IconButton(
                        tooltip: 'Hapus',
                        icon: const Icon(Icons.delete_outline),
                        onPressed: () => setState(() {
                          _rows.removeAt(i);
                          _dirty = true;
                        }),
                      ),
                    ]),
                  ),
                ),
              if (!_loading && _rows.isEmpty) const Padding(padding: EdgeInsets.all(24), child: Center(child: Text('Belum ada palet dihitung', style: TextStyle(color: C.muted)))),
            ]),
          ),
          Footer(children: [
            Text('${_rows.length} baris · ${totKg.toStringAsFixed(1)} kg · ${totPlt.toStringAsFixed(0)} palet', style: const TextStyle(fontWeight: FontWeight.w600)),
            Row(children: [
              Expanded(child: BigButton(label: 'Simpan', outlined: true, busy: _busy, onPressed: _barcode == null ? null : () => _kirim(false))),
              const SizedBox(width: 10),
              Expanded(child: BigButton(label: 'Kirim rak', color: C.green, busy: _busy, onPressed: _barcode == null ? null : () => _kirim(true))),
            ]),
          ]),
        ]),
      ),
    );
  }
}

/// Isi qty untuk palet yang discan: pilih sumber (BL / titipan / PT) bila lebih dari satu, isi sak, kg, palet.
class _IsiPalet extends StatefulWidget {
  const _IsiPalet({required this.info, required this.ruanganTitipan});
  final Map<String, dynamic> info;
  final bool ruanganTitipan;
  @override
  State<_IsiPalet> createState() => _IsiPaletState();
}

class _IsiPaletState extends State<_IsiPalet> {
  late final List<Map<String, dynamic>> _sumber;
  int? _pick;
  final _sak = TextEditingController();
  final _kg = TextEditingController();
  final _palet = TextEditingController(text: '1');
  bool _kgManual = false;

  double get _kgPerSak => toD(widget.info['kgPerSak']);

  @override
  void initState() {
    super.initState();
    _sumber = ((widget.info['sumber'] as List?) ?? []).map((e) => Map<String, dynamic>.from(e as Map)).toList();
    if (_sumber.length == 1) _pick = 0;
    final spp = toD(widget.info['sakPerPalet']);
    if (spp > 0) {
      _sak.text = spp.toStringAsFixed(0);
      _autoKg();
    }
  }

  void _autoKg() {
    if (_kgManual || _kgPerSak <= 0) return;
    final s = double.tryParse(_sak.text.replaceAll(',', '.')) ?? 0;
    _kg.text = (s * _kgPerSak).toStringAsFixed(1);
  }

  String _label(Map<String, dynamic> s) =>
      '${s['titipan'] == true ? 'TITIPAN' : 'BL ${s['noBL'] ?? '-'}'} · PT ${s['ptName'] ?? s['ptCode'] ?? '-'}';

  void _ok() {
    final sak = double.tryParse(_sak.text.replaceAll(',', '.')) ?? 0;
    final kg = double.tryParse(_kg.text.replaceAll(',', '.')) ?? 0;
    final plt = double.tryParse(_palet.text.replaceAll(',', '.')) ?? 0;
    if (sak < 0 || kg < 0 || plt < 0) return showError(context, 'Qty tidak boleh minus');
    if (sak == 0 && kg == 0 && plt == 0) return showError(context, 'Isi sak, kg atau palet');
    final s = _pick == null ? <String, dynamic>{} : _sumber[_pick!];
    if (_sumber.length > 1 && _pick == null) return showError(context, 'Pilih sumber stok (BL / PT)');
    final tit = s['titipan'] == true;
    if (tit && !widget.ruanganTitipan) return showError(context, 'Barang titipan hanya boleh di ruangan titipan');
    final i = widget.info;
    Navigator.of(context).pop(_Baris(
      qr: '${i['qr']}', itemCode: '${i['itemCode']}', itemName: i['itemName']?.toString(), containerNo: '${i['containerNo'] ?? ''}',
      noLot: i['noLot']?.toString(), noBL: s['noBL']?.toString(), titipan: tit, ptCode: s['ptCode']?.toString(), ptName: s['ptName']?.toString(),
      sak: sak, kg: kg, palet: plt,
    ));
  }

  @override
  Widget build(BuildContext context) {
    final i = widget.info;
    final nums = [FilteringTextInputFormatter.allow(RegExp(r'[0-9.,]'))];
    return Padding(
      padding: EdgeInsets.fromLTRB(20, 16, 20, 16 + MediaQuery.of(context).viewInsets.bottom + MediaQuery.of(context).padding.bottom),
      child: SingleChildScrollView(
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Text('${i['itemCode']} · ${i['itemName'] ?? ''}', style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w700)),
          Text('${i['containerNo']}${i['noLot'] != null ? ' · lot ${i['noLot']}' : ' · label lama tanpa lot'}', style: const TextStyle(fontFamily: mono, color: C.muted)),
          const SizedBox(height: 12),
          if (_sumber.isEmpty) const Hint('Sumber stok tidak dikenali; Admin akan memeriksa saat validasi.', color: C.amberText),
          if (_sumber.length == 1) Text(_label(_sumber.first), style: const TextStyle(fontSize: 13)),
          if (_sumber.length > 1) ...[
            const FieldLabel('Sumber stok', required: true, hint: '(BL / PT pada label)'),
            for (var k = 0; k < _sumber.length; k++)
              RadioListTile<int>(
                dense: true,
                contentPadding: EdgeInsets.zero,
                value: k,
                groupValue: _pick,
                onChanged: (v) => setState(() => _pick = v),
                title: Text(_label(_sumber[k])),
              ),
          ],
          const SizedBox(height: 12),
          Row(children: [
            Expanded(
              child: TextField(
                controller: _sak,
                keyboardType: const TextInputType.numberWithOptions(decimal: true),
                inputFormatters: nums,
                decoration: const InputDecoration(labelText: 'Sak'),
                onChanged: (_) => setState(_autoKg),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: TextField(
                controller: _kg,
                keyboardType: const TextInputType.numberWithOptions(decimal: true),
                inputFormatters: nums,
                decoration: InputDecoration(labelText: 'Kg', helperText: _kgPerSak > 0 ? '@${_kgPerSak.toStringAsFixed(1)} kg/sak' : null),
                onChanged: (_) => _kgManual = true,
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: TextField(
                controller: _palet,
                keyboardType: const TextInputType.numberWithOptions(decimal: true),
                inputFormatters: nums,
                decoration: const InputDecoration(labelText: 'Palet'),
              ),
            ),
          ]),
          const SizedBox(height: 16),
          BigButton(label: 'Tambah', color: C.inbound, onPressed: _ok),
        ]),
      ),
    );
  }
}
