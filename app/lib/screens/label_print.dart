import 'package:flutter/material.dart';

import '../api.dart';
import '../printer.dart';
import '../theme.dart';
import '../tspl.dart';
import '../widgets.dart';
import 'settings.dart';

/// Cetak label QR palet. Jumlah label per item = Qty Palet.
/// Server menolak (409) bila PT belum diisi Admin; baris PT di label = OPRC.PrcName.
class LabelPrintScreen extends StatefulWidget {
  const LabelPrintScreen({super.key, required this.objType, required this.docEntry, required this.accent});
  final String objType;
  final int docEntry;
  final Color accent;
  @override
  State<LabelPrintScreen> createState() => _LabelPrintScreenState();
}

class _LabelPrintScreenState extends State<LabelPrintScreen> {
  Map<String, dynamic>? _data;
  String? _error;
  bool _locked = false;
  int _pick = 0;
  LabelSize _size = LabelSize.all.last;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _error = null;
      _locked = false;
    });
    try {
      final d = await Api.labels(widget.objType, widget.docEntry);
      if (mounted) setState(() => _data = d);
    } on ApiException catch (e) {
      if (mounted) {
        setState(() {
          _error = e.message;
          _locked = e.status == 409;
        });
      }
    }
  }

  List<Map<String, dynamic>> get _items =>
      ((_data?['items'] as List?) ?? []).map((e) => Map<String, dynamic>.from(e as Map)).toList();

  List<LabelData> _labels() {
    final d = _data!;
    return _items
        .map((i) => LabelData(
              containerNo: (d['containerNo'] ?? '').toString(),
              date: toDate(d['docDate']) ?? DateTime.now(),
              itemName: (i['itemName'] ?? '').toString(),
              brand: (i['brand'] ?? '').toString(),
              packKg: toD(i['packKg']),
              ptName: (d['ptName'] ?? '').toString(),
              qr: (i['qr'] ?? '').toString(),
              sakPerPalet: toD(i['sakPerPalet']),
              copies: toI(i['qtyPalet']),
            ))
        .toList();
  }

  Future<void> _print() async {
    setState(() => _busy = true);
    try {
      final labels = _labels();
      final pdf = await LabelPrinter.cetak(labels, _size);
      final total = labels.fold<int>(0, (s, l) => s + l.copies);
      if (mounted) showInfo(context, pdf ? '$total label dibuat sebagai PDF (printer Bluetooth tidak tersedia)' : '$total label dikirim ke printer');
    } catch (e) {
      if (mounted) showError(context, e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final isIn = widget.objType == '6730';
    final eyebrow = isIn ? 'Label QR · PT dari Admin' : 'Label Item Inbound · PT dari Admin';
    final items = _items;
    final total = items.fold<int>(0, (s, i) => s + toI(i['qtyPalet']));

    return Scaffold(
      body: Column(children: [
        Header(eyebrow: eyebrow, title: '${widget.docEntry}', accent: widget.accent),
        Expanded(
          child: _error != null
              ? (_locked
                  ? Padding(
                      padding: const EdgeInsets.all(24),
                      child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
                        const Icon(Icons.lock_outline, size: 44, color: C.muted),
                        const SizedBox(height: 12),
                        Text(_error!, textAlign: TextAlign.center),
                        const SizedBox(height: 12),
                        OutlinedButton(onPressed: _load, child: const Text('Cek lagi')),
                      ]),
                    )
                  : ErrorView(_error!, onRetry: _load))
              : _data == null
                  ? const Loading()
                  : ListView(padding: const EdgeInsets.all(20), children: [
                      if (items.isNotEmpty)
                        Box(
                          padding: const EdgeInsets.all(14),
                          child: Column(children: [
                            _LabelPreview(data: _labels()[_pick.clamp(0, items.length - 1).toInt()]),
                            const SizedBox(height: 8),
                            Text('Pratinjau · ukuran ${_size.label}', style: const TextStyle(fontSize: 12, color: C.muted)),
                          ]),
                        ),
                      const SizedBox(height: 12),
                      Box(
                        padding: const EdgeInsets.fromLTRB(8, 8, 8, 4),
                        child: Column(children: [
                          const Padding(
                            padding: EdgeInsets.fromLTRB(8, 4, 8, 8),
                            child: Row(children: [
                              Expanded(child: Text('ITEM', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: C.muted))),
                              Text('LABEL = QTY PALET', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: C.muted)),
                            ]),
                          ),
                          for (var i = 0; i < items.length; i++)
                            ListTile(
                              selected: i == _pick,
                              selectedTileColor: widget.accent == C.inbound ? C.inboundTint : C.outboundTint,
                              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                              onTap: () => setState(() => _pick = i),
                              title: Text('${items[i]['itemCode']}', style: const TextStyle(fontFamily: mono, fontWeight: FontWeight.w600, color: C.ink)),
                              subtitle: Text('${items[i]['itemName']}'),
                              trailing: Text('${toI(items[i]['qtyPalet'])} label',
                                  style: const TextStyle(fontFamily: mono, fontWeight: FontWeight.w600, fontSize: 15, color: C.ink)),
                            ),
                          const Divider(color: C.ink),
                          Padding(
                            padding: const EdgeInsets.fromLTRB(8, 4, 8, 10),
                            child: Row(children: [
                              const Expanded(child: Text('Total', style: TextStyle(fontWeight: FontWeight.w700))),
                              Text('$total label', style: const TextStyle(fontFamily: mono, fontWeight: FontWeight.w700)),
                            ]),
                          ),
                        ]),
                      ),
                      const SizedBox(height: 16),
                      const FieldLabel('Ukuran label'),
                      SegmentedButton<LabelSize>(
                        segments: [for (final s in LabelSize.all) ButtonSegment(value: s, label: Text(s.label))],
                        selected: {_size},
                        showSelectedIcon: false,
                        onSelectionChanged: (v) => setState(() => _size = v.first),
                      ),
                      const SizedBox(height: 16),
                      Box(
                        padding: const EdgeInsets.all(12),
                        child: Row(children: [
                          const Icon(Icons.print_outlined, color: C.greenText),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                              Text(Session.I.printerName ?? 'Printer belum dipilih', style: const TextStyle(fontWeight: FontWeight.w600)),
                              const Text('Bluetooth · TSPL', style: TextStyle(fontSize: 12, color: C.muted)),
                            ]),
                          ),
                          TextButton(
                            onPressed: () async {
                              await Navigator.of(context).push(MaterialPageRoute(builder: (_) => const SettingsScreen(loggedIn: true)));
                              if (mounted) setState(() {});
                            },
                            child: const Text('Ganti'),
                          ),
                        ]),
                      ),
                    ]),
        ),
        if (_data != null && items.isNotEmpty)
          Footer(children: [
            BigButton(label: 'Cetak semua $total label', color: widget.accent, icon: Icons.print, busy: _busy, onPressed: _print),
          ]),
      ]),
    );
  }
}

/// Gambar label palet: container besar, tanggal, item, merek, @isi, PT, QR, kotak SAK.
class _LabelPreview extends StatelessWidget {
  const _LabelPreview({required this.data});
  final LabelData data;
  @override
  Widget build(BuildContext context) {
    const t = TextStyle(fontSize: 11, fontWeight: FontWeight.w600, height: 1.35);
    final pack = data.packKg == data.packKg.roundToDouble() ? data.packKg.toInt().toString() : fmt(data.packKg);
    Widget box([String text = '']) => Container(
          height: 28,
          margin: const EdgeInsets.only(top: 8),
          alignment: Alignment.center,
          decoration: BoxDecoration(border: Border.all(color: C.ink, width: 1.5)),
          child: Text(text, style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w700)),
        );
    return AspectRatio(
      aspectRatio: 100 / 70,
      child: Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(color: Colors.white, border: Border.all(color: C.ink, width: 1.5), borderRadius: BorderRadius.circular(6)),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(data.containerDisplay, style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w700, height: 1.1)),
              const SizedBox(height: 6),
              Text(fmtDate(data.date), style: t),
              Text(data.itemName.toUpperCase(), style: t, maxLines: 1, overflow: TextOverflow.ellipsis),
              Text(data.brand.toUpperCase(), style: t),
              Text('@$pack', style: t),
              Text(data.ptName.toUpperCase(), style: t, maxLines: 1, overflow: TextOverflow.ellipsis),
              const Spacer(),
              Text(data.qr, style: const TextStyle(fontFamily: mono, fontSize: 8, color: C.muted)),
            ]),
          ),
          SizedBox(
            width: 80,
            child: Column(children: [
              const Icon(Icons.qr_code_2, size: 70),
              box('${fmt(data.sakPerPalet)} SAK'),
              box(),
              box(),
            ]),
          ),
        ]),
      ),
    );
  }
}
