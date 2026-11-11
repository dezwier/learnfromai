import 'package:flutter/material.dart';

/// Bottom action strip for overlay panels — fade + fixed center button row.
class OverlayBottomChrome extends StatelessWidget {
  const OverlayBottomChrome({super.key, required this.child});

  final Widget child;

  static const double rowHeight = 88;
  static const double fadeExtra = 82;

  static double height(BuildContext context) =>
      MediaQuery.paddingOf(context).bottom + rowHeight;

  static double fadeHeight(BuildContext context) => height(context) + fadeExtra;

  @override
  Widget build(BuildContext context) {
    final bottomInset = MediaQuery.paddingOf(context).bottom;
    final dark = Theme.of(context).brightness == Brightness.dark;

    return Positioned(
      left: 0,
      right: 0,
      bottom: 0,
      height: fadeHeight(context),
      child: Stack(
        children: [
          Positioned.fill(
            child: IgnorePointer(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.bottomCenter,
                    end: Alignment.topCenter,
                    colors: dark
                        ? [
                            Colors.black.withValues(alpha: 0.82),
                            Colors.black.withValues(alpha: 0.45),
                            Colors.black.withValues(alpha: 0.0),
                          ]
                        : [
                            const Color(0xF2F4F1EA),
                            const Color(0xCCF4F1EA),
                            const Color(0x00F4F1EA),
                          ],
                    stops: const [0.0, 0.42, 1.0],
                  ),
                ),
              ),
            ),
          ),
          Positioned(
            left: 0,
            right: 0,
            bottom: bottomInset + 2,
            child: SizedBox(
              height: rowHeight - 2,
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: Center(child: child),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Circular overlay dismiss control with caption — Mesozoic layout, silver chrome.
class OverlayChromeButton extends StatelessWidget {
  const OverlayChromeButton({
    super.key,
    required this.onPressed,
    required this.icon,
    required this.label,
    this.tooltip,
  });

  static const double buttonSize = 54;

  final VoidCallback onPressed;
  final IconData icon;
  final String label;
  final String? tooltip;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final dark = scheme.brightness == Brightness.dark;
    final dialFill = dark ? const Color(0xFFE8EAEE) : const Color(0xFFF7F6F4);
    final rim = scheme.primary.withValues(alpha: 0.55);
    final iconColor = dark ? const Color(0xFF2A2E33) : const Color(0xFF3A4048);
    final labelColor = dark ? const Color(0xFFC8CDD3) : scheme.primary;

    Widget dial = Material(
      elevation: 4,
      shadowColor: Colors.black.withValues(alpha: 0.35),
      shape: CircleBorder(side: BorderSide(color: rim, width: 1.5)),
      color: dialFill.withValues(alpha: 0.96),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onPressed,
        customBorder: const CircleBorder(),
        child: SizedBox(
          width: buttonSize,
          height: buttonSize,
          child: Icon(icon, size: 28, color: iconColor),
        ),
      ),
    );

    if (tooltip != null) {
      dial = Tooltip(message: tooltip!, child: dial);
    }

    return Column(
      mainAxisSize: MainAxisSize.min,
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        dial,
        const SizedBox(height: 3),
        SizedBox(
          width: buttonSize + 8,
          height: 14,
          child: Text(
            label.toUpperCase(),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            textAlign: TextAlign.center,
            style: TextStyle(
              color: labelColor,
              fontSize: 10,
              fontWeight: FontWeight.w600,
              letterSpacing: 0.45,
              height: 1.1,
              shadows: dark
                  ? const [Shadow(blurRadius: 5, color: Color(0xA6000000))]
                  : const [Shadow(blurRadius: 4, color: Color(0x33000000))],
            ),
          ),
        ),
      ],
    );
  }
}
