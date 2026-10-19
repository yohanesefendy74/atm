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
  await SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp]);
  runApp(const GudangApp());
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
