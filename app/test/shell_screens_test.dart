import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gudang_atm/api.dart';
import 'package:gudang_atm/screens/home.dart';
import 'package:gudang_atm/theme.dart';

/// Menggambar menu utama (Shell) di ukuran HP Android, mengetuk tiap tab, menyimpan gambar ke test/goldens/.
/// Server tidak ada di test -> tiap layar menampilkan pesan gagal koneksi; yang dicek adalah tata letaknya.
Future<void> _font(String family, List<String> files) async {
  final l = FontLoader(family);
  for (final f in files) {
    l.addFont(File(f).readAsBytes().then((b) => ByteData.view(b.buffer)));
  }
  await l.load();
}

void main() {
  setUpAll(() async {
    await _font('IBMPlexSans', ['assets/fonts/IBMPlexSans-Regular.ttf', 'assets/fonts/IBMPlexSans-SemiBold.ttf', 'assets/fonts/IBMPlexSans-Bold.ttf']);
    await _font('IBMPlexMono', ['assets/fonts/IBMPlexMono-Regular.ttf']);
    await _font('MaterialIcons', ['${Platform.environment['FLUTTER_ROOT']}/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf']);
    Session.I.baseUrl = 'http://127.0.0.1:9';
    Session.I.user = {'userCode': 'krani1', 'name': 'Krani Satu'};
  });

  testWidgets('Shell: semua tab tampil', (tester) async {
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 2.75;
    tester.view.padding = const FakeViewPadding(top: 80, bottom: 60);
    tester.view.viewPadding = const FakeViewPadding(top: 80, bottom: 60);
    final errors = <String>[];
    final old = FlutterError.onError;
    FlutterError.onError = (d) => errors.add(d.exceptionAsString().split('\n').first);

    await tester.pumpWidget(MaterialApp(theme: buildTheme(), home: const Shell()));
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 300)));
    await tester.pump(const Duration(milliseconds: 500));
    await expectLater(find.byType(Shell), matchesGoldenFile('goldens/tab0_beranda.png'));

    const labels = ['Tugas', 'Inbound', 'Outbound', 'Timbang'];
    for (var i = 0; i < labels.length; i++) {
      await tester.tap(find.text(labels[i]).last);
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 300)));
      await tester.pump(const Duration(milliseconds: 500));
      await expectLater(find.byType(Shell), matchesGoldenFile('goldens/tab${i + 1}_${labels[i].toLowerCase()}.png'));
    }
    FlutterError.onError = old;
    // ignore: avoid_print
    print('ERRORS(${errors.length}):\n${errors.toSet().join('\n')}');
    File('test/goldens/errors.txt').writeAsStringSync(errors.toSet().join('\n'));
    addTearDown(tester.view.reset);
  });
}
