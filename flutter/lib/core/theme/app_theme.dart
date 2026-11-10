import 'package:flutter/material.dart';

ThemeData buildTheme({Brightness brightness = Brightness.light}) {
  const accent = Color(0xFF1F4B6E);
  final dark = brightness == Brightness.dark;
  final paper = dark ? const Color(0xFF16181C) : const Color(0xFFF4F1EA);
  final ink = dark ? const Color(0xFFF4F1EA) : const Color(0xFF1C2430);
  return ThemeData(
    useMaterial3: true,
    brightness: brightness,
    fontFamily: 'tt_ramilas',
    colorScheme: ColorScheme.fromSeed(seedColor: accent, brightness: brightness).copyWith(
      surface: paper,
      primary: accent,
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
    cardTheme: CardThemeData(color: paper, elevation: 0, margin: EdgeInsets.zero),
    appBarTheme: AppBarTheme(backgroundColor: paper, foregroundColor: ink, elevation: 0, scrolledUnderElevation: 0),
    navigationBarTheme: NavigationBarThemeData(backgroundColor: paper, indicatorColor: const Color(0xFFD5E3EE)),
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
