import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

/// Warna & tipografi mengikuti desain Gudang ATM.
class C {
  static const ink = Color(0xFF16191D);
  static const inbound = Color(0xFF0A57A8);
  static const inboundTint = Color(0xFFE6EEF8);
  static const outbound = Color(0xFFB93E0B);
  static const outboundTint = Color(0xFFFBEDE5);
  static const green = Color(0xFF1F7A3A);
  static const greenTint = Color(0xFFE3F2E7);
  static const greenText = Color(0xFF1F6B34);
  static const amberTint = Color(0xFFFFF4D6);
  static const amberText = Color(0xFF7A5300);
  static const ground = Color(0xFFF2F3EF);
  static const line = Color(0xFFDADDD6);
  static const lineSoft = Color(0xFFECEDE8);
  static const field = Color(0xFFC9CDC5);
  static const muted = Color(0xFF545B63);
  static const disabled = Color(0xFF9AA0A6);
  static const loginRed = Color(0xFFD51F26);
  static const loginNavy = Color(0xFF19037B);
}

const mono = 'IBMPlexMono';

ThemeData buildTheme() {
  final base = ThemeData(
    useMaterial3: true,
    fontFamily: 'IBMPlexSans',
    colorScheme: ColorScheme.fromSeed(seedColor: C.inbound, surface: Colors.white),
    scaffoldBackgroundColor: C.ground,
  );
  return base.copyWith(
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: Colors.white,
      contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
      border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: const BorderSide(color: C.field)),
      enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: const BorderSide(color: C.field)),
      focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: const BorderSide(color: C.ink, width: 2)),
    ),
    snackBarTheme: const SnackBarThemeData(behavior: SnackBarBehavior.floating),
  );
}

final _num = NumberFormat.decimalPattern('id');
String fmt(num? v) => v == null ? '-' : _num.format(v);
String fmtDate(DateTime? d) => d == null ? '-' : DateFormat('dd/MM/yyyy').format(d);

double toD(dynamic v) {
  if (v == null) return 0;
  if (v is num) return v.toDouble();
  return double.tryParse(v.toString()) ?? 0;
}

int toI(dynamic v) => toD(v).round();

DateTime? toDate(dynamic v) => v == null ? null : DateTime.tryParse(v.toString());
