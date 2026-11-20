import 'package:flutter/material.dart';

import '../models.dart';
import 'leitner_bin_chrome.dart';

/// Stacked-card Leitner bins (1…graduation+), Talivo-style.
class LeitnerDistributionCard extends StatelessWidget {
  const LeitnerDistributionCard({
    super.key,
    required this.distribution,
    this.countsRefreshing = false,
  });

  final LeitnerDistribution distribution;
  final bool countsRefreshing;

  @override
  Widget build(BuildContext context) {
    final graduationBin = distribution.graduationBin;
    final maxFromData = distribution.bins.isEmpty
        ? graduationBin
        : distribution.bins.map((b) => b.bin).reduce((a, b) => a > b ? a : b);
    final maxBin = maxFromData < graduationBin ? graduationBin : maxFromData;
    final byBin = {for (final b in distribution.bins) b.bin: b};
    final chart = <LeitnerBinData>[
      for (var bin = 1; bin <= maxBin; bin++)
        byBin[bin] ?? LeitnerBinData(bin: bin, count: 0, countDue: 0, countNotDue: 0),
    ];

    final maxVisualFromData = chart
        .where((d) => d.count > 0)
        .map((d) => LeitnerBinChrome.visualCardCount(d.count))
        .fold(0, (a, b) => a > b ? a : b);
    final maxVisualCount = maxVisualFromData <= 0
        ? 0
        : maxVisualFromData < LeitnerBinChrome.minVisualScaleCards
            ? LeitnerBinChrome.minVisualScaleCards
            : maxVisualFromData;
    final scheme = Theme.of(context).colorScheme;

    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 4, 12, 2),
      child: SizedBox(
        height: 300,
        child: LayoutBuilder(
          builder: (context, constraints) {
            const bottomTitlesReservedHeight = 44.0;
            const barsBottomReservedHeight = 32.0;
            const topChartPadding = 24.0;
            final barAreaHeight =
                (constraints.maxHeight - barsBottomReservedHeight)
                    .clamp(0.0, constraints.maxHeight);
            final drawableBarHeight =
                (barAreaHeight - topChartPadding).clamp(0.0, barAreaHeight);
            final maxStripes = maxVisualCount <= 0
                ? 0
                : maxVisualCount + LeitnerBinChrome.tuckStripes;
            final unitHeight =
                maxStripes > 0 ? drawableBarHeight / maxStripes : 0.0;
            final barWidth = (32.0 - chart.length).clamp(8.0, 28.0);
            final stripeHeight = (unitHeight * 0.85).clamp(1.0, 6.0);

            Color binFill(LeitnerBinData d) =>
                LeitnerBinChrome.fillForBin(d.bin, graduationBin: graduationBin);

            double axisBadgeJitterTop(LeitnerBinData d) {
              final seed = (d.bin * 37 + chart.length * 17) % 5;
              return seed.toDouble() * 0.6;
            }

            double cardHorizontalJitter(LeitnerBinData d, int cardIndex) {
              var seed = d.bin * 73856093 ^ cardIndex * 19349663 ^ 83492791;
              seed ^= (seed >> 13);
              seed *= 1274126177;
              seed ^= (seed >> 16);
              final normalized = (seed & 0x7fffffff) / 0x7fffffff;
              return (normalized * 2.0) - 1.0;
            }

            return Stack(
              children: [
                Positioned(
                  left: 0,
                  right: 0,
                  top: 0,
                  bottom: barsBottomReservedHeight,
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      for (var columnIndex = 0;
                          columnIndex < chart.length;
                          columnIndex++)
                        Builder(
                          builder: (context) {
                            final binData = chart[columnIndex];
                            final visualCount =
                                LeitnerBinChrome.visualCardCount(binData.count);
                            final stripeCount =
                                LeitnerBinChrome.stackStripeCount(binData.count);
                            final fallbackNotDue =
                                (binData.countNotDue == 0 &&
                                        binData.countDue == 0 &&
                                        binData.count > 0)
                                    ? binData.count
                                    : binData.countNotDue;
                            final visualNotDueCount = binData.count > 0
                                ? ((fallbackNotDue / binData.count) *
                                        visualCount)
                                    .round()
                                    .clamp(0, visualCount)
                                : 0;
                            return Expanded(
                              child: Tooltip(
                                message:
                                    'Done: ${binData.countNotDue}\nDue: ${binData.countDue}\nTotal: ${binData.count}',
                                waitDuration: Duration.zero,
                                child: SizedBox.expand(
                                  child: Stack(
                                    clipBehavior: Clip.none,
                                    children: [
                                      if (visualCount > 0)
                                        Positioned(
                                          left: 0,
                                          right: 0,
                                          bottom: stripeCount * unitHeight,
                                          child: Center(
                                            child: Opacity(
                                              opacity: countsRefreshing ? 0.45 : 1,
                                              child: Text(
                                                binData.count >
                                                        LeitnerBinChrome
                                                            .maxVisualCardsPerBin
                                                    ? '100+'
                                                    : '${binData.count}',
                                                style: Theme.of(context)
                                                    .textTheme
                                                    .labelSmall
                                                    ?.copyWith(
                                                      color: binFill(binData)
                                                          .withValues(alpha: 0.9),
                                                      fontWeight: FontWeight.w500,
                                                    ),
                                              ),
                                            ),
                                          ),
                                        ),
                                      if (stripeCount > 0)
                                        Align(
                                          alignment: Alignment.bottomCenter,
                                          child: SizedBox(
                                            width: barWidth,
                                            height: stripeCount * unitHeight,
                                            child: Stack(
                                              children: [
                                                for (var cardIndex = 0;
                                                    cardIndex < stripeCount;
                                                    cardIndex++)
                                                  Builder(
                                                    builder: (context) {
                                                      final jitterX =
                                                          cardHorizontalJitter(
                                                              binData, cardIndex);
                                                      final bottomFadeAlpha =
                                                          cardIndex == 0
                                                              ? 0.42
                                                              : (cardIndex == 1
                                                                  ? 0.58
                                                                  : (cardIndex == 2
                                                                      ? 0.74
                                                                      : 1.0));
                                                      final countedIndex =
                                                          cardIndex -
                                                              LeitnerBinChrome
                                                                  .tuckStripes;
                                                      final colorIndex =
                                                          countedIndex < 0
                                                              ? 0
                                                              : countedIndex;
                                                      final baseColor = colorIndex <
                                                              visualNotDueCount
                                                          ? binFill(binData)
                                                          : LeitnerBinChrome
                                                              .dueOrange;
                                                      return Positioned(
                                                        left: jitterX > 0
                                                            ? jitterX
                                                            : 0,
                                                        right: jitterX < 0
                                                            ? -jitterX
                                                            : 0,
                                                        bottom:
                                                            cardIndex * unitHeight,
                                                        child: Container(
                                                          height: stripeHeight,
                                                          decoration:
                                                              BoxDecoration(
                                                            color: baseColor
                                                                .withValues(
                                                                    alpha:
                                                                        bottomFadeAlpha),
                                                            borderRadius:
                                                                BorderRadius
                                                                    .circular(
                                                                        1.5),
                                                          ),
                                                        ),
                                                      );
                                                    },
                                                  ),
                                              ],
                                            ),
                                          ),
                                        ),
                                    ],
                                  ),
                                ),
                              ),
                            );
                          },
                        ),
                    ],
                  ),
                ),
                Positioned(
                  left: 0,
                  right: 0,
                  bottom: 0,
                  height: bottomTitlesReservedHeight,
                  child: Column(
                    children: [
                      SizedBox(
                        height: 24,
                        child: LayoutBuilder(
                          builder: (context, constraints) {
                            final badgeTopOffsets = [
                              for (final d in chart) axisBadgeJitterTop(d),
                            ];
                            return Stack(
                              children: [
                                Positioned.fill(
                                  child: CustomPaint(
                                    painter: _AxisCenterConnectorPainter(
                                      badgeTopOffsets: badgeTopOffsets,
                                      lineColor: scheme.onSurface
                                          .withValues(alpha: 0.3),
                                      badgeDiameter: 20,
                                      lineYOffset: 7,
                                    ),
                                  ),
                                ),
                                Row(
                                  children: [
                                    for (var i = 0; i < chart.length; i++)
                                      Expanded(
                                        child: _LeitnerAxisBadge(
                                          bin: chart[i].bin,
                                          fill: binFill(chart[i]),
                                          topOffset: badgeTopOffsets[i],
                                        ),
                                      ),
                                  ],
                                ),
                              ],
                            );
                          },
                        ),
                      ),
                      Expanded(
                        child: Row(
                          children: [
                            for (final span in _leitnerGroupSpans(
                              chart,
                              graduationBin,
                            ))
                              Expanded(
                                flex: span.flex,
                                child: Text(
                                  LeitnerBinChrome.groupLabel(span.group),
                                  textAlign: TextAlign.center,
                                  maxLines: 2,
                                  overflow: TextOverflow.ellipsis,
                                  style: Theme.of(context)
                                      .textTheme
                                      .labelSmall
                                      ?.copyWith(
                                        color: LeitnerBinChrome.fillForGroup(
                                            span.group),
                                        fontWeight: FontWeight.w700,
                                        fontSize: 9,
                                        height: 1.0,
                                      ),
                                ),
                              ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }
}

class _LeitnerAxisBadge extends StatelessWidget {
  const _LeitnerAxisBadge({
    required this.bin,
    required this.fill,
    required this.topOffset,
  });

  static const diameter = 20.0;
  static const dotDiameter = 15.5;

  final int bin;
  final Color fill;
  final double topOffset;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: EdgeInsets.only(top: topOffset),
      child: Center(
        child: Container(
          width: diameter,
          height: diameter,
          decoration: BoxDecoration(
            color: LeitnerBinChrome.axisBadgeRing(scheme),
            shape: BoxShape.circle,
            border: Border.all(
              color: scheme.outline.withValues(alpha: 0.18),
              width: 0.8,
            ),
          ),
          child: Center(
            child: Container(
              width: dotDiameter,
              height: dotDiameter,
              decoration: BoxDecoration(color: fill, shape: BoxShape.circle),
              child: Center(
                child: Text(
                  '$bin',
                  style: Theme.of(context).textTheme.labelSmall?.copyWith(
                        color: LeitnerBinChrome.onFill,
                        fontSize: 9,
                        fontWeight: FontWeight.w700,
                      ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

List<({LeitnerBinGroup group, int flex})> _leitnerGroupSpans(
  List<LeitnerBinData> chart,
  int graduationBin,
) {
  final groups = <({LeitnerBinGroup group, int flex})>[];
  for (final binData in chart) {
    final group = LeitnerBinChrome.groupForBin(
      binData.bin,
      graduationBin: graduationBin,
    );
    if (groups.isNotEmpty && groups.last.group == group) {
      groups[groups.length - 1] = (group: group, flex: groups.last.flex + 1);
    } else {
      groups.add((group: group, flex: 1));
    }
  }
  return groups;
}

class _AxisCenterConnectorPainter extends CustomPainter {
  const _AxisCenterConnectorPainter({
    required this.badgeTopOffsets,
    required this.lineColor,
    required this.badgeDiameter,
    this.lineYOffset = 0,
  });

  final List<double> badgeTopOffsets;
  final Color lineColor;
  final double badgeDiameter;
  final double lineYOffset;

  @override
  void paint(Canvas canvas, Size size) {
    if (badgeTopOffsets.length < 2) return;
    final paint = Paint()
      ..color = lineColor
      ..strokeWidth = 1.3
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round;
    final slotWidth = size.width / badgeTopOffsets.length;
    final path = Path();
    for (var i = 0; i < badgeTopOffsets.length; i++) {
      final x = slotWidth * (i + 0.5);
      final y = badgeTopOffsets[i] + (badgeDiameter / 2) + lineYOffset;
      if (i == 0) {
        path.moveTo(x, y);
      } else {
        path.lineTo(x, y);
      }
    }
    canvas.drawPath(path, paint);
  }

  @override
  bool shouldRepaint(covariant _AxisCenterConnectorPainter old) {
    return old.badgeTopOffsets != badgeTopOffsets ||
        old.lineColor != lineColor ||
        old.badgeDiameter != badgeDiameter ||
        old.lineYOffset != lineYOffset;
  }
}
