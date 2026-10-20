import 'package:flutter/material.dart';

import '../api.dart';
import '../scale_ble.dart';
import '../theme.dart';
import '../widgets.dart';

/// Hasil pembacaan berat (BLE / Gateway / manual).
class Berat {
  Berat(this.kg, this.sumber, this.status, this.raw, this.kodeTimbangan);
  final double kg;
  final String sumber; // BLE | GATEWAY | MANUAL
  final String? status;
  final String? raw;
  final String? kodeTimbangan;
  Map<String, dynamic> toJson() => {'kodeTimbangan': kodeTimbangan, 'beratKg': kg, 'sumber': sumber, 'indikatorStatus': status, 'teksMentah': raw};
}

/// Pembaca berat: Bluetooth (default bila terhubung), via Gateway PC, atau manual (butuh kode Admin).
class BeratField extends StatefulWidget {
  const BeratField({super.key, required this.whs, required this.onChanged, this.alat = 'KENDARAAN'});
  final String whs;
  final String alat;
  final ValueChanged<Berat?> onChanged;
  @override
  State<BeratField> createState() => _BeratFieldState();
}

class _BeratFieldState extends State<BeratField> {
  String _mode = 'BLE';
  final _manual = TextEditingController();
  List<Map<String, dynamic>> _timb = [];
  String? _kode;
  Berat? _val;
  bool _busy = false;
  String? _msg;

  @override
  void initState() {
    super.initState();
    if (!BleScale.I.connected) _mode = 'GATEWAY';
    _loadAlat();
  }

  Future<void> _loadAlat() async {
    try {
      final r = Map<String, dynamic>.from(await Api.get('/api/alat', {'whs': widget.whs}) as Map);
      final t = (r['timbangan'] as List).map((e) => Map<String, dynamic>.from(e as Map)).where((x) => x['Alat'] == widget.alat).toList();
      if (mounted) setState(() {
        _timb = t;
        if (t.isNotEmpty) _kode = t.first['KodeTimbangan'].toString();
      });
    } catch (_) {}
  }

  void _set(Berat? b) {
    setState(() => _val = b);
    widget.onChanged(b);
  }

  Future<void> _baca() async {
    setState(() {
      _busy = true;
      _msg = null;
    });
    try {
      if (_mode == 'BLE') {
        final r = await BleScale.I.readStable();
        if (!r.stabil) {
          _msg = 'Berat belum stabil · tunggu lalu coba lagi';
          _set(null);
        } else {
          _set(Berat(r.kg, 'BLE', 'Stabil', r.raw, _kode));
        }
      } else {
        final r = Map<String, dynamic>.from(await Api.post('/api/alat/timbang', {'kodeTimbangan': _kode}) as Map);
        final stabil = r['stabil'] == true;
        if (!stabil) {
          _msg = 'Berat belum stabil';
          _set(null);
        } else {
          _set(Berat(toD(r['beratKg']), 'GATEWAY', 'Stabil', null, _kode));
        }
      }
    } catch (e) {
      _msg = e.toString();
      _set(null);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      SegmentedButton<String>(
        segments: const [
          ButtonSegment(value: 'BLE', label: Text('Bluetooth')),
          ButtonSegment(value: 'GATEWAY', label: Text('Gateway')),
          ButtonSegment(value: 'MANUAL', label: Text('Manual')),
        ],
        selected: {_mode},
        onSelectionChanged: (s) => setState(() {
          _mode = s.first;
          _set(null);
        }),
      ),
      const SizedBox(height: 10),
      if (_mode == 'MANUAL') ...[
        TextField(
          controller: _manual,
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          decoration: const InputDecoration(labelText: 'Berat (kg)', helperText: 'Perlu kode persetujuan Admin'),
          onChanged: (v) {
            final d = double.tryParse(v.replaceAll(',', '.'));
            _set(d == null || d <= 0 ? null : Berat(d, 'MANUAL', null, null, _kode));
          },
        ),
      ] else ...[
        if (_mode == 'BLE' && !BleScale.I.connected) const Hint('Timbangan Bluetooth belum terhubung · Pengaturan > Timbangan', color: C.outbound),
        if (_timb.isNotEmpty)
          DropdownButtonFormField<String>(
            value: _kode,
            decoration: const InputDecoration(labelText: 'Timbangan'),
            items: [for (final t in _timb) DropdownMenuItem(value: t['KodeTimbangan'].toString(), child: Text('${t['KodeTimbangan']} · ${t['Lokasi'] ?? ''}'))],
            onChanged: (v) => setState(() => _kode = v),
          ),
        const SizedBox(height: 8),
        BigButton(label: _val == null ? 'Baca berat' : 'Baca ulang', icon: Icons.scale_outlined, outlined: true, busy: _busy, onPressed: _baca),
      ],
      if (_msg != null) Hint(_msg!, color: C.outbound),
      if (_val != null)
        Padding(
          padding: const EdgeInsets.only(top: 8),
          child: Text('${_val!.kg.toStringAsFixed(0)} kg', style: const TextStyle(fontSize: 32, fontWeight: FontWeight.w800, color: C.green)),
        ),
    ]);
  }
}

/// Pos timbang: daftar kendaraan di dalam, registrasi masuk, timbang keluar.
class PosTimbangScreen extends StatefulWidget {
  const PosTimbangScreen({super.key, this.embedded = false});
  final bool embedded;
  @override
  State<PosTimbangScreen> createState() => _PosTimbangScreenState();
}

class _PosTimbangScreenState extends State<PosTimbangScreen> {
  List<Map<String, dynamic>> _whs = [];
  String? _w;
  List<Map<String, dynamic>> _veh = [];
  String? _error;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _init();
  }

  Future<void> _init() async {
    try {
      final w = await Api.warehouses();
      if (!mounted) return;
      setState(() {
        _whs = w;
        _w = (w.firstWhere((x) => x['isDefault'] == true, orElse: () => w.isEmpty ? <String, dynamic>{} : w.first))['whsCode']?.toString();
      });
      await _load();
    } catch (e) {
      if (mounted) setState(() {
        _error = e.toString();
        _loading = false;
      });
    }
  }

  Future<void> _load() async {
    if (_w == null) return;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final r = await Api.get('/api/kendaraan', {'whs': _w}) as List;
      if (mounted) setState(() => _veh = r.map((e) => Map<String, dynamic>.from(e as Map)).toList());
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
        Header(title: 'Pos Timbang', eyebrow: 'Kendaraan masuk / keluar', back: !widget.embedded),
        Expanded(
          child: RefreshIndicator(
            onRefresh: _load,
            child: ListView(padding: const EdgeInsets.all(16), children: [
              DropdownButtonFormField<String>(
                value: _w,
                decoration: const InputDecoration(labelText: 'Gudang'),
                items: [for (final w in _whs) DropdownMenuItem(value: w['whsCode'].toString(), child: Text('${w['whsCode']} · ${w['whsName']}'))],
                onChanged: (v) {
                  setState(() => _w = v);
                  _load();
                },
              ),
              const SizedBox(height: 12),
              if (_loading) const LinearProgressIndicator(minHeight: 2),
              if (_error != null) ErrorView(_error!, onRetry: _load),
              if (!_loading && _veh.isEmpty && _error == null) const Padding(padding: EdgeInsets.all(24), child: Center(child: Text('Tidak ada kendaraan di dalam', style: TextStyle(color: C.muted)))),
              for (final v in _veh)
                Padding(
                  padding: const EdgeInsets.only(bottom: 10),
                  child: Box(
                    onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => KeluarScreen(whs: _w!, veh: v))).then((_) => _load()),
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Row(children: [
                        Expanded(child: Text('${v['noPolisi']}', style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 16))),
                        Pill('${v['keperluan']}'),
                        const SizedBox(width: 6),
                        if (v['selesaiKrani'] == true) const Pill('Krani selesai', bg: C.greenTint, fg: C.greenText),
                      ]),
                      Text('${v['tiket']} · ${v['sopir']}${v['planNo'] != null ? ' · ${v['planNo']}' : ''}', style: const TextStyle(color: C.muted, fontSize: 13)),
                    ]),
                  ),
                ),
            ]),
          ),
        ),
        Footer(children: [
          BigButton(
            label: 'Registrasi kendaraan masuk',
            icon: Icons.login,
            onPressed: _w == null ? null : () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => MasukScreen(whs: _w!))).then((_) => _load()),
          ),
        ]),
      ]),
    ));
  }
}

Future<bool> _konfirmasi(BuildContext context, List warnings) async {
  final ok = await showDialog<bool>(
    context: context,
    builder: (c) => AlertDialog(
      title: const Text('Periksa peringatan'),
      content: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [for (final w in warnings) Padding(padding: const EdgeInsets.only(bottom: 6), child: Text('• $w'))]),
      actions: [TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Batal')), FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('Sudah saya periksa'))],
    ),
  );
  return ok == true;
}

Future<String?> _tanyaKode(BuildContext context) async {
  final c = TextEditingController();
  return showDialog<String>(
    context: context,
    builder: (d) => AlertDialog(
      title: const Text('Kode persetujuan Admin'),
      content: TextField(controller: c, keyboardType: TextInputType.number, maxLength: 6, decoration: const InputDecoration(hintText: '6 digit')),
      actions: [TextButton(onPressed: () => Navigator.pop(d), child: const Text('Batal')), FilledButton(onPressed: () => Navigator.pop(d, c.text), child: const Text('OK'))],
    ),
  );
}

/// Kirim ke endpoint timbang; menangani konfirmasi peringatan (409) dan kode Admin.
Future<Map<String, dynamic>?> _kirimTimbang(BuildContext context, String path, Map<String, dynamic> body, {required bool butuhKode}) async {
  String? kode;
  if (butuhKode) {
    kode = await _tanyaKode(context);
    if (kode == null) return null;
  }
  body['kodeAdmin'] = kode;
  body['ackPeringatan'] = false;
  try {
    return Map<String, dynamic>.from(await Api.post(path, body) as Map);
  } on ApiException catch (e) {
    if (e.status == 409 && e.data?['perluKonfirmasi'] == true) {
      if (!context.mounted) return null;
      if (!await _konfirmasi(context, e.data!['warnings'] as List)) return null;
      body['ackPeringatan'] = true;
      // kode Admin sekali pakai: minta lagi bila sudah terpakai
      try {
        return Map<String, dynamic>.from(await Api.post(path, body) as Map);
      } on ApiException catch (e2) {
        if (e2.message.contains('Kode persetujuan') && context.mounted) {
          final k2 = await _tanyaKode(context);
          if (k2 == null) return null;
          body['kodeAdmin'] = k2;
          return Map<String, dynamic>.from(await Api.post(path, body) as Map);
        }
        rethrow;
      }
    }
    rethrow;
  }
}

class MasukScreen extends StatefulWidget {
  const MasukScreen({super.key, required this.whs});
  final String whs;
  @override
  State<MasukScreen> createState() => _MasukScreenState();
}

class _MasukScreenState extends State<MasukScreen> {
  String _kep = 'Bongkar';
  final _plat = TextEditingController();
  final _sopir = TextEditingController();
  final _cont = TextEditingController();
  final _plan = TextEditingController();
  final _alasan = TextEditingController();
  bool _kontBawaan = false;
  Berat? _berat;
  bool _busy = false;
  String? _taraInfo;

  Future<void> _cekTara() async {
    try {
      final r = Map<String, dynamic>.from(await Api.get('/api/kendaraan/tara', {'plat': _plat.text, 'container': _cont.text}) as Map);
      final m = r['mobil'];
      if (mounted) setState(() => _taraInfo = m == null ? 'Plat ini belum punya riwayat tara' : 'Tara terakhir ${toD(m['terakhir']).toStringAsFixed(0)} kg · rata-rata ${toD(m['rata']).toStringAsFixed(0)} kg (${m['jumlah']}x)');
    } catch (_) {}
  }

  Future<void> _kirim() async {
    if (_berat == null) return showError(context, 'Baca berat dulu');
    setState(() => _busy = true);
    try {
      final r = await _kirimTimbang(
        context,
        '/api/kendaraan/masuk',
        {
          'whsCode': widget.whs,
          'keperluan': _kep,
          'planNo': _kep == 'AmbilKontainer' ? null : _plan.text.trim(),
          'noPolisi': _plat.text,
          'sopir': _sopir.text,
          'containerNo': _cont.text.trim().isEmpty ? null : _cont.text.trim(),
          'alasanBedaPlan': _alasan.text.trim().isEmpty ? null : _alasan.text.trim(),
          'kontainerBawaan': _kontBawaan,
          'timbang': _berat!.toJson(),
        },
        butuhKode: _berat!.sumber == 'MANUAL',
      );
      if (r != null && mounted) {
        showInfo(context, 'Tiket ${r['tiket']} terbit');
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
    final masukBruto = _kep == 'Bongkar';
    return Scaffold(
      backgroundColor: C.ground,
      body: Column(children: [
        const Header(title: 'Registrasi Masuk', eyebrow: 'Pos timbang'),
        Expanded(
          child: ListView(padding: const EdgeInsets.all(16), children: [
            SegmentedButton<String>(
              segments: const [ButtonSegment(value: 'Bongkar', label: Text('Bongkar')), ButtonSegment(value: 'Muat', label: Text('Muat')), ButtonSegment(value: 'AmbilKontainer', label: Text('Ambil kont.'))],
              selected: {_kep},
              onSelectionChanged: (s) => setState(() {
                _kep = s.first;
                _berat = null;
              }),
            ),
            const SizedBox(height: 12),
            TextField(controller: _plat, textCapitalization: TextCapitalization.characters, decoration: const InputDecoration(labelText: 'No. polisi (B 1234 ABC)'), onEditingComplete: _cekTara),
            if (_taraInfo != null) Hint(_taraInfo!),
            const SizedBox(height: 10),
            TextField(controller: _sopir, textCapitalization: TextCapitalization.words, decoration: const InputDecoration(labelText: 'Nama sopir')),
            const SizedBox(height: 10),
            TextField(controller: _cont, textCapitalization: TextCapitalization.characters, decoration: const InputDecoration(labelText: 'No. kontainer (opsional)')),
            if (_kep != 'AmbilKontainer') ...[
              const SizedBox(height: 10),
              TextField(controller: _plan, textCapitalization: TextCapitalization.characters, decoration: InputDecoration(labelText: _kep == 'Bongkar' ? 'No. SPBB (SPBB/2610/0001)' : 'No. SPMB (SPMB/2610/0001)')),
              const SizedBox(height: 10),
              TextField(controller: _alasan, decoration: const InputDecoration(labelText: 'Alasan beda dokumen (jika ada)')),
            ],
            if (!masukBruto) CheckboxListTile(contentPadding: EdgeInsets.zero, value: _kontBawaan, onChanged: (v) => setState(() => _kontBawaan = v ?? false), title: const Text('Membawa kontainer kosong')),
            const SizedBox(height: 16),
            FieldLabel(masukBruto ? 'Timbang bruto (bermuatan)' : 'Timbang tara (kosong)'),
            BeratField(whs: widget.whs, onChanged: (b) => setState(() => _berat = b)),
          ]),
        ),
        Footer(children: [BigButton(label: 'Simpan & terbitkan tiket', busy: _busy, onPressed: _kirim)]),
      ]),
    );
  }
}

class KeluarScreen extends StatefulWidget {
  const KeluarScreen({super.key, required this.whs, required this.veh});
  final String whs;
  final Map<String, dynamic> veh;
  @override
  State<KeluarScreen> createState() => _KeluarScreenState();
}

class _KeluarScreenState extends State<KeluarScreen> {
  Berat? _berat;
  bool _tinggal = false;
  final _tara = TextEditingController();
  final _yard = TextEditingController();
  bool _busy = false;

  Future<void> _kirim() async {
    if (_berat == null) return showError(context, 'Baca berat dulu');
    setState(() => _busy = true);
    try {
      final r = await _kirimTimbang(
        context,
        '/api/kendaraan/${widget.veh['regId']}/keluar',
        {
          'timbang': _berat!.toJson(),
          'kontainerTinggal': _tinggal,
          'yardArea': _tinggal ? _yard.text.trim().toUpperCase() : null,
          'taraKontainer': _tinggal ? double.tryParse(_tara.text.replaceAll(',', '.')) : null,
        },
        butuhKode: _berat!.sumber == 'MANUAL',
      );
      if (r != null && mounted) {
        final net = toD(r['net']);
        showInfo(context, 'Selesai · net ${net.toStringAsFixed(0)} kg${r['selisihPersen'] != null ? ' · selisih ${r['selisihPersen']}%' : ''}');
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
    final v = widget.veh;
    final bongkar = v['keperluan'] == 'Bongkar';
    final adaKont = v['containerNo'] != null;
    return Scaffold(
      backgroundColor: C.ground,
      body: Column(children: [
        Header(title: 'Timbang Keluar', eyebrow: '${v['noPolisi']} · ${v['keperluan']}'),
        Expanded(
          child: ListView(padding: const EdgeInsets.all(16), children: [
            if (v['selesaiKrani'] != true && v['keperluan'] != 'AmbilKontainer') const Box(color: C.amberTint, child: Text('Krani belum menyelesaikan pekerjaan · kendaraan belum boleh keluar', style: TextStyle(color: C.amberText))),
            const SizedBox(height: 12),
            FieldLabel(bongkar ? 'Timbang tara (kosong)' : 'Timbang bruto (bermuatan)'),
            BeratField(whs: widget.whs, onChanged: (b) => setState(() => _berat = b)),
            if (adaKont && bongkar) ...[
              CheckboxListTile(contentPadding: EdgeInsets.zero, value: _tinggal, onChanged: (x) => setState(() => _tinggal = x ?? false), title: const Text('Kontainer ditinggal di yard')),
              if (_tinggal) ...[
                TextField(controller: _tara, keyboardType: const TextInputType.numberWithOptions(decimal: true), decoration: const InputDecoration(labelText: 'Tara kontainer (kg)')),
                const SizedBox(height: 10),
                TextField(controller: _yard, textCapitalization: TextCapitalization.characters, decoration: const InputDecoration(labelText: 'Area yard (YARD-A01)')),
              ],
            ],
          ]),
        ),
        Footer(children: [BigButton(label: 'Simpan timbang keluar', busy: _busy, onPressed: _kirim)]),
      ]),
    );
  }
}
