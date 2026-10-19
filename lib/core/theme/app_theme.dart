import 'package:flutter/material.dart';

class AllwaysTheme {
  // Restored from the original ALLways customer app's pink/purple visual identity.
  static const green = Color(0xFFC21868);
  static const greenBright = Color(0xFFE65C91);
  static const background = Color(0xFFFFF8FB);
  static const ink = Color(0xFF241923);
  static const line = Color(0xFFF0DDE6);
  static const blush = Color(0xFFFFE1EC);
  static const purple = Color(0xFF7C3AED);

  static ThemeData get light {
    final scheme = ColorScheme.fromSeed(
      seedColor: green,
      brightness: Brightness.light,
    );
    return ThemeData(
      useMaterial3: true,
      colorScheme: scheme.copyWith(
        primary: green,
        secondary: purple,
        surface: Colors.white,
      ),
      scaffoldBackgroundColor: background,
      appBarTheme: const AppBarTheme(
        backgroundColor: Color(0xFFFFFBFD),
        foregroundColor: ink,
        elevation: 0,
        surfaceTintColor: Colors.transparent,
      ),
      cardTheme: CardThemeData(
        color: Colors.white,
        elevation: 0,
        margin: EdgeInsets.zero,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(20),
          side: const BorderSide(color: line),
        ),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: const Color(0xFFFFF7FA),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(20),
          borderSide: const BorderSide(color: line),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(20),
          borderSide: const BorderSide(color: line),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(20),
          borderSide: const BorderSide(color: green, width: 1.5),
        ),
      ),
    );
  }

  static ThemeData get dark {
    final scheme = ColorScheme.fromSeed(
      seedColor: greenBright,
      brightness: Brightness.dark,
    );
    return ThemeData(
      useMaterial3: true,
      colorScheme: scheme.copyWith(primary: greenBright, secondary: purple),
      scaffoldBackgroundColor: const Color(0xFF171219),
      appBarTheme: const AppBarTheme(
        backgroundColor: Color(0xFF201821),
        foregroundColor: Colors.white,
        elevation: 0,
      ),
      cardTheme: CardThemeData(
        color: const Color(0xFF251D26),
        elevation: 0,
        margin: EdgeInsets.zero,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(20),
          side: const BorderSide(color: Color(0xFF443442)),
        ),
      ),
    );
  }
}
