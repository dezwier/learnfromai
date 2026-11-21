import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/physics.dart';
import 'package:flutter/services.dart';

/// Y-axis 3D flip shell (Talivo / Archipelago mechanics).
///
/// Tap left/right half to flip direction; horizontal drag rotates and snaps.
class TurnableYAxisCard extends StatefulWidget {
  const TurnableYAxisCard({
    super.key,
    required this.front,
    required this.back,
    this.borderRadius = 16,
    this.outerPadding = const EdgeInsets.symmetric(vertical: 8.0),
    this.resetIdentity,
    this.fixedFaceHeight,
    this.dismissKeyboardOnInteraction = false,
    this.prelayoutFacesForHeight = true,
    this.onPhysicalBackFaceVisibleChanged,
    this.initialBackFaceVisible = false,
    this.interactionEnabled = true,
  });

  final Widget front;
  final Widget back;
  final double borderRadius;
  final EdgeInsets outerPadding;

  /// When this value changes, the flip angle resets (e.g. pack id).
  final Object? resetIdentity;

  /// When set, both faces use this tight height; skips dynamic height equalization.
  final double? fixedFaceHeight;
  final bool dismissKeyboardOnInteraction;
  final bool prelayoutFacesForHeight;
  final ValueChanged<bool>? onPhysicalBackFaceVisibleChanged;

  /// Start showing the back face (π radians) instead of the front.
  final bool initialBackFaceVisible;

  /// When false, tap/drag flips are ignored (child interactions still work).
  final bool interactionEnabled;

  @override
  State<TurnableYAxisCard> createState() => _TurnableYAxisCardState();
}

class _TurnableYAxisCardState extends State<TurnableYAxisCard>
    with SingleTickerProviderStateMixin {
  late final AnimationController _flipController;
  double _cardWidth = 1;
  bool _isDraggingHorizontally = false;
  double _lastTapTargetAngle = 0;
  bool _reportedPhysicalBackFaceVisible = false;

  static const double _halfTurnRadians = math.pi;
  static const double _fullTurnRadians = 2 * math.pi;
  static const double _swipeSensitivity = 2;
  static const SpringDescription _flipSpring = SpringDescription(
    mass: 1.5,
    stiffness: 100,
    damping: 12,
  );

  double get _rotationAngle => _flipController.value;

  void _tearDownKeyboardConnection() {
    if (!mounted) return;
    FocusManager.instance.primaryFocus?.unfocus();
    SystemChannels.textInput.invokeMethod('TextInput.hide');
  }

  void _reportPhysicalBackFaceVisibleEdges() {
    final angle = _normalizedSignedAngle(_rotationAngle);
    final normalized = _normalizedAngle(angle);
    final visibleNow =
        normalized > (math.pi / 2) && normalized < (3 * math.pi / 2);
    if (visibleNow == _reportedPhysicalBackFaceVisible) return;
    final wasVisible = _reportedPhysicalBackFaceVisible;
    _reportedPhysicalBackFaceVisible = visibleNow;

    if (widget.dismissKeyboardOnInteraction && visibleNow && !wasVisible) {
      _tearDownKeyboardConnection();
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        SystemChannels.textInput.invokeMethod('TextInput.hide');
      });
    }

    final cb = widget.onPhysicalBackFaceVisibleChanged;
    if (cb != null) {
      final arg = visibleNow;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        cb(arg);
      });
    }
  }

  double get _restAngle =>
      widget.initialBackFaceVisible ? _halfTurnRadians : 0;

  @override
  void initState() {
    super.initState();
    _flipController = AnimationController.unbounded(
      vsync: this,
      value: _restAngle,
      duration: const Duration(milliseconds: 260),
    )..addListener(() {
        if (!mounted) return;
        _reportPhysicalBackFaceVisibleEdges();
        setState(() {});
      });
    _lastTapTargetAngle = _restAngle;
    _reportedPhysicalBackFaceVisible = widget.initialBackFaceVisible;
  }

  @override
  void didUpdateWidget(covariant TurnableYAxisCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.resetIdentity != oldWidget.resetIdentity ||
        widget.initialBackFaceVisible != oldWidget.initialBackFaceVisible) {
      _flipController.value = _restAngle;
      _lastTapTargetAngle = _restAngle;
      _reportedPhysicalBackFaceVisible = widget.initialBackFaceVisible;
      final cb = widget.onPhysicalBackFaceVisibleChanged;
      if (cb != null) {
        final arg = widget.initialBackFaceVisible;
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!mounted) return;
          cb(arg);
        });
      }
    }
  }

  @override
  void dispose() {
    _flipController.dispose();
    super.dispose();
  }

  void _springSnapTo(
    double targetAngle, {
    double initialAngularVelocity = 0,
  }) {
    final simulation = SpringSimulation(
      _flipSpring,
      _rotationAngle,
      targetAngle,
      initialAngularVelocity,
    );
    _flipController.animateWith(simulation);
  }

  void _onHorizontalDragStart(DragStartDetails details) {
    if (!widget.interactionEnabled) return;
    _flipController.stop();
    _lastTapTargetAngle =
        (_rotationAngle / _halfTurnRadians).roundToDouble() * _halfTurnRadians;
    _isDraggingHorizontally = true;
  }

  void _onHorizontalDragUpdate(DragUpdateDetails details) {
    if (!widget.interactionEnabled) return;
    final width = _cardWidth <= 0 ? 1 : _cardWidth;
    final dx = details.primaryDelta ?? 0;
    if (dx == 0) return;
    final deltaAngle = -((dx / width) * _swipeSensitivity) * _halfTurnRadians;
    _flipController.value = _rotationAngle + deltaAngle;
  }

  void _onHorizontalDragEnd(DragEndDetails details) {
    if (!widget.interactionEnabled) {
      _isDraggingHorizontally = false;
      return;
    }
    _isDraggingHorizontally = false;
    final width = _cardWidth <= 0 ? 1 : _cardWidth;
    final vx = details.velocity.pixelsPerSecond.dx;
    final flingAngleOffset = vx.abs() > 700 ? (-(vx / width) * 0.18) : 0.0;
    final projected = _rotationAngle + flingAngleOffset;
    final target =
        (projected / _halfTurnRadians).roundToDouble() * _halfTurnRadians;
    _lastTapTargetAngle = target;
    const flingScale = 0.52;
    final initialAngularVelocity =
        -((vx / width) * _swipeSensitivity) * _halfTurnRadians * flingScale;
    _springSnapTo(
      target,
      initialAngularVelocity: initialAngularVelocity,
    );
  }

  void _onHorizontalDragCancel() {
    _isDraggingHorizontally = false;
    if (!widget.interactionEnabled) return;
    final target =
        (_rotationAngle / _halfTurnRadians).roundToDouble() * _halfTurnRadians;
    _lastTapTargetAngle = target;
    _springSnapTo(target);
  }

  double _normalizedAngle(double angle) {
    final normalized = angle % _fullTurnRadians;
    return normalized < 0 ? normalized + _fullTurnRadians : normalized;
  }

  double _normalizedSignedAngle(double angle) {
    final normalized = _normalizedAngle(angle);
    if (normalized > math.pi) return normalized - _fullTurnRadians;
    return normalized;
  }

  void _flipByOneFace({required bool turnLeft}) {
    if (!widget.interactionEnabled) return;
    final baseAngle =
        _flipController.isAnimating ? _lastTapTargetAngle : _rotationAngle;
    final snappedBase =
        (baseAngle / _halfTurnRadians).roundToDouble() * _halfTurnRadians;
    final target = turnLeft
        ? (snappedBase + _halfTurnRadians)
        : (snappedBase - _halfTurnRadians);
    _lastTapTargetAngle = target;
    _springSnapTo(target);
  }

  List<BoxShadow> _cardShadow(double angle) {
    final depth = 0.35 + 0.35 * math.sin(angle).abs().clamp(0.0, 1.0);
    final dark = Theme.of(context).brightness == Brightness.dark;
    final base = dark ? 0.38 : 0.12;
    return [
      BoxShadow(
        color: Colors.black.withValues(alpha: base + 0.12 * depth),
        blurRadius: (dark ? 16 : 12) + 8 * depth,
        offset: Offset(0, 4 + 4 * depth),
      ),
    ];
  }

  @override
  Widget build(BuildContext context) {
    final r = widget.borderRadius;
    final cardContent = LayoutBuilder(
      builder: (context, constraints) {
        if (constraints.maxWidth.isFinite && constraints.maxWidth > 0) {
          _cardWidth = constraints.maxWidth;
        }
        final measurementWidth =
            constraints.maxWidth.isFinite && constraints.maxWidth > 0
                ? constraints.maxWidth
                : _cardWidth;
        final fixedH = widget.fixedFaceHeight;
        final angle = _normalizedSignedAngle(_rotationAngle);
        final normalizedAngle = _normalizedAngle(angle);
        final sideTilt = 0.01 * math.sin(angle);
        final isBackVisible = normalizedAngle > (math.pi / 2) &&
            normalizedAngle < (3 * math.pi / 2);

        Widget faceLayer() {
          final face = isBackVisible
              ? Transform(
                  alignment: Alignment.center,
                  transform: Matrix4.identity()..rotateY(math.pi),
                  transformHitTests: false,
                  child: widget.back,
                )
              : widget.front;
          return face;
        }

        return Transform(
          alignment: Alignment.center,
          transform: Matrix4.identity()
            ..setEntry(3, 2, 0.0017)
            ..rotateY(angle)
            ..rotateZ(sideTilt)
            // ignore: deprecated_member_use
            ..scale(_isDraggingHorizontally ? 0.992 : 1.0),
          transformHitTests: false,
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: Theme.of(context).colorScheme.surfaceContainerHigh,
              borderRadius: BorderRadius.circular(r),
              border: Theme.of(context).brightness == Brightness.dark
                  ? Border.all(color: Colors.white.withValues(alpha: 0.07))
                  : null,
              boxShadow: _cardShadow(angle),
            ),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(r),
              clipBehavior: Clip.antiAlias,
              child: fixedH != null && fixedH > 0 && measurementWidth > 0
                  ? SizedBox(
                      width: measurementWidth,
                      height: fixedH,
                      child: faceLayer(),
                    )
                  : !widget.prelayoutFacesForHeight
                      // Intrinsic height from the visible face (ListView-safe).
                      ? faceLayer()
                      : Stack(
                          alignment: Alignment.topCenter,
                          children: [
                            ExcludeSemantics(
                              child: IgnorePointer(
                                child: Opacity(
                                  opacity: 0,
                                  child: widget.front,
                                ),
                              ),
                            ),
                            ExcludeSemantics(
                              child: IgnorePointer(
                                child: Opacity(
                                  opacity: 0,
                                  child: widget.back,
                                ),
                              ),
                            ),
                            Positioned.fill(child: faceLayer()),
                          ],
                        ),
            ),
          ),
        );
      },
    );

    final wrappedCard = widget.interactionEnabled
        ? GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTapUp: (details) {
              final tapX = details.localPosition.dx;
              final isLeftHalf = tapX <= (_cardWidth / 2);
              _flipByOneFace(turnLeft: isLeftHalf);
            },
            onHorizontalDragStart: _onHorizontalDragStart,
            onHorizontalDragUpdate: _onHorizontalDragUpdate,
            onHorizontalDragEnd: _onHorizontalDragEnd,
            onHorizontalDragCancel: _onHorizontalDragCancel,
            child: cardContent,
          )
        : cardContent;

    return Padding(
      padding: widget.outerPadding,
      child: wrappedCard,
    );
  }
}
