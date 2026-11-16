import 'package:flutter/material.dart';

/// Themed splash: honeycomb mark only (no title).
///
/// [markSize] matches the native launch image point size (256) from
/// `flutter_native_splash` so the logo does not jump when the Flutter splash takes over.
class BrandedSplash extends StatelessWidget {
  const BrandedSplash({super.key, this.dark});

  /// When set, ignores [Theme.of] so splash can match app preference before MaterialApp settles.
  final bool? dark;

  static const paperLight = Color(0xFFF4F1EA);
  static const paperDark = Color(0xFF16181C);

  /// Native LaunchImage / Android pre-12 splash mark size in logical pixels.
  static const double markSize = 256;

  @override
  Widget build(BuildContext context) {
    final useDark = dark ?? Theme.of(context).brightness == Brightness.dark;
    final bg = useDark ? paperDark : paperLight;
    final logoAsset =
        useDark ? 'assets/branding/splash_mark_dark.png' : 'assets/branding/splash_mark.png';

    return ColoredBox(
      color: bg,
      child: Center(
        child: Image.asset(
          logoAsset,
          width: markSize,
          height: markSize,
          fit: BoxFit.contain,
          filterQuality: FilterQuality.high,
        ),
      ),
    );
  }
}
