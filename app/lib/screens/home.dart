import 'package:flutter/material.dart';

import '../api.dart';
import '../theme.dart';
import '../widgets.dart';
import 'inbound.dart';
import 'outbound.dart';
import 'pos_timbang.dart';
import 'tugas.dart';
import 'reports.dart';
import 'settings.dart';

/// Kerangka utama dengan bottom nav: Beranda · Inbound · Scan · Outbound · Laporan.
class Shell extends StatefulWidget {
  const Shell({super.key});
  @override
  State<Shell> createState() => _ShellState();
}

class _ShellState extends State<Shell> {
  int _tab = 0;
  final _visited = <int>{0};
  final _keys = [GlobalKey(), GlobalKey(), GlobalKey(), GlobalKey(), GlobalKey()];

  void go(int tab) => setState(() {
        _tab = tab;
        _visited.add(tab);
      });

  @override
  Widget build(BuildContext context) {
    final pages = [
      HomeTab(key: _keys[0], onGo: go),
      TugasScreen(key: _keys[1], embedded: true),
      InboundListScreen(key: _keys[2]),
      OutboundListScreen(key: _keys[3]),
      PosTimbangScreen(key: _keys[4], embedded: true),
    ];
    return Scaffold(
      resizeToAvoidBottomInset: false,
      body: IndexedStack(index: _tab, children: [for (var i = 0; i < pages.length; i++) _visited.contains(i) ? pages[i] : const SizedBox.shrink()]),
      bottomNavigationBar: _BottomNav(
        tab: _tab,
        onTab: go,
        onScan: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const OutboundHeaderScreen())),
      ),
    );
  }
}

class _BottomNav extends StatelessWidget {
  const _BottomNav({required this.tab, required this.onTab, required this.onScan});
  final int tab;
  final ValueChanged<int> onTab;
  final VoidCallback onScan;

  Widget _item(int i, IconData icon, String label) {
    final on = tab == i;
    final color = on ? (i == 3 ? C.outbound : C.inbound) : C.muted;
    return Expanded(
      child: InkWell(
        onTap: () => onTab(i),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 10),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Icon(icon, color: color),
            const SizedBox(height: 3),
            Text(label, style: TextStyle(fontSize: 11, color: color, fontWeight: on ? FontWeight.w600 : FontWeight.w500)),
          ]),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: const BoxDecoration(color: Colors.white, border: Border(top: BorderSide(color: C.line))),
      padding: EdgeInsets.only(bottom: MediaQuery.of(context).padding.bottom),
      child: Row(children: [
        _item(0, Icons.home_outlined, 'Beranda'),
        _item(1, Icons.assignment_outlined, 'Tugas'),
        _item(2, Icons.download_outlined, 'Inbound'),
        Expanded(
          child: Center(
            child: Material(
              color: C.ink,
              borderRadius: BorderRadius.circular(18),
              child: InkWell(
                borderRadius: BorderRadius.circular(18),
                onTap: onScan,
                child: const SizedBox(width: 56, height: 52, child: Icon(Icons.qr_code_scanner, color: Colors.white, semanticLabel: 'Scan QR')),
              ),
            ),
          ),
        ),
        _item(3, Icons.upload_outlined, 'Outbound'),
        _item(4, Icons.scale_outlined, 'Timbang'),
      ]),
    );
  }
}

class HomeTab extends StatefulWidget {
  const HomeTab({super.key, required this.onGo});
  final ValueChanged<int> onGo;
  @override
  State<HomeTab> createState() => _HomeTabState();
}

class _HomeTabState extends State<HomeTab> {
  List<Map<String, dynamic>> _in = [];
  List<Map<String, dynamic>> _out = [];
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
      final r = await Future.wait([Api.docs('inbound'), Api.docs('outbound')]);
      if (!mounted) return;
      setState(() {
        _in = r[0];
        _out = r[1];
      });
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  bool _today(Map<String, dynamic> d) {
    final dt = toDate(d['docDate']);
    final n = DateTime.now();
    return dt != null && dt.year == n.year && dt.month == n.month && dt.day == n.day;
  }

  @override
  Widget build(BuildContext context) {
    final hour = DateTime.now().hour;
    final greet = hour < 11 ? 'Selamat pagi' : (hour < 15 ? 'Selamat siang' : (hour < 18 ? 'Selamat sore' : 'Selamat malam'));
    final waitPt = _in.where((d) => d['status'] == 'Menunggu PT').length;
    final ready = [..._in, ..._out].where((d) => d['status'] == 'Siap cetak').length;
    final waitDo = _out.where((d) => d['status'] == 'Menunggu DO').length;
    final recent = [..._in, ..._out]..sort((a, b) => toI(b['docEntry']).compareTo(toI(a['docEntry'])));

    return RefreshIndicator(
      onRefresh: _load,
      child: ListView(
        padding: EdgeInsets.fromLTRB(20, MediaQuery.of(context).padding.top + 20, 20, 24),
        children: [
          Row(children: [
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                const Text('GUDANG ATM', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: C.muted, letterSpacing: 1)),
                Text('$greet, ${Session.I.userName}', style: const TextStyle(fontSize: 24, fontWeight: FontWeight.w700)),
              ]),
            ),
            IconButton.filled(
              style: IconButton.styleFrom(backgroundColor: C.ink),
              tooltip: 'Pengaturan',
              onPressed: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const SettingsScreen(loggedIn: true))),
              icon: const Icon(Icons.person_outline, color: Colors.white),
            ),
          ]),
          const SizedBox(height: 20),
          if (_loading) const LinearProgressIndicator(minHeight: 2),
          if (_error != null) ErrorView(_error!, onRetry: _load),
          Row(children: [
            Expanded(child: _stat('INBOUND HARI INI', _in.where(_today).length, '$waitPt menunggu PT', C.inbound)),
            const SizedBox(width: 12),
            Expanded(child: _stat('OUTBOUND HARI INI', _out.where(_today).length, '$waitDo menunggu DO', C.outbound)),
          ]),
          const SizedBox(height: 16),
          _bigAction(C.inbound, Icons.download_outlined, 'Terima Barang', 'Inbound · isi header & detail barang',
              () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const InboundHeaderScreen())).then((_) => _load())),
          const SizedBox(height: 10),
          _bigAction(C.outbound, Icons.upload_outlined, 'Kirim Barang', 'Outbound · OB / KR / RP · scan palet',
              () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const OutboundHeaderScreen())).then((_) => _load())),
          const SizedBox(height: 10),
          Row(children: [
            _quick(Icons.qr_code_scanner, 'Scan QR',
                () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const OutboundHeaderScreen()))),
            const SizedBox(width: 10),
            _quick(Icons.print_outlined, 'Cetak QR ($ready)', () => widget.onGo(2)),
            const SizedBox(width: 10),
            _quick(Icons.inventory_2_outlined, 'Laporan / Stok', () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const ReportsMenu()))),
          ]),
          const SizedBox(height: 16),
          Box(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              const Text('Aktivitas terakhir', style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600)),
              const SizedBox(height: 8),
              if (recent.isEmpty) const Text('Belum ada dokumen', style: TextStyle(color: C.muted)),
              for (final d in recent.take(5))
                Container(
                  padding: const EdgeInsets.symmetric(vertical: 10),
                  decoration: const BoxDecoration(border: Border(top: BorderSide(color: C.lineSoft))),
                  child: Row(children: [
                    Icon('${d['objType']}' == '6730' ? Icons.south : Icons.north,
                        size: 18, color: '${d['objType']}' == '6730' ? C.inbound : C.outbound),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        Text('${d['docEntry']} · ${d['trxCode']}', style: const TextStyle(fontWeight: FontWeight.w500)),
                        Text('${fmt(toD(d['qtyKg']))} KG · ${fmt(toD(d['qtySak']))} sak',
                            style: const TextStyle(fontFamily: mono, fontSize: 12, color: C.muted)),
                      ]),
                    ),
                    StatusPill((d['status'] ?? '').toString(), accent: '${d['objType']}' == '6730' ? C.inbound : C.outbound),
                  ]),
                ),
            ]),
          ),
        ],
      ),
    );
  }

  Widget _stat(String label, int value, String sub, Color accent) => Box(
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(label, style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: accent, letterSpacing: 0.7)),
          Text('$value', style: const TextStyle(fontFamily: mono, fontSize: 32, fontWeight: FontWeight.w700)),
          Text(sub, style: const TextStyle(fontSize: 13, color: C.muted)),
        ]),
      );

  Widget _bigAction(Color color, IconData icon, String title, String sub, VoidCallback onTap) => Material(
        color: color,
        borderRadius: BorderRadius.circular(16),
        child: InkWell(
          borderRadius: BorderRadius.circular(16),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.all(18),
            child: Row(children: [
              Container(
                width: 48,
                height: 48,
                decoration: BoxDecoration(color: Colors.white24, borderRadius: BorderRadius.circular(12)),
                child: Icon(icon, color: Colors.white),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(title, style: const TextStyle(color: Colors.white, fontSize: 17, fontWeight: FontWeight.w700)),
                  Text(sub, style: const TextStyle(color: Colors.white70, fontSize: 13)),
                ]),
              ),
              const Icon(Icons.chevron_right, color: Colors.white),
            ]),
          ),
        ),
      );

  Widget _quick(IconData icon, String label, VoidCallback onTap) => Expanded(
        child: Box(
          radius: 14,
          padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 4),
          onTap: onTap,
          child: Column(children: [
            Icon(icon),
            const SizedBox(height: 6),
            Text(label, textAlign: TextAlign.center, style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w500)),
          ]),
        ),
      );
}
