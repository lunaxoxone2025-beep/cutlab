import 'package:flutter/material.dart';

/// CUTLAB design tokens. Dark, neutral surfaces with one accent colour,
/// carried over from CutLab Lite so both editions feel like one product.
abstract final class CutlabColors {
  static const background = Color(0xFF0D0D10);
  static const surface = Color(0xFF16161B);
  static const surfaceRaised = Color(0xFF202028);
  static const outline = Color(0xFF2A2A33);
  static const text = Color(0xFFF3F3F6);
  static const textMuted = Color(0xFF8D8D99);
  static const accent = Color(0xFF19E3C4);
  static const onAccent = Color(0xFF03211C);
  static const videoTrack = Color(0xFF3A3A48);
  static const audioTrack = Color(0xFF1D5FB8);
  static const textTrack = Color(0xFF8F5CFF);
  static const danger = Color(0xFFFF4D6A);
}

abstract final class CutlabSpacing {
  static const xs = 4.0;
  static const sm = 8.0;
  static const md = 12.0;
  static const lg = 16.0;
  static const xl = 24.0;
  static const radius = 12.0;
}

ThemeData buildCutlabTheme() {
  const scheme = ColorScheme.dark(
    primary: CutlabColors.accent,
    onPrimary: CutlabColors.onAccent,
    secondary: CutlabColors.textTrack,
    surface: CutlabColors.surface,
    onSurface: CutlabColors.text,
    error: CutlabColors.danger,
    outline: CutlabColors.outline,
  );
  final base = ThemeData(colorScheme: scheme, useMaterial3: true, brightness: Brightness.dark);
  return base.copyWith(
    scaffoldBackgroundColor: CutlabColors.background,
    appBarTheme: const AppBarTheme(
      backgroundColor: CutlabColors.background,
      foregroundColor: CutlabColors.text,
      elevation: 0,
      centerTitle: false,
    ),
    cardTheme: const CardTheme(
      color: CutlabColors.surface,
      elevation: 0,
      margin: EdgeInsets.zero,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.all(Radius.circular(CutlabSpacing.radius)),
        side: BorderSide(color: CutlabColors.outline),
      ),
    ),
    inputDecorationTheme: const InputDecorationTheme(
      filled: true,
      fillColor: CutlabColors.surfaceRaised,
      border: OutlineInputBorder(borderRadius: BorderRadius.all(Radius.circular(CutlabSpacing.radius))),
    ),
    textTheme: base.textTheme.apply(bodyColor: CutlabColors.text, displayColor: CutlabColors.text),
  );
}
