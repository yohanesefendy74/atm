import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../api.dart';
import '../theme.dart';
import '../widgets.dart';
import 'home.dart';
import 'settings.dart';

class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key});
  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final _user = TextEditingController(text: Session.I.rememberedUser ?? '');
  final _pass = TextEditingController();
  bool _show = false;
  bool _remember = Session.I.rememberedUser != null;
  String _lang = 'Indonesia';
  bool _busy = false;
  String? _update;

  @override
  void initState() {
    super.initState();
    Api.cekUpdate().then((u) {
      if (mounted) setState(() => _update = u);
    });
  }

  @override
  void dispose() {
    _user.dispose();
    _pass.dispose();
    super.dispose();
  }

  Future<void> _login() async {
    if (_user.text.trim().isEmpty || _pass.text.isEmpty) {
      showError(context, 'UserName dan Password wajib diisi');
      return;
    }
    setState(() => _busy = true);
    try {
      await Api.login(_user.text.trim(), _pass.text);
      await Session.I.saveRememberedUser(_remember ? _user.text.trim() : null);
      if (!mounted) return;
      Navigator.of(context).pushReplacement(MaterialPageRoute(builder: (_) => const Shell()));
    } catch (e) {
      if (mounted) showError(context, e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Widget _row(String label, Widget field) => Padding(
        padding: const EdgeInsets.only(bottom: 16),
        child: Row(children: [
          SizedBox(width: 108, child: Text(label, style: const TextStyle(fontSize: 15))),
          Expanded(child: field),
        ]),
      );

  @override
  Widget build(BuildContext context) {
    final border = OutlineInputBorder(borderRadius: BorderRadius.circular(6), borderSide: const BorderSide(color: Color(0xFFA8ABB0)));
    final deco = InputDecoration(
      border: border,
      enabledBorder: border,
      focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(6), borderSide: const BorderSide(color: C.loginNavy)),
    );
    return Scaffold(
      backgroundColor: Colors.white,
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(24, 16, 24, 24),
          children: [
            Align(
              alignment: Alignment.topRight,
              child: IconButton(
                tooltip: 'Pengaturan server',
                icon: const Icon(Icons.settings_outlined, color: C.muted),
                onPressed: () async {
                  await Navigator.of(context).push(MaterialPageRoute(builder: (_) => const SettingsScreen(loggedIn: false)));
                  if (mounted) setState(() {});
                },
              ),
            ),
            if (_update != null)
              Box(color: C.amberTint, border: C.amberTint, child: Text('Versi baru aplikasi tersedia. Buka $_update di browser HP untuk mengunduh.', style: const TextStyle(color: C.amberText))),
            Center(child: Image.asset('assets/logo.png', width: 280)),
            const SizedBox(height: 48),
            _row('UserName', TextField(controller: _user, decoration: deco, textInputAction: TextInputAction.next)),
            _row(
              'Password',
              TextField(
                controller: _pass,
                obscureText: !_show,
                onSubmitted: (_) => _login(),
                decoration: deco.copyWith(
                  hintText: 'Password',
                  suffixIcon: IconButton(
                    tooltip: _show ? 'Sembunyikan password' : 'Tampilkan password',
                    icon: Icon(_show ? Icons.visibility_off_outlined : Icons.visibility_outlined),
                    onPressed: () => setState(() => _show = !_show),
                  ),
                ),
              ),
            ),
            _row(
              'Language',
              DropdownButtonFormField<String>(
                value: _lang,
                decoration: deco,
                items: const [
                  DropdownMenuItem(value: 'Indonesia', child: Text('Indonesia')),
                  DropdownMenuItem(value: 'English', child: Text('English')),
                ],
                onChanged: (v) => setState(() => _lang = v ?? 'Indonesia'),
              ),
            ),
            CheckboxListTile(
              value: _remember,
              onChanged: (v) => setState(() => _remember = v ?? false),
              controlAffinity: ListTileControlAffinity.leading,
              contentPadding: EdgeInsets.zero,
              title: const Text('Remember me', style: TextStyle(color: C.loginNavy)),
            ),
            const SizedBox(height: 16),
            BigButton(label: 'Login', color: C.loginRed, busy: _busy, onPressed: _login),
            const SizedBox(height: 14),
            BigButton(
              label: 'Change Password',
              color: C.loginNavy,
              onPressed: () => showInfo(context, 'Ganti password dilakukan oleh Admin di SAP / CMS'),
            ),
            const SizedBox(height: 16),
            Center(
              child: TextButton(
                onPressed: () => SystemNavigator.pop(),
                child: const Text('Exit', style: TextStyle(color: C.loginNavy, fontWeight: FontWeight.w700, fontSize: 16)),
              ),
            ),
            const SizedBox(height: 24),
            Text('Server: ${Session.I.baseUrl}', textAlign: TextAlign.center, style: const TextStyle(fontSize: 12, color: C.muted)),
          ],
        ),
      ),
    );
  }
}
