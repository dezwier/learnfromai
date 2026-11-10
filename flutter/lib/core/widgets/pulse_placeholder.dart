import 'package:flutter/material.dart';

/// Full-size pulsing stand-in. Size comes from the parent.
class PulsePlaceholder extends StatefulWidget {
  const PulsePlaceholder({super.key, this.borderRadius});

  const PulsePlaceholder.image({super.key, this.borderRadius});

  const PulsePlaceholder.map({super.key, this.borderRadius});

  final BorderRadius? borderRadius;

  @override
  State<PulsePlaceholder> createState() => _PulsePlaceholderState();
}

class _PulsePlaceholderState extends State<PulsePlaceholder> with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(vsync: this, duration: const Duration(milliseconds: 1100))
    ..repeat(reverse: true);

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final base = Theme.of(context).colorScheme.surfaceContainerHighest;
    final highlight = Theme.of(context).colorScheme.surfaceContainerHigh;
    return AnimatedBuilder(
      animation: _controller,
      builder: (context, _) {
        return DecoratedBox(
          decoration: BoxDecoration(
            color: Color.lerp(base, highlight, _controller.value),
            borderRadius: widget.borderRadius ?? BorderRadius.circular(12),
          ),
        );
      },
    );
  }
}
