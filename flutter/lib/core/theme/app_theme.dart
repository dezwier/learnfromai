import 'package:flutter/material.dart';

ThemeData buildTheme({Brightness brightness = Brightness.light}) {
  // Fancy neutral silver — not blue.
  const accent = Color(0xFF7A8088);
  final dark = brightness == Brightness.dark;
  // Dark: slightly deeper paper so elevated cards read as distinct shapes.
  final paper = dark ? const Color(0xFF12141A) : const Color(0xFFF4F1EA);
  final card = dark ? const Color.fromARGB(255, 27, 30, 37) : paper;
  final ink = dark ? const Color(0xFFF4F1EA) : const Color(0xFF1C2430);
  return ThemeData(
    useMaterial3: true,
    brightness: brightness,
    colorScheme: ColorScheme.fromSeed(seedColor: accent, brightness: brightness).copyWith(
      surface: paper,
      surfaceContainerHigh: card,
      surfaceContainerHighest: card,
      primary: accent,
      onPrimary: dark ? const Color(0xFF121417) : const Color(0xFFF7F6F4),
      onSurface: ink,
    ),
    scaffoldBackgroundColor: paper,
    pageTransitionsTheme: const PageTransitionsTheme(
      builders: {
        TargetPlatform.android: _InstantPageTransitionsBuilder(),
        TargetPlatform.iOS: _InstantPageTransitionsBuilder(),
        TargetPlatform.macOS: _InstantPageTransitionsBuilder(),
        TargetPlatform.linux: _InstantPageTransitionsBuilder(),
        TargetPlatform.windows: _InstantPageTransitionsBuilder(),
        TargetPlatform.fuchsia: _InstantPageTransitionsBuilder(),
      },
    ),
    cardTheme: CardThemeData(color: card, elevation: 0, margin: EdgeInsets.zero),
    appBarTheme: AppBarTheme(backgroundColor: paper, foregroundColor: ink, elevation: 0, scrolledUnderElevation: 0),
    navigationBarTheme: NavigationBarThemeData(
      backgroundColor: paper,
      indicatorColor: dark ? const Color(0xFF3A3E44) : const Color(0xFFD8DCE2),
    ),
    inputDecorationTheme: const InputDecorationTheme(border: OutlineInputBorder()),
  );
}

class _InstantPageTransitionsBuilder extends PageTransitionsBuilder {
  const _InstantPageTransitionsBuilder();

  @override
  Widget buildTransitions<T>(PageRoute<T> route, BuildContext context, Animation<double> animation, Animation<double> secondaryAnimation, Widget child) {
    return child;
  }
}
