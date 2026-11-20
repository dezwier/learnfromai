import 'dart:async';

import 'package:flutter/material.dart';

const learnEdgeSwipeWidth = 28.0;
const learnEdgeSwipeDismissDistance = 72.0;
const learnEdgeSwipeFlingVelocity = 700.0;

/// iOS-style dismiss: drag from a left-edge hit strip slides content right, then pops.
class LearnEdgeSwipeToDismiss extends StatefulWidget {
  const LearnEdgeSwipeToDismiss({
    super.key,
    required this.child,
    required this.onDismiss,
  });

  final Widget child;
  final VoidCallback onDismiss;

  @override
  State<LearnEdgeSwipeToDismiss> createState() => _LearnEdgeSwipeToDismissState();
}

class _LearnEdgeSwipeToDismissState extends State<LearnEdgeSwipeToDismiss>
    with SingleTickerProviderStateMixin {
  late final AnimationController _slide;
  var _dragging = false;
  var _dismissing = false;

  @override
  void initState() {
    super.initState();
    _slide = AnimationController.unbounded(vsync: this, value: 0);
  }

  @override
  void dispose() {
    _slide.dispose();
    super.dispose();
  }

  double get _screenWidth {
    final width = MediaQuery.sizeOf(context).width;
    return width > 0 ? width : 400;
  }

  void _onStart(DragStartDetails details) {
    if (_dismissing) return;
    _slide.stop();
    _dragging = true;
  }

  void _onUpdate(DragUpdateDetails details) {
    if (!_dragging || _dismissing) return;
    final next = (_slide.value + (details.primaryDelta ?? 0)).clamp(0.0, _screenWidth);
    _slide.value = next;
  }

  void _onEnd(DragEndDetails details) {
    if (!_dragging || _dismissing) return;
    _dragging = false;
    final fling = details.velocity.pixelsPerSecond.dx;
    final shouldDismiss =
        _slide.value >= learnEdgeSwipeDismissDistance || fling > learnEdgeSwipeFlingVelocity;
    if (shouldDismiss) {
      unawaited(_animateOffThenDismiss(fling));
      return;
    }
    unawaited(_animateBack());
  }

  void _onCancel() {
    if (_dismissing) return;
    _dragging = false;
    unawaited(_animateBack());
  }

  Future<void> _animateBack() async {
    await _slide.animateTo(
      0,
      duration: const Duration(milliseconds: 220),
      curve: Curves.easeOutCubic,
    );
  }

  Future<void> _animateOffThenDismiss(double flingVx) async {
    if (_dismissing) return;
    _dismissing = true;
    final target = _screenWidth + 24;
    final distance = (target - _slide.value).clamp(1.0, target);
    final ms = flingVx > 200
        ? (distance / flingVx * 1000).clamp(140.0, 280.0).round()
        : 240;
    await _slide.animateTo(
      target,
      duration: Duration(milliseconds: ms),
      curve: Curves.easeOutCubic,
    );
    if (!mounted) return;
    widget.onDismiss();
  }

  @override
  Widget build(BuildContext context) {
    return Stack(
      fit: StackFit.expand,
      children: [
        AnimatedBuilder(
          animation: _slide,
          builder: (context, child) {
            return Transform.translate(
              offset: Offset(_slide.value, 0),
              child: child,
            );
          },
          child: widget.child,
        ),
        Positioned(
          left: 0,
          top: 0,
          bottom: 0,
          width: learnEdgeSwipeWidth,
          child: GestureDetector(
            behavior: HitTestBehavior.translucent,
            onHorizontalDragStart: _onStart,
            onHorizontalDragUpdate: _onUpdate,
            onHorizontalDragEnd: _onEnd,
            onHorizontalDragCancel: _onCancel,
          ),
        ),
      ],
    );
  }
}
