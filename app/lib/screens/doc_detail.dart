import 'package:flutter/material.dart';

import '../api.dart';
import '../theme.dart';
import '../widgets.dart';

/// Tampilan baca-saja dokumen yang sudah dikirim ke Admin.
class DocDetailScreen extends StatefulWidget {
  const DocDetailScreen({super.key, required this.objType, required this.docEntry, required this.accent, required this.status});
  final String objType;
  final int docEntry;
  final Color accent;
  final String status;
  @override
  State<DocDetailScreen> createState() => _DocDetailScreenState();
}

class _DocDetailScreenState extends State<DocDetailScreen> {
  Map<String, dynamic>? _doc;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _error = null);
    try {
      final d = await Api.doc(widget.objType, widget.docEntry);
      if (mounted) setState(() => _doc = d);
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    }
  }

  String get _note => switch (widget.status) {
        'Menunggu PT' => 'Menunggu Admin mengisi PT di CMS. Label QR bisa dicetak setelah itu.',
        'Menunggu DO' => 'Menunggu Admin mengisi customer & No DO di CMS.',
        'Selesai' => 'Sudah diposting Admin. Stok sudah ter-update.',
        _ => '',
      };

  @override
  Widget build(BuildContext context) {
    final h = _doc == null ? null : Map<String, dynamic>.from(_doc!['header'] as Map);
    final lines = _doc == null ? <Map<String, dynamic>>[] : (_doc!['lines'] as List).map((e) => Map<String, dynamic>.from(e as Map)).toList();
    return Scaffold(
      body: Column(children: [
        Header(eyebrow: widget.status, title: '${widget.docEntry}', accent: widget.accent),
        Expanded(
          child: _error != null
              ? ErrorView(_error!, onRetry: _load)
              : h == null
                  ? const Loading()
                  : ListView(padding: const EdgeInsets.all(20), children: [
                      if (_note.isNotEmpty)
                        Box(
                          color: C.amberTint,
                          border: C.amberTint,
                          padding: const EdgeInsets.all(12),
                          child: Text(_note, style: const TextStyle(color: C.amberText)),
                        ),
                      const SizedBox(height: 12),
                      Box(
                        child: Wrap(spacing: 24, runSpacing: 12, children: [
                          KV('TRX', '${h['trxCode']}'),
                          KV('WAREHOUSE', '${h['whsCode']}'),
                          KV('NO. MOBIL', '${h['noMobil'] ?? '-'}'),
                          KV('KONTAINER', '${h['containerNo'] ?? '-'}'),
                          KV('TANGGAL', fmtDate(toDate(h['docDate']))),
                          KV('PT', '${h['ptName'] ?? h['ptCode'] ?? '-'}'),
                        ]),
                      ),
                      const SizedBox(height: 16),
                      Text('Detail · ${lines.length} baris', style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600)),
                      const SizedBox(height: 8),
                      for (final l in lines) ...[
                        Box(
                          padding: const EdgeInsets.all(14),
                          radius: 14,
                          border: toI(l['flag']) == 1 && widget.objType != '6730' ? C.green : C.line,
                          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                            Row(children: [
                              Expanded(child: Text('${l['itemCode']}', style: const TextStyle(fontFamily: mono, fontWeight: FontWeight.w600, fontSize: 15))),
                              if (widget.objType != '6730')
                                toI(l['flag']) == 1
                                    ? const Pill('MASUK', bg: C.greenTint, fg: C.greenText)
                                    : const Pill('KELUAR', bg: C.outboundTint, fg: C.outbound),
                            ]),
                            Text([l['itemName'], l['brand'], l['origin']].where((v) => v != null).join(' · '),
                                style: const TextStyle(fontSize: 13, color: C.muted)),
                            const SizedBox(height: 8),
                            Row(children: [
                              Expanded(child: KV('Qty (${l['uom'] ?? 'KG'})', fmt(toD(l['qty']).abs()))),
                              Expanded(child: KV('Qty 2 (Sak)', fmt(toD(l['qty2']).abs()))),
                              Expanded(child: KV('Qty Palet', fmt(toD(l['qtyPalet']).abs()))),
                            ]),
                          ]),
                        ),
                        const SizedBox(height: 10),
                      ],
                    ]),
        ),
      ]),
    );
  }
}
