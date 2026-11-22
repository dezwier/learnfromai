import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../layout/geometry.dart';
import '../layout/graph_layout.dart';
import '../layout/title_wrap.dart';

class GraphView extends StatefulWidget {
  const GraphView({
    required this.layout,
    required this.focusId,
    required this.highlightId,
    required this.pendingId,
    required this.transform,
    required this.viewport,
    required this.onSelect,
    required this.onHighlight,
    required this.imageBytesFor,
    this.onLongPress,
    this.morphing = false,
  });

  final GraphLayout layout;
  final String? focusId;
  final String? highlightId;
  final String? pendingId;
  final bool morphing;
  final TransformationController transform;
  final Size viewport;
  final ValueChanged<PlacedNode> onSelect;
  final ValueChanged<PlacedNode?> onHighlight;
  final ValueChanged<PlacedNode>? onLongPress;
  final Uint8List? Function(String? imageUrl) imageBytesFor;

  @override
  State<GraphView> createState() => _GraphViewState();
}

class _GraphViewState extends State<GraphView> {
  String? _centerId;

  @override
  void initState() {
    super.initState();
    widget.transform.addListener(_onTransform);
    WidgetsBinding.instance.addPostFrameCallback((_) => _onTransform());
  }

  @override
  void didUpdateWidget(covariant GraphView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.transform != widget.transform) {
      oldWidget.transform.removeListener(_onTransform);
      widget.transform.addListener(_onTransform);
    }
    if (oldWidget.layout != widget.layout ||
        oldWidget.viewport != widget.viewport ||
        oldWidget.focusId != widget.focusId) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _onTransform());
    }
  }

  @override
  void dispose() {
    widget.transform.removeListener(_onTransform);
    super.dispose();
  }

  void _onTransform() {
    if (!mounted || widget.morphing) return;
    final next = _tileAtViewportCenter(
      layout: widget.layout,
      transform: widget.transform.value,
      viewport: widget.viewport,
      currentId: _centerId,
    );
    if (next == _centerId) return;
    setState(() => _centerId = next);
    PlacedNode? node;
    if (next != null) {
      for (final n in widget.layout.nodes) {
        if (n.id == next) {
          node = n;
          break;
        }
      }
    }
    widget.onHighlight(node);
  }

  @override
  Widget build(BuildContext context) {
    const shadowPad = 14.0;
    final ordered = [...widget.layout.nodes];
    if (widget.morphing) {
      // Stable z-order — re-sorting by size every frame reshuffles Elements.
      ordered.sort((a, b) {
        final af = a.id == widget.focusId ? 0 : 1;
        final bf = b.id == widget.focusId ? 0 : 1;
        if (af != bf) return af.compareTo(bf);
        return a.id.compareTo(b.id);
      });
    } else {
      // Largest (focus flower) under smaller hexes so outer tiles stay tappable.
      ordered.sort((a, b) => (b.width * b.height).compareTo(a.width * a.height));
    }
    return ColoredBox(
      color: Theme.of(context).scaffoldBackgroundColor,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          for (final node in ordered)
            Positioned(
              // Keep tile/image State across sort-order shuffles during morph.
              key: ValueKey(node.id),
              left: node.x - shadowPad,
              top: node.y - shadowPad,
              width: node.width + shadowPad * 2,
              height: node.height + shadowPad * 2,
              child: Padding(
                padding: const EdgeInsets.all(shadowPad),
                // Morph drives opacity per-frame; after settle, ease role fades (e.g. extended).
                child: AnimatedOpacity(
                  opacity: node.opacity.clamp(0.0, 1.0),
                  duration: Duration(milliseconds: widget.morphing ? 0 : 380),
                  curve: Curves.easeOutCubic,
                  child: IgnorePointer(
                    ignoring: node.opacity < 0.35,
                    child: _NodeCard(
                      node: node,
                      focused: node.id == widget.focusId,
                      pending: node.id == widget.pendingId,
                      morphing: widget.morphing,
                      centerHighlight:
                          !widget.morphing && node.id == (widget.highlightId ?? _centerId),
                      onTap: () => widget.onSelect(node),
                      onLongPress: widget.onLongPress == null
                          ? null
                          : () => widget.onLongPress!(node),
                      imageBytes: widget.imageBytesFor(
                        (node.imageThumbUrl?.trim().isNotEmpty == true)
                            ? node.imageThumbUrl
                            : node.imageUrl,
                      ),
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// Pick the tile covering the viewport center, with sticky hysteresis to avoid flicker.
String? _tileAtViewportCenter({
  required GraphLayout layout,
  required Matrix4 transform,
  required Size viewport,
  required String? currentId,
}) {
  if (layout.nodes.isEmpty || viewport.isEmpty) return null;
  Matrix4 inverse;
  try {
    inverse = Matrix4.inverted(transform);
  } catch (_) {
    return currentId;
  }
  final center = MatrixUtils.transformPoint(
    inverse,
    Offset(viewport.width / 2, viewport.height / 2),
  );

  for (final node in layout.nodes) {
    if (node.contains(center)) return node.id;
  }

  PlacedNode? best;
  var bestDist = double.infinity;
  for (final node in layout.nodes) {
    final dist = (node.center - center).distance;
    if (dist < bestDist) {
      bestDist = dist;
      best = node;
    }
  }
  if (best == null) return currentId;

  if (currentId != null) {
    for (final node in layout.nodes) {
      if (node.id != currentId) continue;
      final stick = (node.isFlower ? node.radius * 1.1 : node.radius * 0.55);
      final currentDist = (node.center - center).distance;
      if (bestDist > currentDist - stick) return currentId;
      break;
    }
  }
  return best.id;
}

Color _intensifyFill(Color base, double amount, {required bool dark}) {
  if (amount <= 0) return base;
  final hsl = HSLColor.fromColor(base);
  final boosted = dark
      ? hsl
          .withLightness((hsl.lightness + 0.14 * amount).clamp(0.0, 1.0))
          .withSaturation((hsl.saturation + 0.08 * amount).clamp(0.0, 1.0))
      : hsl
          .withLightness((hsl.lightness - 0.10 * amount).clamp(0.0, 1.0))
          .withSaturation((hsl.saturation + 0.18 * amount).clamp(0.0, 1.0));
  return Color.lerp(base, boosted.toColor(), amount)!;
}

class _NodeCard extends StatelessWidget {
  const _NodeCard({
    required this.node,
    required this.focused,
    required this.pending,
    required this.centerHighlight,
    required this.onTap,
    required this.morphing,
    this.onLongPress,
    this.imageBytes,
  });

  final PlacedNode node;
  final bool focused;
  final bool pending;
  final bool centerHighlight;
  final bool morphing;
  final VoidCallback onTap;
  final VoidCallback? onLongPress;
  final Uint8List? imageBytes;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final dark = scheme.brightness == Brightness.dark;
    final base = pending
        ? (dark ? const Color(0xFF3A4554) : const Color(0xFFDDE7F4))
        : nodeFill(node, scheme);
    final flower = node.effectiveFlowerAmount;
    final imageKey = (node.imageThumbUrl?.trim().isNotEmpty == true)
        ? node.imageThumbUrl!
        : (node.imageUrl ?? node.id);
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0, end: centerHighlight ? 1.0 : 0.0),
      duration: const Duration(milliseconds: 220),
      curve: Curves.easeOutCubic,
      builder: (context, spotlight, _) {
        // Focus flower: shadow only — color/scale look wrong on the big tile.
        final fill = flower >= 0.85
            ? base
            : _intensifyFill(base, spotlight * (1 - flower), dark: dark);
        final scale = flower >= 0.85 ? 1.0 : 1.0 + 0.045 * spotlight * (1 - flower);
        final hex = _tileCard(
          scheme: scheme,
          fill: fill,
          dark: dark,
          spotlight: spotlight,
          imageBytes: imageBytes,
          imageKey: imageKey,
        );
        final bloom = _flowerCard(
          scheme: scheme,
          fill: base,
          dark: dark,
          spotlight: spotlight,
          imageBytes: imageBytes,
          imageKey: imageKey,
          contentOpacity: Curves.easeOut.transform(flower.clamp(0.0, 1.0)),
        );
        // Crossfade the whole range so flowerAmount never pops widgets in/out.
        final child = flower <= 0
            ? hex
            : flower >= 1
                ? bloom
                : Stack(
                    fit: StackFit.expand,
                    children: [
                      Opacity(opacity: 1 - flower, child: hex),
                      Opacity(opacity: flower, child: bloom),
                    ],
                  );
        // Clip to hex/flower silhouette so the focus AABB cannot steal taps
        // meant for neighbors-of-neighbors sitting in its bounding box.
        return ClipPath(
          clipper: flower >= 0.5 ? const _FlowerTapClipper() : const _HexTapClipper(),
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: onTap,
            onLongPress: onLongPress,
            child: Transform.scale(
              scale: scale,
              child: child,
            ),
          ),
        );
      },
    );
  }

  Widget _flowerCard({
    required ColorScheme scheme,
    required Color fill,
    required bool dark,
    required double spotlight,
    Uint8List? imageBytes,
    required String imageKey,
    double contentOpacity = 1,
  }) {
    final description = (node.description ?? '').trim();
    final hasImage = imageBytes != null;
    final titleColor = hasImage ? Colors.white : scheme.onSurface;
    final descColor = hasImage
        ? Colors.white.withValues(alpha: 0.88)
        : scheme.onSurface.withValues(alpha: 0.72);
    return CustomPaint(
      painter: _HexFlowerPainter(color: fill, dark: dark, spotlight: spotlight),
      child: Opacity(
        opacity: contentOpacity.clamp(0.0, 1.0),
        child: Stack(
          fit: StackFit.expand,
          children: [
            if (imageBytes != null)
              _FadingHexImage(
                key: ValueKey('img-flower-${node.id}'),
                cacheKey: imageKey,
                bytes: imageBytes,
                flower: true,
              ),
            if (hasImage)
              ClipPath(
                clipper: const _FlowerTapClipper(),
                child: const DecoratedBox(
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      colors: [
                        Color(0x00000000),
                        Color(0x14000000),
                        Color(0x8A000000),
                      ],
                      stops: [0.35, 0.58, 1.0],
                    ),
                  ),
                ),
              ),
            Padding(
              padding: EdgeInsets.symmetric(
                horizontal: node.radius * 0.62,
                vertical: node.radius * 0.58,
              ),
              child: LayoutBuilder(
                builder: (context, constraints) {
                  final scaler = MediaQuery.textScalerOf(context);
                  final maxW = constraints.maxWidth;
                  final maxH = constraints.maxHeight;
                  if (maxW <= 1 || maxH <= 1) return const SizedBox.shrink();

                  final hasDesc = description.isNotEmpty;
                const titleMaxLines = 3;
                final titleStyleBase = TextStyle(
                  fontFamily: 'tt_ramilas',
                  height: 1.1,
                  fontWeight: FontWeight.w700,
                  color: titleColor,
                  shadows: hasImage ? _imageTitleShadows : null,
                );
                final titleBudget = hasDesc ? maxH * 0.42 : maxH * 0.92;
                final locked = node.titleFontSize;
                final titleLaid = layoutTitle(
                  text: node.title,
                  style: titleStyleBase,
                  maxWidth: maxW,
                  maxHeight: titleBudget,
                  maxLines: titleMaxLines,
                  minFontSize: locked ?? 13,
                  maxFontSize: locked ?? (node.radius * 0.5).clamp(17.0, 34.0),
                  textScaler: scaler,
                  hyphenateAtMinSize: true,
                );
                final titleStyle = titleStyleBase.copyWith(fontSize: titleLaid.fontSize);
                final gap = (node.radius * 0.08).clamp(4.0, 10.0);
                final descStyle = TextStyle(
                  fontFamily: 'tt_ramilas',
                  height: 1.25,
                  fontWeight: FontWeight.w500,
                  color: descColor,
                  fontSize: (node.radius * 0.22).clamp(13.0, 18.0),
                  shadows: hasImage ? _imageBodyShadows : null,
                );

                  return Center(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          titleLaid.text,
                          textAlign: TextAlign.center,
                          // layoutTitle already inserted `\n` / `-`; don't re-break letters.
                          softWrap: false,
                          maxLines: titleMaxLines,
                          overflow: TextOverflow.ellipsis,
                          style: titleStyle,
                        ),
                        if (hasDesc) ...[
                          SizedBox(height: gap),
                          Text(
                            description,
                            textAlign: TextAlign.center,
                            softWrap: true,
                            maxLines: 5,
                            overflow: TextOverflow.ellipsis,
                            style: descStyle,
                          ),
                        ],
                      ],
                    ),
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _tileCard({
    required ColorScheme scheme,
    required Color fill,
    required bool dark,
    required double spotlight,
    Uint8List? imageBytes,
    required String imageKey,
  }) {
    final hasImage = imageBytes != null;
    return CustomPaint(
      painter: _HexTilePainter(color: fill, dark: dark, spotlight: spotlight),
      child: Stack(
        fit: StackFit.expand,
        children: [
          if (imageBytes != null)
            _FadingHexImage(
              key: ValueKey('img-hex-${node.id}'),
              cacheKey: imageKey,
              bytes: imageBytes,
              flower: false,
            ),
          Padding(
            padding: EdgeInsets.symmetric(
              horizontal: node.radius * 0.34,
              vertical: node.radius * 0.24,
            ),
            child: Center(
              child: _FittingLabel(
                text: node.title,
                maxLines: 4,
                minFontSize: node.titleFontSize ?? 10,
                maxFontSize: node.titleFontSize ?? (node.radius * 0.32).clamp(11.0, 17.0),
                hyphenateWords: true,
                style: TextStyle(
                  fontFamily: 'tt_ramilas',
                  height: 1.15,
                  fontWeight: FontWeight.w600,
                  color: hasImage ? Colors.white : scheme.onSurface.withValues(alpha: 0.9),
                  shadows: hasImage ? _imageTitleShadows : null,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Thumb fill: fade in once per image URL; remounts / morphs stay opaque.
class _FadingHexImage extends StatefulWidget {
  const _FadingHexImage({
    super.key,
    required this.cacheKey,
    required this.bytes,
    required this.flower,
  });

  final String cacheKey;
  final Uint8List bytes;
  final bool flower;

  static const opacity = 0.4;
  static final _revealed = <String>{};

  @override
  State<_FadingHexImage> createState() => _FadingHexImageState();
}

class _FadingHexImageState extends State<_FadingHexImage> {
  late double _opacity;
  late String _key;
  late bool _animateIn;
  Uint8List? _shown;

  bool get _warm => _FadingHexImage._revealed.contains(_key);

  @override
  void initState() {
    super.initState();
    _key = widget.cacheKey;
    _shown = widget.bytes;
    _animateIn = !_warm;
    _opacity = _warm ? _FadingHexImage.opacity : 0;
    if (_animateIn) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _reveal());
    }
  }

  @override
  void didUpdateWidget(covariant _FadingHexImage oldWidget) {
    super.didUpdateWidget(oldWidget);
    final keyChanged = widget.cacheKey != _key;
    final bytesChanged = !identical(_shown, widget.bytes);
    if (!keyChanged && !bytesChanged) return;
    _key = widget.cacheKey;
    _shown = widget.bytes;
    if (_warm) {
      _animateIn = false;
      _opacity = _FadingHexImage.opacity;
      return;
    }
    _animateIn = true;
    _opacity = 0;
    WidgetsBinding.instance.addPostFrameCallback((_) => _reveal());
  }

  void _reveal() {
    if (!mounted || _shown != widget.bytes || widget.cacheKey != _key) return;
    if (_opacity >= _FadingHexImage.opacity) {
      _FadingHexImage._revealed.add(_key);
      return;
    }
    setState(() => _opacity = _FadingHexImage.opacity);
    _FadingHexImage._revealed.add(_key);
  }

  @override
  Widget build(BuildContext context) {
    return ClipPath(
      clipper: widget.flower ? const _FlowerTapClipper() : const _HexTapClipper(),
      child: AnimatedOpacity(
        opacity: _opacity,
        duration: Duration(milliseconds: _animateIn ? 560 : 0),
        curve: Curves.easeInOutCubic,
        child: Image.memory(
          widget.bytes,
          fit: BoxFit.cover,
          gaplessPlayback: true,
          filterQuality: FilterQuality.medium,
        ),
      ),
    );
  }
}

const _imageTitleShadows = <Shadow>[
  Shadow(color: Color(0xB3000000), blurRadius: 7, offset: Offset(0, 1)),
  Shadow(color: Color(0x80000000), blurRadius: 2, offset: Offset(0, 0.5)),
];

const _imageBodyShadows = <Shadow>[
  Shadow(color: Color(0x99000000), blurRadius: 5, offset: Offset(0, 1)),
];

/// Scales font to the tile. Titles keep whole words until min size, then hyphenate.
class _FittingLabel extends StatelessWidget {
  const _FittingLabel({
    required this.text,
    required this.style,
    required this.maxLines,
    required this.minFontSize,
    required this.maxFontSize,
    this.hyphenateWords = false,
    this.align = Alignment.center,
  });

  final String text;
  final TextStyle style;
  final int maxLines;
  final double minFontSize;
  final double maxFontSize;
  final bool hyphenateWords;
  final Alignment align;

  @override
  Widget build(BuildContext context) {
    final scaler = MediaQuery.textScalerOf(context);
    return LayoutBuilder(
      builder: (context, constraints) {
        final maxWidth = (constraints.maxWidth - 2).clamp(0.0, double.infinity);
        final maxHeight = constraints.maxHeight.isFinite
            ? constraints.maxHeight
            : maxWidth * 2;
        if (maxWidth <= 1 || text.trim().isEmpty) {
          return const SizedBox.shrink();
        }
        final laidOut = layoutTitle(
          text: text,
          style: style,
          maxWidth: maxWidth,
          maxHeight: maxHeight,
          maxLines: maxLines,
          minFontSize: minFontSize,
          maxFontSize: maxFontSize,
          textScaler: scaler,
          hyphenateAtMinSize: hyphenateWords,
        );
        return SizedBox.expand(
          child: Align(
            alignment: align,
            child: Text(
              laidOut.text,
              textAlign: TextAlign.center,
              // layoutTitle already inserted `\n` / `-`; don't re-break letters.
              softWrap: false,
              maxLines: maxLines,
              overflow: TextOverflow.ellipsis,
              style: style.copyWith(fontSize: laidOut.fontSize),
            ),
          ),
        );
      },
    );
  }
}

void _paintHexDepth(
  Canvas canvas,
  Path path,
  Color color, {
  required bool dark,
  double spotlight = 0,
}) {
  final lift = spotlight.clamp(0.0, 1.0);
  // Soft halo in every direction (drawShadow only falls downward).
  final halo = Paint()
    ..color = dark
        ? Colors.white.withValues(alpha: 0.12 + 0.14 * lift)
        : Colors.black.withValues(alpha: 0.12 + 0.12 * lift)
    ..maskFilter = MaskFilter.blur(BlurStyle.normal, 4.5 + 4.0 * lift);
  canvas.drawPath(path, halo);
  if (lift > 0.05) {
    final outer = Paint()
      ..color = dark
          ? Colors.white.withValues(alpha: 0.06 * lift)
          : Colors.black.withValues(alpha: 0.06 * lift)
      ..maskFilter = MaskFilter.blur(BlurStyle.normal, 8 + 4 * lift);
    canvas.drawPath(path, outer);
  }
  canvas.drawPath(path, Paint()..color = color);
  final bounds = path.getBounds();
  final highlight = Paint()
    ..shader = LinearGradient(
      begin: Alignment.topLeft,
      end: Alignment.bottomRight,
      colors: dark
          ? [
              Colors.white.withValues(alpha: 0.14),
              Colors.white.withValues(alpha: 0.0),
              Colors.black.withValues(alpha: 0.22),
            ]
          : [
              Colors.white.withValues(alpha: 0.16),
              Colors.white.withValues(alpha: 0.0),
              Colors.black.withValues(alpha: 0.10),
            ],
      stops: const [0.0, 0.45, 1.0],
    ).createShader(bounds);
  canvas.save();
  canvas.clipPath(path);
  canvas.drawRect(bounds, highlight);
  canvas.restore();
}

class _FlowerTapClipper extends CustomClipper<Path> {
  const _FlowerTapClipper();

  @override
  Path getClip(Size size) {
    final unit = hexFlowerBounds(1.0);
    final lattice = math.min(size.width / unit.width, size.height / unit.height);
    return hexFlowerPath(
      latticeSize: lattice,
      center: Offset(size.width / 2, size.height / 2),
    );
  }

  @override
  bool shouldReclip(covariant _FlowerTapClipper oldClipper) => false;
}

class _HexTapClipper extends CustomClipper<Path> {
  const _HexTapClipper();

  @override
  Path getClip(Size size) {
    final lattice = math.min(size.width / 2, size.height / math.sqrt(3));
    return flatHexPath(
      lattice * (1 - hexGapInset),
      center: Offset(size.width / 2, size.height / 2),
    );
  }

  @override
  bool shouldReclip(covariant _HexTapClipper oldClipper) => false;
}

class _HexFlowerPainter extends CustomPainter {
  _HexFlowerPainter({required this.color, required this.dark, this.spotlight = 0});

  final Color color;
  final bool dark;
  final double spotlight;

  @override
  void paint(Canvas canvas, Size size) {
    final unit = hexFlowerBounds(1.0);
    final lattice = math.min(size.width / unit.width, size.height / unit.height);
    final path = hexFlowerPath(
      latticeSize: lattice,
      center: Offset(size.width / 2, size.height / 2),
    );
    _paintHexDepth(canvas, path, color, dark: dark, spotlight: spotlight);
  }

  @override
  bool shouldRepaint(covariant _HexFlowerPainter oldDelegate) =>
      oldDelegate.color != color ||
      oldDelegate.dark != dark ||
      oldDelegate.spotlight != spotlight;
}

class _HexTilePainter extends CustomPainter {
  _HexTilePainter({required this.color, required this.dark, this.spotlight = 0});

  final Color color;
  final bool dark;
  final double spotlight;

  @override
  void paint(Canvas canvas, Size size) {
    final lattice = math.min(size.width / 2, size.height / math.sqrt(3));
    final path = flatHexPath(
      lattice * (1 - hexGapInset),
      center: Offset(size.width / 2, size.height / 2),
    );
    _paintHexDepth(canvas, path, color, dark: dark, spotlight: spotlight);
  }

  @override
  bool shouldRepaint(covariant _HexTilePainter oldDelegate) =>
      oldDelegate.color != color ||
      oldDelegate.dark != dark ||
      oldDelegate.spotlight != spotlight;
}
