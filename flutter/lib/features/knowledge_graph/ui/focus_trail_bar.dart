import 'package:flutter/material.dart';

import '../graph_controller.dart';

class FocusTrailBar extends StatefulWidget {
  const FocusTrailBar({
    required this.entries,
    required this.currentId,
    required this.onSelect,
  });

  final List<FocusTrailEntry> entries;
  final String? currentId;
  final ValueChanged<FocusTrailEntry> onSelect;

  @override
  State<FocusTrailBar> createState() => _FocusTrailBarState();
}

class _FocusTrailBarState extends State<FocusTrailBar> {
  /// Ids that have finished their entrance (or were present at cold start).
  final Set<String> _settled = {};

  /// Match focus morph so the chip eases in alongside the graph.
  static const _enter = Duration(milliseconds: 480);

  /// Stable tween — a new [Tween] each build restarts [TweenAnimationBuilder].
  static final _revealTween = Tween<double>(begin: 0, end: 1);

  @override
  void initState() {
    super.initState();
    _settled.addAll(widget.entries.map((e) => e.id));
  }

  @override
  void didUpdateWidget(covariant FocusTrailBar oldWidget) {
    super.didUpdateWidget(oldWidget);
    final nextIds = widget.entries.map((e) => e.id).toSet();
    _settled.removeWhere((id) => !nextIds.contains(id));
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    // reverse keeps newest pinned on the right. Entrance widthFactor grows the
    // new chip from the right so the row shifts left in the same motion.
    return RepaintBoundary(
      child: LayoutBuilder(
        builder: (context, constraints) {
          return SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            reverse: true,
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: ConstrainedBox(
              constraints: BoxConstraints(minWidth: constraints.maxWidth - 24),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.end,
                mainAxisSize: MainAxisSize.min,
                children: [
                  for (var i = 0; i < widget.entries.length; i++)
                    _FocusTrailChipReveal(
                      key: ValueKey('trail-$i-${widget.entries[i].id}'),
                      animate: !_settled.contains(widget.entries[i].id),
                      duration: _enter,
                      padLeft: i > 0 ? 6 : 0,
                      onFinished: () {
                        if (!mounted) return;
                        setState(() => _settled.add(widget.entries[i].id));
                      },
                      child: _FocusTrailChip(
                        entry: widget.entries[i],
                        current: widget.entries[i].id == widget.currentId,
                        onTap: () => widget.onSelect(widget.entries[i]),
                        scheme: scheme,
                      ),
                    ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }
}

class _FocusTrailChipReveal extends StatelessWidget {
  const _FocusTrailChipReveal({
    super.key,
    required this.animate,
    required this.duration,
    required this.padLeft,
    required this.onFinished,
    required this.child,
  });

  final bool animate;
  final Duration duration;
  final double padLeft;
  final VoidCallback onFinished;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final padded = padLeft > 0
        ? Padding(padding: EdgeInsets.only(left: padLeft), child: child)
        : child;
    if (!animate) return padded;
    return TweenAnimationBuilder<double>(
      tween: _FocusTrailBarState._revealTween,
      duration: duration,
      curve: Curves.easeOutCubic,
      onEnd: onFinished,
      builder: (context, t, child) {
        return ClipRect(
          child: Align(
            alignment: Alignment.centerRight,
            widthFactor: t.clamp(0.001, 1.0),
            child: Opacity(opacity: t, child: child),
          ),
        );
      },
      child: padded,
    );
  }
}

class _FocusTrailChip extends StatelessWidget {
  const _FocusTrailChip({
    required this.entry,
    required this.current,
    required this.onTap,
    required this.scheme,
  });

  final FocusTrailEntry entry;
  final bool current;
  final VoidCallback onTap;
  final ColorScheme scheme;

  @override
  Widget build(BuildContext context) {
    final bg = current
        ? scheme.primary.withValues(alpha: 0.16)
        : scheme.surfaceContainerHighest.withValues(alpha: 0.92);
    final border = current
        ? scheme.primary.withValues(alpha: 0.55)
        : scheme.onSurface.withValues(alpha: 0.08);
    final fg = current ? scheme.primary : scheme.onSurface.withValues(alpha: 0.78);
    return Material(
      color: Colors.transparent,
      child: InkWell(
        customBorder: const StadiumBorder(),
        onTap: onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 280),
          curve: Curves.easeOutCubic,
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
          decoration: ShapeDecoration(
            color: bg,
            shape: StadiumBorder(side: BorderSide(color: border)),
            shadows: current
                ? null
                : const [
                    BoxShadow(color: Color(0x42000000), blurRadius: 2, offset: Offset(0, 0.5)),
                  ],
          ),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 148),
            child: AnimatedDefaultTextStyle(
              duration: const Duration(milliseconds: 280),
              curve: Curves.easeOutCubic,
              style: TextStyle(
                fontFamily: 'tt_ramilas',
                fontSize: 13,
                fontWeight: current ? FontWeight.w700 : FontWeight.w600,
                height: 1.1,
                color: fg,
              ),
              child: Text(
                entry.title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ),
        ),
      ),
    );
  }
}
