import 'package:flutter/material.dart';

/// Themed splash: honeycomb mark + "learnfromai" in TT Ramillas.
class BrandedSplash extends StatelessWidget {
  const BrandedSplash({super.key});

  static const paperLight = Color(0xFFF4F1EA);
  static const paperDark = Color(0xFF16181C);
  static const inkLight = Color(0xFF1C2430);
  static const inkDark = Color(0xFFF4F1EA);

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    final bg = dark ? paperDark : paperLight;
    final ink = dark ? inkDark : inkLight;
    final logoAsset = dark ? 'assets/branding/app_icon_dark.png' : 'assets/branding/app_icon.png';

    return Scaffold(
      backgroundColor: bg,
      body: SafeArea(
        child: Center(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 32),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                ClipRRect(
                  borderRadius: BorderRadius.circular(28),
                  child: Image.asset(
                    logoAsset,
                    width: 128,
                    height: 128,
                    fit: BoxFit.cover,
                    filterQuality: FilterQuality.high,
                  ),
                ),
                const SizedBox(height: 28),
                Text(
                  'learnfromai',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontFamily: 'tt_ramilas',
                    fontWeight: FontWeight.w500,
                    fontSize: 28,
                    height: 1.1,
                    letterSpacing: -0.4,
                    color: ink,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
