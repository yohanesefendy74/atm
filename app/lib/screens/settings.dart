import 'package:flutter/material.dart';

import '../api.dart';
import '../printer.dart';
import '../theme.dart';
import '../tspl.dart';
import '../widgets.dart';
import 'login.dart';

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key, required this.loggedIn});
  final bool loggedIn;
  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  final _url = TextEditingController(text: Session.I.baseUrl);
  List<PrinterInfo>? _printers;
  bool _busy = false;

  @override
  void dispose() {
    _url.dispose();
    super.dispose();
  }

  Future<void> _saveUrl() async {
    setState(() => _busy = true);
    await Session.I.saveBaseUrl(_url.text);
    try {
      await Api.get('/api/health');
      if (mounted) showInfo(context, 'Server terhubung');
    } catch (e) {
      if (mounted) showError(context, e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _scanPrinters() async {
    try {
      final p = await LabelPrinter.paired();
      if (mounted) setState(() => _printers = p);
    } catch (e) {
      if (mounted) showError(context, e);
    }
  }

  Future<void> _testPrint() async {
    try {
      await LabelPrinter.send(Tspl.test(const LabelSize(100, 70)));
      if (mounted) showInfo(context, 'Label uji dikirim ke printer');
    } catch (e) {
      if (mounted) showError(context, e);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Column(children: [
        const Header(title: 'Pengaturan', eyebrow: 'Gudang ATM', accent: C.ink),
        Expanded(
          child: ListView(padding: const EdgeInsets.all(20), children: [
            if (widget.loggedIn)
              Box(
                child: Row(children: [
                  const Icon(Icons.person_outline),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Text(Session.I.userName, style: const TextStyle(fontWeight: FontWeight.w600)),
                      Text(Session.I.userCode, style: const TextStyle(color: C.muted, fontFamily: mono)),
                    ]),
                  ),
                ]),
              ),
            const SizedBox(height: 16),
            const FieldLabel('Alamat server API'),
            TextField(controller: _url, keyboardType: TextInputType.url, decoration: const InputDecoration(hintText: 'https://172.28.88.1:5443')),
            const Hint('Server GudangAtm.Api di jaringan kantor. HP harus terhubung ke WiFi gudang.'),
            const SizedBox(height: 10),
            BigButton(label: 'Simpan & tes koneksi', busy: _busy, onPressed: _saveUrl, outlined: true),
            const SizedBox(height: 24),
            const FieldLabel('Printer label (TSC / Xprinter, TSPL)'),
            Box(
              padding: const EdgeInsets.all(12),
              child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                Row(children: [
                  const Icon(Icons.print_outlined, color: C.greenText),
                  const SizedBox(width: 10),
                  Expanded(child: Text(Session.I.printerName ?? 'Belum dipilih', style: const TextStyle(fontWeight: FontWeight.w600))),
                  TextButton(onPressed: _scanPrinters, child: const Text('Pilih')),
                ]),
                if (_printers != null && _printers!.isEmpty)
                  const Hint('Tidak ada perangkat ter-pair. Pair printer dulu di Pengaturan Bluetooth Android.'),
                for (final p in _printers ?? <PrinterInfo>[])
                  ListTile(
                    dense: true,
                    title: Text(p.name),
                    subtitle: Text(p.mac, style: const TextStyle(fontFamily: mono)),
                    trailing: p.mac == Session.I.printerMac ? const Icon(Icons.check, color: C.greenText) : null,
                    onTap: () async {
                      await Session.I.savePrinter(p.mac, p.name);
                      if (mounted) setState(() {});
                    },
                  ),
              ]),
            ),
            const SizedBox(height: 10),
            BigButton(label: 'Cetak label uji', icon: Icons.print_outlined, onPressed: _testPrint, outlined: true),
            if (widget.loggedIn) ...[
              const SizedBox(height: 32),
              BigButton(
                label: 'Logout',
                color: C.loginRed,
                onPressed: () {
                  Session.I.logout();
                  Navigator.of(context).pushAndRemoveUntil(MaterialPageRoute(builder: (_) => const LoginScreen()), (_) => false);
                },
              ),
            ],
          ]),
        ),
      ]),
    );
  }
}
