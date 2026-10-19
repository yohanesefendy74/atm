import 'package:flutter/material.dart';

import '../api.dart';
import '../theme.dart';
import '../widgets.dart';
import 'doc_detail.dart';
import 'label_print.dart';

/// Daftar dokumen inbound / outbound + filter status.
/// Dokumen "Siap cetak" (PT sudah diisi Admin) langsung bisa dicetak labelnya.
class DocList extends StatefulWidget {
  const DocList({
    super.key,
    required this.kind,
    required this.accent,
    required this.eyebrow,
    required this.title,
    required this.filters,
    required this.newScreen,
    required this.note,
  });
  final String kind; // inbound / outbound
  final Color accent;
  final String eyebrow;
  final String title;
  final List<String> filters;
  final WidgetBuilder newScreen;
  final String note;

  @override
  State<DocList> createState() => _DocListState();
}

class _DocListState extends State<DocList> {
  List<Map<String, dynamic>> _docs = [];
  String _filter = 'Semua';
  String _search = '';
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
      final d = await Api.docs(widget.kind);
      if (mounted) setState(() => _docs = d);
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _open(Map<String, dynamic> d) async {
    final objType = d['objType'].toString();
    final docEntry = toI(d['docEntry']);
    final page = d['status'] == 'Siap cetak'
        ? LabelPrintScreen(objType: objType, docEntry: docEntry, accent: widget.accent)
        : DocDetailScreen(objType: objType, docEntry: docEntry, accent: widget.accent, status: (d['status'] ?? '').toString());
    await Navigator.of(context).push(MaterialPageRoute(builder: (_) => page));
    if (mounted) _load();
  }

  @override
  Widget build(BuildContext context) {
    final q = _search.toUpperCase();
    final shown = _docs.where((d) {
      if (_filter != 'Semua' && d['status'] != _filter) return false;
      if (q.isEmpty) return true;
      return [d['docEntry'], d['noMobil'], d['containerNo'], d['trxCode']].any((v) => (v ?? '').toString().toUpperCase().contains(q));
    }).toList();

    return Column(children: [
      Header(
        back: false,
        eyebrow: widget.eyebrow,
        title: widget.title,
        accent: widget.accent,
        trailing: FilledButton.icon(
          style: FilledButton.styleFrom(backgroundColor: widget.accent, minimumSize: const Size(0, 44)),
          onPressed: () async {
            await Navigator.of(context).push(MaterialPageRoute(builder: widget.newScreen));
            if (mounted) _load();
          },
          icon: const Icon(Icons.add),
          label: const Text('Baru'),
        ),
        bottom: Column(children: [
          TextField(
            onChanged: (v) => setState(() => _search = v),
            decoration: const InputDecoration(
              prefixIcon: Icon(Icons.search),
              hintText: 'Cari no. dokumen / mobil / kontainer',
              filled: true,
              fillColor: C.ground,
              contentPadding: EdgeInsets.symmetric(vertical: 10),
            ),
          ),
          const SizedBox(height: 10),
          SizedBox(
            height: 36,
            child: ListView(scrollDirection: Axis.horizontal, children: [
              for (final f in ['Semua', ...widget.filters])
                Padding(
                  padding: const EdgeInsets.only(right: 8),
                  child: ChoiceChip(
                    label: Text(f),
                    selected: _filter == f,
                    showCheckmark: false,
                    selectedColor: C.ink,
                    labelStyle: TextStyle(color: _filter == f ? Colors.white : C.ink, fontWeight: FontWeight.w600),
                    onSelected: (_) => setState(() => _filter = f),
                  ),
                ),
            ]),
          ),
        ]),
      ),
      Expanded(
        child: RefreshIndicator(
          onRefresh: _load,
          child: ListView(padding: const EdgeInsets.all(20), children: [
            if (_loading && _docs.isEmpty) const Loading(),
            if (_error != null) ErrorView(_error!, onRetry: _load),
            if (!_loading && _error == null && shown.isEmpty)
              const Padding(padding: EdgeInsets.all(24), child: Text('Tidak ada dokumen', textAlign: TextAlign.center)),
            for (final d in shown) ...[_card(d), const SizedBox(height: 12)],
            Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              const Icon(Icons.info_outline, size: 16, color: C.muted),
              const SizedBox(width: 6),
              Expanded(child: Text(widget.note, style: const TextStyle(fontSize: 12, color: C.muted))),
            ]),
          ]),
        ),
      ),
    ]);
  }

  Widget _card(Map<String, dynamic> d) {
    final status = (d['status'] ?? '').toString();
    final ready = status == 'Siap cetak';
    final labels = toI(d['labelCount']);
    return Box(
      border: ready ? widget.accent : C.line,
      borderWidth: ready ? 2 : 1,
      onTap: () => _open(d),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Expanded(
            child: Text.rich(TextSpan(children: [
              TextSpan(text: '${d['docEntry']}', style: const TextStyle(fontFamily: mono, fontSize: 15, fontWeight: FontWeight.w600)),
              TextSpan(text: '  · ${d['trxCode']}', style: const TextStyle(fontFamily: mono, fontSize: 12, color: C.muted)),
            ])),
          ),
          StatusPill(status, accent: widget.accent),
        ]),
        const SizedBox(height: 6),
        Text(
          [d['whsCode'], d['noMobil'], d['containerNo'] ?? 'tanpa kontainer'].where((v) => v != null && '$v'.isNotEmpty).join(' · '),
          style: const TextStyle(fontFamily: mono, fontSize: 13, color: C.muted),
        ),
        const SizedBox(height: 4),
        Text('${toI(d['lineCount'])} baris · ${fmt(toD(d['qtyKg']))} KG · ${fmt(toD(d['qtySak']))} sak · ${fmt(toD(d['qtyPalet']))} plt',
            style: const TextStyle(fontSize: 13)),
        if (status == 'Menunggu PT') ...[
          const SizedBox(height: 6),
          const Row(children: [
            Icon(Icons.lock_outline, size: 14, color: C.muted),
            SizedBox(width: 6),
            Text('Label terkunci sampai PT diisi Admin', style: TextStyle(fontSize: 13, color: C.muted)),
          ]),
        ],
        if (ready) ...[
          const SizedBox(height: 10),
          SizedBox(
            width: double.infinity,
            child: FilledButton.icon(
              style: FilledButton.styleFrom(backgroundColor: widget.accent, minimumSize: const Size(0, 44)),
              onPressed: () => _open(d),
              icon: const Icon(Icons.print_outlined, size: 18),
              label: Text('Cetak $labels label QR'),
            ),
          ),
        ],
      ]),
    );
  }
}
