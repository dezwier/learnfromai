import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'topic_affinity_models.dart';

const affinityMapHeight = 320.0;

/// Graph-inspired cluster hues (parent / sibling / child / related / slate).
const _clusterPalette = <Color>[
  Color(0xFF8AAFCF),
  Color(0xFFD98E96),
  Color(0xFF97BF88),
  Color(0xFFDCAD6A),
  Color(0xFFADB3BE),
];

class _PlacedBubble {
  const _PlacedBubble({
    required this.node,
    required this.center,
    required this.radius,
    required this.color,
    required this.showLabel,
  });

  final TopicAffinityNode node;
  final Offset center;
  final double radius;
  final Color color;
  final bool showLabel;
}

/// Packed cluster islands of affinity bubbles.
class TopicAffinityMap extends StatefulWidget {
  const TopicAffinityMap({
    super.key,
    required this.payload,
    required this.onOpenTopic,
  });

  final TopicAffinityPayload payload;
  final ValueChanged<String> onOpenTopic;

  @override
  State<TopicAffinityMap> createState() => _TopicAffinityMapState();
}

class _TopicAffinityMapState extends State<TopicAffinityMap>
    with SingleTickerProviderStateMixin {
  late final AnimationController _entrance = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 720),
  )..forward();

  List<_PlacedBubble> _bubbles = const [];
  Size _layoutSize = Size.zero;

  @override
  void dispose() {
    _entrance.dispose();
    super.dispose();
  }

  @override
  void didUpdateWidget(covariant TopicAffinityMap oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.payload != widget.payload) {
      _layoutSize = Size.zero;
      _bubbles = const [];
      _entrance
        ..value = 0
        ..forward();
    }
  }

  void _ensureLayout(Size size) {
    if (size == _layoutSize && _bubbles.isNotEmpty) return;
    _layoutSize = size;
    _bubbles = _layoutBubbles(widget.payload, size);
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: affinityMapHeight,
      width: double.infinity,
      child: LayoutBuilder(
        builder: (context, constraints) {
          final size = Size(constraints.maxWidth, affinityMapHeight);
          _ensureLayout(size);
          return AnimatedBuilder(
            animation: _entrance,
            builder: (context, _) {
              return GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTapUp: (details) {
                  final id = _hitTest(details.localPosition);
                  if (id != null) widget.onOpenTopic(id);
                },
                child: CustomPaint(
                  size: size,
                  painter: _AffinityMapPainter(
                    bubbles: _bubbles,
                    edges: widget.payload.edges,
                    progress: Curves.easeOutCubic.transform(_entrance.value),
                  ),
                ),
              );
            },
          );
        },
      ),
    );
  }

  String? _hitTest(Offset point) {
    for (final bubble in _bubbles.reversed) {
      if ((point - bubble.center).distance <= bubble.radius) {
        return bubble.node.id;
      }
    }
    return null;
  }
}

List<_PlacedBubble> _layoutBubbles(TopicAffinityPayload payload, Size size) {
  if (payload.nodes.isEmpty || size.width <= 0) return const [];

  final byId = {for (final node in payload.nodes) node.id: node};
  final maxAffinity = payload.nodes.map((n) => n.affinity).fold<int>(1, math.max);
  final clusters = [...payload.clusters]..sort((a, b) => b.totalAffinity.compareTo(a.totalAffinity));

  final islandCount = math.max(1, clusters.length);
  final cols = math.min(islandCount, size.width >= 360 ? 3 : 2);
  final rows = (islandCount / cols).ceil();
  final cellW = size.width / cols;
  final cellH = size.height / rows;
  final labelBudget = <String>{};
  final rankedForLabel = [...payload.nodes]..sort((a, b) => b.affinity.compareTo(a.affinity));
  for (final node in rankedForLabel.take(10)) {
    labelBudget.add(node.id);
  }

  final placed = <_PlacedBubble>[];
  for (var i = 0; i < clusters.length; i++) {
    final cluster = clusters[i];
    final col = i % cols;
    final row = i ~/ cols;
    final islandCenter = Offset(cellW * (col + 0.5), cellH * (row + 0.5));
    final color = _clusterPalette[i % _clusterPalette.length];
    final members = [
      for (final id in cluster.nodeIds)
        if (byId[id] != null) byId[id]!,
    ]..sort((a, b) => b.affinity.compareTo(a.affinity));
    if (members.isEmpty) continue;

    final seed = members.first;
    final seedR = _radiusFor(seed.affinity, maxAffinity, members.length == 1);
    placed.add(
      _PlacedBubble(
        node: seed,
        center: islandCenter,
        radius: seedR,
        color: color,
        showLabel: labelBudget.contains(seed.id),
      ),
    );

    final others = members.skip(1).toList();
    var ring = 0;
    var indexInRing = 0;
    var slots = 6;
    for (final node in others) {
      if (indexInRing >= slots) {
        ring += 1;
        indexInRing = 0;
        slots = 6 + ring * 4;
      }
      final r = _radiusFor(node.affinity, maxAffinity, false);
      final ringRadius = seedR + 10 + ring * 28.0 + r;
      final angle = -math.pi / 2 + (indexInRing / slots) * math.pi * 2;
      var center = islandCenter + Offset(math.cos(angle) * ringRadius, math.sin(angle) * ringRadius);
      center = Offset(
        center.dx.clamp(r + 4, size.width - r - 4),
        center.dy.clamp(r + 4, size.height - r - 4),
      );
      placed.add(
        _PlacedBubble(
          node: node,
          center: center,
          radius: r,
          color: color,
          showLabel: labelBudget.contains(node.id),
        ),
      );
      indexInRing += 1;
    }
  }
  return placed;
}

double _radiusFor(int affinity, int maxAffinity, bool alone) {
  final t = math.sqrt(affinity / maxAffinity).clamp(0.0, 1.0);
  final minR = alone ? 28.0 : 16.0;
  final maxR = alone ? 52.0 : 48.0;
  return minR + (maxR - minR) * t;
}

class _AffinityMapPainter extends CustomPainter {
  _AffinityMapPainter({
    required this.bubbles,
    required this.edges,
    required this.progress,
  });

  final List<_PlacedBubble> bubbles;
  final List<TopicAffinityEdge> edges;
  final double progress;

  @override
  void paint(Canvas canvas, Size size) {
    final byId = {for (final b in bubbles) b.node.id: b};

    // Soft island washes behind each cluster group.
    final byCluster = <int, List<_PlacedBubble>>{};
    for (final bubble in bubbles) {
      byCluster.putIfAbsent(bubble.node.clusterId, () => []).add(bubble);
    }
    for (final group in byCluster.values) {
      if (group.isEmpty) continue;
      var minX = group.first.center.dx;
      var maxX = minX;
      var minY = group.first.center.dy;
      var maxY = minY;
      for (final b in group) {
        minX = math.min(minX, b.center.dx - b.radius);
        maxX = math.max(maxX, b.center.dx + b.radius);
        minY = math.min(minY, b.center.dy - b.radius);
        maxY = math.max(maxY, b.center.dy + b.radius);
      }
      final pad = 14.0;
      final rect = RRect.fromRectAndRadius(
        Rect.fromLTRB(minX - pad, minY - pad, maxX + pad, maxY + pad),
        const Radius.circular(28),
      );
      final wash = Paint()
        ..color = group.first.color.withValues(alpha: 0.14 * progress)
        ..style = PaintingStyle.fill;
      canvas.drawRRect(rect, wash);
    }

    final edgePaint = Paint()
      ..color = const Color(0xFF7A8088).withValues(alpha: 0.22 * progress)
      ..strokeWidth = 1.2
      ..style = PaintingStyle.stroke;
    for (final edge in edges) {
      final a = byId[edge.source];
      final b = byId[edge.target];
      if (a == null || b == null) continue;
      if (a.node.clusterId != b.node.clusterId) continue;
      canvas.drawLine(a.center, b.center, edgePaint);
    }

    for (var i = 0; i < bubbles.length; i++) {
      final bubble = bubbles[i];
      final stagger = (i / math.max(1, bubbles.length)).clamp(0.0, 1.0);
      final local = ((progress - stagger * 0.35) / 0.65).clamp(0.0, 1.0);
      final scale = 0.72 + 0.28 * Curves.easeOutBack.transform(local);
      final opacity = local;
      canvas.save();
      canvas.translate(bubble.center.dx, bubble.center.dy);
      canvas.scale(scale);
      canvas.translate(-bubble.center.dx, -bubble.center.dy);

      final fill = Paint()
        ..color = bubble.color.withValues(alpha: 0.88 * opacity)
        ..style = PaintingStyle.fill;
      final rim = Paint()
        ..color = Colors.white.withValues(alpha: 0.55 * opacity)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.5;
      canvas.drawCircle(bubble.center, bubble.radius, fill);
      canvas.drawCircle(bubble.center, bubble.radius, rim);

      if (bubble.showLabel && bubble.radius >= 22) {
        final tp = TextPainter(
          text: TextSpan(
            text: _shortTitle(bubble.node.name),
            style: TextStyle(
              fontFamily: 'tt_ramilas',
              fontWeight: FontWeight.w700,
              fontSize: bubble.radius >= 36 ? 13 : 11,
              height: 1.1,
              color: const Color(0xFF1C1F24).withValues(alpha: 0.92 * opacity),
            ),
          ),
          textAlign: TextAlign.center,
          textDirection: TextDirection.ltr,
          maxLines: 2,
          ellipsis: '…',
        )..layout(maxWidth: bubble.radius * 1.7);
        tp.paint(
          canvas,
          bubble.center - Offset(tp.width / 2, tp.height / 2),
        );
      }
      canvas.restore();
    }
  }

  @override
  bool shouldRepaint(covariant _AffinityMapPainter oldDelegate) {
    return oldDelegate.progress != progress ||
        oldDelegate.bubbles != bubbles ||
        oldDelegate.edges != edges;
  }
}

String _shortTitle(String name) {
  final trimmed = name.trim();
  if (trimmed.length <= 18) return trimmed;
  return '${trimmed.substring(0, 16)}…';
}
