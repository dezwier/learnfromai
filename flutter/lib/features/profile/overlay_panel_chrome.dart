import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/physics.dart';

/// Shared fullscreen overlay chrome: top-right close + interactive left-edge drag dismiss.
class OverlayPanel extends StatefulWidget {
  const OverlayPanel({
    super.key,
    required this.onDismiss,
    required this.child,
    this.bottom,
  });

  final VoidCallback onDismiss;
  final Widget child;
  final Widget? bottom;

  static const double closeSize = 44;
  static const double closeInset = 10;
  static const double edgeWidth = 44;

  static double bottomClearance(BuildContext context, {required bool hasBottom}) {
    if (!hasBottom) return MediaQuery.paddingOf(context).bottom + 24;
    return OverlayLessonFooter.height(context) + 24;
  }

  @override
  State<OverlayPanel> createState() => _OverlayPanelState();
}

class _OverlayPanelState extends State<OverlayPanel>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  var _dragPx = 0.0;
  var _grabPanelPx = 0.0;
  var _grabGlobalX = 0.0;
  var _dragging = false;
  var _dismissing = false;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController.unbounded(vsync: this)
      ..addListener(() {
        if (_dragging) return;
        final width = MediaQuery.sizeOf(context).width;
        setState(() => _dragPx = _controller.value.clamp(0.0, width));
      });
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  double get _width => MediaQuery.sizeOf(context).width;

  bool get _textInputFocused {
    final primary = FocusManager.instance.primaryFocus;
    if (primary == null || !primary.hasFocus) return false;
    final ctx = primary.context;
    if (ctx == null) return false;
    return ctx.widget is EditableText;
  }

  void _onDragStart(DragStartDetails details) {
    if (_dismissing || _textInputFocused) return;
    _controller.stop();
    _grabGlobalX = details.globalPosition.dx;
    _grabPanelPx = _dragPx;
    setState(() => _dragging = true);
  }

  void _onDragUpdate(DragUpdateDetails details) {
    if (_dismissing || !_dragging) return;
    final next = (_grabPanelPx + (details.globalPosition.dx - _grabGlobalX))
        .clamp(0.0, _width);
    if (next == _dragPx) return;
    setState(() => _dragPx = next);
  }

  void _onDragEnd(DragEndDetails details) {
    if (_dismissing) return;
    setState(() => _dragging = false);
    final velocity = details.primaryVelocity ?? 0;
    final shouldDismiss = _dragPx > _width * 0.25 || velocity > 600;
    if (shouldDismiss) {
      unawaited(_animateDismiss(velocity: math.max(velocity, 900)));
    } else {
      _springTo(0, velocity: velocity);
    }
  }

  void _onDragCancel() {
    if (_dismissing) return;
    setState(() => _dragging = false);
    _springTo(0);
  }

  void _springTo(double target, {double velocity = 0}) {
    _controller.value = _dragPx;
    final simulation = SpringSimulation(
      const SpringDescription(mass: 1, stiffness: 180, damping: 22),
      _dragPx,
      target,
      velocity / 1000,
    );
    unawaited(_controller.animateWith(simulation).then((_) {
      if (!mounted) return;
      setState(() => _dragPx = target);
    }));
  }

  Future<void> _animateDismiss({double velocity = 0}) async {
    if (_dismissing) return;
    _dismissing = true;
    setState(() => _dragging = false);
    _controller.value = _dragPx;
    final remaining = (_width - _dragPx).clamp(0.0, _width);
    final speed = math.max(velocity.abs(), 1200.0);
    final ms = (remaining / speed * 1000).clamp(140.0, 280.0).round();
    // Tween dismiss (not spring) so onDismiss always fires promptly.
    await _controller.animateTo(
      _width,
      duration: Duration(milliseconds: ms),
      curve: Curves.easeOutCubic,
    );
    if (!mounted) return;
    setState(() => _dragPx = _width);
    widget.onDismiss();
  }

  void _closePressed() {
    unawaited(_animateDismiss(velocity: 1600));
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final top = MediaQuery.paddingOf(context).top;
    final width = _width;
    final progress = width <= 0 ? 0.0 : (_dragPx / width).clamp(0.0, 1.0);

    return Stack(
      fit: StackFit.expand,
      children: [
        // Absorb hits so the graph/HUD under a sliding panel can't be tapped.
        const Positioned.fill(
          child: ColoredBox(color: Color(0x00000000)),
        ),
        // Soft scrim only — avoid Material elevation, which casts a harsh
        // moving shadow/glare against the graph while the panel slides.
        if (progress > 0)
          Positioned.fill(
            child: IgnorePointer(
              child: ColoredBox(
                color: Colors.black.withValues(alpha: 0.12 * (1 - progress)),
              ),
            ),
          ),
        // Panel slides; gesture layer stays fixed on screen so the drag never drops.
        // Clip so rotated/scaled children (testing backdrop) can't bleed past the edge.
        Transform.translate(
          offset: Offset(_dragPx, 0),
          child: Material(
            color: scheme.surface,
            elevation: 0,
            clipBehavior: Clip.hardEdge,
            child: Stack(
              fit: StackFit.expand,
              clipBehavior: Clip.hardEdge,
              children: [
                Positioned.fill(child: widget.child),
                if (widget.bottom != null) widget.bottom!,
                if (progress > 0)
                  Positioned(
                    left: 0,
                    top: 0,
                    bottom: 0,
                    width: 1,
                    child: ColoredBox(
                      color: Colors.black.withValues(alpha: 0.08 * (1 - progress)),
                    ),
                  ),
                Positioned(
                  top: top + OverlayPanel.closeInset,
                  right: OverlayPanel.closeInset + 2,
                  child: OverlayCloseButton(onPressed: _closePressed),
                ),
              ],
            ),
          ),
        ),
        Positioned(
          left: 0,
          top: 0,
          bottom: 0,
          width: OverlayPanel.edgeWidth,
          child: GestureDetector(
            behavior: HitTestBehavior.translucent,
            onHorizontalDragStart: _onDragStart,
            onHorizontalDragUpdate: _onDragUpdate,
            onHorizontalDragEnd: _onDragEnd,
            onHorizontalDragCancel: _onDragCancel,
          ),
        ),
      ],
    );
  }
}

/// Comfy circular dismiss control for overlay panels.
class OverlayCloseButton extends StatelessWidget {
  const OverlayCloseButton({super.key, required this.onPressed});

  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final dark = scheme.brightness == Brightness.dark;
    final dialFill = dark ? const Color(0xFFE8EAEE) : const Color(0xFFF7F6F4);
    final rim = scheme.primary.withValues(alpha: 0.55);
    final iconColor = dark ? const Color(0xFF2A2E33) : const Color(0xFF3A4048);

    return Tooltip(
      message: 'Close',
      child: Material(
        elevation: 3,
        shadowColor: Colors.black.withValues(alpha: 0.28),
        shape: CircleBorder(side: BorderSide(color: rim, width: 1.4)),
        color: dialFill.withValues(alpha: 0.96),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onPressed,
          customBorder: const CircleBorder(),
          child: SizedBox(
            width: OverlayPanel.closeSize,
            height: OverlayPanel.closeSize,
            child: Icon(Icons.close_rounded, size: 24, color: iconColor),
          ),
        ),
      ),
    );
  }
}

/// Bottom lesson controls: smaller back on the left, wide continue filling the rest.
class OverlayLessonFooter extends StatelessWidget {
  const OverlayLessonFooter({
    super.key,
    required this.onContinue,
    this.onBack,
    this.continueLabel = 'Continue',
    this.continueEnabled = true,
  });

  final VoidCallback onContinue;
  final VoidCallback? onBack;
  final String continueLabel;
  final bool continueEnabled;

  static const double rowHeight = 72;
  static const double fadeExtra = 56;

  static double height(BuildContext context) =>
      MediaQuery.paddingOf(context).bottom +
      MediaQuery.viewInsetsOf(context).bottom +
      rowHeight;

  static double fadeHeight(BuildContext context) => height(context) + fadeExtra;

  @override
  Widget build(BuildContext context) {
    final bottomInset =
        MediaQuery.paddingOf(context).bottom + MediaQuery.viewInsetsOf(context).bottom;
    final dark = Theme.of(context).brightness == Brightness.dark;
    final scheme = Theme.of(context).colorScheme;

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
                            scheme.surface.withValues(alpha: 0.95),
                            scheme.surface.withValues(alpha: 0.78),
                            scheme.surface.withValues(alpha: 0.0),
                          ],
                    stops: const [0.0, 0.45, 1.0],
                  ),
                ),
              ),
            ),
          ),
          Positioned(
            left: 0,
            right: 0,
            bottom: bottomInset + 10,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20),
              child: Row(
                children: [
                  if (onBack != null) ...[
                    TextButton.icon(
                      onPressed: onBack,
                      icon: const Icon(Icons.arrow_back_rounded, size: 18),
                      label: const Text('Back'),
                      style: TextButton.styleFrom(
                        foregroundColor: scheme.onSurface.withValues(alpha: 0.72),
                        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 12),
                        textStyle: const TextStyle(
                          fontWeight: FontWeight.w600,
                          fontSize: 14,
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                  ],
                  Expanded(
                    child: FilledButton(
                      onPressed: continueEnabled ? onContinue : null,
                      style: FilledButton.styleFrom(
                        minimumSize: const Size.fromHeight(52),
                        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(16),
                        ),
                        textStyle: const TextStyle(
                          fontWeight: FontWeight.w700,
                          fontSize: 16,
                        ),
                      ),
                      child: Text(continueLabel),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
