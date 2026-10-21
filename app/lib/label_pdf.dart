import 'dart:typed_data';

import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:printing/printing.dart';

import 'theme.dart';
import 'tspl.dart';

/// Label dalam bentuk PDF (cadangan bila printer Bluetooth tidak ada/tidak terdeteksi, dan untuk iPhone).
/// Dicetak lewat dialog cetak sistem (AirPrint di iPhone, layanan cetak Android) atau dibagikan sebagai file.
class LabelPdf {
  static Future<Uint8List> build(List<LabelData> labels, LabelSize size) async {
    final doc = pw.Document();
    final fmtPage = PdfPageFormat(size.w * PdfPageFormat.mm, size.h * PdfPageFormat.mm, marginAll: 2 * PdfPageFormat.mm);
    final big = size.w >= 100 ? 22.0 : (size.w >= 80 ? 18.0 : 14.0);
    final body = size.w >= 100 ? 12.0 : (size.w >= 80 ? 10.0 : 8.0);
    for (final l in labels) {
      final pack = l.packKg == l.packKg.roundToDouble() ? l.packKg.toInt().toString() : fmt(l.packKg);
      for (var i = 0; i < l.copies; i++) {
        doc.addPage(pw.Page(
          pageFormat: fmtPage,
          build: (_) => pw.Row(crossAxisAlignment: pw.CrossAxisAlignment.start, children: [
            pw.Expanded(
              child: pw.Column(crossAxisAlignment: pw.CrossAxisAlignment.start, children: [
                pw.Text(l.containerDisplay, style: pw.TextStyle(fontSize: big, fontWeight: pw.FontWeight.bold)),
                pw.SizedBox(height: 4),
                pw.Text(fmtDate(l.date), style: pw.TextStyle(fontSize: body)),
                pw.Text(l.itemName.toUpperCase(), style: pw.TextStyle(fontSize: body)),
                pw.Text(l.brand.toUpperCase(), style: pw.TextStyle(fontSize: body)),
                pw.Text('@$pack', style: pw.TextStyle(fontSize: body)),
                pw.Text(l.ptName.toUpperCase(), style: pw.TextStyle(fontSize: body)),
                if (l.ruangan.isNotEmpty) pw.Text('RUANG ${l.ruangan.toUpperCase()}', style: pw.TextStyle(fontSize: body, fontWeight: pw.FontWeight.bold)),
                pw.Spacer(),
                pw.Text(l.qr, style: const pw.TextStyle(fontSize: 6)),
              ]),
            ),
            pw.SizedBox(width: 6),
            pw.Column(children: [
              pw.BarcodeWidget(barcode: pw.Barcode.qrCode(), data: l.qr, width: size.w * 0.3 * PdfPageFormat.mm, height: size.w * 0.3 * PdfPageFormat.mm),
              pw.SizedBox(height: 4),
              pw.Container(
                padding: const pw.EdgeInsets.all(3),
                decoration: pw.BoxDecoration(border: pw.Border.all(width: 1)),
                child: pw.Text('${fmt(l.sakPerPalet)} SAK', style: pw.TextStyle(fontSize: body, fontWeight: pw.FontWeight.bold)),
              ),
            ]),
          ]),
        ));
      }
    }
    return doc.save();
  }

  /// Membuka dialog cetak sistem / simpan PDF.
  static Future<void> cetak(List<LabelData> labels, LabelSize size) async {
    final bytes = await build(labels, size);
    await Printing.layoutPdf(
      name: 'Label-Gudang-ATM',
      format: PdfPageFormat(size.w * PdfPageFormat.mm, size.h * PdfPageFormat.mm),
      onLayout: (_) async => bytes,
    );
  }
}
