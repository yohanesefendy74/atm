import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/date_symbol_data_local.dart';

import 'api.dart';
import 'screens/login.dart';
import 'theme.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await initializeDateFormatting('id');
  await Session.I.load();
  HttpOverrides.global = _InternalCert();
  await SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp]);
  runApp(const GudangApp());
}

/// Server internal memakai sertifikat self-signed: terima HANYA untuk host server yang diisi di Pengaturan.
class _InternalCert extends HttpOverrides {
  @override
  HttpClient createHttpClient(SecurityContext? context) {
    final c = super.createHttpClient(context);
    c.badCertificateCallback = (cert, host, port) => host == (Uri.tryParse(Session.I.baseUrl)?.host ?? '');
    return c;
  }
}

class GudangApp extends StatelessWidget {
  const GudangApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Gudang ATM',
      debugShowCheckedModeBanner: false,
      theme: buildTheme(),
      home: const LoginScreen(),
    );
  }
}
